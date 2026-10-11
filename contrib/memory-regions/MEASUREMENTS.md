# Measurements

Every number in this document was measured on 2026-10-10 on the master
line of this work: the tree of the pull request's tip `f3b83d5555`, the
series on master `b883b468f0` of 2026-09-24 plus the three independent
commits under it, the deferral fix, the heap reserve and a test fix. The release-1.13 line had its own set of
numbers; they are gone from this document, and the last section says where
the two lines differ.

Every number comes from a data file under [`results/data/`](results/data),
one directory per build: [`e1`](results/data/e1), [`checked`](results/data/checked),
[`trusted`](results/data/trusted), [`probe`](results/data/probe).
[`results/tables.py`](results/tables.py) writes every table below from those
files, a marker naming the directory it reads, and
[`results/plot.py`](results/plot.py) draws the plots under
[`results/plots/`](results/plots) from them, one directory per build too.
[`results/run_all.sh`](results/run_all.sh) runs the rows and writes the data,
with `JULIA`, `VANILLA`, `BASELINE_BIN` and `DATA` naming the builds and the
directory of a run; the logs go to `results/log/`, which git ignores. A number
in the prose repeats a number of a table.

## The five builds

| name | tree | flags | what it is |
| --- | --- | --- | --- |
| `master` | upstream master `b883b468f0` | none | stock Julia of that day |
| `base` | master plus the three independent commits | none | the deferral fix, `jl_gc_heap_reserve` and a test fix; the pull request's flag-less build compiles to this code |
| `checked` | the whole series | `WITH_GC_REGIONS=1` | the regions with their escape barrier: the default of the flag |
| `trusted` | the whole series | `WITH_GC_REGIONS=1 WITH_GC_REGION_BARRIER=0` | the regions without the barrier, for a program validated with it on |
| `probe` | the whole series | `WITH_GC_REGIONS=1 -DJL_NO_REGION_ALLOC` | the regions compiled but unusable: the allocator on the stock pools, the census filter folded, every window refused; a probe of what the rest of the region code costs, not a build anyone uses |

Each is installed with `make install` under `/var/tmp/gc-regions-evidence/`,
and [`results/text_sizes.sh`](results/text_sizes.sh) records the text of the
runtime library and of the system image of each.

## How a row is measured

A **cost row** is paired. One round runs each binary once, and the order of
the binaries turns over between the rounds, so a drift of the machine moves
both sides of a round together. The cell of a binary is the median of its
rounds. The cell of a comparison is the median of the per-round differences
or ratios, with a percentile bootstrap interval at 95 % beside it and, for a
difference, the p value of the sign test: the question ten rounds can answer
is whether the difference keeps its direction.
[`results/stats.py`](results/stats.py) computes all of it, seeded. The
latency rows are not paired and not averaged: a tail is a maximum and a set
of quantiles, and the document reports them as such.

The machine: one Linux x86-64 host of 32 CPUs and 61 GB, one NUMA node,
transparent huge pages `madvise`, idle for the whole run. The kernel command
line keeps CPUs 13 and 29, the two threads of one core, tickless and free of
RCU callbacks (`nohz_full=13,29`), and [`tools/hil_isolation.sh`](tools/hil_isolation.sh)
takes them out of the scheduler at run time through cgroup v2 (`sudo ... on`).
The **latency rows** (E1, M3, M4, M5 and M6) ran inside the partition,
pinned to CPU 29 in the real-time class (`SCHED_FIFO` 50), the driver beside
them in the normal class; the tick leaves the core there (211 interrupts a
second against 2,000 outside the partition, measured on 2026-09-23), and a
pure spin of five seconds has a worst gap of 2.1 µs. Every other row ran
outside the partition, the one-thread rows pinned to CPU 28, the multi-
thread rows on CPUs 24 to 28, 30 and 31, and the collector rows M13 and M14
on the 30 CPUs outside 13 and 29, so their largest thread count is 30 where
the release-1.13 line had 32. Every row ran under a timeout and pinned; the
cost rows also under a memory cap in a systemd scope, the latency rows
without one, inside the partition's own cgroup. `data/<run>/context.tsv` records the date, the
commit, the host, the CPU, the kernel and the cores of each run.

## E1 — The two independent commits

The first two commits of the series are stock-collector changes that the
measured loops need, and they are measured on their own: `master` against
`base`, the build that differs from it by those two commits alone.

**The deferral fix.** With the collector disabled and the heap past its
target, master enters the collection entry at every allocation and defers
there; base raises the target once and returns to the fast path.
[`bench/deferral.jl`](bench/deferral.jl) allocates a million small objects
per block with the collector disabled, sixty blocks, and reports the median
nanoseconds per allocation over the second half; both builds defer 480 MB
in every run.

<!-- table E1-deferral run=e1 -->
|  | master | base (the fix) | base / master [95 %] | rounds |
| --- | --- | --- | --- | --- |
| ns per allocation, past the target | 9.32 [9.3, 9.35] | 4.07 [4.05, 4.07] | 0.436 [0.433, 0.438] | 10 |
<!-- /table -->

**The heap reserve.** `jl_gc_heap_reserve(bytes)` maps and prefaults pool
pages before a loop, for a loop that then keeps its pages, which is the
region loop of M6. [`bench/reserve_growth.jl`](bench/reserve_growth.jl)
grows the pool heap by 110 MB of small objects that stay alive and counts
the minor faults of the process while it grows: without the reserve every
fresh page faults at its first touch, with the reserve the growth faults 166
times, and master, which has no reserve, faults as base without one. The
faults of the paced loops of M6 do not move with the reserve, on the stock
loop or on the region loop: they are faults of the memory outside the pools
that the loop's allocations take and give back, not of pool pages, so that
column says nothing about the reserve and the paced tables do not carry it.

<!-- table E1-reserve-growth run=e1 -->
| run | mapped by the reserve (MB) | page faults while the heap grows | live heap after (MB) |
| --- | --- | --- | --- |
| base, no reserve | 0 | 19,575 | 111 |
| base, 512 MB reserved | 536 | 166 | 111 |
| master, no reserve | 0 | 19,561 | 111 |
<!-- /table -->

## E2 — The cost when the regions are built and unused

**Claim.** A program that never opens a window pays, with the barrier
built, one load and one branch at every managed pointer store, a longer
allocation path, the census filter in the mark, and a larger system image;
without the barrier the store costs nothing and the image grows a quarter
of that. The `probe` build, which keeps the region code but takes the allocator
and the filter out, says which part of the rest costs what.

**Text.** The system image grows 7.9 % with the barrier built and 1.9 %
without it; the runtime library 2.1 % and 0.86 %. The barrier's guard sits
at every barrier site of the compiled code, and it is three quarters of
the growth.

<!-- table E2-text -->
| build | libjulia-internal text (bytes) | against base | sys.so text (bytes) | against base |
| --- | --- | --- | --- | --- |
| master | 2,752,636 | -0.01 % | 24,288,857 | +0.00 % |
| base | 2,752,853 | +0.00 % | 24,288,361 | +0.00 % |
| checked | 2,809,200 | +2.05 % | 26,208,021 | +7.90 % |
| trusted | 2,776,411 | +0.86 % | 24,755,921 | +1.93 % |
| probe | 2,807,288 | +1.98 % | 26,210,213 | +7.91 % |
<!-- /table -->

**The unit costs, attributed.** Each cell is the paired difference "the
region build with no window open minus base", from ten rounds of
[`bench/unit_costs.jl`](bench/unit_costs.jl) on each of the three region
builds. The store costs 0.044 ns with the barrier and nothing without it,
so the store's cost is the guard alone. A pool allocation costs 0.16 ns
with everything built, 0.12 without the barrier and 0.09 in the probe,
whose allocator is base's, so the allocator path, one load and one add
where base adds a constant, is a few hundredths of a nanosecond and the
region code around an allocation the rest. The serial mark costs 1.1 to
1.2 ms of 67 with the regions usable and nothing in the probe, so its
cost is the census filter in the claim.

<!-- table E2-unit-attribution -->
| cost | unit | regions built, barrier built − base | regions built, no barrier − base | regions built, allocator and filter off − base |
| --- | --- | --- | --- | --- |
| store_disarmed | ns/store | 0.0436 [0.0407, 0.048], sign 0.002 | -0.00015 [-0.0011, 0.00105], sign 0.75 | 0.0419 [0.0392, 0.0452], sign 0.002 |
| alloc_stock | ns/object | 0.163 [0.154, 0.178], sign 0.002 | 0.117 [0.104, 0.127], sign 0.021 | 0.0935 [0.091, 0.103], sign 0.002 |
| construct_two | ns/object | 0.434 [0.371, 0.527], sign 0.002 | 0.33 [0.29, 0.373], sign 0.002 | 0.22 [0.15, 0.519], sign 0.002 |
| box_twin | ns/object | 0.336 [0.319, 0.412], sign 0.002 | 0.121 [0.076, 0.161], sign 0.002 | 0.353 [0.272, 0.38], sign 0.002 |
| stock_mark | ms/collection | 1.12 [0.8, 1.61], sign 0.002 | 1.19 [0.8, 1.49], sign 0.021 | -0.05 [-0.295, 0.54], sign 1 |
<!-- /table -->

The full table of `checked`, with the rows of a program that uses regions
(the `regions` column) beside the two stock columns:

<!-- table M2 run=checked -->
| cost | unit | vanilla | regions, no window | regions | no window − vanilla [95 %] | rounds |
| --- | --- | --- | --- | --- | --- | --- |
| store_disarmed | ns/store | 0.3335 [0.3333, 0.3367] | 0.3775 [0.3761, 0.3818] | 0.376 [0.3751, 0.3791] | 0.0436 [0.0407, 0.048], sign 0.002 | 10 |
| store_armed | ns/store | — | — | 1.432 [1.431, 1.433] | — | 10 |
| store_armed_const | ns/store | — | — | 0.1561 [0.1561, 0.1562] | — | 10 |
| store_region | ns/store | — | — | 2.075 [2.071, 2.081] | — | 10 |
| window_pair | ns/pair | — | — | 11.46 [11.46, 11.47] | — | 10 |
| switch_pair | ns/pair | — | — | 5.915 [5.913, 5.919] | — | 10 |
| construct_two | ns/object | 7.223 [7.208, 7.253] | 7.652 [7.604, 7.746] | 9.76 [9.731, 9.825] | 0.434 [0.371, 0.527], sign 0.002 | 10 |
| construct_shared | ns/object | 3.458 [3.438, 3.488] | 3.72 [3.704, 3.757] | 6.129 [6.093, 6.146] | 0.271 [0.238, 0.294], sign 0.002 | 10 |
| box_twin | ns/object | 3.784 [3.757, 3.837] | 4.13 [4.093, 4.201] | 6.1 [6.06, 6.143] | 0.336 [0.319, 0.412], sign 0.002 | 10 |
| alloc_stock | ns/object | 2.029 [2.025, 2.037] | 2.193 [2.189, 2.201] | 3.279 [3.271, 3.299] | 0.163 [0.154, 0.178], sign 0.002 | 10 |
| finalizer_register | ns/object | 2.381 [2.352, 2.485] | 2.311 [2.288, 2.413] | 3.471 [3.335, 3.489] | -0.0605 [-0.117, 0.004], sign 0.34 | 10 |
| alloc_region | ns/object | — | — | 3.479 [3.467, 3.494] | — | 10 |
| reset_slice | ns/reset | — | — | 30 [30, 40] | — | 10 |
| stock_mark | ms/collection | 64.78 [64.43, 64.95] | 65.92 [65.41, 66.3] | 66.64 [66.48, 67.12] | 1.12 [0.8, 1.61], sign 0.002 | 10 |
<!-- /table -->

![M2 on checked](results/plots/checked/unit_costs.svg)

**The collector on the whole machine.** A full collection of the same
heap, regions against base, at 1 to 30 threads, ten paired rounds each
([`bench/parallel_gc.jl`](bench/parallel_gc.jl)). With the regions usable
the collection costs 1 to 2 % more at one thread and 7 % more at thirty,
with or without the barrier; the probe costs 3 % at thirty. So the growth
with the thread count is the census filter in the mark loop, 4 points at
thirty threads, and the collector's other checks, the corpse test at a
mark and the page test at a sweep, are the remaining 3.

<!-- table E2-parallel-attribution -->
| threads | regions built, barrier built / base [95 %] | regions built, no barrier / base [95 %] | regions built, allocator and filter off / base [95 %] |
| --- | --- | --- | --- |
| 1 | 1.01 [1.01, 1.02] | 1.02 [1.01, 1.02] | 0.993 [0.984, 0.997] |
| 4 | 1.02 [1.01, 1.02] | 1.02 [1.01, 1.02] | 0.999 [0.995, 1] |
| 8 | 1.03 [0.997, 1.06] | 1.03 [0.992, 1.06] | 0.984 [0.96, 1.01] |
| 16 | 1.03 [0.994, 1.05] | 1.03 [1.01, 1.05] | 1.02 [0.996, 1.06] |
| 30 | 1.07 [1.06, 1.09] | 1.07 [1.04, 1.09] | 1.03 [1.02, 1.05] |
<!-- /table -->

<!-- table M13 run=checked -->
| threads | vanilla (ms) | regions (ms) | regions / vanilla [95 %] | mark vanilla (ms) | mark regions (ms) | time to safepoint (µs) | rounds |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 39.3 [39.2, 39.9] | 39.9 [39.7, 40.4] | 1.01 [1.01, 1.02] | 35.4 [35.3, 35.8] | 36 [35.8, 36.4] | 4.41 [4.06, 4.85] | 10 |
| 4 | 56.3 [56.1, 56.5] | 57.3 [57.2, 57.4] | 1.02 [1.01, 1.02] | 48.6 [48.5, 48.8] | 49.5 [49.3, 49.5] | 6.57 [6.22, 7.32] | 10 |
| 8 | 58.8 [58.2, 61.7] | 61.2 [59.1, 63.1] | 1.03 [0.997, 1.06] | 48.6 [48.3, 51.5] | 50.5 [48.9, 52.4] | 7.39 [7.01, 7.99] | 10 |
| 16 | 66.5 [65.2, 68] | 67.9 [67.1, 69.7] | 1.03 [0.994, 1.05] | 50.3 [49.1, 51.8] | 51 [50, 52.4] | 8.02 [7.65, 8.25] | 10 |
| 30 | 79.3 [79.1, 80.3] | 85.6 [85, 86.1] | 1.07 [1.06, 1.09] | 55.8 [55.4, 56.4] | 60.5 [60.1, 61.1] | 8.14 [7.87, 8.41] | 10 |
<!-- /table -->

![M13 on checked](results/plots/checked/parallel_gc.svg)

**The GC benchmark suite.** Eleven benchmarks of
[GCBenchmarks](https://github.com/JuliaCI/GCBenchmarks), six on one thread
and five on four, ten paired rounds, base against each region build; the
cell is the ratio of the minima over the rounds
([`bench/gcbench.sh`](bench/gcbench.sh)). Three of the eleven abort under
the 16 GB cap on every binary alike, master's included, and have no row: the
mutable binary tree, the object array, and `append`, which ran on master
`c941fbc399` in September and now stops in the suite's own memory-pressure
callback on `b883b468f0` too. Six of the eight are within 1 % on the build
with the barrier; `many_refs`, which allocates large arrays of references,
is 2 % slower with the barrier, 3 % without it and 1 % in the probe;
`pollard` is 4 % slower with the barrier and 3 % without it and in the
probe. Five paired runs of pollard with the collector's counters, on core
28, name the gap: every binary does ten collections over the same allocation
volume within 4 KB; the region builds spend 12 of the 27 ms more in the
collector, in the mark and the sweep of the finalizer list that every BigInt
joins, and the rest in the mutator, 5.6 % more instructions and 3.9 % more
cycles, in the registration of the finalizer and in the counted malloc of
the limbs. The early return of the finalizer hook, the census filter as a
parameter and the inlining of the mark-bit functions were each built and
measured as the cause on 2026-09-24, and pollard did not move under any of
them.

<!-- table M1 run=checked -->
| benchmark | threads | vanilla (s) | regions (s) | regions / vanilla [95 %] | rounds |
| --- | --- | --- | --- | --- | --- |
| tree | 1 | 8.853 | 9.022 | 1.01 [0.995, 1.02] | 10 |
| strings | 1 | 18.520 | 18.537 | 0.996 [0.991, 1.01] | 10 |
| pollard | 1 | 0.661 | 0.688 | 1.04 [1.03, 1.05] | 10 |
| single_ref | 1 | 0.276 | 0.275 | 0.996 [0.99, 1] | 10 |
| many_refs | 1 | 1.728 | 1.769 | 1.02 [1.02, 1.03] | 10 |
| mergesort_parallel | 4 | 1.699 | 1.685 | 0.995 [0.981, 1] | 10 |
| mm_divide_and_conquer | 4 | 0.607 | 0.608 | 0.998 [0.958, 1.02] | 10 |
| issue-52937 | 4 | 9.542 | 9.595 | 1.01 [0.998, 1.01] | 10 |
<!-- /table -->

![M1 on checked](results/plots/checked/gcbench.svg)

<!-- table M1 run=trusted -->
| benchmark | threads | vanilla (s) | regions (s) | regions / vanilla [95 %] | rounds |
| --- | --- | --- | --- | --- | --- |
| tree | 1 | 8.983 | 9.090 | 1 [0.996, 1.02] | 10 |
| strings | 1 | 18.632 | 18.638 | 1 [0.992, 1.01] | 10 |
| pollard | 1 | 0.664 | 0.688 | 1.03 [1.03, 1.04] | 10 |
| single_ref | 1 | 0.273 | 0.275 | 1.01 [1, 1.02] | 10 |
| many_refs | 1 | 1.729 | 1.771 | 1.03 [1.02, 1.03] | 10 |
| mergesort_parallel | 4 | 1.711 | 1.721 | 1.01 [0.997, 1.02] | 10 |
| mm_divide_and_conquer | 4 | 0.604 | 0.603 | 0.993 [0.986, 1.02] | 10 |
| issue-52937 | 4 | 9.563 | 9.639 | 1.01 [1, 1.02] | 10 |
<!-- /table -->

<!-- table M1 run=probe -->
| benchmark | threads | vanilla (s) | regions (s) | regions / vanilla [95 %] | rounds |
| --- | --- | --- | --- | --- | --- |
| tree | 1 | 9.001 | 9.017 | 1 [0.994, 1.02] | 10 |
| strings | 1 | 18.438 | 18.566 | 1 [0.992, 1.01] | 10 |
| pollard | 1 | 0.662 | 0.686 | 1.03 [1.03, 1.04] | 10 |
| single_ref | 1 | 0.274 | 0.276 | 1.01 [1, 1.01] | 10 |
| many_refs | 1 | 1.731 | 1.737 | 1.01 [1, 1.01] | 10 |
| mergesort_parallel | 4 | 1.702 | 1.701 | 0.991 [0.974, 1.01] | 10 |
| mm_divide_and_conquer | 4 | 0.601 | 0.607 | 1.01 [0.996, 1.03] | 10 |
| issue-52937 | 4 | 9.544 | 9.585 | 1 [1, 1.01] | 10 |
<!-- /table -->

## E3 — What a program that uses regions pays

**Claim.** In a window, a store costs the tag compare when the barrier is
armed; a region allocation, a window pair and an unchecked reset cost a few
nanoseconds; a checked reset costs the stop of the world, and so grows with
the threads that run Julia code.

From the `regions` column of the unit costs above, on `checked`: a managed
store 1.43 ns armed against 0.38 disarmed; a region allocation 3.5 ns
against 3.3 for a stock one in the same process; a window pair 11.5 ns, a
task switch pair 5.9; an unchecked reset 30 ns whatever the region held; a
checked reset 27 µs on one thread. On `trusted` the same store costs
0.33 ns and a region allocation 2.0 ns, less than a stock allocation there.

**The reset against the other threads.** [`bench/reset_pause.jl`](bench/reset_pause.jl)
resets a small region two hundred times while the other threads run Julia
code, at 1 to 30 threads, ten rounds. The checked reset grows from 27 µs
alone to 105 µs against 29 workers, and its worst case at 30 threads is
3.5 ms, with a worker stalled up to 4.0 ms; the unchecked reset stays
between 60 and 130 ns. The worst worker stall of the unchecked row at 30
threads is the scheduler's, not a pause: 30 threads and their collector
threads share 30 CPUs there.

<!-- table M14 run=checked -->
| entry | threads | workers | caller median (µs) | caller max (µs) | worst worker stall (µs) | collections | rounds |
| --- | --- | --- | --- | --- | --- | --- | --- |
| checked | 1 | 0 | 27 [26.8, 27.1] | 38.3 [31.9, 42.9] | — | 0 | 10 |
| checked | 4 | 3 | 38.3 [35.5, 41] | 199 [162, 302] | 120 [98.7, 162] | 0 | 10 |
| checked | 8 | 7 | 42.4 [41, 46.1] | 292 [200, 391] | 136 [111, 1.67e+03] | 1 | 10 |
| checked | 16 | 15 | 67.9 [67.4, 69.1] | 259 [177, 895] | 401 [197, 804] | 0 | 10 |
| checked | 30 | 29 | 105 [103, 108] | 3.49e+03 [2.45e+03, 3.92e+03] | 3.96e+03 [3.24e+03, 4.55e+03] | 0 | 10 |
| unsafe | 1 | 0 | 0.06 [0.055, 0.075] | 0.13 [0.115, 0.216] | — | 0 | 10 |
| unsafe | 4 | 3 | 0.06 [0.06, 0.071] | 0.166 [0.14, 0.291] | 0 [0, 274] | 0 | 10 |
| unsafe | 8 | 7 | 0.0705 [0.0655, 0.08] | 0.911 [0.631, 1.25] | 22.2 [0, 1e+03] | 1 | 10 |
| unsafe | 16 | 15 | 0.0805 [0.0755, 0.1] | 0.881 [0.25, 1.75] | 0 [0, 517] | 0 | 10 |
| unsafe | 30 | 29 | 0.13 [0.11, 0.131] | 0.285 [0.27, 0.431] | 4e+03 [1.94e+03, 6.01e+03] | 0 | 10 |
<!-- /table -->

![M14 on checked](results/plots/checked/reset_pause.svg)

## E4 — What the regions buy

Every loop below ran twice, on `checked` and on `trusted`; the baseline
and stock rows ran on `base`. The loops use the unchecked reset, which is
the reset of a loop that has shown it leaves no reference behind; M14 above
says what the checked one would add.

### M3 — The tail

**Claim.** In a pooled event loop whose only garbage is the scratch of the
sink, the reset of the Event region after each event removes the collector
from the per-event latency.

[`bench/tail.jl`](bench/tail.jl) runs twenty million events; `baseline` is
the allocating model under the stock collector, `regions` the scratch model
with one unchecked reset per event; [`bench/yardstick.jl`](bench/yardstick.jl)
gives the two ends, an allocating loop and a loop with every allocation
removed by hand. With 512 MB reserved, on the isolated core:

<!-- table M3 run=checked -->
| script | variant | p50 (ns) | p99 (ns) | p99.9 (ns) | p99.99 (ns) | max (ns) | over 100 µs | collections | GC (ms) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| yardstick | alloc | 70 | 81 | 230 | 892 | 5,382,923 | 17 | 11 | 13.5 | 964 |
| yardstick | pooled | 61 | 71 | 90 | 601 | 163,869 | 1 | 0 | 0.0 | 886 |
| tail | baseline | 80 | 101 | 131 | 621 | 3,917,399 | 16 | 16 | 14.8 | 1,458 |
| tail | regions | 80 | 121 | 121 | 752 | 91,583 | 0 | 0 | 0.0 | 1,592 |
<!-- /table -->

![M3 on checked](results/plots/checked/tail.svg)

<!-- table M3 run=trusted -->
| script | variant | p50 (ns) | p99 (ns) | p99.9 (ns) | p99.99 (ns) | max (ns) | over 100 µs | collections | GC (ms) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| yardstick | alloc | 70 | 91 | 241 | 932 | 5,487,501 | 20 | 11 | 13.8 | 964 |
| yardstick | pooled | 70 | 80 | 90 | 581 | 154,862 | 1 | 0 | 0.0 | 886 |
| tail | baseline | 60 | 71 | 210 | 561 | 4,037,676 | 16 | 16 | 14.1 | 1,459 |
| tail | regions | 70 | 101 | 111 | 181 | 91,213 | 0 | 0 | 0.0 | 1,535 |
<!-- /table -->

![M3 on trusted](results/plots/trusted/tail.svg)

The stock loop's longest event is 3.9 to 4.0 ms, a collection; the region
loop's is 92 µs on `checked` and 91 on `trusted`, no event of twenty million
over 100 µs, and the pooled yardstick's, which allocates nothing, is 155 to
164, one event over. That maximum is the machine's, not the runtime's: a
loop that never touches the allocator meets it as the region loop does,
about once in twenty million events, three seconds of wall time, a stall of
the isolated core. A run with the event queue as a binary heap that never
reallocates, on 2026-09-24, read the same maximum in every row and ten
nanoseconds more per event, which put the queue out of the question.

### M4 — The real-world matrix

**Claim.** In an event loop that allocates per event, one window per slice
and one reset per slice, with a census at the slice boundary, give a lower
and flatter latency distribution than the stock collector, under its own
heuristics or under the program's schedule.

[`results/realworld.sh`](results/realworld.sh) runs five million events at
two garbage weights, W=200 words (a recording) and W=3, with the heap
reserved and prefaulted, memory locked, pinned and real-time on the isolated
core; it counts the page faults and the involuntary switches of the run,
and keeps the try with the fewest. Every configuration reads 0 faults and 0
switches. On `checked`:

<!-- table M4 run=checked -->
| class | mode | events/s | p50 (ns) | p99 (ns) | p99.99 (ns) | max (ns) | max, no preemption (ns) | stock collections | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| recording, W=200 | stock, own heuristics | 6.6 M | 80 | 391 | 661 | 3,323,681 | 3,323,681 | 324 | 1,831 |
| recording, W=200 | stock, program schedule | 6.5 M | 80 | 390 | 671 | 3,233,220 | 3,233,220 | 354 | 1,831 |
| recording, W=200 | regions, census | 13.1 M | 51 | 90 | 210 | 50,536 | 50,536 | — | 1,791 |
| recording, W=200 | regions, no census | 14.1 M | 50 | 80 | 311 | 14,758 | 14,758 | — | 1,791 |
| light, W=3 | stock, own heuristics | 16.9 M | 30 | 50 | 251 | 3,612,827 | 3,612,827 | 36 | 1,831 |
| light, W=3 | stock, program schedule | 16.3 M | 40 | 50 | 201 | 3,194,397 | 3,194,397 | 51 | 1,831 |
| light, W=3 | regions, census | 16.1 M | 40 | 51 | 451 | 58,631 | 58,631 | — | 1,791 |
| light, W=3 | regions, no census | 16.4 M | 40 | 51 | 281 | 14,988 | 14,988 | — | 1,791 |
<!-- /table -->

![M4 on checked](results/plots/checked/latency_ccdf.svg)

The stock collector's longest event is 3.2 to 3.6 ms; the regions' is 51 to
59 µs with the census, at a census boundary, and 15 µs without it.

### M6 — Paced and endurance

**Claim.** At one event per 100 µs on the wall clock, the region loop
misses no slot, where the stock loop misses a slot at every collection;
over 30 minutes the RSS of the region loop stays flat.

[`bench/paced.jl`](bench/paced.jl) fires a million events, one per 100 µs
slot; the row reports how late an event completes against its slot start,
and the page faults of the run. The last row of each table is the region
loop with 512 MB reserved.

<!-- table M6-paced run=checked -->
| variant | events | latency p50 (ns) | latency max (ns) | lateness p99.9 (ns) | lateness max (ns) | slot misses | GC events | GC (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | 1,000,000 | 70 | 4,970,967 | 595 | 4,971,024 | 55 | 1 | 4.9 |
| regions | 1,000,000 | 100 | 5,981 | 261 | 24,857 | 0 | 0 | 0.0 |
<!-- /table -->

![M6-paced on checked](results/plots/checked/paced.svg)

<!-- table M6-paced run=trusted -->
| variant | events | latency p50 (ns) | latency max (ns) | lateness p99.9 (ns) | lateness max (ns) | slot misses | GC events | GC (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | 1,000,000 | 80 | 4,528,483 | 597 | 4,528,542 | 51 | 1 | 4.5 |
| regions | 1,000,000 | 80 | 7,514 | 248 | 23,480 | 0 | 0 | 0.0 |
<!-- /table -->

![M6-paced on trusted](results/plots/trusted/paced.svg)

The stock loop completes an event 4.5 to 5.0 ms late at worst and misses 51
to 55 slots of a million; the region loop's longest event is 6.0 µs on
`checked` and 7.5 µs on `trusted`, its worst lateness 25 and 23 µs, and it
misses none.

[`bench/endurance.jl`](bench/endurance.jl) runs eighteen million events
over thirty minutes with one sample per hundred thousand:

<!-- table M6-endurance run=checked -->
| endurance | value |
| --- | --- |
| samples (one per 100 000 events) | 180 |
| events | 18,000,000 |
| wall (s) | 1,800 |
| RSS at the first sample (MB) | 365.21 |
| RSS at the last sample (MB) | 365.21 |
| RSS max (MB) | 365.21 |
| allocated through the region, first to last sample (MB) | 525 |
| slot misses | 0 |
<!-- /table -->

![M6-endurance on checked](results/plots/checked/endurance.svg)

The RSS is 365 MB on `checked` and 310 MB on `trusted` at the first sample
and at the last, with 525 MB allocated through the region between them, and
no slot missed in the thirty minutes.

### M7 — Against the C++ program

**Claim.** A model written for regions, a packet allocated at send and
dropped at delivery, runs within a small factor of the same model in C++
with `new` and `delete` per event, and the census keeps its memory flat.

[`bench/native.jl`](bench/native.jl) and [`bench/native.cpp`](bench/native.cpp),
five million events, a census every hundred thousand:

<!-- table M7 run=checked -->
| variant | W | events/s | censuses | census p50 (µs) | census max (µs) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- |
| region | 3 | 61.0 M | 50 | 3.2 | 9.3 | 316.9 |
| stock | 3 | 61.7 M | — | — | — | 336.2 |
| cpp | 3 | 66.5 M | — | — | — | 3.9 |
| region | 200 | 30.8 M | 50 | 10.1 | 17.7 | 339.0 |
| stock | 200 | 26.4 M | — | — | — | 336.1 |
| cpp | 200 | 39.9 M | — | — | — | 3.8 |
<!-- /table -->

![M7 on checked](results/plots/checked/native.svg)

<!-- table M7 run=trusted -->
| variant | W | events/s | censuses | census p50 (µs) | census max (µs) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- |
| region | 3 | 82.5 M | 50 | 3.2 | 10.3 | 315.3 |
| stock | 3 | 62.0 M | — | — | — | 328.8 |
| cpp | 3 | 69.8 M | — | — | — | 3.9 |
| region | 200 | 34.6 M | 50 | 11.0 | 18.9 | 337.7 |
| stock | 200 | 26.1 M | — | — | — | 328.7 |
| cpp | 200 | 41.6 M | — | — | — | 3.9 |
<!-- /table -->

![M7 on trusted](results/plots/trusted/native.svg)

At the heavy weight the region loop runs at 0.77 of the C++ program on
`checked` and 0.83 on `trusted`, against 0.63 to 0.66 for the stock loop;
at the light weight `checked` runs at 0.92 and `trusted` faster than the
C++ program, at 1.18.

### M8 — Wholesale death

**Claim.** When a whole structure dies at once, a reset frees it without a
collection.

<!-- table M8 run=checked -->
| showcase | mode | wall (s) | collections | GC (ms) | peak RSS (MB) | rounds |
| --- | --- | --- | --- | --- | --- | --- |
| binarytree | stock | 0.371 | 31 | 81.9 | 334 | 3 |
| binarytree | regions | 0.339 | 0 | 0.0 | 324 | 3 |
| linkedlist | stock | 2.186 | 10 | 1696.2 | 2,449 | 3 |
| linkedlist | regions | 0.581 | 0 | 0.0 | 2,448 | 3 |
| tree | stock | 0.008 | 6 | 0.8 | — | 3 |
| tree | regions | 0.007 | 0 | 0.0 | — | 3 |
<!-- /table -->

![M8 on checked](results/plots/checked/showcase.svg)

<!-- table M8 run=trusted -->
| showcase | mode | wall (s) | collections | GC (ms) | peak RSS (MB) | rounds |
| --- | --- | --- | --- | --- | --- | --- |
| binarytree | stock | 0.372 | 31 | 80.2 | 328 | 3 |
| binarytree | regions | 0.269 | 0 | 0.0 | 322 | 3 |
| linkedlist | stock | 2.183 | 10 | 1685.7 | 2,444 | 3 |
| linkedlist | regions | 0.493 | 0 | 0.0 | 2,447 | 3 |
| tree | stock | 0.007 | 6 | 0.8 | — | 3 |
| tree | regions | 0.004 | 0 | 0.0 | — | 3 |
<!-- /table -->

![M8 on trusted](results/plots/trusted/showcase.svg)

The linked list, which the stock collector traces ten times for 1.7 s,
runs in 0.58 s on `checked` and 0.49 s on `trusted` with no collection, at
the same peak RSS.

### M9 — The growth bound

**Claim.** The census of the open region, armed at a page threshold, holds
the pages of a region that churns inside one window to a bound; disarmed,
the region grows with the churn.

<!-- table M9 run=checked -->
| census | rounds | pages at the last round | pages max | ratio disarmed / armed |
| --- | --- | --- | --- | --- |
| disarmed | 40,000 | 10,089 | 10,089 | 1.00 |
| armed | 40,000 | 60 | 63 | 160.14 |
<!-- /table -->

![M9 on checked](results/plots/checked/census_bound.svg)

### M12 — Thread scaling of the sibling leaves

**Claim.** Sibling leaves, one per worker, scale with the thread count
without coordination between the leaves.

<!-- table M12 run=checked -->
| demo | point | threads | wall stock (ms) | wall regions (ms) | stock / regions | collections stock | collections regions | GC stock (ms) | GC regions (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| B | small | 1 | 13.0 | 13.4 | 0.97 | 0 | 0 | 0.0 | 0.0 |
| B | medium | 1 | 39.0 | 38.7 | 1.01 | 2 | 0 | 0.3 | 0.0 |
| B | large | 1 | 103.3 | 102.2 | 1.01 | 7 | 0 | 0.8 | 0.0 |
| D | work=0 | 1 | 95.9 | 91.6 | 1.05 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 1 | 101.8 | 92.7 | 1.10 | 2 | 0 | 2.2 | 0.0 |
| D | work=2048 | 1 | 95.8 | 97.9 | 0.98 | 13 | 0 | 5.2 | 0.0 |
| B | small | 2 | 10.7 | 10.7 | 0.99 | 0 | 0 | 0.0 | 0.0 |
| B | medium | 2 | 30.7 | 30.5 | 1.01 | 2 | 0 | 0.2 | 0.0 |
| B | large | 2 | 80.9 | 79.3 | 1.02 | 7 | 0 | 0.7 | 0.0 |
| D | work=0 | 2 | 59.6 | 58.9 | 1.01 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 2 | 60.7 | 61.2 | 0.99 | 3 | 0 | 2.4 | 0.0 |
| D | work=2048 | 2 | 72.6 | 63.8 | 1.14 | 17 | 0 | 8.1 | 0.0 |
| B | small | 4 | 6.0 | 6.0 | 0.99 | 1 | 0 | 0.2 | 0.0 |
| B | medium | 4 | 17.0 | 16.6 | 1.03 | 3 | 0 | 0.4 | 0.0 |
| B | large | 4 | 44.3 | 43.0 | 1.03 | 8 | 0 | 0.9 | 0.0 |
| D | work=0 | 4 | 37.9 | 37.5 | 1.01 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 4 | 38.9 | 38.4 | 1.01 | 4 | 0 | 2.9 | 0.0 |
| D | work=2048 | 4 | 47.5 | 39.4 | 1.21 | 22 | 0 | 8.0 | 0.0 |
| B | small | 8 | 3.5 | 3.8 | 0.91 | 1 | 0 | 0.1 | 0.0 |
| B | medium | 8 | 11.0 | 10.3 | 1.07 | 3 | 0 | 0.4 | 0.0 |
| B | large | 8 | 27.2 | 26.2 | 1.04 | 8 | 0 | 1.1 | 0.0 |
| D | work=0 | 8 | 25.4 | 25.1 | 1.01 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 8 | 28.9 | 25.8 | 1.12 | 4 | 0 | 2.3 | 0.0 |
| D | work=2048 | 8 | 38.5 | 31.1 | 1.24 | 23 | 0 | 8.3 | 0.0 |
<!-- /table -->

![M12 on checked](results/plots/checked/scaling.svg)

## E5 — The census, the demonstrators, the checker

### M5 — The census

**Claim.** The pause of a census grows with the live set of the region, not
with the garbage, and stays two orders of magnitude below a full stock
collection over the same heap.

[`bench/census.jl`](bench/census.jl), two million events, a census every
hundred thousand, K live records:

<!-- table M5-pause run=checked -->
| variant | K | pause p50 (µs) | pause max (µs) | stop the world (µs) | mark (µs) | sweep (µs) | live cells | freed cells |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scoped | 300 | 6.5 | 47.6 | 3.1 | 3.3 | 1.0 | 302 | 100,515 |
| coop | 300 | 2.8 | 18.5 | 0.1 | 2.6 | 1.1 | 302 | 100,515 |
| full | 300 | 2054.2 | 7561.4 | — | — | — | — | — |
| scoped | 1,000 | 8.9 | 52.0 | 3.5 | 5.3 | 1.4 | 1,002 | 100,550 |
| coop | 1,000 | 4.7 | 20.4 | 0.1 | 4.1 | 1.3 | 1,002 | 100,550 |
| full | 1,000 | 2084.8 | 7192.7 | — | — | — | — | — |
| scoped | 3,000 | 13.9 | 53.1 | 3.0 | 9.8 | 2.3 | 3,002 | 100,650 |
| coop | 3,000 | 10.3 | 28.6 | 0.1 | 9.2 | 2.1 | 3,002 | 100,650 |
| full | 3,000 | 2170.3 | 7331.3 | — | — | — | — | — |
| scoped | 10,000 | 34.2 | 72.8 | 3.0 | 27.3 | 4.9 | 10,002 | 101,000 |
| coop | 10,000 | 31.2 | 48.1 | 0.1 | 27.4 | 5.0 | 10,002 | 101,000 |
| full | 10,000 | 2394.5 | 7775.7 | — | — | — | — | — |
| scoped | 30,000 | 92.8 | 132.1 | 3.2 | 77.8 | 13.1 | 30,002 | 102,000 |
| coop | 30,000 | 84.0 | 97.3 | 0.1 | 71.8 | 13.0 | 30,002 | 102,000 |
| full | 30,000 | 3122.8 | 8318.2 | — | — | — | — | — |
| scoped | 100,000 | 282.1 | 455.2 | 3.3 | 246.0 | 48.3 | 100,002 | 105,500 |
| coop | 100,000 | 297.9 | 443.7 | 0.1 | 261.9 | 46.4 | 100,002 | 105,500 |
| full | 100,000 | 5390.0 | 10639.9 | — | — | — | — | — |
<!-- /table -->

![M5-pause on checked](results/plots/checked/census_pause.svg)

<!-- table M5-throughput run=checked -->
| variant | W | B | events/s | collections | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- |
| autopool | 3 | 1 | 53.0 M | 0 | 1,222 |
| batch | 3 | 1 | 23.9 M | 0 | 1,222 |
| batch | 3 | 100 | 56.7 M | 0 | 1,222 |
| batch | 3 | 1000 | 56.6 M | 0 | 1,222 |
| pooled | 3 | 1 | 26.2 M | 50 | 1,222 |
| autopool | 200 | 1 | 10.4 M | 0 | 1,223 |
| batch | 200 | 1 | 21.0 M | 0 | 1,222 |
| batch | 200 | 100 | 40.6 M | 0 | 1,222 |
| batch | 200 | 1000 | 37.0 M | 0 | 1,222 |
| pooled | 200 | 1 | 21.1 M | 50 | 1,222 |
<!-- /table -->

![M5-throughput on checked](results/plots/checked/census_throughput.svg)

A census of a region with 300 live records pauses 6.5 µs at the median,
stop the world, and 2.8 µs cooperative; a full stock collection of the same
heap 2.1 ms. With 30,000 live records the census pauses 93 µs.

### M10 — The demonstrators

**Claim.** On four algorithms the same code runs under regions and under
the stock collector; regions remove the collections in every case and win
on wall time where the discarded allocation per unit of work is large.

<!-- table M10 run=checked -->
| demo | point | threads | wall stock (ms) | wall regions (ms) | stock / regions | collections stock | collections regions | GC stock (ms) | GC regions (ms) | peak RSS stock (MB) | peak RSS regions (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | small (1500 instances, n=30, K=3) | 1 | 152.5 | 144.3 | 1.06 | 12 | 0 | 7.2 | 0.0 | 339 | 339 |
| A | medium (3000 instances, n=32, K=3) | 1 | 317.6 | 297.7 | 1.07 | 24 | 0 | 14.5 | 0.0 | 346 | 343 |
| A | large (5000 instances, n=34, K=3) | 1 | 554.4 | 526.2 | 1.05 | 42 | 0 | 23.3 | 0.0 | 346 | 346 |
| B | small (160x100, 8 spp, depth 8, 4 threads) | 4 | 5.8 | 6.1 | 0.95 | 1 | 0 | 0.1 | 0.0 | 349 | 349 |
| B | medium (160x100, 24 spp, depth 8, 4 threads) | 4 | 17.1 | 17.1 | 1.00 | 3 | 0 | 0.4 | 0.0 | 351 | 351 |
| B | large (160x100, 64 spp, depth 8, 4 threads) | 4 | 44.4 | 43.3 | 1.03 | 8 | 0 | 0.9 | 0.0 | 351 | 351 |
| C | work=0 (80000 keys, work=0, 4 threads) | 4 | 28.4 | 63.9 | 0.45 | 5 | 4 | 4.3 | 4.6 | 424 | 386 |
| C | work=64 (80000 keys, work=64, 4 threads) | 4 | 81.7 | 94.6 | 0.86 | 16 | 4 | 22.6 | 4.2 | 478 | 437 |
| C | work=256 (80000 keys, work=256, 4 threads) | 4 | 274.8 | 175.5 | 1.57 | 36 | 2 | 103.7 | 3.5 | 604 | 604 |
| C | work=1024 (80000 keys, work=1024, 4 threads) | 4 | 834.2 | 439.2 | 1.90 | 111 | 2 | 289.8 | 2.9 | 675 | 673 |
| D | work=0 (grid 16, work=0, 4 threads) | 4 | 37.8 | 37.4 | 1.01 | 0 | 0 | 0.0 | 0.0 | 348 | 348 |
| D | work=512 (grid 16, work=512, 4 threads) | 4 | 39.6 | 37.8 | 1.05 | 4 | 0 | 2.7 | 0.0 | 360 | 358 |
| D | work=2048 (grid 16, work=2048, 4 threads) | 4 | 46.4 | 38.8 | 1.20 | 22 | 0 | 8.1 | 0.0 | 369 | 359 |
<!-- /table -->

![M10 on checked](results/plots/checked/demo_a.svg)

![M10 demo_b on checked](results/plots/checked/demo_b.svg)

![M10 demo_c on checked](results/plots/checked/demo_c.svg)

![M10 demo_d on checked](results/plots/checked/demo_d.svg)

![M10 demo_rss on checked](results/plots/checked/demo_rss.svg)

The speculative tree (C) is the crossover: 0.45 of the stock speed with no
work per transaction, 1.90 with 1,024 units of it.

### M11 — The discipline checker

**Claim.** The checker finds the stores of the allocating model that break
the region rule, and finds none in the clean model, without a region in
use.

The checker is tooling of this branch, not of the pull request. On the
master line its compiler hook anchors on the `optimize` entry of the
compiler, and the pass reads a builtin that the optimized IR names through
its binding partition. The allocating model breaks the rule at three
sites: the kernel's queue stores an event made inside a handler, through
the two store paths of `push!`, and the vector of samples grows ten times;
the clean model breaks it nowhere. The numbers are those of the
release-1.13 line.

<!-- table M11 run=checked -->
| model | events | violations (stores) | sites |
| --- | --- | --- | --- |
| alloc | 100,000 | 200,018 | 3 |
| clean | 100,000 | 0 | 0 |
<!-- /table -->

## Where the master line differs from the release-1.13 line

- The store's guard costs 0.044 ns instead of 0.085: master's write barrier
  is field-aware now and the guard sits inside it.
- The full parallel collection costs 7 % more at thirty threads, where it
  cost 7 % at thirty-two; the probe build says that the mark's census filter
  is about half of it.
- The checked reset costs 27 µs alone, as before; the unchecked one 30 ns.
- The paced loop's longest event is 6 to 7.5 µs where it was 5.6 µs, on a
  partition made at run time rather than at boot.
- Against the C++ program the region loop runs at 0.77 with the barrier
  and 0.83 without it, where it ran at 0.85.
- The system image grows 7.9 % with the barrier built, where it grew 3.4 %;
  without the barrier it grows 1.9 %.
