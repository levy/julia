# Measurements

Every number in this document was measured on the master line of this work,
the series of the pull request on master `c941fbc399` plus the two
independent commits under it: the cost rows E2, M1, M2, M13 and the tail
row M3 on 2026-09-25, after the allocator's last change, and the rest on
2026-09-23, on the same tree but for that change. The branch was then
rebased onto master `b883b468f0` of 2026-09-24 and took the annotations
that make the static analysis with the flag read clean; the region code
that the rows exercise is the same, so the numbers stand on the older
base and were not taken again. The release-1.13 line had its own set of
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
| `master` | upstream master `c941fbc399` | none | stock Julia of that day |
| `base` | master plus the two independent commits | none | the deferral fix and `jl_gc_heap_reserve`; the pull request's flag-less build compiles to this code |
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
transparent huge pages `always`, idle for the whole run. The kernel command
line keeps CPUs 13 and 29, the two threads of one core, tickless and free of
RCU callbacks (`nohz_full=13,29`); [`tools/hil_isolation.sh`](tools/hil_isolation.sh)
made the isolated partition at run time through cgroup v2 (`sudo ... on`).
The **latency rows** (M3, M4, M5, M6, and the paced and tail rows with the
reserve) ran inside the partition, pinned to CPU 29 in the real-time class
(`SCHED_FIFO` 50), the driver beside them in the normal class; the tick left
the core (211 interrupts a second against 2,000 outside the partition), and a
pure spin of five seconds there has a worst gap of 2.1 µs. Every other row
ran outside the partition, the one-thread rows pinned to CPU 28, the
multi-thread rows on CPUs 24 to 28, 30 and 31, and the collector rows M13
and M14 on the 30 CPUs outside the partition, so their largest thread count
is 30 where the release-1.13 line had 32. Every row ran under a timeout and
under a memory cap: a systemd scope outside the partition, the partition's
own cgroup limit of 16 GB inside it. `data/<run>/context.tsv` records the
date, the commit, the host, the CPU, the kernel and the cores of each run.

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
| ns per allocation, past the target | 9.65 [9.54, 9.82] | 4.29 [4.26, 4.46] | 0.446 [0.437, 0.458] | 10 |
<!-- /table -->

**The heap reserve.** `jl_gc_heap_reserve(bytes)` maps and prefaults pool
pages before a loop. On the stock paced loop (the collector on, a 128 MB
heap hint) it takes the faults of the run from 1,736 to 1,263 and leaves
the misses where they are, because the stock collector gives pages back
between collections and faults them in again; the reserve is for a loop
that keeps its pages, which is the region loop of M6. Master has no reserve
and shows the same faults as base without one.

<!-- table E1-reserve run=e1 -->
| run | page faults during the run | slot misses | worst lateness (ms) | longest event (µs) |
| --- | --- | --- | --- | --- |
| base, no reserve | 1,736 | 62 | 4.8 | 4,754 |
| base, 512 MB reserved | 1,263 | 55 | 4.9 | 4,890 |
| master, no reserve | 1,760 | 57 | 4.9 | 4,871 |
<!-- /table -->

## E2 — The cost when the regions are built and unused

**Claim.** A program that never opens a window pays, with the barrier
built, one load and one branch at every managed pointer store, a longer
allocation path, the census filter in the mark, and a larger system image;
without the barrier the store costs nothing and the image grows a third of
that. The `probe` build, which keeps the region code but takes the allocator
and the filter out, says which part of the rest costs what.

**Text.** The system image grows 9.2 % with the barrier built and 3.0 %
without it; the runtime library 2.1 % and 0.85 %. The barrier's guard sits
at every barrier site of the compiled code, and it is two thirds of the
growth.

<!-- table E2-text -->
| build | libjulia-internal text (bytes) | against base | sys.so text (bytes) | against base |
| --- | --- | --- | --- | --- |
| master | 2,752,678 | -0.05 % | 24,147,941 | +0.00 % |
| base | 2,753,991 | +0.00 % | 24,147,293 | +0.00 % |
| checked | 2,810,682 | +2.06 % | 26,367,269 | +9.19 % |
| trusted | 2,777,389 | +0.85 % | 24,877,329 | +3.02 % |
| probe | 2,808,674 | +1.99 % | 26,370,037 | +9.20 % |
<!-- /table -->

**The unit costs, attributed.** Each cell is the paired difference "the
region build with no window open minus base", from ten rounds of
[`bench/unit_costs.jl`](bench/unit_costs.jl) on each of the three region
builds. The store costs 0.045 ns with the barrier and nothing without it,
so the store's cost is the guard alone. A pool allocation costs 0.17 ns
with everything built, 0.13 without the barrier and 0.11 in the probe,
whose allocator is base's, so the allocator path, one load and one add
where base adds a constant, is a few hundredths of a nanosecond and the
region code around an allocation the rest. The serial mark costs 1.2 to
1.3 ms of 65 with the regions usable and nothing in the probe, so its
cost is the census filter in the claim.

<!-- table E2-unit-attribution -->
| cost | unit | regions built, barrier built − base | regions built, no barrier − base | regions built, allocator and filter off − base |
| --- | --- | --- | --- | --- |
| store_disarmed | ns/store | 0.043 [0.0396, 0.0448], sign 0.002 | -0.00045 [-0.00165, 0.00055], sign 0.34 | 0.044 [0.0425, 0.0447], sign 0.002 |
| alloc_stock | ns/object | 0.17 [0.157, 0.231], sign 0.002 | 0.13 [0.12, 0.509], sign 0.002 | 0.109 [0.092, 0.118], sign 0.002 |
| construct_two | ns/object | 0.406 [0.376, 0.432], sign 0.002 | 0.366 [0.326, 0.391], sign 0.002 | 0.197 [0.147, 0.264], sign 0.002 |
| box_twin | ns/object | 0.325 [0.29, 0.354], sign 0.002 | 0.138 [0.0825, 0.163], sign 0.002 | 0.246 [0.196, 0.304], sign 0.002 |
| stock_mark | ms/collection | 1.23 [0.825, 1.41], sign 0.021 | 1.32 [0.98, 2.01], sign 0.002 | -0.395 [-1.27, 0.09], sign 0.34 |
<!-- /table -->

The full table of `checked`, with the rows of a program that uses regions
(the `regions` column) beside the two stock columns:

<!-- table M2 run=checked -->
| cost | unit | vanilla | regions, no window | regions | no window − vanilla [95 %] | rounds |
| --- | --- | --- | --- | --- | --- | --- |
| store_disarmed | ns/store | 0.3323 [0.3318, 0.3361] | 0.3759 [0.3752, 0.3772] | 0.3759 [0.375, 0.3866] | 0.043 [0.0396, 0.0448], sign 0.002 | 10 |
| store_armed | ns/store | — | — | 1.427 [1.426, 1.428] | — | 10 |
| store_armed_const | ns/store | — | — | 0.156 [0.1559, 0.156] | — | 10 |
| store_region | ns/store | — | — | 2.022 [2.019, 2.025] | — | 10 |
| window_pair | ns/pair | — | — | 11.45 [11.45, 11.46] | — | 10 |
| switch_pair | ns/pair | — | — | 5.909 [5.902, 6.305] | — | 10 |
| construct_two | ns/object | 7.175 [7.157, 7.225] | 7.576 [7.56, 7.613] | 9.678 [9.631, 9.743] | 0.406 [0.376, 0.432], sign 0.002 | 10 |
| construct_shared | ns/object | 3.448 [3.429, 3.469] | 3.705 [3.672, 3.723] | 6.055 [6.037, 6.093] | 0.266 [0.216, 0.279], sign 0.002 | 10 |
| box_twin | ns/object | 3.749 [3.717, 3.775] | 4.087 [4.048, 4.101] | 5.954 [5.941, 6.011] | 0.325 [0.29, 0.354], sign 0.002 | 10 |
| alloc_stock | ns/object | 2.016 [2.014, 2.026] | 2.191 [2.185, 2.249] | 3.256 [3.251, 3.269] | 0.17 [0.157, 0.231], sign 0.002 | 10 |
| finalizer_register | ns/object | 2.244 [2.166, 2.265] | 2.3 [2.279, 2.31] | 3.477 [3.333, 3.489] | 0.065 [0.02, 0.12], sign 0.021 | 10 |
| alloc_region | ns/object | — | — | 3.63 [3.619, 3.638] | — | 10 |
| reset_slice | ns/reset | — | — | 30 [30, 30] | — | 10 |
| stock_mark | ms/collection | 64.55 [64.39, 64.99] | 65.7 [65.49, 66.01] | 66.56 [66.18, 67.14] | 1.23 [0.825, 1.41], sign 0.021 | 10 |
<!-- /table -->

![M2 on checked](results/plots/checked/unit_costs.svg)

**The collector on the whole machine.** A full collection of the same
heap, regions against base, at 1 to 30 threads, ten paired rounds each
([`bench/parallel_gc.jl`](bench/parallel_gc.jl)). With the regions usable
the collection costs 1 to 2 % more at one thread and 6 to 8 % more at thirty,
with or without the barrier; the probe costs 3 % at thirty. So the growth
with the thread count is the census filter in the mark loop, 3 to 5 points
at thirty threads, and the collector's other checks, the corpse test at a
mark and the page test at a sweep, are the remaining 3.

<!-- table E2-parallel-attribution -->
| threads | regions built, barrier built / base [95 %] | regions built, no barrier / base [95 %] | regions built, allocator and filter off / base [95 %] |
| --- | --- | --- | --- |
| 1 | 1.01 [1, 1.02] | 1.02 [1.01, 1.02] | 0.989 [0.981, 0.996] |
| 4 | 1.02 [1.01, 1.03] | 1.02 [1.02, 1.03] | 0.99 [0.988, 0.997] |
| 8 | 0.989 [0.939, 1.05] | 1.03 [0.99, 1.05] | 1.01 [0.968, 1.05] |
| 16 | 1.04 [1.03, 1.07] | 1.05 [1.02, 1.11] | 1.02 [1, 1.05] |
| 30 | 1.06 [1.04, 1.09] | 1.08 [1.07, 1.09] | 1.03 [1.02, 1.08] |
<!-- /table -->

<!-- table M13 run=checked -->
| threads | vanilla (ms) | regions (ms) | regions / vanilla [95 %] | mark vanilla (ms) | mark regions (ms) | time to safepoint (µs) | rounds |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 39.4 [39.1, 39.6] | 39.8 [39.7, 40] | 1.01 [1, 1.02] | 35.5 [35.3, 35.7] | 36 [35.8, 36.1] | 4.29 [3.89, 4.4] | 10 |
| 4 | 56.3 [56.2, 56.7] | 57.4 [57.3, 57.6] | 1.02 [1.01, 1.03] | 48.8 [48.6, 49.1] | 49.7 [49.6, 49.9] | 6.53 [5.75, 7.06] | 10 |
| 8 | 61.9 [58.3, 63.4] | 60.2 [58.9, 61.6] | 0.989 [0.939, 1.05] | 51.7 [48.6, 53.6] | 49.6 [48.4, 51.2] | 7 [6.52, 7.47] | 10 |
| 16 | 65.9 [64.8, 66.7] | 68.3 [67.8, 70.6] | 1.04 [1.03, 1.07] | 49.9 [48.7, 50.5] | 51 [50.9, 53.6] | 7.52 [7.21, 8.06] | 10 |
| 30 | 80.5 [79.7, 81.9] | 85.6 [84.8, 87.7] | 1.06 [1.04, 1.09] | 56.7 [55.5, 57.5] | 60.4 [59.8, 62.2] | 7.81 [7.35, 8.39] | 10 |
<!-- /table -->

![M13 on checked](results/plots/checked/parallel_gc.svg)

**The GC benchmark suite.** Eleven benchmarks of
[GCBenchmarks](https://github.com/JuliaCI/GCBenchmarks), six on one thread
and five on four, ten paired rounds, base against each region build; the
cell is the ratio of the minima over the rounds
([`bench/gcbench.sh`](bench/gcbench.sh)). Two of the eleven, the mutable
binary tree and the object array, abort under the 16 GB cap on every
binary alike and have no row. Seven of the nine are within 1 % on the
build with the barrier; `many_refs`, which allocates large arrays of
references, is 2 % slower with the barrier and without it and equal in
the probe; `pollard` is 7 % slower with the barrier, 6 % in the probe and
12 % without the barrier in this run, where two rounds of ten fell far
off. Five paired runs of pollard with the collector's counters, on core
28, name the gap: every region build does eleven collections where base
does ten, over the same allocation volume within 11 KB, and the eleventh
costs about 15 of the 38 ms; the rest is 4.7 % more instructions, in the
registration of the finalizer that every BigInt carries and in the mark of
the finalizer list, and 4 % more page faults. The collector's heap target
follows its own timing, so the threshold of the eleventh collection falls
differently on a build whose mark costs a little more. The early return of
the finalizer hook, the census filter as a parameter and the inlining of
the mark-bit functions were each built and measured as the cause on
2026-09-24, and pollard did not move under any of them.

<!-- table M1 run=checked -->
| benchmark | threads | vanilla (s) | regions (s) | regions / vanilla [95 %] | rounds |
| --- | --- | --- | --- | --- | --- |
| append | 1 | 0.766 | 0.779 | 1.01 [1.01, 1.02] | 2 |
| tree | 1 | 8.833 | 8.917 | 1.01 [1, 1.02] | 10 |
| strings | 1 | 18.710 | 18.745 | 1 [0.995, 1.01] | 10 |
| pollard | 1 | 0.652 | 0.695 | 1.07 [1.06, 1.07] | 10 |
| single_ref | 1 | 0.273 | 0.274 | 1 [1, 1.01] | 10 |
| many_refs | 1 | 1.733 | 1.776 | 1.02 [1.02, 1.03] | 10 |
| mergesort_parallel | 4 | 1.705 | 1.705 | 1 [0.986, 1.02] | 10 |
| mm_divide_and_conquer | 4 | 0.596 | 0.607 | 1.01 [0.998, 1.04] | 10 |
| issue-52937 | 4 | 9.458 | 9.527 | 1.01 [0.998, 1.01] | 10 |
<!-- /table -->

![M1 on checked](results/plots/checked/gcbench.svg)

<!-- table M1 run=trusted -->
| benchmark | threads | vanilla (s) | regions (s) | regions / vanilla [95 %] | rounds |
| --- | --- | --- | --- | --- | --- |
| append | 1 | 0.765 | 0.779 | 1.02 [1.01, 1.03] | 2 |
| tree | 1 | 8.759 | 8.779 | 1 [0.992, 1.01] | 10 |
| strings | 1 | 18.639 | 18.683 | 0.994 [0.988, 1.01] | 10 |
| pollard | 1 | 0.650 | 0.725 | 1.12 [1.07, 1.13] | 10 |
| single_ref | 1 | 0.272 | 0.275 | 1.01 [1.01, 1.01] | 10 |
| many_refs | 1 | 1.733 | 1.774 | 1.02 [1.02, 1.03] | 10 |
| mergesort_parallel | 4 | 1.687 | 1.738 | 1.03 [1.02, 1.04] | 10 |
| mm_divide_and_conquer | 4 | 0.601 | 0.607 | 1.01 [0.996, 1.04] | 10 |
| issue-52937 | 4 | 9.434 | 9.533 | 1.01 [1, 1.01] | 10 |
<!-- /table -->

<!-- table M1 run=probe -->
| benchmark | threads | vanilla (s) | regions (s) | regions / vanilla [95 %] | rounds |
| --- | --- | --- | --- | --- | --- |
| append | 1 | 0.766 | 0.777 | 1.01 [1, 1.02] | 3 |
| tree | 1 | 8.734 | 8.791 | 1 [0.997, 1.01] | 10 |
| strings | 1 | 18.595 | 18.566 | 0.996 [0.987, 1.01] | 10 |
| pollard | 1 | 0.655 | 0.693 | 1.06 [1.05, 1.06] | 10 |
| single_ref | 1 | 0.273 | 0.274 | 1.01 [0.996, 1.01] | 10 |
| many_refs | 1 | 1.733 | 1.737 | 1 [0.999, 1] | 10 |
| mergesort_parallel | 4 | 1.682 | 1.684 | 1.01 [0.99, 1.02] | 10 |
| mm_divide_and_conquer | 4 | 0.597 | 0.595 | 0.996 [0.98, 1.02] | 10 |
| issue-52937 | 4 | 9.470 | 9.472 | 0.999 [0.995, 1] | 10 |
<!-- /table -->

## E3 — What a program that uses regions pays

**Claim.** In a window, a store costs the tag compare when the barrier is
armed; a region allocation, a window pair and an unchecked reset cost a few
nanoseconds; a checked reset costs the stop of the world, and so grows with
the threads that run Julia code.

From the `regions` column of the unit costs above, on `checked`: a managed
store 1.44 ns armed against 0.38 disarmed; a region allocation 3.9 ns
against 3.4 for a stock one in the same process; a window pair 11.3 ns, a
task switch pair 6.1; an unchecked reset 30 ns whatever the region held; a
checked reset 27 µs on one thread. On `trusted` the same store costs
0.33 ns and a region allocation 2.2 ns, less than a stock allocation there.

**The reset against the other threads.** [`bench/reset_pause.jl`](bench/reset_pause.jl)
resets a small region two hundred times while the other threads run Julia
code, at 1 to 30 threads, ten rounds. The checked reset grows from 27 µs
alone to 105 µs against 29 workers, and its worst case at 30 threads is
3.8 ms, with a worker stalled up to 4.4 ms; the unchecked reset stays
between 65 and 130 ns. The worst worker stall of the unchecked row at 30
threads is the scheduler's, not a pause: 30 threads and their collector
threads share 30 CPUs there.

<!-- table M14 run=checked -->
| entry | threads | workers | caller median (µs) | caller max (µs) | worst worker stall (µs) | collections | rounds |
| --- | --- | --- | --- | --- | --- | --- | --- |
| checked | 1 | 0 | 26.9 [26.8, 27.3] | 37.8 [34.3, 44.1] | — | 0 | 10 |
| checked | 4 | 3 | 35.5 [35.2, 36.1] | 235 [165, 415] | 119 [90.8, 166] | 0 | 10 |
| checked | 8 | 7 | 44 [42.7, 45] | 131 [110, 300] | 109 [99.8, 404] | 1 | 10 |
| checked | 16 | 15 | 68.8 [66.6, 70.5] | 460 [405, 700] | 227 [163, 669] | 0 | 10 |
| checked | 30 | 29 | 105 [103, 107] | 3.81e+03 [3.52e+03, 3.86e+03] | 4.37e+03 [3.62e+03, 5.22e+03] | 0 | 10 |
| unsafe | 1 | 0 | 0.0653 [0.06, 0.075] | 0.17 [0.12, 0.3] | — | 0 | 10 |
| unsafe | 4 | 3 | 0.07 [0.06, 0.08] | 0.19 [0.166, 0.271] | 0 [0, 21.9] | 0 | 10 |
| unsafe | 8 | 7 | 0.0705 [0.07, 0.08] | 0.341 [0.255, 0.982] | 11.4 [0, 978] | 1 | 10 |
| unsafe | 16 | 15 | 0.09 [0.08, 0.09] | 1.81 [0.376, 2.21] | 0 [0, 14.9] | 0 | 10 |
| unsafe | 30 | 29 | 0.13 [0.115, 0.135] | 0.451 [0.211, 1.17] | 4e+03 [2.48e+03, 4.5e+03] | 0 | 10 |
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
| yardstick | alloc | 61 | 81 | 230 | 842 | 5,420,597 | 22 | 11 | 14.5 | 905 |
| yardstick | pooled | 80 | 91 | 110 | 742 | 91,473 | 0 | 0 | 0.0 | 825 |
| tail | baseline | 60 | 80 | 120 | 471 | 4,106,928 | 16 | 16 | 14.6 | 1,401 |
| tail | regions | 70 | 110 | 111 | 461 | 96,502 | 0 | 0 | 0.0 | 1,561 |
<!-- /table -->

![M3 on checked](results/plots/checked/tail.svg)

<!-- table M3 run=trusted -->
| script | variant | p50 (ns) | p99 (ns) | p99.9 (ns) | p99.99 (ns) | max (ns) | over 100 µs | collections | GC (ms) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| yardstick | alloc | 61 | 81 | 250 | 862 | 5,598,342 | 19 | 11 | 14.7 | 904 |
| yardstick | pooled | 60 | 71 | 90 | 541 | 91,853 | 0 | 0 | 0.0 | 824 |
| tail | baseline | 60 | 91 | 131 | 551 | 4,359,705 | 15 | 15 | 16.0 | 1,401 |
| tail | regions | 80 | 111 | 120 | 632 | 94,459 | 0 | 0 | 0.0 | 1,558 |
<!-- /table -->

![M3 on trusted](results/plots/trusted/tail.svg)

The stock loop's longest event is 4.1 to 4.4 ms, a collection; the region
loop's is 97 µs on `checked` and 94 on `trusted`, and the pooled
yardstick's, which allocates nothing, is 92. That maximum is the machine's,
not the runtime's:
a bare loop of ten million rounds of a window, a hundred allocations and an
unchecked reset has a worst round of 3.5 µs on the same core, and the paced
loop and the real-world matrix below stay under 15 µs; a loop that never
touches the allocator meets the same 90 µs about once in twenty million
events, three seconds of wall time, which is a stall of the core (the
kernel command line carries no `nohz_full`, so the isolated core still
takes its tick and its housekeeping). A run with the event queue as a
binary heap that never reallocates, on 2026-09-24, read the same maximum
in every row and ten nanoseconds more per event, which put the queue out
of the question.

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
| recording, W=200 | stock, own heuristics | 6.5 M | 81 | 391 | 762 | 3,348,376 | 3,348,376 | 325 | 1,657 |
| recording, W=200 | stock, program schedule | 6.6 M | 71 | 381 | 932 | 3,173,476 | 3,173,476 | 366 | 1,657 |
| recording, W=200 | regions, census | 14.0 M | 50 | 80 | 171 | 56,346 | 56,346 | — | 1,618 |
| recording, W=200 | regions, no census | 14.4 M | 50 | 80 | 291 | 15,139 | 15,139 | — | 1,618 |
| light, W=3 | stock, own heuristics | 16.7 M | 40 | 50 | 241 | 3,640,437 | 3,640,437 | 37 | 1,674 |
| light, W=3 | stock, program schedule | 16.4 M | 40 | 50 | 171 | 3,078,267 | 3,078,267 | 51 | 1,657 |
| light, W=3 | regions, census | 16.0 M | 40 | 51 | 120 | 52,219 | 52,219 | — | 1,618 |
| light, W=3 | regions, no census | 16.2 M | 40 | 51 | 270 | 12,553 | 12,553 | — | 1,618 |
<!-- /table -->

![M4 on checked](results/plots/checked/latency_ccdf.svg)

The stock collector's longest event is 3.3 to 3.7 ms; the regions' is 50 µs
with the census, exactly at a census boundary, and 10 to 14.5 µs without it.

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
| baseline | 1,000,000 | 80 | 4,674,588 | 686 | 4,674,637 | 52 | 1 | 4.6 |
| regions | 1,000,000 | 90 | 6,783 | 250 | 47,481 | 0 | 0 | 0.0 |
| regions | 1,000,000 | 100 | 8,286 | 343 | 8,570 | 0 | 0 | 0.0 |
<!-- /table -->

![M6-paced on checked](results/plots/checked/paced.svg)

<!-- table M6-paced run=trusted -->
| variant | events | latency p50 (ns) | latency max (ns) | lateness p99.9 (ns) | lateness max (ns) | slot misses | GC events | GC (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | 1,000,000 | 70 | 4,951,299 | 692 | 4,951,348 | 56 | 1 | 4.9 |
| regions | 1,000,000 | 90 | 6,241 | 255 | 8,620 | 0 | 0 | 0.0 |
| regions | 1,000,000 | 81 | 5,491 | 797 | 66,921 | 0 | 0 | 0.0 |
<!-- /table -->

![M6-paced on trusted](results/plots/trusted/paced.svg)

The stock loop completes an event 4.7 to 5.0 ms late at worst and misses 52
to 56 slots of a million; the region loop completes every event within
6.8 µs on `checked` and 6.2 µs on `trusted` and misses none.

[`bench/endurance.jl`](bench/endurance.jl) runs eighteen million events
over thirty minutes with one sample per hundred thousand:

<!-- table M6-endurance run=checked -->
| endurance | value |
| --- | --- |
| samples (one per 100 000 events) | 180 |
| events | 18,000,000 |
| wall (s) | 1,800 |
| RSS at the first sample (MB) | 333.46 |
| RSS at the last sample (MB) | 333.46 |
| RSS max (MB) | 333.46 |
| allocated through the region, first to last sample (MB) | 525 |
| slot misses | 0 |
<!-- /table -->

![M6-endurance on checked](results/plots/checked/endurance.svg)

The RSS is 333 MB at the first sample and at the last, on both builds, with
525 MB allocated through the region between them.

### M7 — Against the C++ program

**Claim.** A model written for regions, a packet allocated at send and
dropped at delivery, runs within a small factor of the same model in C++
with `new` and `delete` per event, and the census keeps its memory flat.

[`bench/native.jl`](bench/native.jl) and [`bench/native.cpp`](bench/native.cpp),
five million events, a census every hundred thousand:

<!-- table M7 run=checked -->
| variant | W | events/s | censuses | census p50 (µs) | census max (µs) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- |
| region | 3 | 59.0 M | 50 | 3.3 | 9.3 | 281.1 |
| stock | 3 | 60.1 M | — | — | — | 270.2 |
| cpp | 3 | 67.2 M | — | — | — | 3.9 |
| region | 200 | 31.1 M | 50 | 12.2 | 16.5 | 303.6 |
| stock | 200 | 25.7 M | — | — | — | 295.3 |
| cpp | 200 | 37.6 M | — | — | — | 3.8 |
<!-- /table -->

![M7 on checked](results/plots/checked/native.svg)

<!-- table M7 run=trusted -->
| variant | W | events/s | censuses | census p50 (µs) | census max (µs) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- |
| region | 3 | 84.2 M | 50 | 3.1 | 8.6 | 280.1 |
| stock | 3 | 61.7 M | — | — | — | 270.1 |
| cpp | 3 | 69.3 M | — | — | — | 3.9 |
| region | 200 | 35.0 M | 50 | 10.8 | 15.8 | 303.7 |
| stock | 200 | 26.8 M | — | — | — | 269.8 |
| cpp | 200 | 35.6 M | — | — | — | 3.9 |
<!-- /table -->

![M7 on trusted](results/plots/trusted/native.svg)

At the heavy weight the region loop runs at 0.83 of the C++ program on
`checked` and 0.98 on `trusted`, against 0.68 to 0.75 for the stock loop;
at the light weight `trusted` runs faster than the C++ program.

### M8 — Wholesale death

**Claim.** When a whole structure dies at once, a reset frees it without a
collection.

<!-- table M8 run=checked -->
| showcase | mode | wall (s) | collections | GC (ms) | peak RSS (MB) | rounds |
| --- | --- | --- | --- | --- | --- | --- |
| binarytree | stock | 0.377 | 31 | 81.5 | 266 | 3 |
| binarytree | regions | 0.341 | 0 | 0.0 | 266 | 3 |
| linkedlist | stock | 2.240 | 10 | 1711.4 | 2,404 | 3 |
| linkedlist | regions | 0.630 | 0 | 0.0 | 2,412 | 3 |
| tree | stock | 0.008 | 6 | 0.9 | — | 3 |
| tree | regions | 0.006 | 0 | 0.0 | — | 3 |
<!-- /table -->

![M8 on checked](results/plots/checked/showcase.svg)

<!-- table M8 run=trusted -->
| showcase | mode | wall (s) | collections | GC (ms) | peak RSS (MB) | rounds |
| --- | --- | --- | --- | --- | --- | --- |
| binarytree | stock | 0.361 | 31 | 81.2 | 266 | 3 |
| binarytree | regions | 0.263 | 0 | 0.0 | 267 | 3 |
| linkedlist | stock | 2.234 | 10 | 1708.1 | 2,382 | 3 |
| linkedlist | regions | 0.532 | 0 | 0.0 | 2,391 | 3 |
| tree | stock | 0.007 | 6 | 0.8 | — | 3 |
| tree | regions | 0.004 | 0 | 0.0 | — | 3 |
<!-- /table -->

![M8 on trusted](results/plots/trusted/showcase.svg)

The linked list, which the stock collector traces ten times for 1.7 s,
runs in 0.63 s on `checked` and 0.53 s on `trusted` with no collection, at
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
| B | small | 1 | 13.2 | 13.4 | 0.98 | 0 | 0 | 0.0 | 0.0 |
| B | medium | 1 | 38.9 | 38.6 | 1.01 | 2 | 0 | 0.3 | 0.0 |
| B | large | 1 | 103.0 | 101.8 | 1.01 | 7 | 0 | 0.9 | 0.0 |
| D | work=0 | 1 | 97.1 | 95.0 | 1.02 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 1 | 105.2 | 97.8 | 1.08 | 2 | 0 | 2.3 | 0.0 |
| D | work=2048 | 1 | 96.2 | 101.1 | 0.95 | 14 | 0 | 5.5 | 0.0 |
| B | small | 2 | 10.9 | 10.8 | 1.00 | 1 | 0 | 0.1 | 0.0 |
| B | medium | 2 | 30.6 | 30.6 | 1.00 | 3 | 0 | 0.3 | 0.0 |
| B | large | 2 | 81.0 | 79.1 | 1.02 | 8 | 0 | 0.8 | 0.0 |
| D | work=0 | 2 | 61.5 | 60.1 | 1.02 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 2 | 60.0 | 61.7 | 0.97 | 3 | 0 | 2.7 | 0.0 |
| D | work=2048 | 2 | 71.4 | 61.4 | 1.16 | 17 | 0 | 8.0 | 0.0 |
| B | small | 4 | 5.7 | 6.2 | 0.92 | 1 | 0 | 0.1 | 0.0 |
| B | medium | 4 | 16.7 | 16.6 | 1.01 | 3 | 0 | 0.4 | 0.0 |
| B | large | 4 | 44.3 | 43.1 | 1.03 | 8 | 0 | 0.9 | 0.0 |
| D | work=0 | 4 | 40.8 | 40.3 | 1.01 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 4 | 41.9 | 40.9 | 1.02 | 4 | 0 | 3.2 | 0.0 |
| D | work=2048 | 4 | 49.2 | 42.0 | 1.17 | 23 | 0 | 8.0 | 0.0 |
| B | small | 8 | 3.6 | 4.0 | 0.91 | 1 | 0 | 0.2 | 0.0 |
| B | medium | 8 | 10.4 | 10.3 | 1.00 | 3 | 0 | 0.4 | 0.0 |
| B | large | 8 | 27.1 | 26.1 | 1.04 | 8 | 0 | 1.1 | 0.0 |
| D | work=0 | 8 | 27.9 | 25.5 | 1.09 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 8 | 27.2 | 26.1 | 1.04 | 4 | 0 | 2.1 | 0.0 |
| D | work=2048 | 8 | 40.2 | 27.2 | 1.48 | 24 | 0 | 8.2 | 0.0 |
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
| scoped | 300 | 6.5 | 44.7 | 3.1 | 3.7 | 1.1 | 302 | 100,515 |
| coop | 300 | 2.9 | 20.1 | 0.1 | 2.9 | 1.3 | 302 | 100,515 |
| full | 300 | 2078.0 | 7104.8 | — | — | — | — | — |
| scoped | 1,000 | 7.7 | 47.2 | 2.7 | 4.8 | 1.3 | 1,002 | 100,550 |
| coop | 1,000 | 4.7 | 24.2 | 0.1 | 4.6 | 1.7 | 1,002 | 100,550 |
| full | 1,000 | 1881.5 | 5620.1 | — | — | — | — | — |
| scoped | 3,000 | 13.5 | 49.9 | 2.9 | 9.2 | 2.1 | 3,002 | 100,650 |
| coop | 3,000 | 10.6 | 27.3 | 0.1 | 9.4 | 2.1 | 3,002 | 100,650 |
| full | 3,000 | 2189.6 | 6579.6 | — | — | — | — | — |
| scoped | 10,000 | 34.2 | 77.3 | 3.4 | 27.1 | 4.9 | 10,002 | 101,000 |
| coop | 10,000 | 30.4 | 45.9 | 0.1 | 26.3 | 4.8 | 10,002 | 101,000 |
| full | 10,000 | 2391.6 | 6828.8 | — | — | — | — | — |
| scoped | 30,000 | 92.7 | 135.4 | 3.3 | 77.3 | 13.0 | 30,002 | 102,000 |
| coop | 30,000 | 88.6 | 109.7 | 0.1 | 76.6 | 12.9 | 30,002 | 102,000 |
| full | 30,000 | 3111.4 | 7841.0 | — | — | — | — | — |
| scoped | 100,000 | 301.1 | 429.8 | 3.3 | 263.6 | 46.8 | 100,002 | 105,500 |
| coop | 100,000 | 277.3 | 327.7 | 0.1 | 238.0 | 44.0 | 100,002 | 105,500 |
| full | 100,000 | 5413.0 | 10497.1 | — | — | — | — | — |
<!-- /table -->

![M5-pause on checked](results/plots/checked/census_pause.svg)

<!-- table M5-throughput run=checked -->
| variant | W | B | events/s | collections | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- |
| autopool | 3 | 1 | 52.2 M | 0 | 1,049 |
| batch | 3 | 1 | 23.2 M | 0 | 1,049 |
| batch | 3 | 100 | 54.1 M | 0 | 1,049 |
| batch | 3 | 1000 | 54.5 M | 0 | 1,049 |
| pooled | 3 | 1 | 26.7 M | 50 | 1,049 |
| autopool | 200 | 1 | 10.9 M | 0 | 1,049 |
| batch | 200 | 1 | 20.1 M | 0 | 1,049 |
| batch | 200 | 100 | 39.4 M | 0 | 1,049 |
| batch | 200 | 1000 | 36.9 M | 0 | 1,049 |
| pooled | 200 | 1 | 22.8 M | 50 | 1,049 |
<!-- /table -->

![M5-throughput on checked](results/plots/checked/census_throughput.svg)

A census of a region with 300 live records pauses 6.5 µs at the median,
stop the world, and 2.9 µs cooperative; a full stock collection of the same
heap 2.1 ms. With 30,000 live records the census pauses 93 µs.

### M10 — The demonstrators

**Claim.** On four algorithms the same code runs under regions and under
the stock collector; regions remove the collections in every case and win
on wall time where the discarded allocation per unit of work is large.

<!-- table M10 run=checked -->
| demo | point | threads | wall stock (ms) | wall regions (ms) | stock / regions | collections stock | collections regions | GC stock (ms) | GC regions (ms) | peak RSS stock (MB) | peak RSS regions (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | small (1500 instances, n=30, K=3) | 1 | 150.3 | 141.4 | 1.06 | 12 | 0 | 7.0 | 0.0 | 308 | 307 |
| A | medium (3000 instances, n=32, K=3) | 1 | 314.7 | 298.1 | 1.06 | 24 | 0 | 13.5 | 0.0 | 314 | 311 |
| A | large (5000 instances, n=34, K=3) | 1 | 562.6 | 531.2 | 1.06 | 42 | 0 | 23.7 | 0.0 | 315 | 315 |
| B | small (160x100, 8 spp, depth 8, 4 threads) | 4 | 5.9 | 6.1 | 0.98 | 1 | 0 | 0.2 | 0.0 | 315 | 313 |
| B | medium (160x100, 24 spp, depth 8, 4 threads) | 4 | 16.7 | 16.5 | 1.01 | 3 | 0 | 0.3 | 0.0 | 317 | 317 |
| B | large (160x100, 64 spp, depth 8, 4 threads) | 4 | 44.1 | 42.9 | 1.03 | 8 | 0 | 0.9 | 0.0 | 317 | 317 |
| C | work=0 (80000 keys, work=0, 4 threads) | 4 | 28.9 | 64.2 | 0.45 | 5 | 4 | 4.6 | 4.5 | 394 | 357 |
| C | work=64 (80000 keys, work=64, 4 threads) | 4 | 80.9 | 98.7 | 0.82 | 22 | 5 | 24.0 | 5.5 | 406 | 406 |
| C | work=256 (80000 keys, work=256, 4 threads) | 4 | 267.2 | 183.2 | 1.46 | 37 | 0 | 98.0 | 0.0 | 578 | 578 |
| C | work=1024 (80000 keys, work=1024, 4 threads) | 4 | 833.8 | 467.2 | 1.78 | 131 | 2 | 297.9 | 3.7 | 650 | 650 |
| D | work=0 (grid 16, work=0, 4 threads) | 4 | 37.3 | 37.0 | 1.01 | 0 | 0 | 0.0 | 0.0 | 316 | 315 |
| D | work=512 (grid 16, work=512, 4 threads) | 4 | 39.4 | 38.3 | 1.03 | 4 | 0 | 2.8 | 0.0 | 326 | 326 |
| D | work=2048 (grid 16, work=2048, 4 threads) | 4 | 46.1 | 38.7 | 1.19 | 26 | 0 | 8.1 | 0.0 | 331 | 326 |
<!-- /table -->

![M10 on checked](results/plots/checked/demo_a.svg)

![M10 demo_b on checked](results/plots/checked/demo_b.svg)

![M10 demo_c on checked](results/plots/checked/demo_c.svg)

![M10 demo_d on checked](results/plots/checked/demo_d.svg)

![M10 demo_rss on checked](results/plots/checked/demo_rss.svg)

The speculative tree (C) is the crossover: 0.45 of the stock speed with no
work per transaction, 1.78 with 1,024 units of it.

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

- The store's guard costs 0.045 ns instead of 0.085: master's write barrier
  is field-aware now and the guard sits inside it.
- The full parallel collection costs 6 to 8 % more at thirty threads, where
  it cost 7 % at thirty-two; the probe build says that the mark's census
  filter is about half of it.
- The checked reset costs 27 µs alone, as before; the unchecked one 30 ns.
- The paced loop's worst completion is 6 to 9 µs where it was 5.6 µs, on a
  partition made at run time rather than at boot.
- Against the C++ program the region loop runs at 0.83 with the barrier
  and 0.98 without it, where it ran at 0.85.
- The system image grows 9.2 % with the barrier built, where it grew 3.4 %;
  without the barrier it grows 3.0 %.
