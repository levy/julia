# Demonstrators: regions against the stock collector

The goal: widely-known algorithms, written in Julia, where the region-based
runtime beats the stock collector on the same code. Each ships an A/B: the
identical algorithm, run once with regions and once with the stock
collector, so the only variable is the memory management.

Two families:

- **Compute-bound (A, B): a backtracking search and a parallel path
  tracer.** These win CATEGORICALLY -- zero collections, zero GC time, no
  stop-the-world pauses -- but only a few percent on wall time, because GC
  is a small fraction of a compute-bound run. Done; see `SHOWCASE.md`.
- **Allocation-bound (C, D): optimistic concurrency with path-copying.**
  Threads build alternative versions up to the root, one commits by a
  compare-and-swap, the rest discard their paths and retry. Under
  contention most paths are discarded -- pure allocation garbage -- so the
  region's O(1) reset of a lost attempt beats the collector's trace-and-
  free, and the win should show on WALL time, not just pauses. This is the
  shape the region tree is for, and the target of C and D below.

## The honesty bar (read first)

A "regions are faster than the GC" claim is worthless if the benchmark is
rigged. The plan holds itself to these rules, and the result states them.

1. **Apples to apples.** The region run and the stock run execute the same
   allocation pattern -- the same objects, the same counts. The region run
   adds `region_set`/`region_reset`; the stock run relies on `GC.gc`.
   Nothing else differs.
2. **Name the strongest stock alternative.** A skeptic says "just
   preallocate / use in-place buffers / use bitmasks." That is true where
   it applies, and it is the reason both demonstrators use the *natural
   allocating form* of an algorithm whose per-phase working set is
   irregular and hard to preallocate (variable candidate sets; variable
   bounce depth). The result reports the in-place baseline too, where one
   exists, and does not hide it.
3. **The claim is bounded.** The honest hypothesis is not "regions beat
   all stock code always." It is: for the natural allocating form, the
   region run is (a) faster in wall time once allocation pressure is high
   enough that stock GC time is a real fraction of the run, and (b) lower
   in maximum pause at every scale, because the transients never enter a
   stop-the-world collection. Both parts are measured; a regime where
   stock ties or wins (low pressure) is reported, not omitted.
4. **The discipline must hold with no quarantine.** Each demonstrator
   asserts zero region escapes across its run -- the win is real only if
   the program obeys the young->old rule, which the barrier checks.

## Methodology (both demonstrators)

- Binaries: this tree build (regions) as the region run; the SAME binary
  with regions unused as the stock run (so the runtime is identical and
  only the region calls differ), plus the vanilla build as a cross-check
  that the stock path is not itself a regression.
- Pinning and interleaving: the build lane for functional runs; timed A/B
  interleaved A/B/A/B on the isolated core, min of five, per the machine
  discipline in this repo.
- Metrics, per run, from `Base.gc_num()` and `/proc/self/stat`:
  wall time, stock collection count, total GC time, **maximum pause**
  (the tail number that matters most), and peak RSS.
- Scales: run each demonstrator at three allocation-pressure levels (small
  / medium / large working set) to show the wall-time win grows with
  pressure and the pause win is categorical.
- Every number lands in `SHOWCASE.md` with the script that produced it.

## Demonstrator A -- backtracking search (`bt_solver_demo.jl`)

- [ ] **The algorithm.** A backtracking constraint solver in its natural
      allocating form: graph K-colouring or Latin-square/Sudoku, with the
      per-node working set as allocated objects (candidate/domain sets as
      `Vector`/`Set`, a copied partial assignment per branch). This is the
      idiomatic readable form and the form a non-expert writes -- not the
      bitmask form (which allocates nothing and where regions rightly do
      not help; the result says so).
- [ ] **The region mapping.** A batch of independent instances; each
      instance's solve runs in one region, reset when the instance
      finishes. The solution (a colouring, or UNSAT) is copied out to
      region 0 as a small result. Parallel workers each take a sibling
      leaf (the tree), so the batch runs concurrently with per-instance
      resets and no cross-worker interference. Deep recursion inside one
      instance stays in that instance's one region -- the region is reset
      between instances, not between frames, so recursion depth is not
      bounded by `JL_GC_MAX_REGIONS`.
- [ ] **The A/B and acceptance.** Region run vs stock run on the same
      batch, three scales (instance count / board size). Accept when: the
      region run does far fewer stock collections (ideally zero on the
      transients), its maximum pause is lower at every scale, and its wall
      time is lower at the medium and large scales; zero quarantines
      throughout; identical solutions from both runs.

## Demonstrator B -- parallel path tracer (`pathtrace_demo.jl`)

- [ ] **The algorithm.** A small path tracer: a handful of spheres,
      Lambertian and mirror materials, N samples per pixel, bounded
      bounce depth. Its natural form allocates per bounce (ray, hit
      record, scattered ray) -- variable in count with bounce depth, so
      not trivially preallocated.
- [ ] **The region mapping.** Embarrassingly parallel: one sibling leaf
      per worker thread. Each pixel (or each sample) allocates its bounce
      transients in the worker's leaf and resets the leaf when the
      sample finishes; the surviving output is one small colour added to
      the image buffer in region 0 (a region-0-valued store, legal). This
      reuses exactly the sibling-leaf machinery `showcase_tree.jl`
      already exercises, at a real workload.
- [ ] **The A/B and acceptance.** Region run vs stock run rendering the
      same image at three sample counts. Accept when: the region run
      keeps the collector out of the render loop (zero or near-zero
      collections), its maximum pause is lower at every sample count, and
      its wall time is lower at the medium and large sample counts; the
      two runs produce a bit-identical image; zero quarantines.

## The allocation-bound pair (C and D)

Demonstrators A and B are compute-bound: they win categorically on
collections and pauses, but only a few percent on wall time, because GC is
a small fraction of a compute-bound run. The pair below is ALLOCATION-bound
by construction -- most of the work IS allocation that dies -- so the
wall-time win should be real, not marginal. Both are the same shape the
region tree is for: a shared structure, per-thread speculation that mostly
dies, a winner that commits, the losers that reset, repeat. This is
optimistic concurrency with path-copying: threads build alternative
versions up to the root, one commits by a compare-and-swap on the root, the
rest discard their paths and retry. Under contention most paths are
discarded -- pure allocation garbage whose volume is (abort rate x path
length x threads), which can dwarf the useful work.

The region mapping is exact: the shared persistent structure is region 0
(or the trunk); each worker path-copies in its OWN sibling leaf (mutually
isolated, so one speculation cannot corrupt another -- enforced, not
assumed); the winner copies its winning path into region 0 and CAS-commits
the root (the O(depth) copy-at-the-boundary the design already charges);
the losers reset their leaves (O(1) wholesale death). A speculative node
pointing DOWN into the unchanged shared subtree is leaf -> region-0
(young -> old): legal. Only the committed path crosses into region 0, by an
explicit copy -- the one place the discipline says to copy.

The fair stock baseline is the SAME persistent path-copying algorithm under
the stock collector: identical allocation, only the abort reclamation
differs (stock traces and frees the discarded paths; the region resets
them). Apples to apples, as the bar demands. A mutable in-place concurrent
tree is a DIFFERENT algorithm (it gives up the persistent snapshot and
needs locks or fine-grained CAS); the write-up names it as the other
baseline but does not pretend the region version competes with it.

## Demonstrator C -- optimistic concurrent persistent BST (`optimistic_bst_demo.jl`)

- [ ] **The algorithm.** N worker threads insert keys into a shared
      persistent binary search tree (or HAMT). Each insert reads the
      shared root, path-copies from the touched leaf to a new root
      (O(depth) new nodes -- trivial per-node compute, so allocation
      dominates), then CAS-commits the root old -> new; a lost CAS discards
      the path and retries. Deep tree + high contention makes it strongly
      allocation-bound.
- [ ] **The region mapping.** The shared tree in region 0; each worker's
      speculative path in its own sibling leaf; the winner copies its path
      into region 0 before the CAS; the losers reset. The census safety
      valve (branch region-tree) is NOT needed here -- each attempt is
      short and resets, so death is per-attempt, bounded.
- [ ] **The A/B and acceptance.** Region run vs stock run, the same
      persistent algorithm, three contention levels (thread count /
      key-space overlap) and two tree depths. Accept when: the region run
      does far fewer collections and lower GC time at every point; its
      maximum pause is lower everywhere; and -- the point of this
      demonstrator -- its WALL time is lower and the advantage RISES with
      the abort rate. The final trees from both runs are identical; zero
      quarantines. Report the abort rate alongside each row, since it is
      the independent variable that drives the win.

## Demonstrator D -- Delaunay mesh refinement (`dmr_demo.jl`)

- [ ] **The algorithm.** The canonical irregular-parallel benchmark
      (Galois / Lonestar). A shared triangle mesh; workers repeatedly pick
      a "bad" triangle, compute its cavity, and retriangulate it --
      allocating new triangles and vertices -- then commit if the cavity
      did not overlap another worker's, else abort and discard the new
      triangles. Aborted cavities are pure allocation garbage; the mesh is
      the shared trunk. Heavily allocation-bound (object creation per
      cavity), and famous, so it answers "a real algorithm, not a toy."
- [ ] **The region mapping.** The mesh in region 0; each worker's
      speculative cavity retriangulation in its own leaf; a committed
      cavity's new triangles are copied into region 0 and spliced; an
      aborted cavity resets its leaf. Conflict detection is the
      application's (a lock per touched triangle, or a version check); the
      region model handles only the memory of the aborted work.
- [ ] **The A/B and acceptance.** Region run vs stock run of the same
      optimistic refinement, three mesh sizes / bad-triangle densities.
      Accept when the region run wins on collections, GC time, maximum
      pause, AND wall time, with the wall advantage rising as the abort
      rate rises. Both runs converge to a valid Delaunay mesh with the same
      triangle count; zero quarantines. This is the heavyweight; C is the
      clean minimal one, and D is optional if C already shows the wall win.

## Stage C -- the write-up

- [x] `SHOWCASE.md` holds A and B: their tables (wall / collections / GC
      time / RSS at three scales each) and the honest caveats -- the
      categorical collection/pause win, the modest compute-bound wall win,
      the in-place-code and OOM caveats.
- [ ] Extend `SHOWCASE.md` with C (and D if built): the allocation-bound
      tables with the ABORT RATE as the independent variable, and the
      headline this pair is for -- a wall-time advantage that RISES with
      the abort rate, next to the pause advantage that holds flat. This is
      the wall-time proof the compute-bound pair could not give.

## Risks and honest failure modes

- **Low pressure ties.** At small working sets the stock collector barely
  runs and the region calls are pure overhead; the region run may tie or
  lose there. Expected, reported, and the reason the scales sweep exists.
- **In-place code wins.** If either algorithm is rewritten allocation-free
  (bitmask solver, preallocated ray stack), regions have nothing to
  reclaim. The result names this and frames the claim against the natural
  allocating form, not against a hand-optimised one.
- **The escape barrier fires.** If the natural code stores a transient
  into the image buffer or the result set the wrong way (a younger object
  into region 0), the barrier quarantines and the demonstrator fails
  loudly -- which is the barrier doing its job, and a signal to fix the
  code's discipline, not to weaken the barrier.
- **Wall-time parity with a pause win.** It is possible a demonstrator
  matches stock on wall time but wins decisively on maximum pause. That is
  still a real result (the real-time story), and the plan accepts it as
  such rather than forcing a throughput win that is not there.
