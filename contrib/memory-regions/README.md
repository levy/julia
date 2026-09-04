# Memory regions

A region is a numbered part of the pool heap that a program frees as one
act. A program opens a window on a region, allocates into it, closes the
window, and later resets the region: every object that the window allocated
is gone at once, with no mark and no sweep. An escape barrier keeps the rule
that no object in a region references an object in a younger region; a
census reclaims the dead cells of a region that must live on. The stock
collector runs as before, and a program that never opens a window pays one
predicted branch per store.

The design, the rules, and the API are in the devdoc,
`doc/src/devdocs/gc-regions.md`. This folder holds what a reader needs to
try the runtime, to measure it, and to know how it came to be.

## The documents

| Document | Holds |
| --- | --- |
| `doc/src/devdocs/gc-regions.md` | the model, the six rules, the barrier, the API with its return codes, the tree, the census, the limits, and one paragraph on cost. Present tense; describes what is. |
| `MEASUREMENTS.md` | every measurement: the claim, the script, the data file, the plot, and the numbers. Twelve rows, M1 to M12. |
| `HISTORY.md` | the ten plans in date order, the ideas that were tried and dropped, the bugs the tidy found and their tests, the deferred ideas, the audit of the entry points, and the backup tags. |
| this file | the folder map and the build. |

## The folder

| Path | Content |
| --- | --- |
| `regions.jl` | the Julia face of the runtime: `@with_region`, `region_reset`, the tree declarations, the census. Every benchmark and demonstrator includes it. |
| `bench/` | the benchmarks: the unit costs, the GCBenchmarks sweep, the event-loop models and their tails, the census, the growth bound, the region-native model against C++. `bench/README.md` lists each program and its command. |
| `demo/` | the demonstrators: four algorithms run twice, under regions and under the stock collector, with the two results side by side; and three showcases of wholesale death. `demo/README.md` lists each. |
| `tools/` | the discipline checker, which finds the stores that break the region rule before a program runs under regions; and the core isolation for the paced measurements. `tools/README.md` lists each. |
| `results/` | `run_all.sh` runs every measurement and writes `data/*.tsv`; `plot.py` draws `plots/*.svg` from the data files; `realworld.sh` is the matrix of the real-world loop. The logs go to `results/log/`, which git ignores. |

The tests of the runtime are not here. They are the five scripts
`test/gc/regions_*.jl`, run by `test/gc.jl` as part of the `gc` test set,
one process each; `test/gc/regions_api.jl` is the thin wrapper they share.

## The build

The runtime is part of the julia build. From the root of the repository:

```
make -j8
```

Two defines turn parts of the runtime off, for a build that measures what
each part costs:

| Define | Effect |
| --- | --- |
| `JL_NO_REGION_ALLOC` | the small allocator takes the stock pool directly; a window has no effect on where objects go. |
| `JL_NO_REGION_STORE_BARRIER` | the escape barrier is compiled out of the lowered write barrier and of the two C-side hooks. |

Pass a define through `CPPFLAGS` in `Make.user`, which `src/Makefile`
adds to every C and C++ compile of the runtime, for example
`CPPFLAGS += -DJL_NO_REGION_STORE_BARRIER`.

To run the tests of the runtime alone:

```
usr/bin/julia test/gc/regions_window.jl
usr/bin/julia test/gc/regions_escape.jl
usr/bin/julia test/gc/regions_lifetime.jl
usr/bin/julia -t4 test/gc/regions_census.jl
usr/bin/julia -t4 test/gc/regions_tree.jl
```

Each script prints its check count and exits 0, or prints `FAIL: <name>` and
exits 1 at the first failed check. `make test-gc` runs them with the rest of
the `gc` test set, each script at 1, 2, and 4 threads, with and without an
interactive thread, with and without the concurrent sweep.

To run every measurement, with a vanilla julia built at the base commit and
a checkout of GCBenchmarks:

```
VANILLA=/path/to/vanilla/usr/bin/julia GCBENCHMARKS=/path/to/GCBenchmarks \
    contrib/memory-regions/results/run_all.sh
python3 contrib/memory-regions/results/plot.py
```

`run_all.sh` takes about four and a half hours. It pins the single-thread
rows to one core (`CORE`, default 29) and the four-thread rows to a range
(`MTCORES`, default 24-27). A row that a step of the run skips is named in
`results/log/status.tsv`.

## The headline

Three claims, each with its measurement in `MEASUREMENTS.md`:

1. Unused, the runtime costs nothing that the GCBenchmarks can see (M1),
   and one predicted branch per store (M2).
2. Used alone, a reset frees a region in constant time, a window pair costs
   tens of nanoseconds, and the collector's tail leaves the per-event
   latency of an event loop (M3, M4, M6).
3. Used with the stock collector, the two coexist: a stock collection walks
   region objects and leaves them where they are, and a census reclaims the
   dead cells of a region that lives on (M5, M9). Where the discarded
   allocation per unit of work is large, the region model wins on wall time
   as well (M10).
