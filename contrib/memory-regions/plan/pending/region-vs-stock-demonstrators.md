# Two demonstrators: regions against the stock collector

The goal: two widely-known algorithms, written in Julia, where the
region-based runtime beats the stock collector on the same code. One is a
backtracking search (branch-and-bound / CSP), one is a parallel path
tracer. Each ships an A/B: the identical algorithm, run once with regions
and once with the stock collector, so the only variable is the memory
management.

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

## Stage C -- the write-up

- [ ] `SHOWCASE.md`: both demonstrators, their tables (wall / collections
      / GC time / max pause / RSS at three scales each), the vanilla
      cross-check, and the honest caveats from the bar above -- including
      the in-place baseline and the low-pressure regime where stock ties.
      The headline is the pair of curves: wall-time advantage rising with
      allocation pressure, and a max-pause advantage that holds flat
      across all of it.

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
