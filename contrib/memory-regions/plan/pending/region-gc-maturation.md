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
- [ ] Defined escape behavior: a store that violates the rule must at
      worst leak, never corrupt. Decide between promotion-on-escape and
      an always-on cheap checked mode (the page-tag compare is ~2-5 ns
      per reference store; measure a sampling variant too), guided by
      the barrier cost on the full benchmark suite.
      Acceptance: the resizing-Dict counterexample runs correctly with
      regions on; no benchmark regresses beyond the stated barrier cost.
- [ ] The malloc'd-data hole: the per-region malloc list (designed, not
      built), so a large array dying in a region frees with it.
      Acceptance: the corruption reproducer in the limits becomes a test
      that passes.
- [ ] The finalizer story: either per-region finalizer lists run at
      reset/census, or a documented, catchable refusal.

## Stage 2 - coexistence with no contract

- [ ] Regions-as-roots (DESIGN.md, "Coexistence"): the stock mark scans
      region cells as roots, touches no region header; remove the
      quiescence contract and the GC.gc deferral notes.
- [ ] Dirty cards on region pages, so the young collection scans only
      written region pages; measure the barrier branch.
      Acceptance: GC.gc(true) and GC.gc(false) at arbitrary points of
      the real-world loop, checksums correct, batteries pass; the sched
      column of the matrix re-measured with regions live.

## Stage 3 - multithreading

- [ ] The census under threads: a safepoint-integrated entry (the
      sanctioned "caller is the only mutator" shape from the upstream
      questions), task stacks via live_tasks, finalizer lists walked.
      Acceptance: the matrix on 4 threads, one region set per thread,
      0 corruption over the endurance run.

## Stage 4 - evidence

- [ ] The full GCBenchmarks suite on the region build with regions
      unused: no regression (the zero-cost claim, suite-wide).
- [ ] binary_tree and linked/list with a @with_region wrap: the
      wholesale-death showcase against the stock columns.
- [ ] Package load times and code size, before/after.

## When the stages stand

The work ends at the evidence. Whether anything ever goes upstream, and
in what shape, is the user's manual decision outside this plan; the
working assumption that keeps the option open stays as in stage 0 - the
region state behind its own functions, no new invariant leaking into
code that does not test the region tag, and every stage carrying its
measurements the way this branch does: the environment, the scripts,
the logs, one run set.
