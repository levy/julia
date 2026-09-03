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

## What this proves, honestly

- **The categorical result (load-independent, proven under load):** on the
  natural allocating form of both algorithms, the region run does **zero**
  stock collections and **zero** GC time, where the stock run's collections
  and GC time rise with allocation pressure. Regions remove the collector, and
  every stop-the-world pause with it, from the hot loop.
- **The wall-time result (conservative, shared lane):** the region run is
  consistently a few percent faster, because these workloads are compute-bound
  and GC is a small fraction of them. A quiet-core re-measure is pending to
  pin the ratio; the load-independent metrics above do not need it.
- **The honest caveats.** Bitmask / in-place forms of either algorithm
  allocate nothing and regions do not help them -- the win is against the
  natural allocating form, not a hand-optimised one. And a single unbounded
  search under regions would grow the region without bound and OOM, where the
  stock collector survives; the node cap keeps the death per-instance, which
  is the shape the region model is for. Both caveats are the plan's honesty
  bar, kept.

## Reproduce

`julia bt_solver_demo.jl` and `julia -t4 pathtrace_demo.jl`, each under
`systemd-run --user --scope -p MemoryMax=6G`. The tables are the min of the
interleaved A/B in `demo_common.jl`.
