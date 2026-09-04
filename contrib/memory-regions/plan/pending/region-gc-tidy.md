# Tidy the region collector for a pull request

The region collector is complete: the chain, the maturation, the tree, the
open-region census, and four demonstrators. The work lives on four stacked
branches with 73 commits, a 100-file `contrib/` folder, six overlapping
documents, and 44 log files. Nobody can review that. This plan rebuilds the
work as one branch that a Julia developer can read from the first commit to
the last, with the runtime in small commits, the tests in `test/`, the
measurements redone once on the final tree, the plots regenerated, and the
history in one document that the reader opens only when they want it.

The plan is internal, as every plan before it: no posts, no issues, no
discussions on Julia project pages. The pull request opens on `levy/julia`.
Any step toward upstream is the user's manual act.

## The five properties of the result

1. **Easy to follow.** One branch, one idea per commit, no detour. A fix
   lives in the commit that introduces the thing it fixes.
2. **All documented.** Every detour, rejected idea, and regression is in
   `HISTORY.md`, with the backup branches for the full record. The source
   describes what is; it carries no history.
3. **Measurements collected.** Every number lives in one file, was measured
   on the final tree, has its data file, its script, and its plot.
4. **Tests and samples separated.** Correctness tests live in `test/`.
   Benchmarks, demonstrators, and tools live in `contrib/`, each in its own
   folder with a README.
5. **Mature enough for a pull request.** Every commit builds. The test suite
   passes. The pull request text is short and honest.

## The stance along the way

The tidy is also a review. The person who moves a function reads it as a
reviewer, not as a mover. These rules apply at every step:

- **Read critically.** For every runtime function ask: is it correct under
  threads (which lock, which `ptls`), across a task switch, across an
  exception, and with a stock collection in the middle? Is every
  `JL_NOTSAFEPOINT` true? Does an error path leave a window open? Is a
  fixed table (`GC_MAX_BLOCKS`, `JL_GC_MAX_REGIONS`, the mask widths) bounded
  with a check, or does it fail silently? Is a return code documented and
  distinct? Is there dead code, a debug leftover, a hot-path print?
- **Fix a bug when you find one.** First a test case that fails
  (in the five scripts), then the fix, in the runtime commit that owns the
  mechanism. The commit message describes the mechanism as it now is. The
  finding goes to `HISTORY.md`, section "Found during the tidy": the
  symptom, the cause, the fix, the test.
- **No new feature.** A fix makes an existing promise true. A feature makes
  a new promise. A feature idea gets one line in `HISTORY.md`, section
  "Deferred", and no code.
- **Write up anything substantial before the step continues.** A finding
  goes to `HISTORY.md`. A number goes to `MEASUREMENTS.md`. A claim in a
  document that no test or measurement backs is either backed or removed.
- **Add a measurement or a plot when it answers a question a reviewer will
  ask** and the record does not answer it yet. Each addition names its
  question in the table of step 6, has a bound, and tells one thing per
  plot. Candidates already known: peak memory of the demonstrators (the
  honest cost of the model: a region holds its garbage until the reset);
  thread scaling of the sibling leaves; region pages over time under the
  growth bound.

## Facts (2026-09-03)

**Branches** on `levy/julia`, all pushed:

| branch | tip | commits | holds |
| --- | --- | --- | --- |
| `memory-regions` | 2d249ce25b | 31 from base | the chain runtime, the Julia face, the real-time measurements |
| `region-maturation` | c0b8d4df4a | +24 | soundness, coexistence, tasks, the inline fix, the refusals |
| `region-tree` | a2521fbf57 | +11 | declared parentage, sibling isolation, the open-region census |
| `region-demonstrators` | 99f578096e | +7 | demonstrators A to D (contrib only) |

`region-demonstrators` branched from `region-tree` at bddaf9cbed, **before**
the open-region census (e09e184daa) and its document (a2521fbf57). The
demonstrators ran on a runtime without the census. The truth for this plan
is the union of the two tips.

**Base.** All four branches sit on `v1.13.0-rc3` (a861d5fe28). Upstream
`release-1.13` is at `v1.13.0-rc4` (8f33e09afe, 57 commits, 66 changed lines
in the files this work touches). Upstream `master` is `1.14.0-DEV` and
changes 1100 lines in `gc-stock.c` alone. A move to `master` is a port, not
a rebase.

**Runtime delta** against the base (region-tree tip): 14 files, about 1600
lines added. `gc-stock.c` holds one block of about 1000 lines near its end
and 16 small hook hunks in the allocation, mark, sweep, and collect paths.
The exported API is 22 entry points:

```
jl_gc_region_set  jl_gc_region_reset  jl_gc_region_reset_global  jl_gc_region_current
jl_gc_region_declare_parent  jl_gc_region_parent_of
jl_gc_region_collect  jl_gc_region_collect_coop  jl_gc_region_census_threshold  jl_gc_region_pages
jl_gc_region_wb  jl_region_barrier_on  jl_gc_region_quarantined
jl_gc_region_of  jl_gc_region_stat  jl_gc_region_overflow  jl_gc_region_verify
jl_gc_region_set_debug  jl_gc_region_check  jl_gc_region_reserve
jl_gc_region_track_malloced  jl_gc_region_add_finalizer   (internal, not exported)
```

Nothing under `test/` or `doc/` changed. Every test is a script under
`contrib/memory-regions/`. Source comments still say "region prototype".

**The contrib folder** (`region-demonstrators` plus the two `region-tree`
commits): 38 Julia scripts, 3 shell scripts, 2 Python scripts, 1 C++ file,
6 documents (README 28 KB, DESIGN 31 KB, MEASUREMENTS 32 KB, MATURATION 9 KB,
TREE 5 KB, SHOWCASE 9 KB), 10 done plans, 44 logs, 2 plots. The documents
overlap: the multithreaded sweep and the construction-barrier cost appear
twice; the "residual-cleanup" section of MEASUREMENTS.md is history; TREE.md
and SHOWCASE.md point at plan paths that moved; README.md says "six runs"
where the matrix has eight. Two tests (`lock_discipline_test.jl`,
`subsystem_refusal_test.jl`) and one repro (`ctor_gap_demo.jl`) are cited by
no document. The unit costs have no script: they came from unnamed
microbenchmarks.

**Plots.** `plot_realworld.py` writes SVG directly, with no plotting
library. The machine has no matplotlib. The two plots (`latency_ccdf.svg`,
`max_pause.svg`) cover the real-world loop only.

**The Julia test suite.** `test/gc.jl` runs each script under `test/gc/`
with `run_gctest(file)` in a subprocess matrix (1, 2, 4 threads; 0 or 1 GC
threads; concurrent sweep off or on). A script passes when it exits 0. The
`"gc"` entry in `test/choosetests.jl` covers them. Devdocs register in
`doc/make.jl` next to `devdocs/gc.md`.

## Decisions

- **D1. Base = `v1.13.0-rc4`.** The tip of upstream `release-1.13` on the
  day step 0 runs, recorded by SHA in this plan. Not `master`: the port is
  separate work and the pull request text says so.
- **D2. One new branch `gc-regions`, one new worktree `julia-gc-regions`.**
  The four old branches do not change. Step 0 tags their tips
  `backup/<branch>-2026-09-03` and pushes the tags.
- **D3. The truth is one tree.** Step 0 merges `region-tree` into
  `region-demonstrators`. The tidy branch equals that tree in behavior.
  Every runtime difference is a line in the audit table of `HISTORY.md`.
- **D4. The runtime moves to `src/gc-regions.c`** with `src/gc-regions.h`
  for the hook declarations. `gc-stock.c` keeps only the hooks. Bound: if
  the move needs more than 15 `static` symbols of `gc-stock.c` made
  non-static, stop, keep the code in `gc-stock.c` as one delimited section,
  and record the reason.
- **D5. Twelve runtime commits.** The series below. A fix folds into the
  commit that introduces the mechanism. Every commit builds.
- **D6. Tests go to `test/gc/regions_*.jl`**, five scripts, run by
  `run_gctest` from `test/gc.jl`. A script exits nonzero on the first
  failure. A script that needs a thread count checks `Threads.nthreads()`
  and exits 0 when the count does not apply. The scripts share
  `test/gc/regions_api.jl`, a 20-line set of `ccall` wrappers.
- **D7. No Base API.** The Julia face stays in `contrib/` and uses region
  integers. The pull request names a Base API as future work.
- **D8. Four reader documents.** `doc/src/devdocs/gc-regions.md` (design,
  API, rules, limits — from DESIGN.md, MATURATION.md, TREE.md),
  `contrib/memory-regions/README.md` (the folder map and how to run
  everything), `contrib/memory-regions/MEASUREMENTS.md` (every number, every
  plot, including the demonstrators — from MEASUREMENTS.md and SHOWCASE.md),
  and `contrib/memory-regions/HISTORY.md` (the detours — from the ten done
  plans and the history sections). The done plans do not move to the new
  branch; `HISTORY.md` links their backup branch.
- **D9. Every important measurement is redone** on the `gc-regions` tip.
  The data files (`.tsv`) live in `contrib/memory-regions/results/`. The
  `.log` files do not move to the new branch. `plot.py` draws every plot
  from the data files, in plain Python.
- **D10. API cleanups in the audit.** `jl_gc_region_reserve` becomes
  `jl_gc_heap_reserve`: it prefaults the heap and is not tied to regions.
  An entry point stays only when a test or a measurement uses it; the audit
  table lists the fate of each of the 22.
- **D11. Machine discipline.** Builds run `nice -n 10 taskset -c 16-23
  make -j8`. Test suites run on cores 24-27. Timing runs alone on core 29
  (13 as the spare), one at a time, under `systemd-run --user --scope -p
  MemoryMax=…`, with a timeout, with a log file. Other agents share the
  machine: never kill a process that this plan did not start.
- **D12. The pull request opens on `levy/julia`**, from `gc-regions` to a
  branch `release-1.13` that step 0 pushes at the base SHA, so the diff is
  exactly the series. It opens only on the user's go.

## Target layout

```
src/gc-regions.c                       the runtime, one file
src/gc-regions.h                       hook declarations for gc-stock.c, task.c, gf.c, gc-common.c
src/gc-stock.c, gc-pages.c, ...        hooks only
test/gc.jl                             + @testset "regions": run_gctest on the five scripts
test/gc/regions_api.jl                 the ccall wrappers the scripts share
test/gc/regions_window.jl              set / reset / current, the window follows its task, the reserve
test/gc/regions_escape.jl              barrier, quarantine, construction store, the ctor-gap case
test/gc/regions_lifetime.jl            finalizers, malloc'd data, WeakRef and image refusal, stock coexistence
test/gc/regions_census.jl              collect, cooperative collect, parked-task root, the reset precondition, the growth bound
test/gc/regions_tree.jl                sibling isolation, reset order, the shared trunk under a lock, reset_global
doc/src/devdocs/gc-regions.md          the design for Julia developers
contrib/memory-regions/
  README.md                            map of the folder, how to build, how to run each thing
  MEASUREMENTS.md                      every number and plot, with script and data file
  HISTORY.md                           the detours, the rejected ideas, the backup branches
  regions.jl                           the Julia face (integers; @with_region)
  bench/                               kernel.jl, yardstick.jl (was harness.jl), model_*.jl,
                                       tail.jl, paced.jl, endurance.jl, census.jl (was stage5_scoped.jl),
                                       native.jl + native.cpp (was stage6), unit_costs.jl (new),
                                       census_bound.jl, gcbench.sh (the zero-cost sweep), README.md
  demo/                                demo_common.jl, bt_solver.jl, pathtrace.jl, optimistic_bst.jl,
                                       dmr_core.jl + dmr.jl, showcase_binarytree.jl, showcase_linkedlist.jl,
                                       showcase_tree.jl, README.md
  tools/                               region_check.jl, checker_run.jl, hook_patch.py, hil_isolation.sh, README.md
  results/                             run_all.sh, realworld.sh, plot.py, data/*.tsv, plots/*.svg
```

## The runtime series

Each commit builds. The message describes the state after the commit and
the reason, never the history. Original commits absorbed are listed for the
person who writes the series, not for the message.

| # | commit | contents | absorbs |
| --- | --- | --- | --- |
| 1 | `gc: region state in the thread heap, and the window` | `gc-regions.c/h`, `gc-tls-stock.h` fields, page tag `region_n` (`gc-stock.h`, `gc-pages.c`), the allocation path routes to the region's pools, `jl_gc_region_set` / `jl_gc_region_current`, `JL_NO_REGION_ALLOC`, compiler allocations go to region 0 (`gf.c`) | 52969ba846, 5875176376, 953f4fd71f |
| 2 | `gc: the stock collector and open regions coexist` | the mark filter and sweep guard skip region pages, a deferred collection re-arms with a real interval, no contract between the two | 13989e9665, eab67d8fab |
| 3 | `gc: reset a region in O(1)` | `jl_gc_region_reset`, page return, the region's own malloc'd list (`gc-common.c`) and finalizer list, both run by the reset | f0848c8936, d345768b80, 0e463ce373 |
| 4 | `gc: the escape barrier - a shorter lifetime stored into a longer one quarantines the region` | `jl_gc_region_wb`, `jl_region_barrier_on`, `gc-wb-stock.h`, the codegen hooks for stores and construction (`cgutils.cpp`, `llvm-late-gc-lowering.cpp`), the quarantine, the child-first test, `JL_NO_REGION_STORE_BARRIER` | 91601592e0, b10b78f0d2, 0121cb9049 (barrier half) |
| 5 | `gc: a region window follows its task` | `task.c`, `julia_threads.h`, stickiness across the window | e4432f4ccd |
| 6 | `gc: the census - collect one region alone` | `jl_gc_region_collect`, `jl_gc_region_collect_coop`, the scoped mark filter (outlined `gc_scoped_claim`, forced-inline queue operations in `work-stealing-queue.h`), parked task stacks as roots, finalizers of dead objects, the reset precondition check | 2b8180c5df, fb83dc7af2, 4a6ef66b23, a34a779bef, 9620d5972d, d4bbdd6e55 |
| 7 | `gc: refuse what a region cannot hold` | `WeakRef` on a region object, a system image inside a window (`staticdata.c`) | 72a8ba92e2, 0121cb9049 (image half) |
| 8 | `gc: a tree of regions - declared parentage and sibling isolation` | `jl_gc_region_declare_parent`, `jl_gc_region_parent_of`, the up-tree mask in the barrier, `JL_GC_MAX_REGIONS`, the per-heap live and has-child masks, the reset refuses on a live child, `jl_gc_region_reset_global` | 2d1a8f9e28, 0a7eeb47ec, b9c1c11330 |
| 9 | `gc: the open region censuses itself on growth` | `region_maybe_census` in `maybe_collect`, `jl_gc_region_census_threshold`, `jl_gc_region_pages` | e09e184daa |
| 10 | `gc: a populated heap reserve, so a loop never faults` | `jl_gc_heap_reserve` (renamed), the prefault flag, the block table in `gc-pages.c` | 19bf8a1e36 |
| 11 | `gc: region diagnostics` | `jl_gc_region_of`, `jl_gc_region_stat`, `jl_gc_region_overflow`, `jl_gc_region_verify`, `jl_gc_region_quarantined`, and whatever the audit keeps of `set_debug` / `check` | f6ab9319d1 |
| 12 | `gc: the region rules in one place` | the header comment of `gc-regions.c`: the model, the six rules, the discipline the barrier does not remove, the API in one table | DESIGN.md |

Then, on top:

| # | commit | contents |
| --- | --- | --- |
| 13 | `test: the region collector` | the five scripts, `regions_api.jl`, the `@testset` in `test/gc.jl` |
| 14 | `doc: memory regions in the developer documentation` | `doc/src/devdocs/gc-regions.md`, the `doc/make.jl` entry |
| 15 | `contrib: the Julia face of the region collector` | `regions.jl`, `README.md`, `tools/` |
| 16 | `contrib: region benchmarks` | `bench/` |
| 17 | `contrib: region demonstrators` | `demo/` |
| 18 | `contrib: the measurements of the region collector` | `results/`, `MEASUREMENTS.md`, the plots |
| 19 | `contrib: the history of the region collector` | `HISTORY.md` |

## Steps

Every step ends with a check. A step that fails its check does not continue.
Mark a step done in this file when its check passes, and record any decision
the step forced.

### Step 0 — backups, the truth, the worktree

- [x] Tag the four tips: `backup/memory-regions-2026-09-03` (2d249ce25b),
      `backup/region-maturation-2026-09-03` (c0b8d4df4a),
      `backup/region-tree-2026-09-03` (a2521fbf57),
      `backup/region-demonstrators-2026-09-03` (9915f3c7de). Pushed.
- [x] On `region-demonstrators` (worktree `julia-demos`): `git merge
      region-tree`. Expected: `gc-stock.c`, `regions.jl`,
      `region_census_bound_test.jl`, `TREE.md` arrive, no conflict. Build
      (D11). Run `showcase_tree.jl`, `region_census_bound_test.jl`, and one
      demonstrator (`dmr_demo.jl`, cores 24-27) as a smoke check. Commit. Push.
      This tip is **the truth**: `e37c9c7cc4` (merged without conflict; the
      three smoke checks pass; pushed). The truth binary reports
      `1.13.0-rc3.unknown`.
- [x] Fetch upstream `release-1.13`; the tip is **the base**: `8f33e09afe`
      (`v1.13.0-rc4`). Pushed as `origin/release-1.13`. Note: `git fetch
      upstream release-1.13` makes no tracking ref on this clone; fetch with
      an explicit refspec (`+refs/heads/release-1.13:refs/remotes/upstream/release-1.13`).
- [x] `git worktree add ../julia-gc-regions -b gc-regions-flat <base>`.
      **Deviation:** the worktree carries `gc-regions-flat` (the scratch
      branch of steps 1 to 6), not `gc-regions`. Step 7 creates `gc-regions`
      from the patch stack. No `Make.user`: every branch so far built with
      the defaults. Build (D11; a full build from a clean worktree takes
      about one hour on 8 cores) — waits for the truth build.
- [x] Check: `../julia-gc-regions/julia -e 'println(VERSION)'` prints
      `1.13.0-rc4.1` (commit `fe0c579e36`); the four tags and
      `origin/release-1.13` exist on the remote.

### Step 1 — the flat port

One commit that holds the whole runtime on the new base, before any split.

- [x] `git diff a861d5fe28 e37c9c7cc4 -- src | git apply -3` in the new
      worktree: 14 files, 1963 diff lines, **no conflict** (the 66 rc3-to-rc4
      lines do not touch the region block). Checked per file: the line
      count between the applied tree and the truth equals the upstream
      rc3-to-rc4 count (`gc-stock.c` 4, `gf.c` 13, `julia_internal.h` 48,
      `staticdata.c` 12).
- [x] Build. Run every correctness script from the truth's `contrib/` folder
      (copied to the scratchpad, `../../julia` replaced by the new binary):
      the 13 tests of the inventory plus `region_census_bound_test.jl`.
      Each must pass as it passes on the truth. Done: 14/14 `ALL PASS`, exit
      0, on both binaries (cores 24-27, `MemoryMax=8G`, 600 s per script;
      `lock_discipline_test.jl` runs with one thread, the two tree tests
      with four).
- [x] Commit `wip: the region runtime, flat, on rc4` on the scratch branch
      `gc-regions-flat`: `fe0c579e36` (committed before the build, so the
      build has a fixed tree to name; the script check follows).
- [x] Check: the script results equal the truth's, line for line. The one
      difference is the address that `stage3_safety.jl` prints.

### Step 2 — the file move and the critical review

- [x] Create `src/gc-regions.c` and `src/gc-regions.h`; move the region block
      and the region-only helpers out of `gc-stock.c`; add `gc-regions` to
      the `SRCS` list of `src/Makefile`. Apply the D4 bound. Done: the move
      made one `static` function of `gc-stock.c` visible
      (`jl_gc_free_memory`) and added one non-static helper
      (`gc_queue_execution_roots`, the thread-local roots plus the parked
      tasks of one thread, for the census); both are declared in
      `gc-stock.h`. Well under the bound of 15. The other stock helpers the
      region code uses were already non-static (`gc_mark_finlist`,
      `gc_mark_loop_serial`) or are `STATIC_INLINE` in `gc-stock.h`.
      `gc-stock.c` keeps the hooks listed at the end of the audit table.
- [x] Review the runtime, function by function, with the questions of "The
      stance along the way". Keep a review log in the scratchpad: one line
      per function, the verdict (clean / cleanup / bug / deferred idea).
      Known places to look first: the `gf.c` wrappers (the window across an
      exception), the fixed block table of the heap reserve (silent drop
      past 4096 blocks), the `-7` style return codes (one table, one
      meaning each), `jl_error` reached from a `JL_NOTSAFEPOINT` path, the
      `saved_region` of the census across a task switch, the census hook on
      the allocation path, the quarantine mask against `JL_GC_MAX_REGIONS`.
      Done: `review.md` in the scratchpad: 12 bugs (B1 to B12), 15
      cleanups, 5 stock-path changes that need their own series commit,
      3 deferred items. The findings go into `HISTORY.md` in step 5.
- [x] Fix every bug the review finds, as the stance says: test first, fix
      in the flat tree, finding in `HISTORY.md`. Done: 12 fixes, each with
      a test case (`newtests/b*.jl`, 9 scripts). Every case fails on the
      truth's binary (one hang, three segfaults, one abort, four failed
      checks) and passes on the new binary. The cases become part of the
      five test scripts in step 3.
- [x] Clean the source against three rules: it describes what is (no
      "prototype", no "was", no dates, no stage numbers); every exported
      entry point has a doc comment that states its contract, its return
      codes, and its thread rules; every entry point is used by a test or a
      measurement. Write the audit table into `HISTORY.md`: entry point,
      fate (keep / rename / drop), reason. Apply D10. Done: the audit table
      is `audit.md` in the scratchpad (18 entry points kept, 1 renamed, 2
      dropped, every hook listed); the refusal codes are one enum in
      `gc-regions.h` (EINVAL -1 to EROOT -8). It moves into `HISTORY.md` in
      step 5.
- [x] Build. Run the 14 scripts again, plus the new cases. Done: 14/14
      `ALL PASS` and 9/9 `ALL PASS` on the new binary
      (`correctness-out-flat2.log`, `newtests-out-flat2.log`).
- [x] Measure the four unit costs (window open and close, reset, disarmed
      barrier, allocation in a region) and the zero-cost sweep on core 29,
      against the truth's binary, interleaved, min of 5. The move must not
      change them beyond noise (2 %). Done, twice (`bench/unit_costs.jl`,
      10 rows, `unit-costs-out/`, `unit-costs-out2/`). The first run found
      two things worth a fix and a rule:
      - The stock mark was +6.4 %: the B10 fix loaded the census filter
        once more per object. Fixed: `gc_mark_obj8/16/32` load the filter
        once per object and pass it down, like the array loop. After the
        rebuild the stock mark is at parity (64.45 vs 64.55 ms, 1.002).
      - A tight JIT loop's cost is quantized by code placement: the same
        native code runs at 1.37, 1.44 or 1.64 ns per store in different
        positions (`smoke/store_armed_layout.jl`, four pads, two binaries).
        The script compiles 8 copies of each tight loop and reports the min
        over the copies. Rule for `bench/README.md`: an A/B on one copy
        compares placements, not code.
      Second run: `store_disarmed` 1.000, `construct_two` 1.007,
      `window_pair` 0.981, `reset_slice` 1.000, `stock_mark` 1.002. Beyond
      the bound with a cause: `store_region` 0.870, `alloc_region` 0.840,
      `switch_pair` 0.927 are gains because GCC inlines `page_metadata` in
      the slow path of `jl_gc_region_wb` in its own translation unit;
      `store_armed` 1.054 and `alloc_stock` 1.046 (+0.07 and +0.15 ns per
      armed store) are the placement of the C fast path, which is
      instruction-identical in both libraries (`wb_*.s` in the scratchpad)
      and starts 16-byte aligned in both. Not a source change. The full
      tables and the reasons are in `review.md` ("Unit costs"), for
      `HISTORY.md`.
- [x] Commit on `gc-regions-flat`. Done: `fe0c579e36` (the flat port),
      `dad6679f67` (the review), `c061516430` (the doc comments),
      `33beda0084` (the census-filter hoist); the wip commits become the
      series in step 7.
- [x] Check: `git diff <truth> gc-regions-flat -- src` contains only lines
      that the audit table or a finding in `HISTORY.md` explains. Done, as
      an interdiff, because the truth sits on an older base than rc4: the
      region diff of the truth against `a861d5fe28` versus the region diff
      of the flat against `8f33e09afe`, file by file (`interdiff/` in the
      scratchpad). Every differing line is named by the audit table, a bug
      B1 to B12, or a cleanup; the check found four cleanups that the
      review log did not list yet, now C16 to C19 (the `saved > 0` restore
      in gf.c, the `JL_NO_REGION_STORE_BARRIER` macro of the C-side barrier
      hooks, the `jl_gc_region_barrier_on` rename, the
      `jl_gc_region_task_switch` call in task.c).

### Step 3 — the tests

- [x] Write the five scripts and `regions_api.jl` from the 14 contrib tests.
      Each assertion keeps its message. A script exits 1 at the first
      failure and prints the assertion. Done. No case needs a thread count:
      every case runs at every thread count of the matrix, so no script
      prints a skip line. The two multi-thread cases (`tree_multithread_leaves`,
      `census_parked_task`) use `Threads.@threads :static` and
      `Threads.@spawn` and hold at `-t 1` as well.
- [x] Review each test as a reviewer: does it assert the property, or does
      it only run? Done, one pass per script. Findings that changed a
      script: the 5000-task census case moved from the top level into
      `census_many_tasks()` (its top-level placement had a rationale that
      was not a property); the parked-task handshake uses `Base.Event`
      instead of `Channel{Nothing}(1)` (a `put!` inside a window grows the
      channel's buffer in the region, see the test pitfalls) and lost an
      unexplained `GC.enable(false)`; `tree_multithread_leaves` runs
      `:static` because a region is reset on the heap that allocated it and
      a worker that waits for the lock must not migrate; the helper
      `tree_make_b7` lost its bug-number name. The review of the census
      script found bug **B13** (`review.md`): the census leaves every old
      task in the remset of the census thread, and the next stock
      collection frees the page of a task that sits alone on its page (the
      root task of a GC mark thread). Root-caused with trace
      instrumentation (reverted), fixed in `region_census_mark` (the remset
      length and pointer count are restored), test `census_leaves_remsets`
      for the stop-the-world and the cooperative census. Without the fix
      the script dies with SIGSEGV at `-t 2 --gcthreads=2` and `-t 4
      --gcthreads=4`; with it every configuration passes.
- [x] Add `@testset "regions"` to `test/gc.jl` with five `run_gctest` lines.
- [x] `taskset -c 24-27 ./julia test/runtests.jl gc` under `MemoryMax=8G`
      with a 30-minute timeout. Green: `Overall | 129 | 129`, 70 s
      (`gc-suite-run.log` in the scratchpad).
- [x] Remove the 14 scripts from `contrib/`; `ctor_gap_demo.jl` becomes a
      case of `regions_escape.jl`. Done as: step 4 does not port the 14
      scripts nor `ctor_gap_demo.jl` to the new branch (the flat branch has
      no `contrib/memory-regions/` yet); the ctor-gap case is
      `ctor_gap_quarantines_region5` in `regions_escape.jl`.
- [x] Commit on `gc-regions-flat`. Done: `37e94a877d` (the B13 fix, folds
      into series commit 6) and `3de985b15c` (the tests, series commit 13).
- [x] Check: the five scripts run in the matrix of `run_gctest` (60 runs),
      all exit 0 — 12 passes per script in the log. Assertion counts: the
      14 contrib scripts hold 91 static assertion lines (`check(` and
      `@test`), the 9 `newtests/b*.jl` scripts 60 more; the five new
      scripts hold 226 static `check(` lines and run 624 checks per process
      (window 72, escape 33, lifetime 50, census 50, tree 419; loops count
      each round).

### Step 4 — the contrib folder

- [x] Make `bench/`, `demo/`, `tools/`, `results/`. Move and rename as the
      target layout says. Fix every `include` and every `../../julia` path
      (the scripts find the binary from `Sys.BINDIR`).
- [x] Write `bench/unit_costs.jl`: the microbenchmarks behind the unit-cost
      table, one function per cost, min of N, printed as a TSV row.
- [x] Write `bench/gcbench.sh`: the zero-cost sweep — the GCBenchmarks
      subset used before (`big_arrays`, `many_refs`, `binarytree`,
      `linkedlist`, `mergesort_parallel`, `mm_divide_and_conquer`,
      `issue-52937`), vanilla binary against region binary, 1 and 4
      threads, interleaved, min of 5, one TSV.
      *Done as eleven benchmarks, not seven: the six serial ones the
      maturation and tree plans used (`append`, `linked/tree`, `strings`,
      `pollard`, `single_ref`, `many_refs`) on one thread on `CORE`, and
      five multithreaded ones (`tree_mutable`, `mergesort_parallel`,
      `mm_divide_and_conquer`, `objarray`, `issue-52937`) on four threads
      on `MTCORES`. The two binaries alternate inside every round.*
- [x] Write `results/run_all.sh`: every measurement of the table below, in
      order, each with its core, its `MemoryMax`, its timeout, and its data
      file. Write `results/plot.py`: every plot of the table, from the data
      files, plain Python, one function per plot, shared style with the
      current `plot_realworld.py`.
      *`plot.py` got a `decade_bounds` helper: the log axis of the CCDF
      divided by zero on a data file with one decade.*
- [x] Write the three folder READMEs: one line per file, the command that
      runs it, what it prints. *Each README has a second table, "Files that
      the programs include", so a reader knows which files are not
      programs.*
- [x] Delete `logs/`, `plan/`, `stage*` names, `run.sh`, `hil_isolation.sh`
      from the root (moved), the six old documents (replaced in step 5).
- [x] Commit on `gc-regions-flat`. *`6983351ce5`, 37 files.*
- [x] Check: `bench/README.md`, `demo/README.md`, `tools/README.md` name
      every file in their folder and nothing else; every script starts with
      `julia`, `julia -t4`, or `python3` as its README says, on the new
      binary, without an edit. *Checked 2026-09-04: 21 items, every one
      exit 0, on cores 24-27 under `MemoryMax=8G`; 16 items wrote their
      TSV rows; `unit_costs.jl` prints its rows to stdout and `run_all.sh`
      collects them from the log; the checker and `hil_isolation.sh status`
      print reports, not rows. The checker found 20015 stores at 3 sites in
      the allocating model and 0 in the clean one.*
      *The runtime fix of step 3 grew during this step: a dynamic dispatch
      on a new signature (`jl_lookup_generic_`) and a type first
      instantiated at run time (`inst_datatype_inner`) inside a window put
      the argument tuple type or the new `DataType` into the region, and the
      runtime's cache then held a reference into it: an escape, a
      quarantine. Both cache-miss paths now run in region 0 (`6c517decd4`);
      `regions_window.jl` covers four first-time paths. A window opened at
      top level still quarantines (a `BindingPartition` stored into a
      `Binding`); that stays the documented discipline rule.*

### Step 5 — the documents

- [ ] `doc/src/devdocs/gc-regions.md`: the goal, the model in one page, the
      six rules, the API table (the entry points the audit keeps, with
      integers and return codes), the tree, the census, the growth bound, the heap
      reserve, the discipline the barrier does not remove, the limits (no
      Base API, no compile inside a window, WeakRef and image refused, eight
      regions, Linux x86-64 measured only), and one paragraph on cost with
      a link to `MEASUREMENTS.md`. Present tense, no history. Register in
      `doc/make.jl` after `devdocs/gc.md`. `make -C doc html` builds it.
- [ ] `contrib/memory-regions/HISTORY.md`: one section per done plan (ten),
      in date order, each a paragraph: the question, what was tried, what
      was rejected and why, what landed. Then the detours as their own
      list: the deferral re-arm, the inline-budget mark regression,
      `preserve_most` rejected, the construction-store gap, the OOM hazard
      and the census, the compile-inside-a-window escape, the region-1 trunk
      stored into a global. Then "Found during the tidy": every bug the
      review found, with symptom, cause, fix, and test — or the sentence
      "The review found no bug", if that is true. Then "Deferred": the
      feature ideas the tidy did not build, one line each. Then the audit
      table of step 2. Then the four backup tags with one line each.
- [ ] `contrib/memory-regions/README.md`: the folder map, the build, the
      four documents, the headline figure (filled in step 6).
- [ ] `contrib/memory-regions/MEASUREMENTS.md`: the skeleton — one section
      per measurement of the table below, each with the claim in one
      sentence, the script, the data file, the plot, and an empty table
      that step 6 fills.
- [ ] Commit on `gc-regions-flat`.
- [ ] Check: no document links to a file that does not exist on the branch
      (`grep -o '\]([^)]*)'` over the four documents, every target resolved);
      no document contains "prototype", "stage 3", "was rejected" outside
      `HISTORY.md`.

### Step 6 — the measurements, redone

All on the `gc-regions-flat` tip, core 29, one at a time, `run_all.sh`.
The vanilla binary is `julia-vanilla` rebuilt at the base SHA. Each row
gets its data file, its table in `MEASUREMENTS.md`, and — where the table
says so — its plot.

| # | measurement | script | data | plot | bound |
| --- | --- | --- | --- | --- | --- |
| M1 | zero cost when unused: region binary against vanilla, 7 GCBenchmarks, 1 and 4 threads | `bench/gcbench.sh` | `gcbench.tsv` | bars: ratio per benchmark, two thread counts, a line at 1.0 | 40 min |
| M2 | unit costs: window open+close, reset, disarmed barrier, armed barrier, construction store, allocation in a region against stock | `bench/unit_costs.jl` | `unit_costs.tsv` | table only | 10 min |
| M3 | the tail, one Bool apart: baseline against regions, p50 to max | `bench/tail.jl` | `tail.tsv` | table only | 10 min |
| M4 | the real-world loop: 8 runs, 4 collector modes, 2 garbage classes | `results/realworld.sh` | `ccdf_*.tsv`, `realworld.tsv` | the CCDF pair and the max-pause plot (kept) | 60 min |
| M5 | the census: against a full collection; pause against live set K; throughput stock / coop / pooled; the slice knob | `bench/census.jl` | `census_*.tsv` | line: pause against K (the live-set law); bars: throughput | 30 min |
| M6 | paced (1 event per 100 µs) and endurance (30 min) | `bench/paced.jl`, `bench/endurance.jl` | `paced.tsv`, `endurance.tsv` | line: RSS over 30 min | 45 min |
| M7 | region-native against C++ new/delete | `bench/native.jl`, `bench/native.cpp` | `native.tsv` | table only | 10 min |
| M8 | wholesale death: binary tree, linked list, the tree showcase, stock against regions; peak RSS of both | `demo/showcase_*.jl` | `showcase.tsv` | bars: collections and GC time; bars: peak RSS | 15 min |
| M9 | the growth bound: region pages over the rounds, threshold off and on | `bench/census_bound.jl` (the test in `regions_census.jl` asserts the bound; the bench prints the pages per round) | `census_bound.tsv` | line: pages per round, two series, the threshold as a horizontal line — the question: "what stops a region from growing?" | 5 min |
| M10 | demonstrators A to D: wall, collections, GC time, peak RSS, region against stock, across the sweep | `demo/*.jl` | `demo_a.tsv` … `demo_d.tsv` | one figure per demonstrator: wall time region against stock over the sweep, the stock collection count on a second axis; one figure for all four: peak RSS region against stock — the question: "what does the model cost in memory?" | 20 min |
| M11 | the discipline checker: violations in the allocating model against the clean model | `tools/checker_run.jl` | `checker.tsv` | table only | 15 min (skip and record if `hook_patch.py` does not apply to rc4's `Compiler`) |
| M12 | thread scaling of the sibling leaves: demonstrator B and D at 1, 2, 4, 8 threads, region against stock | `demo/pathtrace.jl`, `demo/dmr.jl` with `-t` | `scaling.tsv` | line: wall time against thread count, two series per demonstrator — the question: "do isolated leaves scale without coordination?" | 20 min (cores 24-31, the only row that leaves the isolated core; run when the load average is below 4) |

A row that a finding of the review makes necessary is added here with its
question, its bound, and its plot, before it runs.

- [ ] Run `run_all.sh`. Total bound about four and a half hours. Log to
      `results/run_all.log` (not committed).
- [ ] Read every result as a reviewer before it goes into a table: a number
      that contradicts a claim of the documents is a finding, not a typo.
      Follow it to its cause (a rerun on the spare core, then the code)
      before the step continues.
- [ ] Fill every table of `MEASUREMENTS.md`. Under each table, one line: the
      date, the SHA, the core, the command.
- [ ] Add a drift table to `HISTORY.md`: the headline numbers before (from
      the old documents) and after, side by side. A drift beyond 10 % on any
      headline gets one sentence of explanation or a rerun.
- [ ] `python3 results/plot.py` writes every plot. Every plot has a title
      that states the claim, both series named in the plot, axis labels
      with units, and a caption line with the SHA and the core.
- [ ] Put the headline figure and its plot into `README.md`.
- [ ] Commit on `gc-regions-flat`.
- [ ] Check: `results/data/` holds one file per row of the table; every
      number in `MEASUREMENTS.md` has a data file; every plot is regenerated
      by `plot.py` from those files with no other input.

### Step 7 — the series

- [ ] Build the patch stack: for each of commits 1 to 12, one patch file
      cut from `git diff <base> gc-regions-flat -- src`, by hand, hunk by
      hunk, into a `series/` directory in the scratchpad (a git repository
      of its own, so nothing is lost). Commits 13 to 19 are whole-directory
      patches.
- [ ] `series/build.sh`: from `<base>`, apply and commit each patch with its
      message, in order, onto `gc-regions`.
- [ ] Check 1: `git diff gc-regions-flat gc-regions` is empty.
- [ ] Check 2: every commit builds — loop over the 19 commits, `make -j8`
      on cores 16-23, `julia -e 1` runs. Bound: 19 incremental builds, about
      three hours. Log the loop.
- [ ] Check 3: at commits 1 to 12, the tests that exist at that point pass
      (run the five scripts from the tip at each commit; a script that calls
      an entry point the commit does not have yet is expected to fail, and
      the loop records which; the count of failures must fall to zero at
      commit 12).
- [ ] Reset `gc-regions-flat` to the same tree as a tag `gc-regions-flat`
      for the record; the branch itself is deleted.

### Step 8 — the gate

- [ ] `taskset -c 24-27 ./julia test/runtests.jl gc core threads misc`
      under `MemoryMax=16G`, 90-minute timeout. Zero fail, zero error.
- [ ] `make -C doc html` builds the devdoc.
- [ ] Every `results/` plot opens and reads at a glance (open each SVG).
- [ ] The PR text below is complete: every ⟨placeholder⟩ replaced with the
      measured number and the real link.
- [ ] Push `gc-regions`. Write the PR text into this file, final.
- [ ] Tell the user. Open the pull request (`gh pr create --repo levy/julia
      --base release-1.13 --head gc-regions`) only on the user's go.

### Step 9 — close

- [ ] Move this plan to `plan/done/` on `region-demonstrators` (the
      development lineage keeps its plans). Push.
- [ ] Update the memory `region-gc-maturation-branch.md`: the final branch,
      the tags, the PR.

## Acceptance

The plan is implemented when all of these hold:

1. `gc-regions` exists on `origin`, 19 commits on `origin/release-1.13`,
   every commit builds, and `git diff gc-regions-flat gc-regions` is empty.
2. `test/runtests.jl gc core threads misc` is green on the tip.
3. `MEASUREMENTS.md` holds M1 to M12 with data files under `results/data/`,
   measured on the tip's SHA, and every plot under `results/plots/` comes
   from `plot.py`.
4. The four reader documents exist, link only to files on the branch, and
   contain no history outside `HISTORY.md`.
5. The four backup tags and `origin/release-1.13` exist.
6. The PR text below has no placeholder left.
7. `HISTORY.md` has "Found during the tidy" and "Deferred". Every bug in
   the first has a test and a fix in the series; or the section says, in
   one sentence, that the review found none.

## Risks

- **The rc4 port breaks a hook.** 66 upstream lines in `gc-stock.c`, `gf.c`,
  `julia_internal.h`, `staticdata.c`. Step 1's script run catches it.
- **The file move needs too many statics.** D4 has the bound and the
  fallback.
- **A measurement drifts.** The drift table of step 6 makes it visible; a
  rerun on the spare core decides between noise and a real change. A real
  change is a bug in the tidy, and the flat tree goes back to the last
  green commit.
- **Other agents load the machine.** Collections and GC time are
  load-independent; wall time is not. `run_all.sh` records the load average
  before each row; a row measured above load 8 is rerun.
- **The hooked-compiler checker does not apply to rc4.** M11 is skipped and
  recorded; the tool stays with a note.
- **`run_gctest` runs each script twelve times.** The scripts are seconds
  each; the endurance and the demonstrators are not tests and stay out of
  `test/`.

## The pull request text

Title: **GC: memory regions — free one lifetime's objects in O(1), beside the stock collector**

> This adds regions to the stock collector. A region is the set of objects
> a thread allocates while a region window is open. A reset returns the
> region's pages in O(1), with no trace. The stock collector never traces a
> region's pages; the two coexist with no contract between them. Regions
> form a declared tree (eight today); sibling regions are isolated.
>
> One rule keeps it safe: a reference must point to an object of equal or
> longer lifetime. A checked write barrier turns a violation into a
> quarantined region — a leak, never a dangling pointer. A census collects
> one region alone, stop-the-world or cooperative, and an open region past a
> growth threshold censuses itself, so internal garbage cannot grow a region
> without bound.
>
> **Why.** Hard real-time loops: a discrete-event simulation that drives
> hardware. On a 5-million-event loop with ~1.7 KB of garbage per event, on
> an isolated core, the longest pause goes from ⟨3957⟩ µs (stock) to ⟨12⟩ µs
> (regions, no census) — [MEASUREMENTS.md](⟨link⟩), figure 1.
>
> **Cost when unused.** ⟨M1 range⟩ against vanilla on the GCBenchmarks
> subset, 1 and 4 threads; one predicted branch per pointer store (the
> barrier is armed only while a region exists); `JL_NO_REGION_ALLOC` and
> `JL_NO_REGION_STORE_BARRIER` compile both to literal zero.
>
> **Cost when used.** A window pair ⟨n⟩ ns, a reset ⟨n⟩ ns per page, the
> armed barrier ⟨n⟩ ns, a construction store +⟨1.4⟩ ns worst case. The
> wall-time win appears only where discarded allocation per unit of work
> dominates: the demonstrators show the crossover honestly (a bare
> optimistic insert loses at 0.44x; heavy speculation wins up to 1.63x).
> A region holds its garbage until the reset, so peak memory is ⟨M10 RSS
> ratio⟩ of the stock run on the demonstrators.
>
> **What it is not.** No Base API yet — the Julia face is a `ccall` wrapper
> in `contrib/memory-regions/regions.jl` and uses region integers. No
> compilation inside a window (compiler allocations go to region 0). A
> `WeakRef` to a region object and a system image inside a window are
> refused. Measured on Linux x86-64 only. Based on `v1.13.0-rc4`; a port to
> `master` is separate work.
>
> **How to read it.** Twelve runtime commits, one idea each, in
> `src/gc-regions.c` with small hooks in the stock collector; then tests
> (`test/gc/regions_*.jl`), the devdoc (`doc/src/devdocs/gc-regions.md`), the
> benchmarks, the demonstrators, the measurements with their data and plots,
> and the history. The history document records every detour, every
> rejected idea, and ⟨the bugs the final review found, with their tests⟩;
> the four development branches are kept under `backup/` tags.
>
> Branch: ⟨link to gc-regions⟩ · Design: ⟨link to devdoc⟩ · Measurements:
> ⟨link⟩ · History: ⟨link⟩ · contrib README: ⟨link⟩
>
> Questions I would like answered by review: whether the barrier's placement
> in `cgutils.cpp` and `llvm-late-gc-lowering.cpp` is the one you would
> choose; whether the task-follows-window rule in `task.c` is acceptable;
> whether a Base API is wanted before or after the runtime.
