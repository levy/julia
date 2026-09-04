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
- **D13. The gate found a sixteenth bug (2026-09-04); the fix is a suspend
  of the window, in Base.** The `gc` group on the series tip failed twice
  at `JULIA_NUM_THREADS=2,0`: `a Task of region 2 was stored into a
  GenericMemory of region 0` at the `wait` of the `interleave` case. A
  120-run loop of `regions_window.jl` at `2,0` failed 8 times; a probe in
  `jl_new_task` gave the backtrace: `wait` → `get_sched_task` →
  `OncePerThread` → `Task(wait_forever)`. Julia 1.13 makes a thread's
  scheduler task at the first idle wait on that thread, on behalf of the
  task that waits, inside its window when it holds one; the sticky work
  queue of a thread (`Workqueues`) is made the same way. Three fixes were
  weighed. (a) Allocate every `Task` in region 0 in `jl_new_task`: wrong
  layer, `Task(f)` allocates the `ThreadSynchronizer` for `donenotify` in
  Julia before the `ccall`, so a region-0 `Task` would point at a region
  object, and a `Task` made and never scheduled inside a window is legal
  today. (b) Bracket the two scheduler sites: leaves every other
  `OncePerProcess` / `OncePerThread` with the same escape. (c) Bracket the
  slow path of every `Once` in `base/lock.jl`: the value and the tables
  are runtime state in a table that outlives every window. Chosen: (c).
  The bracket cannot be `jl_gc_region_set(0)`: `init_perprocesss` takes a
  `ReentrantLock` and can park the task, and a closed window unpins the
  task, which could then migrate and reopen the window on another thread
  heap. So the runtime gets one pair, `jl_gc_region_suspend` and
  `jl_gc_region_resume` in `gc-common.c` (exported for the `ccall`, a
  no-op on a third-party heap): region 0 installed, the window still open
  and counted, the task still pinned; a `finally` runs the resume on the
  exception path. The C brackets of B14, B15 and inference keep
  `jl_gc_region_set(0)`: they never park, and an exception past them leaves
  the window closed, which is coherent, while a suspend there would leave a
  window counted open with no way to close it after an exception (a
  conversion was written and reverted for that reason). Test:
  `lazy_state_stays_in_region_0` in `regions_window.jl`, deterministic. The
  flat tree changed, so the series is cut again and Checks 1 to 3 and the
  gate run again on the new tip. Recorded as B16 in `HISTORY.md`.
- **D14. A task spawned inside a window is an escape; the devdoc says so
  and a test fixes it (2026-09-04).** The review of B16 asked what a
  `Threads.@spawn` inside a window does: the `Task` and its synchronizer
  are region objects, and the schedule stores the task into the
  scheduler's queues, stock objects. A probe confirmed a deterministic
  `REGION-ESCAPE` at 1 and at 2 threads, the result still computed, the
  region quarantined. That is the barrier as designed, not a bug, and no
  rule of the devdoc named it. Added: the rule "make tasks outside the
  window" and `spawn_quarantines_region2` in `regions_escape.jl` (36 checks,
  33 before; region 2 is burned, region 1 stays the one clean region). No
  runtime change. The flat commit is `9c4eca80ee`; the series is cut a
  third time, and only the trees of commits 14, 15 and 20 change, so Checks
  2 and 3 of the second cut carry over to commits 1 to 13 by tree identity;
  the tip binary is rebuilt and the `gc` group runs on it.
- **D15. The measurements are not run again after B16; the document names
  the measured commit (2026-09-04).** `MEASUREMENTS.md` said that the
  `src/` of the measured commit `48603f334c` is the `src/` of the tip. After
  B16 that is false: the tip differs in `src/gc-common.c`, `src/gc-regions.h`,
  `src/task.c` and `base/lock.jl`. The fix runs at most once per process and
  once per thread, in the slow path of `OncePerProcess` and `OncePerThread`,
  which ran before the fix and after it; the fix adds one suspend and one
  resume around it, and two stores in `jl_init_root_task`. No script under
  `bench/` waits or spawns, and the multi-thread rows of M1 and M4 make the
  scheduler state once per thread in both binaries. A rerun of every row
  takes hours on cores that the user needs now. The paragraph names the
  measured commit and the difference; the acceptance item "measured on the
  tip's SHA" is not met to the letter and this entry says why. The rerun is
  one command, `results/run_all.sh` on a quiet machine, and the user can ask
  for it. The flat commit is `8c1bb50b50`; the series is cut a fourth time,
  and only the trees of commits 19 and 20 change.
- **D16. Every branch and tag that the series supersedes is renamed
  `obsolete/...` (2026-09-04, the user's direction).** Branches, local and
  on `origin`: `memory-regions`, `region-maturation`, `region-tree` and
  `region-demonstrators` became `obsolete/<name>`; the worktrees
  `julia-region`, `julia-mature`, `julia-tree` and `julia-demos` follow
  them. Tags: `backup/<name>-2026-09-03` became `obsolete/<name>-2026-09-03`
  (annotated again under the new name, pushed, the old names deleted on
  `origin`); the local cut tags became `obsolete/gc-regions-cut1..4-2026-09-04`.
  Not renamed: `gc-regions` (the result), `gc-regions-flat` (the flat tree
  the series was cut from; `MEASUREMENTS.md` and `HISTORY.md` name it, so
  it is pushed now), `sealed-aot` (other work), `master`, `release-1.13`.
  `HISTORY.md` (section "The obsolete branches and their tags") and the
  README row for it name the new names, so the series is cut a fifth time
  from the flat tip `728957e8b1`: commits 1 to 15 keep their SHAs; 16
  `3d1b546748` (README), 17 `a2ea6b7720`, 18 `b7d40e4659`, 19 `c0eb11ffd5`,
  20 `4b02199e76` (the tip, pushed with `--force-with-lease` on the fourth
  cut, which is the tag `obsolete/gc-regions-cut4-2026-09-04`). Outside
  `contrib/memory-regions/` the tree is the fourth cut's, so the gate
  stands. `retake.sh` takes a first stage now.
- **D17. The stock-only build folds the census filter out; the documents
  say what each define keeps (2026-09-04, the user's direction).** The
  user asked whether a switch to chain regions would make the unused cost
  zero. The answer: the unused cost comes from the barrier's armed-flag
  check, the construction-store barrier, and the census filter of the mark
  loops, none of which reads the shape; the chain is the default shape
  already, and the shape is read only in the cold path of the armed
  barrier. Zero cost exists at build time only, and the review of the two
  defines found one gap: the mark loops loaded
  `jl_gc_region_census_target` under `JL_NO_REGION_ALLOC` too, a build that
  can never run a census, while the PR text said the defines "compile both
  halves to nothing". Fix, in the flat commit `4efd0bd38c`: the loops read
  the filter through `jl_gc_region_census_filter()`, the constant 0 under
  the define. Proof at the object level: `gc-stock.o` compiled with
  `-DJL_NO_REGION_ALLOC` holds 0 references to the target against 43
  without it, and the default compile is instruction-identical to the
  object before the change (`objdump -d` differs in the file name line
  only). The devdoc Cost section, the README and HISTORY (C21) say what
  each define removes and what a build with both keeps: one page tag per
  page and a store and a compare at a task switch, nothing per object;
  the region tests fail on both builds by design. The series is cut a
  sixth time from stage 7 (the census commit)
  with `retake.sh`, which now takes the runtime stages through
  `reveal.py`: commits 1 to 6 keep their SHAs; 7 `16edc596d9`, 13
  `e24c913184`, 14 `5d768c352c`, 15 `a5a1d28fa9`, 16 `b747323edd`, 17
  `4afc22da24`, 18 `1e8cd82fd3`, 19 `f2ac61920d`, 20 `3087f0cfc5`. The
  fifth cut is the tag `obsolete/gc-regions-cut5-2026-09-04`. Because the
  default build's code is identical, the `core threads misc` gate of the
  third cut stands; Check 2/3 runs again on commits 7 to 20 and the `gc`
  group on the new tip binary.
- **D18. No build-time chain switch (2026-09-04, recommended; the user's
  decision is open).** The user asked whether a build that promises a
  chain, with the simpler check `cr <= pr`, is worth having. Recommended
  no: the check that differs runs only in the cold path of the armed
  barrier, after two page-map walks, and the tree test is one load of a
  64-bit word from an eight-entry array in L1, a shift and an `and`, below
  the noise of the `store_region` row; the chain is the default shape from
  the same code; each build switch is one more configuration for the
  gate, and a chain-only binary must refuse `region_parent!`, so a library
  that uses sibling leaves fails on it. One barrier, one shape, no switch,
  unless a measurement ever shows the uptree load.
- **D19. MEASUREMENTS.md shows each plot (2026-09-04, the user's
  direction).** The user asked why the plots were not visible in the
  document. The document named each plot by its path in a code span and
  never used the image syntax, so a reader saw a file name. Fix, in the
  flat commit `d543cb834a` (tag `gc-regions-flat`): each of the eighteen
  plots stands under the table that holds its data, as an image whose
  alternative text is the heading of the plot; the path stays in the
  prose. `tables.py` rewrites only between its markers, and a run after
  the change leaves the document as it is. The change is in stage 19
  alone, so it goes into the sixth cut with the retake of stages 15 to 20.

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
the reason, never the history. The original commits absorbed are listed for
the person who writes the series, not for the message.

The series is cut with stage markers, not with hand-cut patches. Every
final runtime file is annotated once (`//@[N`, `//@[N-M`, `//@]`; `#@[` in
the Makefile); an unmarked line belongs to every stage, a removed base line
is wrapped `//@[0-K`. `reveal.py stage k` writes the tree of stage k;
`reveal.py check` asserts that stage 0 equals the base and the last stage
equals the flat tip for every file, so the final tree stays the single
source. `xstage.py` asserts that no identifier appears before the stage
that declares it. The series repository lives in the scratchpad
(`series/`: `annotated/src/*`, `annotate_*.py`, `reveal.py`, `xstage.py`,
`messages/01..20.txt`, `build.sh`).

| # | commit | contents | absorbs |
| --- | --- | --- | --- |
| 1 | `gc: region state in the thread heap, and the window` | `gc-regions.c/h`, the region table and `active_pools` in `gc-tls-stock.h`, the page tag `region_n` and chain `region_next` (`gc-stock.h`), the allocation path routes to the region's pools, the sweep guard, `jl_gc_region_set` / `jl_gc_region_current`, `JL_NO_REGION_ALLOC`, `jl_gc_region_init_heap`, the Makefile | 52969ba846, 5875176376 |
| 2 | `gc: a stock collection and open windows coexist` | the brackets `prepare` / `finish`, `clear_stock_marks` after every pass, `saved_region`, `jl_gc_region_install_task` | 13989e9665 |
| 3 | `gc: the runtime's own work allocates in region 0` | `gf.c` (`jl_type_infer`, `jl_compile_method_internal`, the lookup slow path), `jltypes.c` (`inst_datatype_new`) | 953f4fd71f |
| 4 | `gc: reset a region in O(1)` | `jl_gc_region_reset`, the fresh list and its reuse in `gc_add_page`, the region's finalizer list and malloc'd list, `finalizer_depth` and the finalizer brackets (`gc-common.c/h`), `jl_gc_free_memory` exported, `mark_finalizer_lists`, EBUSY | f0848c8936, d345768b80, 0e463ce373 |
| 5 | `gc: the escape barrier quarantines the region of an escaped child` | `jl_gc_region_wb`, `jl_gc_region_barrier_on`, `gc-wb-stock.h`, `cgutils.cpp`, `llvm-late-gc-lowering.cpp`, the quarantine mask, `jl_gc_region_quarantined`, EQUARANTINED, `JL_NO_REGION_STORE_BARRIER` | 91601592e0, b10b78f0d2, 0121cb9049 (barrier half) |
| 6 | `gc: a window belongs to its task` | `task.c`, `julia_threads.h` (`sticky_before_region`), `jl_gc_region_task_switch`, the sticky block in `jl_gc_region_set` | e4432f4ccd |
| 7 | `gc: the census collects one region alone` | `jl_gc_region_collect` / `_collect_coop`, the census filter, `gc_scoped_claim` and the forced-inline queue (`work-stealing-queue.h`), `gc_queue_execution_roots`, `region_windows_open`, `jl_gc_region_stat`, `jl_gc_region_init`, ERACE / EUNSAFE / EFINALIZERS | 2b8180c5df, fb83dc7af2, 4a6ef66b23, a34a779bef, 9620d5972d, d4bbdd6e55 |
| 8 | `gc: refuse what a region cannot hold` | the `WeakRef` refusal, `staticdata.c` | 72a8ba92e2, 0121cb9049 (image half) |
| 9 | `gc: a tree of regions` | `jl_gc_region_declare_parent` / `_parent_of`, the up-tree mask in the barrier, the live / has-child masks and child counts, ECHILD, `jl_gc_region_reset_global` | 2d1a8f9e28, 0a7eeb47ec, b9c1c11330 |
| 10 | `gc: the open region censuses itself on growth` | `jl_gc_region_census_threshold`, `jl_gc_region_maybe_census` in `maybe_collect`, `jl_gc_region_census_open`, `jl_gc_region_pages` | e09e184daa |
| 11 | `gc: a deferred collection re-arms the trigger` | `gc_defer_collection` | eab67d8fab |
| 12 | `gc: a populated heap reserve, so a loop never faults` | `jl_gc_heap_reserve`, the prefault flag and the block table in `gc-pages.c` | 19bf8a1e36 |
| 13 | `gc: region diagnostics` | `jl_gc_region_of`, `jl_gc_region_verify`, `jl_gc_region_set_debug` / `_check`, EROOT, the corpse report in `gc_setmark_pool`, the tagged-page report in `jl_gc_free_page` | f6ab9319d1 |

Then, on top, whole directories from the flat tip:

| # | commit | contents |
| --- | --- | --- |
| 14 | `test: the region collector` | the five scripts, `regions_api.jl`, the `@testset` in `test/gc.jl` |
| 15 | `doc: memory regions in the developer documentation` | `doc/src/devdocs/gc-regions.md`, the `doc/make.jl` entry |
| 16 | `contrib/memory-regions: the Julia face of the region collector` | `regions.jl`, `README.md`, `tools/` |
| 17 | `contrib/memory-regions: the benchmarks` | `bench/` |
| 18 | `contrib/memory-regions: the demonstrators` | `demo/` |
| 19 | `contrib/memory-regions: the measurements` | `results/`, `MEASUREMENTS.md`, the plots |
| 20 | `contrib/memory-regions: the history of the region collector` | `HISTORY.md` |

Decisions the cut forced (2026-09-04):

- The order of the first three commits is window, coexistence, region 0.
  The sweep guard is in commit 1: a region page must never be swept from
  the first commit, or the window alone is unsound. The brackets and the
  clear are in commit 2, before the runtime's own work moves to region 0:
  a stock collection leaves a region object marked; without the clear, a
  second collection across a held window does not traverse the object
  again and sweeps its region-0 children from under it.
- The planned commit "the region rules in one place" does not exist. The
  rules live in the devdoc (commit 15); the header comment of
  `gc-regions.c` grows with each stage and states the model of that stage.
- `gc_defer_collection` is its own commit (11). It fixes the disabled
  path of the stock collector and touches no region entry.
- The census stats and `jl_gc_region_init` arrive with the census (7);
  the third-party-heap stubs in `gc-regions.h` grow per stage; the enum of
  refusal codes grows per stage.
- The 13 runtime commits add 20 to 557 lines each; the census is the
  largest. A dry run of `build.sh` on 2026-09-04 passed Check 1 with the
  results not yet on the flat tip; the real run follows Step 6.

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
      *The sysimage was rebuilt from the bootstrap on 2026-09-04, because
      `sys.so` predated `src/jltypes.c`: the second build had only relinked
      the libraries. On the rebuilt binary the five scripts pass: window 75,
      escape 33, lifetime 50, census 50, tree 419 checks.*

### Step 5 — the documents

- [x] `doc/src/devdocs/gc-regions.md`: the goal, the model in one page, the
      six rules, the API table (the entry points the audit keeps, with
      integers and return codes), the tree, the census, the growth bound, the heap
      reserve, the discipline the barrier does not remove, the limits (no
      Base API, no compile inside a window, WeakRef and image refused, eight
      regions, Linux x86-64 measured only), and one paragraph on cost with
      a link to `MEASUREMENTS.md`. Present tense, no history. Register in
      `doc/make.jl` after `devdocs/gc.md`. `make -C doc html` builds it.
      *347 lines. The window section names the four runtime paths that run
      in region 0 (inference, compilation, the dispatch cache miss, the type
      instantiation cache miss) and the top-level rule. `make -C doc html`
      exit 0 on 2026-09-04; the page renders with its `@ref` resolved. The
      cost paragraph names `MEASUREMENTS.md` by path, not by a URL: a link
      to `JuliaLang/julia/blob/master` would carry no such file.*
- [x] `contrib/memory-regions/HISTORY.md`: one section per done plan (ten),
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
      *Written as eleven plan sections (the tidy is the eleventh), the
      seven named detours plus the 22-row table of every detour, the bug
      table B1 to B15 with B1′ (symptom, cause, fix, test case), the
      cleanups C1 to C20, the stock-path changes S1 to S5, the pitfalls of
      the tests and the benchmarks, the deferred list, the audit table, the
      tags, and a vocabulary. `preserve_most` is NOT in the detours: no
      source file, document, or plan of the four branches names it, only
      this plan's text did. The detour that is sourced is the inline IR
      tag-compare rejected in the chain-residuals plan, and that one is
      listed. The drift table is added in step 6.*
- [x] `contrib/memory-regions/README.md`: the folder map, the build, the
      four documents, the headline figure (filled in step 6). *The build
      section names `CPPFLAGS += -DJL_NO_...` in `Make.user`: `src/Makefile`
      adds `CPPFLAGS` to every C and C++ compile; `CFLAGS` would miss the
      C++ half. The headline section states the three claims and points at
      M1 to M10; the numbers and the plot come in step 6.*
- [x] `contrib/memory-regions/MEASUREMENTS.md`: the skeleton — one section
      per measurement of the table below, each with the claim in one
      sentence, the script, the data file, the plot, and an empty table
      that step 6 fills. *Twelve sections. The data and plot names are the
      ones `run_all.sh` and `plot.py` write; the table columns are the TSV
      columns each script emits.*
- [x] Commit on `gc-regions-flat`. *`ba3cf22cd4`.*
- [x] Check: no document links to a file that does not exist on the branch
      (`grep -o '\]([^)]*)'` over the four documents, every target resolved);
      no document contains "prototype", "stage 3", "was rejected" outside
      `HISTORY.md`. *The three contrib documents carry no markdown links;
      the devdoc carries one `@ref`, resolved. Two GitHub links to
      `src/gc-regions.c/.h` on master were replaced by plain paths: the
      files do not exist on master. No banned word outside `HISTORY.md`.*

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

- [x] Run `run_all.sh`. *Done 2026-09-03 (full) and 2026-09-04 (`ONLY="M1
      M2 M3 M6"` after the harness fixes). The full run takes about one
      hour, not four and a half: `status.tsv` sums to 2843 s, of which the
      endurance row is 1801 s. Logs in `results/log/` (git ignores it).*
- [x] Read every result as a reviewer before it goes into a table. *Seven
      harness faults (H1 to H7) and five changed claims; see "The
      measurements, redone" in `HISTORY.md`. Each fault was followed to its
      cause and fixed before the affected rows ran again.*
- [x] Fill every table of `MEASUREMENTS.md`. *Decision: no per-table line
      of date, SHA, core and command. `results/tables.py` writes every
      table from the data files between markers; `context.tsv` holds the
      date, SHA, host, cores and scheduling class once; each section names
      its script, data file and plot; `run_all.sh` is the command. A
      hand-typed line under each table is what H6 removed.*
- [x] Add a drift table to `HISTORY.md`. *Fourteen rows, old against new,
      each change beyond the spread with its cause named.*
- [x] `python3 results/plot.py` writes every plot. *Eighteen plots. The
      caption names the core per kind of row (`rt`, `single`, `multi`,
      `mixed`), because the multi-thread rows do not run on core 29. Every
      SVG was rendered to PNG and read; the pass found the H7 legend fault,
      overlapping labels on five plots, a clipped legend, and markers that
      hid one another where two values coincide; all fixed.*
- [x] Put the headline figure and its plot into `README.md`. *Three claims
      and demonstrator C.*
- [x] Commit on `gc-regions-flat`. *`c1cf27eeb0`; the B16 fix (D13) is
      `3c4f0686ac` on top, the spawn rule (D14) `9c4eca80ee`, and the
      corrected measurement statement (D15) `8c1bb50b50`, the flat tip.*
- [x] Check: `results/data/` holds one file per row of the table; every
      number in `MEASUREMENTS.md` has a data file; every plot is regenerated
      by `plot.py` from those files with no other input. *26 data files, 18
      plots; `tables.py` and `plot.py` read `data/` only.*

### Step 7 — the series

- [x] Cut the series: stage markers in the 18 final runtime files
      (`series/annotated/src`), `reveal.py check` passes for every file
      (`last stage 13; OK`), `xstage.py` passes (`OK 0`). Done 2026-09-04;
      the method and the decisions are recorded under "The runtime series".
      The second cut (D13) adds `base/lock.jl` as the nineteenth staged
      file, with `#@[` markers; the B16 fix folds into stage 6, the commit
      that lets a window park with its task, because the suspend exists for
      the pinning that stage introduces. `reveal.py check` and `xstage.py`
      pass again.
- [x] `series/build.sh`: a worktree on `gc-regions` from `<base>`; stages
      1 to 13 from `reveal.py stage k`, commits 14 to 20 from
      `git checkout gc-regions-flat -- <paths>`; each commit takes
      `messages/NN.txt`. A dry run passed on 2026-09-04 and was removed.
      For the second cut the script also accepts the existing worktree and
      resets the branch to the base with `checkout -B`, so the build
      products stay and Check 2 runs incrementally.
- [x] Run `build.sh` after Step 6 commits the results on the flat tip:
      `build.sh /home/projectured/workspace/julia-gc-regions
      /home/projectured/workspace/julia-gc-series`. Done 2026-09-04 from the
      flat tip `c1cf27eeb0`; the 20 commits are `1544632201` (1) to
      `9e9edbda41` (20, the tip of `gc-regions`). That first cut is kept as
      the local tag `backup/gc-regions-cut1-2026-09-04`. The second cut, from
      the flat tip `3c4f0686ac` on 2026-09-04 10:45: `fcb36e783e` (1),
      `b6c5a32d80` (6, with the B16 fix), `d29d7cd322` (13), `0ac093b8d7`
      (20), kept as the local tag `backup/gc-regions-cut2-2026-09-04`. The
      third cut (D14), from the flat tip `9c4eca80ee` on 2026-09-04 12:12:
      `d46b90515a` (1), `add66926fb` (6), `fdf84973a2` (13), `19ef466bde`
      (14), `555227c4ea` (20, the tip of `gc-regions`). The trees of commits
      1 to 13 of the third cut equal those of the second cut (checked with
      `git rev-parse <commit>^{tree}` pairwise); commits 14 to 20 differ by
      the test, the devdoc and the history only. The third cut is kept as
      the local tag `backup/gc-regions-cut3-2026-09-04`. The fourth cut
      (D15), from the flat tip `8c1bb50b50` on 2026-09-04 12:37, keeps
      commits 1 to 18 of the third cut as they are (`retake.sh` resets the
      branch to commit 18 `b226b3e441` and takes stages 19 and 20 again from
      the flat tag): `85abba0de8` (19), `6159d71b25` (20, the tip of
      `gc-regions`). Outside `contrib/memory-regions/` the tree of the tip
      equals the tree of the third cut's tip (`git diff --quiet 555227c4ea
      HEAD -- . ':!contrib/memory-regions'`), so every build and test input
      of the tip is the one the gate ran on. The sixth cut (D17), from the
      flat tip `c6f8bc566c` on 2026-09-04 14:40, keeps commits 1 to 6 and
      takes stages 7 to 20 again (`retake.sh <worktree> add66926fb 7`):
      every commit from 7 to 13 differs from its fifth-cut twin by the same
      two-file change, and the tip differs from the fifth cut's tip by
      exactly the flat commit (checked with `git diff --stat` pairwise and
      at line level for commit 7). Check 2/3 ran on that cut's commits 7
      to 20 (14:28 to 15:27); then stages 15 to 20 were taken again from
      the flat tag `d543cb834a` (the devdoc and HISTORY wording of D17,
      the plot embeds of D19), which changes no file under `src/`, `base/`
      or `test/`: the final commits are 15 `9226b04b9e`, 16 `a58a86fd3b`,
      17 `70f04d1598`, 18 `f7bcfb6730`, 19 `d0d9966cb1`, 20 `3577055ee6`
      (the tip of `gc-regions`, pushed 15:36 with `--force-with-lease` on
      the fifth cut). The tip differs from the checked commit `3087f0cfc5`
      by three documentation files only.
- [x] Check 1: `git diff gc-regions-flat gc-regions` is empty (build.sh
      asserts it). Passed on every cut, the sixth included.
- [x] Check 2: every commit builds — loop over the 20 commits, `make -j8`
      on cores 16-23, `julia -e 1` runs. Bound: 20 incremental builds, about
      three hours. Log the loop. Not before `run_all.sh` ends. Passed
      2026-09-04 08:20 to 09:47 on the first cut (`9e9edbda41`): all 20
      commits `make=0 run=ok`, 456 s for the first build and 234 to 267 s
      for each later one; log `series/check23.log`. Passed again on the
      second cut (D13) 2026-09-04 10:37 to 12:09: all 20 commits `make=0
      run=ok`, 238 to 327 s each; the first cut's per-commit logs are in
      `series/check23-cut1/`. The third cut carries the result over for
      commits 1 to 13 by tree identity; its tip is built alone
      (`gate/build-tip-cut3.log`).
- [x] Check 3: at commits 1 to 13, the tests that exist at that point pass
      (run the five scripts from the tip at each commit; a script that calls
      an entry point the commit does not have yet is expected to fail, and
      the loop records which; the count of failures must fall to zero at
      commit 13). Passed 2026-09-04: at commits 1 to 12 every script stops
      with `could not load symbol` at an entry point of a later commit
      (`jl_gc_region_reset` at 1, `_collect` before 7, `_reset_global` and
      `_parent_of` before 9, `_of` before 13); the one exception is the
      escape script at commit 1, which segfaults inside inference, because
      the compiler still allocates inside the window until commits 2 and 3.
      At commit 13 all five scripts exit 0. Logs: scratchpad
      `series/check23.log`, `series/check23/test-N-*.log`. Passed again on
      the second cut with the same pattern; the scripts were the flat tip's
      at 10:37, before the spawn case of D14, which the `gc` group on the
      third cut's tip covers. Checks 2 and 3 passed again on the sixth cut
      (D17), commits 7 to 20, 2026-09-04 14:28 to 15:27
      (`julia-gc-series-tooling/check23.log`): every commit `make=0
      run=ok`, 240 to 273 s each; at commits 7 to 12 the five scripts stop
      with `could not load symbol`, at commit 13 all five exit 0.
- [x] Reset `gc-regions-flat` to the same tree as a tag `gc-regions-flat`
      for the record; the branch itself is deleted. Done 2026-09-04: the
      branch is deleted; the tag points at the flat tip `8c1bb50b50`; the
      worktree `julia-gc-regions` stays detached there.

### Step 8 — the gate

- [x] `taskset -c 24-27 ./julia test/runtests.jl gc core threads misc`
      under `MemoryMax=16G`, 90-minute timeout. Zero fail, zero error.
      Passed 2026-09-04 08:22 to 08:35 on the flat binary, whose code is
      the tip's (the later changes to build inputs are a comment and one
      Makefile dependency line): 8,635,981 pass, 8 broken (stock markers),
      0 fail, 0 error, `SUCCESS`. The `gc` group runs again on the binary
      of the series tip after Check 2 (see Step 7). That rerun failed
      2026-09-04 09:47 to 09:48 (`gate/runtests-tip-gc.log`): two of the
      twelve configurations of `regions_window.jl`, both at
      `JULIA_NUM_THREADS=2,0`, with `FAIL: the event region is not
      quarantined`. The cause is B16 (D13). The repro loop
      (`gate/repro/loop.sh`, `regions_window.jl` 120 times at `2,0`) fails 8
      of 120 on the first cut and 0 of 120 on the fixed flat binary; the
      `gc` group on the fixed flat binary passes 2026-09-04 10:34 to 10:35
      (`gate/runtests-flat-fixed-gc.log`, 129 of 129, `SUCCESS`, 60 script
      runs). On the binary of the third cut's tip (`555227c4ea`, built
      alone, `gate/build-tip-cut3.log`): the `gc` group passes 2026-09-04
      12:16 (`gate/runtests-tip-cut3-gc.log`, 129 of 129, `SUCCESS`, the
      spawn case of D14 included) and the repro loop passes 0 of 40; the
      `core threads misc` groups pass 12:23 to 12:36
      (`gate/runtests-tip-cut3-core-threads-misc.log`: 8,635,852 pass, 8
      broken, 0 fail, 0 error, `SUCCESS`). The fourth cut's tip has the same
      build and test inputs (Step 7), so the gate stands for it. The sixth
      cut (D17) changes `src/gc-regions.h` and `src/gc-stock.c` with no
      change to the default build's code (the objects are
      instruction-identical), so the `core threads misc` result stands;
      the `gc` group ran again on the binary of the sixth cut's tip
      2026-09-04 15:32 to 15:33 (`gate/runtests-tip-cut6-gc.log`, 129 of
      129, `SUCCESS`, 60 script runs).
- [x] `make -C doc html` builds the devdoc. Passed 2026-09-04 on the flat
      tree (exit 0); the only warnings are the size warnings of the stock
      manual. `devdocs/gc-regions.html` renders with its 16 sections. Run
      again 2026-09-04 12:38 on the series tip after the rule of D14
      (`gate/doc-tip-cut4.log`, exit 0, the same seven stock warnings); the
      rule "Make tasks outside the window" is in the rendered page. The
      build ran once more on the tip of the sixth cut, 2026-09-04 15:34
      (`gate/doc-tip-cut6.log`, exit 0, the seven stock size warnings
      only), and the rendered page holds the Cost paragraph of D17.
- [x] Every `results/` plot opens and reads at a glance (open each SVG).
      Done in Step 6: every SVG was rendered to PNG and read against its
      data after the fixes (H7 and the nine layout defects).
- [x] The PR text below is complete: every ⟨placeholder⟩ replaced with the
      measured number and the real link. Done 2026-09-04; the text names
      the `collect` / `reset` asymmetry as a question, and the nonzero
      costs of an unused runtime with their numbers.
- [x] Push `gc-regions`. Write the PR text into this file, final. Pushed
      2026-09-04: the third cut `555227c4ea` first, then the fourth cut
      `6159d71b25` with `--force-with-lease` on the third. The PR text below
      is final. The fifth cut `4b02199e76` and the sixth cut `3577055ee6`
      followed, each with `--force-with-lease` on the one before; the tag
      `gc-regions-flat` on origin follows the flat tip (`d543cb834a`).
- [ ] Tell the user. Open the pull request (`gh pr create --repo levy/julia
      --base release-1.13 --head gc-regions`) only on the user's go. The
      report went to the user 2026-09-04; the PR is not opened.

### Step 9 — close

- [ ] Move this plan to `plan/done/` on `obsolete/region-demonstrators`
      (the development lineage keeps its plans; D16 renamed it). Push.
- [x] Update the memory `region-gc-maturation-branch.md`: the final branch,
      the tags, the PR. Done 2026-09-04; the memory says the PR is not
      opened.

## Acceptance

The plan is implemented when all of these hold:

1. `gc-regions` exists on `origin`, 20 commits on `origin/release-1.13`,
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

Status on 2026-09-04 12:40: items 1, 2, 4, 5, 6 and 7 hold. Item 1:
`origin/gc-regions` is `6159d71b25`, 20 commits on `origin/release-1.13`,
Check 1 empty; every commit builds by Check 2 on the second cut for commits
1 to 13 (tree identity with the fourth cut), and the build inputs of commits
14 to 20 equal those of commit 13 (`git diff --quiet fdf84973a2 6159d71b25
-- . ':!test' ':!doc' ':!contrib'`), and the tip built alone. Item 2: the
four groups pass on the binary of the third cut's tip, whose build and test
inputs are the fourth cut's. Item 3 holds except "measured on the tip's
SHA": the tables ran on `48603f334c`, before the B16 fix, and
`MEASUREMENTS.md` says so and says why they stand (D15). Item 5: the four
`backup/*-2026-09-03` tags and `release-1.13` are on `origin`; the three
cut tags and `gc-regions-flat` are local. After D16 (13:05) the four tags
are `obsolete/*-2026-09-03`, the four cut tags are
`obsolete/gc-regions-cut{1,2,3,4}-2026-09-04` (local), `gc-regions-flat` is
on `origin` too, and `origin/gc-regions` is `4b02199e76`.

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

Final on 2026-09-04. Every number repeats a table of `MEASUREMENTS.md`.

Title: **GC: memory regions — free the objects of one lifetime in O(1), beside the stock collector**

> This branch adds regions to the stock collector. A region is the set of
> objects that a thread allocates while a region window is open. A reset
> returns the pages of the region in O(1), with no trace. The stock collector
> never traces the pages of a region; the two coexist with no contract
> between them. Regions form a declared tree (eight today); sibling regions
> are isolated.
>
> One rule keeps it safe: a reference must point to an object of equal or
> longer lifetime. A checked write barrier turns a violation into a
> quarantined region — a leak, never a dangling pointer. A census collects
> one region alone, stop-the-world or cooperative, and an open region past a
> growth threshold censuses itself, so internal garbage cannot grow a region
> without bound.
>
> **Why.** Hard real-time loops: a discrete-event simulation that drives
> hardware. On a 5-million-event loop with about 1.7 KB of garbage per
> event, on an isolated core, the longest pause goes from 3,831 µs (stock)
> to 16 µs (regions, no census) or 55 µs (regions, with a census):
> [MEASUREMENTS.md](https://github.com/levy/julia/blob/gc-regions/contrib/memory-regions/MEASUREMENTS.md),
> M4, `results/plots/max_pause.svg`.
>
> **Cost when unused.** On the GCBenchmarks subset (nine benchmarks, 1 and
> 4 threads) the ratio regions / vanilla is 0.96 to 1.03 on eight of them,
> inside the round-to-round spread of each; `many_refs` runs at 0.92 because
> of a stock-path fix in this branch (a deferred collection re-arms its
> trigger). The unit costs are not zero (M2): a pointer store pays one flag
> load and a predicted branch (0.41 ns against 0.32 ns); an object
> constructed with two pointer fields pays a barrier that vanilla omits
> (8.2 ns against 7.1 ns); the stock mark pays about 1 %. Two build
> defines exist for measurement, not for production:
> `JL_NO_REGION_STORE_BARRIER` takes the barrier out (a store and a
> construction compile as vanilla compiles them), `JL_NO_REGION_ALLOC`
> takes the region pools out and folds the census filter out of the mark
> loops; a build with both keeps one page tag per page and nothing per
> object. The region tests fail on both builds by design.
>
> **Cost when used.** A window pair 10.5 ns, a reset under 30 ns (the two
> clock reads are 10 of it), an armed store 1.4 ns, an allocation in a
> region 3.7 ns against 3.3 ns in the stock pool of the same process (M2).
> The wall-time win appears only where the discarded allocation per unit of
> work dominates, and the demonstrators show the crossover (M10): a bare
> optimistic insert loses at 0.44x; the same insert with heavy speculation
> wins at 1.98x. A region holds its garbage until the reset, so the peak RSS
> of the demonstrators is within 9 % of the stock run, above it on one point
> (C at work=256, 594 MB against 547 MB).
>
> **What it is not.** No Base API: the Julia face is a `ccall` wrapper in
> `contrib/memory-regions/regions.jl`, and the runtime API takes region
> integers. Base changes in one place: the slow path of `OncePerProcess`
> and `OncePerThread` in `base/lock.jl` runs with the window suspended, so
> the scheduler task and the sticky work queue a first `wait` on a thread
> makes land in region 0. No compilation inside a window: inference,
> compilation, the method-cache miss path, and a new type instantiation run
> in region 0. A
> `WeakRef` to a region object and a system image inside a window are
> refused. Measured on Linux x86-64 only. Based on `v1.13.0-rc4`; a port to
> `master` is separate work.
>
> **How to read it.** Thirteen runtime commits, one idea each, in
> `src/gc-regions.c` with small hooks in the stock collector; then the tests
> (`test/gc/regions_*.jl`), the devdoc (`doc/src/devdocs/gc-regions.md`), the
> benchmarks, the demonstrators, the measurements with their data and plots,
> and the history.
> [HISTORY.md](https://github.com/levy/julia/blob/gc-regions/contrib/memory-regions/HISTORY.md)
> records every detour and every rejected idea, and the sixteen bugs that
> the final review and its test gate found in the development runtime, each
> with a test in the series; three of them were silent heap corruption. The
> tables of `MEASUREMENTS.md` ran on `48603f334c`, a commit of the flat
> tree before the last fix; the document says what the tip adds and why the
> tables stand for it. The four
> development branches are not rewritten: they are the branches
> `obsolete/<name>`, with their tips at the start of the tidy under the tags
> `obsolete/<name>-2026-09-03`; the tag `gc-regions-flat` marks the flat
> tree the series was cut from.
>
> Branch: https://github.com/levy/julia/tree/gc-regions ·
> Design: https://github.com/levy/julia/blob/gc-regions/doc/src/devdocs/gc-regions.md ·
> Measurements: https://github.com/levy/julia/blob/gc-regions/contrib/memory-regions/MEASUREMENTS.md ·
> History: https://github.com/levy/julia/blob/gc-regions/contrib/memory-regions/HISTORY.md ·
> contrib README: https://github.com/levy/julia/blob/gc-regions/contrib/memory-regions/README.md
>
> Questions for the review: whether the placement of the barrier in
> `cgutils.cpp` and `llvm-late-gc-lowering.cpp` is the one you would choose;
> whether the task-follows-window rule in `task.c` is acceptable; whether
> `jl_gc_region_collect` on a region never used on a heap must return
> `EINVAL`, as it does, where `jl_gc_region_reset` returns 0 for the same
> region; whether a Base API is wanted before or after the runtime.
