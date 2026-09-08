// This file is a part of Julia. License is MIT: https://julialang.org/license

/*
  saving and restoring system images

  This performs serialization and deserialization of system and package images. It creates and saves a compact binary
  blob, making deserialization "simple" and fast: we "only" need to deal with uniquing, pointer relocation,
  method root insertion, registering with the garbage collector, making note of special internal types, and
  backedges/invalidation. Special objects include things like builtin functions, C-implemented types (those in jltypes.c),
  the metadata for documentation, optimal layouts, integration with native system image generation, and preparing other
  preprocessing directives.

  During serialization, the flow has several steps:

  - step 1 inserts relevant items into `serialization_order`, an `obj` => `id::Int` mapping. `id` is assigned by
    order of insertion. This stage is implemented by `jl_queue_for_serialization` and its callees;
    while it would be simplest to use recursion, this risks stack overflow, so recursion is mimicked
    using a work-queue managed by `jl_serialize_reachable`.

    It's worth emphasizing that the only goal of this stage is to insert objects into `serialization_order`.
    In later stages, such objects get written in order of `id`.

  - step 2 (the biggest of four steps) takes all items in `serialization_order` and actually serializes them ordered
    by `id`. The system is serialized into several distinct streams (see `jl_serializer_state`), a "main stream"
    (the `s` field) as well as parallel streams for writing specific categories of additional internal data (e.g.,
    global data invisible to codegen, as well as deserialization "touch-up" tables, see below). These different streams
    will be concatenated in later steps. Certain key items (e.g., builtin types & functions associated with `INSERT_TAG`
    below, integers smaller than 512) get serialized via a hard-coded tag table.

    Serialization builds "touch up" tables used during deserialization. Pointers and items requiring gc
    registration get encoded as `(location, target)` pairs in `relocs_list` and `gctags_list`, respectively.
    `location` is the site that needs updating (e.g., the address of a pointer referencing an object), and is
    set to `position(s)`, the offset of the object from the beginning of the deserialized blob.
    `target` is a bitfield-encoded index into lists of different categories of data (e.g., mutable data, constant data,
    symbols, functions, etc.) to which the pointer at `location` refers. The different lists and their bitfield flags
    are given by the `RefTags` enum: if `t` is the category tag (one of the `RefTags` enums) and `i` is the index into
    one of the corresponding categorical list, then `index = t << RELOC_TAG_OFFSET + i`. The simplest source for the
    details of this encoding can be found in the pair of functions `get_reloc_for_item` and `get_item_for_reloc`.

    `uniquing` also holds the serialized location of external DataTypes, MethodInstances, and singletons
    in the serialized blob (i.e., new-at-the-time-of-serialization specializations).

    Most of step 2 is handled by `jl_write_values`, followed by special handling of the dedicated parallel streams.

  - step 3 combines the different sections (fields of `jl_serializer_state`) into one

Much of the "real work" during deserialization is done by `get_item_for_reloc`. But a few items require specific
attention:
- uniquing: during deserialization, the target item (an "external" type or MethodInstance) must be checked against
  the running system to see whether such an object already exists (i.e., whether some other previously-loaded package
  or workload has created such types/MethodInstances previously) or whether it needs to be created de-novo.
  In either case, all references at `location` must be updated to the one in the running system.
    `new_dt_objs` is a hash set of newly allocated datatype-reachable objects
- method root insertion: when new specializations generate new roots, these roots must be inserted into
  method root tables
- backedges & invalidation: external edges have to be checked against the running system and any invalidations executed.

Encoding of a pointer:
- in the location of the pointer, we initially write zero padding
- for both relocs_list and gctags_list, we write loc/backrefid (for gctags_list this is handled by the caller of write_gctaggedfield,
  for relocs_list it's handled by write_pointerfield)
- when writing to disk, both call get_reloc_for_item, and its return value (subject to modification by gc bits)
  ends up being written into the data stream (s->s), and the data stream's position written to s->relocs

External links:
- location holds the offset
- loc/0 in relocs_list

*/
#include <stdlib.h>
#include <string.h>
#include <stdio.h> // printf
#include <inttypes.h> // PRIxPTR

#include <zstd.h>

#include "julia.h"
#include "julia_internal.h"
#include "julia_gcext.h"
#include "builtin_proto.h"
#include "processor.h"
#include "serialize.h"

#ifdef _OS_WINDOWS_
#include <memoryapi.h>
#else
#include <dlfcn.h>
#include <sys/mman.h>
#include <link.h>
#include <fcntl.h>
#include <unistd.h>
#endif

#include "valgrind.h"
#include "julia_assert.h"

static const size_t WORLD_AGE_REVALIDATION_SENTINEL = 0x1;
JL_DLLEXPORT size_t jl_require_world = ~(size_t)0;
JL_DLLEXPORT _Atomic(size_t) jl_first_image_replacement_world = ~(size_t)0;

// This structure is used to store hash tables for the memoization
// of queries in staticdata.c (currently only `type_in_worklist`).
typedef struct {
    htable_t type_in_worklist;
} jl_query_cache;

static void init_query_cache(jl_query_cache *cache) JL_NOTSAFEPOINT
{
    htable_new(&cache->type_in_worklist, 0);
}

static void destroy_query_cache(jl_query_cache *cache) JL_NOTSAFEPOINT
{
    htable_free(&cache->type_in_worklist);
}

#include "staticdata_utils.c"
#include "precompile_utils.c"

#ifdef __cplusplus
extern "C" {
#endif

// TODO: put WeakRefs on the weak_refs list during deserialization
// TODO: handle finalizers

#define NUM_TAGS    6

// An array of special references that need to be restored from the sysimg
static void get_tags(jl_value_t **tags[NUM_TAGS])
{
    // Make sure to keep an extra slot at the end to sentinel length
    unsigned int i = 0;
#define INSERT_TAG(sym) tags[i++] = (jl_value_t**)&(sym)
    INSERT_TAG(jl_method_table);
    INSERT_TAG(jl_module_init_order);
    INSERT_TAG(jl_typeinf_func);
    INSERT_TAG(jl_compile_and_emit_func);
    INSERT_TAG(jl_libdl_dlopen_func);
    // n.b. must update NUM_TAGS when you add something here
#undef INSERT_TAG
    assert(i == NUM_TAGS - 1);
    tags[i] = NULL;
}

// hash of definitions for predefined tagged object
static htable_t symbol_table;
static uintptr_t nsym_tag;
// array of definitions for the predefined tagged object types
// (reverse of symbol_table)
static arraylist_t deser_sym;

static htable_t serialization_order; // to break cycles, mark all objects that are serialized
static htable_t nullptrs;
// FIFO queue for objects to be serialized. Anything requiring fixup upon deserialization
// must be "toplevel" in this queue. For types, parameters and field types must appear
// before the "wrapper" type so they can be properly recached against the running system.
static arraylist_t serialization_queue;
static arraylist_t layout_table;     // cache of `position(s)` for each `id` in `serialization_order`

// ── the image written by pages (Stage F of the reactive plan) ──────────
// `JULIA_REACTIVE_IMAGE_WRITE=pages`: the loader protects the pages of the
// sysimg section and the fault handler marks the pages the process writes
// (reactive_dirty_protect, jl_reactive_dirty_fault). A save then copies the
// clean pages from the file of the base image, rewrites the objects of the
// dirty pages in place, appends the new objects, and merges the relocation
// lists by position. The const data and the symbols are never relocated at
// load, so their base bytes are taken from memory and from the base. The
// loader needs no change: the product is a version 3 image.
static int reactive_overlay_mode(void) JL_NOTSAFEPOINT
{
    const char *env = getenv("JULIA_REACTIVE_IMAGE_WRITE");
    return env != NULL && strcmp(env, "overlay") == 0;
}
static int reactive_pages_mode(void) JL_NOTSAFEPOINT
{
    const char *env = getenv("JULIA_REACTIVE_IMAGE_WRITE");
    return env != NULL && (strcmp(env, "pages") == 0 || strcmp(env, "overlay") == 0);
}

// The sections of an image (Stage G): under `reactive_sections_on` the
// loader takes them from here, not from the stream, so that the sysimg
// and the const data can live in a region of their own.
typedef struct {
    const char *ptr;
    size_t size;
} reactive_span_t;
typedef struct {
    reactive_span_t sysimg;      // with its leading word
    reactive_span_t const_data;
    reactive_span_t symbols;
    reactive_span_t relocs;
    reactive_span_t gvar;
    reactive_span_t fptr;
    reactive_span_t roots;       // the tail of the blob after the fptr record
    size_t blob_span;            // the registered blob: this many bytes from sysimg.ptr
} reactive_sections_t;
static reactive_sections_t reactive_sections;
static int reactive_sections_on = 0;
// The region of an overlay-mode process: the base's sysimg and const data
// mapped from its file at their offsets in the blob (a package image
// names an object of the sysimage by that offset), then headroom for the
// growth of the const data, then the new objects of the overlays. One
// span, one blob; the sysimg offsets of the new objects start past the
// const headroom.
#define REACTIVE_SYSIMG_HEADROOM ((size_t)256 << 20)
#define REACTIVE_CONST_HEADROOM ((size_t)64 << 20)
static char *reactive_region_base = NULL;
static size_t reactive_region_span = 0;
static char *reactive_region_const = NULL;   // the const data inside the region
static char *reactive_region_const_limit = NULL; // the end of the const headroom: the new objects start here
static char *reactive_gap_lo = NULL;         // the unused pages of the const headroom
static char *reactive_gap_hi = NULL;
static size_t reactive_objects_end = 0;      // the end of the objects of the base and the overlays (a sysimg offset)
static size_t reactive_base_end = 0;         // the end of the objects of the base alone: the overlays' objects lie past the const headroom

// The overlay image (Stage G): the delta as a shared object of its own,
// with the blob below; the loader applies a chain of them to the base.
#define REACTIVE_OVERLAY_MAGIC 0x314c5245564f4c4aULL
typedef struct {
    uint64_t magic;
    uint64_t base_sysimg_size;   // the composed sysimg this overlay extends, with its leading word
    uint64_t base_const_size;
    uint64_t base_syms_size;
    uint64_t page_size;
    uint64_t npatch_sysimg;      // page patches: an index list, then the pages
    uint64_t npatch_const;
    uint64_t new_sysimg_size;    // the new objects, after the base
    uint64_t new_const_size;
    uint64_t new_syms_size;
    uint64_t relocs_size;        // the full merged lists
    uint64_t gvar_size;          // the slots of this overlay's own image
    uint64_t fptr_size;          // the fresh table
    uint64_t roots_size;
    uint64_t off_patch_idx_sysimg;
    uint64_t off_patch_sysimg;
    uint64_t off_patch_idx_const;
    uint64_t off_patch_const;
    uint64_t off_new_sysimg;
    uint64_t off_new_const;
    uint64_t off_new_syms;
    uint64_t off_relocs;
    uint64_t off_gvar;
    uint64_t off_fptr;
    uint64_t off_roots;
    uint32_t external_fns_begin;
    uint32_t ngvars;
    uint64_t reserved[4];
} reactive_overlay_header_t;
static int reactive_overlay_on = 0;                 // this save writes an overlay
static reactive_overlay_header_t reactive_overlay_header;
static size_t reactive_overlay_blob_start = 0;      // the position of the blob in the output stream
static int reactive_base_lists_ready = 0;           // reactive_base holds the lists of the loaded state
static int reactive_base_lists_pending = 0;         // the lists of the loaded state wait in reactive_sections.relocs
// the chain of images of an overlay-mode process, for the slot updates
typedef struct {
    jl_image_t img;
    reactive_span_t gvar;
    uint32_t external_fns_begin;
} reactive_chain_image_t;
#define REACTIVE_CHAIN_MAX 64
static reactive_chain_image_t reactive_chain[REACTIVE_CHAIN_MAX];
static size_t reactive_chain_n = 0;
static char *reactive_syms_buffer = NULL;           // the symbols of the base and the overlays, concatenated

JL_DLLEXPORT int jl_reactive_overlay_mode(void) JL_NOTSAFEPOINT
{
    return reactive_overlay_mode();
}

// The sections of a blob, in the layout the save writes.
static int reactive_parse_blob(const char *blob, size_t size, reactive_sections_t *sec) JL_NOTSAFEPOINT
{
    memset(sec, 0, sizeof(*sec));
    size_t pos = 0;
    if (size < sizeof(uintptr_t))
        return 0;
    size_t sizeof_sysdata = *(const uintptr_t*)(blob + pos);
    sec->sysimg.ptr = blob + pos;
    sec->sysimg.size = sizeof_sysdata + sizeof(uintptr_t);
    pos += sizeof(uintptr_t) + sizeof_sysdata;
    if (pos + sizeof(uintptr_t) > size)
        return 0;
    sec->const_data.size = *(const uintptr_t*)(blob + pos);
    pos += sizeof(uintptr_t);
    pos = LLT_ALIGN(pos, JL_CACHE_BYTE_ALIGNMENT);
    sec->const_data.ptr = blob + pos;
    pos += sec->const_data.size;
    sec->blob_span = pos;
    sec->symbols.size = *(const uintptr_t*)(blob + pos);
    pos += sizeof(uintptr_t);
    pos = LLT_ALIGN(pos, 8);
    sec->symbols.ptr = blob + pos;
    pos += sec->symbols.size;
    sec->relocs.size = *(const uintptr_t*)(blob + pos);
    pos += sizeof(uintptr_t);
    pos = LLT_ALIGN(pos, 8);
    sec->relocs.ptr = blob + pos;
    pos += sec->relocs.size;
    sec->gvar.size = *(const uintptr_t*)(blob + pos);
    pos += sizeof(uintptr_t);
    pos = LLT_ALIGN(pos, 8);
    sec->gvar.ptr = blob + pos;
    pos += sec->gvar.size;
    sec->fptr.size = *(const uintptr_t*)(blob + pos);
    pos += sizeof(uintptr_t);
    pos = LLT_ALIGN(pos, 8);
    sec->fptr.ptr = blob + pos;
    pos += sec->fptr.size;
    pos = LLT_ALIGN(pos, 8);
    if (pos > size)
        return 0;
    sec->roots.ptr = blob + pos;
    sec->roots.size = size - pos;
    return 1;
}
// the loaded image
static char *reactive_image_base = NULL;        // the sysimg section of the loaded image (its leading word first)
static size_t reactive_image_len = 0;
static size_t reactive_sysimg_size = 0;         // the sysimg section with its leading word
static const char *reactive_blob_data = NULL;   // the blob of the loaded image, used in place
static size_t reactive_blob_size = 0;
static char *reactive_const_base = NULL;        // the const data section of the loaded image
static size_t reactive_const_len = 0;
static char *reactive_syms_base = NULL;         // the symbols section of the loaded image
static size_t reactive_syms_len = 0;
static arraylist_t reactive_base_syms;          // the symbols of the base, in index order
static int reactive_base_syms_kept = 0;
// the dirty pages
static char *reactive_dirty_start = NULL;
static size_t reactive_dirty_len = 0;
static uint8_t *reactive_dirty_bits = NULL;
static size_t reactive_dirty_npages = 0;
static const char *reactive_dirty_path = NULL;
// the base image, from its file: the sections and the lists
typedef struct {
    char *map;                  // the private mapping of the file bytes of the blob
    size_t map_len;
    const char *sysimg;         // the sections, file bytes
    size_t sysimg_size;         // with the leading word
    const char *const_data;
    size_t const_size;
    const char *symbols;
    size_t symbols_size;
    const char *relocs;
    size_t relocs_size;
    arraylist_t gctags;         // the positions of the lists of the base, ascending
    arraylist_t relocs_list;
    arraylist_t memowner;
    arraylist_t memref;
    arraylist_t fixups;         // the fixup objects of the base (offsets)
} reactive_base_t;
static reactive_base_t reactive_base;
static int reactive_base_mapped = 0;
// this save
static int reactive_pages_on = 0;               // the save writes by pages
static int reactive_pages_force = 0;            // the pre-queue of the dirty objects passes the base test
static int reactive_pages_retry = 0;            // a refused page write runs again as a whole write
static uint8_t *reactive_pages_bits = NULL;     // the snapshot of the dirty bitmap
static uint8_t *reactive_pages_rewritten = NULL; // per base object: rewritten in place
static const char *reactive_pages_refusal = NULL; // the reason the save writes whole instead
static size_t reactive_pages_append = 0;        // the append position of the sysimg stream
static size_t reactive_pages_const_append = 0;  // the append position of the const data stream
static size_t reactive_pages_ndirty = 0;
static size_t reactive_pages_nrewritten = 0;
static uint64_t *reactive_page_hashes = NULL;   // per protected page: the hash of its bytes at the load

// The hash of a page: a page the process wrote and restored (a lock taken
// and released) hashes as at the load, and the save treats it as clean.
static uint64_t reactive_page_hash(const char *page) JL_NOTSAFEPOINT
{
    const uint64_t *w = (const uint64_t*)page;
    size_t n = jl_page_size / sizeof(uint64_t);
    uint64_t h = 0x9E3779B97F4A7C15ULL;
    for (size_t i = 0; i < n; i++) {
        h ^= w[i];
        h *= 0xBF58476D1CE4E5B9ULL;
        h ^= h >> 31;
    }
    return h;
}

static inline int reactive_in_sysimg(const void *v) JL_NOTSAFEPOINT
{
    return reactive_image_base != NULL && (const char*)v >= reactive_image_base &&
           (const char*)v < reactive_image_base + reactive_sysimg_size;
}

static inline int reactive_in_const(const void *v) JL_NOTSAFEPOINT
{
    return reactive_const_base != NULL && (const char*)v >= reactive_const_base &&
           (const char*)v < reactive_const_base + reactive_const_len;
}

// A page of the sysimg section that the process wrote since the load. The
// bytes outside the protected range count as written.
static int reactive_pages_dirty(const char *addr) JL_NOTSAFEPOINT
{
    if (reactive_dirty_start == NULL || addr < reactive_dirty_start ||
        addr >= reactive_dirty_start + reactive_dirty_len)
        return 1;
    return reactive_pages_bits[(addr - reactive_dirty_start) / jl_page_size];
}

// The liveness test of the prunes: queued, or an object of the base when
// the save writes by pages (the base stays whole).
static inline int reactive_pages_live(jl_value_t *v) JL_NOTSAFEPOINT
{
    return ptrhash_get(&serialization_order, v) != HT_NOTFOUND ||
           (reactive_pages_on && jl_object_in_image(v));
}

// The index of the base object whose tag is at `pos`, or of the last object
// whose tag is before `pos`.
static size_t reactive_base_object_at(size_t pos) JL_NOTSAFEPOINT
{
    arraylist_t *tags = &reactive_base.gctags;
    size_t lo = 0, hi = tags->len;
    while (hi - lo > 1) {
        size_t mid = lo + (hi - lo) / 2;
        if ((size_t)tags->items[mid] <= pos)
            lo = mid;
        else
            hi = mid;
    }
    return lo;
}
static arraylist_t object_worklist;  // used to mimic recursion by jl_serialize_reachable
// JULIA_REACTIVE_HEAPDUMP (reactive_dump_heap): the object whose fields are
// walked, and the first referrer of every object.
static int reactive_dump_on = 0;
static jl_value_t *reactive_dump_walking = NULL;
static htable_t reactive_dump_parents;
static arraylist_t deferred_supers;  // deferred datatype super fields, handled by jl_serialize_reachable once the pre-order recursion has unwound

// Permanent list of void* (begin, end+1) pairs of system/package images we've loaded previously
// together with their module build_ids (used for external linkage)
// jl_linkage_blobs.items[2i:2i+1] correspond to build_ids[i]   (0-offset indexing)
arraylist_t jl_linkage_blobs;
arraylist_t jl_image_relocs;
// Keep track of which image corresponds to which top module.
arraylist_t jl_top_mods;

// Eytzinger tree of images. Used for very fast jl_object_in_image queries
// See https://algorithmica.org/en/eytzinger
arraylist_t eytzinger_image_tree;
arraylist_t eytzinger_idxs;
static uintptr_t img_min;
static uintptr_t img_max;

// HT_NOTFOUND is a valid integer ID, so we store the integer ids mangled.
// This pair of functions mangles/demanges
static size_t from_seroder_entry(void *entry) JL_NOTSAFEPOINT
{
    return (size_t)((char*)entry - (char*)HT_NOTFOUND - 1);
}

static void *to_seroder_entry(size_t idx) JL_NOTSAFEPOINT
{
    return (void*)((char*)HT_NOTFOUND + 1 + idx);
}

static htable_t new_methtables;
//static size_t precompilation_world;

static int ptr_cmp(const void *l, const void *r) JL_NOTSAFEPOINT
{
    uintptr_t left = *(const uintptr_t*)l;
    uintptr_t right = *(const uintptr_t*)r;
    return (left > right) - (left < right);
}

// Build an eytzinger tree from a sorted array
static int eytzinger(uintptr_t *src, uintptr_t *dest, size_t i, size_t k, size_t n) JL_NOTSAFEPOINT
{
    if (k <= n) {
        i = eytzinger(src, dest, i, 2 * k, n);
        dest[k-1] = src[i];
        i++;
        i = eytzinger(src, dest, i, 2 * k + 1, n);
    }
    return i;
}

static size_t eyt_obj_idx(jl_value_t *obj) JL_NOTSAFEPOINT
{
    size_t n = eytzinger_image_tree.len - 1;
    if (n == 0)
        return n;
    assert(n % 2 == 0 && "Eytzinger tree not even length!");
    uintptr_t cmp = (uintptr_t) obj;
    if (cmp <= img_min || cmp > img_max)
        return n;
    uintptr_t *tree = (uintptr_t*)eytzinger_image_tree.items;
    size_t k = 1;
    // note that k preserves the history of how we got to the current node
    while (k <= n) {
        int greater = (cmp > tree[k - 1]);
        k <<= 1;
        k |= greater;
    }
    // Free to assume k is nonzero, since we start with k = 1
    // and cmp > gc_img_min
    // This shift does a fast revert of the path until we get
    // to a node that evaluated less than cmp.
    k >>= (__builtin_ctzll(k) + 1);
    assert(k != 0);
    assert(k <= n && "Eytzinger tree index out of bounds!");
    assert(tree[k - 1] < cmp && "Failed to find lower bound for object!");
    return k - 1;
}

//used in staticdata.c after we add an image
void rebuild_image_blob_tree(void) JL_NOTSAFEPOINT
{
    size_t inc = 1 + jl_linkage_blobs.len - eytzinger_image_tree.len;
    assert(eytzinger_idxs.len == eytzinger_image_tree.len);
    assert(eytzinger_idxs.max == eytzinger_image_tree.max);
    arraylist_grow(&eytzinger_idxs, inc);
    arraylist_grow(&eytzinger_image_tree, inc);
    eytzinger_idxs.items[eytzinger_idxs.len - 1] = (void*)jl_linkage_blobs.len;
    eytzinger_image_tree.items[eytzinger_image_tree.len - 1] = (void*)1; // outside image
    for (size_t i = 0; i < jl_linkage_blobs.len; i++) {
        assert((uintptr_t) jl_linkage_blobs.items[i] % 4 == 0 && "Linkage blob not 4-byte aligned!");
        // We abuse the pointer here a little so that a couple of properties are true:
        // 1. a start and an end are never the same value. This simplifies the binary search.
        // 2. ends are always after starts. This also simplifies the binary search.
        // We assume that there exist no 0-size blobs, but that's a safe assumption
        // since it means nothing could be there anyways
        uintptr_t val = (uintptr_t) jl_linkage_blobs.items[i];
        eytzinger_idxs.items[i] = (void*)(val + (i & 1));
    }
    qsort(eytzinger_idxs.items, eytzinger_idxs.len - 1, sizeof(void*), ptr_cmp);
    img_min = (uintptr_t) eytzinger_idxs.items[0];
    img_max = (uintptr_t) eytzinger_idxs.items[eytzinger_idxs.len - 2] + 1;
    eytzinger((uintptr_t*)eytzinger_idxs.items, (uintptr_t*)eytzinger_image_tree.items, 0, 1, eytzinger_idxs.len - 1);
    // Reuse the scratch memory to store the indices
    // Still O(nlogn) because binary search
    for (size_t i = 0; i < jl_linkage_blobs.len; i ++) {
        uintptr_t val = (uintptr_t) jl_linkage_blobs.items[i];
        // This is the same computation as in the prior for loop
        uintptr_t eyt_val = val + (i & 1);
        size_t eyt_idx = eyt_obj_idx((jl_value_t*)(eyt_val + 1)); assert(eyt_idx < eytzinger_idxs.len - 1);
        assert(eytzinger_image_tree.items[eyt_idx] == (void*)eyt_val && "Eytzinger tree failed to find object!");
        if (i & 1)
            eytzinger_idxs.items[eyt_idx] = (void*)n_linkage_blobs();
        else
            eytzinger_idxs.items[eyt_idx] = (void*)(i / 2);
    }
}

static int eyt_obj_in_img(jl_value_t *obj) JL_NOTSAFEPOINT
{
    assert((uintptr_t) obj % 4 == 0 && "Object not 4-byte aligned!");
    int idx = eyt_obj_idx(obj);
    // Now we use a tiny trick: tree[idx] & 1 is whether or not tree[idx] is a
    // start (0) or an end (1) of a blob. If it's a start, then the object is
    // in the image, otherwise it is not.
    int in_image = ((uintptr_t)eytzinger_image_tree.items[idx] & 1) == 0;
    return in_image;
}

size_t external_blob_index(jl_value_t *v) JL_NOTSAFEPOINT
{
    assert((uintptr_t) v % 4 == 0 && "Object not 4-byte aligned!");
    int eyt_idx = eyt_obj_idx(v);
    // We fill the invalid slots with the length, so we can just return that
    size_t idx = (size_t) eytzinger_idxs.items[eyt_idx];
    return idx;
}

JL_DLLEXPORT uint8_t jl_object_in_image(jl_value_t *obj) JL_NOTSAFEPOINT
{
    return eyt_obj_in_img(obj);
}

// Map an object to it's "owning" top module
JL_DLLEXPORT jl_value_t *jl_object_top_module(jl_value_t* v) JL_NOTSAFEPOINT
{
    size_t idx = external_blob_index(v);
    size_t lbids = n_linkage_blobs();
    if (idx < lbids) {
        return (jl_value_t*)jl_top_mods.items[idx];
    }
    // The object is runtime allocated
    return (jl_value_t*)jl_nothing;
}

// hash of definitions for predefined function pointers
// (reverse is jl_builtin_f_addrs)
static htable_t fptr_to_id;

void *native_functions;   // opaque jl_native_code_desc_t blob used for fetching data from LLVM

// table of struct field addresses to rewrite during saving
static htable_t field_replace;
static htable_t bits_replace;


typedef struct {
    ios_t *s;                   // the main stream
    ios_t *const_data;          // GC-invisible internal data (e.g., datatype layouts, list-like typename fields, foreign types, internal arrays)
    ios_t *symbols;             // names (char*) of symbols (some may be referenced by pointer in generated code)
    ios_t *relocs;              // for (de)serializing relocs_list and gctags_list
    ios_t *gvar_record;         // serialized array mapping gvid => spos
    ios_t *fptr_record;         // serialized array mapping fptrid => spos
    arraylist_t memowner_list;  // a list of memory locations that have shared owners
    arraylist_t memref_list;    // a list of memoryref locations
    arraylist_t relocs_list;    // a list of (location, target) pairs, see description at top
    arraylist_t gctags_list;    //      "
    arraylist_t uniquing_types; // a list of locations that reference types that must be de-duplicated
    arraylist_t uniquing_super; // a list of datatypes, used in super fields, that need to be marked in uniquing_types once they are reached, for handling unique-ing of them on deserialization
    arraylist_t uniquing_objs;  // a list of locations that reference non-types that must be de-duplicated
    arraylist_t fixup_types;    // a list of locations of types requiring (re)caching
    arraylist_t fixup_objs;     // a list of locations of objects requiring (re)caching
    // mapping from a buildid_idx to a depmods_idx
    jl_array_t *buildid_depmods_idxs;
    // record of build_ids for all external linkages, in order of serialization for the current sysimg/pkgimg
    // conceptually, the base pointer for the jth externally-linked item is determined from
    //     i = findfirst(==(link_ids[j]), build_ids)
    //     blob_base = jl_linkage_blobs.items[2i]                     # 0-offset indexing
    // We need separate lists since they are intermingled at creation but split when written.
    jl_array_t *link_ids_relocs;
    jl_array_t *link_ids_gctags;
    jl_array_t *link_ids_gvars;
    jl_array_t *link_ids_external_fnvars;
    jl_array_t *method_roots_list;
    htable_t method_roots_index;
    uint64_t worklist_key;
    jl_query_cache *query_cache;
    jl_ptls_t ptls;
    jl_image_t *image;
    int8_t incremental;
    char *root_base;            // the sysimg base the roots resolve against, when they are read from another stream
} jl_serializer_state;

static jl_value_t *jl_bigint_type = NULL;
static jl_debuginfo_t *jl_nulldebuginfo;
static int gmp_limb_size = 0;

#ifdef _P64
#define RELOC_TAG_OFFSET 61
#define DEPS_IDX_OFFSET 40    // only on 64-bit can we encode the dependency-index as part of the tagged reloc
#else
// this supports up to 8 RefTags, 512MB of pointer data, and 4/2 (64/32-bit) GB of constant data.
#define RELOC_TAG_OFFSET 29
#define DEPS_IDX_OFFSET RELOC_TAG_OFFSET
#endif


// Tags of category `t` are located at offsets `t << RELOC_TAG_OFFSET`
// Consequently there is room for 2^RELOC_TAG_OFFSET pointers, etc
enum RefTags {
    DataRef,            // mutable data
    ConstDataRef,       // constant data (e.g., layouts)
    TagRef,             // items serialized via their tags
    SymbolRef,          // symbols
    FunctionRef,        // functions
    SysimageLinkage,    // reference to the sysimage (from pkgimage)
    ExternalLinkage,    // reference to some other pkgimage
    BaseRef             // an object of the base of a page-written image, by its final offset
};

#define SYS_EXTERNAL_LINK_UNIT sizeof(void*)

// calling conventions for internal entry points.
// this is used to set the method-instance->invoke field
typedef enum {
    JL_API_NULL,
    JL_API_BOXED,
    JL_API_CONST,
    JL_API_WITH_PARAMETERS,
    JL_API_OC_CALL,
    JL_API_INTERPRETED,
    JL_API_BUILTIN,
    JL_API_MAX
} jl_callingconv_t;

// Sub-divisions of some RefTags
const uintptr_t BuiltinFunctionTag = ((uintptr_t)1 << (RELOC_TAG_OFFSET - 1));


#if RELOC_TAG_OFFSET <= 32
typedef uint32_t reloc_t;
#else
typedef uint64_t reloc_t;
#endif
static void write_reloc_t(ios_t *s, uintptr_t reloc_id) JL_NOTSAFEPOINT
{
    if (sizeof(reloc_t) <= sizeof(uint32_t)) {
        assert(reloc_id < UINT32_MAX);
        write_uint32(s, reloc_id);
    }
    else {
        write_uint64(s, reloc_id);
    }
}

// Reporting to PkgCacheInspector
typedef struct {
    size_t sysdata;
    size_t isbitsdata;
    size_t symboldata;
    size_t tagslist;
    size_t reloclist;
    size_t gvarlist;
    size_t fptrlist;
} pkgcachesizes;

// --- Static Compile ---
static jl_image_buf_t jl_sysimage_buf = { JL_IMAGE_KIND_NONE };

static inline uintptr_t *sysimg_gvars(const char *base, const int32_t *offsets, size_t idx)
{
    return (uintptr_t*)(base + offsets[idx]);
}

JL_DLLEXPORT int jl_running_on_valgrind(void)
{
    return RUNNING_ON_VALGRIND;
}

// --- serializer ---

#define NBOX_C 1024

static int jl_needs_serialization(jl_serializer_state *s, jl_value_t *v) JL_NOTSAFEPOINT
{
    // ignore items that are given a special relocation representation
    if (s->incremental && jl_object_in_image(v))
        return 0;

    if (v == NULL || jl_is_symbol(v) || v == jl_nothing) {
        return 0;
    }
    else if (jl_typetagis(v, jl_int64_tag << 4)) {
        int64_t i64 = *(int64_t*)v + NBOX_C / 2;
        if ((uint64_t)i64 < NBOX_C)
            return 0;
    }
    else if (jl_typetagis(v, jl_int32_tag << 4)) {
        int32_t i32 = *(int32_t*)v + NBOX_C / 2;
        if ((uint32_t)i32 < NBOX_C)
            return 0;
    }
    else if (jl_typetagis(v, jl_uint8_tag << 4)) {
        return 0;
    }
    else if (v == (jl_value_t*)s->ptls->root_task) {
        return 0;
    }
    // A page-written image copies the objects of the base from the base
    // file: the walk stops at them, except at the dirty objects that the
    // save queues first.
    if (reactive_pages_on && !reactive_pages_force && jl_object_in_image(v))
        return 0;

    return 1;
}

static int caching_tag(jl_value_t *v, jl_query_cache *query_cache) JL_NOTSAFEPOINT
{
    if (jl_is_method_instance(v)) {
        jl_method_instance_t *mi = (jl_method_instance_t*)v;
        jl_value_t *m = mi->def.value;
        if (jl_is_method(m) && jl_object_in_image(m))
            return 1 + type_in_worklist(mi->specTypes, query_cache);
    }
    if (jl_is_binding(v)) {
        jl_globalref_t *gr = ((jl_binding_t*)v)->globalref;
        if (!gr)
            return 0;
        if (!jl_object_in_image((jl_value_t*)gr->mod))
            return 0;
        return 1;
    }
    if (jl_is_datatype(v)) {
        jl_datatype_t *dt = (jl_datatype_t*)v;
        if (jl_is_tuple_type(dt) ? !dt->isconcretetype : dt->hasfreetypevars)
            return 0; // aka !is_cacheable from jltypes.c
        if (jl_object_in_image((jl_value_t*)dt->name))
            return 1 + type_in_worklist(v, query_cache);
    }
    jl_value_t *dtv = jl_typeof(v);
    if (jl_is_datatype_singleton((jl_datatype_t*)dtv)) {
        return 1 - type_in_worklist(dtv, query_cache); // these are already recached in the datatype in the image
    }
    return 0;
}

static int needs_recaching(jl_value_t *v, jl_query_cache *query_cache) JL_NOTSAFEPOINT
{
    return caching_tag(v, query_cache) == 2;
}

static int needs_uniquing(jl_value_t *v, jl_query_cache *query_cache) JL_NOTSAFEPOINT
{
    assert(!jl_object_in_image(v));
    return caching_tag(v, query_cache) == 1;
}

static void record_field_change(jl_value_t **addr, jl_value_t *newval) JL_NOTSAFEPOINT
{
    if (*addr != newval)
        ptrhash_put(&field_replace, (void*)addr, newval);
}

static jl_value_t *get_replaceable_field(jl_value_t **addr, int mutabl) JL_GC_DISABLED
{
    jl_value_t *fld = (jl_value_t*)ptrhash_get(&field_replace, addr);
    if (fld == HT_NOTFOUND) {
        fld = *addr;
        if (mutabl && fld && jl_is_cpointer_type(jl_typeof(fld)) && jl_unbox_voidpointer(fld) != NULL && jl_unbox_voidpointer(fld) != (void*)(uintptr_t)-1) {
            void **nullval = ptrhash_bp(&nullptrs, (void*)jl_typeof(fld));
            if (*nullval == HT_NOTFOUND) {
                void *C_NULL = NULL;
                *nullval = (void*)jl_new_bits(jl_typeof(fld), &C_NULL);
            }
            fld = (jl_value_t*)*nullval;
        }
        return fld;
    }
    return fld;
}

static uintptr_t jl_fptr_id(void *fptr)
{
    void **pbp = ptrhash_bp(&fptr_to_id, fptr);
    if (*pbp == HT_NOTFOUND || fptr == NULL)
        return 0;
    else
        return *(uintptr_t*)pbp;
}

static int effects_foldable(uint32_t effects)
{
    // N.B.: This needs to be kept in sync with Core.Compiler.is_foldable(effects, true)
    return ((effects & 0x7) == 0) && // is_consistent(effects)
           (((effects >> 10) & 0x03) == 0) && // is_noub(effects)
           (((effects >> 3) & 0x03) == 0) && // is_effect_free(effects)
           ((effects >> 6) & 0x01); // is_terminates(effects)
}


// `jl_queue_for_serialization` adds items to `serialization_order`
#define jl_queue_for_serialization(s, v) jl_queue_for_serialization_((s), (jl_value_t*)(v), 1, 0)
static void jl_queue_for_serialization_(jl_serializer_state *s, jl_value_t *v, int recursive, int immediate) JL_GC_DISABLED;

// Set while a reactive image is written; the format is described below.
static int reactive_prune_heap = 0;

// A weak list of a module: the list and its memory are serialized, its
// members only when something else reaches them. The list is pruned to the
// serialized members once the heap is known (reactive_prune_weak_list), the
// way the backedge lists of a binding are.
static void reactive_queue_weak_list(jl_serializer_state *s, jl_value_t *list) JL_GC_DISABLED
{
    if (list == jl_nothing)
        return;
    jl_queue_for_serialization_(s, (jl_value_t*)((jl_array_t*)list)->ref.mem, 0, 1);
    jl_queue_for_serialization(s, list);
}

static void jl_queue_module_for_serialization(jl_serializer_state *s, jl_module_t *m) JL_GC_DISABLED
{
    jl_queue_for_serialization(s, m->name);
    jl_queue_for_serialization(s, m->parent);
    if (!jl_options.strip_metadata)
        jl_queue_for_serialization(s, m->file);
    jl_queue_for_serialization(s, jl_atomic_load_relaxed(&m->bindingkeyset));
    if (jl_options.trim) {
        jl_queue_for_serialization_(s, (jl_value_t*)jl_atomic_load_relaxed(&m->bindings), 0, 1);
        jl_svec_t *table = jl_atomic_load_relaxed(&m->bindings);
        for (size_t i = 0; i < jl_svec_len(table); i++) {
            jl_binding_t *b = (jl_binding_t*)jl_svecref(table, i);
            if ((void*)b == jl_nothing)
                break;
            jl_value_t *val = jl_get_binding_value_in_world(b, jl_atomic_load_relaxed(&jl_world_counter));
            // keep binding objects that are defined in the latest world and ...
            if (val &&
                // ... point to modules ...
                (jl_is_module(val) ||
                 // ... or point to __init__ methods ...
                 !strcmp(jl_symbol_name(b->globalref->name), "__init__") ||
                 // ... or point to Base functions accessed by the runtime
                 (m == jl_base_module && (!strcmp(jl_symbol_name(b->globalref->name), "wait") ||
                                          !strcmp(jl_symbol_name(b->globalref->name), "task_done_hook") ||
                                          !strcmp(jl_symbol_name(b->globalref->name), "_uv_hook_close"))))) {
                jl_queue_for_serialization(s, b);
            }
        }
    }
    else {
        jl_queue_for_serialization(s, jl_atomic_load_relaxed(&m->bindings));
    }

    for (size_t i = 0; i < module_usings_length(m); i++) {
        jl_queue_for_serialization(s, module_usings_getmod(m, i));
    }

    if (jl_options.trim || jl_options.strip_ir) {
        record_field_change((jl_value_t**)&m->usings_backedges, jl_nothing);
        record_field_change((jl_value_t**)&m->scanned_methods, jl_nothing);
    }
    else if (reactive_prune_heap) {
        // A module that only a `using` backedge reaches is dead: nothing can
        // name it again. So is a method that only the scanned list reaches:
        // a deleted one. Both lists are weak in a reactive image, or every
        // `Module()` of a rebuild would stay in the image with its bindings.
        reactive_queue_weak_list(s, m->usings_backedges);
        reactive_queue_weak_list(s, m->scanned_methods);
    }
    else {
        jl_queue_for_serialization(s, m->usings_backedges);
        jl_queue_for_serialization(s, m->scanned_methods);
    }
}

static int codeinst_may_be_runnable(jl_code_instance_t *ci, int incremental) {
    size_t max_world = jl_atomic_load_relaxed(&ci->max_world);
    if (max_world == ~(size_t)0)
        return 1;
    if (incremental)
        return 0;
    return jl_atomic_load_relaxed(&ci->min_world) <= jl_typeinf_world && jl_typeinf_world <= max_world;
}

// The reactive image format drops what no world of the image runs: a method
// table entry that a deleted method closed (`jl_method_table_disable`), and
// a code instance that an edit invalidated. Both have a finite `max_world`;
// the ones that the world of the compiler still runs stay, as
// `codeinst_may_be_runnable` keeps them. A dropped entry takes its method,
// the specializations and their code out of the image: the backedge lists
// are pruned to the serialized code instances. A stock image keeps them all.
// `reactive_prune_heap` (above) is set while such an image is written.

static int reactive_entry_dead(jl_typemap_entry_t *e) JL_NOTSAFEPOINT
{
    size_t max_world = jl_atomic_load_relaxed(&e->max_world);
    if (max_world == ~(size_t)0)
        return 0;
    return !(jl_atomic_load_relaxed(&e->min_world) <= jl_typeinf_world && jl_typeinf_world <= max_world);
}

static jl_typemap_entry_t *reactive_live_entry(jl_typemap_entry_t *e) JL_NOTSAFEPOINT
{
    while ((jl_value_t*)e != jl_nothing && reactive_entry_dead(e))
        e = jl_atomic_load_relaxed(&e->next);
    return e;
}

static jl_code_instance_t *reactive_live_ci(jl_code_instance_t *ci) JL_NOTSAFEPOINT
{
    while (ci != NULL && !codeinst_may_be_runnable(ci, 0))
        ci = jl_atomic_load_relaxed(&ci->next);
    return ci;
}

// Record the `next` changes that take the dead entries out of the chain at
// `head`; returns the live head (`jl_nothing` for an empty chain).
static jl_typemap_entry_t *reactive_prune_entries(jl_typemap_entry_t *head) JL_NOTSAFEPOINT
{
    jl_typemap_entry_t *live = reactive_live_entry(head);
    for (jl_typemap_entry_t *e = live; (jl_value_t*)e != jl_nothing; ) {
        jl_typemap_entry_t *next = jl_atomic_load_relaxed(&e->next);
        jl_typemap_entry_t *nlive = reactive_live_entry(next);
        if (nlive != next)
            record_field_change((jl_value_t**)&e->next, (jl_value_t*)nlive);
        e = nlive;
    }
    return live;
}

static void reactive_prune_typemap_memory(jl_genericmemory_t *a) JL_NOTSAFEPOINT;

// Record the field changes that take the dead entries out of a typemap
// (`Union{TypeMapLevel, TypeMapEntry, Nothing}`) held in `slot`.
static void reactive_prune_typemap(jl_value_t **slot) JL_NOTSAFEPOINT
{
    jl_value_t *v = *slot;
    if (v == NULL || v == jl_nothing)
        return;
    if (jl_typetagis(v, jl_typemap_entry_type)) {
        jl_typemap_entry_t *live = reactive_prune_entries((jl_typemap_entry_t*)v);
        if ((jl_value_t*)live != v)
            record_field_change(slot, (jl_value_t*)live);
    }
    else if (jl_typetagis(v, jl_typemap_level_type)) {
        jl_typemap_level_t *node = (jl_typemap_level_t*)v;
        reactive_prune_typemap_memory(jl_atomic_load_relaxed(&node->targ));
        reactive_prune_typemap_memory(jl_atomic_load_relaxed(&node->arg1));
        reactive_prune_typemap_memory(jl_atomic_load_relaxed(&node->tname));
        reactive_prune_typemap_memory(jl_atomic_load_relaxed(&node->name1));
        reactive_prune_typemap((jl_value_t**)&node->linear);
        reactive_prune_typemap((jl_value_t**)&node->any);
    }
}

// The entry chain in the value slot `i` of an eqtable (`data[i - 1]` holds
// the key). An empty chain is not a value there: `lookup_leafcache` and
// `Base.visit` read the fields of a value; the slot becomes the deleted-key
// tombstone of the eqtable (key `nothing`, value NULL), which both skip.
static void reactive_prune_eqtable_chain(jl_value_t **data, size_t i) JL_NOTSAFEPOINT
{
    jl_value_t *d = data[i];
    jl_typemap_entry_t *live = reactive_prune_entries((jl_typemap_entry_t*)d);
    if ((jl_value_t*)live == jl_nothing) {
        record_field_change(&data[i - 1], jl_nothing);
        record_field_change(&data[i], NULL);
    }
    else if ((jl_value_t*)live != d) {
        record_field_change(&data[i], (jl_value_t*)live);
    }
}

// The values of a typemap hash (`jl_typemap_memory_visitor`): a typemap, or
// a hash of typemaps.
static void reactive_prune_typemap_memory(jl_genericmemory_t *a) JL_NOTSAFEPOINT
{
    if (a == NULL || a == (jl_genericmemory_t*)jl_an_empty_memory_any)
        return;
    jl_value_t **data = (jl_value_t**)a->ptr;
    for (size_t i = 1; i < a->length; i += 2) {
        jl_value_t *d = data[i];
        if (d == NULL)
            continue;
        if (jl_is_genericmemory(d))
            reactive_prune_typemap_memory((jl_genericmemory_t*)d);
        else if (jl_typetagis(d, jl_typemap_entry_type))
            reactive_prune_eqtable_chain(data, i);
        else
            reactive_prune_typemap(&data[i]);
    }
}

// The leaf cache is an eqtable from a type tuple to an entry chain.
static void reactive_prune_leafcache(jl_genericmemory_t *a) JL_NOTSAFEPOINT
{
    if (a == NULL || a == (jl_genericmemory_t*)jl_an_empty_memory_any)
        return;
    jl_value_t **data = (jl_value_t**)a->ptr;
    for (size_t i = 1; i < a->length; i += 2) {
        if (data[i] != NULL)
            reactive_prune_eqtable_chain(data, i);
    }
}

static int reactive_prune_mtable(jl_methtable_t *mt, void *env)
{
    (void)env;
    reactive_prune_typemap((jl_value_t**)&mt->defs);
    jl_methcache_t *mc = mt->cache;
    reactive_prune_typemap((jl_value_t**)&mc->cache);
    reactive_prune_leafcache(jl_atomic_load_relaxed(&mc->leafcache));
    return 1;
}

// Anything that requires uniquing or fixing during deserialization needs to be "toplevel"
// in serialization (i.e., have its own entry in `serialization_order`). Consequently,
// objects that act as containers for other potentially-"problematic" objects must add such "children"
// to the queue.
// Most objects use preorder traversal. But things that need uniquing require postorder:
// you want to handle uniquing of `Dict{String,Float64}` before you tackle `Vector{Dict{String,Float64}}`.
// Uniquing is done in `serialization_order`, so the very first mention of such an object must
// be the "source" rather than merely a cross-reference.
static void jl_insert_into_serialization_queue(jl_serializer_state *s, jl_value_t *v, int recursive, int immediate) JL_GC_DISABLED
{
    jl_value_t *dump_walking = reactive_dump_walking;
    if (reactive_dump_on)
        reactive_dump_walking = v;
    jl_datatype_t *t = (jl_datatype_t*)jl_typeof(v);
    jl_queue_for_serialization_(s, (jl_value_t*)t, 1, immediate);
    const jl_datatype_layout_t *layout = t->layout;

    if (!recursive)
        goto done_fields;

    if (s->incremental && jl_is_datatype(v) && immediate) {
        jl_datatype_t *dt = (jl_datatype_t*)v;
        // ensure all type parameters are recached
        jl_queue_for_serialization_(s, (jl_value_t*)dt->parameters, 1, 1);
        if (jl_is_datatype_singleton(dt) && needs_uniquing(dt->instance, s->query_cache)) {
            assert(jl_needs_serialization(s, dt->instance)); // should be true, since we visited dt
            // do not visit dt->instance for our template object as it leads to unwanted cycles here
            // (it may get serialized from elsewhere though)
            record_field_change(&dt->instance, jl_nothing);
        }
        goto done_fields; // for now
    }
    if (jl_is_method_instance(v)) {
        jl_method_instance_t *mi = (jl_method_instance_t*)v;
        if (s->incremental) {
            jl_value_t *def = mi->def.value;
            if (needs_uniquing(v, s->query_cache)) {
                // we only need 3 specific fields of this (the rest are not used)
                jl_queue_for_serialization(s, mi->def.value);
                jl_queue_for_serialization(s, mi->specTypes);
                jl_queue_for_serialization(s, (jl_value_t*)mi->sparam_vals);
                goto done_fields;
            }
            else if (jl_is_method(def) && jl_object_in_image(def)) {
                // we only need 3 specific fields of this (the rest are restored afterward, if valid)
                // in particular, cache is repopulated by jl_mi_cache_insert for all foreign function,
                // so must not be present here
                record_field_change((jl_value_t**)&mi->cache, NULL);
            }
            else {
                assert(!needs_recaching(v, s->query_cache));
            }
            // Any back-edges will be re-validated and added by staticdata.jl, so
            // drop them from the image here
            record_field_change((jl_value_t**)&mi->backedges, NULL);
            // n.b. opaque closures cannot be inspected and relied upon like a
            // normal method since they can get improperly introduced by generated
            // functions, so if they appeared at all, we will probably serialize
            // them wrong and segfault. The jl_code_for_staged function should
            // prevent this from happening, so we do not need to detect that user
            // error now.
        }
        else if (reactive_prune_heap) {
            jl_code_instance_t *head = jl_atomic_load_relaxed(&mi->cache);
            jl_code_instance_t *live = reactive_live_ci(head);
            if (live != head)
                record_field_change((jl_value_t**)&mi->cache, (jl_value_t*)live);
        }
        // don't recurse into all backedges memory (yet)
        jl_value_t *backedges = get_replaceable_field((jl_value_t**)&mi->backedges, 1);
        if (backedges) {
            assert(!jl_options.trim && !jl_options.strip_ir);
            jl_queue_for_serialization_(s, (jl_value_t*)((jl_array_t*)backedges)->ref.mem, 0, 1);
            size_t i = 0, n = jl_array_nrows(backedges);
            while (i < n) {
                jl_value_t *invokeTypes;
                jl_code_instance_t *caller;
                i = get_next_edge((jl_array_t*)backedges, i, &invokeTypes, &caller);
                if (invokeTypes)
                    jl_queue_for_serialization(s, invokeTypes);
            }
        }
    }
    if (jl_is_binding(v)) {
        jl_binding_t *b = (jl_binding_t*)v;
        if (s->incremental && needs_uniquing(v, s->query_cache)) {
            jl_queue_for_serialization(s, b->globalref->mod);
            jl_queue_for_serialization(s, b->globalref->name);
            goto done_fields;
        }
        if (jl_options.trim || jl_options.strip_ir) {
            record_field_change((jl_value_t**)&b->backedges, NULL);
        }
        else {
            // don't recurse into all backedges memory (yet)
            jl_value_t *backedges = get_replaceable_field((jl_value_t**)&b->backedges, 1);
            if (backedges) {
                jl_queue_for_serialization_(s, (jl_value_t*)((jl_array_t*)backedges)->ref.mem, 0, 1);
                for (size_t i = 0, n = jl_array_nrows(backedges); i < n; i++) {
                    jl_value_t *b = jl_array_ptr_ref(backedges, i);
                    if (!jl_is_code_instance(b) && !jl_is_method_instance(b) && !jl_is_method(b)) // otherwise usually a Binding?
                        jl_queue_for_serialization(s, b);
                }
            }
        }
    }
    if (s->incremental && jl_is_globalref(v)) {
        jl_globalref_t *gr = (jl_globalref_t*)v;
        if (jl_object_in_image((jl_value_t*)gr->mod)) {
            record_field_change((jl_value_t**)&gr->binding, NULL);
        }
    }
    if (jl_is_typename(v)) {
        jl_typename_t *tn = (jl_typename_t*)v;
        // don't recurse into several fields (yet)
        jl_queue_for_serialization_(s, (jl_value_t*)jl_atomic_load_relaxed(&tn->cache), 0, 1);
        jl_queue_for_serialization_(s, (jl_value_t*)jl_atomic_load_relaxed(&tn->linearcache), 0, 1);
        if (s->incremental) {
            assert(!jl_object_in_image((jl_value_t*)tn->module));
            assert(!jl_object_in_image((jl_value_t*)tn->wrapper));
        }
    }
    if (jl_is_mtable(v)) {
        jl_methtable_t *mt = (jl_methtable_t*)v;
        // Any back-edges will be re-validated and added by staticdata.jl, so
        // drop them from the image here
        if (s->incremental || jl_options.trim || jl_options.strip_ir) {
            record_field_change((jl_value_t**)&mt->backedges, jl_an_empty_memory_any);
        }
        else {
            // don't recurse into all backedges memory (yet)
            jl_value_t *allbackedges = get_replaceable_field((jl_value_t**)&mt->backedges, 1);
            jl_queue_for_serialization_(s, allbackedges, 0, 1);
            for (size_t i = 0, n = ((jl_genericmemory_t*)allbackedges)->length; i < n; i += 2) {
                jl_value_t *tn = jl_genericmemory_ptr_ref(allbackedges, i);
                jl_queue_for_serialization(s, tn);
                jl_value_t *backedges = jl_genericmemory_ptr_ref(allbackedges, i + 1);
                if (backedges && backedges != jl_nothing) {
                    jl_queue_for_serialization_(s, (jl_value_t*)((jl_array_t*)backedges)->ref.mem, 0, 1);
                    jl_queue_for_serialization(s, backedges);
                    for (size_t i = 0, n = jl_array_nrows(backedges); i < n; i += 2) {
                        jl_value_t *t = jl_array_ptr_ref(backedges, i);
                        assert(!jl_is_code_instance(t));
                        jl_queue_for_serialization(s, t);
                    }
                }
            }
        }
    }
    if (jl_is_code_instance(v)) {
        jl_code_instance_t *ci = (jl_code_instance_t*)v;
        jl_method_instance_t *mi = jl_get_ci_mi(ci);
        if (s->incremental) {
            // make sure we don't serialize other reachable cache entries of foreign methods
            // Should this now be:
            // if (ci !in ci->defs->cache)
            //     record_field_change((jl_value_t**)&ci->next, NULL);
            // Why are we checking that the method/module this originates from is in_image?
            // and then disconnect this CI?
            if (jl_object_in_image((jl_value_t*)mi->def.value)) {
                // TODO: if (ci in ci->defs->cache)
                record_field_change((jl_value_t**)&ci->next, NULL);
            }
        }
        else if (reactive_prune_heap) {
            jl_code_instance_t *next = jl_atomic_load_relaxed(&ci->next);
            jl_code_instance_t *live = reactive_live_ci(next);
            if (live != next)
                record_field_change((jl_value_t**)&ci->next, (jl_value_t*)live);
        }
        jl_value_t *inferred = jl_atomic_load_relaxed(&ci->inferred);
        if (inferred && inferred != jl_nothing && !jl_is_uint8(inferred)) { // disregard if there is nothing here to delete (e.g. builtins, unspecialized)
            jl_method_t *def = mi->def.method;
            if (jl_is_method(def)) { // don't delete toplevel code
                int is_relocatable = !s->incremental || jl_is_code_info(inferred) ||
                    (jl_is_string(inferred) && jl_string_len(inferred) > 0 && jl_string_data(inferred)[jl_string_len(inferred) - 1]);
                int may_discard_trees = !jl_get_type_infer_preserve_ir();
                int discard = 0;
                if (may_discard_trees && s->incremental && native_functions &&
                    jl_options.outputo != NULL && ci->owner == jl_nothing && def->source != NULL &&
                    jl_is_code_info(inferred) && jl_ir_inlining_cost(inferred) == UINT16_MAX) {
                    // Backstop: CodeInstance cached by a task racing the end of
                    // include phase can escape jl_finalize_precompile_inferred.
                    // Mirror the def->source guard below so optimized opaque
                    // closures (whose IR can't be reconstructed) are preserved.
                    record_field_change((jl_value_t**)&ci->inferred, jl_nothing);
                }
                else if (!is_relocatable) {
                    discard = 1;
                }
                else if (def->source == NULL) {
                    // don't delete code from optimized opaque closures that can't be reconstructed (and builtins)
                }
                else if (may_discard_trees && // if allowed to delete
                         (!codeinst_may_be_runnable(ci, s->incremental) || // delete all code that cannot run
                          jl_atomic_load_relaxed(&ci->invoke) == jl_fptr_const_return)) { // delete all code that just returns a constant
                    discard = 1;
                }
                else if (may_discard_trees &&
                         native_functions && // don't delete any code if making a ji file
                         (ci->owner == jl_nothing) && // don't delete code for external interpreters
                         !effects_foldable(jl_atomic_load_relaxed(&ci->ipo_purity_bits)) && // don't delete code we may want for irinterp
                         jl_ir_inlining_cost(inferred) == UINT16_MAX) { // don't delete inlineable code
                    // delete the code now: if we thought it was worth keeping, it would have been converted to object code
                    discard = 1;
                }
                if (discard) {
                    // keep only the inlining cost, so inference can later decide if it is worth getting the source back
                    if (jl_is_string(inferred) || jl_is_code_info(inferred))
                        inferred = jl_box_uint8(jl_encode_inlining_cost(jl_ir_inlining_cost(inferred)));
                    else
                        inferred = jl_nothing;
                    record_field_change((jl_value_t**)&ci->inferred, inferred);
                }
                else if (s->incremental && jl_is_string(inferred)) {
                    // New roots for external methods
                    if (jl_object_in_image((jl_value_t*)def)) {
                        void **pfound = ptrhash_bp(&s->method_roots_index, def);
                        if (*pfound == HT_NOTFOUND) {
                            *pfound = def;
                            size_t nwithkey = nroots_with_key(def, s->worklist_key);
                            if (nwithkey) {
                                jl_array_ptr_1d_push(s->method_roots_list, (jl_value_t*)def);
                                jl_array_t *newroots = jl_alloc_vec_any(nwithkey);
                                jl_array_ptr_1d_push(s->method_roots_list, (jl_value_t*)newroots);
                                rle_iter_state rootiter = rle_iter_init(0);
                                uint64_t *rletable = NULL;
                                size_t nblocks2 = 0;
                                size_t nroots = jl_array_nrows(def->roots);
                                size_t k = 0;
                                if (def->root_blocks) {
                                    rletable = jl_array_data(def->root_blocks, uint64_t);
                                    nblocks2 = jl_array_nrows(def->root_blocks);
                                }
                                while (rle_iter_increment(&rootiter, nroots, rletable, nblocks2)) {
                                    if (rootiter.key == s->worklist_key) {
                                        jl_value_t *newroot = jl_array_ptr_ref(def->roots, rootiter.i);
                                        jl_queue_for_serialization(s, newroot);
                                        jl_array_ptr_set(newroots, k++, newroot);
                                    }
                                }
                                assert(k == nwithkey);
                            }
                        }
                    }
                }
            }
        }
    }

    if (immediate) // must be things that can be recursively handled, and valid as type parameters
        assert(jl_is_immutable(t) || jl_is_typevar(v) || jl_is_symbol(v) || jl_is_svec(v));

    if (layout->npointers == 0) {
        // bitstypes do not require recursion
    }
    else if (jl_is_svec(v)) {
        size_t i, l = jl_svec_len(v);
        jl_value_t **data = jl_svec_data(v);
        for (i = 0; i < l; i++) {
            jl_queue_for_serialization_(s, data[i], 1, immediate);
        }
    }
    else if (jl_is_array(v)) {
        jl_array_t *ar = (jl_array_t*)v;
        jl_value_t *mem = get_replaceable_field((jl_value_t**)&ar->ref.mem, 1);
        jl_queue_for_serialization_(s, mem, 1, immediate);
    }
    else if (jl_is_genericmemory(v)) {
        jl_genericmemory_t *m = (jl_genericmemory_t*)v;
        const char *data = (const char*)m->ptr;
        if (jl_genericmemory_how(m) == JL_GENERICMEMORY_STRINGOWNED) {
            assert(jl_is_string(jl_genericmemory_data_owner_field(m)));
        }
        else if (layout->flags.arrayelem_isboxed) {
            size_t i, l = m->length;
            for (i = 0; i < l; i++) {
                jl_value_t *fld = get_replaceable_field(&((jl_value_t**)data)[i], 1);
                jl_queue_for_serialization_(s, fld, 1, immediate);
            }
        }
        else if (layout->first_ptr >= 0) {
            uint16_t elsz = layout->size;
            size_t i, l = m->length;
            size_t j, np = layout->npointers;
            for (i = 0; i < l; i++) {
                for (j = 0; j < np; j++) {
                    uint32_t ptr = jl_ptr_offset(t, j);
                    jl_value_t *fld = get_replaceable_field(&((jl_value_t**)data)[ptr], 1);
                    jl_queue_for_serialization_(s, fld, 1, immediate);
                }
                data += elsz;
            }
        }
    }
    else if (jl_is_module(v)) {
        jl_queue_module_for_serialization(s, (jl_module_t*)v);
    }
    else if (layout->nfields > 0) {
        if (jl_options.trim) {
            if (jl_is_method(v)) {
                jl_method_t *m = (jl_method_t *)v;
                if (jl_is_svec(jl_atomic_load_relaxed(&m->specializations)))
                    jl_queue_for_serialization_(s, (jl_value_t*)jl_atomic_load_relaxed(&m->specializations), 0, 1);
            }
            else if (jl_is_mtable(v)) {
                jl_methtable_t *mt = (jl_methtable_t*)v;
                jl_methtable_t *newmt = (jl_methtable_t*)ptrhash_get(&new_methtables, mt);
                if (newmt != HT_NOTFOUND)
                    record_field_change((jl_value_t **)&mt->defs, (jl_value_t*)jl_atomic_load_relaxed(&newmt->defs));
                else
                    record_field_change((jl_value_t **)&mt->defs, jl_nothing);
            }
            else if (jl_is_mcache(v)) {
                jl_methcache_t *mc = (jl_methcache_t*)v;
                jl_value_t *cache = jl_atomic_load_relaxed(&mc->cache);
                if (!jl_typetagis(cache, jl_typemap_entry_type) || ((jl_typemap_entry_t*)cache)->sig != jl_tuple_type) { // aka Builtins (maybe sometimes OpaqueClosure too)
                    record_field_change((jl_value_t **)&mc->cache, jl_nothing);
                }
                record_field_change((jl_value_t **)&mc->leafcache, jl_an_empty_memory_any);
            }
            // TODO: prune any partitions and partition data that has been deleted in the current world
            //else if (jl_is_binding(v)) {
            //    jl_binding_t *b = (jl_binding_t*)v;
            //}
            //else if (jl_is_binding_partition(v)) {
            //    jl_binding_partition_t *bpart = (jl_binding_partition_t*)v;
            //}
        }
        if (reactive_prune_heap && jl_is_method(v)) {
            // The interference set of a method is weak in a reactive image:
            // an insertion adds the new method to the set of every method it
            // intersects, a deleted one included, and nothing removes a
            // member. A strong set would keep a deleted method in the image
            // with its specializations and their code (reactive_prune_interferences).
            jl_method_t *m = (jl_method_t*)v;
            jl_queue_for_serialization_(s, (jl_value_t*)jl_atomic_load_relaxed(&m->interferences), 0, 1);
        }
        char *data = (char*)jl_data_ptr(v);
        size_t i, np = layout->npointers;
        size_t fldidx = 1;
        for (i = 0; i < np; i++) {
            uint32_t ptr = jl_ptr_offset(t, i);
            size_t offset = jl_ptr_offset(t, i) * sizeof(jl_value_t*);
            while (offset >= (fldidx == layout->nfields ? jl_datatype_size(t) : jl_field_offset(t, fldidx)))
                fldidx++;
            int mutabl = !jl_field_isconst(t, fldidx - 1);
            jl_value_t *fld = get_replaceable_field(&((jl_value_t**)data)[ptr], mutabl);
            jl_queue_for_serialization_(s, fld, 1, immediate);
        }
    }

done_fields: ;

    // We've encountered an item we need to cache
    void **bp = ptrhash_bp(&serialization_order, v);
    assert(*bp == (void*)(uintptr_t)-2);
    arraylist_push(&serialization_queue, (void*) v);
    size_t idx = serialization_queue.len - 1;
    assert(serialization_queue.len < ((uintptr_t)1 << RELOC_TAG_OFFSET) && "too many items to serialize");
    *bp = to_seroder_entry(idx);

    // DataType is very unusual, in that some of the fields need to be pre-order, and some
    // (notably super) must not be (even if `jl_queue_for_serialization_` would otherwise
    // try to promote itself to be immediate)
    if (s->incremental && jl_is_datatype(v) && immediate && recursive) {
        jl_datatype_t *dt = (jl_datatype_t*)v;
        // do not handle the super field now: the supertype's parameters can reach back to
        // objects that are still on the recursion stack (e.g. `struct Baz{T} <: Bar{Foo{Baz{T}}} end`),
        // which would order the supertype before its own parameters in the queue. Defer it
        // until the recursion unwinds; any forward reference this creates in the image is
        // handled at load time by the uniquing_super/delay_list machinery.
        if (jl_needs_serialization(s, (jl_value_t*)dt->super))
            arraylist_push(&deferred_supers, (void*)dt->super);
        immediate = 0;
        char *data = (char*)jl_data_ptr(v);
        size_t i, np = layout->npointers;
        for (i = 0; i < np; i++) {
            uint32_t ptr = jl_ptr_offset(t, i);
            if (ptr * sizeof(jl_value_t*) == offsetof(jl_datatype_t, super))
                continue; // skip the super field, since it might not be quite validly ordered
            int mutabl = 1;
            jl_value_t *fld = get_replaceable_field(&((jl_value_t**)data)[ptr], mutabl);
            jl_queue_for_serialization_(s, fld, 1, immediate);
        }
    }
    reactive_dump_walking = dump_walking;
}


static void jl_queue_for_serialization_(jl_serializer_state *s, jl_value_t *v, int recursive, int immediate) JL_GC_DISABLED
{
    if (!jl_needs_serialization(s, v))
        return;

    jl_datatype_t *t = (jl_datatype_t*)jl_typeof(v);
    // check early from errors, so we have a little bit of contextual state for debugging them
    if (t == jl_task_type) {
        jl_error("Task cannot be serialized");
    }
    if (s->incremental && needs_uniquing(v, s->query_cache) && t == jl_binding_type) {
        jl_binding_t *b = (jl_binding_t*)v;
        if (b->globalref == NULL)
            jl_error("Binding cannot be serialized"); // no way (currently) to recover its identity
    }
    if (jl_is_foreign_type(t) == 1) {
        jl_error("Cannot serialize instances of foreign datatypes");
    }

    // Items that require postorder traversal must visit their children prior to insertion into
    // the worklist/serialization_order (and also before their first use)
    if (s->incremental && !immediate) {
        if (jl_is_datatype(t) && needs_uniquing(v, s->query_cache))
            immediate = 1;
        if (jl_is_datatype_singleton((jl_datatype_t*)t) && needs_uniquing(v, s->query_cache))
            immediate = 1;
    }

    void **bp = ptrhash_bp(&serialization_order, v);
    assert(!immediate || *bp != (void*)(uintptr_t)-2);
    if (*bp == HT_NOTFOUND) {
        *bp = (void*)(uintptr_t)-1; // now enqueued
        if (reactive_dump_on)
            ptrhash_put(&reactive_dump_parents, v, reactive_dump_walking ? reactive_dump_walking : jl_nothing);
    }
    else if (!s->incremental || !immediate || !recursive || *bp != (void*)(uintptr_t)-1)
        return;

    if (immediate) {
        *bp = (void*)(uintptr_t)-2; // now immediate
        jl_insert_into_serialization_queue(s, v, recursive, immediate);
    }
    else {
        arraylist_push(&object_worklist, (void*)v);
    }
}

// Do a pre-order traversal of the to-serialize worklist, in the identical order
// to the calls to jl_queue_for_serialization would occur in a purely recursive
// implementation, but without potentially running out of stack.
static void jl_serialize_reachable(jl_serializer_state *s) JL_GC_DISABLED
{
    size_t i, prevlen = 0;
    while (1) {
        // handle deferred super fields now: the recursion stack is unwound here, so
        // everything reachable through their parameters is already validly ordered
        while (deferred_supers.len) {
            jl_value_t *super = (jl_value_t*)deferred_supers.items[--deferred_supers.len];
            jl_queue_for_serialization_(s, super, 1, 1);
        }
        if (object_worklist.len == 0)
            break;
        // reverse!(object_worklist.items, prevlen:end);
        // prevlen is the index of the first new object
        for (i = prevlen; i < object_worklist.len; i++) {
            size_t j = object_worklist.len - i + prevlen - 1;
            void *tmp = object_worklist.items[i];
            object_worklist.items[i] = object_worklist.items[j];
            object_worklist.items[j] = tmp;
        }
        prevlen = --object_worklist.len;
        jl_value_t *v = (jl_value_t*)object_worklist.items[prevlen];
        void **bp = ptrhash_bp(&serialization_order, (void*)v);
        assert(*bp != HT_NOTFOUND && *bp != (void*)(uintptr_t)-2);
        if (*bp == (void*)(uintptr_t)-1) { // might have been eagerly handled for post-order while in the lazy pre-order queue
            *bp = (void*)(uintptr_t)-2;
            jl_insert_into_serialization_queue(s, v, 1, 0);
        }
        else {
            assert(s->incremental);
        }
    }
}

static void ios_ensureroom(ios_t *s, size_t newsize) JL_NOTSAFEPOINT
{
    size_t prevsize = s->size;
    if (prevsize < newsize) {
        ios_trunc(s, newsize);
        assert(s->size == newsize);
        memset(&s->buf[prevsize], 0, newsize - prevsize);
    }
}

static void write_padding(ios_t *s, size_t nb) JL_NOTSAFEPOINT
{
    static const char zeros[16] = {0};
    while (nb > 16) {
        ios_write(s, zeros, 16);
        nb -= 16;
    }
    if (nb != 0)
        ios_write(s, zeros, nb);
}

static void write_pointer(ios_t *s) JL_NOTSAFEPOINT
{
    assert((ios_pos(s) & (sizeof(void*) - 1)) == 0 && "stream misaligned for writing a word-sized value");
    write_uint(s, 0);
}

// Records the buildid holding `v` and returns the tagged offset within the corresponding image
static uintptr_t add_external_linkage(jl_serializer_state *s, jl_value_t *v, jl_array_t *link_ids) JL_GC_DISABLED
{
    size_t i = external_blob_index(v);
    if (i < n_linkage_blobs()) {
        // We found the sysimg/pkg that this item links against
        // Compute the relocation code
        size_t offset = (uintptr_t)v - (uintptr_t)jl_linkage_blobs.items[2*i];
        assert((offset % SYS_EXTERNAL_LINK_UNIT) == 0);
        offset /= SYS_EXTERNAL_LINK_UNIT;
        assert(n_linkage_blobs() == jl_array_nrows(s->buildid_depmods_idxs));
        size_t depsidx = jl_array_data(s->buildid_depmods_idxs, uint32_t)[i]; // map from build_id_idx -> deps_idx
        assert(depsidx < INT32_MAX);
        if (depsidx < ((uintptr_t)1 << (RELOC_TAG_OFFSET - DEPS_IDX_OFFSET)) && offset < ((uintptr_t)1 << DEPS_IDX_OFFSET))
            // if it fits in a SysimageLinkage type, use that representation
            return ((uintptr_t)SysimageLinkage << RELOC_TAG_OFFSET) + ((uintptr_t)depsidx << DEPS_IDX_OFFSET) + offset;
        // otherwise, we store the image key in `link_ids`
        assert(link_ids && jl_is_array(link_ids));
        jl_array_grow_end(link_ids, 1);
        uint32_t *link_id_data  = jl_array_data(link_ids, uint32_t);  // wait until after the `grow`
        link_id_data[jl_array_nrows(link_ids) - 1] = depsidx;
        assert(offset < ((uintptr_t)1 << RELOC_TAG_OFFSET) && "offset to external image too large");
        return ((uintptr_t)ExternalLinkage << RELOC_TAG_OFFSET) + offset;
    }
    return 0;
}

// The reference to an object of the base that the page write did not
// queue: its offset in the base, with the tag BaseRef for the sysimg section
// (the finish makes it a DataRef) and ConstDataRef for the const data.
static uintptr_t reactive_pages_base_ref(jl_value_t *v) JL_NOTSAFEPOINT
{
    if (reactive_in_sysimg(v))
        return ((uintptr_t)BaseRef << RELOC_TAG_OFFSET) + ((const char*)v - reactive_image_base);
    if (reactive_in_const(v)) {
        size_t off = (const char*)v - reactive_const_base;
        assert(off % sizeof(void*) == 0);
        return ((uintptr_t)ConstDataRef << RELOC_TAG_OFFSET) + off / sizeof(void*);
    }
    jl_safe_printf("reactive: pages: an object of the image lies outside the base sections\n");
    abort();
}

// Return the integer `id` for `v`. Generically this is looked up in `serialization_order`,
// but symbols, small integers, and a couple of special items (`nothing` and the root Task)
// have special handling.
#define backref_id(s, v, link_ids) _backref_id(s, (jl_value_t*)(v), link_ids)
static uintptr_t _backref_id(jl_serializer_state *s, jl_value_t *v, jl_array_t *link_ids) JL_GC_DISABLED
{
    assert(v != NULL && "cannot get backref to NULL object");
    if (jl_is_symbol(v)) {
        void **pidx = ptrhash_bp(&symbol_table, v);
        void *idx = *pidx;
        if (idx == HT_NOTFOUND) {
            size_t l = strlen(jl_symbol_name((jl_sym_t*)v));
            write_uint32(s->symbols, l);
            ios_write(s->symbols, jl_symbol_name((jl_sym_t*)v), l + 1);
            size_t offset = ++nsym_tag;
            assert(offset < ((uintptr_t)1 << RELOC_TAG_OFFSET) && "too many symbols");
            idx = to_seroder_entry(offset - 1);
            *pidx = idx;
        }
        return ((uintptr_t)SymbolRef << RELOC_TAG_OFFSET) + from_seroder_entry(idx);
    }
    else if (v == (jl_value_t*)s->ptls->root_task) {
        return (uintptr_t)TagRef << RELOC_TAG_OFFSET;
    }
    else if (v == jl_nothing) {
        return ((uintptr_t)TagRef << RELOC_TAG_OFFSET) + 1;
    }
    else if (jl_typetagis(v, jl_int64_tag << 4)) {
        int64_t i64 = *(int64_t*)v + NBOX_C / 2;
        if ((uint64_t)i64 < NBOX_C)
            return ((uintptr_t)TagRef << RELOC_TAG_OFFSET) + i64 + 2;
    }
    else if (jl_typetagis(v, jl_int32_tag << 4)) {
        int32_t i32 = *(int32_t*)v + NBOX_C / 2;
        if ((uint32_t)i32 < NBOX_C)
            return ((uintptr_t)TagRef << RELOC_TAG_OFFSET) + i32 + 2 + NBOX_C;
    }
    else if (jl_typetagis(v, jl_uint8_tag << 4)) {
        uint8_t u8 = *(uint8_t*)v;
        return ((uintptr_t)TagRef << RELOC_TAG_OFFSET) + u8 + 2 + NBOX_C + NBOX_C;
    }
    if (s->incremental && jl_object_in_image(v)) {
        assert(link_ids);
        uintptr_t item = add_external_linkage(s, v, link_ids);
        assert(item && "no external linkage identified");
        return item;
    }
    void *idx = ptrhash_get(&serialization_order, v);
    if (idx == HT_NOTFOUND && reactive_pages_on && jl_object_in_image(v))
        return reactive_pages_base_ref(v);
    if (idx == HT_NOTFOUND) {
        jl_(jl_typeof(v));
        jl_(v);
    }
    assert(idx != HT_NOTFOUND && "object missed during jl_queue_for_serialization pass");
    assert(idx != (void*)(uintptr_t)-1 && "object missed during jl_insert_into_serialization_queue pass");
    assert(idx != (void*)(uintptr_t)-2 && "object missed during jl_insert_into_serialization_queue pass");
    return ((uintptr_t)DataRef << RELOC_TAG_OFFSET) + from_seroder_entry(idx);
}


static void record_uniquing(jl_serializer_state *s, jl_value_t *fld, uintptr_t offset) JL_NOTSAFEPOINT
{
    if (s->incremental && jl_needs_serialization(s, fld) && needs_uniquing(fld, s->query_cache)) {
        if (jl_is_datatype(fld) || jl_is_datatype_singleton((jl_datatype_t*)jl_typeof(fld)))
            arraylist_push(&s->uniquing_types, (void*)(uintptr_t)offset);
        else if (jl_is_method_instance(fld) || jl_is_binding(fld))
            arraylist_push(&s->uniquing_objs, (void*)(uintptr_t)offset);
        else
            assert(0 && "unknown object type with needs_uniquing set");
    }
}

// Save blank space in stream `s` for a pointer `fld`, storing both location and target
// in `relocs_list`.
static void write_pointerfield(jl_serializer_state *s, jl_value_t *fld) JL_NOTSAFEPOINT
{
    if (fld != NULL) {
        arraylist_push(&s->relocs_list, (void*)(uintptr_t)ios_pos(s->s));
        arraylist_push(&s->relocs_list, (void*)backref_id(s, fld, s->link_ids_relocs));
        record_uniquing(s, fld, ios_pos(s->s));
    }
    write_pointer(s->s);
}

// Save blank space in stream `s` for a pointer `fld`, storing both location and target
// in `gctags_list`.
static void write_gctaggedfield(jl_serializer_state *s, jl_datatype_t *ref) JL_NOTSAFEPOINT
{
    // jl_printf(JL_STDOUT, "gctaggedfield: position %p, value 0x%lx\n", (void*)(uintptr_t)ios_pos(s->s), ref);
    arraylist_push(&s->gctags_list, (void*)(uintptr_t)ios_pos(s->s));
    arraylist_push(&s->gctags_list, (void*)backref_id(s, ref, s->link_ids_gctags));
    write_pointer(s->s);
}


// Special handling from `jl_write_values` for modules
static void jl_write_module(jl_serializer_state *s, uintptr_t item, jl_module_t *m) JL_GC_DISABLED
{
    size_t reloc_offset = ios_pos(s->s);
    size_t tot = sizeof(jl_module_t);
    ios_write(s->s, (char*)m, tot);     // raw memory dump of the `jl_module_t` structure
    // will need to recreate the binding table for this
    arraylist_push(&s->fixup_objs, (void*)reloc_offset);

    // Handle the fields requiring special attention
    jl_module_t *newm = (jl_module_t*)&s->s->buf[reloc_offset];
    newm->name = NULL;
    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, name)));
    arraylist_push(&s->relocs_list, (void*)backref_id(s, m->name, s->link_ids_relocs));
    newm->parent = NULL;
    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, parent)));
    arraylist_push(&s->relocs_list, (void*)backref_id(s, m->parent, s->link_ids_relocs));
    jl_atomic_store_relaxed(&newm->bindings, NULL);
    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, bindings)));
    arraylist_push(&s->relocs_list, (void*)backref_id(s, jl_atomic_load_relaxed(&m->bindings), s->link_ids_relocs));
    jl_atomic_store_relaxed(&newm->bindingkeyset, NULL);
    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, bindingkeyset)));
    arraylist_push(&s->relocs_list, (void*)backref_id(s, jl_atomic_load_relaxed(&m->bindingkeyset), s->link_ids_relocs));
    newm->file = NULL;
    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, file)));
    arraylist_push(&s->relocs_list, (void*)backref_id(s, jl_options.strip_metadata ? jl_empty_sym : m->file , s->link_ids_relocs));
    if (jl_options.strip_metadata)
        newm->line = 0;
    newm->usings_backedges = NULL;
    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, usings_backedges)));
    arraylist_push(&s->relocs_list, (void*)backref_id(s, get_replaceable_field(&m->usings_backedges, 1), s->link_ids_relocs));
    newm->scanned_methods = NULL;
    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, scanned_methods)));
    arraylist_push(&s->relocs_list, (void*)backref_id(s, get_replaceable_field(&m->scanned_methods, 1), s->link_ids_relocs));

    // After reload, everything that has happened in this process happened semantically at
    // (for .incremental) or before jl_require_world, so reset this flag.
    jl_atomic_store_relaxed(&newm->export_set_changed_since_require_world, 0);

    // write out the usings list
    memset(&newm->usings._space, 0, sizeof(newm->usings._space));
    if (m->usings.items == &m->usings._space[0]) {
        newm->usings.items = &newm->usings._space[0];
        // Push these relocations here, to keep them in order. This pairs with the `newm->usings.items = ` below.
        arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, usings.items)));
        arraylist_push(&s->relocs_list, (void*)(((uintptr_t)DataRef << RELOC_TAG_OFFSET) + item));
        size_t i;
        for (i = 0; i < module_usings_length(m); i++) {
            struct _jl_module_using *newm_data = module_usings_getidx(newm, i);
            struct _jl_module_using *data = module_usings_getidx(m, i);
            // TODO: Remove dead entries
            newm_data->min_world = data->min_world;
            newm_data->max_world = data->max_world;
            if (s->incremental) {
                if (data->max_world != ~(size_t)0)
                    newm_data->max_world = 0;
                newm_data->min_world = jl_require_world;
            }
            arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, usings._space[3*i])));
            arraylist_push(&s->relocs_list, (void*)backref_id(s, data->mod, s->link_ids_relocs));
        }
        newm->usings.items = (void**)offsetof(jl_module_t, usings._space);
    }
    else {
        newm->usings.items = (void**)tot;
        arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_module_t, usings.items)));
        arraylist_push(&s->relocs_list, (void*)(((uintptr_t)DataRef << RELOC_TAG_OFFSET) + item));
        newm = NULL; // `write_*(s->s)` below may invalidate `newm`, so defensively set it to NULL
        size_t i;
        for (i = 0; i < module_usings_length(m); i++) {
            struct _jl_module_using *data = module_usings_getidx(m, i);
            write_pointerfield(s, (jl_value_t*)data->mod);
            if (s->incremental) {
                // TODO: Drop dead ones entirely?
                write_uint(s->s, jl_require_world);
                write_uint(s->s, data->max_world == ~(size_t)0 ? ~(size_t)0 : 1);
            } else {
                write_uint(s->s, data->min_world);
                write_uint(s->s, data->max_world);
            }
            static_assert(sizeof(struct _jl_module_using) == 3*sizeof(void*), "_jl_module_using mismatch");
            tot += sizeof(struct _jl_module_using);
        }
        for (; i < module_usings_max(m); i++) {
            write_pointer(s->s);
            write_uint(s->s, 0);
            write_uint(s->s, 0);
            tot += sizeof(struct _jl_module_using);
        }
    }
    assert(ios_pos(s->s) - reloc_offset == tot);
}

static void record_memoryref(jl_serializer_state *s, size_t reloc_offset, jl_genericmemoryref_t ref) {
    ios_t *f = s->s;
    // make some header modifications in-place
    jl_genericmemoryref_t *newref = (jl_genericmemoryref_t*)&f->buf[reloc_offset];
    const jl_datatype_layout_t *layout = ((jl_datatype_t*)jl_typetagof(ref.mem))->layout;
    if (!layout->flags.arrayelem_isunion && layout->size != 0) {
        newref->ptr_or_offset = (void*)((char*)ref.ptr_or_offset - (char*)ref.mem->ptr); // relocation offset (bytes)
        arraylist_push(&s->memref_list, (void*)reloc_offset); // relocation location
        arraylist_push(&s->memref_list, NULL); // relocation target (ignored)
    }
}

static void record_memoryrefs_inside(jl_serializer_state *s, jl_datatype_t *t, size_t reloc_offset, const char *data)
{
    assert(jl_is_datatype(t));
    size_t i, nf = jl_datatype_nfields(t);
    for (i = 0; i < nf; i++) {
        size_t offset = jl_field_offset(t, i);
        if (jl_field_isptr(t, i))
            continue;
        jl_value_t *ft = jl_field_type_concrete(t, i);
        if (jl_is_uniontype(ft))
            continue;
        if (jl_is_genericmemoryref_type(ft))
            record_memoryref(s, reloc_offset + offset, *(jl_genericmemoryref_t*)(data + offset));
        else
            record_memoryrefs_inside(s, (jl_datatype_t*)ft, reloc_offset + offset, data + offset);
    }
}

static void record_gvars(jl_serializer_state *s, arraylist_t *globals) JL_GC_DISABLED
{
    for (size_t i = 0; i < globals->len; i++)
        jl_queue_for_serialization(s, globals->items[i]);
}

static void record_external_fns(jl_serializer_state *s, arraylist_t *external_fns) JL_NOTSAFEPOINT
{
    if (!s->incremental && !reactive_overlay_on) {
        assert(external_fns->len == 0);
        (void) external_fns;
        return;
    }

    // We could call jl_queue_for_serialization here, but that should
    // always be a no-op.
#ifndef JL_NDEBUG
    for (size_t i = 0; i < external_fns->len; i++) {
        jl_code_instance_t *ci = (jl_code_instance_t*)external_fns->items[i];
        assert(jl_atomic_load_relaxed(&ci->flags) & JL_CI_FLAGS_FROM_IMAGE);
    }
#endif
}

jl_value_t *jl_find_ptr = NULL;

static inline int reactive_object_id_expected(jl_datatype_t *t) JL_NOTSAFEPOINT
{
    return t->name->mutabl &&
           t != jl_datatype_type &&
           t != jl_typename_type &&
           t != jl_string_type &&
           t != jl_simplevector_type &&
           t != jl_module_type;
}

// The window the in-place write of the base object with the tag at `tag_pos`
// must end in: before the header of the next object, and after the padding
// that the writer puts in front of it.
static void reactive_pages_window(size_t tag_pos, size_t *lo, size_t *hi, size_t *index) JL_NOTSAFEPOINT
{
    arraylist_t *tags = &reactive_base.gctags;
    size_t i = reactive_base_object_at(tag_pos);
    assert((size_t)tags->items[i] == tag_pos);
    *index = i;
    size_t next = i + 1 < tags->len ? (size_t)tags->items[i + 1] : reactive_base.sysimg_size;
    size_t oid = 0;
    if (reactive_overlay_on && tag_pos < reactive_base_end && next > reactive_base_end) {
        // the last object of the base: the next tag lies past the const
        // headroom, in an overlay's objects
        next = reactive_base_end;
    }
    else if (i + 1 < tags->len) {
        jl_value_t *nv = (jl_value_t*)(reactive_image_base + next + sizeof(jl_taggedvalue_t));
        oid = reactive_object_id_expected((jl_datatype_t*)jl_typeof(nv)) ? sizeof(size_t) : 0;
    }
    *hi = next - oid;
    *lo = *hi - 16;
}

// The main function for serializing all the items queued in `serialization_order`
// (They are also stored in `serialization_queue` which is order-preserving, unlike the hash table used
//  for `serialization_order`).
static void jl_write_values(jl_serializer_state *s) JL_GC_DISABLED
{
    size_t l = serialization_queue.len;

    arraylist_new(&layout_table, 0);
    arraylist_grow(&layout_table, l * 2);
    memset(layout_table.items, 0, l * 2 * sizeof(void*));

    // Serialize all entries
    for (size_t item = 0; item < l; item++) {
        jl_value_t *v = (jl_value_t*)serialization_queue.items[item];           // the object
        JL_GC_PROMISE_ROOTED(v);
        assert(!(s->incremental && jl_object_in_image(v)));
        jl_datatype_t *t = (jl_datatype_t*)jl_typeof(v);
        assert((!jl_is_datatype_singleton(t) || t->instance == v) && "detected singleton construction corruption");
        int mutabl = t->name->mutabl;
        ios_t *f = s->s;
        if (t->smalltag) {
            if (t->layout->npointers == 0 || t == jl_string_type) {
                if (jl_datatype_nfields(t) == 0 || mutabl == 0 || t == jl_string_type) {
                    f = s->const_data;
                }
            }
        }

        uintptr_t object_id_expected = reactive_object_id_expected(t);
        // An object of the base of a page-written image is rewritten in
        // place: the stream seeks to its header in the base, and its end
        // must fall in the window before the next object.
        int in_place = 0;
        size_t in_place_lo = 0, in_place_hi = 0, in_place_index = 0;
        if (reactive_pages_on && jl_object_in_image(v)) {
            assert(f == s->s && reactive_in_sysimg(v));
            size_t data_off = (char*)v - reactive_image_base;
            size_t tag_pos = data_off - sizeof(jl_taggedvalue_t);
            reactive_pages_window(tag_pos, &in_place_lo, &in_place_hi, &in_place_index);
            ios_seek(f, tag_pos - (object_id_expected ? sizeof(size_t) : 0));
            in_place = 1;
        }
        // realign stream to expected gc alignment (16 bytes) after tag
        uintptr_t skip_header_pos = ios_pos(f) + sizeof(jl_taggedvalue_t);
        if (object_id_expected)
            skip_header_pos += sizeof(size_t);
        write_padding(f, LLT_ALIGN(skip_header_pos, 16) - skip_header_pos);

        // write header
        if (object_id_expected)
            write_uint(f, jl_object_id(v));
        if (s->incremental && jl_needs_serialization(s, (jl_value_t*)t) && needs_uniquing((jl_value_t*)t, s->query_cache))
            arraylist_push(&s->uniquing_types, (void*)(uintptr_t)(ios_pos(f)|1));
        if (f == s->const_data)
            write_uint(s->const_data, ((uintptr_t)t->smalltag << 4) | GC_OLD_MARKED | GC_IN_IMAGE);
        else
            write_gctaggedfield(s, t);
        size_t reloc_offset = ios_pos(f);
        assert(item < layout_table.len && layout_table.items[item] == NULL);
        layout_table.items[item] = (void*)(reloc_offset | (f == s->const_data)); // store the inverse mapping of `serialization_order` (`id` => object-as-streampos)

        if (s->incremental) {
            if (needs_uniquing(v, s->query_cache)) {
                if (jl_is_binding(v)) {
                    jl_binding_t *b = (jl_binding_t*)v;
                    write_pointerfield(s, (jl_value_t*)b->globalref->mod);
                    write_pointerfield(s, (jl_value_t*)b->globalref->name);
                    continue;
                }
                else if (jl_is_method_instance(v)) {
                    assert(f == s->s);
                    jl_method_instance_t *mi = (jl_method_instance_t*)v;
                    write_pointerfield(s, mi->def.value);
                    write_pointerfield(s, mi->specTypes);
                    write_pointerfield(s, (jl_value_t*)mi->sparam_vals);
                    continue;
                }
                else if (jl_is_datatype(v)) {
                    // iterate in reverse, so that the element swapped in from the back upon
                    // removal is always one we have already examined
                    for (size_t i = s->uniquing_super.len; i > 0; i--) {
                        if (s->uniquing_super.items[i - 1] == (void*)v) {
                            s->uniquing_super.items[i - 1] = arraylist_pop(&s->uniquing_super);
                            arraylist_push(&s->uniquing_types, (void*)(uintptr_t)(reloc_offset|3));
                        }
                    }
                }
                else {
                    assert(jl_is_datatype_singleton(t) && "unreachable");
                }
            }
            else if (needs_recaching(v, s->query_cache)) {
                arraylist_push(jl_is_datatype(v) ? &s->fixup_types : &s->fixup_objs, (void*)reloc_offset);
            }
        }

        // write data
        if (jl_is_array(v)) {
            assert(f == s->s);
            // Internal data for types in julia.h with `jl_array_t` field(s)
            jl_array_t *ar = (jl_array_t*)v;
            // copy header
            size_t headersize = sizeof(jl_array_t) + jl_array_ndims(ar)*sizeof(size_t);
            ios_write(f, (char*)v, headersize);
            // make some header modifications in-place
            jl_array_t *newa = (jl_array_t*)&f->buf[reloc_offset];
            newa->ref.mem = NULL; // relocation offset
            arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_array_t, ref.mem))); // relocation location
            jl_value_t *mem = get_replaceable_field((jl_value_t**)&ar->ref.mem, 1);
            arraylist_push(&s->relocs_list, (void*)backref_id(s, mem, s->link_ids_relocs)); // relocation target
            record_memoryref(s, reloc_offset + offsetof(jl_array_t, ref), ar->ref);
        }
        else if (jl_is_genericmemory(v)) {
            assert(f == s->s);
            // Internal data for types in julia.h with `jl_genericmemory_t` field(s)
            jl_genericmemory_t *m = (jl_genericmemory_t*)v;
            const jl_datatype_layout_t *layout = t->layout;
            size_t len = m->length;
            // if (jl_genericmemory_how(m) == JL_GENERICMEMORY_STRINGOWNED) {
            //     jl_value_t *owner = jl_genericmemory_data_owner_field(m);
            //     write_uint(f, len);
            //     write_pointerfield(s, owner);
            //     write_pointerfield(s, owner);
            //     jl_genericmemory_t *new_mem = (jl_genericmemory_t*)&f->buf[reloc_offset];
            //     assert(new_mem->ptr == NULL);
            //     new_mem->ptr = (void*)((char*)m->ptr - (char*)owner); // relocation offset
            // }
            // else
            {
                size_t datasize = len * layout->size;
                size_t tot = datasize;
                int isbitsunion = layout->flags.arrayelem_isunion;
                if (isbitsunion)
                    tot += len;
                size_t headersize = sizeof(jl_genericmemory_t);
                // copy header
                ios_write(f, (char*)v, headersize);
                // write data
                if (!layout->flags.arrayelem_isboxed && layout->first_ptr < 0) {
                    // set owner to NULL
                    write_pointer(f);
                    // Non-pointer eltypes get encoded in the const_data section
                    size_t alignment_amt = JL_SMALL_BYTE_ALIGNMENT;
                    if (tot >= ARRAY_CACHE_ALIGN_THRESHOLD)
                        alignment_amt = JL_CACHE_BYTE_ALIGNMENT;
                    if (in_place && reactive_in_const(m->ptr))
                        ios_seek(s->const_data, (char*)m->ptr - reactive_const_base);
                    uintptr_t data = LLT_ALIGN(ios_pos(s->const_data), alignment_amt);
                    write_padding(s->const_data, data - ios_pos(s->const_data));
                    // write data and relocations
                    jl_genericmemory_t *new_mem = (jl_genericmemory_t*)&f->buf[reloc_offset];
                    new_mem->ptr = NULL; // relocation offset
                    data /= sizeof(void*);
                    assert(data < ((uintptr_t)1 << RELOC_TAG_OFFSET) && "offset to constant data too large");
                    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_genericmemory_t, ptr))); // relocation location
                    arraylist_push(&s->relocs_list, (void*)(((uintptr_t)ConstDataRef << RELOC_TAG_OFFSET) + data)); // relocation target
                    jl_value_t *et = jl_tparam1(t);
                    if (jl_is_cpointer_type(et)) {
                        // reset Ptr fields to C_NULL (but keep MAP_FAILED / INVALID_HANDLE)
                        const intptr_t *data = (const intptr_t*)m->ptr;
                        size_t i;
                        for (i = 0; i < len; i++) {
                            if (data[i] != -1)
                                write_pointer(s->const_data);
                            else
                                ios_write(s->const_data, (char*)&data[i], sizeof(data[i]));
                        }
                    }
                    else {
                        if (isbitsunion) {
                            ios_write(s->const_data, (char*)m->ptr, datasize);
                            ios_write(s->const_data, jl_genericmemory_typetagdata(m), len);
                        }
                        else {
                            ios_write(s->const_data, (char*)m->ptr, tot);
                        }
                    }
                    if (len == 0) { // TODO: should we have a zero-page, instead of writing each type's fragment separately?
                        write_padding(s->const_data, layout->size ? layout->size : isbitsunion);
                    }
                    else if (jl_genericmemory_how(m) == JL_GENERICMEMORY_STRINGOWNED) {
                        assert(jl_is_string(jl_genericmemory_data_owner_field(m)));
                        write_padding(s->const_data, 1);
                    }
                }
                else {
                    // Pointer eltypes are encoded in the mutable data section
                    headersize = LLT_ALIGN(headersize, JL_SMALL_BYTE_ALIGNMENT);
                    size_t data = LLT_ALIGN(ios_pos(f), JL_SMALL_BYTE_ALIGNMENT);
                    write_padding(f, data - ios_pos(f));
                    assert(reloc_offset + headersize == ios_pos(f));
                    jl_genericmemory_t *new_mem = (jl_genericmemory_t*)&f->buf[reloc_offset];
                    new_mem->ptr = (void*)headersize; // relocation offset
                    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_genericmemory_t, ptr))); // relocation location
                    arraylist_push(&s->relocs_list, (void*)(((uintptr_t)DataRef << RELOC_TAG_OFFSET) + item)); // relocation target
                    if (!layout->flags.arrayelem_isboxed) {
                        // copy all of the data first
                        const char *data = (const char*)m->ptr;
                        ios_write(f, data, datasize);
                        // the rewrite all of the embedded pointers to null+relocation
                        uint16_t elsz = layout->size;
                        size_t j, np = layout->first_ptr < 0 ? 0 : layout->npointers;
                        size_t i;
                        for (i = 0; i < len; i++) {
                            for (j = 0; j < np; j++) {
                                size_t offset = i * elsz + jl_ptr_offset(t, j) * sizeof(jl_value_t*);
                                jl_value_t *fld = get_replaceable_field((jl_value_t**)&data[offset], 1);
                                size_t fld_pos = reloc_offset + headersize + offset;
                                if (fld != NULL) {
                                    arraylist_push(&s->relocs_list, (void*)(uintptr_t)fld_pos); // relocation location
                                    arraylist_push(&s->relocs_list, (void*)backref_id(s, fld, s->link_ids_relocs)); // relocation target
                                    record_uniquing(s, fld, fld_pos);
                                }
                                memset(&f->buf[fld_pos], 0, sizeof(fld)); // relocation offset (none)
                            }
                        }
                    }
                    else {
                        jl_value_t **data = (jl_value_t**)m->ptr;
                        size_t i;
                        for (i = 0; i < len; i++) {
                            jl_value_t *e = get_replaceable_field(&data[i], 1);
                            write_pointerfield(s, e);
                        }
                    }
                }
            }
        }
        else if (jl_typeis(v, jl_module_type)) {
            assert(f == s->s);
            jl_write_module(s, item, (jl_module_t*)v);
        }
        else if (jl_typetagis(v, jl_task_tag << 4)) {
            abort(); // unreachable
        }
        else if (jl_is_svec(v)) {
            assert(f == s->s);
            ios_write(f, (char*)v, sizeof(void*));
            size_t ii, l = jl_svec_len(v);
            assert(l > 0 || (jl_svec_t*)v == jl_emptysvec);
            for (ii = 0; ii < l; ii++) {
                write_pointerfield(s, jl_svecref(v, ii));
            }
        }
        else if (jl_is_string(v)) {
            ios_write(f, (char*)v, sizeof(void*) + jl_string_len(v));
            write_uint8(f, '\0'); // null-terminated strings for easier C-compatibility
        }
        else if (jl_is_foreign_type(t) == 1) {
            abort(); // unreachable
        }
        else if (jl_datatype_nfields(t) == 0) {
            // The object has no fields, so we just snapshot its byte representation
            assert(t->layout->npointers == 0);
            ios_write(f, (char*)v, jl_datatype_size(t));
        }
        else if (jl_bigint_type && jl_typetagis(v, jl_bigint_type)) {
            // foreign types require special handling
            assert(f == s->s);
            if (in_place) {
                // the limbs of the base may not hold the value
                reactive_pages_refusal = "a bigint of the base changed";
                return;
            }
            jl_value_t *sizefield = jl_get_nth_field(v, 1);
            int32_t sz = jl_unbox_int32(sizefield);
            int32_t nw = (sz == 0 ? 1 : (sz < 0 ? -sz : sz));
            size_t nb = nw * gmp_limb_size;
            ios_write(f, (char*)&nw, sizeof(int32_t));
            ios_write(f, (char*)&sz, sizeof(int32_t));
            uintptr_t data = LLT_ALIGN(ios_pos(s->const_data), 8);
            write_padding(s->const_data, data - ios_pos(s->const_data));
            data /= sizeof(void*);
            assert(data < ((uintptr_t)1 << RELOC_TAG_OFFSET) && "offset to constant data too large");
            arraylist_push(&s->relocs_list, (void*)(reloc_offset + 8)); // relocation location
            arraylist_push(&s->relocs_list, (void*)(((uintptr_t)ConstDataRef << RELOC_TAG_OFFSET) + data)); // relocation target
            void *pdata = jl_unbox_voidpointer(jl_get_nth_field(v, 2));
            ios_write(s->const_data, (char*)pdata, nb);
            write_pointer(f);
        }
        else {
            // Generic object::DataType serialization by field
            const char *data = (const char*)v;
            size_t i, nf = jl_datatype_nfields(t);
            size_t tot = 0;
            for (i = 0; i < nf; i++) {
                size_t offset = jl_field_offset(t, i);
                const char *slot = data + offset;
                write_padding(f, offset - tot);
                tot = offset;
                size_t fsz = jl_field_size(t, i);
                jl_value_t *replace = (jl_value_t*)ptrhash_get(&bits_replace, (void*)slot);
                if (replace != HT_NOTFOUND && fsz > 0) {
                    assert(t->name->mutabl && !jl_field_isptr(t, i));
                    jl_value_t *rty = jl_typeof(replace);
                    size_t sz = jl_datatype_size(rty);
                    ios_write(f, (const char*)replace, sz);
                    jl_value_t *ft = jl_field_type_concrete(t, i);
                    int isunion = jl_is_uniontype(ft);
                    unsigned nth = 0;
                    if (!jl_find_union_component(ft, rty, &nth))
                        assert(0 && "invalid field assignment to isbits union");
                    assert(sz <= fsz - isunion);
                    write_padding(f, fsz - sz - isunion);
                    if (isunion)
                        write_uint8(f, nth);
                }
                else if (t->name->mutabl && jl_is_cpointer_type(jl_field_type_concrete(t, i)) && *(intptr_t*)slot != -1) {
                    // reset Ptr fields to C_NULL (but keep MAP_FAILED / INVALID_HANDLE)
                    assert(!jl_field_isptr(t, i));
                    write_pointer(f);
                }
                else if (fsz > 0) {
                    ios_write(f, slot, fsz);
                }
                tot += fsz;
            }

            size_t np = t->layout->npointers;
            size_t fldidx = 1;
            for (i = 0; i < np; i++) {
                size_t offset = jl_ptr_offset(t, i) * sizeof(jl_value_t*);
                while (offset >= (fldidx == nf ? jl_datatype_size(t) : jl_field_offset(t, fldidx)))
                    fldidx++;
                int mutabl = !jl_field_isconst(t, fldidx - 1);
                jl_value_t *fld = get_replaceable_field((jl_value_t**)&data[offset], mutabl);
                size_t fld_pos = offset + reloc_offset;
                if (fld != NULL) {
                    arraylist_push(&s->relocs_list, (void*)(uintptr_t)(fld_pos)); // relocation location
                    arraylist_push(&s->relocs_list, (void*)backref_id(s, fld, s->link_ids_relocs)); // relocation target
                    record_uniquing(s, fld, fld_pos);
                }
                memset(&f->buf[fld_pos], 0, sizeof(fld)); // relocation offset (none)
            }

            // Need do a tricky fieldtype walk an record all memoryref we find inlined in this value
            record_memoryrefs_inside(s, t, reloc_offset, data);

            // A few objects need additional handling beyond the generic serialization above
            if (s->incremental && jl_typetagis(v, jl_typemap_entry_type)) {
                assert(f == s->s);
                jl_typemap_entry_t *newentry = (jl_typemap_entry_t*)&s->s->buf[reloc_offset];
                if (jl_atomic_load_relaxed(&newentry->max_world) == ~(size_t)0) {
                    if (jl_atomic_load_relaxed(&newentry->min_world) > 1) {
                        jl_atomic_store_relaxed(&newentry->min_world, ~(size_t)0);
                        jl_atomic_store_relaxed(&newentry->max_world, WORLD_AGE_REVALIDATION_SENTINEL);
                        arraylist_push(&s->fixup_objs, (void*)reloc_offset);
                    }
                }
                else {
                    // garbage newentry - delete it :(
                    jl_atomic_store_relaxed(&newentry->min_world, 1);
                    jl_atomic_store_relaxed(&newentry->max_world, 0);
                }
            }
            else if (s->incremental && jl_is_binding_partition(v)) {
                jl_binding_partition_t *newbpart = (jl_binding_partition_t*)&s->s->buf[reloc_offset];
                size_t max_world = jl_atomic_load_relaxed(&newbpart->max_world);
                if (max_world == ~(size_t)0) {
                    // Still valid. Will be considered to be defined in jl_require_world
                    // after reload, which is the first world before new code runs.
                    // We use this as a quick check to determine whether a binding was
                    // invalidated. If a binding was first defined in or before
                    // jl_require_world, then we can assume that all precompile processes
                    // will have seen it consistently.
                    jl_atomic_store_relaxed(&newbpart->min_world, jl_require_world);
                }
                else {
                    // The world will not be reachable after loading
                    jl_atomic_store_relaxed(&newbpart->min_world, 1);
                    jl_atomic_store_relaxed(&newbpart->max_world, 0);
                }
            }
            else if (jl_is_method(v)) {
                assert(f == s->s);
                write_padding(f, sizeof(jl_method_t) - tot); // hidden fields
                jl_method_t *m = (jl_method_t*)v;
                jl_method_t *newm = (jl_method_t*)&f->buf[reloc_offset];
                if (s->incremental) {
                    if (jl_atomic_load_relaxed(&newm->primary_world) > 1) {
                        jl_atomic_store_relaxed(&newm->primary_world, ~(size_t)0); // min-world
                        int dispatch_status = jl_atomic_load_relaxed(&newm->dispatch_status);
                        int new_dispatch_status = 0;
                        if (!(dispatch_status & METHOD_SIG_LATEST_ONLY))
                            new_dispatch_status |= METHOD_SIG_PRECOMPILE_MANY;
                        jl_atomic_store_relaxed(&newm->dispatch_status, new_dispatch_status);
                        arraylist_push(&s->fixup_objs, (void*)reloc_offset);
                    }
                }
                else {
                    newm->nroots_sysimg = m->roots ? jl_array_len(m->roots) : 0;
                }
            }
            else if (jl_is_method_instance(v)) {
                assert(f == s->s);
                jl_method_instance_t *newmi = (jl_method_instance_t*)&f->buf[reloc_offset];
                jl_atomic_store_relaxed(&newmi->flags, 0);
                if (s->incremental) {
                    jl_atomic_store_relaxed(&newmi->dispatch_status, 0);
                }
            }
            else if (jl_is_code_instance(v)) {
                assert(f == s->s);

                // Handle the native-code pointers
                jl_code_instance_t *ci = (jl_code_instance_t*)v;
                jl_code_instance_t *newci = (jl_code_instance_t*)&f->buf[reloc_offset];

                if (s->incremental) {
                    if (jl_atomic_load_relaxed(&ci->max_world) == ~(size_t)0) {
                        //assert(jl_atomic_load_relaxed(&ci->edges) != jl_emptysvec); // some code (such as !==) might add a method lookup restriction but not keep the edges
                        jl_atomic_store_release(&newci->min_world, ~(size_t)0);
                        jl_atomic_store_release(&newci->max_world, WORLD_AGE_REVALIDATION_SENTINEL);
                        arraylist_push(&s->fixup_objs, (void*)reloc_offset);
                    }
                    else {
                        // garbage object - delete it :(
                        jl_atomic_store_release(&newci->min_world, 1);
                        jl_atomic_store_release(&newci->max_world, 0);
                    }
                }
                jl_atomic_store_relaxed(&newci->time_compile, 0.0);
                jl_atomic_store_relaxed(&newci->invoke, NULL);
                // preserve only JL_CI_FLAGS_NATIVE_CACHE_VALID bits
                jl_atomic_store_relaxed(&newci->flags, jl_atomic_load_relaxed(&newci->flags) & JL_CI_FLAGS_NATIVE_CACHE_VALID);
                jl_atomic_store_relaxed(&newci->specptr.fptr, NULL);
                int8_t fptr_id = JL_API_NULL;
                int8_t builtin_id = 0;
                if (jl_atomic_load_relaxed(&ci->invoke) == jl_fptr_const_return) {
                    fptr_id = JL_API_CONST;
                }
                else {
                    if (jl_is_method(jl_get_ci_mi(ci)->def.method)) {
                        builtin_id = jl_fptr_id(jl_atomic_load_relaxed(&ci->specptr.fptr));
                        if (builtin_id) { // found in the table of builtins
                            assert(builtin_id >= 2);
                            fptr_id = JL_API_BUILTIN;
                        }
                        else {
                            int32_t invokeptr_id = 0;
                            int32_t specfptr_id = 0;
                            jl_get_function_id(native_functions, ci, &invokeptr_id, &specfptr_id); // see if we generated code for it
                            if (invokeptr_id) {
                                if (invokeptr_id == -1) {
                                    fptr_id = JL_API_BOXED;
                                }
                                else if (invokeptr_id == -2) {
                                    fptr_id = JL_API_WITH_PARAMETERS;
                                }
                                else if (invokeptr_id == -3) {
                                    abort();
                                }
                                else if (invokeptr_id == -4) {
                                    fptr_id = JL_API_OC_CALL;
                                }
                                else if (invokeptr_id == -5) {
                                    abort();
                                }
                                else {
                                    assert(invokeptr_id > 0);
                                    ios_ensureroom(s->fptr_record, invokeptr_id * sizeof(void*));
                                    ios_seek(s->fptr_record, (invokeptr_id - 1) * sizeof(void*));
                                    write_reloc_t(s->fptr_record, (reloc_t)~reloc_offset);
#ifdef _P64
                                    if (sizeof(reloc_t) < 8)
                                        write_padding(s->fptr_record, 8 - sizeof(reloc_t));
#endif
                                }
                                if (specfptr_id) {
                                    assert(specfptr_id > invokeptr_id && specfptr_id > 0);
                                    ios_ensureroom(s->fptr_record, specfptr_id * sizeof(void*));
                                    ios_seek(s->fptr_record, (specfptr_id - 1) * sizeof(void*));
                                    write_reloc_t(s->fptr_record, reloc_offset);
#ifdef _P64
                                    if (sizeof(reloc_t) < 8)
                                        write_padding(s->fptr_record, 8 - sizeof(reloc_t));
#endif
                                }
                            }
                        }
                    }
                }
                jl_atomic_store_relaxed(&newci->invoke, NULL); // relocation offset
                // Reactive reuse: a precompile request that this build did not
                // serve does not pass to the next build. The run time sets the
                // flag during the build, after the worklist is closed; the next
                // build would compile the method instance although nothing
                // changed.
                if (fptr_id == JL_API_NULL && builtin_id == 0 && jl_reactive_reuse_enabled())
                    jl_atomic_store_relaxed(&newci->precompile, 0);
                if (fptr_id != JL_API_NULL) {
                    assert(fptr_id < BuiltinFunctionTag && "too many functions to serialize");
                    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_code_instance_t, invoke))); // relocation location
                    arraylist_push(&s->relocs_list, (void*)(((uintptr_t)FunctionRef << RELOC_TAG_OFFSET) + fptr_id)); // relocation target
                }
                if (builtin_id >= 2) {
                    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_code_instance_t, specptr.fptr))); // relocation location
                    arraylist_push(&s->relocs_list, (void*)(((uintptr_t)FunctionRef << RELOC_TAG_OFFSET) + BuiltinFunctionTag + builtin_id - 2)); // relocation target
                }
            }
            else if (jl_is_datatype(v)) {
                assert(f == s->s);
                jl_datatype_t *dt = (jl_datatype_t*)v;
                jl_datatype_t *newdt = (jl_datatype_t*)&f->buf[reloc_offset];

                if (dt->layout != NULL) {
                    size_t nf = dt->layout->nfields;
                    size_t np = dt->layout->npointers;
                    size_t fieldsize = 0;
                    uint8_t is_foreign_type = dt->layout->flags.fielddesc_type == JL_FIELDDESC_FOREIGN;
                    if (!is_foreign_type) {
                        fieldsize = jl_fielddesc_size(dt->layout->flags.fielddesc_type);
                    }
                    char *flddesc = (char*)dt->layout;
                    size_t fldsize = sizeof(jl_datatype_layout_t) + nf * fieldsize;
                    if (!is_foreign_type && dt->layout->first_ptr != -1)
                        fldsize += np * jl_fielddesc_ptr_size(dt->layout->flags.fielddesc_type);
                    if (in_place && reactive_in_const(dt->layout))
                        ios_seek(s->const_data, (char*)dt->layout - reactive_const_base);
                    uintptr_t layout = LLT_ALIGN(ios_pos(s->const_data), sizeof(void*));
                    write_padding(s->const_data, layout - ios_pos(s->const_data)); // realign stream
                    newdt->layout = NULL; // relocation offset
                    layout /= sizeof(void*);
                    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_datatype_t, layout))); // relocation location
                    arraylist_push(&s->relocs_list, (void*)(((uintptr_t)ConstDataRef << RELOC_TAG_OFFSET) + layout)); // relocation target
                    ios_write(s->const_data, flddesc, fldsize);
                    if (is_foreign_type) {
                        // make sure we have space for the extra hidden pointers
                        // zero them since they will need to be re-initialized externally
                        assert(fldsize == sizeof(jl_datatype_layout_t));
                        jl_fielddescdyn_t dyn = {0, 0};
                        ios_write(s->const_data, (char*)&dyn, sizeof(jl_fielddescdyn_t));
                    }
                }
                void *superidx = ptrhash_get(&serialization_order, dt->super);
                if (s->incremental && superidx != HT_NOTFOUND && from_seroder_entry(superidx) > item && needs_uniquing((jl_value_t*)dt->super, s->query_cache))
                    arraylist_push(&s->uniquing_super, dt->super);
            }
            else if (jl_is_typename(v)) {
                assert(f == s->s);
                jl_typename_t *tn = (jl_typename_t*)v;
                jl_typename_t *newtn = (jl_typename_t*)&f->buf[reloc_offset];
                if (tn->atomicfields != NULL) {
                    size_t nb = (jl_svec_len(tn->names) + 31) / 32 * sizeof(uint32_t);
                    if (in_place && reactive_in_const(tn->atomicfields))
                        ios_seek(s->const_data, (char*)tn->atomicfields - reactive_const_base);
                    uintptr_t layout = LLT_ALIGN(ios_pos(s->const_data), sizeof(void*));
                    write_padding(s->const_data, layout - ios_pos(s->const_data)); // realign stream
                    newtn->atomicfields = NULL; // relocation offset
                    layout /= sizeof(void*);
                    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_typename_t, atomicfields))); // relocation location
                    arraylist_push(&s->relocs_list, (void*)(((uintptr_t)ConstDataRef << RELOC_TAG_OFFSET) + layout)); // relocation target
                    ios_write(s->const_data, (char*)tn->atomicfields, nb);
                }
                if (tn->constfields != NULL) {
                    size_t nb = (jl_svec_len(tn->names) + 31) / 32 * sizeof(uint32_t);
                    if (in_place && reactive_in_const(tn->constfields))
                        ios_seek(s->const_data, (char*)tn->constfields - reactive_const_base);
                    uintptr_t layout = LLT_ALIGN(ios_pos(s->const_data), sizeof(void*));
                    write_padding(s->const_data, layout - ios_pos(s->const_data)); // realign stream
                    newtn->constfields = NULL; // relocation offset
                    layout /= sizeof(void*);
                    arraylist_push(&s->relocs_list, (void*)(reloc_offset + offsetof(jl_typename_t, constfields))); // relocation location
                    arraylist_push(&s->relocs_list, (void*)(((uintptr_t)ConstDataRef << RELOC_TAG_OFFSET) + layout)); // relocation target
                    ios_write(s->const_data, (char*)tn->constfields, nb);
                }
            }
            else if (jl_is_globalref(v)) {
                assert(f == s->s);
                jl_globalref_t *gr = (jl_globalref_t*)v;
                if (s->incremental && jl_object_in_image((jl_value_t*)gr->mod)) {
                    // will need to populate the binding field later
                    arraylist_push(&s->fixup_objs, (void*)reloc_offset);
                }
            }
            else if (jl_is_genericmemoryref(v)) {
                assert(f == s->s);
                record_memoryref(s, reloc_offset, *(jl_genericmemoryref_t*)v);
            }
            else {
                write_padding(f, jl_datatype_size(t) - tot);
            }
        }
        if (in_place) {
            size_t end = ios_pos(f);
            if (end <= in_place_lo || end > in_place_hi) {
                // a module whose usings grew: it does not fit its place
                reactive_pages_refusal = "an object of the base does not fit its place";
                return;
            }
            reactive_pages_rewritten[in_place_index] = 1;
            reactive_pages_nrewritten++;
            ios_seek(f, reactive_pages_append);
            ios_seek(s->const_data, reactive_pages_const_append);
        }
        else if (reactive_pages_on) {
            reactive_pages_append = ios_pos(s->s);
            reactive_pages_const_append = ios_pos(s->const_data);
        }
    }
    assert(s->uniquing_super.len == 0);
}

// In deserialization, create Symbols and set up the
// index for backreferencing
static void jl_read_symbols(jl_serializer_state *s)
{
    assert(deser_sym.len == 0);
    uintptr_t base = (uintptr_t)&s->symbols->buf[0];
    uintptr_t end = base + s->symbols->size;
    while (base < end) {
        uint32_t len = jl_load_unaligned_i32((void*)base);
        base += 4;
        const char *str = (const char*)base;
        base += len + 1;
        //printf("symbol %3d: %s\n", len, str);
        jl_sym_t *sym = _jl_symbol(str, len);
        arraylist_push(&deser_sym, (void*)sym);
    }
}


// In serialization, extract the appropriate serializer position for RefTags-encoded index `reloc_item`.
// Used for hard-coded tagged items, `relocs_list`, and `gctags_list`
static uintptr_t get_reloc_for_item(uintptr_t reloc_item, size_t reloc_offset)
{
    enum RefTags tag = (enum RefTags)(reloc_item >> RELOC_TAG_OFFSET);
    if (tag == BaseRef) {
        // an object of the base of a page-written image: its offset is final
        uintptr_t offset = reloc_item & (((uintptr_t)1 << RELOC_TAG_OFFSET) - 1);
        return ((uintptr_t)DataRef << RELOC_TAG_OFFSET) + offset + reloc_offset;
    }
    if (tag == DataRef) {
        // first serialized segment
        // need to compute the final relocation offset via the layout table
        assert(reloc_item < layout_table.len);
        uintptr_t reloc_base = (uintptr_t)layout_table.items[reloc_item];
        assert(reloc_base != 0 && "layout offset missing for relocation item");
        if (reloc_base & 1) {
            // convert to a ConstDataRef
            tag = ConstDataRef;
            reloc_base &= ~(uintptr_t)1;
            assert(LLT_ALIGN(reloc_base, sizeof(void*)) == reloc_base);
            reloc_base /= sizeof(void*);
            assert(reloc_offset == 0);
        }
        // write reloc_offset into s->s at pos
        return ((uintptr_t)tag << RELOC_TAG_OFFSET) + reloc_base + reloc_offset;
    }
    else {
        // just write the item reloc_id directly
#ifndef JL_NDEBUG
        assert(reloc_offset == 0 && "offsets for relocations to builtin objects should be precomposed in the reloc_item");
        size_t offset = (reloc_item & (((uintptr_t)1 << RELOC_TAG_OFFSET) - 1));
        switch (tag) {
        case ConstDataRef:
            break;
        case SymbolRef:
            assert(offset < nsym_tag && "corrupt relocation item id");
            break;
        case TagRef:
            assert(offset < 2 * NBOX_C + 258 && "corrupt relocation item id");
            break;
        case FunctionRef:
            if (offset & BuiltinFunctionTag) {
                offset &= ~BuiltinFunctionTag;
                assert(offset < jl_n_builtins && "unknown function pointer id");
            }
            else {
                assert(offset < JL_API_MAX && "unknown function pointer id");
            }
            break;
        case SysimageLinkage:
            break;
        case ExternalLinkage:
            break;
        default:
            assert(0 && "corrupt relocation item id");
            abort();
        }
#endif
        return reloc_item; // pre-composed relocation + offset
    }
}

// Compute target location at deserialization
static inline uintptr_t get_item_for_reloc(jl_serializer_state *s, uintptr_t base, uintptr_t reloc_id, jl_array_t *link_ids, int *link_index) JL_NOTSAFEPOINT
{
    enum RefTags tag = (enum RefTags)(reloc_id >> RELOC_TAG_OFFSET);
    size_t offset = (reloc_id & (((uintptr_t)1 << RELOC_TAG_OFFSET) - 1));
    switch (tag) {
    case DataRef:
        assert(offset <= s->s->size);
        return (uintptr_t)base + offset;
    case ConstDataRef:
        offset *= sizeof(void*);
        assert(offset <= s->const_data->size);
        return (uintptr_t)s->const_data->buf + offset;
    case SymbolRef:
        assert(offset < deser_sym.len && deser_sym.items[offset] && "corrupt relocation item id");
        return (uintptr_t)deser_sym.items[offset];
    case TagRef:
        if (offset == 0)
            return (uintptr_t)s->ptls->root_task;
        if (offset == 1)
            return (uintptr_t)jl_nothing;
        offset -= 2;
        if (offset < NBOX_C)
            return (uintptr_t)jl_box_int64((int64_t)offset - NBOX_C / 2);
        offset -= NBOX_C;
        if (offset < NBOX_C)
            return (uintptr_t)jl_box_int32((int32_t)offset - NBOX_C / 2);
        offset -= NBOX_C;
        if (offset < 256)
            return (uintptr_t)jl_box_uint8(offset);
        // offset -= 256;
        assert(0 && "corrupt relocation item id");
        jl_unreachable(); // terminate control flow if assertion is disabled.
    case FunctionRef:
        if (offset & BuiltinFunctionTag) {
            offset &= ~BuiltinFunctionTag;
            assert(offset < jl_n_builtins && "unknown function pointer ID");
            return (uintptr_t)jl_builtin_f_addrs[offset];
        }
        switch ((jl_callingconv_t)offset) {
        case JL_API_BOXED:
            if (s->image->fptrs.nptrs)
                return (uintptr_t)jl_fptr_args;
            return (uintptr_t)NULL;
        case JL_API_WITH_PARAMETERS:
            if (s->image->fptrs.nptrs)
                return (uintptr_t)jl_fptr_sparam;
            return (uintptr_t)NULL;
        case JL_API_OC_CALL:
            if (s->image->fptrs.nptrs)
                return (uintptr_t)jl_f_opaque_closure_call;
            return (uintptr_t)NULL;
        case JL_API_CONST:
            return (uintptr_t)jl_fptr_const_return;
        case JL_API_INTERPRETED:
            return (uintptr_t)jl_fptr_interpret_call;
        case JL_API_BUILTIN:
            return (uintptr_t)jl_fptr_args;
        case JL_API_NULL:
        case JL_API_MAX:
        //default:
            assert("corrupt relocation item id");
        }
    case SysimageLinkage: {
#ifdef _P64
        size_t depsidx = offset >> DEPS_IDX_OFFSET;
        offset &= ((size_t)1 << DEPS_IDX_OFFSET) - 1;
#else
        size_t depsidx = 0;
#endif
        assert(s->buildid_depmods_idxs && depsidx < jl_array_len(s->buildid_depmods_idxs));
        size_t i = jl_array_data(s->buildid_depmods_idxs, uint32_t)[depsidx];
        assert(2*i < jl_linkage_blobs.len);
        return (uintptr_t)jl_linkage_blobs.items[2*i] + offset*SYS_EXTERNAL_LINK_UNIT;
    }
    case ExternalLinkage: {
        assert(link_ids);
        assert(link_index);
        assert(0 <= *link_index && *link_index < jl_array_len(link_ids));
        uint32_t depsidx = jl_array_data(link_ids, uint32_t)[*link_index];
        *link_index += 1;
        assert(depsidx < jl_array_len(s->buildid_depmods_idxs));
        size_t i = jl_array_data(s->buildid_depmods_idxs, uint32_t)[depsidx];
        assert(2*i < jl_linkage_blobs.len);
        return (uintptr_t)jl_linkage_blobs.items[2*i] + offset*SYS_EXTERNAL_LINK_UNIT;
    }
    case BaseRef:
        break; // never in an image: the finish of a save makes it a DataRef
    }
    abort();
}


static void jl_finish_relocs(char *base, size_t size, arraylist_t *list)
{
    for (size_t i = 0; i < list->len; i += 2) {
        size_t pos = (size_t)list->items[i];
        size_t item = (size_t)list->items[i + 1];   // item is tagref-encoded
        uintptr_t *pv = (uintptr_t*)(base + pos);
        assert(pos < size && pos != 0);
        *pv = get_reloc_for_item(item, *pv);
    }
}

static void jl_write_offsetlist(ios_t *s, size_t size, arraylist_t *list)
{
    for (size_t i = 0; i < list->len; i += 2) {
        size_t last_pos = i ? (size_t)list->items[i - 2] : 0;
        size_t pos = (size_t)list->items[i];
        assert(pos < size && pos != 0);
        // write pos as compressed difference.
        size_t pos_diff = pos - last_pos;
        while (pos_diff) {
            assert(pos_diff >= 0);
            if (pos_diff <= 127) {
                write_int8(s, pos_diff);
                break;
            }
            else {
                // Extract the next 7 bits
                int8_t ns = pos_diff & (int8_t)0x7F;
                pos_diff >>= 7;
                // Set the high bit if there's still more
                ns |= (!!pos_diff) << 7;
                write_int8(s, ns);
            }
        }
    }
    write_int8(s, 0);
}


static void jl_write_arraylist(ios_t *s, arraylist_t *list)
{
    write_uint(s, list->len);
    ios_write(s, (const char*)list->items, list->len * sizeof(void*));
}

static void jl_read_reloclist(jl_serializer_state *s, jl_array_t *link_ids, uint8_t bits)
{
    uintptr_t base = (uintptr_t)s->s->buf;
    uintptr_t last_pos = 0;
    uint8_t *current = (uint8_t *)(s->relocs->buf + s->relocs->bpos);
    int link_index = 0;
    while (1) {
        // Read the offset of the next object
        size_t pos_diff = 0;
        size_t cnt = 0;
        while (1) {
            assert(s->relocs->bpos <= s->relocs->size);
            assert((char *)current <= (char *)(s->relocs->buf + s->relocs->size));
            int8_t c = *current++;
            s->relocs->bpos += 1;

            pos_diff |= ((size_t)c & 0x7F) << (7 * cnt++);
            if ((c >> 7) == 0)
                break;
        }
        if (pos_diff == 0)
            break;

        uintptr_t pos = last_pos + pos_diff;
        last_pos = pos;
        uintptr_t *pv = (uintptr_t *)(base + pos);
        uintptr_t v = *pv;
        v = get_item_for_reloc(s, base, v, link_ids, &link_index);
        if (bits && v && ((jl_datatype_t*)v)->smalltag)
            v = (uintptr_t)((jl_datatype_t*)v)->smalltag << 4; // TODO: should we have a representation that supports sweep without a relocation step?
        *pv = v | bits;
    }
    assert(!link_ids || link_index == jl_array_len(link_ids));
}

static void jl_read_memreflist(jl_serializer_state *s)
{
    uintptr_t base = (uintptr_t)s->s->buf;
    uintptr_t last_pos = 0;
    uint8_t *current = (uint8_t *)(s->relocs->buf + s->relocs->bpos);
    while (1) {
        // Read the offset of the next object
        size_t pos_diff = 0;
        size_t cnt = 0;
        while (1) {
            assert(s->relocs->bpos <= s->relocs->size);
            assert((char *)current <= (char *)(s->relocs->buf + s->relocs->size));
            int8_t c = *current++;
            s->relocs->bpos += 1;

            pos_diff |= ((size_t)c & 0x7F) << (7 * cnt++);
            if ((c >> 7) == 0)
                break;
        }
        if (pos_diff == 0)
            break;

        uintptr_t pos = last_pos + pos_diff;
        last_pos = pos;
        jl_genericmemoryref_t *pv = (jl_genericmemoryref_t*)(base + pos);
        size_t offset = (size_t)pv->ptr_or_offset;
        pv->ptr_or_offset = (void*)((char*)pv->mem->ptr + offset);
    }
}


static void jl_read_arraylist(ios_t *s, arraylist_t *list)
{
    size_t list_len = read_uint(s);
    arraylist_new(list, 0);
    arraylist_grow(list, list_len);
    ios_read(s, (char*)list->items, list_len * sizeof(void*));
}

// Persistent set of image objects that reference non-image objects.
// Used to track GC reachability for mutable objects in the images,
// treating them as a third, "permanent" GC generation.
arraylist_t image_remset;
jl_mutex_t image_remset_lock;

// jl_write_value and jl_read_value are used for storing Julia objects that are adjuncts to
// the image proper. For example, new methods added to external callables require
// insertion into the appropriate method table.
#define jl_write_value(s, v) _jl_write_value((s), (jl_value_t*)(v))
static void _jl_write_value(jl_serializer_state *s, jl_value_t *v) JL_GC_DISABLED
{
    if (v == NULL) {
        write_reloc_t(s->s, 0);
        return;
    }
    uintptr_t item = backref_id(s, v, NULL);
    uintptr_t reloc = get_reloc_for_item(item, 0);
    write_reloc_t(s->s, reloc);
}

static jl_value_t *jl_read_value(jl_serializer_state *s)
{
    uintptr_t offset = *(reloc_t*)((uintptr_t)s->s->buf + (uintptr_t)s->s->bpos);
    s->s->bpos += sizeof(reloc_t);
    if (offset == 0)
        return NULL;
    uintptr_t base = s->root_base ? (uintptr_t)s->root_base : (uintptr_t)s->s->buf;
    return (jl_value_t*)get_item_for_reloc(s, base, offset, NULL, NULL);
}

// The next two, `jl_read_offset` and `jl_delayed_reloc`, are essentially a split version
// of `jl_read_value` that allows usage of the relocation data rather than passing NULL
// to `get_item_for_reloc`.
// This works around what would otherwise be an order-dependency conundrum: objects
// that may require relocation data have to be inserted into `serialization_order`,
// and that may include some of the adjunct data that gets serialized via
// `jl_write_value`. But we can't interpret them properly until we read the relocation
// data, and that happens after we pull items out of the serialization stream.
static uintptr_t jl_read_offset(jl_serializer_state *s)
{
    uintptr_t base = (uintptr_t)&s->s->buf[0];
    uintptr_t offset = *(reloc_t*)(base + (uintptr_t)s->s->bpos);
    s->s->bpos += sizeof(reloc_t);
    return offset;
}

static jl_value_t *jl_delayed_reloc(jl_serializer_state *s, uintptr_t offset) JL_GC_DISABLED
{
    if (!offset)
        return NULL;
    uintptr_t base = (uintptr_t)s->s->buf;
    int link_index = 0;
    jl_value_t *ret = (jl_value_t*)get_item_for_reloc(s, base, offset, s->link_ids_relocs, &link_index);
    assert(!s->link_ids_relocs || link_index < jl_array_len(s->link_ids_relocs));
    return ret;
}


static void jl_update_all_fptrs(jl_serializer_state *s, jl_image_t *image)
{
    jl_image_fptrs_t fvars = image->fptrs;
    // make these NULL now so we skip trying to restore GlobalVariable pointers later
    image->gvars_base = NULL;
    if (fvars.nptrs == 0)
        return;

    memcpy(image->jl_small_typeof, &jl_small_typeof, sizeof(jl_small_typeof));

    int img_fvars_max = s->fptr_record->size / sizeof(void*);
    size_t i;
    uintptr_t base = (uintptr_t)&s->s->buf[0];
    // These will become MethodInstance references, but they start out as a list of
    // offsets into `s` for CodeInstances
    jl_method_instance_t **linfos = (jl_method_instance_t**)&s->fptr_record->buf[0];
    uint32_t clone_idx = 0;
    for (i = 0; i < img_fvars_max; i++) {
        reloc_t offset = *(reloc_t*)&linfos[i];
        linfos[i] = NULL;
        if (offset != 0) {
            int specfunc = 1;
            if (offset & ((uintptr_t)1 << (8 * sizeof(reloc_t) - 1))) {
                // if high bit is set, this is the func wrapper, not the specfunc
                specfunc = 0;
                offset = ~offset;
            }
            jl_code_instance_t *codeinst = (jl_code_instance_t*)(base + offset);
            assert(jl_is_method(jl_get_ci_mi(codeinst)->def.method) && jl_atomic_load_relaxed(&codeinst->invoke) != jl_fptr_const_return);
            assert(specfunc ? jl_atomic_load_relaxed(&codeinst->invoke) != NULL : jl_atomic_load_relaxed(&codeinst->invoke) == NULL);
            linfos[i] = jl_get_ci_mi(codeinst);     // now it's a MethodInstance
            void *fptr = fvars.ptrs[i];
            for (; clone_idx < fvars.nclones; clone_idx++) {
                uint32_t idx = fvars.clone_idxs[clone_idx] & jl_sysimg_val_mask;
                if (idx < i)
                    continue;
                if (idx == i)
                    fptr = fvars.clone_ptrs[clone_idx];
                break;
            }
            if (specfunc) {
                jl_atomic_store_relaxed(&codeinst->specptr.fptr, fptr);
                // TODO: set JL_CI_FLAGS_SPECPTR_SPECIALIZED only if confirmed to be true
                jl_atomic_store_relaxed(&codeinst->flags, jl_atomic_load_relaxed(&codeinst->flags) | JL_CI_FLAGS_SPECPTR_SPECIALIZED | JL_CI_FLAGS_INVOKE_MATCHES_SPECPTR | JL_CI_FLAGS_FROM_IMAGE);
            }
            else {
                jl_atomic_store_relaxed(&codeinst->invoke, (jl_callptr_t)fptr);
            }
        }
    }
    // Tell LLVM about the native code
    jl_register_fptrs(image->base, &fvars, linfos, img_fvars_max);
}

static uint32_t write_gvars(jl_serializer_state *s, arraylist_t *globals, arraylist_t *external_fns) JL_GC_DISABLED
{
    size_t len = globals->len + external_fns->len;
    ios_ensureroom(s->gvar_record, len * sizeof(reloc_t));
    for (size_t i = 0; i < globals->len; i++) {
        void *g = globals->items[i];
        uintptr_t item = backref_id(s, g, s->link_ids_gvars);
        uintptr_t reloc = get_reloc_for_item(item, 0);
        write_reloc_t(s->gvar_record, reloc);
        record_uniquing(s, (jl_value_t*)g, ((i << 2) | 2)); // mark as gvar && !tag
    }
    for (size_t i = 0; i < external_fns->len; i++) {
        jl_code_instance_t *ci = (jl_code_instance_t*)external_fns->items[i];
        assert(ci && (jl_atomic_load_relaxed(&ci->flags) & JL_CI_FLAGS_SPECPTR_SPECIALIZED));
        uintptr_t item = backref_id(s, (void*)ci, s->link_ids_external_fnvars);
        uintptr_t reloc = get_reloc_for_item(item, 0);
        write_reloc_t(s->gvar_record, reloc);
    }
    return globals->len;
}

// Pointer relocation for native-code referenced global variables
static void jl_update_all_gvars(jl_serializer_state *s, jl_image_t *image, uint32_t external_fns_begin)
{
    if (image->gvars_base == NULL)
        return;
    uintptr_t base = (uintptr_t)s->s->buf;
    size_t i = 0;
    size_t l = s->gvar_record->size / sizeof(reloc_t);
    reloc_t *gvars = (reloc_t*)&s->gvar_record->buf[0];
    int gvar_link_index = 0;
    int external_fns_link_index = 0;
    assert(l == image->ngvars);
    for (i = 0; i < l; i++) {
        uintptr_t offset = gvars[i];
        uintptr_t v = 0;
        if (i < external_fns_begin) {
            v = get_item_for_reloc(s, base, offset, s->link_ids_gvars, &gvar_link_index);
        }
        else {
            v = get_item_for_reloc(s, base, offset, s->link_ids_external_fnvars, &external_fns_link_index);
        }
        uintptr_t *gv = sysimg_gvars(image->gvars_base, image->gvars_offsets, i);
        *gv = v;
    }
    assert(!s->link_ids_gvars || gvar_link_index == jl_array_len(s->link_ids_gvars));
    assert(!s->link_ids_external_fnvars || external_fns_link_index == jl_array_len(s->link_ids_external_fnvars));
}

static void jl_root_new_gvars(jl_serializer_state *s, jl_image_t *image, uint32_t external_fns_begin)
{
    if (image->gvars_base == NULL)
        return;
    size_t i = 0;
    size_t l = s->gvar_record->size / sizeof(reloc_t);
    for (i = 0; i < l; i++) {
        uintptr_t *gv = sysimg_gvars(image->gvars_base, image->gvars_offsets, i);
        uintptr_t v = *gv;
        if (i < external_fns_begin) {
            if (!jl_is_binding(v))
                v = (uintptr_t)jl_as_global_root((jl_value_t*)v, 1);
        }
        else {
            jl_code_instance_t *codeinst = (jl_code_instance_t*) v;
            assert(codeinst && (jl_atomic_load_relaxed(&codeinst->flags) & JL_CI_FLAGS_SPECPTR_SPECIALIZED) && jl_atomic_load_relaxed(&codeinst->specptr.fptr));
            v = (uintptr_t)jl_atomic_load_relaxed(&codeinst->specptr.fptr);
        }
        *gv = v;
    }
}

// Code below helps slim down the images by
// removing cached types not referenced in the stream
static jl_svec_t *jl_prune_type_cache_hash(jl_svec_t *cache) JL_GC_DISABLED
{
    size_t l = jl_svec_len(cache), i;
    size_t sz = 0;
    if (l == 0)
        return cache;
    for (i = 0; i < l; i++) {
        jl_value_t *ti = jl_svecref(cache, i);
        if (ti == jl_nothing)
            continue;
        if (!reactive_pages_live(ti))
            jl_svecset(cache, i, jl_nothing);
        else
            sz += 1;
    }
    if (sz < HT_N_INLINE)
        sz = HT_N_INLINE;

    void *idx = ptrhash_get(&serialization_order, cache);
    if (reactive_pages_on && idx == HT_NOTFOUND)
        return cache; // a cache of the base that the save did not queue holds live entries only
    assert(idx != HT_NOTFOUND && idx != (void*)(uintptr_t)-1);
    assert(serialization_queue.items[from_seroder_entry(idx)] == cache);
    jl_svec_t *old = cache;
    cache = cache_rehash_set(cache, sz);
    if (reactive_pages_on && jl_object_in_image((jl_value_t*)old)) {
        // A page write keeps the old cache in the queue: it is rewritten in
        // its place (its dead entries null), and the new cache appends. An
        // overlay writes the pages of the base from the queue alone, so an
        // object dropped from it would land as zeros under its tag.
        arraylist_push(&serialization_queue, (void*)cache);
        ptrhash_put(&serialization_order, cache, to_seroder_entry(serialization_queue.len - 1));
        return cache;
    }
    // redirect all references to the old cache to relocate to the new cache object
    ptrhash_put(&serialization_order, cache, idx);
    serialization_queue.items[from_seroder_entry(idx)] = cache;
    return cache;
}

static void jl_prune_type_cache_linear(jl_svec_t *cache)
{
    size_t l = jl_svec_len(cache), ins = 0, i;
    for (i = 0; i < l; i++) {
        jl_value_t *ti = jl_svecref(cache, i);
        if (ti == jl_nothing)
            break;
        if (reactive_pages_live(ti))
            jl_svecset(cache, ins++, ti);
    }
    while (ins < l)
        jl_svecset(cache, ins++, jl_nothing);
}

static void jl_prune_mi_backedges(jl_array_t *backedges)
{
    if (backedges == NULL)
        return;
    size_t i = 0, ins = 0, n = jl_array_nrows(backedges);
    while (i < n) {
        jl_value_t *invokeTypes;
        jl_code_instance_t *caller;
        i = get_next_edge(backedges, i, &invokeTypes, &caller);
        if (reactive_pages_live((jl_value_t*)caller))
            ins = set_next_edge(backedges, ins, invokeTypes, caller);
    }
    jl_array_del_end(backedges, n - ins);
}

static void jl_prune_tn_backedges(jl_array_t *backedges)
{
    size_t i = 0, ins = 0, n = jl_array_nrows(backedges);
    for (i = 1; i < n; i += 2) {
        jl_value_t *ci = jl_array_ptr_ref(backedges, i);
        if (reactive_pages_live(ci)) {
            jl_array_ptr_set(backedges, ins++, jl_array_ptr_ref(backedges, i - 1));
            jl_array_ptr_set(backedges, ins++, ci);
        }
    }
    jl_array_del_end(backedges, n - ins);
}

static void jl_prune_mt_backedges(jl_genericmemory_t *allbackedges)
{
    for (size_t i = 0, n = allbackedges->length; i < n; i += 2) {
        jl_value_t *tn = jl_genericmemory_ptr_ref(allbackedges, i);
        jl_value_t *backedges = jl_genericmemory_ptr_ref(allbackedges, i + 1);
        if (tn && tn != jl_nothing && backedges)
            jl_prune_tn_backedges((jl_array_t*)backedges);
    }
}

static void jl_prune_binding_backedges(jl_array_t *backedges)
{
    if (backedges == NULL)
        return;
    size_t i = 0, ins = 0, n = jl_array_nrows(backedges);
    for (i = 0; i < n; i++) {
        jl_value_t *b = jl_array_ptr_ref(backedges, i);
        if (reactive_pages_live(b)) {
            jl_array_ptr_set(backedges, ins, b);
            ins++;
        }
    }
    jl_array_del_end(backedges, n - ins);
}

// A weak list of a module (reactive_queue_weak_list): keep the serialized
// members.
static void reactive_prune_weak_list(jl_value_t *list)
{
    if (list != jl_nothing)
        jl_prune_binding_backedges((jl_array_t*)list);
}

// The interference set of a method (weak, see jl_insert_into_serialization_queue):
// keep the serialized members at the front, the rest of the memory null, the
// layout of the set (idset.c).
static void reactive_prune_interferences(jl_method_t *m)
{
    jl_genericmemory_t *keys = jl_atomic_load_relaxed(&m->interferences);
    size_t ins = 0, n = keys->length;
    for (size_t i = 0; i < n; i++) {
        jl_value_t *k = jl_genericmemory_ptr_ref(keys, i);
        if (k == NULL)
            break;
        if (reactive_pages_live(k))
            jl_genericmemory_ptr_set(keys, ins++, k);
    }
    for (; ins < n; ins++)
        jl_genericmemory_ptr_set(keys, ins, NULL);
}

uint_t bindingkey_hash(size_t idx, jl_value_t *data);
uint_t speccache_hash(size_t idx, jl_value_t *data);

static void jl_prune_idset(_Atomic(jl_svec_t*) *pkeys, _Atomic(jl_genericmemory_t*) *pkeyset, uint_t (*key_hash)(size_t, jl_value_t*), jl_value_t *parent) JL_GC_DISABLED
{
    jl_svec_t *keys = jl_atomic_load_relaxed(pkeys);
    size_t l = jl_svec_len(keys), i;
    if (l == 0)
        return;
    arraylist_t keys_list;
    arraylist_new(&keys_list, 0);
    for (i = 0; i < l; i++) {
        jl_value_t *k = jl_svecref(keys, i);
        if (k == jl_nothing)
            continue;
        if (ptrhash_get(&serialization_order, k) != HT_NOTFOUND)
            arraylist_push(&keys_list, k);
    }
    jl_genericmemory_t *keyset = jl_atomic_load_relaxed(pkeyset);
    _Atomic(jl_genericmemory_t*)keyset2;
    jl_atomic_store_relaxed(&keyset2, (jl_genericmemory_t*)jl_an_empty_memory_any);
    jl_svec_t *keys2 = jl_alloc_svec_uninit(keys_list.len);
    for (i = 0; i < keys_list.len; i++) {
        jl_binding_t *ref = (jl_binding_t*)keys_list.items[i];
        jl_svecset(keys2, i, ref);
        jl_smallintset_insert(&keyset2, parent, key_hash, i, (jl_value_t*)keys2);
    }
    void *idx = ptrhash_get(&serialization_order, keys);
    assert(idx != HT_NOTFOUND && idx != (void*)(uintptr_t)-1);
    assert(serialization_queue.items[(char*)idx - 1 - (char*)HT_NOTFOUND] == keys);
    ptrhash_put(&serialization_order, keys2, idx);
    serialization_queue.items[(char*)idx - 1 - (char*)HT_NOTFOUND] = keys2;

    idx = ptrhash_get(&serialization_order, keyset);
    assert(idx != HT_NOTFOUND && idx != (void*)(uintptr_t)-1);
    assert(serialization_queue.items[(char*)idx - 1 - (char*)HT_NOTFOUND] == keyset);
    ptrhash_put(&serialization_order, jl_atomic_load_relaxed(&keyset2), idx);
    serialization_queue.items[(char*)idx - 1 - (char*)HT_NOTFOUND] = jl_atomic_load_relaxed(&keyset2);
    jl_atomic_store_relaxed(pkeys, keys2);
    jl_gc_wb(parent, keys2);
    jl_atomic_store_relaxed(pkeyset, jl_atomic_load_relaxed(&keyset2));
    jl_gc_wb(parent, jl_atomic_load_relaxed(&keyset2));
}

static void jl_prune_method_specializations(jl_method_t *m) JL_GC_DISABLED
{
    jl_value_t *specializations_ = jl_atomic_load_relaxed(&m->specializations);
    if (!jl_is_svec(specializations_)) {
        if (ptrhash_get(&serialization_order, specializations_) == HT_NOTFOUND)
            record_field_change((jl_value_t **)&m->specializations, (jl_value_t*)jl_emptysvec);
        return;
    }
    jl_prune_idset((_Atomic(jl_svec_t*)*)&m->specializations, &m->speckeyset, speccache_hash, (jl_value_t*)m);
}

static void jl_prune_module_bindings(jl_module_t *m) JL_GC_DISABLED
{
    jl_prune_idset(&m->bindings, &m->bindingkeyset, bindingkey_hash, (jl_value_t*)m);
}

static void strip_slotnames(jl_array_t *slotnames, int n)
{
    // replace slot names with `?`, except unused_sym since the compiler looks at it
    jl_sym_t *questionsym = jl_symbol("?");
    int i;
    for (i = 0; i < n; i++) {
        jl_value_t *s = jl_array_ptr_ref(slotnames, i);
        if (s != (jl_value_t*)jl_unused_sym)
            jl_array_ptr_set(slotnames, i, questionsym);
    }
}

static jl_value_t *strip_codeinfo_meta(jl_method_t *m, jl_value_t *ci_, jl_code_instance_t *codeinst)
{
    jl_code_info_t *ci = NULL;
    JL_GC_PUSH1(&ci);
    int compressed = 0;
    if (!jl_is_code_info(ci_)) {
        compressed = 1;
        ci = jl_uncompress_ir(m, codeinst, (jl_value_t*)ci_);
    }
    else {
        ci = (jl_code_info_t*)ci_;
    }
    strip_slotnames(ci->slotnames, jl_array_len(ci->slotnames));
    ci->debuginfo = jl_nulldebuginfo;
    jl_gc_wb(ci, ci->debuginfo);
    jl_value_t *ret = (jl_value_t*)ci;
    if (compressed)
        ret = (jl_value_t*)jl_compress_ir(m, ci);
    JL_GC_POP();
    return ret;
}

static void strip_specializations_(jl_method_instance_t *mi)
{
    assert(jl_is_method_instance(mi));
    jl_code_instance_t *codeinst = jl_atomic_load_relaxed(&mi->cache);
    while (codeinst) {
        jl_value_t *inferred = jl_atomic_load_relaxed(&codeinst->inferred);
        if (inferred && inferred != jl_nothing && !jl_is_uint8(inferred)) {
            if (jl_options.strip_ir) {
                record_field_change((jl_value_t**)&codeinst->inferred, jl_nothing);
            }
            else if (jl_options.strip_metadata) {
                jl_value_t *stripped = strip_codeinfo_meta(mi->def.method, inferred, codeinst);
                if (jl_atomic_cmpswap_relaxed(&codeinst->inferred, &inferred, stripped)) {
                    jl_gc_wb(codeinst, stripped);
                }
            }
        }
        if (jl_options.strip_ir)
            record_field_change((jl_value_t**)&codeinst->edges, (jl_value_t*)jl_emptysvec);
        if (jl_options.strip_metadata)
            record_field_change((jl_value_t**)&codeinst->debuginfo, (jl_value_t*)jl_nulldebuginfo);
        codeinst = jl_atomic_load_relaxed(&codeinst->next);
    }
    if (jl_options.trim || jl_options.strip_ir) {
        record_field_change((jl_value_t**)&mi->backedges, NULL);
    }
}

static int strip_all_codeinfos__(jl_typemap_entry_t *def, void *_env)
{
    jl_method_t *m = def->func.method;
    if (m->source) {
        int stripped_ir = 0;
        if (jl_options.strip_ir) {
            int should_strip_ir = jl_options.trim;
            if (!should_strip_ir) {
                if (jl_atomic_load_relaxed(&m->unspecialized)) {
                    jl_code_instance_t *unspec = jl_atomic_load_relaxed(&jl_atomic_load_relaxed(&m->unspecialized)->cache);
                    if (unspec && jl_atomic_load_relaxed(&unspec->invoke)) {
                        // we have a generic compiled version, so can remove the IR
                        should_strip_ir = 1;
                    }
                }
            }
            if (!should_strip_ir) {
                int mod_setting = jl_get_module_compile(m->module);
                if (!(mod_setting == JL_OPTIONS_COMPILE_OFF || mod_setting == JL_OPTIONS_COMPILE_MIN)) {
                    // if the method is declared not to be compiled, keep IR for interpreter
                    should_strip_ir = 1;
                }
            }
            if (should_strip_ir) {
                record_field_change(&m->source, jl_nothing);
                record_field_change((jl_value_t**)&m->roots, NULL);
                stripped_ir = 1;
            }
        }
        if (jl_options.strip_metadata) {
            if (!stripped_ir) {
                m->source = strip_codeinfo_meta(m, m->source, NULL);
                jl_gc_wb(m, m->source);
            }
            jl_array_t *slotnames = jl_uncompress_argnames(m->slot_syms);
            JL_GC_PUSH1(&slotnames);
            int tostrip = jl_array_len(slotnames);
            // for keyword methods, strip only nargs to keep the keyword names at the end for reflection
            if (jl_tparam0(jl_unwrap_unionall(m->sig)) == (jl_value_t*)jl_kwcall_type)
                tostrip = m->nargs;
            strip_slotnames(slotnames, tostrip);
            m->slot_syms = jl_compress_argnames(slotnames);
            jl_gc_wb(m, m->slot_syms);
            JL_GC_POP();
        }
    }
    if (jl_options.strip_metadata) {
        record_field_change((jl_value_t**)&m->file, (jl_value_t*)jl_empty_sym);
        m->line = 0;
        record_field_change((jl_value_t**)&m->debuginfo, (jl_value_t*)jl_nulldebuginfo);
    }
    jl_value_t *specializations = jl_atomic_load_relaxed(&m->specializations);
    if (!jl_is_svec(specializations)) {
        strip_specializations_((jl_method_instance_t*)specializations);
    }
    else {
        size_t i, l = jl_svec_len(specializations);
        for (i = 0; i < l; i++) {
            jl_value_t *mi = jl_svecref(specializations, i);
            if (mi != jl_nothing)
                strip_specializations_((jl_method_instance_t*)mi);
        }
    }
    if (jl_atomic_load_relaxed(&m->unspecialized))
        strip_specializations_(jl_atomic_load_relaxed(&m->unspecialized));
    if (jl_options.strip_ir && m->root_blocks)
        record_field_change((jl_value_t**)&m->root_blocks, NULL);
    return 1;
}

static int strip_all_codeinfos_mt(jl_methtable_t *mt, void *_env)
{
    return jl_typemap_visitor(jl_atomic_load_relaxed(&mt->defs), strip_all_codeinfos__, NULL);
}

static void jl_strip_all_codeinfos(jl_array_t *mod_array)
{
    jl_foreach_reachable_mtable(strip_all_codeinfos_mt, mod_array, NULL);
}

static int strip_module(jl_module_t *m, jl_sym_t *docmeta_sym)
{
    size_t world = jl_atomic_load_relaxed(&jl_world_counter);
    jl_svec_t *table = jl_atomic_load_relaxed(&m->bindings);
    for (size_t i = 0; i < jl_svec_len(table); i++) {
        jl_binding_t *b = (jl_binding_t*)jl_svecref(table, i);
        if ((void*)b == jl_nothing)
            break;
        jl_sym_t *name = b->globalref->name;
        jl_value_t *v = jl_get_binding_value_in_world(b, world);
        if (v) {
            if (jl_is_module(v)) {
                jl_module_t *child = (jl_module_t*)v;
                if (child != m && child->parent == m && child->name == name) {
                    // this is the original/primary binding for the submodule
                    if (!strip_module(child, docmeta_sym))
                        return 0;
                }
            }
        }
        if (name == docmeta_sym) {
            if (jl_atomic_load_relaxed(&b->value))
                record_field_change((jl_value_t**)&b->value, jl_nothing);
            // TODO: this is a pretty stupidly unsound way to do this, but it is way to late here to do this correctly (by calling delete_binding and getting an updated world age then dropping all partitions from older worlds)
            jl_binding_partition_t *bp = jl_atomic_load_relaxed(&b->partitions);
            while (bp) {
                if (jl_bkind_is_defined_constant(jl_binding_kind(bp))) {
                    // XXX: bp->kind = PARTITION_KIND_UNDEF_CONST;
                    record_field_change((jl_value_t**)&bp->restriction, NULL);
                }
                bp = jl_atomic_load_relaxed(&bp->next);
            }
        }
    }
    return 1;
}


static void jl_strip_all_docmeta(jl_array_t *mod_array)
{
    jl_sym_t *docmeta_sym = NULL;
    if (jl_base_module) {
        jl_value_t *docs = jl_get_global(jl_base_module, jl_symbol("Docs"));
        if (docs && jl_is_module(docs)) {
            docmeta_sym = (jl_sym_t*)jl_get_global((jl_module_t*)docs, jl_symbol("META"));
        }
    }
    if (!docmeta_sym)
        return;
    for (size_t i = 0; i < jl_array_nrows(mod_array); i++) {
        jl_module_t *m = (jl_module_t*)jl_array_ptr_ref(mod_array, i);
        assert(jl_is_module(m));
        if (m->parent == m) // some toplevel modules (really just Base) aren't actually
            strip_module(m, docmeta_sym);
    }
}

// --- entry points ---

jl_genericmemory_t *jl_global_roots_list;
jl_genericmemory_t *jl_global_roots_keyset;
jl_mutex_t global_roots_lock;

jl_mutex_t precompile_field_replace_lock;
jl_svec_t *precompile_field_replace JL_GLOBALLY_ROOTED;

static inline jl_value_t *get_checked_fieldindex(const char *name, jl_datatype_t *st, jl_value_t *v, jl_value_t *arg, int mutabl)
{
    if (mutabl) {
        if (st == jl_module_type)
            jl_error("cannot assign variables in other modules");
        if (!st->name->mutabl)
            jl_errorf("%s: immutable struct of type %s cannot be changed", name, jl_symbol_name(st->name->name));
    }
    size_t idx;
    if (jl_is_long(arg)) {
        idx = jl_unbox_long(arg) - 1;
        if (idx >= jl_datatype_nfields(st))
            jl_bounds_error(v, arg);
    }
    else if (jl_is_symbol(arg)) {
        idx = jl_field_index(st, (jl_sym_t*)arg, 1);
        arg = jl_box_long(idx);
    }
    else {
        jl_value_t *ts[2] = {(jl_value_t*)jl_long_type, (jl_value_t*)jl_symbol_type};
        jl_value_t *t = jl_type_union(ts, 2);
        jl_type_error(name, t, arg);
    }
    if (mutabl && jl_field_isconst(st, idx)) {
        jl_errorf("%s: const field .%s of type %s cannot be changed", name,
                jl_symbol_name((jl_sym_t*)jl_svecref(jl_field_names(st), idx)), jl_symbol_name(st->name->name));
    }
    return arg;
}

JL_DLLEXPORT void jl_set_precompile_field_replace(jl_value_t *val, jl_value_t *field, jl_value_t *newval)
{
    if (!jl_generating_output())
        return;
    jl_datatype_t *st = (jl_datatype_t*)jl_typeof(val);
    jl_value_t *idx = get_checked_fieldindex("setfield!", st, val, field, 1);
    JL_GC_PUSH1(&idx);
    size_t idxval = jl_unbox_long(idx);
    jl_value_t *ft = jl_field_type_concrete(st, idxval);
    if (!jl_isa(newval, ft))
        jl_type_error("setfield!", ft, newval);
    JL_LOCK(&precompile_field_replace_lock);
    if (precompile_field_replace == NULL) {
        precompile_field_replace = jl_alloc_svec(3);
        jl_svecset(precompile_field_replace, 0, jl_alloc_vec_any(0));
        jl_svecset(precompile_field_replace, 1, jl_alloc_vec_any(0));
        jl_svecset(precompile_field_replace, 2, jl_alloc_vec_any(0));
    }
    jl_array_ptr_1d_push((jl_array_t*)jl_svecref(precompile_field_replace, 0), val);
    jl_array_ptr_1d_push((jl_array_t*)jl_svecref(precompile_field_replace, 1), idx);
    jl_array_ptr_1d_push((jl_array_t*)jl_svecref(precompile_field_replace, 2), newval);
    JL_GC_POP();
    JL_UNLOCK(&precompile_field_replace_lock);
}


JL_DLLEXPORT int jl_is_globally_rooted(jl_value_t *val JL_MAYBE_UNROOTED) JL_NOTSAFEPOINT
{
    if (jl_is_datatype(val)) {
        jl_datatype_t *dt = (jl_datatype_t*)val;
        if (jl_unwrap_unionall(dt->name->wrapper) == val)
            return 1;
        return (jl_is_tuple_type(val) ? dt->isconcretetype : !dt->hasfreetypevars); // aka is_cacheable from jltypes.c
    }
    if (jl_is_bool(val) || jl_is_symbol(val) ||
            val == (jl_value_t*)jl_any_type || val == (jl_value_t*)jl_bottom_type || val == (jl_value_t*)jl_core_module)
        return 1;
    if (val == ((jl_datatype_t*)jl_typeof(val))->instance)
        return 1;
    return 0;
}

static jl_value_t *extract_wrapper(jl_value_t *t JL_PROPAGATES_ROOT) JL_NOTSAFEPOINT JL_GLOBALLY_ROOTED
{
    t = jl_unwrap_unionall(t);
    if (jl_is_datatype(t))
        return ((jl_datatype_t*)t)->name->wrapper;
    return NULL;
}

JL_DLLEXPORT jl_value_t *jl_as_global_root(jl_value_t *val, int insert)
{
    if (jl_is_globally_rooted(val))
        return val;
    jl_value_t *tw = extract_wrapper(val);
    if (tw && (val == tw || jl_types_egal(val, tw)))
        return tw;
    if (jl_is_uint8(val))
        return jl_box_uint8(jl_unbox_uint8(val));
    if (jl_is_int32(val)) {
        int32_t n = jl_unbox_int32(val);
        if ((uint32_t)(n+512) < 1024)
            return jl_box_int32(n);
    }
    else if (jl_is_int64(val)) {
        uint64_t n = jl_unbox_uint64(val);
        if ((uint64_t)(n+512) < 1024)
            return jl_box_int64(n);
    }
    // check table before acquiring lock to reduce writer contention
    jl_value_t *rval = jl_idset_get(jl_global_roots_list, jl_global_roots_keyset, val);
    if (rval)
        return rval;
    JL_LOCK(&global_roots_lock);
    rval = jl_idset_get(jl_global_roots_list, jl_global_roots_keyset, val);
    if (rval) {
        val = rval;
    }
    else if (insert) {
        ssize_t idx;
        jl_global_roots_list = jl_idset_put_key(jl_global_roots_list, val, &idx);
        jl_global_roots_keyset = jl_idset_put_idx(jl_global_roots_list, jl_global_roots_keyset, idx);
    }
    else {
        val = NULL;
    }
    JL_UNLOCK(&global_roots_lock);
    return val;
}

// Companion to jl_collect_methtable_from_mod: method tables owned by the worklist
// are serialized without their contents, since all of their (currently valid)
// methods were collected as extext methods, to be re-added and re-activated on
// load by jl_add_methods / jl_activate_methods, which also restores their
// dispatch status.
static int jl_prune_internal_mtable(jl_methtable_t *mt, void *env)
{
    (void)env;
    if (jl_object_in_image((jl_value_t*)mt))
        return 1;
    record_field_change((jl_value_t**)&mt->defs, jl_nothing);
    jl_methcache_t *mc = mt->cache;
    record_field_change((jl_value_t**)&mc->cache, jl_nothing);
    record_field_change((jl_value_t**)&mc->leafcache, jl_an_empty_memory_any);
    return 1;
}

// In addition to the system image (where `worklist = NULL`), this can also save incremental images with external linkage
// JULIA_REACTIVE_HEAPDUMP (reactive_dump_heap): the head of an object.
static void reactive_describe(ios_t *dump, jl_value_t *v)
{
    if (jl_is_symbol(v))
        ios_printf(dump, "%s", jl_symbol_name((jl_sym_t*)v));
    else if (jl_is_string(v)) {
        const char *data = jl_string_data(v);
        for (size_t k = 0; k < jl_string_len(v) && k < 100; k++)
            ios_putc(data[k] >= 0x20 && data[k] < 0x7f ? data[k] : '.', dump);
    }
    else if (jl_is_module(v)) {
        jl_module_t *m = (jl_module_t*)v;
        ios_printf(dump, "%s.%s", jl_symbol_name(m->parent->name), jl_symbol_name(m->name));
    }
    else if (jl_is_method(v)) {
        jl_method_t *m = (jl_method_t*)v;
        ios_printf(dump, "%s.%s %s:%d w%zu status %d", jl_symbol_name(m->module->name), jl_symbol_name(m->name),
                   jl_symbol_name(m->file), m->line, jl_atomic_load_relaxed(&m->primary_world),
                   jl_atomic_load_relaxed(&m->dispatch_status));
    }
    else if (jl_is_method_instance(v)) {
        jl_method_instance_t *mi = (jl_method_instance_t*)v;
        if (jl_is_method(mi->def.value))
            ios_printf(dump, "%s.%s", jl_symbol_name(mi->def.method->module->name), jl_symbol_name(mi->def.method->name));
    }
    else if (jl_is_code_instance(v)) {
        jl_code_instance_t *ci = (jl_code_instance_t*)v;
        if (jl_is_method_instance(ci->def) && jl_is_method(((jl_method_instance_t*)ci->def)->def.value))
            ios_printf(dump, "%s.%s", jl_symbol_name(((jl_method_instance_t*)ci->def)->def.method->module->name),
                       jl_symbol_name(((jl_method_instance_t*)ci->def)->def.method->name));
        ios_printf(dump, " w%zu:%zu", jl_atomic_load_relaxed(&ci->min_world), jl_atomic_load_relaxed(&ci->max_world));
    }
    else if (jl_is_datatype(v)) {
        jl_datatype_t *dt = (jl_datatype_t*)v;
        ios_printf(dump, "%s.%s", jl_symbol_name(dt->name->module->name), jl_symbol_name(dt->name->name));
    }
    else if (jl_is_typename(v)) {
        jl_typename_t *tn = (jl_typename_t*)v;
        ios_printf(dump, "%s.%s", jl_symbol_name(tn->module->name), jl_symbol_name(tn->name));
    }
    else if (jl_is_binding(v)) {
        jl_binding_t *b = (jl_binding_t*)v;
        if (b->globalref)
            ios_printf(dump, "%s.%s", jl_symbol_name(b->globalref->mod->name), jl_symbol_name(b->globalref->name));
    }
    else if (jl_typetagis(v, jl_typemap_entry_type)) {
        jl_typemap_entry_t *e = (jl_typemap_entry_t*)v;
        ios_printf(dump, "w%zu:%zu", jl_atomic_load_relaxed(&e->min_world), jl_atomic_load_relaxed(&e->max_world));
    }
    else if (jl_is_genericmemory(v))
        ios_printf(dump, "%zu", ((jl_genericmemory_t*)v)->length);
}

// JULIA_REACTIVE_HEAPDUMP=<path>: one line per object of the heap: its
// address, its type, its size, its head, and after `<-` the address, the
// type and the head of the object that reached it first. A tool of the reactive format: the difference
// between the dumps of two rebuilds names what a rebuild keeps, and the
// referrer names why.
static void reactive_dump_heap(const char *path)
{
    ios_t dump;
    if (ios_file(&dump, path, 1, 1, 1, 1) != NULL) {
        for (size_t i = 0; i < serialization_queue.len; i++) {
            jl_value_t *v = (jl_value_t*)serialization_queue.items[i];
            jl_datatype_t *t = (jl_datatype_t*)jl_typeof(v);
            size_t sz = jl_is_genericmemory(v) ? ((jl_genericmemory_t*)v)->length * jl_datatype_layout(t)->size :
                        jl_is_string(v) ? jl_string_len(v) : jl_datatype_size(t);
            ios_printf(&dump, "%p | %s | %zu | ", (void*)v, jl_typeof_str(v), sz);
            reactive_describe(&dump, v);
            jl_value_t *parent = (jl_value_t*)ptrhash_get(&reactive_dump_parents, v);
            if (parent != HT_NOTFOUND && parent != jl_nothing) {
                ios_printf(&dump, " <- %p %s ", (void*)parent, jl_typeof_str(parent));
                reactive_describe(&dump, parent);
            }
            ios_putc('\n', &dump);
        }
        ios_close(&dump);
    }
}

// ── the page write: the base ───────────────────────────────────────────

struct reactive_phdr_query {
    uintptr_t addr;
    uintptr_t file_off;
    int found;
};

static int reactive_phdr_callback(struct dl_phdr_info *info, size_t size, void *data) JL_NOTSAFEPOINT
{
    struct reactive_phdr_query *q = (struct reactive_phdr_query*)data;
    for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD)
            continue;
        uintptr_t start = info->dlpi_addr + ph->p_vaddr;
        if (q->addr >= start && q->addr < start + ph->p_filesz) {
            q->file_off = ph->p_offset + (q->addr - start);
            q->found = 1;
            return 1;
        }
    }
    return 0;
}

// Read a list of positions, delta-coded as jl_write_offsetlist writes them.
static const uint8_t *reactive_base_read_positions(const uint8_t *cur, arraylist_t *out) JL_NOTSAFEPOINT
{
    size_t last = 0;
    while (1) {
        size_t diff = 0, cnt = 0;
        while (1) {
            int8_t c = (int8_t)*cur++;
            diff |= ((size_t)c & 0x7F) << (7 * cnt++);
            if ((c >> 7) == 0)
                break;
        }
        if (diff == 0)
            break;
        last += diff;
        arraylist_push(out, (void*)last);
    }
    return cur;
}

// The lists of the loaded state, decoded from a relocs section: the
// object index (gc tags) and the relocation lists the next save merges.
static void reactive_base_lists_from(const char *relocs, size_t size)
{
    reactive_base_t *b = &reactive_base;
    if (reactive_base_lists_ready) {
        arraylist_free(&b->gctags);
        arraylist_free(&b->relocs_list);
        arraylist_free(&b->memowner);
        arraylist_free(&b->memref);
        arraylist_free(&b->fixups);
    }
    arraylist_new(&b->gctags, 0);
    arraylist_new(&b->relocs_list, 0);
    arraylist_new(&b->memowner, 0);
    arraylist_new(&b->memref, 0);
    arraylist_new(&b->fixups, 0);
    const uint8_t *cur = (const uint8_t*)relocs;
    cur = reactive_base_read_positions(cur, &b->gctags);
    cur = reactive_base_read_positions(cur, &b->relocs_list);
    cur = reactive_base_read_positions(cur, &b->memowner);
    cur = reactive_base_read_positions(cur, &b->memref);
    size_t nfixups = *(const uintptr_t*)cur;
    cur += sizeof(uintptr_t);
    arraylist_grow(&b->fixups, nfixups);
    memcpy(b->fixups.items, cur, nfixups * sizeof(void*));
    (void)size;
    reactive_base_lists_ready = 1;
}

// Map the file bytes of the base image's blob and locate its sections and
// lists. Answers 0 when the base has no file (a compressed image, or no
// image), and the save writes whole.
// The file that holds the blob at `addr`, and the blob's offset in it.
static int reactive_blob_file(const void *addr, const char **fname, size_t *file_off) JL_NOTSAFEPOINT
{
    Dl_info info;
    if (!dladdr(addr, &info) || info.dli_fname == NULL)
        return 0;
    struct reactive_phdr_query q = { (uintptr_t)addr, 0, 0 };
    dl_iterate_phdr(reactive_phdr_callback, &q);
    if (!q.found)
        return 0;
    *fname = info.dli_fname;
    *file_off = q.file_off;
    return 1;
}

static int reactive_base_map(void)
{
    if (reactive_base_mapped)
        return 1;
    if (reactive_blob_data == NULL || reactive_sysimg_size == 0)
        return 0;
    const char *fname = NULL;
    size_t file_off = 0;
    if (!reactive_blob_file(reactive_blob_data, &fname, &file_off))
        return 0;
    int fd = open(fname, O_RDONLY);
    if (fd < 0)
        return 0;
    size_t page = jl_page_size;
    size_t off = file_off & ~(page - 1);
    size_t delta = file_off - off;
    size_t len = delta + reactive_blob_size;
    char *map = (char*)mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, off);
    close(fd);
    if (map == MAP_FAILED)
        return 0;
    reactive_base_t *b = &reactive_base;
    memset(b, 0, sizeof(*b));
    b->map = map;
    b->map_len = len;
    reactive_sections_t sec;
    if (!reactive_parse_blob(map + delta, reactive_blob_size, &sec)) {
        munmap(map, len);
        return 0;
    }
    b->sysimg = sec.sysimg.ptr;
    b->sysimg_size = sec.sysimg.size;
    b->const_data = sec.const_data.ptr;
    b->const_size = sec.const_data.size;
    b->symbols = sec.symbols.ptr;
    b->symbols_size = sec.symbols.size;
    b->relocs = sec.relocs.ptr;
    b->relocs_size = sec.relocs.size;
    if (b->sysimg_size != reactive_sysimg_size || b->const_size != reactive_const_len ||
        b->symbols_size != reactive_syms_len) {
        jl_safe_printf("reactive: pages: the file of the base image does not match the loaded image\n");
        munmap(map, len);
        return 0;
    }
    reactive_base_lists_from(b->relocs, b->relocs_size);
    reactive_base_mapped = 1;
    return 1;
}

// Begin a page write: the snapshot of the dirty bitmap, the base in the
// three streams the save appends to, and the base symbols in the table.
static int reactive_pages_begin(ios_t *sysimg, ios_t *const_data, ios_t *symbols)
{
    reactive_overlay_on = 0;
    if (reactive_overlay_mode()) {
        // An overlay writes the dirty pages and the new objects only: the
        // buffer starts from memory, and the lists of the loaded state
        // came with the chain.
        if (reactive_base_lists_pending) {
            reactive_base_lists_from(reactive_sections.relocs.ptr, reactive_sections.relocs.size);
            reactive_base_lists_pending = 0;
        }
        if (!reactive_base_lists_ready || reactive_region_base == NULL) {
            jl_safe_printf("reactive: overlay: the loaded image has no region; the save writes whole\n");
            return -1;
        }
        reactive_overlay_on = 1;
    }
    else if (!reactive_base_map()) {
        jl_safe_printf("reactive: pages: the base image has no file bytes; the save writes whole\n");
        return -1;
    }
    if (reactive_dirty_bits == NULL || !reactive_base_syms_kept) {
        jl_safe_printf("reactive: pages: the loader tracked no pages; the save writes whole\n");
        return -1;
    }
    reactive_pages_bits = (uint8_t*)malloc_s(reactive_dirty_npages);
    memcpy(reactive_pages_bits, reactive_dirty_bits, reactive_dirty_npages);
    reactive_pages_ndirty = 0;
    size_t restored = 0;
    for (size_t i = 0; i < reactive_dirty_npages; i++) {
        if (reactive_pages_bits[i] && reactive_page_hashes != NULL &&
            reactive_page_hash(reactive_dirty_start + i * jl_page_size) == reactive_page_hashes[i]) {
            reactive_pages_bits[i] = 0;
            restored++;
        }
        reactive_pages_ndirty += reactive_pages_bits[i];
    }
    if (jl_reactive_timings())
        jl_safe_printf("reactive: pages: %zu pages written, %zu of them as at the load\n",
                       reactive_pages_ndirty + restored, restored);
    reactive_pages_rewritten = (uint8_t*)calloc(reactive_base.gctags.len, 1);
    reactive_pages_nrewritten = 0;
    if (reactive_overlay_on) {
        // The buffers hold the base's extent, but only the dirty pages are
        // written from them: they are zeroed, and the rewrite of every
        // object on them fills them; the const pages come from memory.
        size_t page = jl_page_size;
        ios_trunc(sysimg, reactive_sysimg_size);
        for (size_t off = 0; off < reactive_sysimg_size; off += page) {
            char *addr = reactive_image_base + off;
            if (addr >= reactive_region_const && addr < reactive_region_const_limit)
                continue;
            if (reactive_pages_dirty(addr))
                memset(sysimg->buf + off, 0, off + page <= reactive_sysimg_size ? page : reactive_sysimg_size - off);
        }
        reactive_pages_append = reactive_sysimg_size;
        reactive_base.sysimg_size = reactive_objects_end;
        ios_trunc(const_data, reactive_const_len);
        for (size_t off = 0; off < reactive_const_len; off += page) {
            if (reactive_pages_dirty(reactive_const_base + off))
                memcpy(const_data->buf + off, reactive_const_base + off,
                       off + page <= reactive_const_len ? page : reactive_const_len - off);
        }
    }
    else {
        ios_write(sysimg, reactive_base.sysimg, reactive_base.sysimg_size);
        reactive_pages_append = reactive_base.sysimg_size;
        ios_write(const_data, reactive_const_base, reactive_const_len);
    }
    reactive_pages_const_append = reactive_const_len;
    // The const data comes from memory, with the runtime's writes into the
    // bits memories; a pointer element is null in an image, as the whole
    // write makes it (a match context of PCRE, a handle): reset them.
    {
        arraylist_t *tags = &reactive_base.gctags;
        size_t reset = 0;
        for (size_t i = 0; i < tags->len; i++) {
            jl_value_t *v = (jl_value_t*)(reactive_image_base + (size_t)tags->items[i] + sizeof(jl_taggedvalue_t));
            if (!jl_is_genericmemory(v))
                continue;
            jl_datatype_t *t = (jl_datatype_t*)jl_typeof(v);
            const jl_datatype_layout_t *layout = t->layout;
            if (layout->flags.arrayelem_isboxed || layout->first_ptr >= 0)
                continue;
            if (!jl_is_cpointer_type(jl_tparam1(t)))
                continue;
            jl_genericmemory_t *m = (jl_genericmemory_t*)v;
            if (!reactive_in_const(m->ptr))
                continue;
            intptr_t *out = (intptr_t*)&const_data->buf[(const char*)m->ptr - reactive_const_base];
            const intptr_t *in = (const intptr_t*)m->ptr;
            for (size_t k = 0; k < m->length; k++) {
                if (in[k] != -1 && out[k] != 0) {
                    out[k] = 0;
                    reset++;
                }
            }
        }
        if (jl_reactive_timings())
            jl_safe_printf("reactive: pages: %zu pointer elements of the base reset\n", reset);
    }
    ios_write(symbols, reactive_syms_base, reactive_syms_len);
    for (size_t i = 0; i < reactive_base_syms.len; i++)
        ptrhash_put(&symbol_table, reactive_base_syms.items[i], to_seroder_entry(i));
    nsym_tag = reactive_base_syms.len;
    reactive_pages_refusal = NULL;
    reactive_pages_on = 1;
    return 0;
}

static void reactive_pages_end(void)
{
    free(reactive_pages_bits);
    reactive_pages_bits = NULL;
    free(reactive_pages_rewritten);
    reactive_pages_rewritten = NULL;
    reactive_pages_on = 0;
    reactive_pages_force = 0;
    reactive_overlay_on = 0;
}

// The pages of `lo..lo+len` that this save writes: their indices in `out`.
// The const data and its headroom lie inside the sysimg extent of the
// region; the sysimg loop leaves them to the const loop.
static size_t reactive_overlay_dirty_pages(const char *lo, size_t len, arraylist_t *out, int skip_const)
{
    size_t page = jl_page_size;
    size_t n = (len + page - 1) / page;
    for (size_t k = 0; k < n; k++) {
        const char *addr = lo + k * page;
        if (skip_const && addr >= reactive_region_const && addr < reactive_region_const_limit)
            continue;
        if (reactive_pages_dirty(addr))
            arraylist_push(out, (void*)k);
    }
    return out->len;
}

static void reactive_overlay_align(ios_t *f, size_t a)
{
    size_t rel = ios_pos(f) - reactive_overlay_blob_start;
    write_padding(f, LLT_ALIGN(rel, a) - rel);
}

// Write the overlay blob: the header (completed after the roots), the page
// patches of the sysimg and the const data, the new objects, the new
// symbols, the lists and the records. The offsets are relative to the blob.
static void reactive_overlay_emit(ios_t *f, ios_t *sysimg, ios_t *const_data, ios_t *symbols,
                                  ios_t *relocs, ios_t *gvar, ios_t *fptr, uint32_t external_fns_begin)
{
    size_t page = jl_page_size;
    reactive_overlay_header_t *h = &reactive_overlay_header;
    memset(h, 0, sizeof(*h));
    h->magic = REACTIVE_OVERLAY_MAGIC;
    h->page_size = page;
    h->base_sysimg_size = reactive_sysimg_size;
    h->base_const_size = reactive_const_len;
    h->base_syms_size = reactive_syms_len;
    h->external_fns_begin = external_fns_begin;
    h->ngvars = gvar->size / sizeof(reloc_t);
    reactive_overlay_blob_start = ios_pos(f);
    ios_write(f, (const char*)h, sizeof(*h));
    // the dirty pages of the sysimg
    arraylist_t idx;
    arraylist_new(&idx, 0);
    reactive_overlay_dirty_pages(reactive_image_base, reactive_sysimg_size, &idx, 1);
    h->npatch_sysimg = idx.len;
    reactive_overlay_align(f, 8);
    h->off_patch_idx_sysimg = ios_pos(f) - reactive_overlay_blob_start;
    for (size_t i = 0; i < idx.len; i++)
        write_uint32(f, (uint32_t)(size_t)idx.items[i]);
    reactive_overlay_align(f, page);
    h->off_patch_sysimg = ios_pos(f) - reactive_overlay_blob_start;
    for (size_t i = 0; i < idx.len; i++) {
        size_t off = (size_t)idx.items[i] * page;
        size_t avail = off < sysimg->size ? sysimg->size - off : 0;
        size_t n = avail < page ? avail : page;
        ios_write(f, sysimg->buf + off, n);
        write_padding(f, page - n);
    }
    // the dirty pages of the const data
    arraylist_free(&idx);
    arraylist_new(&idx, 0);
    reactive_overlay_dirty_pages(reactive_const_base, reactive_const_len, &idx, 0);
    h->npatch_const = idx.len;
    reactive_overlay_align(f, 8);
    h->off_patch_idx_const = ios_pos(f) - reactive_overlay_blob_start;
    for (size_t i = 0; i < idx.len; i++)
        write_uint32(f, (uint32_t)(size_t)idx.items[i]);
    reactive_overlay_align(f, page);
    h->off_patch_const = ios_pos(f) - reactive_overlay_blob_start;
    for (size_t i = 0; i < idx.len; i++) {
        size_t off = (size_t)idx.items[i] * page;
        size_t avail = off < const_data->size ? const_data->size - off : 0;
        size_t n = avail < page ? avail : page;
        ios_write(f, const_data->buf + off, n);
        write_padding(f, page - n);
    }
    arraylist_free(&idx);
    // the new objects, symbols, lists and records
    reactive_overlay_align(f, page);
    h->off_new_sysimg = ios_pos(f) - reactive_overlay_blob_start;
    h->new_sysimg_size = sysimg->size - reactive_sysimg_size;
    ios_write(f, sysimg->buf + reactive_sysimg_size, h->new_sysimg_size);
    reactive_overlay_align(f, page);
    h->off_new_const = ios_pos(f) - reactive_overlay_blob_start;
    h->new_const_size = const_data->size - reactive_const_len;
    ios_write(f, const_data->buf + reactive_const_len, h->new_const_size);
    reactive_overlay_align(f, 8);
    h->off_new_syms = ios_pos(f) - reactive_overlay_blob_start;
    h->new_syms_size = symbols->size - reactive_syms_len;
    ios_write(f, symbols->buf + reactive_syms_len, h->new_syms_size);
    reactive_overlay_align(f, 8);
    h->off_relocs = ios_pos(f) - reactive_overlay_blob_start;
    h->relocs_size = relocs->size;
    ios_seek(relocs, 0);
    ios_copyall(f, relocs);
    reactive_overlay_align(f, 8);
    h->off_gvar = ios_pos(f) - reactive_overlay_blob_start;
    h->gvar_size = gvar->size;
    ios_seek(gvar, 0);
    ios_copyall(f, gvar);
    reactive_overlay_align(f, 8);
    h->off_fptr = ios_pos(f) - reactive_overlay_blob_start;
    h->fptr_size = fptr->size;
    ios_seek(fptr, 0);
    ios_copyall(f, fptr);
    if (jl_reactive_timings())
        jl_safe_printf("reactive: overlay: %zu sysimg pages and %zu const pages patched, %zu KB new objects, %zu KB new const, %zu KB lists\n",
                       (size_t)h->npatch_sysimg, (size_t)h->npatch_const, (size_t)h->new_sysimg_size / 1024,
                       (size_t)h->new_const_size / 1024, (size_t)h->relocs_size / 1024);
}

// After the roots: the header gets its last sizes and lands at the front.
static void reactive_overlay_finish(ios_t *f)
{
    reactive_overlay_header_t *h = &reactive_overlay_header;
    h->roots_size = ios_pos(f) - reactive_overlay_blob_start - h->off_roots;
    size_t end = ios_pos(f);
    ios_seek(f, reactive_overlay_blob_start);
    ios_write(f, (const char*)h, sizeof(*h));
    ios_seek(f, end);
}

// Queue the objects of the dirty pages: the objects whose tag is in a dirty
// page, and an object whose bytes reach into one.
static void reactive_pages_queue_dirty(jl_serializer_state *s) JL_GC_DISABLED
{
    arraylist_t *tags = &reactive_base.gctags;
    size_t n = tags->len;
    size_t page = jl_page_size;
    size_t queued = 0;
    reactive_pages_force = 1;
    for (size_t i = 0; i < n; i++) {
        size_t pos = (size_t)tags->items[i];
        char *addr = reactive_image_base + pos;
        int dirty = reactive_pages_dirty(addr);
        if (!dirty) {
            char *next = i + 1 < n ? reactive_image_base + (size_t)tags->items[i + 1]
                                   : reactive_image_base + reactive_base.sysimg_size;
            if (reactive_overlay_on && i + 1 == n)
                next = reactive_image_base + reactive_objects_end;
            if (reactive_overlay_on && pos < reactive_base_end && next > reactive_image_base + reactive_base_end)
                next = reactive_image_base + reactive_base_end;
            for (char *p = (char*)LLT_ALIGN((uintptr_t)addr + 1, page); p < next; p += page) {
                if (reactive_pages_dirty(p)) {
                    dirty = 1;
                    break;
                }
            }
        }
        if (dirty) {
            jl_value_t *v = (jl_value_t*)(addr + sizeof(jl_taggedvalue_t));
            jl_queue_for_serialization(s, v);
            queued++;
        }
    }
    reactive_pages_force = 0;
    if (jl_reactive_timings())
        jl_safe_printf("reactive: pages: %zu dirty pages of %zu, %zu objects of the base queued\n",
                       reactive_pages_ndirty, reactive_dirty_npages, queued);
}

// The fptr record of the code instances of the base that the save did not
// queue: the fresh function table names them by their base offset.
static void reactive_pages_fptrs(jl_serializer_state *s)
{
    if (native_functions == NULL)
        return;
    size_t n = 0;
    jl_get_llvm_cis(native_functions, &n, NULL);
    if (n == 0)
        return;
    jl_code_instance_t **cis = (jl_code_instance_t**)malloc_s(n * sizeof(void*));
    jl_get_llvm_cis(native_functions, &n, cis);
    size_t written = 0;
    for (size_t i = 0; i < n; i++) {
        jl_code_instance_t *ci = cis[i];
        if (!jl_object_in_image((jl_value_t*)ci) || !reactive_in_sysimg(ci))
            continue;
        if (ptrhash_get(&serialization_order, ci) != HT_NOTFOUND)
            continue;
        size_t off = (char*)ci - reactive_image_base;
        int32_t invokeptr_id = 0, specfptr_id = 0;
        jl_get_function_id(native_functions, ci, &invokeptr_id, &specfptr_id);
        if (invokeptr_id > 0) {
            ios_ensureroom(s->fptr_record, invokeptr_id * sizeof(void*));
            ios_seek(s->fptr_record, (invokeptr_id - 1) * sizeof(void*));
            write_reloc_t(s->fptr_record, (reloc_t)~off);
#ifdef _P64
            if (sizeof(reloc_t) < 8)
                write_padding(s->fptr_record, 8 - sizeof(reloc_t));
#endif
        }
        if (specfptr_id > 0) {
            ios_ensureroom(s->fptr_record, specfptr_id * sizeof(void*));
            ios_seek(s->fptr_record, (specfptr_id - 1) * sizeof(void*));
            write_reloc_t(s->fptr_record, off);
#ifdef _P64
            if (sizeof(reloc_t) < 8)
                write_padding(s->fptr_record, 8 - sizeof(reloc_t));
#endif
            written++;
        }
    }
    free(cis);
    if (jl_reactive_timings())
        jl_safe_printf("reactive: pages: %zu functions of the base keep their code instance\n", written);
}

static int reactive_pages_cmp_pos(const void *a, const void *b) JL_NOTSAFEPOINT
{
    size_t x = *(const size_t*)a, y = *(const size_t*)b;
    return x < y ? -1 : x > y ? 1 : 0;
}

static void reactive_pages_write_diff(ios_t *s, size_t pos_diff) JL_NOTSAFEPOINT
{
    while (pos_diff) {
        if (pos_diff <= 127) {
            write_int8(s, pos_diff);
            break;
        }
        int8_t ns = pos_diff & (int8_t)0x7F;
        pos_diff >>= 7;
        ns |= (!!pos_diff) << 7;
        write_int8(s, ns);
    }
}

// Write a list of positions: the entries of the base outside the rewritten
// objects, merged with the entries of this save, ascending.
static void reactive_pages_write_list(ios_t *out, size_t size, arraylist_t *base, arraylist_t *pairs)
{
    size_t nnew = pairs->len / 2;
    size_t *fresh = (size_t*)malloc_s((nnew + 1) * sizeof(size_t));
    for (size_t i = 0; i < nnew; i++)
        fresh[i] = (size_t)pairs->items[2 * i];
    qsort(fresh, nnew, sizeof(size_t), reactive_pages_cmp_pos);
    arraylist_t *tags = &reactive_base.gctags;
    size_t j = 0;           // the base object the base entry belongs to
    size_t k = 0;           // the next fresh entry
    size_t last = 0;
    for (size_t i = 0; i < base->len; i++) {
        size_t pos = (size_t)base->items[i];
        while (j + 1 < tags->len && (size_t)tags->items[j + 1] <= pos)
            j++;
        if (reactive_pages_rewritten[j])
            continue;
        while (k < nnew && fresh[k] < pos) {
            assert(fresh[k] > last);
            reactive_pages_write_diff(out, fresh[k] - last);
            last = fresh[k++];
        }
        assert(pos > last && "a base entry and a fresh entry share a position");
        reactive_pages_write_diff(out, pos - last);
        last = pos;
    }
    while (k < nnew) {
        assert(fresh[k] > last && fresh[k] < size);
        reactive_pages_write_diff(out, fresh[k] - last);
        last = fresh[k++];
    }
    write_int8(out, 0);
    free(fresh);
}

// Write the fixup objects: the base's outside the rewritten objects, then
// this save's.
static void reactive_pages_write_fixups(ios_t *out, arraylist_t *base, arraylist_t *fresh)
{
    arraylist_t merged;
    arraylist_new(&merged, base->len + fresh->len);
    for (size_t i = 0; i < base->len; i++) {
        size_t pos = (size_t)base->items[i];
        size_t j = reactive_base_object_at(pos);
        if (!reactive_pages_rewritten[j])
            arraylist_push(&merged, (void*)pos);
    }
    for (size_t i = 0; i < fresh->len; i++)
        arraylist_push(&merged, fresh->items[i]);
    jl_write_arraylist(out, &merged);
    arraylist_free(&merged);
}

// Answers 0, or -1 when a page write refuses and the caller writes whole.
static int jl_save_system_image_to_stream(ios_t *f, jl_array_t *mod_array,
                                           jl_array_t *module_init_order, jl_array_t *worklist, jl_array_t *extext_methods,
                                           jl_array_t *new_ext_cis, jl_query_cache *query_cache)
{
    htable_new(&field_replace, 0);
    htable_new(&bits_replace, 0);
    if (worklist)
        jl_foreach_reachable_mtable(jl_prune_internal_mtable, mod_array, NULL);
    // A reactive image drops the closed typemap entries and the invalid
    // code instances: the next build must not reuse a deleted method.
    reactive_prune_heap = (worklist == NULL && jl_reactive_image_format());
    if (reactive_prune_heap)
        jl_foreach_reachable_mtable(reactive_prune_mtable, mod_array, NULL);
    // strip metadata and IR when requested
    if (jl_options.strip_metadata || jl_options.strip_ir) {
        if (jl_options.strip_metadata) {
            jl_nulldebuginfo = (jl_debuginfo_t*)jl_get_global(jl_core_module, jl_symbol("NullDebugInfo"));
            if (jl_nulldebuginfo == NULL)
                jl_errorf("Core.NullDebugInfo required for --strip-metadata option");
        }
        jl_strip_all_codeinfos(mod_array);
        jl_strip_all_docmeta(mod_array);
    }
    // collect needed methods and replace method tables that are in the tags array
    htable_new(&new_methtables, 0);
    arraylist_t MIs;
    arraylist_new(&MIs, 0);
    arraylist_t gvars;
    arraylist_new(&gvars, 0);
    arraylist_t external_fns;
    arraylist_new(&external_fns, 0);
    // prepare hash table with any fields the user wanted us to rewrite during serialization
    if (precompile_field_replace) {
        jl_array_t *vals = (jl_array_t*)jl_svecref(precompile_field_replace, 0);
        jl_array_t *fields = (jl_array_t*)jl_svecref(precompile_field_replace, 1);
        jl_array_t *newvals = (jl_array_t*)jl_svecref(precompile_field_replace, 2);
        size_t i, l = jl_array_nrows(vals);
        assert(jl_array_nrows(fields) == l && jl_array_nrows(newvals) == l);
        for (i = 0; i < l; i++) {
            jl_value_t *val = jl_array_ptr_ref(vals, i);
            size_t field = jl_unbox_long(jl_array_ptr_ref(fields, i));
            jl_value_t *newval = jl_array_ptr_ref(newvals, i);
            jl_datatype_t *st = (jl_datatype_t*)jl_typeof(val);
            size_t offs = jl_field_offset(st, field);
            char *fldaddr = (char*)val + offs;
            if (jl_field_isptr(st, field)) {
                record_field_change((jl_value_t**)fldaddr, newval);
            }
            else if (jl_field_size(st, field) > 0) {
                // replace the bits
                ptrhash_put(&bits_replace, (void*)fldaddr, newval);
                // and any pointers inside
                jl_datatype_t *rty = (jl_datatype_t*)jl_typeof(newval);
                const jl_datatype_layout_t *layout = rty->layout;
                size_t j, np = layout->npointers;
                for (j = 0; j < np; j++) {
                    uint32_t ptr = jl_ptr_offset(rty, j);
                    record_field_change((jl_value_t**)fldaddr + ptr, *(((jl_value_t**)newval) + ptr));
                }
            }
        }
    }

    int en = jl_gc_enable(0);
    if (native_functions) {
        size_t num_gvars, num_external_fns;
        jl_get_llvm_gv_inits(native_functions, &num_gvars, NULL);
        arraylist_grow(&gvars, num_gvars);
        jl_get_llvm_gv_inits(native_functions, &num_gvars, gvars.items);
        jl_get_llvm_external_fns(native_functions, &num_external_fns, NULL);
        arraylist_grow(&external_fns, num_external_fns);
        jl_get_llvm_external_fns(native_functions, &num_external_fns,
                                 (jl_code_instance_t *)external_fns.items);
        if (jl_options.trim) {
            size_t num_mis;
            jl_get_llvm_cis(native_functions, &num_mis, NULL);
            arraylist_grow(&MIs, num_mis);

            // Record MethodInstances for user-provided code (as reported by codegen)
            jl_get_llvm_cis(native_functions, &num_mis, (jl_code_instance_t**)MIs.items);
            for (size_t i = 0; i < num_mis; i++) {
                jl_code_instance_t *ci = (jl_code_instance_t*)MIs.items[i];
                MIs.items[i] = (void*)jl_get_ci_mi(ci);
            }

            // Record MethodInstances for built-ins (used when dynamically dispatching to a
            // built-in, e.g., in the Core._apply_iterate implementation)
            jl_datatype_t *tt = NULL;
            JL_GC_PUSH1(&tt);
            for (size_t i = 0; i < jl_n_builtins; i++) {
                jl_value_t *builtin = jl_builtin_instances[i];
                if (builtin == NULL)
                    continue;

                jl_datatype_t *dt = (jl_datatype_t*)jl_typeof(builtin);
                jl_value_t *params[2];
                params[0] = dt->name->wrapper;
                params[1] = jl_tparam0(jl_anytuple_type);
                tt = (jl_datatype_t*)jl_apply_tuple_type_v(params, 2);
                jl_method_instance_t *mi = (jl_method_instance_t *)jl_method_lookup_by_tt(
                    tt, /* world */ 1, /* mt */ jl_nothing
                );
                assert(!jl_is_nothing(mi));
                arraylist_push(&MIs, mi);
            }
            JL_GC_POP();
        }
    }
    if (jl_options.trim) {
        jl_rebuild_methtables(&MIs, &new_methtables);
    }

    nsym_tag = 0;
    htable_new(&symbol_table, 0);
    htable_new(&fptr_to_id, jl_n_builtins);
    uintptr_t i;
    for (i = 0; i < jl_n_builtins; i++) {
        ptrhash_put(&fptr_to_id, (void*)(uintptr_t)jl_builtin_f_addrs[i], (void*)(i + 2));
    }
    htable_new(&serialization_order, 25000);
    htable_new(&nullptrs, 0);
    arraylist_new(&object_worklist, 0);
    arraylist_new(&deferred_supers, 0);
    arraylist_new(&serialization_queue, 0);
    reactive_dump_on = getenv("JULIA_REACTIVE_HEAPDUMP") != NULL;
    if (reactive_dump_on)
        htable_new(&reactive_dump_parents, 0);
    ios_t sysimg, const_data, symbols, relocs, gvar_record, fptr_record;
    ios_mem(&sysimg, 0);
    ios_mem(&const_data, 0);
    ios_mem(&symbols, 0);
    ios_mem(&relocs, 0);
    ios_mem(&gvar_record, 0);
    ios_mem(&fptr_record, 0);
    jl_serializer_state s = {0};
    int result = 0;
    s.query_cache = query_cache;
    s.incremental = !(worklist == NULL);
    s.s = &sysimg;
    s.const_data = &const_data;
    s.symbols = &symbols;
    s.relocs = &relocs;
    s.gvar_record = &gvar_record;
    s.fptr_record = &fptr_record;
    s.ptls = jl_current_task->ptls;
    arraylist_new(&s.memowner_list, 0);
    arraylist_new(&s.memref_list, 0);
    arraylist_new(&s.relocs_list, 0);
    arraylist_new(&s.gctags_list, 0);
    arraylist_new(&s.uniquing_types, 0);
    arraylist_new(&s.uniquing_super, 0);
    arraylist_new(&s.uniquing_objs, 0);
    arraylist_new(&s.fixup_types, 0);
    arraylist_new(&s.fixup_objs, 0);
    s.buildid_depmods_idxs = image_to_depmodidx(mod_array);
    s.link_ids_relocs = jl_alloc_array_1d(jl_array_int32_type, 0);
    s.link_ids_gctags = jl_alloc_array_1d(jl_array_int32_type, 0);
    s.link_ids_gvars = jl_alloc_array_1d(jl_array_int32_type, 0);
    s.link_ids_external_fnvars = jl_alloc_array_1d(jl_array_int32_type, 0);
    s.method_roots_list = NULL;
    htable_new(&s.method_roots_index, 0);
    jl_value_t **_tags[NUM_TAGS];
    jl_value_t ***tags = s.incremental ? NULL : _tags;
    if (worklist) {
        s.method_roots_list = jl_alloc_vec_any(0);
        s.worklist_key = jl_worklist_key(worklist);
    }
    else {
        get_tags(_tags);
    }

    if (worklist == NULL) {
        // empty!(Core.ARGS)
        if (jl_core_module != NULL) {
            jl_array_t *args = (jl_array_t*)jl_get_global(jl_core_module, jl_symbol("ARGS"));
            if (args != NULL) {
                jl_array_del_end(args, jl_array_len(args));
            }
        }
    }
    jl_bigint_type = jl_base_module ? jl_get_global(jl_base_module, jl_symbol("BigInt")) : NULL;
    if (jl_bigint_type) {
        gmp_limb_size = jl_unbox_long(jl_get_global((jl_module_t*)jl_get_global(jl_base_module, jl_symbol("GMP")),
                                                    jl_symbol("BITS_PER_LIMB"))) / 8;
    }
    jl_genericmemory_t *global_roots_list = NULL;
    jl_genericmemory_t *global_roots_keyset = NULL;

    uint64_t t_step = jl_hrtime(), t_queue = 0, t_prune = 0, t_write = 0;
    reactive_pages_on = 0;
    if (reactive_prune_heap && !jl_options.trim && reactive_pages_mode() && !reactive_pages_retry)
        reactive_pages_begin(&sysimg, &const_data, &symbols);
    { // step 1: record values (recursively) that need to go in the image
        size_t i;
        if (reactive_pages_on) {
            // The objects of the dirty pages first: the walk from them
            // queues the new objects and stops at the rest of the base.
            reactive_pages_queue_dirty(&s);
            jl_serialize_reachable(&s);
        }
        if (worklist == NULL) {
            for (i = 0; tags[i] != NULL; i++) {
                jl_value_t *tag = *tags[i];
                jl_queue_for_serialization(&s, tag);
            }
            for (i = 0; i < jl_n_builtins; i++)
                jl_queue_for_serialization(&s, jl_builtin_instances[i]);
#define XX(name, type) jl_queue_for_serialization(&s, (jl_value_t*)jl_##name);
            JL_EXPORTED_DATA_POINTERS(XX)
#undef XX
#define XX(name, type) jl_queue_for_serialization(&s, (jl_value_t*)jl_##name);
            JL_CONST_GLOBAL_VARS(XX)
#undef XX
            jl_queue_for_serialization(&s, s.ptls->root_task->tls);
        }
        else {
            // Queue the worklist itself as the first item we serialize
            jl_queue_for_serialization(&s, worklist);
            jl_queue_for_serialization(&s, module_init_order);
        }
        // step 1.1: as needed, serialize the data needed for insertion into the running system
        if (extext_methods) {
            // Queue method extensions
            jl_queue_for_serialization(&s, extext_methods);
            // Queue the new specializations
            jl_queue_for_serialization(&s, new_ext_cis);
        }
        jl_serialize_reachable(&s);
        // step 1.2: ensure all gvars are part of the sysimage too
        record_gvars(&s, &gvars);
        record_external_fns(&s, &external_fns);
        if (jl_options.trim)
            record_gvars(&s, &MIs);
        jl_serialize_reachable(&s);
        // Beyond this point, all content should already have been visited, so now we can prune
        // the rest and add some internal root arrays.
        // step 1.3: include some other special roots
        if (s.incremental) {
            // Queue the new roots array
            jl_queue_for_serialization(&s, s.method_roots_list);
            jl_serialize_reachable(&s);
        }
        // step 1.4: prune (garbage collect) special weak references from the jl_global_roots_list
        if (worklist == NULL) {
            global_roots_list = jl_alloc_memory_any(0);
            global_roots_keyset = jl_alloc_memory_any(0);
            for (size_t i = 0; i < jl_global_roots_list->length; i++) {
                jl_value_t *val = jl_genericmemory_ptr_ref(jl_global_roots_list, i);
                if (val && reactive_pages_live(val)) {
                    ssize_t idx;
                    global_roots_list = jl_idset_put_key(global_roots_list, val, &idx);
                    global_roots_keyset = jl_idset_put_idx(global_roots_list, global_roots_keyset, idx);
                }
            }
            jl_queue_for_serialization(&s, global_roots_list);
            jl_queue_for_serialization(&s, global_roots_keyset);
            jl_serialize_reachable(&s);
        }
        t_queue = jl_hrtime() - t_step; t_step = jl_hrtime();
        // step 1.5: prune (garbage collect) some special weak references known caches
        for (i = 0; i < serialization_queue.len; i++) {
            jl_value_t *v = (jl_value_t*)serialization_queue.items[i];
            if (jl_is_method(v)) {
                if (jl_options.trim)
                    jl_prune_method_specializations((jl_method_t*)v);
                if (reactive_prune_heap)
                    reactive_prune_interferences((jl_method_t*)v);
            }
            else if (jl_is_module(v)) {
                if (jl_options.trim)
                    jl_prune_module_bindings((jl_module_t*)v);
                if (reactive_prune_heap) {
                    jl_module_t *m = (jl_module_t*)v;
                    reactive_prune_weak_list(get_replaceable_field(&m->usings_backedges, 1));
                    reactive_prune_weak_list(get_replaceable_field(&m->scanned_methods, 1));
                }
            }
            else if (jl_is_typename(v)) {
                jl_typename_t *tn = (jl_typename_t*)v;
                jl_atomic_store_relaxed(&tn->cache,
                    jl_prune_type_cache_hash(jl_atomic_load_relaxed(&tn->cache)));
                jl_gc_wb(tn, jl_atomic_load_relaxed(&tn->cache));
                jl_prune_type_cache_linear(jl_atomic_load_relaxed(&tn->linearcache));
            }
            else if (jl_is_method_instance(v)) {
                jl_method_instance_t *mi = (jl_method_instance_t*)v;
                jl_value_t *backedges = get_replaceable_field((jl_value_t**)&mi->backedges, 1);
                jl_prune_mi_backedges((jl_array_t*)backedges);
            }
            else if (jl_is_binding(v)) {
                jl_binding_t *b = (jl_binding_t*)v;
                jl_value_t *backedges = get_replaceable_field((jl_value_t**)&b->backedges, 1);
                jl_prune_binding_backedges((jl_array_t*)backedges);
            }
            else if (jl_is_mtable(v)) {
                jl_methtable_t *mt = (jl_methtable_t*)v;
                jl_value_t *backedges = get_replaceable_field((jl_value_t**)&mt->backedges, 1);
                jl_prune_mt_backedges((jl_genericmemory_t*)backedges);
            }
        }
    }

    const char *heapdump = getenv("JULIA_REACTIVE_HEAPDUMP");
    if (heapdump && *heapdump)
        reactive_dump_heap(heapdump);

    uint32_t external_fns_begin = 0;
    t_prune = jl_hrtime() - t_step; t_step = jl_hrtime();
    { // step 2: build all the sysimg sections
        if (!reactive_pages_on)
            write_padding(&sysimg, sizeof(uintptr_t));
        jl_write_values(&s);
        if (reactive_overlay_on && reactive_pages_refusal == NULL) {
            // The pages of the base come from the queue alone: an object of
            // a dirty page that the queue lost would land as zeros.
            arraylist_t *tags = &reactive_base.gctags;
            size_t page = jl_page_size;
            for (size_t i = 0; i < tags->len; i++) {
                if (reactive_pages_rewritten[i])
                    continue;
                char *addr = reactive_image_base + (size_t)tags->items[i];
                size_t off = (size_t)tags->items[i];
                char *next = i + 1 < tags->len ? reactive_image_base + (size_t)tags->items[i + 1]
                                               : reactive_image_base + reactive_objects_end;
                if (off < reactive_base_end && next > reactive_image_base + reactive_base_end)
                    next = reactive_image_base + reactive_base_end;
                int dirty = reactive_pages_dirty(addr);
                for (char *p = (char*)LLT_ALIGN((uintptr_t)addr + 1, page); !dirty && p < next; p += page)
                    dirty = reactive_pages_dirty(p);
                if (dirty) {
                    jl_safe_printf("reactive: overlay: the object at %zu of a dirty page was not rewritten\n", off);
                    reactive_pages_refusal = "an object of a dirty page left the queue";
                    break;
                }
            }
        }
        if (reactive_pages_refusal != NULL && reactive_overlay_on)
            jl_errorf("reactive: overlay: %s; the overlay cannot be written", reactive_pages_refusal);
        if (reactive_pages_refusal != NULL) {
            jl_safe_printf("reactive: pages: %s; the save writes whole\n", reactive_pages_refusal);
            result = -1;
            ios_close(&sysimg);
            ios_close(&const_data);
            ios_close(&symbols);
            ios_close(&relocs);
            ios_close(&gvar_record);
            ios_close(&fptr_record);
            goto cleanup;
        }
        external_fns_begin = write_gvars(&s, &gvars, &external_fns);
        if (reactive_pages_on)
            reactive_pages_fptrs(&s);
    }

    // This ensures that we can use the low bit of addresses for
    // identifying end pointers in gc's eytzinger search.
    write_padding(&sysimg, 4 - (sysimg.size % 4));
    write_padding(&const_data, 4 - (const_data.size % 4));

    if (sysimg.size > ((uintptr_t)1 << RELOC_TAG_OFFSET)) {
        jl_printf(
            JL_STDERR,
            "ERROR: system image too large: sysimg.size is 0x%" PRIxPTR " but the limit is 0x%" PRIxPTR "\n",
            (uintptr_t)sysimg.size,
            ((uintptr_t)1 << RELOC_TAG_OFFSET)
        );
        jl_exit(1);
    }
    if (const_data.size / sizeof(void*) > ((uintptr_t)1 << RELOC_TAG_OFFSET)) {
        jl_printf(
            JL_STDERR,
            "ERROR: system image too large: const_data.size is 0x%" PRIxPTR " but the limit is 0x%" PRIxPTR "\n",
            (uintptr_t)const_data.size,
            ((uintptr_t)1 << RELOC_TAG_OFFSET)*sizeof(void*)
        );
        jl_exit(1);
    }

    t_write = jl_hrtime() - t_step; t_step = jl_hrtime();
    // step 3: combine all of the sections into one file
    assert(ios_pos(f) % JL_CACHE_BYTE_ALIGNMENT == 0);
    ssize_t sysimg_offset = ios_pos(f);
    size_t sysimg_size = 0;
    if (reactive_overlay_on) {
        // The overlay blob (Stage G): the relocation targets are finished
        // in the buffers, the merged lists written, then the dirty pages,
        // the new objects and the records; the roots follow in step 4.
        sysimg_size = s.s->size;
        jl_finish_relocs(sysimg.buf, sysimg_size, &s.gctags_list);
        jl_finish_relocs(sysimg.buf, sysimg_size, &s.relocs_list);
        reactive_pages_write_list(s.relocs, sysimg_size, &reactive_base.gctags, &s.gctags_list);
        reactive_pages_write_list(s.relocs, sysimg_size, &reactive_base.relocs_list, &s.relocs_list);
        reactive_pages_write_list(s.relocs, sysimg_size, &reactive_base.memowner, &s.memowner_list);
        reactive_pages_write_list(s.relocs, sysimg_size, &reactive_base.memref, &s.memref_list);
        reactive_pages_write_fixups(s.relocs, &reactive_base.fixups, &s.fixup_objs);
        reactive_overlay_emit(f, &sysimg, &const_data, &symbols, &relocs, &gvar_record, &fptr_record, external_fns_begin);
        ios_close(&sysimg);
        ios_close(&const_data);
        ios_close(&symbols);
        ios_close(&relocs);
        ios_close(&gvar_record);
        ios_close(&fptr_record);
        if (jl_reactive_timings())
            jl_safe_printf("reactive: heap queue %.1f s, prune %.1f s, write %.1f s, combine %.1f s, %zu objects\n",
                           t_queue / 1e9, t_prune / 1e9, t_write / 1e9, (jl_hrtime() - t_step) / 1e9, serialization_queue.len);
    }
    else {
    write_uint(f, sysimg.size - sizeof(uintptr_t));
    ios_seek(&sysimg, sizeof(uintptr_t));
    ios_copyall(f, &sysimg);
    sysimg_size = s.s->size;
    assert(ios_pos(f) - sysimg_offset == sysimg_size);
    ios_close(&sysimg);

    write_uint(f, const_data.size);
    // realign stream to max-alignment for data
    write_padding(f, LLT_ALIGN(ios_pos(f), JL_CACHE_BYTE_ALIGNMENT) - ios_pos(f));
    ios_seek(&const_data, 0);
    ios_copyall(f, &const_data);
    ios_close(&const_data);

    write_uint(f, symbols.size);
    write_padding(f, LLT_ALIGN(ios_pos(f), 8) - ios_pos(f));
    ios_seek(&symbols, 0);
    ios_copyall(f, &symbols);
    ios_close(&symbols);

    // Prepare and write the relocations sections, now that the rest of the image is laid out
    char *base = &f->buf[0];
    jl_finish_relocs(base + sysimg_offset, sysimg_size, &s.gctags_list);
    jl_finish_relocs(base + sysimg_offset, sysimg_size, &s.relocs_list);
    if (reactive_pages_on) {
        reactive_pages_write_list(s.relocs, sysimg_size, &reactive_base.gctags, &s.gctags_list);
        reactive_pages_write_list(s.relocs, sysimg_size, &reactive_base.relocs_list, &s.relocs_list);
        reactive_pages_write_list(s.relocs, sysimg_size, &reactive_base.memowner, &s.memowner_list);
        reactive_pages_write_list(s.relocs, sysimg_size, &reactive_base.memref, &s.memref_list);
        reactive_pages_write_fixups(s.relocs, &reactive_base.fixups, &s.fixup_objs);
    }
    else {
        jl_write_offsetlist(s.relocs, sysimg_size, &s.gctags_list);
        jl_write_offsetlist(s.relocs, sysimg_size, &s.relocs_list);
        jl_write_offsetlist(s.relocs, sysimg_size, &s.memowner_list);
        jl_write_offsetlist(s.relocs, sysimg_size, &s.memref_list);
        if (s.incremental) {
            jl_write_arraylist(s.relocs, &s.uniquing_types);
            jl_write_arraylist(s.relocs, &s.uniquing_objs);
            jl_write_arraylist(s.relocs, &s.fixup_types);
        }
        jl_write_arraylist(s.relocs, &s.fixup_objs);
    }
    write_uint(f, relocs.size);
    write_padding(f, LLT_ALIGN(ios_pos(f), 8) - ios_pos(f));
    ios_seek(&relocs, 0);
    ios_copyall(f, &relocs);
    ios_close(&relocs);

    write_uint(f, gvar_record.size);
    write_padding(f, LLT_ALIGN(ios_pos(f), 8) - ios_pos(f));
    ios_seek(&gvar_record, 0);
    ios_copyall(f, &gvar_record);
    ios_close(&gvar_record);

    write_uint(f, fptr_record.size);
    write_padding(f, LLT_ALIGN(ios_pos(f), 8) - ios_pos(f));
    ios_seek(&fptr_record, 0);
    ios_copyall(f, &fptr_record);
    ios_close(&fptr_record);

    if (jl_reactive_timings())
        jl_safe_printf("reactive: heap queue %.1f s, prune %.1f s, write %.1f s, combine %.1f s, %zu objects\n",
                       t_queue / 1e9, t_prune / 1e9, t_write / 1e9, (jl_hrtime() - t_step) / 1e9, serialization_queue.len);
    if (jl_reactive_timings() && reactive_pages_on)
        jl_safe_printf("reactive: pages: %zu objects rewritten in place, %zu appended; sysimg %zu KB of which %zu KB new\n",
                       reactive_pages_nrewritten, serialization_queue.len - reactive_pages_nrewritten,
                       sysimg_size / 1024, (sysimg_size - reactive_base.sysimg_size) / 1024);
    }
    { // step 4: record locations of special roots
        write_padding(f, LLT_ALIGN(ios_pos(f), 8) - ios_pos(f));
        if (reactive_overlay_on)
            reactive_overlay_header.off_roots = ios_pos(f) - reactive_overlay_blob_start;
        s.s = f;
        if (worklist == NULL) {
            size_t i;
            for (i = 0; tags[i] != NULL; i++) {
                jl_value_t *tag = *tags[i];
                jl_write_value(&s, tag);
            }
            for (i = 0; i < jl_n_builtins; i++)
                jl_write_value(&s, jl_builtin_instances[i]);
#define XX(name, type) jl_write_value(&s, (jl_value_t*)jl_##name);
            JL_EXPORTED_DATA_POINTERS(XX)
#undef XX
#define XX(name, type) jl_write_value(&s, (jl_value_t*)jl_##name);
            JL_CONST_GLOBAL_VARS(XX)
#undef XX
            jl_write_value(&s, global_roots_list);
            jl_write_value(&s, global_roots_keyset);
            jl_write_value(&s, s.ptls->root_task->tls);
            write_uint32(f, jl_get_gs_ctr());
            size_t world = jl_atomic_load_acquire(&jl_world_counter);
            // assert(world == precompilation_world); // This triggers on a normal build of julia
            write_uint(f, world);
            write_uint(f, jl_typeinf_world);
        }
        else {
            jl_write_value(&s, worklist);
            // save module initialization order
            size_t i, l = jl_array_len(module_init_order);
            for (i = 0; i < l; i++) {
                // verify that all these modules were saved
                assert(ptrhash_get(&serialization_order, jl_array_ptr_ref(module_init_order, i)) != HT_NOTFOUND);
            }
            jl_write_value(&s, module_init_order);
            jl_write_value(&s, extext_methods);
            jl_write_value(&s, new_ext_cis);
            jl_write_value(&s, s.method_roots_list);
        }
        write_uint32(f, jl_array_len(s.link_ids_gctags));
        ios_write(f, (char*)jl_array_data(s.link_ids_gctags, uint32_t), jl_array_len(s.link_ids_gctags) * sizeof(uint32_t));
        write_uint32(f, jl_array_len(s.link_ids_relocs));
        ios_write(f, (char*)jl_array_data(s.link_ids_relocs, uint32_t), jl_array_len(s.link_ids_relocs) * sizeof(uint32_t));
        write_uint32(f, jl_array_len(s.link_ids_gvars));
        ios_write(f, (char*)jl_array_data(s.link_ids_gvars, uint32_t), jl_array_len(s.link_ids_gvars) * sizeof(uint32_t));
        write_uint32(f, jl_array_len(s.link_ids_external_fnvars));
        ios_write(f, (char*)jl_array_data(s.link_ids_external_fnvars, uint32_t), jl_array_len(s.link_ids_external_fnvars) * sizeof(uint32_t));
        write_uint32(f, external_fns_begin);
    }
    if (reactive_overlay_on)
        reactive_overlay_finish(f);

cleanup:
    if (reactive_pages_on)
        reactive_pages_end();
    arraylist_free(&object_worklist);
    arraylist_free(&deferred_supers);
    arraylist_free(&serialization_queue);
    if (reactive_dump_on)
        htable_free(&reactive_dump_parents);
    reactive_dump_on = 0;
    arraylist_free(&layout_table);
    arraylist_free(&s.uniquing_types);
    arraylist_free(&s.uniquing_super);
    arraylist_free(&s.uniquing_objs);
    arraylist_free(&s.fixup_types);
    arraylist_free(&s.fixup_objs);
    arraylist_free(&s.memowner_list);
    arraylist_free(&s.memref_list);
    arraylist_free(&s.relocs_list);
    arraylist_free(&s.gctags_list);
    arraylist_free(&gvars);
    arraylist_free(&external_fns);
    htable_free(&s.method_roots_index);
    htable_free(&field_replace);
    htable_free(&bits_replace);
    htable_free(&serialization_order);
    htable_free(&nullptrs);
    htable_free(&symbol_table);
    htable_free(&fptr_to_id);
    htable_free(&new_methtables);
    nsym_tag = 0;
    reactive_prune_heap = 0;

    jl_gc_enable(en);
    return result;
}

static int ci_not_internal_cache(jl_code_instance_t *ci)
{
    jl_method_instance_t *mi = jl_get_ci_mi(ci);
    return !(jl_atomic_load_relaxed(&ci->flags) & JL_CI_FLAGS_NATIVE_CACHE_VALID) || jl_object_in_image(mi->def.value);
}

static void jl_write_header_for_incremental(ios_t *f, jl_array_t *worklist, jl_array_t *mod_array, jl_array_t **udeps, int64_t *srctextpos, int64_t *checksumpos)
{
    *checksumpos = write_header(f, 0);
    write_uint8(f, jl_cache_flags());
    // write description of contents (name, uuid, buildid)
    write_worklist_for_header(f, worklist);
    // Determine unique (module, abspath, fsize, hash, mtime) dependencies for the files defining modules in the worklist
    // (see Base._require_dependencies). These get stored in `udeps` and written to the ji-file header
    // (abspath will be converted to a relocateable @depot path before writing, cf. Base.replace_depot_path).
    // Also write Preferences.
    // last word of the dependency list is the end of the data / start of the srctextpos
    *srctextpos = write_dependency_list(f, worklist, udeps);  // srctextpos: position of srctext entry in header index (update later)
    // write description of requirements for loading (modules that must be pre-loaded if initialization is to succeed)
    // this can return errors during deserialize,
    // best to keep it early (before any actual initialization)
    write_mod_list(f, mod_array);
}

JL_DLLEXPORT void jl_create_system_image(void **_native_data, jl_array_t *worklist, bool_t emit_split,
                                         ios_t **s, ios_t **z, jl_array_t **udeps, int64_t *srctextpos, jl_array_t *module_init_order)
{
    if (jl_options.strip_ir || jl_options.trim) {
        // make sure this is precompiled for jl_foreach_reachable_mtable
        jl_get_loaded_modules();
    }
    jl_gc_collect(JL_GC_FULL);
    jl_gc_collect(JL_GC_INCREMENTAL);   // sweep finalizers
    JL_TIMING(SYSIMG_DUMP, SYSIMG_DUMP);

    // iff emit_split
    // write header and src_text to one file f/s
    // write systemimg to a second file ff/z
    jl_task_t *ct = jl_current_task;
    ios_t *f = (ios_t*)malloc_s(sizeof(ios_t));
    ios_mem(f, 0);

    ios_t *ff = NULL;
    if (emit_split) {
        ff = (ios_t*)malloc_s(sizeof(ios_t));
        ios_mem(ff, 0);
    } else {
        ff = f;
    }

    jl_array_t *mod_array = NULL, *extext_methods = NULL, *new_ext_cis = NULL, *ext_foreign_cis = NULL;
    int64_t checksumpos = 0;
    int64_t checksumpos_ff = 0;
    int64_t datastartpos = 0;
    JL_GC_PUSH4(&mod_array, &extext_methods, &new_ext_cis, &ext_foreign_cis);

    ext_foreign_cis = jl_alloc_vec_any(0);

    mod_array = jl_get_loaded_modules();  // __toplevel__ modules loaded in this session (from Base.loaded_modules_array)
    if (worklist) {
        if (_native_data != NULL) {
            if (suppress_precompile)
                newly_inferred = NULL;
            *_native_data = jl_create_native(NULL, 0, 1, jl_atomic_load_acquire(&jl_world_counter), NULL, suppress_precompile ? (jl_array_t*)jl_an_empty_vec_any : worklist, 0, module_init_order, ext_foreign_cis);
        }
        jl_write_header_for_incremental(f, worklist, mod_array, udeps, srctextpos, &checksumpos);
        if (emit_split) {
            checksumpos_ff = write_header(ff, 1);
            write_uint8(ff, jl_cache_flags());
            write_mod_list(ff, mod_array);
        }
        else {
            checksumpos_ff = checksumpos;
        }
    }
    else if (_native_data != NULL) {
        *_native_data = jl_create_native(NULL, jl_options.trim, 0, jl_atomic_load_acquire(&jl_world_counter), mod_array, NULL, jl_options.compile_enabled == JL_OPTIONS_COMPILE_ALL, module_init_order, ext_foreign_cis);
    }
    if (_native_data != NULL)
        native_functions = *_native_data;

    // Make sure we don't run any Julia code concurrently after this point
    // since it will invalidate our serialization preparations
    jl_gc_enable_finalizers(ct, 0);
    assert((ct->reentrant_timing & 0b1110) == 0);
    ct->reentrant_timing |= 0b1000;
    if (worklist) {
        // extext_methods: [method1, ...], worklist-owned "extending external" methods added to functions owned by modules outside the worklist

        // Save the inferred code from newly inferred, external methods
        if (native_functions) {
            arraylist_t CIs;
            arraylist_new(&CIs, 0);
            size_t num_cis;
            jl_get_llvm_cis(native_functions, &num_cis, NULL);
            arraylist_grow(&CIs, num_cis);
            jl_get_llvm_cis(native_functions, &num_cis, (jl_code_instance_t**)CIs.items);
            // Create a filtered list of the compiled code instances that are
            // possibly not referenced via any other way but valid for the
            // Method cache field of an external method
            new_ext_cis = jl_alloc_vec_any(0);
            for (size_t i = 0; i < num_cis; i++) {
                jl_code_instance_t *ci = (jl_code_instance_t*)CIs.items[i];
                if (ci_not_internal_cache(ci))
                    jl_array_ptr_1d_push(new_ext_cis, (jl_value_t*)ci);
            }
            arraylist_free(&CIs);
        }
        else {
            new_ext_cis = jl_compute_new_ext_cis();
        }

        // Merge foreign & external CIs
        if (ext_foreign_cis) {
            size_t n_ext = jl_array_nrows(ext_foreign_cis);
            for (size_t i = 0; i < n_ext; i++) {
                jl_array_ptr_1d_push(new_ext_cis, jl_array_ptr_ref(ext_foreign_cis, i));
            }
        }
        ext_foreign_cis = NULL; // not needed anymore, free it

        // Collect method extensions
        extext_methods = jl_alloc_vec_any(0);
        jl_collect_extext_methods(extext_methods, mod_array);

        if (!emit_split) {
            write_int32(f, 0); // No clone_targets
            write_padding(f, LLT_ALIGN(ios_pos(f), JL_CACHE_BYTE_ALIGNMENT) - ios_pos(f));
        }
        else {
            write_padding(ff, LLT_ALIGN(ios_pos(ff), JL_CACHE_BYTE_ALIGNMENT) - ios_pos(ff));
        }
        datastartpos = ios_pos(ff);
    }

    jl_query_cache query_cache;
    init_query_cache(&query_cache);
    jl_finalize_precompile_inferred(worklist != NULL && _native_data != NULL && jl_options.outputo != NULL);
    uint64_t t_heap = jl_hrtime();
    reactive_pages_retry = 0;
    if (jl_save_system_image_to_stream(ff, mod_array, module_init_order, worklist, extext_methods, new_ext_cis, &query_cache) != 0) {
        // the page write refused: the whole write, from the same state
        ios_seek(ff, datastartpos);
        ios_trunc(ff, datastartpos);
        reactive_pages_retry = 1;
        jl_save_system_image_to_stream(ff, mod_array, module_init_order, worklist, extext_methods, new_ext_cis, &query_cache);
        reactive_pages_retry = 0;
    }
    if (jl_reactive_timings())
        jl_safe_printf("reactive: heap %.1f s\n", (jl_hrtime() - t_heap) / 1e9);
    if (_native_data != NULL)
        native_functions = NULL;
    // make sure we don't run any Julia code concurrently before this point
    // Re-enable running julia code for postoutput hooks, atexit, etc.
    jl_gc_enable_finalizers(ct, 1);
    ct->reentrant_timing &= ~0b1000u;

    if (worklist) {
        // Go back and update the checksum in the header
        int64_t dataendpos = ios_pos(ff);
        uint32_t checksum = jl_crc32c(0, &ff->buf[datastartpos], dataendpos - datastartpos);
        ios_seek(ff, checksumpos_ff);
        write_uint64(ff, checksum | ((uint64_t)0xfafbfcfd << 32));
        write_uint64(ff, datastartpos);
        write_uint64(ff, dataendpos);
        ios_seek(ff, dataendpos);

        // Write the checksum to the split header if necessary
        if (emit_split) {
            int64_t cur = ios_pos(f);
            ios_seek(f, checksumpos);
            write_uint64(f, checksum | ((uint64_t)0xfafbfcfd << 32));
            ios_seek(f, cur);
            // Next we will write the clone_targets and afterwards the srctext
        }
    }

    destroy_query_cache(&query_cache);

    JL_GC_POP();
    *s = f;
    if (emit_split)
        *z = ff;
    return;
}

// Takes in a path of the form "usr/lib/julia/sys.so"
JL_DLLEXPORT jl_image_buf_t jl_preload_sysimg(const char *fname)
{
    if (jl_sysimage_buf.kind != JL_IMAGE_KIND_NONE)
        return jl_sysimage_buf;

    char *dot = (char*) strrchr(fname, '.');
    int is_ji = (dot && !strcmp(dot, ".ji"));

    if (is_ji) {
        // .ji extension => load .ji file only
        ios_t f;

        if (ios_file(&f, fname, 1, 0, 0, 0) == NULL)
            jl_errorf("System image file \"%s\" not found.", fname);
        ios_bufmode(&f, bm_none);

        ios_seek_end(&f);
        size_t len = ios_pos(&f);
        char *sysimg = (char*)jl_gc_perm_alloc(len, 0, 64, 0);
        ios_seek(&f, 0);

        if (ios_readall(&f, sysimg, len) != len)
            jl_errorf("Error reading system image file.");

        ios_close(&f);

        jl_sysimage_buf = (jl_image_buf_t) {
            .kind = JL_IMAGE_KIND_JI,
            .pointers = NULL,
            .data = sysimg,
            .size = len,
            .base = 0,
        };
        return jl_sysimage_buf;
    } else {
        // Get handle to sys.so
        return jl_set_sysimg_so(jl_load_dynamic_library(fname, JL_RTLD_LOCAL | JL_RTLD_NOW, 1));
    }
}


static void jl_prefetch_system_image(const char *data, size_t size)
{
    size_t page_size = jl_getpagesize(); /* jl_page_size is not set yet when loading sysimg */
    void *start = (void *)((uintptr_t)data & ~(page_size - 1));
    size_t size_aligned = LLT_ALIGN(size, page_size);
#ifdef _OS_WINDOWS_
    WIN32_MEMORY_RANGE_ENTRY entry = {start, size_aligned};
    PrefetchVirtualMemory(GetCurrentProcess(), 1, &entry, 0);
#else
    madvise(start, size_aligned, MADV_WILLNEED);
#endif
}

JL_DLLEXPORT void jl_image_unpack_uncomp(void *handle, jl_image_buf_t *image)
{
    size_t *plen;
    uint32_t *pchecksum;
    jl_dlsym(handle, "jl_system_image_size", (void **)&plen, 1, 0);
    jl_dlsym(handle, "jl_system_image_data", (void **)&image->data, 1, 0);
    jl_dlsym(handle, "jl_image_pointers", (void**)&image->pointers, 1, 0);
    jl_dlsym(handle, "jl_system_image_checksum", (void **)&pchecksum, 1, 0);
    image->size = *plen;
    image->checksum = *pchecksum;
    jl_prefetch_system_image(image->data, image->size);
}

JL_DLLEXPORT void jl_image_unpack_zstd(void *handle, jl_image_buf_t *image)
{
    size_t *plen;
    uint32_t *pchecksum;
    const char *data;
    jl_dlsym(handle, "jl_system_image_size", (void **)&plen, 1, 0);
    jl_dlsym(handle, "jl_system_image_data", (void **)&data, 1, 0);
    jl_dlsym(handle, "jl_image_pointers", (void **)&image->pointers, 1, 0);
    jl_dlsym(handle, "jl_system_image_checksum", (void **)&pchecksum, 1, 0);
    image->checksum = *pchecksum;
    jl_prefetch_system_image(data, *plen);
    image->size = ZSTD_getFrameContentSize(data, *plen);
    size_t page_size = jl_getpagesize(); /* jl_page_size is not set yet when loading sysimg */
    size_t aligned_size = LLT_ALIGN(image->size, page_size);
    int fail = 0;
#if defined(_OS_WINDOWS_)
    size_t large_page_size = GetLargePageMinimum();
    image->data = NULL;
    if (large_page_size > 0 && image->size > 4 * large_page_size) {
        size_t aligned_size = LLT_ALIGN(image->size, large_page_size);
        image->data = (char *)VirtualAlloc(
            NULL, aligned_size, MEM_COMMIT | MEM_RESERVE | MEM_LARGE_PAGES, PAGE_READWRITE);
    }
    if (!image->data) {
        /* Try small pages if large pages failed. */
        image->data = (char *)VirtualAlloc(NULL, aligned_size, MEM_COMMIT | MEM_RESERVE,
                                           PAGE_READWRITE);
    }
    fail = !image->data;
#else
    image->data = (char *)mmap(NULL, aligned_size, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    fail = image->data == (void *)-1;
#endif
    if (fail) {
        const char *err;
#if defined(_OS_WINDOWS_)
        char err_buf[256];
        win32_formatmessage(GetLastError(), err_buf, sizeof(err_buf));
        err = err_buf;
#else
        err = strerror(errno);
#endif
        jl_printf(JL_STDERR, "ERROR: failed to allocate memory for system image: %s\n",
                  err);
        jl_exit(1);
    }

    ZSTD_decompress((void *)image->data, image->size, data, *plen);
    size_t len = (*plen) & ~(page_size - 1);
#ifdef _OS_WINDOWS_
    if (len)
        VirtualFree((void *)data, len, MEM_RELEASE);
#else
    munmap((void *)data, len);
#endif
}

// From a shared library handle, verify consistency and return a jl_image_buf_t
static jl_image_buf_t get_image_buf(void *handle, int is_pkgimage)
{
    // verify that the linker resolved the symbols in this image against ourselves (libjulia-internal)
    void** (*get_jl_RTLD_DEFAULT_handle_addr)(void) = NULL;
    if (handle != jl_RTLD_DEFAULT_handle) {
        int symbol_found = jl_dlsym(handle, "get_jl_RTLD_DEFAULT_handle_addr", (void **)&get_jl_RTLD_DEFAULT_handle_addr, 0, 0);
        if (!symbol_found || (void*)&jl_RTLD_DEFAULT_handle != (get_jl_RTLD_DEFAULT_handle_addr()))
            jl_error("Image file failed consistency check: maybe opened the wrong version?");
    }

    jl_image_unpack_func_t **unpack;
    jl_image_buf_t image = {
        .kind = JL_IMAGE_KIND_SO,
        .pointers = NULL,
        .data = NULL,
        .size = 0,
        .base = 0,
    };

    // verification passed, lookup the buffer pointers
    if (jl_image_unpack == NULL || is_pkgimage) {
        // in the usual case, the sysimage was not statically linked to libjulia-internal
        // look up the external sysimage symbols via the dynamic linker
        jl_dlsym(handle, "jl_image_unpack", (void **)&unpack, 1, 0);
    }
    else {
        // the sysimage was statically linked directly against libjulia-internal
        // use the internal symbols
        unpack = &jl_image_unpack;
    }
    (*unpack)(handle, &image);

#ifdef _OS_WINDOWS_
    image.base = (intptr_t)handle;
#else
    Dl_info dlinfo;
    if (dladdr((void*)image.pointers, &dlinfo) != 0)
        image.base = (intptr_t)dlinfo.dli_fbase;
    else
        image.base = 0;
#endif

    return image;
}

// The handle of the loaded system image, kept for `jl_reactive_image_exports`.
static void *reactive_image_handle = NULL;

// Allow passing in a module handle directly, rather than a path
JL_DLLEXPORT jl_image_buf_t jl_set_sysimg_so(void *handle)
{
    if (jl_sysimage_buf.kind != JL_IMAGE_KIND_NONE)
        return jl_sysimage_buf;

    jl_sysimage_buf = get_image_buf(handle, /* is_pkgimage */ 0);
    reactive_image_handle = handle;
    return jl_sysimage_buf;
}

#ifndef JL_NDEBUG
// skip the performance optimizations of jl_types_equal and just use subtyping directly
// one of these types is invalid - that's why we're doing the recache type operation
// static int jl_invalid_types_equal(jl_datatype_t *a, jl_datatype_t *b)
// {
//     return jl_subtype((jl_value_t*)a, (jl_value_t*)b) && jl_subtype((jl_value_t*)b, (jl_value_t*)a);
// }
#endif

extern void rebuild_image_blob_tree(void);
extern void export_jl_small_typeof(void);
extern void export_jl_sysimg_globals(void);

// When an image is loaded with ignore_native, all subsequent image loads must ignore
// native code in the cache-file since we can't gurantuee that there are no call edges
// into the native code of the image. See https://github.com/JuliaLang/julia/pull/52123#issuecomment-1959965395.
int IMAGE_NATIVE_CODE_TAINTED = 0;

// TODO: This should possibly be in Julia
static int jl_validate_binding_partition(jl_binding_t *b, jl_binding_partition_t *bpart, size_t mod_idx, int unchanged_implicit, int no_replacement)
{
    if (jl_atomic_load_relaxed(&bpart->max_world) != ~(size_t)0)
        return 1;
    size_t raw_kind = bpart->kind;
    enum jl_partition_kind kind = (enum jl_partition_kind)(raw_kind & PARTITION_MASK_KIND);
    if (!unchanged_implicit && jl_bkind_is_some_implicit(kind)) {
        // TODO: Should we actually update this in place or delete it from the partitions list
        // and allocate a fresh bpart?
        jl_update_loaded_bpart(b, bpart);
        bpart->kind |= (raw_kind & PARTITION_MASK_FLAG);
        if (jl_atomic_load_relaxed(&bpart->min_world) > jl_require_world)
            goto invalidated;
    }
    {
        if (!jl_bkind_is_some_explicit_import(kind) && kind != PARTITION_KIND_IMPLICIT_GLOBAL)
            return 1;
        jl_binding_t *imported_binding = (jl_binding_t*)bpart->restriction;
        jl_binding_partition_t *latest_imported_bpart = jl_atomic_load_relaxed(&imported_binding->partitions);
        if (no_replacement)
            goto add_backedge;
        if (!latest_imported_bpart)
            return 1;
        if (jl_atomic_load_relaxed(&latest_imported_bpart->min_world) <=
            jl_atomic_load_relaxed(&bpart->min_world)) {
    add_backedge:
            // Imported binding is still valid
            if ((kind == PARTITION_KIND_EXPLICIT || kind == PARTITION_KIND_IMPORTED) &&
                    external_blob_index((jl_value_t*)imported_binding) != mod_idx) {
                jl_add_binding_backedge(imported_binding, (jl_value_t*)b);
            }
            return 1;
        }
        else {
            // Binding partition was invalidated
            assert(jl_atomic_load_relaxed(&bpart->min_world) == jl_require_world);
            jl_atomic_store_relaxed(&bpart->min_world,
                jl_atomic_load_relaxed(&latest_imported_bpart->min_world));
        }
    }
invalidated:
    // We need to go through and re-validate any bindings in the same image that
    // may have imported us.
    if (b->backedges) {
        JL_LOCK(&b->globalref->mod->lock);
        for (size_t i = 0; i < jl_array_len(b->backedges); i++) {
            jl_value_t *edge = jl_array_ptr_ref(b->backedges, i);
            if (!jl_is_binding(edge))
                continue;
            jl_binding_t *bedge = (jl_binding_t*)edge;
            if (!jl_atomic_load_relaxed(&bedge->partitions))
                continue;
            JL_UNLOCK(&b->globalref->mod->lock);
            jl_validate_binding_partition(bedge, jl_atomic_load_relaxed(&bedge->partitions), mod_idx, 0, 0);
            JL_LOCK(&b->globalref->mod->lock);
        }
        JL_UNLOCK(&b->globalref->mod->lock);
    }
    if (bpart->kind & PARTITION_FLAG_EXPORTED) {
        jl_module_t *mod = b->globalref->mod;
        jl_sym_t *name = b->globalref->name;
        JL_LOCK(&mod->lock);
        jl_atomic_store_release(&mod->export_set_changed_since_require_world, 1);
        if (mod->usings_backedges != jl_nothing) {
            for (size_t i = 0; i < jl_array_len(mod->usings_backedges); i++) {
                jl_module_t *edge = (jl_module_t*)jl_array_ptr_ref(mod->usings_backedges, i);
                jl_binding_t *importee = jl_get_module_binding(edge, name, 0);
                if (!importee)
                    continue;
                if (!jl_atomic_load_relaxed(&importee->partitions))
                    continue;
                JL_UNLOCK(&mod->lock);
                jl_validate_binding_partition(importee, jl_atomic_load_relaxed(&importee->partitions), mod_idx, 0, 0);
                JL_LOCK(&mod->lock);
            }
        }
        JL_UNLOCK(&mod->lock);
        return 0;
    }
    return 1;
}

static int all_usings_unchanged_implicit(jl_module_t *mod)
{
    int unchanged_implicit = 1;
    for (size_t i = 0; unchanged_implicit && i < module_usings_length(mod); i++) {
        jl_module_t *usee = module_usings_getmod(mod, i);
        unchanged_implicit &= !jl_atomic_load_acquire(&usee->export_set_changed_since_require_world);
    }
    return unchanged_implicit;
}

// The dirty pages of the image (Stage F of the plan, the measurement).
// Under JULIA_REACTIVE_DIRTY_PAGES=<path> the loader protects the data pages
// of the image once the relocations are applied, the fault handler marks a
// page and lifts its protection at the first write, and the write of an
// image appends a report to the path: the pages the process wrote, and
// the instructions that wrote them first.
#define REACTIVE_DIRTY_WRITERS 128
static uintptr_t reactive_dirty_writer_ip[REACTIVE_DIRTY_WRITERS];
static size_t reactive_dirty_writer_n[REACTIVE_DIRTY_WRITERS];
static size_t reactive_dirty_nwriters = 0;
static size_t reactive_dirty_faults = 0;

static void reactive_dirty_protect(char *start, size_t len)
{
    reactive_dirty_path = getenv("JULIA_REACTIVE_DIRTY_PAGES");
    if (reactive_dirty_path != NULL && *reactive_dirty_path == '\0')
        reactive_dirty_path = NULL;
    if (reactive_dirty_path == NULL && !reactive_pages_mode())
        return;
    size_t page = jl_page_size;
    char *first = (char*)LLT_ALIGN((uintptr_t)start, page);
    char *end = (char*)(((uintptr_t)(start + len)) & ~(uintptr_t)(page - 1));
    if (end <= first)
        return;
    reactive_dirty_start = first;
    reactive_dirty_len = end - first;
    reactive_dirty_npages = reactive_dirty_len / page;
    reactive_dirty_bits = (uint8_t*)calloc(reactive_dirty_npages, 1);
    if (mprotect(first, reactive_dirty_len, PROT_READ) != 0) {
        jl_safe_printf("reactive: dirty pages: mprotect of %p + %zu KB failed: %s\n", (void*)first,
                       reactive_dirty_len / 1024, strerror(errno));
        reactive_dirty_start = NULL;
    }
    else if (reactive_dirty_path != NULL || jl_reactive_timings()) {
        jl_safe_printf("reactive: dirty pages: %zu pages of the image protected\n", reactive_dirty_npages);
    }
}

// The fault handler asks first: a write into a protected page of the
// image marks the page, lifts its protection, and is not a fault.
JL_DLLEXPORT int jl_reactive_dirty_fault(void *addr, void *ip) JL_NOTSAFEPOINT
{
    char *a = (char*)addr;
    if (reactive_dirty_start == NULL || a < reactive_dirty_start || a >= reactive_dirty_start + reactive_dirty_len)
        return 0;
    size_t page = jl_page_size;
    size_t index = (a - reactive_dirty_start) / page;
    reactive_dirty_bits[index] = 1;
    reactive_dirty_faults++;
    size_t i;
    for (i = 0; i < reactive_dirty_nwriters; i++)
        if (reactive_dirty_writer_ip[i] == (uintptr_t)ip)
            break;
    if (i == reactive_dirty_nwriters && i < REACTIVE_DIRTY_WRITERS) {
        reactive_dirty_writer_ip[i] = (uintptr_t)ip;
        reactive_dirty_writer_n[i] = 0;
        reactive_dirty_nwriters++;
    }
    if (i < REACTIVE_DIRTY_WRITERS)
        reactive_dirty_writer_n[i]++;
    mprotect(reactive_dirty_start + index * page, page, PROT_READ | PROT_WRITE);
    return 1;
}

JL_DLLEXPORT void jl_reactive_dirty_report(const char *tag)
{
    if (reactive_dirty_start == NULL || reactive_dirty_path == NULL)
        return;
    size_t dirty = 0;
    for (size_t i = 0; i < reactive_dirty_npages; i++)
        dirty += reactive_dirty_bits[i];
    ios_t out;
    if (ios_file(&out, reactive_dirty_path, 1, 1, 1, 0) == NULL)
        return;
    ios_seek_end(&out);
    ios_printf(&out, "%s: %zu of %zu pages dirty (%zu KB of %zu KB), %zu faults, %zu writers\n", tag, dirty,
               reactive_dirty_npages, dirty * jl_page_size / 1024, reactive_dirty_len / 1024,
               reactive_dirty_faults, reactive_dirty_nwriters);
    for (size_t i = 0; i < reactive_dirty_nwriters; i++) {
        Dl_info info;
        if (dladdr((void*)reactive_dirty_writer_ip[i], &info) && info.dli_fname) {
            ios_printf(&out, "  writer %zu pages: %s+0x%zx %s\n", reactive_dirty_writer_n[i], info.dli_fname,
                       (size_t)(reactive_dirty_writer_ip[i] - (uintptr_t)info.dli_fbase),
                       info.dli_sname ? info.dli_sname : "");
        }
        else {
            ios_printf(&out, "  writer %zu pages: 0x%zx\n", reactive_dirty_writer_n[i], (size_t)reactive_dirty_writer_ip[i]);
        }
    }
    ios_close(&out);
}

static void jl_restore_system_image_from_stream_(ios_t *f, jl_image_t *image,
                                                 jl_array_t *depmods, uint64_t checksum,
                                /* outputs */    jl_array_t **restored,         jl_array_t **init_order,
                                                 jl_array_t **extext_methods, jl_array_t **internal_methods,
                                                 jl_array_t **new_ext_cis, jl_array_t **method_roots_list,
                                                 pkgcachesizes *cachesizes) JL_GC_DISABLED
{
    jl_task_t *ct = jl_current_task;
    int en = jl_gc_enable(0);
    ios_t sysimg, const_data, symbols, relocs, gvar_record, fptr_record;
    jl_serializer_state s = {0};
    s.incremental = restored != NULL; // jl_linkage_blobs.len > 0;
    s.image = image;
    s.s = NULL;
    s.const_data = &const_data;
    s.symbols = &symbols;
    s.relocs = &relocs;
    s.gvar_record = &gvar_record;
    s.fptr_record = &fptr_record;
    s.ptls = ct->ptls;
    jl_value_t **_tags[NUM_TAGS];
    jl_value_t ***tags = s.incremental ? NULL : _tags;
    if (!s.incremental)
        get_tags(_tags);

    htable_t new_dt_objs;
    htable_new(&new_dt_objs, 0);
    arraylist_new(&deser_sym, 0);

    if (jl_options.use_sysimage_native_code != JL_OPTIONS_USE_SYSIMAGE_NATIVE_CODE_YES || IMAGE_NATIVE_CODE_TAINTED) {
        memset(&image->fptrs, 0, sizeof(image->fptrs));
        image->gvars_base = NULL;
        IMAGE_NATIVE_CODE_TAINTED = 1;
    }

    // step 1: read section map
    size_t sizeof_sysdata, sizeof_constdata, sizeof_sysimg, sizeof_symbols;
    size_t sizeof_relocations, sizeof_gvar_record, sizeof_fptr_record;
    ios_t roots_stream;
    ios_t *r = f;               // the stream the roots are read from
    int sections = reactive_sections_on && !s.incremental;
    if (sections) {
        // The sections of the image come from the override (an overlay-mode
        // process: the sysimg and the const data live in a region).
        reactive_sections_t *sec = &reactive_sections;
        sizeof_sysdata = sec->sysimg.size - sizeof(uintptr_t);
        ios_static_buffer(&sysimg, (char*)sec->sysimg.ptr, sec->sysimg.size);
        sizeof_constdata = sec->const_data.size;
        ios_static_buffer(&const_data, (char*)sec->const_data.ptr, sizeof_constdata);
        sizeof_sysimg = sec->blob_span;
        sizeof_symbols = sec->symbols.size;
        ios_static_buffer(&symbols, (char*)sec->symbols.ptr, sizeof_symbols);
        sizeof_relocations = sec->relocs.size;
        sizeof_gvar_record = sec->gvar.size;
        sizeof_fptr_record = sec->fptr.size;
        ios_static_buffer(&relocs, (char*)sec->relocs.ptr, sizeof_relocations);
        ios_static_buffer(&gvar_record, (char*)sec->gvar.ptr, sizeof_gvar_record);
        ios_static_buffer(&fptr_record, (char*)sec->fptr.ptr, sizeof_fptr_record);
        ios_static_buffer(&roots_stream, (char*)sec->roots.ptr, sec->roots.size);
        r = &roots_stream;
        s.root_base = (char*)sec->sysimg.ptr;
    }
    else {
    assert(ios_pos(f) == 0 && f->bm == bm_mem);
    sizeof_sysdata = read_uint(f);
    ios_static_buffer(&sysimg, f->buf, sizeof_sysdata + sizeof(uintptr_t));
    ios_skip(f, sizeof_sysdata);

    sizeof_constdata = read_uint(f);
    // realign stream to max-alignment for data
    ios_seek(f, LLT_ALIGN(ios_pos(f), JL_CACHE_BYTE_ALIGNMENT));
    ios_static_buffer(&const_data, f->buf + f->bpos, sizeof_constdata);
    ios_skip(f, sizeof_constdata);

    sizeof_sysimg = f->bpos;

    sizeof_symbols = read_uint(f);
    ios_seek(f, LLT_ALIGN(ios_pos(f), 8));
    ios_static_buffer(&symbols, f->buf + f->bpos, sizeof_symbols);
    ios_skip(f, sizeof_symbols);

    sizeof_relocations = read_uint(f);
    ios_seek(f, LLT_ALIGN(ios_pos(f), 8));
    assert(!ios_eof(f));
    ios_static_buffer(&relocs, f->buf + f->bpos, sizeof_relocations);
    ios_skip(f, sizeof_relocations);

    sizeof_gvar_record = read_uint(f);
    ios_seek(f, LLT_ALIGN(ios_pos(f), 8));
    assert(!ios_eof(f));
    ios_static_buffer(&gvar_record, f->buf + f->bpos, sizeof_gvar_record);
    ios_skip(f, sizeof_gvar_record);

    sizeof_fptr_record = read_uint(f);
    ios_seek(f, LLT_ALIGN(ios_pos(f), 8));
    assert(!ios_eof(f));
    ios_static_buffer(&fptr_record, f->buf + f->bpos, sizeof_fptr_record);
    ios_skip(f, sizeof_fptr_record);

    // step 2: get references to special values
    ios_seek(f, LLT_ALIGN(ios_pos(f), 8));
    assert(!ios_eof(f));
    }
    if (!s.incremental) {
        reactive_sysimg_size = sizeof_sysdata + sizeof(uintptr_t);
        reactive_const_base = (char*)&const_data.buf[0];
        reactive_const_len = sizeof_constdata;
        reactive_syms_base = (char*)&symbols.buf[0];
        reactive_syms_len = sizeof_symbols;
    }
    s.s = r;
    uintptr_t offset_restored = 0, offset_init_order = 0, offset_extext_methods = 0, offset_new_ext_cis = 0, offset_method_roots_list = 0;
    if (!s.incremental) {
        size_t i;
        for (i = 0; tags[i] != NULL; i++) {
            jl_value_t **tag = tags[i];
            *tag = jl_read_value(&s);
        }
        for (i = 0; i < jl_n_builtins; i++)
            jl_builtin_instances[i] = jl_read_value(&s);
#define XX(name, type) jl_##name = (type)jl_read_value(&s);
        JL_EXPORTED_DATA_POINTERS(XX)
#undef XX
#define XX(name, type) jl_##name = (type)jl_read_value(&s);
        JL_CONST_GLOBAL_VARS(XX)
#undef XX
#define XX(name) \
        ijl_small_typeof[(jl_##name##_tag << 4) / sizeof(*ijl_small_typeof)] = jl_##name##_type;
        JL_SMALL_TYPEOF(XX)
#undef XX
        export_jl_small_typeof();
        export_jl_sysimg_globals();
        jl_global_roots_list = (jl_genericmemory_t*)jl_read_value(&s);
        jl_global_roots_keyset = (jl_genericmemory_t*)jl_read_value(&s);
        s.ptls->root_task->tls = jl_read_value(&s);
        jl_gc_wb(s.ptls->root_task, s.ptls->root_task->tls);

        uint32_t gs_ctr = read_uint32(r);
        jl_require_world = read_uint(r);
        jl_atomic_store_release(&jl_world_counter, jl_require_world);
        jl_typeinf_world = read_uint(r);
        jl_set_gs_ctr(gs_ctr);
    }
    else {
        offset_restored = jl_read_offset(&s);
        offset_init_order = jl_read_offset(&s);
        offset_extext_methods = jl_read_offset(&s);
        offset_new_ext_cis = jl_read_offset(&s);
        offset_method_roots_list = jl_read_offset(&s);
    }
    s.buildid_depmods_idxs = depmod_to_imageidx(depmods);
    size_t nlinks_gctags = read_uint32(r);
    if (nlinks_gctags > 0) {
        s.link_ids_gctags = jl_alloc_array_1d(jl_array_int32_type, nlinks_gctags);
        ios_read(r, (char*)jl_array_data(s.link_ids_gctags, uint32_t), nlinks_gctags * sizeof(uint32_t));
    }
    size_t nlinks_relocs = read_uint32(r);
    if (nlinks_relocs > 0) {
        s.link_ids_relocs = jl_alloc_array_1d(jl_array_int32_type, nlinks_relocs);
        ios_read(r, (char*)jl_array_data(s.link_ids_relocs, uint32_t), nlinks_relocs * sizeof(uint32_t));
    }
    size_t nlinks_gvars = read_uint32(r);
    if (nlinks_gvars > 0) {
        s.link_ids_gvars = jl_alloc_array_1d(jl_array_int32_type, nlinks_gvars);
        ios_read(r, (char*)jl_array_data(s.link_ids_gvars, uint32_t), nlinks_gvars * sizeof(uint32_t));
    }
    size_t nlinks_external_fnvars = read_uint32(r);
    if (nlinks_external_fnvars > 0) {
        s.link_ids_external_fnvars = jl_alloc_array_1d(jl_array_int32_type, nlinks_external_fnvars);
        ios_read(r, (char*)jl_array_data(s.link_ids_external_fnvars, uint32_t), nlinks_external_fnvars * sizeof(uint32_t));
    }
    uint32_t external_fns_begin = read_uint32(r);
    if (s.incremental) {
        assert(restored && init_order && extext_methods && internal_methods && new_ext_cis && method_roots_list);
        *restored = (jl_array_t*)jl_delayed_reloc(&s, offset_restored);
        *init_order = (jl_array_t*)jl_delayed_reloc(&s, offset_init_order);
        *extext_methods = (jl_array_t*)jl_delayed_reloc(&s, offset_extext_methods);
        *new_ext_cis = (jl_array_t*)jl_delayed_reloc(&s, offset_new_ext_cis);
        *method_roots_list = (jl_array_t*)jl_delayed_reloc(&s, offset_method_roots_list);
        *internal_methods = jl_alloc_vec_any(0);
    }
    s.s = NULL;
    s.root_base = NULL;

    // step 3: apply relocations
    assert(sections || !ios_eof(f));
    jl_read_symbols(&s);
    ios_close(&symbols);

    char *image_base = (char*)&sysimg.buf[0];
    reloc_t *relocs_base = (reloc_t*)&relocs.buf[0];
    if (!s.incremental) {
        reactive_image_base = image_base;
        reactive_image_len = sizeof_sysdata;
    }

    s.s = &sysimg;
    jl_read_reloclist(&s, s.link_ids_gctags, GC_OLD_MARKED | GC_IN_IMAGE); // gctags
    size_t sizeof_tags = ios_pos(&relocs);
    (void)sizeof_tags;
    jl_read_reloclist(&s, s.link_ids_relocs, 0); // general relocs
    jl_read_memreflist(&s); // memowner_list relocs (must come before memref_list reads the pointers and after general relocs computes the pointers)
    jl_read_memreflist(&s); // memref_list relocs
    // s.link_ids_gvars will be processed in `jl_update_all_gvars`
    // s.link_ids_external_fns will be processed in `jl_update_all_gvars`
    if (reactive_chain_n > 0) {
        // the chain of an overlay-mode process: every image's record sets
        // its own slots, and every image gets the small typeof table
        for (size_t ci = 0; ci < reactive_chain_n; ci++) {
            ios_t record;
            ios_static_buffer(&record, (char*)reactive_chain[ci].gvar.ptr, reactive_chain[ci].gvar.size);
            s.gvar_record = &record;
            jl_update_all_gvars(&s, &reactive_chain[ci].img, reactive_chain[ci].external_fns_begin);
            memcpy(reactive_chain[ci].img.jl_small_typeof, &jl_small_typeof, sizeof(jl_small_typeof));
        }
        s.gvar_record = &gvar_record;
    }
    else {
        jl_update_all_gvars(&s, image, external_fns_begin); // gvars relocs
    }
    if (s.incremental) {
        jl_read_arraylist(s.relocs, &s.uniquing_types);
        jl_read_arraylist(s.relocs, &s.uniquing_objs);
        jl_read_arraylist(s.relocs, &s.fixup_types);
    }
    else {
        arraylist_new(&s.uniquing_types, 0);
        arraylist_new(&s.uniquing_objs, 0);
        arraylist_new(&s.fixup_types, 0);
    }
    jl_read_arraylist(s.relocs, &s.fixup_objs);
    // Perform the uniquing of objects that we don't "own" and consequently can't promise
    // weren't created by some other package before this one got loaded:
    // - iterate through all objects that need to be uniqued. The first encounter has to be the
    //   "reconstructable blob". We either look up the object (if something has created it previously)
    //   or construct it for the first time, crucially outside the pointer range of any pkgimage.
    //   This ensures it stays unique-worthy.
    // - after we've stored the address of the "real" object (which for convenience we do among the data
    //   written to allow lookup/reconstruction), then we have to update references to that "reconstructable blob":
    //   instead of performing the relocation within the package image, we instead (re)direct all references
    //   to the external object.
    arraylist_t cleanup_list;
    arraylist_new(&cleanup_list, 0);
    arraylist_t delay_list;
    arraylist_new(&delay_list, 0);
    JL_LOCK(&typecache_lock); // Might GC--prevent other threads from changing any type caches while we inspect them all
    for (size_t i = 0; i < s.uniquing_types.len; i++) {
        uintptr_t item = (uintptr_t)s.uniquing_types.items[i];
        // check whether we are operating on the typetag
        // (needing to ignore GC bits) or a regular field
        // and check whether this is a gvar index
        int tag = (item & 3);
        item &= ~(uintptr_t)3;
        uintptr_t *pfld;
        jl_value_t **obj, *newobj;
        if (tag == 3) {
            obj = (jl_value_t**)(image_base + item);
            pfld = NULL;
            for (size_t i = 0; i < delay_list.len; i += 2) {
                if (obj == (jl_value_t **)delay_list.items[i + 0]) {
                    pfld = (uintptr_t*)delay_list.items[i + 1];
                    delay_list.items[i + 1] = arraylist_pop(&delay_list);
                    delay_list.items[i + 0] = arraylist_pop(&delay_list);
                    break;
                }
            }
            assert(pfld);
        }
        else if (tag == 2) {
            if (image->gvars_base == NULL)
                continue;
            item >>= 2;
            assert(item < s.gvar_record->size / sizeof(reloc_t));
            pfld = sysimg_gvars(image->gvars_base, image->gvars_offsets, item);
            obj = *(jl_value_t***)pfld;
        }
        else {
            pfld = (uintptr_t*)(image_base + item);
            if (tag == 1)
                obj = (jl_value_t**)jl_typeof(jl_valueof(pfld));
            else
                obj = *(jl_value_t***)pfld;
            if ((char*)obj > (char*)pfld) {
                // this must be the super field
                assert(tag == 0);
                arraylist_push(&delay_list, obj);
                arraylist_push(&delay_list, pfld);
                // FIXME: leaving the `super` field populated here and then performing
                // type canonicalization is unsound since it intentionally exposes sub-
                // typing to non-canonicalized types (c.f. `jl_type_equality_is_identity`)
                //
                // Type canonicalization requires that any queried types are already
                // canonicalized or that `super` is not needed to decide type-equality.
                // The latter is essentially never true in general (proof is left to the
                // reader) and the former is not possible in the presence of circular types.
                //
                // For now we blindly hope that subtyping rarely inspects `super` and, if
                // it does, that it doesn't compare it against any equal-but-not-yet-
                // canonicalized-to types so that the result is unaffected.
                continue;
            }
        }
        uintptr_t otyp = jl_typetagof(obj);   // the original type of the object that was written here
        assert(image_base < (char*)obj && (char*)obj <= image_base + sizeof_sysimg);
        if (otyp == jl_datatype_tag << 4) {
            jl_datatype_t *dt = (jl_datatype_t*)obj[0], *newdt;
            if (jl_is_datatype(dt)) {
                newdt = dt; // already done
            }
            else {
                dt = (jl_datatype_t*)obj;
                arraylist_push(&cleanup_list, (void*)obj);
                ptrhash_remove(&new_dt_objs, (void*)obj); // unmark obj as invalid before must_be_new_dt
                if (must_be_new_dt((jl_value_t*)dt, &new_dt_objs, image_base, sizeof_sysimg))
                    newdt = NULL;
                else
                    newdt = jl_lookup_cache_type_(dt);
                if (newdt == NULL) {
                    // make a non-owned copy of obj so we don't accidentally
                    // assume this is the unique copy later
                    newdt = jl_new_uninitialized_datatype();
                    jl_astaggedvalue(newdt)->bits.gc = GC_OLD;
                    // leave most fields undefined for now, but we may need instance later,
                    // and we overwrite the name field (field 0) now so preserve it too
                    if (dt->instance) {
                        if (dt->instance == jl_nothing)
                            dt->instance = jl_gc_permobj(ct->ptls, 0, newdt, 0);
                        newdt->instance = dt->instance;
                    }
                    static_assert(offsetof(jl_datatype_t, name) == 0, "");
                    newdt->name = dt->name;
                    ptrhash_put(&new_dt_objs, (void*)newdt, dt);
                }
                else {
                    assert(newdt->hash == dt->hash);
                }
                obj[0] = (jl_value_t*)newdt;
            }
            newobj = (jl_value_t*)newdt;
        }
        else {
            assert(!(image_base < (char*)otyp && (char*)otyp <= image_base + sizeof_sysimg));
            newobj = ((jl_datatype_t*)otyp)->instance;
            assert(newobj && newobj != jl_nothing);
            arraylist_push(&cleanup_list, (void*)obj);
        }
        if (tag == 1)
            *pfld = (uintptr_t)newobj | GC_OLD_MARKED | GC_IN_IMAGE;
        else
            *pfld = (uintptr_t)newobj;
        assert(!(image_base < (char*)newobj && (char*)newobj <= image_base + sizeof_sysimg));
        assert(jl_typetagis(obj, otyp));
    }
    assert(delay_list.len == 0);
    arraylist_free(&delay_list);
    // now that all the fields of dt are assigned and unique, copy them into
    // their final newdt memory location: this ensures we do not accidentally
    // think this pkg image has the singular unique copy of it
    void **table = new_dt_objs.table;
    for (size_t i = 0; i < new_dt_objs.size; i += 2) {
        void *dt = table[i + 1];
        if (dt != HT_NOTFOUND) {
            jl_datatype_t *newdt = (jl_datatype_t*)table[i];
            jl_typename_t *name = newdt->name;
            static_assert(offsetof(jl_datatype_t, name) == 0, "");
            assert(*(void**)dt == (void*)newdt);
            *newdt = *(jl_datatype_t*)dt; // copy the datatype fields (except field 1, which we corrupt above)
            newdt->name = name;
        }
    }
    // we should never see these pointers again, so scramble their memory, so any attempt to look at them crashes
    for (size_t i = 0; i < cleanup_list.len; i++) {
        void *item = cleanup_list.items[i];
        jl_taggedvalue_t *o = jl_astaggedvalue(item);
        jl_value_t *t = jl_typeof(item); // n.b. might be 0xbabababa already
        if (t == (jl_value_t*)jl_datatype_type)
            memset(o, 0xba, sizeof(jl_value_t*) + sizeof(jl_datatype_t));
        else
            memset(o, 0xba, sizeof(jl_value_t*) + 0); // singleton
        o->bits.in_image = 1;
    }
    arraylist_grow(&cleanup_list, -cleanup_list.len);
    // finally cache all our new types now
    jl_safepoint_suspend_all_threads(ct); // past this point, it is now not safe to observe the intermediate states on other threads via reflection, so temporarily pause those
    for (size_t i = 0; i < new_dt_objs.size; i += 2) {
        void *dt = table[i + 1];
        if (dt != HT_NOTFOUND) {
            jl_datatype_t *newdt = (jl_datatype_t*)table[i];
            jl_cache_type_(newdt);
        }
    }
    for (size_t i = 0; i < s.fixup_types.len; i++) {
        uintptr_t item = (uintptr_t)s.fixup_types.items[i];
        jl_value_t *obj = (jl_value_t*)(image_base + item);
        assert(jl_is_datatype(obj));
        jl_cache_type_((jl_datatype_t*)obj);
    }
    JL_UNLOCK(&typecache_lock); // Might GC
    jl_safepoint_resume_all_threads(ct); // TODO: move this later to also protect MethodInstance allocations, but we would need to acquire all jl_specializations_get_linfo and jl_module_globalref locks, which is hard
    // Perform fixups: things like updating world ages, inserting methods & specializations, etc.
    for (size_t i = 0; i < s.uniquing_objs.len; i++) {
        uintptr_t item = (uintptr_t)s.uniquing_objs.items[i];
        // check whether this is a gvar index
        int tag = (item & 3);
        assert(tag == 0 || tag == 2);
        item &= ~(uintptr_t)3;
        uintptr_t *pfld;
        jl_value_t **obj, *newobj;
        if (tag == 2) {
            if (image->gvars_base == NULL)
                continue;
            item >>= 2;
            assert(item < s.gvar_record->size / sizeof(reloc_t));
            pfld = sysimg_gvars(image->gvars_base, image->gvars_offsets, item);
            obj = *(jl_value_t***)pfld;
        }
        else {
            pfld = (uintptr_t*)(image_base + item);
            obj = *(jl_value_t***)pfld;
        }
        uintptr_t otyp = jl_typetagof(obj);   // the original type of the object that was written here
        if (otyp == (uintptr_t)jl_method_instance_type) {
            assert(image_base < (char*)obj && (char*)obj <= image_base + sizeof_sysimg);
            jl_value_t *m = obj[0];
            if (jl_is_method_instance(m)) {
                newobj = m; // already done
            }
            else {
                arraylist_push(&cleanup_list, (void*)obj);
                jl_value_t *specTypes = obj[1];
                jl_value_t *sparams = obj[2];
                newobj = (jl_value_t*)jl_specializations_get_linfo((jl_method_t*)m, specTypes, (jl_svec_t*)sparams);
                obj[0] = newobj;
            }
        }
        else if (otyp == (uintptr_t)jl_binding_type) {
            jl_value_t *m = obj[0];
            if (jl_is_binding(m)) {
                newobj = m; // already done
            }
            else {
                arraylist_push(&cleanup_list, (void*)obj);
                jl_value_t *name = obj[1];
                newobj = (jl_value_t*)jl_get_module_binding((jl_module_t*)m, (jl_sym_t*)name, 1);
                obj[0] = newobj;
            }
        }
        else {
            abort(); // should be unreachable
        }
        *pfld = (uintptr_t)newobj;
        assert(!(image_base < (char*)newobj && (char*)newobj <= image_base + sizeof_sysimg));
        assert(jl_typetagis(obj, otyp));
    }
    arraylist_free(&s.uniquing_types);
    arraylist_free(&s.uniquing_objs);
    for (size_t i = 0; i < cleanup_list.len; i++) {
        void *item = cleanup_list.items[i];
        jl_taggedvalue_t *o = jl_astaggedvalue(item);
        jl_value_t *t = jl_typeof(item);
        if (t == (jl_value_t*)jl_method_instance_type)
            memset(o, 0xba, sizeof(jl_value_t*) * 3); // only specTypes and sparams fields stored
        else if (t == (jl_value_t*)jl_binding_type)
            memset(o, 0xba, sizeof(jl_value_t*) * 3); // stored as mod/name
        o->bits.in_image = 1;
    }
    arraylist_free(&cleanup_list);
    for (size_t i = 0; i < s.fixup_objs.len; i++) {
        uintptr_t item = (uintptr_t)s.fixup_objs.items[i];
        jl_value_t *obj = (jl_value_t*)(image_base + item);
        if (jl_typetagis(obj, jl_typemap_entry_type) || jl_is_method(obj) || jl_is_code_instance(obj)) {
            jl_array_ptr_1d_push(*internal_methods, obj);
            assert(s.incremental);
        }
        else if (jl_is_method_instance(obj)) {
            jl_method_instance_t *newobj = jl_specializations_get_or_insert((jl_method_instance_t*)obj);
            assert(newobj == (jl_method_instance_t*)obj); // strict insertion expected
            (void)newobj;
        }
        else if (jl_is_globalref(obj)) {
            jl_globalref_t *r = (jl_globalref_t*)obj;
            if (r->binding == NULL) {
                jl_globalref_t *gr = (jl_globalref_t*)jl_module_globalref(r->mod, r->name);
                r->binding = gr->binding;
                jl_gc_wb(r, gr->binding);
            }
        }
        else if (jl_is_module(obj)) {
            // rebuild the usings table for module v
            // TODO: maybe want to hold the lock on `v`, but that only strongly matters for async / thread safety
            // and we are already bad at that
            jl_module_t *mod = (jl_module_t*)obj;
            mod->build_id.hi = checksum;
            if (mod->usings.items != &mod->usings._space[0]) {
                // arraylist_t assumes we called malloc to get this memory, so make that true now
                void **newitems = (void**)malloc_s(mod->usings.max * sizeof(void*));
                memcpy(newitems, mod->usings.items, mod->usings.len * sizeof(void*));
                mod->usings.items = newitems;
            }
            size_t mod_idx = external_blob_index((jl_value_t*)mod);
            if (s.incremental) {
                // Rebuild cross-image usings backedges
                for (size_t i = 0; i < module_usings_length(mod); ++i) {
                    struct _jl_module_using *data = module_usings_getidx(mod, i);
                    if (external_blob_index((jl_value_t*)data->mod) != mod_idx) {
                        jl_add_usings_backedge(data->mod, mod);
                    }
                }
            }
        }
        else {
            abort();
        }
    }
    if (s.incremental) {
        int no_replacement = jl_atomic_load_relaxed(&jl_first_image_replacement_world) == ~(size_t)0;
        for (size_t i = 0; i < s.fixup_objs.len; i++) {
            uintptr_t item = (uintptr_t)s.fixup_objs.items[i];
            jl_value_t *obj = (jl_value_t*)(image_base + item);
            if (jl_is_module(obj)) {
                jl_module_t *mod = (jl_module_t*)obj;
                size_t mod_idx = external_blob_index((jl_value_t*)mod);
                jl_svec_t *table = jl_atomic_load_relaxed(&mod->bindings);
                int unchanged_implicit = no_replacement || all_usings_unchanged_implicit(mod);
                for (size_t i = 0; i < jl_svec_len(table); i++) {
                    jl_binding_t *b = (jl_binding_t*)jl_svecref(table, i);
                    if ((jl_value_t*)b == jl_nothing)
                        continue;
                    jl_binding_partition_t *bpart = jl_atomic_load_relaxed(&b->partitions);
                    if (!jl_validate_binding_partition(b, bpart, mod_idx, unchanged_implicit, no_replacement)) {
                        unchanged_implicit = all_usings_unchanged_implicit(mod);
                    }
                }
            }
        }
    }
    arraylist_free(&s.fixup_types);
    arraylist_free(&s.fixup_objs);

    if (s.incremental)
        jl_root_new_gvars(&s, image, external_fns_begin);
    ios_close(&relocs);
    ios_close(&const_data);
    ios_close(&gvar_record);

    htable_free(&new_dt_objs);

    s.s = NULL;

    if (0) {
        printf("sysimg size breakdown:\n"
               "     sys data: %8u\n"
               "  isbits data: %8u\n"
               "      symbols: %8u\n"
               "    tags list: %8u\n"
               "   reloc list: %8u\n"
               "    gvar list: %8u\n"
               "    fptr list: %8u\n",
            (unsigned)sizeof_sysdata,
            (unsigned)sizeof_constdata,
            (unsigned)sizeof_symbols,
            (unsigned)sizeof_tags,
            (unsigned)(sizeof_relocations - sizeof_tags),
            (unsigned)sizeof_gvar_record,
            (unsigned)sizeof_fptr_record);
    }
    if (cachesizes) {
        cachesizes->sysdata = sizeof_sysdata;
        cachesizes->isbitsdata = sizeof_constdata;
        cachesizes->symboldata = sizeof_symbols;
        cachesizes->tagslist = sizeof_tags;
        cachesizes->reloclist = sizeof_relocations - sizeof_tags;
        cachesizes->gvarlist = sizeof_gvar_record;
        cachesizes->fptrlist = sizeof_fptr_record;
    }

    s.s = &sysimg;
    jl_update_all_fptrs(&s, image); // fptr relocs and registration
    if (reactive_chain_n > 0) {
        // the chain: the external-function slots of every overlay take the
        // pointers of the code instances, which the fresh table set now
        for (size_t ci = 0; ci < reactive_chain_n; ci++) {
            ios_t record;
            ios_static_buffer(&record, (char*)reactive_chain[ci].gvar.ptr, reactive_chain[ci].gvar.size);
            s.gvar_record = &record;
            jl_root_new_gvars(&s, &reactive_chain[ci].img, reactive_chain[ci].external_fns_begin);
        }
        s.gvar_record = &gvar_record;
    }
    s.s = NULL;

    ios_close(&fptr_record);
    ios_close(&sysimg);

    if (!s.incremental)
        jl_gc_reset_alloc_count();
    if (!s.incremental && reactive_pages_mode() && !reactive_base_syms_kept) {
        // The base symbols keep their index in a page-written image.
        arraylist_new(&reactive_base_syms, deser_sym.len);
        memcpy(reactive_base_syms.items, deser_sym.items, deser_sym.len * sizeof(void*));
        reactive_base_syms.len = deser_sym.len;
        reactive_base_syms_kept = 1;
    }
    arraylist_free(&deser_sym);

    // Prepare for later external linkage against the sysimg
    // Also sets up images for protection against garbage collection
    arraylist_push(&jl_linkage_blobs, (void*)image_base);
    arraylist_push(&jl_linkage_blobs, (void*)(image_base + sizeof_sysimg));
    arraylist_push(&jl_image_relocs, (void*)relocs_base);
    if (restored == NULL) {
        arraylist_push(&jl_top_mods, (void*)jl_top_module);
    } else {
        size_t len = jl_array_nrows(*restored);
        assert(len > 0);
        jl_module_t *topmod = (jl_module_t*)jl_array_ptr_ref(*restored, len-1);
        // Ordinarily set during deserialization, but our compiler stub image,
        // just returns a reference to the sysimage version, so we set it here.
        topmod->build_id.hi = checksum;
        assert(jl_is_module(topmod));
        arraylist_push(&jl_top_mods, (void*)topmod);
    }
    jl_timing_counter_inc(JL_TIMING_COUNTER_ImageSize, sizeof_sysimg + sizeof(uintptr_t));
    rebuild_image_blob_tree();

    // jl_printf(JL_STDOUT, "%ld blobs to link against\n", jl_linkage_blobs.len >> 1);
    jl_gc_enable(en);

    if (s.incremental) {
        jl_add_methods(*extext_methods);
    }
    else {
        if (reactive_region_base != NULL)
            reactive_dirty_protect(reactive_region_base, reactive_sysimg_size);
        else
            reactive_dirty_protect(reactive_image_base, reactive_image_len);
        if (reactive_pages_mode() && reactive_dirty_start != NULL) {
            // The base is mapped now: a save may replace the file later.
            if (reactive_region_base == NULL && !reactive_base_map())
                jl_safe_printf("reactive: pages: the base image has no file bytes; every save writes whole\n");
            reactive_page_hashes = (uint64_t*)malloc_s(reactive_dirty_npages * sizeof(uint64_t));
            for (size_t i = 0; i < reactive_dirty_npages; i++) {
                char *page = reactive_dirty_start + i * jl_page_size;
                if (reactive_gap_lo != NULL && page >= reactive_gap_lo && page < reactive_gap_hi)
                    reactive_page_hashes[i] = 0;    // the gap of the region: never written
                else
                    reactive_page_hashes[i] = reactive_page_hash(page);
            }
        }
    }
}

static jl_value_t *jl_validate_cache_file(ios_t *f, jl_array_t *depmods, uint64_t *checksum, int64_t *dataendpos, int64_t *datastartpos)
{
    uint8_t pkgimage = 0;
    if (ios_eof(f) || 0 == (*checksum = jl_read_verify_header(f, &pkgimage, dataendpos, datastartpos)) || (*checksum >> 32 != 0xfafbfcfd)) {
        return jl_get_exceptionf(jl_errorexception_type,
                "Precompile file header verification checks failed.");
    }
    uint8_t flags = read_uint8(f);
    if (pkgimage && !jl_match_cache_flags_current(flags)) {
        return jl_get_exceptionf(jl_errorexception_type, "Pkgimage flags mismatch");
    }
    if (!pkgimage) {
        // skip past the worklist
        size_t len;
        while ((len = read_int32(f)))
            ios_skip(f, len + 3 * sizeof(uint64_t));
        // skip past the dependency list
        size_t deplen = read_uint64(f);
        ios_skip(f, deplen - sizeof(uint64_t));
        read_uint64(f); // where is this write coming from?
    }

    // verify that the system state is valid
    return read_verify_mod_list(f, depmods);
}

// TODO?: refactor to make it easier to create the "package inspector"
static jl_value_t *jl_restore_package_image_from_stream(ios_t *f, jl_image_t *image, jl_array_t *depmods, int completeinfo, const char *pkgname, int needs_permalloc)
{
    JL_TIMING(LOAD_IMAGE, LOAD_Pkgimg);
    jl_timing_printf(JL_TIMING_DEFAULT_BLOCK, pkgname);
    uint64_t checksum = 0;
    int64_t dataendpos = 0;
    int64_t datastartpos = 0;
    jl_value_t *verify_fail = jl_validate_cache_file(f, depmods, &checksum, &dataendpos, &datastartpos);

    if (verify_fail)
        return verify_fail;

    assert(datastartpos > 0 && datastartpos < dataendpos);
    needs_permalloc = jl_options.permalloc_pkgimg || needs_permalloc;

    jl_value_t *restored = NULL;
    jl_array_t *init_order = NULL, *extext_methods = NULL, *internal_methods = NULL, *new_ext_cis = NULL, *method_roots_list = NULL;
    jl_svec_t *cachesizes_sv = NULL;
    JL_GC_PUSH7(&restored, &init_order, &extext_methods, &internal_methods, &new_ext_cis, &method_roots_list, &cachesizes_sv);

    { // make a permanent in-memory copy of f (excluding the header)
        ios_bufmode(f, bm_none);
        JL_SIGATOMIC_BEGIN();
        size_t len = dataendpos - datastartpos;
        char *sysimg;
        int success = !needs_permalloc;
        ios_seek(f, datastartpos);
        if (needs_permalloc)
            sysimg = (char*)jl_gc_perm_alloc(len, 0, 64, 0);
        else
            sysimg = &f->buf[f->bpos];
        if (needs_permalloc)
            success = ios_readall(f, sysimg, len) == len;
        if (!success) {
            restored = jl_get_exceptionf(jl_errorexception_type, "Error reading package image file.");
            JL_SIGATOMIC_END();
        }
        else {
            if (needs_permalloc)
                ios_close(f);
            ios_static_buffer(f, sysimg, len);
            pkgcachesizes cachesizes;
            jl_restore_system_image_from_stream_(f, image, depmods, checksum, (jl_array_t**)&restored, &init_order, &extext_methods, &internal_methods, &new_ext_cis, &method_roots_list, &cachesizes);
            JL_SIGATOMIC_END();

            // Add roots to methods
            int failed = jl_copy_roots(method_roots_list, jl_worklist_key((jl_array_t*)restored));
            if (failed != 0) {
                jl_printf(JL_STDERR, "Error copying roots to methods from Module: %s\n", pkgname);
                abort();
            }
            // Insert method extensions and handle edges
            int new_methods = jl_array_nrows(extext_methods) > 0;
            if (!new_methods) {
                size_t i, l = jl_array_nrows(internal_methods);
                for (i = 0; i < l; i++) {
                    jl_value_t *obj = jl_array_ptr_ref(internal_methods, i);
                    if (jl_is_method(obj)) {
                        new_methods = 1;
                        break;
                    }
                }
            }
            JL_LOCK(&world_counter_lock);
            // allocate a world for the new methods, and insert them there, invalidating content as needed
            size_t world = jl_atomic_load_relaxed(&jl_world_counter);
            if (new_methods)
                world += 1;
            jl_activate_methods(extext_methods, internal_methods, world, pkgname);
            // TODO: inject internal_methods into caches here, so the system can see them immediately as potential candidates (before validation)
            // allow users to start running in this updated world
            if (new_methods)
                jl_atomic_store_release(&jl_world_counter, world);
            // now permit more methods to be added again
            JL_UNLOCK(&world_counter_lock);

            if (completeinfo) {
                cachesizes_sv = jl_alloc_svec(7);
                jl_svecset(cachesizes_sv, 0, jl_box_long(cachesizes.sysdata));
                jl_svecset(cachesizes_sv, 1, jl_box_long(cachesizes.isbitsdata));
                jl_svecset(cachesizes_sv, 2, jl_box_long(cachesizes.symboldata));
                jl_svecset(cachesizes_sv, 3, jl_box_long(cachesizes.tagslist));
                jl_svecset(cachesizes_sv, 4, jl_box_long(cachesizes.reloclist));
                jl_svecset(cachesizes_sv, 5, jl_box_long(cachesizes.gvarlist));
                jl_svecset(cachesizes_sv, 6, jl_box_long(cachesizes.fptrlist));
                // Surface extext_methods and new_ext_cis to external inspectors (e.g. PkgCacheInspector.jl).
                // With the single global jl_method_table, `extext_methods` contains *all* worklist methods
                // (not just externally-extending ones); `internal_methods` overlaps it and exists only for
                // per-object world-stamp updates during the fixup walk.
                restored = (jl_value_t*)jl_svec(7, restored, init_order, internal_methods, extext_methods, new_ext_cis, method_roots_list, cachesizes_sv);
            }
            else {
                restored = (jl_value_t*)jl_svec(3, restored, init_order, internal_methods);
            }
        }
    }

    JL_GC_POP();
    return restored;
}

static void jl_restore_system_image_from_stream(ios_t *f, jl_image_t *image, uint32_t checksum)
{
    JL_TIMING(LOAD_IMAGE, LOAD_Sysimg);
    jl_restore_system_image_from_stream_(f, image, NULL, checksum | ((uint64_t)0xfdfcfbfa << 32), NULL, NULL, NULL, NULL, NULL, NULL, NULL);
}

JL_DLLEXPORT jl_value_t *jl_restore_incremental_from_buf(jl_image_buf_t buf, jl_image_t *image, jl_array_t *depmods, int completeinfo, const char *pkgname, int needs_permalloc)
{
    ios_t f;
    ios_static_buffer(&f, (char*)buf.data, buf.size);
    jl_value_t *ret = jl_restore_package_image_from_stream(&f, image, depmods, completeinfo, pkgname, needs_permalloc);
    ios_close(&f);
    return ret;
}

JL_DLLEXPORT jl_value_t *jl_restore_incremental(const char *fname, jl_array_t *depmods, int completeinfo, const char *pkgname)
{
    ios_t f;
    if (ios_file(&f, fname, 1, 0, 0, 0) == NULL) {
        return jl_get_exceptionf(jl_errorexception_type,
            "Cache file \"%s\" not found.\n", fname);
    }
    jl_image_t pkgimage = {};
    jl_value_t *ret = jl_restore_package_image_from_stream(&f, &pkgimage, depmods, completeinfo, pkgname, 1);
    ios_close(&f);
    return ret;
}

// --- Reactive reuse of the loaded system image ---
//
// A build with JULIA_REACTIVE_REUSE=1 boots from a system image A and emits
// only the code that A does not hold. The delta is linked with A's text
// objects, so A's functions and global slots keep their ids and the delta
// appends to them. This is the runtime side: a copy of the parsed image
// (`jl_update_all_fptrs` clears `gvars_base` of the original), the world
// counter after the restore, and a map from a native pointer to A's
// function id.

static jl_image_t reactive_image;
static int reactive_image_loaded = 0;
static uint32_t reactive_nshards = 0;
static uint32_t reactive_image_version = 0;
static size_t reactive_base_world = 0;

typedef struct {
    void *addr;
    uint32_t id; // 1-based position in A's function table
} reactive_fptr_entry_t;
static reactive_fptr_entry_t *reactive_fptr_map = NULL;
static size_t reactive_fptr_map_len = 0;

static int reactive_fptr_entry_cmp(const void *a, const void *b) JL_NOTSAFEPOINT
{
    uintptr_t x = (uintptr_t)((const reactive_fptr_entry_t*)a)->addr;
    uintptr_t y = (uintptr_t)((const reactive_fptr_entry_t*)b)->addr;
    return x < y ? -1 : x > y ? 1 : 0;
}

// The id of `addr` in A's function table, or 0 when it is not an entry.
static uint32_t reactive_fptr_id(void *addr) JL_NOTSAFEPOINT
{
    if (addr == NULL)
        return 0;
    if (reactive_fptr_map == NULL) {
        jl_image_fptrs_t *fptrs = &reactive_image.fptrs;
        reactive_fptr_map = (reactive_fptr_entry_t*)malloc_s(sizeof(reactive_fptr_entry_t) * (fptrs->nptrs + 1));
        size_t n = 0;
        uint32_t clone_idx = 0;
        for (uint32_t i = 0; i < fptrs->nptrs; i++) {
            void *p = fptrs->ptrs[i];
            // a cloned function is reached through its clone pointer; the
            // clone indices are sorted, as in `jl_update_all_fptrs`
            for (; clone_idx < fptrs->nclones; clone_idx++) {
                uint32_t idx = fptrs->clone_idxs[clone_idx] & jl_sysimg_val_mask;
                if (idx < i)
                    continue;
                if (idx == i)
                    p = fptrs->clone_ptrs[clone_idx];
                break;
            }
            if (p == NULL)
                continue;
            reactive_fptr_map[n].addr = p;
            reactive_fptr_map[n].id = i + 1;
            n++;
        }
        qsort(reactive_fptr_map, n, sizeof(reactive_fptr_entry_t), reactive_fptr_entry_cmp);
        reactive_fptr_map_len = n;
    }
    size_t lo = 0, hi = reactive_fptr_map_len;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if ((uintptr_t)reactive_fptr_map[mid].addr < (uintptr_t)addr)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo < reactive_fptr_map_len && reactive_fptr_map[lo].addr == addr)
        return reactive_fptr_map[lo].id;
    return 0;
}

JL_DLLEXPORT int jl_reactive_reuse_enabled(void) JL_NOTSAFEPOINT
{
    if (!reactive_image_loaded)
        return 0;
    const char *env = getenv("JULIA_REACTIVE_REUSE");
    return env != NULL && env[0] == '1' && env[1] == '\0';
}

// The output file of the next image write, the `--output-o` of this
// process; NULL clears it, and then the exit writes no image. A compiler
// server writes one image per save through a forked child, so the path
// changes while the process lives. The copy of the path is never freed: a
// save is rare and the string small.
JL_DLLEXPORT void jl_reactive_set_output(const char *path) JL_NOTSAFEPOINT
{
    jl_options.outputo = path ? strdup(path) : NULL;
}

// The trim of the next image write: the trimmed product of a save (Stage E
// of the plan) is written by a forked child that sets it, with the IR and
// the metadata stripped as `juliac` does; the parent keeps them.
JL_DLLEXPORT void jl_reactive_set_trim(int on) JL_NOTSAFEPOINT
{
    jl_options.trim = on ? JL_TRIM_SAFE : JL_TRIM_NO;
    jl_options.strip_ir = on;
    jl_options.strip_metadata = on;
}

// The level of the timing report: 0 off, 1 the times and the counts, 2 also
// one line per code instance of the delta
JL_DLLEXPORT int jl_reactive_timings(void) JL_NOTSAFEPOINT
{
    const char *env = getenv("JULIA_REACTIVE_TIMINGS");
    if (env == NULL || env[0] < '0' || env[0] > '9' || env[1] != '\0')
        return 0;
    return env[0] - '0';
}

// Whether this build emits the reactive image format (version 3): asked
// for with JULIA_REACTIVE_IMAGE=1, and implied by reuse.
JL_DLLEXPORT int jl_reactive_image_format(void) JL_NOTSAFEPOINT
{
    if (jl_reactive_reuse_enabled())
        return 1;
    const char *env = getenv("JULIA_REACTIVE_IMAGE");
    return env != NULL && env[0] == '1' && env[1] == '\0';
}

// The format version of the loaded image, 0 without one
JL_DLLEXPORT uint32_t jl_reactive_base_version(void) JL_NOTSAFEPOINT
{
    return reactive_image_loaded ? reactive_image_version : 0;
}

JL_DLLEXPORT uint32_t jl_reactive_base_nfvars(void) JL_NOTSAFEPOINT
{
    return jl_reactive_reuse_enabled() ? reactive_image.fptrs.nptrs : 0;
}

JL_DLLEXPORT uint32_t jl_reactive_base_ngvars(void) JL_NOTSAFEPOINT
{
    // an overlay is an image of its own: its slots and shards start at 0
    return jl_reactive_reuse_enabled() && !reactive_overlay_mode() ? reactive_image.ngvars : 0;
}

JL_DLLEXPORT uint32_t jl_reactive_base_nshards(void) JL_NOTSAFEPOINT
{
    return jl_reactive_reuse_enabled() && !reactive_overlay_mode() ? reactive_nshards : 0;
}

JL_DLLEXPORT size_t jl_reactive_base_world(void) JL_NOTSAFEPOINT
{
    return jl_reactive_reuse_enabled() ? reactive_base_world : 0;
}

// The value that A's global slot `i` holds now: the object the emitted code
// of A names through that slot.
JL_DLLEXPORT void *jl_reactive_base_gvar(uint32_t i) JL_NOTSAFEPOINT
{
    assert(i < reactive_image.ngvars);
    return *(void**)sysimg_gvars(reactive_image.gvars_base, reactive_image.gvars_offsets, i);
}

// Whether A exports the symbol `name`: the alias of a `@ccallable` method that
// A defined. The delta must not define it again, because A's text objects are
// linked in front of the delta and the link sees the symbol twice. A's alias
// stays correct for a redefined method: the wrapper behind it resolves its
// target through `jl_get_abi_converter` in the current world.
JL_DLLEXPORT int jl_reactive_image_exports(const char *name) JL_NOTSAFEPOINT
{
    if (!jl_reactive_reuse_enabled() || reactive_image_handle == NULL)
        return 0;
    void *addr = NULL;
    return jl_dlsym(reactive_image_handle, name, &addr, 0, 0) && addr != NULL;
}

// The function ids of `ci` in A's function table, in the form `jl_get_function_id`
// gives them: the invoke id is the wrapper's id, or -1 for `jl_fptr_args`, -2
// for `jl_fptr_sparam`, -4 for `jl_f_opaque_closure_call`; the spec id is the
// id of the specialized function. Returns 0 when `ci` has no native code in A.
// The out pointers can be NULL.
JL_DLLEXPORT int jl_reactive_image_ids(jl_code_instance_t *ci, int32_t *invokeptr_id, int32_t *specfptr_id) JL_NOTSAFEPOINT
{
    if (!jl_reactive_reuse_enabled())
        return 0;
    if (!(jl_atomic_load_relaxed(&ci->flags) & JL_CI_FLAGS_FROM_IMAGE))
        return 0;
    uint32_t spec = reactive_fptr_id(jl_atomic_load_relaxed(&ci->specptr.fptr));
    if (spec == 0)
        return 0;
    jl_callptr_t invoke = jl_atomic_load_relaxed(&ci->invoke);
    int32_t inv;
    if (invoke == jl_fptr_args_addr)
        inv = -1;
    else if (invoke == jl_fptr_sparam_addr)
        inv = -2;
    else if (invoke == jl_f_opaque_closure_call_addr)
        inv = -4;
    else {
        uint32_t wrapper = reactive_fptr_id((void*)invoke);
        if (wrapper == 0 || wrapper >= spec)
            return 0;
        inv = (int32_t)wrapper;
    }
    if (invokeptr_id)
        *invokeptr_id = inv;
    if (specfptr_id)
        *specfptr_id = (int32_t)spec;
    return 1;
}

// The symbol name of the function with the 1-based id `id` in A's function
// table: the name the delta declares to call it directly. The names are those
// of A's base target.
JL_DLLEXPORT const char *jl_reactive_image_fname(int32_t id) JL_NOTSAFEPOINT
{
    if (!jl_reactive_reuse_enabled() || id <= 0 || (uint32_t)id > reactive_image.fptrs.nptrs)
        return NULL;
    if (reactive_image.fptrs.names == NULL)
        return NULL;
    return reactive_image.fptrs.names[id - 1];
}

// Overlay mode (Stage G): the sysimg of the base is mapped from its file
// into a reserved region, with headroom for the new objects of the
// overlays; the const data is copied after the headroom. The rest of the
// sections stay in the blob of the shared object. Answers 0 when the
// region cannot be made, and the image loads in place.
static int reactive_region_load(jl_image_buf_t buf)
{
    reactive_sections_t sec;
    if (!reactive_parse_blob((const char*)buf.data, buf.size, &sec))
        return 0;
    const char *fname = NULL;
    size_t file_off = 0;
    if (!reactive_blob_file(buf.data, &fname, &file_off)) {
        jl_safe_printf("reactive: overlay: the blob of the image has no file; the image loads in place\n");
        return 0;
    }
    size_t page = jl_getpagesize();
    if (file_off % page != 0) {
        jl_safe_printf("reactive: overlay: the blob is not page aligned in its file; the image loads in place\n");
        return 0;
    }
    const char *blob = (const char*)buf.data;
    size_t const_start = sec.const_data.ptr - blob;
    size_t mapped = LLT_ALIGN(const_start + sec.const_data.size, page);
    size_t const_limit = mapped + REACTIVE_CONST_HEADROOM;
    size_t span = const_limit + REACTIVE_SYSIMG_HEADROOM;
    char *region = (char*)mmap(NULL, span, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (region == MAP_FAILED) {
        jl_safe_printf("reactive: overlay: the region of %zu MB cannot be reserved; the image loads in place\n", span >> 20);
        return 0;
    }
    int fd = open(fname, O_RDONLY);
    if (fd < 0 || mmap(region, mapped, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_FIXED, fd, file_off) == MAP_FAILED) {
        jl_safe_printf("reactive: overlay: the base cannot be mapped from %s; the image loads in place\n", fname);
        if (fd >= 0)
            close(fd);
        munmap(region, span);
        return 0;
    }
    close(fd);
    reactive_region_base = region;
    reactive_region_span = span;
    reactive_region_const = region + const_start;
    reactive_region_const_limit = region + const_limit;
    reactive_gap_lo = region + mapped;
    reactive_gap_hi = region + const_limit;
    reactive_objects_end = sec.sysimg.size;
    reactive_base_end = sec.sysimg.size;
    reactive_sections = sec;
    reactive_sections.sysimg.ptr = region;
    reactive_sections.sysimg.size = const_limit;     // the new objects of an overlay start here
    reactive_sections.const_data.ptr = region + const_start;
    reactive_sections.blob_span = const_limit;
    reactive_sections_on = 1;
    if (jl_reactive_timings())
        jl_safe_printf("reactive: overlay: the base loads in a region of %zu MB (sysimg %zu MB, const %zu MB)\n",
                       span >> 20, sec.sysimg.size >> 20, sec.const_data.size >> 20);
    return 1;
}

static jl_image_buf_t get_image_buf(void *handle, int is_pkgimage);

// Grow the sysimg of the region to `size` bytes: the headroom pages it
// needs become writable.
static int reactive_region_grow_sysimg(size_t size)
{
    size_t page = jl_getpagesize();
    size_t have = LLT_ALIGN(reactive_sections.sysimg.size, page);
    size_t need = LLT_ALIGN(size, page);
    if (need > reactive_region_span)
        return 0;
    if (need > have && mprotect(reactive_region_base + have, need - have, PROT_READ | PROT_WRITE) != 0)
        return 0;
    return 1;
}

static int reactive_region_grow_const(size_t size)
{
    // the const data starts inside a page: the growth works in whole pages
    size_t page = jl_getpagesize();
    char *cur_end = reactive_region_const + reactive_sections.const_data.size;
    char *new_end = reactive_region_const + size;
    if (new_end > reactive_region_const_limit)
        return 0;
    char *lo = (char*)((uintptr_t)cur_end & ~(uintptr_t)(page - 1));
    char *hi = (char*)LLT_ALIGN((uintptr_t)new_end, page);
    if (hi > lo && mprotect(lo, hi - lo, PROT_READ | PROT_WRITE) != 0)
        return 0;
    return 1;
}

// Apply the chain of overlays named by `<image file>.chain`, one path per
// line relative to the image's directory: each overlay's new objects go
// after the current end, its patches over the pages they name, and its
// function table composes with the current one through its reuse map;
// the last overlay's lists, records and roots restore the image. The
// base image `image` becomes the composed image.
static void reactive_chain_load(jl_image_t *image)
{
    const char *image_file = jl_options.image_file;
    if (image_file == NULL)
        return;
    size_t flen = strlen(image_file);
    char *chain_path = (char*)malloc_s(flen + 8);
    memcpy(chain_path, image_file, flen);
    strcpy(chain_path + flen, ".chain");
    FILE *chain = fopen(chain_path, "r");
    if (chain == NULL) {
        free(chain_path);
        return;
    }
    char *dir = (char*)malloc_s(flen + 1);
    memcpy(dir, image_file, flen + 1);
    char *slash = strrchr(dir, '/');
    if (slash)
        *slash = '\0';
    // the base is the first image of the chain
    reactive_chain_n = 0;
    reactive_chain[0].img = *image;
    reactive_chain[0].gvar = reactive_sections.gvar;
    reactive_chain[0].external_fns_begin = (uint32_t)(reactive_sections.gvar.size / sizeof(reloc_t));
    reactive_chain_n = 1;
    jl_image_fptrs_t composed = image->fptrs;
    size_t page = jl_getpagesize();
    char line[4096];
    size_t applied = 0;
    while (fgets(line, sizeof(line), chain) != NULL) {
        size_t n = strlen(line);
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r' || line[n - 1] == ' '))
            line[--n] = '\0';
        if (n == 0 || line[0] == '#')
            continue;
        char *path = (char*)malloc_s(strlen(dir) + n + 2);
        if (line[0] == '/')
            strcpy(path, line);
        else
            sprintf(path, "%s/%s", dir, line);
        void *handle = jl_load_dynamic_library(path, JL_RTLD_LOCAL | JL_RTLD_NOW, 1);
        jl_image_buf_t ob = get_image_buf(handle, 0);
        const reactive_overlay_header_t *h = (const reactive_overlay_header_t*)ob.data;
        if (ob.size < sizeof(*h) || h->magic != REACTIVE_OVERLAY_MAGIC)
            jl_errorf("reactive: overlay %s is not an overlay image", path);
        if (h->base_sysimg_size != reactive_sections.sysimg.size || h->base_const_size != reactive_sections.const_data.size ||
            h->base_syms_size != reactive_sections.symbols.size || h->page_size != page)
            jl_errorf("reactive: overlay %s extends another state (sysimg %zu, const %zu, symbols %zu; loaded %zu, %zu, %zu)", path,
                      (size_t)h->base_sysimg_size, (size_t)h->base_const_size, (size_t)h->base_syms_size,
                      reactive_sections.sysimg.size, reactive_sections.const_data.size, reactive_sections.symbols.size);
        if (reactive_chain_n >= REACTIVE_CHAIN_MAX)
            jl_errorf("reactive: the chain holds more than %d overlays", REACTIVE_CHAIN_MAX);
        const char *blob = (const char*)ob.data;
        // the new objects, then the patches over the pages they name
        size_t new_sysimg = reactive_sections.sysimg.size + h->new_sysimg_size;
        if (!reactive_region_grow_sysimg(new_sysimg))
            jl_errorf("reactive: overlay %s: no room for %zu KB of new objects", path, (size_t)h->new_sysimg_size / 1024);
        memcpy(reactive_region_base + reactive_sections.sysimg.size, blob + h->off_new_sysimg, h->new_sysimg_size);
        size_t new_const = reactive_sections.const_data.size + h->new_const_size;
        if (!reactive_region_grow_const(new_const))
            jl_errorf("reactive: overlay %s: no room for %zu KB of new const data", path, (size_t)h->new_const_size / 1024);
        memcpy(reactive_region_const + reactive_sections.const_data.size, blob + h->off_new_const, h->new_const_size);
        const uint32_t *pidx = (const uint32_t*)(blob + h->off_patch_idx_sysimg);
        for (size_t i = 0; i < h->npatch_sysimg; i++) {
            size_t off = (size_t)pidx[i] * page;
            size_t n = off + page <= new_sysimg ? page : new_sysimg - off;
            memcpy(reactive_region_base + off, blob + h->off_patch_sysimg + i * page, n);
        }
        pidx = (const uint32_t*)(blob + h->off_patch_idx_const);
        for (size_t i = 0; i < h->npatch_const; i++) {
            size_t off = (size_t)pidx[i] * page;
            size_t n = off + page <= new_const ? page : new_const - off;
            memcpy(reactive_region_const + off, blob + h->off_patch_const + i * page, n);
        }
        // the symbols: the base's and every overlay's, concatenated
        size_t new_syms = reactive_sections.symbols.size + h->new_syms_size;
        char *syms = (char*)malloc_s(new_syms + 1);
        memcpy(syms, reactive_sections.symbols.ptr, reactive_sections.symbols.size);
        memcpy(syms + reactive_sections.symbols.size, blob + h->off_new_syms, h->new_syms_size);
        free(reactive_syms_buffer);
        reactive_syms_buffer = syms;
        // the sections of the composed state
        reactive_sections.sysimg.size = new_sysimg;
        reactive_sections.const_data.size = new_const;
        reactive_sections.symbols.ptr = syms;
        reactive_sections.symbols.size = new_syms;
        reactive_sections.relocs.ptr = blob + h->off_relocs;
        reactive_sections.relocs.size = h->relocs_size;
        reactive_sections.gvar.ptr = blob + h->off_gvar;
        reactive_sections.gvar.size = h->gvar_size;
        reactive_sections.fptr.ptr = blob + h->off_fptr;
        reactive_sections.fptr.size = h->fptr_size;
        reactive_sections.roots.ptr = blob + h->off_roots;
        reactive_sections.roots.size = h->roots_size;
        // the blob spans the sysimg extent: the base, the const data inside
        // it, the headroom, and the objects of every overlay
        reactive_sections.blob_span = new_sysimg;
        // the image of the overlay: its own functions, slots and clones
        jl_image_t oimg = jl_init_processor_pkgimg(ob);   // the JIT target of the base; this parses only
        const uint32_t *reuse = NULL;
        jl_dlsym(handle, "jl_fvar_reuse", (void**)&reuse, 0, 0);
        uint32_t nptrs = oimg.fptrs.nptrs;
        void **ptrs = (void**)malloc_s(sizeof(void*) * (nptrs + 1));
        for (uint32_t k = 0; k < nptrs; k++) {
            uint32_t src = reuse ? reuse[k] : 0;
            if (src != 0) {
                if (src > composed.nptrs)
                    jl_errorf("reactive: overlay %s reuses function %u of a table of %u", path, src, composed.nptrs);
                ptrs[k] = composed.ptrs[src - 1];
            }
            else {
                ptrs[k] = oimg.fptrs.ptrs[k];
            }
        }
        composed.nptrs = nptrs;
        composed.ptrs = ptrs;
        composed.names = oimg.fptrs.names;
        composed.nclones = 0;
        composed.clone_ptrs = NULL;
        composed.clone_idxs = NULL;
        reactive_chain[reactive_chain_n].img = oimg;
        reactive_chain[reactive_chain_n].gvar = reactive_sections.gvar;
        reactive_chain[reactive_chain_n].external_fns_begin = h->external_fns_begin;
        reactive_chain_n++;
        applied++;
        if (jl_reactive_timings())
            jl_safe_printf("reactive: overlay %s: %zu + %zu pages patched, %zu KB new objects, %u functions of which %u reused\n",
                           line, (size_t)h->npatch_sysimg, (size_t)h->npatch_const, (size_t)h->new_sysimg_size / 1024,
                           nptrs, (uint32_t)(reuse ? 0 : 0));
        free(path);
    }
    fclose(chain);
    free(chain_path);
    free(dir);
    if (applied == 0) {
        reactive_chain_n = 0;
        return;
    }
    image->fptrs = composed;
    reactive_objects_end = reactive_sections.sysimg.size;
    reactive_gap_lo = reactive_region_base + LLT_ALIGN(reactive_region_const + reactive_sections.const_data.size - reactive_region_base, page);
}

// An image with a chain file beside it loads through the region and the
// chain, whatever the environment: the launcher of a bundle and the oracle
// know nothing of the mode; the mode itself makes a process that will
// save an overlay load through the region.
static int reactive_chain_exists(void) JL_NOTSAFEPOINT
{
    const char *image_file = jl_options.image_file;
    if (image_file == NULL)
        return 0;
    size_t flen = strlen(image_file);
    char *chain_path = (char*)malloc_s(flen + 8);
    memcpy(chain_path, image_file, flen);
    strcpy(chain_path + flen, ".chain");
    int exists = access(chain_path, R_OK) == 0;
    free(chain_path);
    return exists;
}

JL_DLLEXPORT void jl_restore_system_image(jl_image_t *image, jl_image_buf_t buf)
{
    ios_t f;

    if (buf.kind == JL_IMAGE_KIND_NONE)
        return;
    reactive_chain_n = 0;
    if (buf.kind == JL_IMAGE_KIND_SO && (reactive_overlay_mode() || reactive_chain_exists()) && reactive_region_load(buf))
        reactive_chain_load(image);

    if (buf.kind == JL_IMAGE_KIND_SO) {
        assert(image->fptrs.ptrs); // jl_init_processor_sysimg should already be run
        reactive_image = *image;
        reactive_nshards = ((const jl_image_pointers_t*)buf.pointers)->header->nshards;
        reactive_image_version = ((const jl_image_pointers_t*)buf.pointers)->header->version;
        reactive_image_loaded = 1;
    }

    if (buf.kind == JL_IMAGE_KIND_SO) {
        reactive_blob_data = buf.data;
        reactive_blob_size = buf.size;
    }

    JL_SIGATOMIC_BEGIN();
    ios_static_buffer(&f, (char *)buf.data, buf.size);

    jl_restore_system_image_from_stream(&f, image, buf.checksum);
    if (reactive_sections_on) {
        // the lists of the loaded state decode at the first save: a bundle's
        // launcher never saves, and the decode costs a large part of a start
        reactive_base_lists_ready = 0;
        reactive_base_lists_pending = 1;
    }
    reactive_sections_on = 0;

    ios_close(&f);
    JL_SIGATOMIC_END();
    reactive_base_world = jl_atomic_load_acquire(&jl_world_counter);
}

JL_DLLEXPORT jl_value_t *jl_restore_package_image_from_file(const char *fname, jl_array_t *depmods, int completeinfo, const char *pkgname, int ignore_native)
{
    void *pkgimg_handle = jl_dlopen(fname, JL_RTLD_LAZY);
    if (!pkgimg_handle) {
#ifdef _OS_WINDOWS_
        int err;
        char reason[256];
        err = GetLastError();
        win32_formatmessage(err, reason, sizeof(reason));
#else
        const char *reason = dlerror();
#endif
        jl_errorf("Error opening package file %s: %s\n", fname, reason);
    }

    jl_image_buf_t buf = get_image_buf(pkgimg_handle, /* is_pkgimage */ 1);

    jl_gc_notify_image_load(buf.data, buf.size);

    // Despite the name, this function actually parses the pkgimage
    jl_image_t pkgimage = jl_init_processor_pkgimg(buf);

    if (ignore_native) {
        // Must disable using native code in possible downstream users of this code:
        // https://github.com/JuliaLang/julia/pull/52123#issuecomment-1959965395.
        // The easiest way to do that is to disable it in all of them.
        IMAGE_NATIVE_CODE_TAINTED = 1;
    }

    jl_value_t* mod = jl_restore_incremental_from_buf(buf, &pkgimage, depmods, completeinfo, pkgname, 0);

    return mod;
}


#ifdef __cplusplus
}
#endif
