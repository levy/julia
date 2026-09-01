// This file is a part of Julia. License is MIT: https://julialang.org/license

// Meant to be included in "julia_threads.h"
#ifndef JL_GC_TLS_H
#define JL_GC_TLS_H

#include "julia_atomics.h"
#include "work-stealing-queue.h"
// GC threading ------------------------------------------------------------------

#include "arraylist.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    struct _jl_taggedvalue_t *freelist; // root of list of free objects
    struct _jl_taggedvalue_t *newpages; // root of list of chunks of free objects
    uint16_t osize; // size of objects in this pool
} jl_gc_pool_t;

typedef struct {
    // variable for tracking young (i.e. not in `GC_OLD_MARKED`/last generation) large objects
    struct _bigval_t *young_generation_of_bigvals;

    // lower bound of the number of pointers inside remembered values
    int remset_nptr;
    // remembered set
    arraylist_t remset;

    // variables for allocating objects from pools
#define JL_GC_N_MAX_POOLS 51 // conservative. must be kept in sync with `src/julia_internal.h`
    jl_gc_pool_t norm_pools[JL_GC_N_MAX_POOLS];

    // --- region prototype -----------------------------------------------------
    // A region is a saved set of pool heads plus the pages claimed while it
    // was current. Swapping regions swaps the pool heads; the inlined
    // allocation fast path is untouched. Region 0 is the default heap.
#define JL_GC_MAX_REGIONS 4
    uint8_t current_region;
    // The live pool array of the current region: norm_pools for region 0,
    // regions[n].pools for region n. Allocation paths decode their stable
    // norm_pools-relative offset into an index and address through this
    // pointer, so a region switch is one pointer store -- no copying, and
    // no parked state that can go stale.
    jl_gc_pool_t *active_pools;
    struct {
        jl_gc_pool_t pools[JL_GC_N_MAX_POOLS];
        struct _jl_gc_pagemeta_t *pages;   // chained through region_next
        struct _jl_gc_pagemeta_t *fresh_pages; // wholly dead pages, ready for
                                           // reuse; their metadata is stale -
                                           // gc_add_page resets a page when it
                                           // claims it, so nobody resets one here
        struct _jl_gc_pagemeta_t *pages_tail; // last link of `pages`, so a reset
                                           // parks the whole chain in O(1)
        uint32_t n_pages;                  // pages on `pages`
        uint32_t n_fresh;                  // pages on `fresh_pages`
        uint8_t initialized;
        uint32_t overflow_pages;           // pages beyond one per pool at reset
    } regions[JL_GC_MAX_REGIONS];
    // --------------------------------------------------------------------------
} jl_thread_heap_t;

typedef struct {
    ws_queue_t chunk_queue;
    ws_queue_t ptr_queue;
    arraylist_t reclaim_set;
} jl_gc_markqueue_t;

typedef struct {
    // thread local increment of `perm_scanned_bytes`
    size_t perm_scanned_bytes;
    // thread local increment of `scanned_bytes`
    size_t scanned_bytes;
} jl_gc_mark_cache_t;

typedef struct {
    _Atomic(struct _jl_gc_pagemeta_t *) bottom;
} jl_gc_page_stack_t;

typedef struct {
    jl_thread_heap_t heap;
    jl_gc_page_stack_t page_metadata_allocd;
    jl_gc_markqueue_t mark_queue;
    jl_gc_mark_cache_t gc_cache;
    _Atomic(size_t) gc_sweeps_requested;
    _Atomic(size_t) gc_stack_sweep_requested;
    arraylist_t sweep_objs;
} jl_gc_tls_states_t;

#ifdef __cplusplus
}
#endif

#endif // JL_GC_TLS_H
