# The cost of regions that a program does not use

A julia built with `WITH_GC_REGIONS=1`, on a program that never opens a
window, runs the stock collector with a few hooks in it. This document says
what such a program pays, in memory and in time, and which build option
takes which part out. Every number was measured on 2026-10-10 on the tree
of the pull request's tip `f3b83d5555`, on master `b883b468f0`, which the
fix round of 2026-10-11 and the rebases onto master `df8b6ac5c2` and then
`7e178224d3` followed without a change on a measured path; the method, the machine and the five
builds are those of
[`MEASUREMENTS.md`](MEASUREMENTS.md), whose E2 section holds the same tables.
[`results/tables.py`](results/tables.py) writes the tables of both documents
from the data files under [`results/data/`](results/data).

The builds compared: **base**, master plus the three independent commits,
which is what the flag-less build of the pull request compiles to;
**checked**, the regions with their escape barrier, the default of the flag;
**trusted**, the regions without the barrier (`WITH_GC_REGION_BARRIER=0`);
**probe**, the regions compiled but unusable (`-DJL_NO_REGION_ALLOC`), a
build that isolates the cost of the code the probe keeps, not one anyone
uses.

## What the cost is made of

1. **A static cost, once per process.** More code in the runtime, and a
   larger system image: with the barrier built, every managed pointer
   store of compiled Julia code carries a guard, one load of a byte and
   one predicted branch, and the guard has a cold block behind it.
2. **A structural cost, per thread and per pool page.** A few hundred bytes
   in each thread heap, and eight bytes more in the metadata of each 16 KB
   pool page. Nothing per object and nothing per task. No heap memory is
   allocated for regions until a first window opens: the region table of a
   thread heap is 64 `NULL` pointers until then.
3. **A dynamic cost, per operation.** The guard on each pointer store and
   on each construction of an object with boxed children; one load and one
   add on each pool allocation, which reach the pool of the current region
   where base adds a constant; one read of the census filter per claim in
   the mark loop; a page test in the sweep and a corpse test in the mark.
   Each is a fraction of a nanosecond.

## Memory

The sizes come from `sizeof` in a C program compiled against the headers of
the two builds, and from `size` on the installed binaries
([`results/text_sizes.sh`](results/text_sizes.sh), `data/text.tsv`); they do
not depend on the machine's load.

| item | base | checked | delta |
| --- | --- | --- | --- |
| thread heap struct, `jl_thread_heap_t` | 1,496 B | 2,104 B | +608 B per thread: the region table (512 B), the pool pointer, the three region bytes, the two masks and the child counts |
| task struct, `jl_task_t` | 280 B | 280 B | 0: the two region bytes sit in existing padding |
| page metadata, `jl_gc_pagemeta_t` | 40 B | 48 B | +8 B per 16 KB page: the tag and the chain pointer; 512 KB on a 1 GB pool heap |
| region state on the heap | — | 0 B | 64 `NULL` pointers until a first window; about 1.5 KB per region a heap then uses |

<!-- table E2-text -->
| build | libjulia-internal text (bytes) | against base | sys.so text (bytes) | against base |
| --- | --- | --- | --- | --- |
| master | 2,752,636 | -0.01 % | 24,288,857 | +0.00 % |
| base | 2,752,853 | +0.00 % | 24,288,361 | +0.00 % |
| checked | 2,809,200 | +2.05 % | 26,208,021 | +7.90 % |
| trusted | 2,776,411 | +0.86 % | 24,755,921 | +1.93 % |
| probe | 2,807,288 | +1.98 % | 26,210,213 | +7.91 % |
<!-- /table -->

The system image is the larger item: 7.9 % more text with the barrier
built, 1.9 % without it. The difference between the two is the guard at
every barrier site of the compiled code of Base; the 1.9 % is the region
runtime and the hooks.

## Time

Every cell below is the paired difference or ratio "the region build with
no window open against base", over ten rounds, the machine idle, from
[`MEASUREMENTS.md`](MEASUREMENTS.md) E2.

**The unit costs.** The store costs its guard, 0.044 ns, and nothing at all
without the barrier. A pool allocation costs 0.16 ns with everything built,
0.12 without the barrier and 0.09 in the probe, whose allocator is base's:
the allocator's own share is a few hundredths of a nanosecond, one load and
one add, and the region code around an allocation is the rest; a
constructor of two boxed fields pays two allocations and one guard. The
serial mark costs 1.1 to 1.2 ms of 67, the census filter in the claim, and
nothing when the filter is folded.

<!-- table E2-unit-attribution -->
| cost | unit | regions built, barrier built − base | regions built, no barrier − base | regions built, allocator and filter off − base |
| --- | --- | --- | --- | --- |
| store_disarmed | ns/store | 0.0436 [0.0407, 0.048], sign 0.002 | -0.00015 [-0.0011, 0.00105], sign 0.75 | 0.0419 [0.0392, 0.0452], sign 0.002 |
| alloc_stock | ns/object | 0.163 [0.154, 0.178], sign 0.002 | 0.117 [0.104, 0.127], sign 0.021 | 0.0935 [0.091, 0.103], sign 0.002 |
| construct_two | ns/object | 0.434 [0.371, 0.527], sign 0.002 | 0.33 [0.29, 0.373], sign 0.002 | 0.22 [0.15, 0.519], sign 0.002 |
| box_twin | ns/object | 0.336 [0.319, 0.412], sign 0.002 | 0.121 [0.076, 0.161], sign 0.002 | 0.353 [0.272, 0.38], sign 0.002 |
| stock_mark | ms/collection | 1.12 [0.8, 1.61], sign 0.002 | 1.19 [0.8, 1.49], sign 0.021 | -0.05 [-0.295, 0.54], sign 1 |
<!-- /table -->

**The parallel collection.** A full collection of the same heap, at 1 to 30
threads. The cost grows with the thread count: 1 to 2 % at one thread, 7 %
at thirty, with or without the barrier; the probe, which folds the census
filter, costs 3 % at thirty. So 4 points of the thirty-thread cost are the
census filter in the mark loop and 3 are the collector's other checks.
This is the number a reviewer will question first, and it is the one the
regions have not yet reduced.

<!-- table E2-parallel-attribution -->
| threads | regions built, barrier built / base [95 %] | regions built, no barrier / base [95 %] | regions built, allocator and filter off / base [95 %] |
| --- | --- | --- | --- |
| 1 | 1.01 [1.01, 1.02] | 1.02 [1.01, 1.02] | 0.993 [0.984, 0.997] |
| 4 | 1.02 [1.01, 1.02] | 1.02 [1.01, 1.02] | 0.999 [0.995, 1] |
| 8 | 1.03 [0.997, 1.06] | 1.03 [0.992, 1.06] | 0.984 [0.96, 1.01] |
| 16 | 1.03 [0.994, 1.05] | 1.03 [1.01, 1.05] | 1.02 [0.996, 1.06] |
| 30 | 1.07 [1.06, 1.09] | 1.07 [1.04, 1.09] | 1.03 [1.02, 1.05] |
<!-- /table -->

**After the first window.** The costs above are those of a process that
never opens a window. Once a window has opened, the escape barrier is
armed for the rest of the process: every store of a boxed child pays the
page lookup of the child, and a constructor of boxed fields pays it per
field. The table is the paired difference "the same binary after one
window against the same binary with no window"; the store row is the
armed copy loop against the disarmed one. Without the barrier there is no
armed state, and the column shows it.

<!-- table E2-armed -->
| cost | unit | armed − no window, barrier built | armed − no window, no barrier |
| --- | --- | --- | --- |
| alloc_stock | ns/object | 1.09 [1.08, 1.1], sign 0.002 | 0.0105 [0.0015, 0.056], sign 0.11 |
| construct_two | ns/object | 2.12 [2.03, 2.16], sign 0.002 | 0.0775 [0.033, 0.092], sign 0.039 |
| construct_shared | ns/object | 2.39 [2.36, 2.44], sign 0.002 | -0.001 [-0.023, 0.02], sign 1 |
| box_twin | ns/object | 1.95 [1.89, 2.03], sign 0.002 | 0.004 [-0.019, 0.036], sign 0.75 |
| finalizer_register | ns/object | 1.08 [1, 1.14], sign 0.002 | 0.0215 [-0.048, 0.111], sign 0.75 |
| store | ns/store | 1.06 [1.05, 1.06], sign 0.002 | -0.00095 [-0.0013, 0.0003], sign 0.34 |
<!-- /table -->

**The GC benchmark suite.** Eleven benchmarks of GCBenchmarks, six on one
thread and five on four, ten paired rounds; the cell is the ratio of the
minima over the rounds, region build over base. Three of the eleven abort
under the 16 GB cap on every binary alike, master's included, and have no
row. Six of the eight are within 1 % on the build with the barrier;
`many_refs`, which allocates large arrays of references, pays 2 % with the
barrier, 3 % without it and 1 % in the probe; `pollard` pays 4 % with the
barrier and 3 % without it and in the probe. pollard is bound by the
collector and by the malloc of its BigInt limbs, and five paired runs with
the collector's counters, on core 28, say what the gap is: every binary does
ten collections over the same allocation volume within 4 KB, and the region
builds spend 12 of the 27 ms more in the collector, in the mark and the
sweep of the finalizer list that every BigInt joins; the rest is the
mutator's, 5.6 % more instructions and 3.9 % more cycles, in the
registration of the finalizer and in the counted malloc of the limbs. The
early return of the finalizer hook, the census filter and the inlining of
the mark-bit functions were each built and measured as the cause on the
September tree, and pollard did not move under any of them.

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

## The options and what each takes out

| build | store | pool allocation | serial mark | full collection at 30 threads | system image text |
| --- | --- | --- | --- | --- | --- |
| `WITH_GC_REGIONS=0`, the default | base | base | base | base | base |
| `WITH_GC_REGIONS=1` | +0.044 ns | +0.16 ns | +1.7 % | +7 % | +7.9 % |
| `WITH_GC_REGIONS=1 WITH_GC_REGION_BARRIER=0` | +0 | +0.12 ns | +1.8 % | +7 % | +1.9 % |

The barrier option removes the store's cost and three quarters of the image
growth; it does not touch the collector's cost, which is the census filter
and the page and corpse tests. A program that never uses regions and wants
none of it builds without the flag, and gets the code of base, object for
object.
