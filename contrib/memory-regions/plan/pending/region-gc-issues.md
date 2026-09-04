# Region GC — the issues a code review found

This plan collects the robustness, correctness and safety issues of the
region collector that a review of the sixth cut found, and it says how to
close them. The series `gc-regions` on levy/julia is at `3577055ee6`; the
flat tree is the tag `gc-regions-flat` at `d543cb834a`. The pull request is
not opened.

The tidy plan is `region-gc-tidy.md` in this folder. That plan built the
series and its gate. This plan changes the runtime.

## Status of the evidence

Every issue below comes from a read of the source at `d543cb834a`. **No
issue below is reproduced by a test.** The place and the code path are
facts; the consequence is a deduction from the code. Step 1 of the work is
to turn each consequence into a test that fails, before any fix.

## The rule that every issue is measured against

Rule 3 of the design says a reference from an older region into a younger
one is an escape. Rule 4 says the write barrier catches such a store and
quarantines the child's region. An issue below is a hole when a store that
breaks rule 3 does not reach the barrier, or when the runtime frees a region
that rule 4 already condemned.

An invariant carries most of the runtime: **the runtime's own objects are
always region 0**, because the branch forces region 0 around inference,
compilation, a dispatch cache miss, and a type instantiation. A region-0
child is legal under any parent. This invariant is why most unbarriered
stores in the runtime are harmless. It is load-bearing and it is not written
down. Write it down (see I9).

## The issues

### I1 — The constructor stores of the C runtime do not run the region check

**Rank: first. Class: correctness and safety.**

The generational shortcut "the parent is fresh, so no barrier is needed" is
inverted for a region. A fresh parent takes the **current** region. The
child can come from an **earlier** window. The hole opens when the window is
closed, the parent is region 0, and the child survived an earlier window.
The compiled path was fixed for exactly this (stock-path change S4 forces
`need_wb = true` in `emit_new_struct`). The C constructors were not.

Three barrier entry points are empty functions, so a store they annotate
runs no region check:

| Entry | Where | Its generational reason |
| --- | --- | --- |
| `jl_gc_wb_fresh` | `src/gc-interface.h:255` | the parent is young |
| `jl_gc_wb_current_task` | `src/gc-interface.h:262` | the parent is in the remembered set |
| `jl_gc_wb_knownold` | `src/gc-interface.h:265` | the child is old |

None of the three reasons says anything about a region.

Two more barriers carry no region check, and they move many references at
once:

- `jl_gc_wb_genericmemory_copy_boxed`, `src/gc-wb-stock.h:66`, called by
  `jl_genericmemory_copyto`, `src/genericmemory.c:234`. `Base.copyto!`
  reaches it through `base/genericmemory.jl:143`.
- `jl_gc_wb_genericmemory_copy_ptr`, `src/gc-wb-stock.h:115`, called at
  `src/genericmemory.c:250`.

`jl_gc_wb_back`, `src/gc-wb-stock.h:39`, takes no child, so it cannot check.
Its sites are `src/task.c:514` and `src/gc-stock.c:1608` and `:1630`.

**The sites that carry a user value.** These are the ones a program can
reach with a region object as the child:

| Site | What it stores |
| --- | --- |
| `src/task.c:1142` | `t->start`, the closure the task runs |
| `src/task.c:1144` | `t->donenotify` |
| `src/task.c:1147` | `t->scope`, through `jl_gc_wb_fresh` |
| `src/opaque_closure.c:128` | `oc->captures`, the captured environment |
| `src/genericmemory.c:285` | the element copy of `jl_genericmemory_copy_slice`, which is `copy` of an array, with no barrier of any kind |
| `src/genericmemory.c:234`, `:250` | the element copy of `copyto!` |
| `src/genericmemory.c:309` | `m->mem` of `jl_new_memoryref` |
| `src/genericmemory.c:113` | the owner field of `jl_string_to_genericmemory` |
| `src/simplevector.c:44`, `:55`, `:67`, `:105` | the raw element writes of `jl_svec1`, `jl_svec2`, `jl_svec3`, `jl_svec_fill` |
| `src/simplevector.c:96` | the element copy of `jl_svec_copy` |
| `src/interpreter.c:547`, `src/rtutils.c:300`, `:340` | `ct->scope`, through `jl_gc_wb_current_task` |
| `src/codegen.cpp:6288`, `:9573` | `ct->scope` from compiled code, with no barrier at all |
| `src/module.c:184`, `:633`, `:1724`, `:1734` | the `restriction` of a binding partition, through `jl_gc_wb_fresh` |
| `src/gf.c:3212` | the `{f, args, world}` copy of `jl_method_error_bare` |

The sharpest of these is `src/task.c:1142`. The documentation tells the
program to make its tasks **outside** the window. The natural code builds
the closure inside the window and spawns the task outside. That puts a
region child into a stock `Task` with no check.

**Detection gap without a dangling pointer.** The splat path builds its
argument vector with no barrier: `src/builtins.c:761` and the element copy
of `_copy_to`, `src/builtins.c:635`. The elements are the caller's own
arguments, so `f(region_objects...)` is unchecked. The vector dies with the
call, so nothing dangles. What is lost is the report. The comment at
`src/builtins.c:773` states the generational reasoning in full, which makes
it the clearest example of the inverted assumption.

**Not a hole, for the record.** `a->ref.mem = mem` in `_new_array`,
`src/array.c:65`, needs no check: the caller allocates the backing memory
moments before, so the array and its memory always share the current region.
The same holds for `src/ircode.c:643` and `src/builtins.c:1739`.

**Not a hole, by the region-0 invariant.** The unbarriered stores of
`jltypes.c`, `gf.c` (except `jl_method_error_bare`), `method.c`,
`datatype.c`, `staticdata.c` and `toplevel.c` store symbols, modules, types,
methods, code data or image data. All of those are region 0.

**Fix shape.** Give the three empty entry points the region check, and leave
their generational body empty. That closes every annotated site in one edit.
Then add the check, or the annotation, at the sites that write raw. The
owning commit is stage 5, "the escape barrier quarantines the region of an
escaped child".

**Warning: this fix has a price.** The check is one load of the armed flag
and a predicted branch at each site. Two of the sites are hot
(`jl_new_memoryref`, the splat copy). M1 and M2 must run again after the
fix. Read "The cost gate" below before the site list grows.

### I2 — The reset frees a region a finalizer quarantined

**Rank: second. Class: correctness and safety.**

`jl_gc_region_reset` tests the quarantine at `src/gc-regions.c:536` and runs
the debug root check at `:545`. It then calls `region_reset_heap`, which
runs the region's own finalizers at `src/gc-regions.c:494` and frees the
pages at `:499`. A finalizer runs arbitrary Julia code with the barrier
armed. A finalizer that stores a region object into a stock object
quarantines the region, and the reset, already past its check, frees the
pages under that reference.

The global reset is immune: it refuses a region with pending finalizers
(`EFINALIZERS`).

No test covers the case. `test/gc/regions_escape.jl` has no finalizer, and
the finalizer of `test/gc/regions_lifetime.jl:147` stores a fresh region-0
object.

**Fix shape.** Read the quarantine again after the finalizer list ran. Keep
the pages and return `EQUARANTINED` when it is set. The owning commit is
stage 4, "reset a region in O(1)".

### I3 — Two cooperative censuses can pass the same gate

**Rank: third. Class: correctness.**

`jl_gc_region_collect_coop` reads the window count at
`src/gc-regions.c:904` and increments it at `:909`. The read and the
increment are not one act, so two threads can both pass. Both then write the
one process-wide filter `jl_gc_region_census_target` and share the one
`region_census_tasks` table. A census that marks with another region's
filter sweeps live objects.

The stop-the-world census is safe: `jl_safepoint_start_gc` serializes it,
and the loser gets `ERACE`.

**Fix shape.** Replace the read and the increment by one compare-exchange on
a dedicated flag, or by a compare-exchange from 0 to 1 on the window count.
The owning commit is stage 7, "the census collects one region alone".

### I4 — A task that dies inside a window leaks the window count

**Class: robustness.**

Only `jl_gc_region_set(0)` decrements `region_windows_open`
(`src/gc-regions.c:452`), and no task-exit hook closes a window. A task that
dies with a window open leaves the count above zero for the life of the
process. From then on `jl_gc_region_collect`, `jl_gc_region_collect_coop`,
`jl_gc_region_reset_global`, `jl_gc_region_declare_parent` and
`jl_gc_region_check` return `EBUSY`. There is no recovery.

The macro `@with_region` of `contrib/memory-regions/regions.jl` protects
with `try`/`finally`. The raw entry, which the documentation calls the
interface, does not.

**Fix shape.** Close the window of a task that finishes. The task switch
already carries the state (`jl_gc_region_task_switch`,
`src/gc-regions.h:151`), so the exit path can decrement the count for a task
whose `region` field is not 0. The owning commit is stage 6, "a window
belongs to its task".

### I5 — Guards that detect but do not prevent

**Class: robustness.**

- `jl_gc_free_page` prints `FREEPAGE-TAGGED … a tagged page must never
  free` and then frees the page (`src/gc-pages.c:235`). The guard names the
  violation and lets the harm happen. Make it keep the page.
- `gc_setmark_pool` calls `abort()` on a pool object with no page metadata
  (`src/gc-stock.c:337`). It runs in every program, region or not, and it
  ends the process without a Julia backtrace. Keep the diagnosis; decide
  whether an abort or the stock fault is the better end. This is recorded as
  stock-path change S3, so a change here needs its own line in `HISTORY.md`.

### I6 — Races on shared state

**Class: robustness.**

- `jl_gc_region_declare_parent` checks the window count and every heap's
  live mask, then writes `region_parent[]` and rebuilds the eight
  `region_uptree[]` entries with relaxed stores (`src/gc-regions.c:126`). A
  window that opens on another thread in that gap reads a half-built tree.
  The declaration is a startup act, so the likelihood is low.
- `region_collect_stats[8]` (`src/gc-regions.c:66`) is a plain global. Two
  censuses on two threads interleave their numbers.
- `jl_gc_region_census_page_threshold` (`src/gc-regions.c:78`) is a plain
  `int` written from one thread and read on the allocation path of every
  thread.
- The armed flag is stored with release and read relaxed. On x86-64 that is
  enough. The cost is measured on x86-64 only; on a weaker memory model
  another thread can miss the arming for a while.

### I7 — Cross-heap effects

**Class: robustness.**

- A census marks region objects on **every** heap, because
  `region_census_mark` walks the execution roots of every thread
  (`src/gc-regions.c:793`), and `region_scoped_sweep` clears the marks of
  the calling heap alone. Dead cells on the other heaps look live until the
  next stock collection clears them. The result is a delay, not a
  corruption.
- `jl_gc_region_reset` does not test whether another heap holds the same
  region. "Use the global reset for a region several threads fill" is a
  limit in the documentation, not a refusal in the code.

### I8 — The cost that the Cost section does not name

**Class: documentation.**

Each thread heap carries eight full pool arrays (`regions[8]`, each with
`jl_gc_pool_t pools[51]`), about 10 KB per thread, plus the masks and the
child counts (`src/gc-tls-stock.h:40`). Every page metadata grows by
`region_n` and `region_next`. Both costs are unconditional. Name them in the
Cost section of the developer documentation.

### I9 — Two rules the documentation does not state

**Class: documentation.**

- **The region-0 invariant.** The runtime's own objects are always region 0,
  because the forced region-0 zones put them there, and a region-0 child is
  legal under any parent. This is why the unbarriered stores of the type
  system and the method table are sound. State it next to rule 4. Anyone who
  removes a forced zone opens a class of missed escapes at once.
- **The barrier sees managed stores only.** A store from C code, and
  `unsafe_store!`, are invisible. Add the rule to "Discipline the barrier
  does not remove".

## Decisions

- **D1. Fix the bug, do not add a feature.** Every change of this plan
  closes a hole that exists. No new entry point, no new mode.
- **D2. Each fix goes into its owning stage.** The series is a staged
  reveal; a fix that lands as a later commit would leave its own stage
  wrong. Take the stages again with `retake.sh` of
  `workspace/julia-gc-series-tooling`, as D17 of the tidy plan did. The
  owning stage of each fix is named above.
- **D3. The tests go into stage 14.** The test commit is one commit
  ("regions: the tests"), whatever stage the fix belongs to.
- **D4. A test comes before its fix.** Each issue needs a test that fails on
  `d543cb834a` first. An issue whose test cannot be made to fail is reported
  as such and is not "fixed".
- **D5. The cost gate decides the width of I1.** See below.

## The cost gate

I1 widens the barrier to sites that pay nothing today. The claim "the cost
when unused is small" is measured, published in `MEASUREMENTS.md`, and it is
the first thing a reviewer will test. So:

1. Fix the three empty entry points first, and measure.
2. Run M1 (`bench/gcbench.sh`) and M2 (`bench/unit_costs.jl`) against the
   same vanilla binary the tables used.
3. Accept the fix when `store_disarmed`, `construct_two`, `alloc_stock` and
   the GCBenchmark ratios stay inside the spread the tables record.
4. If a row moves outside its spread, cut the site list to the sites that
   can carry a user value, and measure again.
5. Update the tables and the Cost section with the new numbers. A cost that
   grew must appear in the tables, not in prose alone.

## Steps

### Step 1 — Reproduce

- [ ] Write a failing test for I1 with a task: build a closure inside a
      window, spawn the task outside, reset, and read the closure. Expect a
      `CORPSE` abort or a wrong value today.
- [ ] Write a failing test for I1 with `copy` and with `copyto!` on a
      `Vector{Any}`: copy region objects into a region-0 vector, reset, and
      read. Assert that the region is quarantined; today it is not.
- [ ] Write a failing test for I2: register a finalizer on a region object
      whose body stores the object into a global, then reset. Assert that
      the reset returns `EQUARANTINED`; today it frees.
- [ ] Write a failing test for I4: run a task that opens a window and throws
      past it, then assert that `jl_gc_region_collect` does not return
      `EBUSY`.
- [ ] Record which tests fail as expected and which do not. An issue whose
      test passes today is downgraded and its entry above is corrected.
- [ ] I3, I6 and I7 need a race or several heaps. Write a stress script for
      I3 if one can be made to fail in a bounded time; otherwise fix by
      inspection and say so.

### Step 2 — Fix, one commit per issue, on the flat tree

Work on the flat worktree `workspace/julia-gc-regions`, as the tidy plan
did. Build with `nice -n 10 taskset -c 16-23 make -j8`.

- [ ] I1 part 1: the region check in `jl_gc_wb_fresh`,
      `jl_gc_wb_current_task` and `jl_gc_wb_knownold`.
- [ ] I1 part 2: the region check in the two `GenericMemory` copy barriers.
- [ ] I1 part 3: the sites that write raw, from the table above.
- [ ] Run the cost gate. Record the numbers.
- [ ] I2: the second quarantine test after the finalizers.
- [ ] I3: one compare-exchange.
- [ ] I4: close the window of a task that finishes.
- [ ] I5: keep a tagged page instead of freeing it; decide the abort.
- [ ] I6: atomics for the two globals; make the declaration atomic against a
      window.
- [ ] I7: clear the marks the census set on other heaps, or refuse a census
      of a region that another heap holds. Choose one and say why.
- [ ] I8 and I9: the documentation.

### Step 3 — Fold into the series

- [ ] Map each flat commit to its owning stage with `xstage.py`.
- [ ] Move the annotated markers in `annotated/` of the tooling repository so
      each change appears at its stage.
- [ ] `reveal.py check` passes.
- [ ] `retake.sh <worktree> <commit before the first stage> <first stage>`
      from the lowest stage that changed. Stage 4 is the lowest one this plan
      touches, so commits 1 to 3 keep their SHAs.
- [ ] Check 1: the tree of the branch equals the tree of the flat tag.

### Step 4 — The gate

- [ ] Check 2 and Check 3 with `check23.sh <first stage>`: every commit
      builds, `julia -e 1` runs, and the five region scripts pass at commit
      13.
- [ ] The `gc` group on the tip binary: 0 fail, 0 error.
- [ ] `core threads misc` on the tip binary. I1 changes the code of the
      default build, so the result of the third cut does **not** carry over.
- [ ] `make -C doc html` builds.
- [ ] M1 and M2 again, with the tables and the Cost section updated.

### Step 5 — Close

- [ ] Add a bug row for each fixed issue to `HISTORY.md`, in the shape the
      B-numbers use, and a stock-path row for I5 if the abort changes.
- [ ] Update the pull request text in `region-gc-tidy.md` if a cost number
      moved.
- [ ] Push `gc-regions` with `--force-with-lease`, and the flat tag.
- [ ] Move this plan to `plan/done/`.

## Acceptance

- Every test of Step 1 that failed on `d543cb834a` passes on the tip.
- The gate of Step 4 is green.
- The cost rows of M1 and M2 stay inside their spread, or the tables carry
  the new numbers and the Cost section explains them.
- `HISTORY.md` names every issue this plan closed, and the developer
  documentation carries I8 and I9.

## Risks

- **The barrier grows wider than the measurements allow.** The cost gate is
  the control. The fallback is a smaller site list, and an honest sentence
  that says which stores stay unchecked.
- **A re-cut costs a full check.** Check 2 and Check 3 over commits 4 to 20
  take about 90 minutes of builds. Run them on cores 16 to 23 with `nice`,
  and never on the timing cores.
- **A fix at stage 4 or 5 moves eighteen commit SHAs.** Everything that
  names a SHA — this plan, the tidy plan, `HISTORY.md`, the memory — must be
  updated in the same pass.
- **A test for I1 can abort the test process** when it reproduces a
  `CORPSE`. Run such a test as its own process, the way `test/gc.jl` runs
  the region scripts.

## Out of scope

- Any new region feature. The eight-region cap, the one-heap rule, the
  missing `Base` API and the permanent quarantine stay as they are.
- The standing discipline rules the documentation already states: a closed
  window before a reset, no top-level window, an exception caught inside the
  window, no blocking, tasks made outside, no `WeakRef`, no serialization.
- The deferred item of `HISTORY.md`: a per-region count of open windows, so
  a reset can see a parked task of the same thread. It is a real gap; it
  needs a design, not a fix.
