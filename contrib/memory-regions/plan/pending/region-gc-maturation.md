# Maturing the region collector

The goal: the region allocator/collector matured internally to the
point where it could stand as a Julia runtime feature - no cost when
unused, full benefit when used alone, coexistence with the stock
collector. The obstacles and their ranking are in DESIGN.md under "The
road upstream"; this plan turns them into stages. Each stage has an
acceptance test. No pull request is part of this plan: if one ever
happens, the user makes it manually.

## Stage 0 - internal only, for now

The user's direction (2026-09-03): nothing goes to the project pages -
no Discourse thread, no issue, no discussions. The work proceeds
internally through the stages below, and the packaging question is
decided by us when the work is ready: the working assumption is
gc-stock patches shaped so that a later move behind the GC interface or
into an MMTk plan stays cheap (the region state behind its own
functions, no new invariant leaking into code that does not test the
region tag).

## Stage 1 - soundness prerequisites (independent of upstream)

- [x] Per-task window state (task_window_test.jl: ALL PASS, batteries
      green). The task carries its region across switches (parked in
      ctx_switch, installed on arrival; the window count untouched - the
      window belongs to the task). An open window makes the task sticky,
      because a region's pages live in the thread heap; the stickiness it
      had returns at close. Design choice recorded: windows follow tasks,
      tasks with windows do not migrate.
- [x] Defined escape behavior (escape_test.jl: ALL PASS). The checked
      mode was chosen: a runtime flag armed at the first region_set;
      disarmed, every pointer store pays one well-predicted
      load-and-branch (emitted in the write-barrier lowering, and in the
      inline C barriers); armed, a cold call compares the two page tags,
      and an illegal store QUARANTINES the child's region - reset
      returns typemax-1, the censuses return -5, the memory is retained,
      and a one-time warning names the regions. The resizing Dict runs
      correctly and leaks exactly its Event tables. Two facts recorded:
      (a) the armed legal-store path costs ~9 ns of light-loop median
      (p50 31 -> 40 ns, 18.0 -> 15.7 M events/s) - the fast path is a
      later candidate for inline IR tag-compares instead of the call;
      (b) two honest gaps - the fresh-store elision can skip a barrier
      across a window open (region_set is not a safepoint), and even a
      blocking take! inside a window escapes through its wait-queue
      growth, which the task test now documents as expected output: the
      composability hazard, demonstrated.
- [x] The malloc'd-data hole (malloced_test.jl: ALL PASS, single- and
      multi-threaded). A memory with malloc'd data allocated inside a
      region goes to the region's own list, never the common one (whose
      stale entry once read recycled pages - the old corruption). The
      reset frees all of the region's data (RSS-bounded over 20 000
      32 KB churn cycles); the census frees the dead and keeps the live,
      filtered by mark before the page walk clears the bits. Found on
      the way, two enforcements the barrier delivered by itself: a
      region object stored into a module binding (the old soft rule "a
      global may not hold a region object", now with defined behavior),
      and a window store into a compiler Box - a captured local,
      reassigned, is boxed in region 0 at function entry, and the box
      store escapes. The warning now names both types, which is how the
      box was found; the composability hazards are not hypothetical,
      they are the first three things the barrier caught.
- [x] The finalizer story (finalizer_test.jl: ALL PASS; the stage-3
      battery's gate case rewritten to its successor). Per-region
      finalizer lists: registration on a region object goes to the
      region's list (cross-thread registration still errors, until
      stage 3); the reset runs them all on whole objects before it
      frees; the cooperative census runs the dead ones between its mark
      and its sweep, and marks the listed finalizer functions so a
      survivor's closure is not swept from under the list (a dead
      entry's function lives one census too long - slack, not
      unsoundness); the stop-the-world census refuses a region that has
      finalizers (-6) - running arbitrary code with the world stopped
      can deadlock, and the coop entry or the reset is the answer. A
      finalizer that resurrects its object is an escape, quarantined
      like any other.

Stage 1 stands: windows follow tasks, escapes are leaks with a named
warning, malloc'd data dies with its region, finalizers run at the
region's own boundaries. Six suites green on every item.

## Stage 2 - coexistence with no contract

- [x] Coexistence, landed simpler than designed (stockgc_test.jl: ALL
      PASS both modes; GC.gc(false)/(true) inside open windows and
      between them, with a census after - six clean probes under forced
      mid-loop collections). Not regions-as-roots: the stock mark walks
      region objects NORMALLY (exact liveness through them), a bracket
      around the collection installs region 0 on every stopped thread
      (the sweep prologue's cursor sync needs norm_pools) and afterwards
      clears the low header bits of every region page the mark touched -
      has_marked IS the card, so young collections stay proportional and
      the planned card barrier is unnecessary; an aligned freelist link
      survives the blind clear. The deferral guard is gone. Two repairs
      the tests forced: the census claims a task whatever its bits (a
      stock collection leaves tasks OLD-MARKED; a mark-based claim then
      never scanned the stack and the census freed the live set), and
      the restore puts back each task's exact prior bits - stripping
      old-marked to old-unmarked would break the remembered-set
      invariant the other way. The matrix re-measurement with regions
      and stock live together moves to stage 4's evidence.

## Stage 3 - multithreading

- [x] The census under tasks and threads, scoped by what the barrier
      already guarantees (parked_task_test.jl: ALL PASS both modes, three
      runs each; the single-thread case is the discriminating one). The
      real hole was same-thread parked tasks: a task with a closed window
      and region references on its stack was invisible to the
      caller-roots census - all three scanners (both census entries and
      the rule-5 check) now queue live_tasks through the repaired task
      claim; the stop-the-world forms walk every thread's list, the
      cooperative form the caller's. What needed NO code, argued in the
      comments in place: cross-thread references into a region and
      finalizer-held region references are both escapes - quarantined,
      impossible in a disciplined program - so cross-thread root scans
      and finalizer-list walks are not the census's business. The
      cooperative -4 stays the contract (the test retries like an engine
      would). The four-thread matrix and the endurance acceptance land
      with stage 4's evidence runs.

## Stage 4 - evidence (MATURATION.md holds the tables)

- [x] The GCBenchmarks serial set, vanilla v1.13.0-rc3 against this
      build with regions unused, interleaved on the isolated core: the
      four realistic benches within noise (append 1.01, strings 1.00,
      BST 1.04, pollard 1.05); the two big_arrays GC-stressors show the
      machinery's per-item cost (single_ref 1.08 mark - hoisted down from
      1.19; many_refs 1.24 alloc-fast-path indirection). NOT a suite-wide
      zero: honest residual on 100M-object microbenches, the reason the
      stock-only compile mode exists.
- [x] binary_tree and linked/list with a @with_region wrap
      (showcase_*.jl): 0.32 s/0 coll vs 0.47 s/31, and 0.42 s/0 coll vs
      2.19 s. Wholesale death, the shape the regions are for.
- [x] Load time unchanged (0.06 s), runtime library +0.8 %. 30-min
      endurance on the armed runtime: 0 misses, RSS flat.

## When the stages stand

The work ends at the evidence. Whether anything ever goes upstream, and
in what shape, is the user's manual decision outside this plan; the
working assumption that keeps the option open stays as in stage 0 - the
region state behind its own functions, no new invariant leaking into
code that does not test the region tag, and every stage carrying its
measurements the way this branch does: the environment, the scripts,
the logs, one run set.
