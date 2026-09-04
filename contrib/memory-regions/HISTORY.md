# The history of the region collector

The source, the tests, and the devdoc (`doc/src/devdocs/gc-regions.md`)
describe what the region collector is. This document holds what they leave
out: the order in which the work happened, the ideas that were tried and
dropped, the bugs that the tidy found, the ideas that the tidy did not build,
the fate of every entry point of the development runtime, and the tags that
keep the development branches. A reader who wants the code does not need this
document. A reader who asks "why not the other way?" starts here.

The development happened in ten plans on four branches of `levy/julia`, all on
`v1.13.0-rc3`. The tidy (2026-09-03 to 2026-09-04) ported the union of the
four tips onto `v1.13.0-rc4` as one flat tree, reviewed every line of the
runtime delta, fixed what the review found, moved the scripts into tests and
benchmarks, and cut the result into the commit series of the branch. The
development branches are renamed `obsolete/<name>`; their tips stay under
the tags of the section "The obsolete branches and their tags".

## The ten plans

The plans are in the order the work happened. Each section gives the
question, what was tried, what was dropped and why, and what landed.

### 1. The branch rebuild (2026-09-01)

The first runtime was one 779-line commit. The question was how to make it a
series that a reader can follow. A script cut the final files against the
base files into stages, one runtime idea per stage, and asserted that the last
stage equals the old runtime byte for byte. The runtime landed as ten commits
and the Julia side as eight. Every stage got a smoke test that used only what
the stage newly allowed, so a failure pointed at its stage.

Several smoke tests failed on their first attempt, and each failure taught a
rule of the design. A test that allocated an array with malloc'd data inside
a window crashed with glibc heap corruption: the reset knew nothing about the
runtime's malloc list. That became a documented limit at the time, and the
maturation later fixed it (malloc'd data of a region goes to the region's own
list). A test that held its census table in a global binding segfaulted: a
global is a store into region 0, and the census marks only from the execution
roots, so the cells of the table were freed. The table moved onto a function
frame, and "a global never holds a region object" became rule 3. A test that
wrapped a finalizer registration in a compiled `try` never saw the refusal,
because the compiler removes an effect-free registration. The test moved to a
child process's interpreted top level. A test that asserted "no collector time
inside a window" failed on timing, because the collection a window owes runs
at the first allocation after the window closes. Smoke tests inside a window
were restricted to calls on functions compiled before the window opened,
because a compile inside a window pinned region 0 and let the owed collection
run during the pin.

Two detours of the tooling: the stage-cutting script first anchored on a
forward declaration and corrupted two stages (fixed by anchoring on the
signature plus the opening brace), and a build on every core crashed the IDE
(builds ran on half the cores from then on).

### 2. The real-world measurement (2026-09-01)

The question was the latency of the configuration a real event loop runs: one
window per slice of events, one reset per slice, a cooperative census at a
slice boundary, against the stock collector. Five million events ran at two
cache-optimal (window, slice) points: about 100 bytes per event with slices
of 1000, and about 1.7 KB per event with slices of 100. The census's share of
the distribution shows by its absence between two runs, one with the census
and one without it.

The measurement found two sources of interference. A stall of about 330 µs of
kernel time, once per about 4 MB of new pages, was first blamed on page-block
claims, then on a checklist of context switches, syscalls, cgroup pressure,
transparent huge pages, NUMA, KSM, page migration, and the mmap lock. `perf`
and the function-graph tracer named the real cause: `rmqueue_bulk` refills
the per-CPU free list under the zone lock with interrupts off, 1008 pages at a
time. The second finding was a deferred `jl_gc_collect` that re-armed its
trigger at zero (plan 3). The preemption method also changed: "keep only a
zero-switch run" failed on this machine, because an idle core still took three
to five preemptions per run, so the driver samples the involuntary-switch
counter every 10 000 events and reports the maximum over the blocks with none.
Peak RSS replaced `gc_live_bytes` in the memory row, because the stock
accounting never subtracts what a reset frees.

### 3. The deferral re-arm (2026-09-01)

With the stock collector disabled, a deferred `jl_gc_collect` re-armed the
allocation trigger near zero, so the next allocation re-entered
`jl_gc_collect` at once: about 20 ns per allocation, 10 % of a region run's
samples. The first diagnosis, `gc_num.interval` near zero, was wrong; the
trigger is `maybe_collect`'s test `heap_size >= heap_target`. The fix re-arms
`heap_target = heap_size + grant`, with the same minimum grant a real
collection gives. The first edit anchored on the wrong line and changed
nothing; the unchanged measurement (10.17 %) proved that before anyone trusted
it. Both deferral branches were then edited. `ijl_gc_collect`'s share of
samples went from 10.2 % to 0.01 %, and the light-garbage loop from 13.5 to
17.1 million events per second. The consequence went into the documents: the
collection a window owes now runs when the granted allowance is spent, not at
the first allocation after the window closes.

### 4. The prefault for the HIL loop (2026-09-01)

A hardware-in-the-loop simulator must not take page faults inside its loop,
and a measurement that cannot be reproduced is worthless. `jl_gc_heap_reserve`
(then `jl_gc_region_reserve`) maps whole page blocks with `MAP_POPULATE` into
the clean pool, so a loop whose heap fits the reserve maps and faults nothing.
The first version left pages the runtime claimed at startup unfaulted: a
512 MB reserve still showed 43, 19, and 21 faults in the light workload. The
guess that free-list pop order caused them was wrong (the list is LIFO and
serves the reserve first). `perf record` under `setarch -R` found JIT code
that touched pages inside GC blocks claimed before the reserve existed. The
second version records every claimed block and prefaults it too, with
`MADV_POPULATE_WRITE`. The light probe then read zero faults. The documents
say plainly that the measurement is Julia and its collector under the best
case a simulator can arrange, not the OS, and that the peak RSS includes the
reserve.

### 5. No preemption (2026-09-01, reboot later)

The other half of "the OS must not bite": the loop runs on a real-time class
on an isolated core, not on the least-preempted of several tries. The user
chose full kernel isolation: `isolcpus`, `nohz_full`, and `rcu_nocbs` on
CPUs 13 and 29 (the two hardware threads of one core; the loop pins to 29 and
13 stays idle), real-time and memlock limits raised in systemd and PAM,
real-time throttling disabled, and a reboot. The limits went into
`/etc/systemd/system.conf` and `user.conf`, not only `limits.conf`, because
`pam_limits` is not wired into `common-session` on this machine. After the
reboot every kept run showed `SCHED_FIFO`, a locked memory image, zero
involuntary context switches, and zero page faults; nine interrupts reached
CPU 29 in a 3 s run. The stock recording-class p99.99 went from 3.6 µs to
691 ns. The per-block attribution method stays as the fallback for a machine
without this isolation.

### 6. The optimisation loop (undated, after plan 5)

From the isolated-core baseline (recording class 12.9 million events per
second, light 18.1), four iterations of measure, reason, change, remeasure,
keep or revert. Kept: the O(1) reset, which clears the pool cursors and parks
the whole page chain on the fresh list instead of a per-page `gc_reset_page`
(reset 1916 ns to 21 ns; boundary events p50 2024 ns to 120 ns; events over
800 ns from 50 000 to 0). Kept: the non-atomic scoped mark, because under the
census's single-mutator contract there is no race (mark 58 µs to 32 µs, pause
max 73 µs to 50 µs, about 2.4 ns per live object). Reverted: a software
prefetch of the next array element's header, because the records already
stream under the hardware prefetcher (mark 58.4 µs to 60.9 µs). Reverted: a
one-entry page-metadata cache in the scoped filter, because the page-table
walk was not the bottleneck (58.4 µs to 58.0 µs). The loop stopped when the
remaining costs (mark about 3 ns per object, sweep 4 to 7 µs, window 5.2 ns,
reset 21 ns) were near the floor. The final matrix: recording class 15.6
against stock's 7.2 million events per second, every percentile won, max
53 µs; light 18.2 million events per second, with stock 1 ns ahead at the
median.

### 7. The maturation (2026-09-03)

The question was what the region collector needs to be a runtime feature:
zero cost when unused, full benefit when used alone, coexistence with the
stock collector. Stage 0 recorded the user's direction that nothing goes to
public project pages. Stage 1 landed the soundness prerequisites: the window
follows its task (a task carries its region across a context switch and an
open window makes the task sticky), the escape barrier with the quarantine
(a flag armed at the first `region_set`; disarmed, one predicted branch per
store), malloc'd data on the region's own list, and per-region finalizer
lists (the reset runs them all, the cooperative census runs the dead ones,
the stop-the-world census refuses a region with live finalizers). Stage 2
landed coexistence simpler than designed: the stock mark walks region objects
normally, a bracket installs region 0 on every stopped thread during a stock
collection, and the marks on region pages are cleared afterward. The card
barrier the design had planned was not built, because `has_marked` already
acts as the card. Stage 3 built the multithreaded shape on the guarantees the
barrier gives. Stage 4 collected the evidence against vanilla Julia.

Two census detours: claiming a task by its mark bits was dropped, because a
stock collection leaves tasks old-marked and the claim would skip live
stacks; restoring a task to a generic old-unmarked state was dropped, because
it breaks the remembered-set invariant. The census claims every task and
restores each task's exact prior bits.

The zero-cost claim had one real regression, misread twice. The `big_arrays`
stressors read 1.08 and 1.24 against vanilla, and two load hoists meant to
fix them measured no change: the load was never the cost. A signal-based
profile found a fortified `memcpy` inside the work-stealing queue: the region
filter's body had pushed the mark drain past GCC's inline budget, so every
marked object paid a real call and a size-checked copy, about 40 % of a 35
million object mark. `FORCE_INLINE` on the queue's push and pop and a
`NOINLINE` outlined filter (`gc_scoped_claim`) put the drain back to
vanilla's code: mark time 1369 ms to 955 ms against vanilla's 967 ms. The
serial GCBenchmarks then read 1.01, 1.00, 1.01, 1.06, 0.98, 0.92.

### 8. The chain residuals (2026-09-03)

Every item left in prose after the maturation became a test or a recorded
decision. The `many_refs` allocation gain (region about 2x faster than
vanilla, collector off) was traced by a bisect over 30 base commits to the
deferral re-arm: vanilla re-enters `jl_gc_collect` on every allocation while
the heap sits above its target and the collector is disabled. Per-phase page
faults, syscalls, the loop code, and the page layout had all measured equal.
`JL_NO_REGION_ALLOC` compiles the allocation indirection out, as
`JL_NO_REGION_STORE_BARRIER` does the barrier. The armed barrier got the
child-first order (a region-0 child is legal under any parent, so the common
store returns after one page-map walk): 1.94 ns to 1.49 ns per armed store,
and the HIL kernel's p50 armed equals disarmed at 61 ns. An inline IR
tag-compare in the compiler was rejected: it would replicate the page-table
walk in every store's IR for no gain over the cold call.

The construction-store gap was worse than "elision": `emit_new_struct` stored
an already-boxed child with `need_wb = false`, so a region-1 child in a
region-0 parent was never checked. Three approaches: A, a construction-only
intrinsic; B, `need_wb = true` for boxed pointer children when the barrier is
compiled in; C, discipline only. B landed, because it ships the fix now, at
+1.4 ns per two-pointer-field construction in the worst case (42.4 to 43.8
ns), gone under `JL_NO_REGION_STORE_BARRIER`. A blocking `take!` inside a
window stays a discipline rule, not a runtime change. Weak references to a
region object are refused at `jl_gc_new_weakref_th`; the image writer refuses
inside a window; the id dict and serialization keep the generic quarantine.
The multithreaded sweep at four threads read 0.97, 1.06, and parity.

### 9. The region tree (2026-09-03)

The chain (region m is an ancestor of n when m < n) became a declared tree,
with a shared trunk and one private leaf per task as the motivating shape.
Parentage is declared data (`declare_parent`), with `parent < child`
enforced, so ids stay a topological order. Implicit parentage from the
nesting of windows was rejected, because it would depend on execution order
and give no answer for a region under two parents. The barrier tests an
ancestor bitmask in the cold call only; the disarmed path did not change. An
id names one lifetime globally, never a per-thread role, because two same-id
leaves on two threads would carry equal page tags and pass a cross-thread
store undetected. A leaf resets on the fast per-heap path behind a one-bit
precondition; a trunk resets as one stop-the-world act across every heap
(`reset_global`), because a per-heap trunk reset would dangle the references
of other threads. `JL_GC_MAX_REGIONS` went from 4 to 8. A postorder subtree
reset and a subtree census were deferred: the two-level shape needs neither.

The tree plan also closed the one hazard of the model that the demonstrators
had named: a computation whose garbage dies inside a window, such as a deep
backtracking search, grows its region without bound and runs out of memory,
where the stock collector reclaims the dead branches. The census of the open
region fires when the region grows past an armed threshold and sweeps the
dead cells in place: 156 MB of churn in one window holds 10 089 pages
disarmed against 63 pages armed. The census bounds the memory of the region,
not the time of the search.

### 10. The demonstrators (2026-09-03)

Four algorithms where the region runtime beats the stock collector on the
same code, under an explicit honesty bar: the same allocation on both sides,
the strongest stock alternative named, a bounded claim, zero quarantines. Two
compute-bound demonstrators (A, backtracking graph colouring; B, a parallel
path tracer with one sibling leaf per worker) win on collections and pauses
with a small wall-time gain, because the collector is a small share of a
compute-bound run. Two allocation-bound demonstrators (C, an optimistic
concurrent persistent BST; D, optimistic Delaunay mesh refinement) share one
shape: a trunk, per-worker speculative leaves, a committed winner, and an
O(1) leaf reset for every loser. Their wall-time gain rises with the
discarded speculative allocation: C from 0.44x (a loss, with almost nothing
per attempt) to 1.63x, D from parity to 1.39x, with the region's GC time flat
where stock's climbs from 4.6 ms to 278 ms. The stock baseline is the same
path-copying algorithm under the stock collector; a mutable in-place tree is a
different algorithm and is never claimed as beaten. D commits in seed-id
order so both runs converge to the same mesh, at the cost of not being
lock-free.

### 11. The tidy (2026-09-03 to 2026-09-04)

The tidy ported the union of the four tips onto `v1.13.0-rc4` as one flat
tree and checked the port equal to the truth. It then read every line of the
runtime delta as a reviewer, with the rule "test first, fix in the flat
tree, record here". The review found thirteen bugs in the development
runtime, two more surfaced while the scripts became tests, one more in the
final gate of the test suite, and every fix has a test that fails on the
development binary and passes on the new one. The
scripts became five test scripts under `test/gc/`, and the measurement
scripts became `bench/`, `demo/`, and `tools/`. The eighteen entry points
that survived the audit got one contract each in `src/gc-regions.h`. Every
measurement ran again on the flat tree; six faults of the harness and five
claims fell. The findings are in the section "Found during the tidy" below.

## The detours

The ideas the work tried and dropped, or the faults it found on the way. The
first seven are the ones a reader of the runtime meets first; the table after
them lists every detour of the ten plans.

- **The deferral re-arm.** A deferred `jl_gc_collect` re-armed its trigger
  at zero and cost 20 ns per allocation. The fix, `gc_defer_collection`
  re-arms `heap_target`, is a stock-path change with a visible consequence:
  a `GC.enable(false)` loop allocates at full speed on this runtime, and the
  `many_refs` benchmark reads below vanilla for that reason (plans 3, 8).
- **The inline-budget mark regression.** The census filter inside the mark
  drain pushed the drain over GCC's inline budget, and the stock mark paid a
  `memcpy` call per object. Two load hoists changed nothing; the fix is
  `FORCE_INLINE` on the queue operations and a `NOINLINE` filter (plan 7).
  The tidy met the same seam again: the B10 fix loaded the filter once more
  per object and cost the stock mark 6.4 %, until the mark loops loaded the
  filter once per object at the top.
- **The inline IR tag-compare, rejected.** An inline check of the two page
  tags in every store's IR was designed and not built: the child-first cold
  call already brought the armed store within 0.1 ns of the disarmed one, and
  the inline form would replicate the page-table walk in every store
  (plan 8).
- **The construction-store gap.** A constructor stored an already-boxed
  child without a write barrier, so the region barrier never saw it. The
  construction-only intrinsic (A) and discipline alone (C) lost to widening
  `need_wb` (B), at +1.4 ns per two-pointer-field construction as plan 8
  measured it; the flat tree measures +1.05 ns in a process without a window
  (M2). The intrinsic is a deferred item below.
- **The out-of-memory hazard and the census.** A search whose dead branches
  die inside a window grows its region without bound. The demonstrators
  first bounded the search by a node cap; the tree plan then built the census
  of the open region, fired on growth (plans 9, 10).
- **The compile inside a window.** The smoke tests of plan 1 called only
  functions compiled before the window opened, because a compile inside a
  window pinned region 0. The maturation made inference and compilation run
  in region 0. The tidy found two more first-time paths that had stayed in
  the window: a dynamic dispatch on a new signature and a type first
  instantiated at run time (B14, B15 below). Both run in region 0 now. The
  final gate of the test suite found a third, in Base: the scheduler task
  and the work queue a thread makes at its first idle wait (B16). Base
  makes them with the window suspended now. A
  window at top level stays the one case the runtime does not cover: the
  evaluator stores a `BindingPartition` of the region into a stock
  `Binding`, and the barrier quarantines the region exactly. That is rule 5
  of the devdoc: open a window inside a function.
- **A region object in a global binding.** The stage-7 smoke test of plan 1
  held its census table in a global and segfaulted, because a global is a
  store into region 0 and the census marks only from the execution roots.
  The maturation defined a store into a module binding, and a store into a
  compiler-generated `Box`, as escapes that the barrier catches (plans 1, 7).

| Detour | Why it was dropped | What replaced it |
| --- | --- | --- |
| The stage-cutting script anchored on a forward declaration of `jl_gc_region_check` | It corrupted stages 9 and 10 | Anchoring on the signature plus the opening brace |
| A build of every runtime stage with `make -j24` on every core | It crashed the IDE during the stage-3 build | Builds on half the cores |
| A stage-4 smoke test that asserted no collector time inside an open window | It failed on timing: the owed collection runs at the first allocation after the window closes | The test reads the pause count from inside the window |
| A stage-5 smoke test that allocated an array with malloc'd data inside a window | It crashed with glibc heap corruption: the reset did not know the runtime's malloc list | A pool-objects-only test and a documented limit; the maturation later fixed the limit |
| A stage-6 smoke test that wrapped a finalizer registration in a compiled `try` | The compiler removes an effect-free registration, so the refusal never reached the runtime | The registration runs at a child process's interpreted top level |
| A stage-7 smoke test that held the census table in a global binding | It segfaulted: a global is a store into region 0, and the census marks only from the execution roots | The table lives on a function frame |
| Page-block claims, then context switches, syscalls, faults, cgroup pressure, THP, NUMA, KSM, page migration, and the mmap lock, as the cause of the 330 µs stall | `perf` and the function-graph tracer named the real cause | `rmqueue_bulk` refills the per-CPU free list under the zone lock with interrupts off |
| "Keep only a zero-switch run" as the preemption method | An idle core still took three to five preemptions per run over twenty tries | Per-block attribution: the involuntary-switch counter sampled every 10 000 events |
| The re-arm bug diagnosed as `gc_num.interval` near zero | The real trigger is `maybe_collect`'s `heap_size >= heap_target` | `gc_defer_collection` re-arms `heap_target` |
| The first edit to `gc_defer_collection`, anchored past a `static_assert` in the stock branch | It changed nothing; the unchanged measurement proved it | The correct anchor, both deferral branches edited |
| A prefault only at the moment `jl_gc_heap_reserve` is called | Pages the runtime claimed at startup stayed unfaulted (43, 19, 21 faults) | Every claimed block is recorded and prefaulted with `MADV_POPULATE_WRITE` |
| Free-list pop order as the cause of the remaining faults | The list is LIFO and serves the reserve first | The finding of `perf record`: JIT code touched pages inside blocks claimed before the reserve |
| A software prefetch of the next array element's header in the census mark | It made the mark slower (58.4 to 60.9 µs): the records stream under the hardware prefetcher | Nothing; reverted |
| A one-entry (page, metadata) cache in the census's scoped filter | It measured no change (58.4 to 58.0 µs): the page-table walk was not the bottleneck | Nothing; reverted |
| A card barrier for stock and region coexistence | `has_marked` already acts as the card, and young collections stayed proportional without it | A bracket that installs region 0 on every stopped thread, plus the `has_marked` bit |
| A census that claims a task by its mark bits | A stock collection leaves tasks old-marked, so the claim would skip live stacks | The census claims every task regardless of its bits |
| A task restored to a generic old-unmarked state after the census | It breaks the remembered-set invariant | Each task's exact prior bits are restored |
| Two load hoists (an objarray commit and a memory8/16 twin) against the `single_ref` and `many_refs` cost | They measured no change: the load was never the cost | `FORCE_INLINE` on the work-stealing queue's push and pop, and a `NOINLINE` scoped filter |
| Per-phase page faults, syscalls, the loop code, or the page layout as the cause of the `many_refs` allocation gain | All measured equal between the two binaries | A bisect over the base commits: the deferral re-arm |
| A construction-only write-barrier intrinsic (A), or discipline alone (C), for the construction-store gap | A was more work than the pass allowed; C ships no fix | B: `need_wb = true` for boxed pointer children at construction |
| Implicit region parentage derived from the nesting of windows | It would depend on execution order and give no answer for a region under two parents | Declared parentage |
| A per-region `finalizing_region` flag against re-entry from a finalizer (the development runtime) | Stock finalizer lists need the same guard, and `jl_finalize_th` nests | A per-heap `finalizer_depth` (B11 below) |

## Found during the tidy

The review read the runtime delta (`8f33e09afe..fe0c579e36`, the flat port
of the truth) line by line, with four verdicts: clean, cleanup, bug, or
deferred. A bug got a test first, then a fix in the flat tree. Every test
below fails on the development binary and passes on the new one.

### Bugs

| # | Where | Symptom | Cause | Fix | Test |
| --- | --- | --- | --- | --- | --- |
| B1 | `gc_scoped_claim`, the census's record of tasks | After a census over more than 4096 young tasks, the next stock collection skips a task's stack and frees its live objects. | The record of tasks met outside the region was a fixed array of 4096; on overflow a young task kept `GC_MARKED`. | The record is a growable list of (task, bits) with a hash table as the dedup. | `census_many_tasks` in `regions_census.jl` (5000 tasks). |
| B1′ | The same record | The census loops forever with an unbounded queue (8.4 GB at 4200 tasks). | An overflowed task that references itself (a parked task through an `Event` wait queue) was not found by the dedup and was pushed on every visit. | Part of B1: the hash table is the dedup for every recorded task. | `census_many_tasks`. |
| B2 | The stock root phase | A stock collection frees a finalizer closure that only a region's finalizer list references; the reset then calls a freed function. | A region's finalizer list was not a stock root. | Every initialized region list on every heap is marked in the same phase as the stock lists (`jl_gc_region_mark_finalizer_lists`). | `closures_survive_stock_collections` in `regions_lifetime.jl`. |
| B3 | `region_run_finalizers` | A finalizer that yields lets another task open a window on the region during its reset. | The region's run loop set no `in_finalizer`, pushed no GC frame, and ran the list in the wrong order. | One `jl_gc_run_finalizer_list(ct, list)` factored out of `run_finalizers` in `gc-common.c`, called for stock and region lists alike. | `reset_runs_finalizers_in_reverse_order`, `reset_runs_every_finalizer` in `regions_lifetime.jl`. |
| B4 | `jl_gc_region_set`, `_reset`, `_verify`, `_quarantined`, and the others | A release build indexes past `regions[8]` on a bad region number; `_quarantined` shifted by an unchecked `n`. | Range checks were `assert` only. | Every entry refuses with `JL_GC_REGION_EINVAL` before it touches any state; one return-code table in `gc-regions.h`. | `bad_region_numbers` in `regions_window.jl`, `census_bad_number_refusals`, `tree_bad_declarations`. |
| B5 | `jl_gc_region_declare_parent` | A trunk reset is refused forever after a re-declaration, or a trunk reset frees a live child. | The declaration changed `region_parent[]` while the child was live, and the live-child count went stale. | The declaration refuses (`EBUSY`) while the child is live on any heap or any window is open. | `tree_declare_while_live`, `tree_declare_busy_while_open` in `regions_tree.jl`. |
| B6 | `jl_gc_region_add_finalizer` | A quiescent entry of a finalizer list was read as an object. | Entries tagged 2 are not objects; the hook tested them as objects. | The hook returns before the object test on a tagged entry. | The finalizer cases of `regions_lifetime.jl` run through the hook; no dedicated case. |
| B7 | `jl_gc_region_declare_parent` | After the declarations 2←1, 3←2, 2←0, a region-1 object stored into a region-3 object is not quarantined and dangles after the reset of region 1. | Only the child's ancestor mask was rebuilt. | Every ancestor mask is rebuilt from `region_parent[]` in index order after each accepted declaration. | `tree_redeclared_ancestor` in `regions_tree.jl`. |
| B8 | `jl_gc_region_reset_global` | The process hangs. | The trunk reset ran finalizers with the world stopped; a finalizer that allocated enough called `jl_gc_collect`, which waited for the world forever. | The reset refuses with `EFINALIZERS` when any heap's instance of the region has finalizers; a census runs first. | `reset_global_refuses_with_pending_finalizers` in `regions_lifetime.jl`. |
| B9 | `jl_gc_region_collect_coop` | A segfault in `jl_is_globally_rooted`. | The dead finalizers ran between mark and sweep with the census filter still set; a finalizer that allocated triggered a stock collection that marked through the filter and freed the heap. | Stock order: mark, then the dead finalizable objects and their functions are resurrected for one cycle through the scoped claim, then sweep, then the filter clears, then the pairs run. | `census_coop_finalizer_alloc` in `regions_census.jl`. |
| B10 | `gc_mark_obj8/16/32`, the unrolled last field | Silent heap corruption: a region-1 node whose last field is a region-0 vector of 50 000 `Ref`s loses the `Ref`s at the next young collection. Every task's `code` closure is such a last field. | The mark loop claimed the last pointer field with a raw `gc_try_setmark_tag`, not through the census filter; the census marked a region-0 object and left the mark, and the next stock collection did not scan it. | The unroll runs only while no census runs; under the filter the last field goes through the same claim as the others. The filter is loaded once per object, so the stock mark pays one relaxed load per object. | `census_last_field_leak` in `regions_census.jl`. |
| B11 | The epilogue of `jl_gc_collect`, `jl_finalize_th` | `REGION-ESCAPE`, and a region quarantined by a finalizer the program never saw run. | Stock finalizers ran inside the caller's open window: their allocations went into the region and their stores into stock objects were escapes. | Finalizer lists run with region 0 installed (`jl_gc_region_finalizers_begin/end`), under a per-heap `finalizer_depth`; while it is nonzero every region entry except `region_set(0)` and the queries refuses `EBUSY`. | `stock_finalizer_inside_a_window` in `regions_lifetime.jl`. |
| B12 | `region_finish_stock_collection`, `jl_gc_collect` | `GC error (probable corruption)` after `GC.gc(false); GC.gc(); GC.gc(false)` with a region object that references a stock array. | The marks a stock collection left on region pages were cleared once per `jl_gc_collect`, but a forced full collection runs two passes; a region object marked in the first pass was refused by the second, so its stock children were not marked and were swept. | `jl_gc_region_clear_stock_marks` runs in `_jl_gc_collect` after `gc_sweep_pool`, once per pass. | `second_pass_survives_alternating_collections` in `regions_lifetime.jl`. |
| B13 | `region_census_mark`, the stock task branch of `gc_mark_outrefs` | SIGSEGV in `gc_mark_outrefs` or `GC error (probable corruption)` at `--gcthreads=2` after a census, a stock collection, and churn. | The stock task branch re-adds an old task to the marking thread's remset; the census scanned every task and set no mark bit, so every old task sat in the remset with header `GC_OLD`, a state the stock protocol never produces. The next collection scanned the task as a remset object, its page kept `has_marked = 0`, and the sweep freed the page with the live task in it. A GC thread's root task is alone on its page. | The census saves `remset.len` and `remset_nptr` before it queues the roots and restores them after the last mark loop. | `census_leaves_remsets` in `regions_census.jl` (stop-the-world and cooperative). |
| B14 | `jl_lookup_generic_` in `gf.c` | `REGION-ESCAPE: a DataType of region 1 was stored into a SimpleVector of region 0`; the region is quarantined after a dynamic dispatch on a signature the method cache had not seen, or after `invokelatest`. | The cache-miss path built the argument tuple type and the cache entry inside the window. | The cache-miss path runs with region 0 installed, as inference and compilation do; a cache hit pays one compare. | `first_time_code_stays_in_region_0` in `regions_window.jl`. |
| B15 | `inst_datatype_inner` in `jltypes.c` | The same escape after `Vector{T}(undef, n)` with a run-time `T`, or a tuple of a fresh type combination, inside a window. | The cache-miss path made the new `DataType` and its parameter vector inside the window and stored them into the stock type cache. | The tail past the caches is `inst_datatype_new` and runs with region 0 installed; a cache hit pays nothing. | `first_time_code_stays_in_region_0`. |
| B16 | `OncePerThread`, `OncePerProcess` in `base/lock.jl`; the scheduler task of `wait` in `base/task.jl` | `REGION-ESCAPE: a Task of region 2 was stored into a GenericMemory of region 0` in about 7 % of the runs of `regions_window.jl` at `JULIA_NUM_THREADS=2,0`, at the `wait` of the `interleave` case; region 2 quarantined. | Julia 1.13 makes a thread's scheduler task lazily: the first `wait` that finds the local queue empty calls `get_sched_task()`, a `OncePerThread` that does `Task(wait_forever)` on behalf of the task that waits. When that task holds a window, the scheduler task, its `ThreadSynchronizer` and the table of the `OncePerThread` are made in the region, and the store into the per-thread table is an escape. The thread's sticky work queue (`Workqueues`, also a `OncePerThread`) is made the same way at the first sticky enqueue. Which thread runs the windowed task first decides whether its scheduler task exists yet, so the failure was a race of the thread configuration. | The slow path of every `OncePerProcess` and `OncePerThread` runs with the window suspended: a new pair `jl_gc_region_suspend`, `jl_gc_region_resume` (`gc-common.c`, exported for the `ccall`) installs region 0 and installs the window again, without closing it - the task stays pinned to its thread while the slow path parks on a lock, and a `finally` runs the resume on the exception path. The C brackets of B14, B15 and inference keep `jl_gc_region_set(0)`: they never park, and an exception past them leaves the window closed, which is coherent; a suspend on those sites would leave a window counted open with no way to close it after an exception. | `lazy_state_stays_in_region_0` in `regions_window.jl`; the `interleave` case at `2,0` is the original race, 8 of 120 runs before the fix. |

Three of the bugs (B10, B12, B13) are silent heap corruption in the
development runtime, in programs that keep a region object across a stock
collection, and two (B11, B16) quarantine a region for a reason the program
cannot see. None of them showed in the development scripts. B13 needs two
GC threads and a stock collection after a census; B12 needs a forced full
collection with a live region object; B10 needs a census over a region-0
vector in a last field. The development scripts did none of the three.

### Cleanups

| # | Where | Finding | Action |
| --- | --- | --- | --- |
| C1 | `overflow_pages`, `jl_gc_region_overflow` | Never incremented; the entry always returned 0. | Dropped. |
| C2 | `jl_gc_map_addr` | A debug walk of the page map from a corruption hunt; no caller. | Dropped. |
| C3 | `jl_gc_region_verify` | A debug walk of the page chains. | Kept: the tests call it after every reset. |
| C4 | The comment on `region_windows_open` | "A collection must not run while any window is open" was false after coexistence. | The stock collection parks the open windows; the comment says so. |
| C5 | The comment on the cooperative census | "Any `jl_gc_collect` defers while the counter is nonzero" was false. | The census is sound because its thread reaches no safepoint while the filter is set, and every other collector waits for it; the comment says so. |
| C6 | The documentation of `jl_gc_region_reset` | "Returns `UINT64_MAX`" was wrong, and the debug refusals were reported as "live references". | One return-code table in `gc-regions.h`. |
| C7 | Local `extern` declarations in `gc-common.c`, `gf.c`, `staticdata.c` | Ad hoc. | Moved to `gc-regions.h`. |
| C8 | "region prototype", "v1", "v2", "stage N" in the source | History in source. | Removed; the history is this document. |
| C9 | `jl_gc_region_reserve` | It prefaults the pool heap, not a region. | Renamed `jl_gc_heap_reserve`. |
| C10 | `jl_gc_region_add_finalizer` throws from a `NOTSAFEPOINT` caller | A cross-thread finalizer on a region object is an illegal program; the throw happens before the lock and before any list changes. | Kept; documented in the API and in a comment. |
| C11 | `finalize(o)` on a region object | A silent no-op. | Documented in the API. |
| C12 | The exception path of the region-0 wrappers in `gf.c` | An exception between `jl_gc_region_set(0)` and the restore leaves region 0 current. | Documented; the window state stays consistent, and the handler at the window boundary closes the window. |
| C13 | `GC_MAX_BLOCKS 4096` | Blocks past about 64 GB are not prefaulted, silently. | Documented. |
| C14 | Region pages never return to the OS | A property, not a bug. | Documented. |
| C15 | `escape_test.jl`, `stockgc_test.jl` | Printed ALL PASS but did not exit nonzero on a failure. | Every test exits nonzero on a failed check. |
| C16 | The `gf.c` wrappers, `if (saved != 0) jl_gc_region_set(saved)` | A refusal code from `jl_gc_region_set(0)` was fed back as a region number. | `if (saved > 0)`: only a real window is restored. |
| C17 | `gc-wb-stock.h`, the two C-side barrier hooks | They ignored `JL_NO_REGION_STORE_BARRIER`: a build with the define had the codegen half off and the C half on. | One macro `jl_gc_region_wb_check(parent, ptr)` for both hooks, empty under the define. |
| C18 | `jl_region_barrier_on` | The one region symbol without the `jl_gc_region_` prefix. | Renamed `jl_gc_region_barrier_on`. |
| C19 | `ctx_switch` in `task.c` | The park and install of the window were inline in the task code. | One call, `jl_gc_region_task_switch`, in `gc-regions.c`. |
| C20 | `contrib/memory-regions/regions.jl` | The Julia wrapper's comments named the wrong refusal codes for the census and the reset. | The comments name the codes of `gc-regions.h`. |

### Stock-path changes

Five changes touch paths a program without regions runs. Each has its own
commit in the series, with the reason in the message.

| # | Where | Change | Reason |
| --- | --- | --- | --- |
| S1 | `gc_defer_collection` | Re-arms `heap_target` when a collection is deferred. | Without it a disabled collector re-enters `jl_gc_collect` on every allocation; a `GC.enable(false)` loop allocates at full speed with it. A visible behavior change. |
| S2 | `work-stealing-queue.h`, `gc_ptr_queue_push/pop` | `FORCE_INLINE`. | The census filter moved the inliner's budget and the stock mark loop lost its inlining; the hot code is otherwise byte-identical. |
| S3 | `gc_setmark_pool` | `gc_region_corpse_report` on `NULL` page metadata. | Names the object that a bad reset dangled, on a path that already crashes. |
| S4 | `cgutils.cpp`, `emit_new_struct` | `need_wb = true` for boxed pointer children at construction. | The escape barrier needs the store checked; off under `JL_NO_REGION_STORE_BARRIER`. |
| S5 | `llvm-late-gc-lowering.cpp` | A flag-guarded call to `jl_gc_region_wb` after the generational barrier. | The escape barrier; off under the same define. |

### Pitfalls of the tests and the benchmarks

Facts that cost time during the tidy and that a reader who extends the tests
or the benchmarks meets again.

- The compiler removes an allocation that does not escape. An object a test
  needs in a region must escape: return it from a `@noinline` function or
  hand it to the runtime.
- The compiler inlines the finalizer of a non-escaping object at its last
  use, and no finalizer is registered. The first B8 test passed on nothing.
- A local `Ref` that never escapes is scalarized; its store has no write
  barrier, so the escape barrier never sees it.
- A closure is boxed where it is first passed as `Any`; a closure passed
  unboxed into a window is boxed inside the window, in the region.
- A `put!` into a `Channel` inside a window grows the channel's data vector
  (a stock array gets a region memory). The tests hand off with
  `Base.Event`, which allocates nothing on `notify`.
- `GC.gc(false)` is a request, not a guarantee: the heuristic can turn a
  young collection into a full pass.
- `println` to stdout is pipe-buffered; `jl_safe_printf` writes to stderr
  unbuffered. In a captured log their order is not the order of execution.
- A crash from a freed GC page lands wherever the page is next read: a
  crash in case N+1 can be the fault of case N.
- A store loop with one invariant child measures no barrier: the compiler
  hoists the whole barrier out of the loop.
- The barrier is armed at the first window of the process and stays armed.
  A disarmed number needs a process that never opens a window;
  `unit_costs.jl` runs a child process for it.
- Region 2 is a child of region 1 in the default chain, so a window on
  region 2 makes every reset of region 1 refuse with `ECHILD` until region 2
  resets. The first `alloc_region` row read 6.1 ns instead of 3.7 ns: the
  refused resets let region 1 grow, and the row measured page faults.
- The cost of a tight loop is quantized by code placement: the same loop
  ran at 1.37, 1.44, or 1.64 ns per store in one binary, and which level a
  process gets depends on what the JIT compiled before it. An A/B of two
  binaries on one copy of a loop compares placements. `unit_costs.jl`
  compiles eight copies of each tight loop and reports the minimum. The rows
  that spend their time in the runtime's C code have one placement per
  binary; a difference there needs the disassembly as a second witness.

### The measurements, redone

The tidy ran every measurement again on the flat tree, with
`results/run_all.sh`, and read every result as a reviewer before it went
into a table. The rule was: a number that disagrees with its claim is a
finding, and a finding is followed to its cause before the step continues.
Three kinds of finding came out: faults of the harness, claims the data did
not support, and drift against the numbers of the development branch.

**Faults of the harness.** None of them is a fault of the runtime; each one
put a wrong number into a table of the development branch, or would have.

| # | Where | Fault | Fix |
| --- | --- | --- | --- |
| H1 | `bench/gcbench.sh` | The suite prints `times = 0x…`; the script read the field as decimal, so every wall time was 0. | The parse reads both forms and `$((ns))` makes the row decimal. A run that prints no `times` field is reported as `FAILED` with the tail of its output and gets no row. |
| H2 | `bench/paced.jl`, `bench/yardstick.jl` | The result vectors were `Vector{Int64}(undef, n)`; the first touch of each of their huge pages fell inside a measured slot and cost about 200 µs. The four slot misses of the regions run were these faults, not the runtime. | `zeros`, which touches every page before the loop. The regions run misses no slot. |
| H3 | `bench/unit_costs.jl`, the design | One process opened a window to measure the window rows, and the barrier stays armed from the first window on. The `alloc_stock` and `construct_two` rows compared an armed process with vanilla, and the no-window cost was confounded with the armed cost. | A third run: the regions binary in a process that never opens a window. M2 has three columns. |
| H4 | `results/run_all.sh` | Each run overwrote `log/status.tsv`; a partial rerun lost the status of the rows it did not run. | Append. |
| H5 | `results/plot.py`, `plot_scaling` | The points were grouped by their full label, which carries the thread count, so one thread count matched and the axis had zero width. The plot had never been drawn. | Group by the name before the parenthesis. |
| H6 | `MEASUREMENTS.md` | Every table was typed from the logs by hand. | `results/tables.py` writes every table from the data files; a table lives between two markers. |
| H7 | `results/plot.py`, the throughput plot of M5 | The legend named the `autopool` row, which is the in-place handler under the stock collector with no region call, "region, one reset per event", and the `pooled` row, which opens a window per event, "hand-pooled, no allocation". The table of M5 was right; the plot said the opposite of it. | The legend names each row for what `census.jl` runs. Every plot was rendered and read against its data before it went in; the same pass found labels that overlapped or ran off the canvas, and markers that hid one another where two values coincide. |

**Claims the data did not support.** Five claims of the development branch
changed.

- *M2, the cost when unused.* The old claim was "one predicted branch per
  store". The three-column measurement gives the no-window costs against
  vanilla: +0.085 ns per pointer store, +0.28 ns per pool allocation,
  +1.05 ns per object constructed with two pointer fields, and +1.2 % on the
  stock mark. The claim now names them: small, not zero. The construction
  cost is the largest; the flag check is about a quarter of it, the rest is
  the generational barrier that vanilla omits at construction (S4).
- *M5, the throughput.* The old claim was that a census-paced region loop
  keeps the throughput of the stock loop. The `batch` rows run no census,
  and the `pooled` row (a window and a reset per event, a scoped collection
  every 100 000 events) is slower than the stock in-place handler at B = 1
  with light scratch, faster at B ≥ 100. The claim says that now.
- *M12, thread scaling.* The old claim said the region model scales where
  the stock collector does not. Both scale. The region model is faster at
  two threads and more on demonstrator D, where the stock side collects;
  equal at one thread; equal on demonstrator B, which collects little.
- *M3, the residual tail.* A run with zero collections still has events
  over 100 µs, and its maximum moves between runs (34 µs, 165 µs). The
  cause is the page fault of the machine on a fresh huge page; the scripts
  of M3 take no heap reserve. M4 takes the reserve and counts the faults:
  zero. The prose of M3 says which columns carry the claim.
- *The counters.* `Base.gc_live_bytes()` grows by every byte a region
  allocates and a reset never subtracts it: the stock sweep skips region
  pages, and a reset frees pages, not bytes. The endurance row read the
  counter as a leak. The devdoc has a section "Counters" now, and the row
  is named "allocated through the region".

**Drift.** The numbers of the development branch (its `MEASUREMENTS.md`,
2026-09-01 to 2026-09-03) against the flat tree. A change inside the spread
of the rounds is noise; every change beyond that has its cause named.

| Row | Development branch | Flat tree | Cause |
| --- | --- | --- | --- |
| M1 serial: append, tree, strings, pollard, single_ref, many_refs | 1.01, 1.00, 1.01, 1.06, 0.98, 0.92 | 1.01, 1.03, 1.01, 1.01, 0.96, 0.92 | Inside the spread. `many_refs` is S1 in both. |
| M1 parallel: mergesort, mm, issue-52937 | 0.97, 1.06, parity | 1.00, 1.02, 1.01 | Inside the spread. |
| M2 armed store | 1.49 ns | 1.37 ns | Placement; the row is the minimum over eight copies now. |
| M2 disarmed store | ~0.41 ns | 0.41 ns | Same. |
| M2 window pair, switch pair | 10.4 ns, 5.2 ns | 10.5 ns, 5.1 ns | Same. |
| M2 reset | ~21 ns | 30.0 ns | The new row times one call between two clock reads, and the pair of reads costs 10 ns on this host; the row is an upper bound. In the same method a reset after one `Ref` reads 20 ns, and a loop of window, one allocation, and reset runs at 24.5 ns per iteration, of which the window pair is 10.5 ns. The old harness is not in the flat tree. |
| M2 construction, two pointer fields | +1.4 ns (an armed process against vanilla) | +1.05 ns, no window; +3.5 ns, armed | H3: the old row was the armed number on one copy of the loop. |
| M3 `tail regions` maximum | 9.9 µs | 165 µs (34 µs in another run) | The machine's page fault; zero collections in both. See M3. |
| M5 census, cooperative | ~2–3 µs + ~3.3 ns × K | 2.2 µs at K = 300, 276 µs at K = 100 000 | The same law, about 2.7 ns × K. |
| M6 paced, slot misses baseline / regions | 20 / 0 | 122 / 0 | The baseline runs with `--heap-size-hint=128M` now and collects twice; H2 for the regions run. |
| M6 endurance, 30 minutes: RSS first / last sample, misses, bytes per event | 301.7 / 301.7 MB, 0, 29.3 | 303.6 / 303.6 MB, 0, 29.3 | Same. The row that read the live-heap counter as a leak is named "allocated through the region" now. |
| M8 showcase tree, collections stock / regions | 6 / 0 | 6 / 0 | Same. |
| M9 growth bound, pages disarmed / armed | 10 089 / 63 | 10 089 / 63 | Same. |
| M10 demonstrator C, largest point | 1.63× | 1.98× | Four threads on cores that are not isolated; the stock side's collection count decides the wall time and moves between runs. |
| M10 demonstrator D, largest point | 1.39× | 1.19× | Same. |

## Deferred

Ideas the tidy did not build. None of them is needed for the runtime to be
correct under its documented rules.

- **A faster dedup of tasks in the census.** The record of tasks met
  outside the region is a hash table now; clearing the marks from
  `live_tasks` first would make the record unnecessary.
- **`finalize(o)` on a region object.** A hook in `jl_finalize_th` would run
  the region-list entry; today the call is a documented no-op.
- **A reset that sees a parked task's window.** A per-heap reset of region n
  does not check for a parked task of the same thread that holds a window on
  n; that task's stack references dangle after the reset. Detection needs a
  per-region count of open windows. The rule stands: close every window on a
  region before its reset.
- **The `collect` and `reset` asymmetry.** `jl_gc_region_collect` and
  `_collect_coop` return `EINVAL` for a valid region never used on the heap,
  while `jl_gc_region_reset` returns 0 for it. Both are documented and the
  tests pin them. A census of an empty region could return 0. An open API
  question for the review.
- **The census marks a task's buffers.** The task scan calls
  `gc_setmark_buf_` on each task's exception stack and copy-stack buffer. The
  direction is safe: a set `has_marked` only makes the sweep walk the page,
  and a stale mark on a young buffer promotes it to old at worst. No fix.
- **A construction-only barrier intrinsic.** An object constructed with two
  pointer fields costs +1.05 ns on this branch in a process that never opens
  a window (M2, `construct_two`, 8.19 ns against 7.13 ns on vanilla). The
  flag checks are about 0.26 ns of it; the rest is the generational barrier,
  which a fresh object does not need. An intrinsic that emits the region
  check alone at construction would cut the cost to the flag checks.
- **A postorder subtree reset and a subtree census.** The two-level shape
  (a trunk and leaves) needs neither.
- **An in-process test of the image refusal.** `jl_create_system_image`
  refuses inside a window; a test needs a `--output-*` child process inside a
  window. Documented only.

One property looks like a bug and is not: the window itself makes a region
live on the heap, whatever it allocates. An empty window on region n blocks
`region_reset(n-1)` with `ECHILD` until n resets, because the window can
allocate later. Every test resets a region after its window for that reason.

## The audit of the entry points

The development runtime exported twenty region entries from `gc-stock.c` and
`gc-pages.c`, and three hooks. The tidy keeps eighteen entries and every
hook, and adds one exported pair for Base (B16). Every kept entry is used by
a test under `test/gc/` or by a program under `bench/` or `demo/`.

| Entry point | Fate | Reason |
| --- | --- | --- |
| `jl_gc_region_set` | keep | the window |
| `jl_gc_region_current` | keep | the query behind `staticdata.c`'s refusal and the tests of the window state |
| `jl_gc_region_reset` | keep | the reset |
| `jl_gc_region_reset_global` | keep | the trunk reset with the world stopped |
| `jl_gc_region_declare_parent` | keep | the tree |
| `jl_gc_region_parent_of` | keep | the tree query |
| `jl_gc_region_collect` | keep | the stop-the-world census |
| `jl_gc_region_collect_coop` | keep | the cooperative census |
| `jl_gc_region_census_threshold` | keep | the census the allocator triggers |
| `jl_gc_region_of` | keep | the region of an object |
| `jl_gc_region_pages` | keep | the page count a census bounds |
| `jl_gc_region_quarantined` | keep | the escape observable |
| `jl_gc_region_stat` | keep | the census phase breakdown; the benchmarks read it |
| `jl_gc_region_set_debug` | keep | the debug reset check |
| `jl_gc_region_check` | keep | the debug check alone |
| `jl_gc_region_verify` | keep | the page-chain consistency walk; the tests call it after every reset |
| `jl_gc_region_wb` | keep | the escape barrier the lowered write barrier calls |
| `jl_gc_region_reserve` | renamed `jl_gc_heap_reserve` | it prefaults the pool heap, not a region |
| `jl_gc_region_overflow` | dropped | `overflow_pages` was never incremented; no script read the entry |
| `jl_gc_map_addr` | dropped | a debug walk from a corruption hunt; undocumented; no caller |
| `jl_gc_region_add_finalizer` (hook) | keep | diverts a finalizer on a region object to the region's list |
| `jl_gc_region_track_malloced` (hook) | keep | tracks a memory with malloc'd data allocated in a region |
| `jl_gc_install_task_region` (hook) | renamed `jl_gc_region_install_task` | one prefix for the whole runtime |
| `jl_gc_region_task_switch` (inline) | new name | the park and install of the window at a task switch, in one place |
| `jl_gc_region_suspend`, `jl_gc_region_resume` | new (B16) | the bracket Base puts around its lazily initialized state; exported for the `ccall`, not part of the application API |
| `jl_gc_region_finalizers_begin/end` (inline) | new | B11: finalizers run with region 0 installed under the finalizer depth |
| `jl_gc_region_prepare_stock_collection` | keep | parks the windows before a stock collection |
| `jl_gc_region_clear_stock_marks` | new | B12: clears the marks on region pages after every pass |
| `jl_gc_region_finish_stock_collection` | keep, narrowed | installs the parked windows again; the mark clear moved out of it |
| `jl_gc_region_mark_finalizer_lists` | new | B2: the region finalizer lists are roots of the stock mark |
| `jl_gc_region_census_claim_task` | keep | the census dedup of tasks met outside the region (B1) |
| `jl_gc_region_census_open` | keep | the census the allocator triggers |
| `jl_gc_region_init`, `jl_gc_region_init_heap` | keep | process and per-heap initialization |

The stock-path changes that stay in `gc-stock.c` after the move of the
region code into `gc-regions.c`: the page tag fields, the `active_pools`
indirection in the small allocator and in `gc_reset_page`, the page tag and
the fresh-page reuse in `gc_add_page`, the census filter of the mark loops,
the region skip in `gc_sweep_pool_page`, the corpse report in
`gc_setmark_pool` (S3), the `WeakRef` refusal in `jl_gc_new_weakref_th`, the
init hooks, the three hooks in `_jl_gc_collect` and `jl_gc_collect`, the
`FORCE_INLINE` on the queue (S2), `gc_defer_collection` (S1), and two helpers
the census shares (`gc_queue_execution_roots`, `jl_gc_free_memory`).

Checked on 2026-09-04: the region diff of the flat tree against rc4 and the
region diff of the truth against rc3 differ only in lines that this table,
the cleanups, or the bugs name. `cgutils.cpp`, `julia_threads.h`, and
`work-stealing-queue.h` are identical in both diffs.

The scripts of the development tree that became tests, and did not survive
as files: `stage3_safety.jl` and `v2_regression.jl` (the regression
batteries) became the five `regions_*.jl` scripts; `stage4_trap.jl` (the
barrier trap, which passed when it exited 1) became the quarantine cases of
`regions_escape.jl`; `ctor_gap_demo.jl` became `ctor_gap_quarantines_region5`.

## The obsolete branches and their tags

The four development branches are not rewritten. This branch supersedes
them, so each one is renamed `obsolete/<name>`, and its tip at the start of
the tidy is the tag `obsolete/<name>-2026-09-03`, pushed; `git log <tag>`
shows the full record, with every plan under
`contrib/memory-regions/plan/done/`. The tag `gc-regions-flat` marks the
flat tree from which the commits of this branch were cut.

| Tag | Tip | Holds |
| --- | --- | --- |
| `obsolete/memory-regions-2026-09-03` | `2d249ce25b` | the chain runtime, the Julia face, the real-time measurements (plans 1 to 6) |
| `obsolete/region-maturation-2026-09-03` | `c0b8d4df4a` | soundness, coexistence, tasks, the inline fix, the refusals (plans 7, 8) |
| `obsolete/region-tree-2026-09-03` | `a2521fbf57` | declared parentage, sibling isolation, the census of the open region (plan 9) |
| `obsolete/region-demonstrators-2026-09-03` | `9915f3c7de` | demonstrators A to D and the tidy plan (plan 10); the truth of the tidy is its merge with `region-tree`, `e37c9c7cc4` |

## Vocabulary of the plans

Words the plans use that the devdoc does not define.

- **stage** — one testable increment of a plan; a different sequence in each
  plan.
- **the guards** — the stage-4 commit of the branch rebuild: the sweeper's
  tagged-page skip, the deferral of `jl_gc_collect` while a window is open,
  the region-0 pins of the compiler, and "born initialized", in one commit.
- **the batteries** — the regression scripts (`stage3_safety.jl`,
  `v2_regression.jl`) that had to read ALL PASS before a change was trusted.
  They are the five test scripts now.
- **the trap** — `stage4_trap.jl`: a store of a region-1 vector into a
  region-0 holder under the hooked compiler; it passed when it exited 1.
- **recording-class garbage, light garbage** — the two allocation classes
  of the real-world loop: about 1.7 KB and about 100 bytes per event.
- **no-census** — a regions-only run that resets each slice and never
  calls the census; memory traded for the absence of the census pause.
- **the matrix** — a table of timed runs across configurations and scales.
- **HIL** — hardware-in-the-loop, the simulator use case behind the
  prefault and the isolated core.
- **isolated core** — a CPU taken out of the scheduler domains
  (`isolcpus`, `nohz_full`, `rcu_nocbs`); the measurement environment from
  plan 5 on.
- **quiet lane** — a lightly loaded core for the demonstrators' sweeps, not
  the isolated core.
- **the honesty bar** — the rules of the demonstrators: the same allocation
  on both sides, the strongest stock alternative named, a bounded claim,
  zero quarantines.
