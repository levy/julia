# Region GC — the region state of a heap is made on first use

A thread heap carries the state of every region, whether or not the thread
ever opens a window: `regions[JL_GC_MAX_REGIONS]` in `src/gc-tls-stock.h`,
one struct of about 1.5 KB per region. With 64 regions that is about 100 KB
per thread, zeroed at thread start. This plan makes the table a table of
pointers, 64 words, and makes the state of a region on a heap when the heap
first uses that region. This is the second half of what the region-tree plan
deferred as "64 regions, lazy per-heap state"; the first half is
`region-gc-64-regions.md` in `done/`.

Branch `gc-regions-fixes`, worktree `julia-gc-fixes`, on top of the 64
regions. The fold into the staged series happens with the fixes and the 64
regions, so the gate runs once.

## The design

- The anonymous struct of `regions[]` gets a name, `jl_gc_region_state_t`:
  the state of one region on one heap. It loses its `initialized` byte: a
  region has state on a heap when its pointer is not `NULL`.
- `regions[]` becomes `jl_gc_region_state_t *regions[JL_GC_MAX_REGIONS]`.
  `jl_gc_region_init_heap` zeroes the table. Region 0 never gets state: its
  pools are `norm_pools`, and no site indexes `regions[0]`.
- `region_lazy_init` allocates the state with `calloc_s` on the first use of
  a region on a heap, and fills the pool sizes and the two lists as before.
  `calloc_s` aborts the process when memory runs out, as the runtime does for
  its own metadata. The state is never freed: a thread heap lives for the
  process, and a reset parks the pages for the next window.
- Every `heap->regions[n].field` becomes `heap->regions[n]->field`, and every
  `initialized` test becomes a `NULL` test. A site that walks the state
  several times loads the pointer once into a local.

## Who makes the state

The state of region n on a heap exists before any site reads it, because
the three ways a heap comes to use a region all call `region_lazy_init`:

- a window: `jl_gc_region_set`;
- a task switch that installs a window the task holds:
  `jl_gc_region_install_task`;
- a borrow of a container's region: `jl_gc_region_install_borrow`.

The sites that read the state without a test are the ones a window or a
borrow guards: the page claim in `gc_add_page`, the malloc'd-data tracking,
the finalizer registration on a region object of this heap, the census hook
of the allocator (its caller tests `current_region != 0` first), and the
census mark. Every other site tests the pointer, as it tested `initialized`.

## Runtime cost

The allocation fast path does not change: it reads `active_pools`, and that
pointer now points into the heap-allocated state instead of into the thread
heap. The sites that index `regions[n]` pay one dependent load each: the
page claim, the malloc'd-data track, the finalizer registration, a window
open, a task switch, a borrow. None is per object. The three brackets of a
stock collection test a pointer per region per heap instead of a byte. The
memory goes from about 100 KB per thread to 512 bytes per thread, plus
about 1.5 KB per region a heap uses.

## Steps

### Step 1 — The struct and the table

- [x] `gc-tls-stock.h`: name the struct, drop `initialized`, make the table
      a table of pointers, and say in the comment when the state is made.
      The typedef sits after `jl_thread_heap_t`, because the stock line
      that defines `JL_GC_N_MAX_POOLS` is inside the heap struct; the heap
      names it as `struct _jl_gc_region_state_t *`.
- [x] `region_lazy_init`: `calloc_s`, then the pool sizes and the lists.
- [x] `jl_gc_region_init_heap`: the `memset` of the table stays; the line
      that marked region 0 initialized goes.

### Step 2 — The sites

- [x] `gc-regions.c`: the 68 sites. The `initialized` tests become `NULL`
      tests; the loops of the brackets, the global reset, the global root
      scan and the census mark skip a `NULL` state. `jl_gc_region_pages`
      was the one entry that read the state without a test; it answers 0
      for a `NULL` state. `region_reset_heap` loads the pointer once.
- [x] `gc-stock.c`: `gc_add_page` loads the state once, for the fresh-page
      reuse and for the chain of a new page.
- [x] `gc-regions.h`: `jl_gc_region_maybe_census` reads through the pointer;
      its comment says why the state exists, and an `assert` says it.
- [x] `grep` finds no `regions[...]\.` left in `src/`.

### Step 3 — The tests

- [x] `regions_window.jl` gains a case: every entry answers for a valid
      region that no window opened on this heap, without state. `pages` 0,
      `reset` 0, `reset_global` 0, `collect` and `coop` `EINVAL`, `check` 0,
      `verify` 0, `quarantined` 0, `parent_of` the chain parent. The case
      extends `no_window_defaults` on region 5, `UNOPENED`, which no case
      of the script opens on any thread: 91 checks became 100.
- [x] The multi-thread configurations of the sweep cover the `NULL` states
      of the other heaps in the brackets, the global reset and the global
      root scan: `regions_many.jl` opens every region on one heap only.
- [x] The ten scripts pass at every harness configuration (60 of 60 runs
      exit 0; the `REGION-` line counts equal the 64-regions sweep), and
      the `gc` group passes.

### Step 4 — The documents

- [x] The devdoc: the Limits line on the cost of a window names the pointer
      table and the state a first window makes; the file table's line for
      `gc-tls-stock.h` names `jl_gc_region_state_t`.
- [x] `HISTORY.md`: a paragraph after the one on the 64 regions, whose last
      sentence said the lazy state stays deferred; that sentence went.

### Step 5 — Land

- [x] One commit for the code and the tests, one for the documents, explicit
      paths: `c061421172` "gc: a heap makes the state of a region on its
      first use" and `025b0e8557` "gc: the devdoc and the history record
      the lazy region state".
- [x] Rebuild, run the sweep and the `gc` group: the sweep 60 of 60, the
      `gc` group 189 of 189 at `JULIA_NUM_THREADS=4`.
- [x] Push `gc-regions-fixes`. The fold into the series is Step 3 of
      `region-gc-issues.md` and covers this change too.

## Acceptance

- `sizeof` of the region table in `jl_thread_heap_t` is
  `JL_GC_MAX_REGIONS * sizeof(void *)`: 512 bytes on x86-64, checked with a
  C program that includes `julia.h`; `sizeof(jl_gc_region_state_t)` is 1576
  bytes there.
- Every entry answers for a region that no window opened, on a heap that
  has no state for it.
- The sweep is green at every configuration; the `gc` group is green.
- No measurement number enters a document; M1 and M2 run on the idle
  machine with the fold.

## Out of scope

- Freeing the state at a reset. A reset parks the pages for the next window
  on the region, and the state holds their chains.
- A per-region window count, a subtree reset, a subtree census: deferred in
  `HISTORY.md` and unchanged by this plan.
