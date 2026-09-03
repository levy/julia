# The road to a real PR

The goal: the region allocator/collector as a Julia runtime feature with
no cost when unused, full benefit when used alone, and coexistence with
the stock collector. The obstacles and their ranking are in DESIGN.md
under "The road upstream"; this plan turns them into stages. Each stage
has an acceptance test; a stage that cannot meet it blocks the PR, not
the stage after it.

## Stage 0 - engage before code

- [ ] Post the upstream questions (README, "Questions for upstream")
      as a Discourse thread / issue, with the record's numbers and the
      one-region unification as the frame. The answers decide stage 5's
      packaging (gc-stock patch, GC-interface extension, or MMTk plan).
      Acceptance: a core developer names the acceptable packaging.

## Stage 1 - soundness prerequisites (independent of upstream)

- [ ] Per-task window state: `current_region`/`active_pools` move to the
      task, switched at yield points; a window survives migration.
      Acceptance: a task that yields inside a window and resumes on
      another thread allocates correctly; a stress test with @spawn.
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

## Stage 5 - packaging and the PR series

- [ ] Per stage-0's answer: gc-stock patches, a GC-interface extension,
      or an MMTk plan. Staged as the upstream questions already cut it:
      PR 1 the per-page owner tag and per-owner page chains; PR 2 the
      single-mutator collection entry; PR 3 regions on top, API no-oped
      behind a build flag.
- [ ] Every PR carries its measurements the way this branch does: the
      environment, the scripts, the logs, one run set.
