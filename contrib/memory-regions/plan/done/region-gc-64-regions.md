# Region GC — 64 regions

Eight regions is a constant, not a design limit. `JL_GC_MAX_REGIONS` is 8 in
`src/gc-tls-stock.h`: region 0 is the stock heap, regions 1 to 7 are the
regions a program can open. A program with more independent lifetimes than
seven has to multiplex them, and the region-tree plan deferred "64 regions,
lazy per-heap state". This plan does the first half: the constant goes to 64.
The lazy per-heap state is a separate plan, if the memory per thread ever
matters.

Branch `gc-regions-fixes`, worktree `julia-gc-fixes`, on top of the review
fixes (`region-gc-issues.md`, Step 2b). The fold into the staged series
happens together with those fixes, so the gate runs once.

## What bounds the count

| Item | Width | Holds 64? |
| --- | --- | --- |
| `JL_GC_MAX_REGIONS` | 8 | the constant |
| page tag `region_n`, task `region`, `region_parent[]`, `region_child_count[]` | `uint8_t` | yes |
| `region_live_mask`, `region_haschild_mask`, `region_uptree[]` | `uint64_t` | yes, exactly: bit 63 is region 63 |
| `region_quarantined_mask`, and the `(uint32_t)1 << cr` in `jl_gc_region_wb` | `uint32_t` | no: must widen to `uint64_t` |
| per-heap `regions[]` | 8 entries of 1576 bytes = 12.6 KB per thread | grows to 100.9 KB per thread |

Nothing else indexes by the count. The census works on one target region,
the barrier reads two page tags and one `uptree` word, `jl_gc_region_stat`
indexes phases.

## Runtime cost

None on a hot path. The allocation fast path reads `active_pools`, one
pointer. The barrier reads two page tags and shifts one `uint64_t`. A window
open, a task switch and a borrow write a pointer and a byte. The three
brackets of a stock collection loop over 64 entries per heap instead of 8 and
skip the uninitialized ones: 64 byte tests per thread per collection. The
memory is 88 KB more per thread, zeroed once at thread start by the `memset`
in `jl_gc_region_init_heap`.

## Steps

### Step 1 — The constant and the mask

- [x] `JL_GC_MAX_REGIONS` 8 → 64 in `src/gc-tls-stock.h`.
- [x] `region_quarantined_mask` `uint32_t` → `uint64_t`; the `bit` and
      `seen` of `jl_gc_region_wb` follow.
- [x] The comment "The eight uptree words" in `jl_gc_region_declare_parent`
      says "The uptree words".

Done: no other shift on a region number exists in `gc-regions.c`, and no
loop uses the literal 8. The comment on `regions[]` in `gc-tls-stock.h`
names no count.

### Step 2 — The tests

- [x] `regions_api.jl` gains `const MAX_REGIONS = 64`. The three scripts that
      use `8` as a bad number (`regions_window.jl`, `regions_census.jl`,
      `regions_tree.jl`) use `MAX_REGIONS`.
- [x] A new script `test/gc/regions_many.jl`, listed in `test/gc.jl`:
  - a window on every region 1 to 63 allocates and closes; every region
    holds pages; `region_set(64)` refuses with `EINVAL`;
  - the default chain: `parent_of(63) == 62`, and a legal store does not
    quarantine: an object of region 63 references an object of region 62,
    its parent, or an object of its own region;
  - the top bit of the quarantine mask: an escape from region 63 quarantines
    63 and no other region (the widened mask);
  - the reset of every region in the order 63 down to 1 succeeds; region 62
    refuses with `ECHILD` while 63 is live;
  - a declared tree with 62 leaves (regions 2 to 63) under trunk 1: every
    leaf resets on its own while the others are live, then the trunk resets.
- [x] The new script passes at every harness configuration (threads 1, 2, 4;
      0 and 1 interactive threads), and the nine other scripts still pass.

Done: 402 checks per run of `regions_many.jl`; the sweep of the ten scripts
at the six configurations exits 0 in every run, and the runtime prints the
same report lines as in the sweep of the fixes, plus the two escapes the new
script provokes (region 32 and region 63). Two facts the script taught:
the quarantines must come last, because a quarantined region stays live and
a live region refuses a tree declaration; and the frame that resets the
leaves must hold no leaf object, so the fills and the stores run in their
own `@noinline` function. The tree has 62 leaves, regions 2 to 63 under
trunk 1, not 63.

### Step 3 — The documents

- [x] The devdoc: "(7)" in The model, "Eight regions" and "eight pool arrays"
      in Limits, and the Cost section if it names the per-thread memory.
      Done: the Cost section names no per-thread memory; the Limits line
      now says "64 region entries, about 100 KB" (a `sizeof`, not a
      measurement).
- [x] `HISTORY.md`: the sentence "`JL_GC_MAX_REGIONS` went from 4 to 8"
      gains the step to 64. The change is not a fix, so it does not get a
      row in the third-review table. It gets a short paragraph after that
      table.
- [x] The comment in `gc-tls-stock.h` on `regions[]`, if it names a count.
      Done: it names none.

### Step 4 — Land

- [x] One commit for the code and the tests, one for the documents, explicit
      paths. Done: `1e71388e75` (code and tests), `75fd633ce8` (documents).
- [x] Rebuild, run `regions_many.jl` and the sweep of all scripts. Done: the
      build with the new constant recompiled the runtime and the sysimage;
      `region_set(63)` opens, `region_set(64)` returns `EINVAL`.
- [x] Push `gc-regions-fixes`. Done, 2026-09-05. The fold into the series is
      Step 3 of `region-gc-issues.md` and covers this change too: it belongs
      to the stage that owns `gc-tls-stock.h`.

## Acceptance

- `region_set(63)` opens a window; `region_set(64)` returns `EINVAL`.
- An escape from region 63 quarantines region 63 only.
- The `gc` group is green; the sweep is green at every configuration.
- No measurement number enters a document; M1 and M2 run on the idle
  machine with the fold.

## Out of scope

- The lazy per-heap state (`regions[64]` pointers, `calloc` on first use).
  It saves 88 KB per thread and costs one dependent load per page claim; it
  touches about 80 sites and region 0 needs a real entry or a guard in
  `jl_gc_region_maybe_census`.
- A per-region window count, a subtree reset, a subtree census: deferred in
  `HISTORY.md` and unchanged by the count.
