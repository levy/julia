# Regions against the stock collector: two demonstrators

Two widely-known algorithms in Julia, each run once with regions and once
with the stock collector on the **same code**, so the only variable is the
memory management. The plan is `plan/pending/region-vs-stock-demonstrators.md`;
this file is the result. Both run under a hard `MemoryMax` and a per-unit-of-
work cap, so a runaway search cannot OOM the machine.

## How to read the numbers

The trustworthy, **load-independent** metrics are the stock collection count
and the total GC time: both are deltas of `Base.gc_num` over the run,
intrinsic to the allocation pattern, and unaffected by other work on the
machine. Wall time is load-sensitive; the wall figures below were taken on the
shared functional lane while other agents were active, so they are the
conservative floor, not a quiet-core best. The categorical claim rests on the
load-independent metrics.

## Demonstrator A -- backtracking graph colouring (`bt_solver_demo.jl`)

A batch of independent random graphs, K-coloured by natural allocating
backtracking (a `Set` of used colours and a candidate `Vector` per search
node). Each instance's search runs in one region, reset when the instance
finishes; the answer copied out is a small `Int`. A node-visit cap bounds each
instance's search, so the region's peak stays one instance's working set --
the point where the stock collector would reclaim backtracked garbage
mid-search and the region would not. Hard instances (K=3, dense) hit the cap,
so each allocates a large but bounded amount; across thousands of instances
that is real pressure on the collector.

| scale | region coll. | stock coll. | region GC ms | stock GC ms | region wall | stock wall |
| --- | --- | --- | --- | --- | --- | --- |
| 1500 inst, n=30 | **0** | 11 | **0.0** | 5.6 | 99 ms | 103 ms |
| 3000 inst, n=32 | **0** | 23 | **0.0** | 11.6 | 209 ms | 218 ms |
| 5000 inst, n=34 | **0** | 41 | **0.0** | 20.1 | 375 ms | 390 ms |

Same answers from both runs, no region escape, peak RSS ~270 MB for both. The
region run does **zero** collections at every scale; the stock run's
collections and GC time grow with the batch. Wall time is ~1.04x in the
region's favour -- modest, because this search is compute-bound and GC is only
~5 % of it, which is exactly the GC time the region removes.

## Demonstrator B -- parallel path tracer (`pathtrace_demo.jl`)

A small path tracer (four spheres, Lambertian and metal, depth 8), one sibling
leaf per worker thread. Each pixel's samples allocate per-bounce hit records (a
mutable `Hit` per intersection, dynamic dispatch on an abstract `Material`);
the leaf resets after the pixel, and the surviving colour (an isbits `Vec3`) is
stored into the region-0 image. A per-pixel deterministic RNG makes the image
bit-identical across region and stock and across thread scheduling.

| scale | region coll. | stock coll. | region GC ms | stock GC ms | region wall | stock wall |
| --- | --- | --- | --- | --- | --- | --- |
| 8 spp | **0** | 0 | **0.0** | 0.0 | 6.0 ms | 5.7 ms |
| 24 spp | **0** | 2 | **0.0** | 0.3 | 16.8 ms | 17.0 ms |
| 64 spp | **0** | 7 | **0.0** | 0.8 | 44.0 ms | 44.7 ms |

Bit-identical image from both runs, no escape, peak RSS ~277 MB for both. The
sibling leaves let four threads reset per pixel with no coordination and mutual
isolation. Again the region run keeps the collector out entirely; the win
grows with the sample count.

## Demonstrator C -- optimistic concurrent persistent BST (`optimistic_bst_demo.jl`)

The allocation-bound case, and the one that wins on WALL time. Four threads
insert keys into ONE shared persistent tree; each attempt path-copies a new
version in its own sibling leaf and commits by a compare-and-swap on the root;
a lost attempt (validated by re-reading the root before it touches region 0)
resets its leaf, so its whole speculation is leaf garbage. The abort rate sits
near 300% (three retries per key at four threads). A tunable transaction body
adds the speculative allocation a real transaction does; sweeping it, at 80000
keys, on a quiet isolated lane:

| transaction work | region wall | stock wall | speedup | region GC | stock GC | stock coll. |
| --- | --- | --- | --- | --- | --- | --- |
| 0 (bare insert) | 66 ms | 29 ms | **0.44x** | 5.5 | 4.6 | 5 |
| 64 | 101 ms | 84 ms | **0.83x** | 6.1 | 23.0 | 16 |
| 256 | 181 ms | 266 ms | **1.47x** | 2.6 | 98.5 | 28 |
| 1024 | 494 ms | 807 ms | **1.63x** | 4.7 | 278.0 | 114 |

Same key set from both runs, no quarantine, aborts steady ~280-300 % across
the sweep. This is the honest crossover: with a bare insert the discarded
allocation per attempt is tiny and the region's window overhead (open, close,
and the O(depth) commit copy-out) dominates -- the region **loses, 0.44x**. As
the transaction body grows, the garbage a lost attempt discards grows with it;
the stock collector's GC time climbs from 4.6 ms to **278 ms** (5 to 114
collections) while the region's stays **flat at ~5 ms** (it resets the losers),
and the region **wins, up to 1.63x**, the advantage rising with the allocation.
This is the wall-time win the compute-bound pair could not give, and it appears
exactly where the model predicts: when aborted speculation is the dominant
allocation.

## What this proves, honestly

- **The categorical result (compute-bound A and B, load-independent):** on the
  natural allocating form of both, the region run does **zero** stock
  collections and **zero** GC time, where the stock run's collections and GC
  time rise with allocation pressure. Regions remove the collector, and every
  stop-the-world pause with it, from the hot loop. Wall time there is only a
  few percent better, because those workloads are compute-bound.
- **The wall-time result (allocation-bound C):** when aborted speculation is
  the dominant allocation, the region wins on wall time -- up to 1.63x here,
  and rising with the discarded allocation -- while its GC stays flat and the
  stock collector's climbs to 278 ms. The crossover is honest: with tiny
  per-attempt allocation the region's overhead makes it lose (0.44x), so the
  win is real only past the point where discarded garbage dominates.
- **The honest caveats.** Bitmask / in-place forms of either algorithm
  allocate nothing and regions do not help them -- the win is against the
  natural allocating form, not a hand-optimised one. And a single unbounded
  search under regions would grow the region without bound and OOM, where the
  stock collector survives; the node cap keeps the death per-instance, which
  is the shape the region model is for. Both caveats are the plan's honesty
  bar, kept.

  **Update:** the OOM hazard is now fixed on branch `region-tree` by the
  open-region census -- a region past a threshold reclaims its dead cells in
  place, so a computation with internal garbage degrades to a region-local
  mark-sweep instead of OOMing (region_census_bound_test.jl: 160x memory
  bound). The census bounds memory, not the time of an exponential search;
  the node cap here still bounds time, which the memory model does not.

## Reproduce

`julia bt_solver_demo.jl` and `julia -t4 pathtrace_demo.jl`, each under
`systemd-run --user --scope -p MemoryMax=6G`. The tables are the min of the
interleaved A/B in `demo_common.jl`.
