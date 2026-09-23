# The cost of regions that a program does not use

A julia built with `WITH_GC_REGIONS=1`, on a program that never opens a
window, runs the stock collector with a few hooks in it. This document says
what such a program pays, in memory and in time, and which build option
takes which part out. Every number was measured on 2026-09-23 on the master
line; the method, the machine and the five builds are those of
[`MEASUREMENTS.md`](MEASUREMENTS.md), whose E2 section holds the same tables.
[`results/tables.py`](results/tables.py) writes the tables of both documents
from the data files under [`results/data/`](results/data).

The builds compared: **base**, master plus the two independent commits,
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
   on each construction of an object with boxed children; the region's
   pool array behind one pointer on each pool allocation; one read of the
   census filter per claim in the mark loop; a page test in the sweep and
   a corpse test in the mark. Each is a fraction of a nanosecond.

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
| master | 2,752,678 | -0.05 % | 24,147,941 | +0.00 % |
| base | 2,753,991 | +0.00 % | 24,147,293 | +0.00 % |
| checked | 2,810,546 | +2.05 % | 26,288,113 | +8.87 % |
| trusted | 2,777,325 | +0.85 % | 24,806,545 | +2.73 % |
| probe | 2,808,538 | +1.98 % | 26,287,561 | +8.86 % |
<!-- /table -->

The system image is the larger item: 8.9 % more text with the barrier
built, 2.7 % without it. The difference between the two is the guard at
every barrier site of the compiled code of Base; the 2.7 % is the region
runtime and the hooks.

## Time

Every cell below is the paired difference or ratio "the region build with
no window open against base", over ten rounds, the machine idle, from
[`MEASUREMENTS.md`](MEASUREMENTS.md) E2.

**The unit costs.** The store costs its guard, 0.045 ns, and nothing at all
without the barrier. A pool allocation costs 0.34 ns with everything built,
of which the allocator's indirection is about 0.17 and the region code
around an allocation the rest; a constructor of two boxed fields pays two
allocations and one guard. The serial mark costs 0.9 to 1.1 ms of 65, the
census filter in the claim, and nothing when the filter is folded.

<!-- table E2-unit-attribution -->
| cost | unit | regions built, barrier built − base | regions built, no barrier − base | regions built, allocator and filter off − base |
| --- | --- | --- | --- | --- |
| store_disarmed | ns/store | 0.0446 [0.0407, 0.054], sign 0.002 | 0.00035 [-0.0121, 0.0035], sign 1 | 0.0426 [0.0373, 0.0434], sign 0.002 |
| alloc_stock | ns/object | 0.343 [0.331, 0.353], sign 0.002 | 0.263 [0.257, 0.273], sign 0.002 | 0.098 [0.0815, 0.113], sign 0.002 |
| construct_two | ns/object | 0.678 [0.604, 0.775], sign 0.002 | 0.588 [0.559, 0.64], sign 0.002 | 0.208 [0.141, 0.281], sign 0.002 |
| box_twin | ns/object | 0.672 [0.636, 0.688], sign 0.002 | 0.402 [0.354, 0.433], sign 0.002 | 0.514 [0.462, 0.544], sign 0.002 |
| stock_mark | ms/collection | 0.895 [0.325, 1.31], sign 0.021 | 1.1 [0.69, 1.57], sign 0.002 | -0.045 [-0.19, 0.31], sign 0.75 |
<!-- /table -->

**The parallel collection.** A full collection of the same heap, at 1 to 30
threads. The cost grows with the thread count: 1 % at one thread, 8 to 9 %
at thirty, with or without the barrier; the probe, which folds the census
filter, costs 3 % at thirty. So 5 to 6 points of the thirty-thread cost are
the census filter in the mark loop and 3 are the collector's other checks.
This is the number a reviewer will question first, and it is the one the
regions have not yet reduced.

<!-- table E2-parallel-attribution -->
| threads | regions built, barrier built / base [95 %] | regions built, no barrier / base [95 %] | regions built, allocator and filter off / base [95 %] |
| --- | --- | --- | --- |
| 1 | 1.01 [0.996, 1.02] | 1.01 [1, 1.02] | 0.991 [0.983, 1] |
| 4 | 1.02 [1.01, 1.02] | 1.02 [1.02, 1.02] | 0.992 [0.985, 0.999] |
| 8 | 1.02 [1, 1.05] | 1.03 [0.981, 1.05] | 1.01 [1, 1.05] |
| 16 | 1.05 [1.04, 1.08] | 1.03 [0.999, 1.11] | 1.02 [0.987, 1.03] |
| 30 | 1.08 [1.05, 1.11] | 1.09 [1.05, 1.11] | 1.03 [1.02, 1.06] |
<!-- /table -->

**The GC benchmark suite.** Eleven benchmarks of GCBenchmarks, six on one
thread and five on four, ten paired rounds; the cell is the ratio of the
minima over the rounds, region build over base.

<!-- table M1 run=checked -->
| benchmark | threads | vanilla (s) | regions (s) | regions / vanilla [95 %] | rounds |
| --- | --- | --- | --- | --- | --- |
| append | 1 | 0.829 | 0.785 | 0.949 [0.899, 0.998] | 2 |
| tree | 1 | 9.061 | 9.063 | 1.01 [0.987, 1.02] | 5 |
| strings | 1 | 19.338 | 18.903 | 1 [0.961, 1.01] | 5 |
| pollard | 1 | 0.664 | 0.698 | 1.06 [1.04, 1.07] | 5 |
| single_ref | 1 | 0.277 | 0.276 | 0.998 [0.919, 1.01] | 5 |
| many_refs | 1 | 1.743 | 1.797 | 1.03 [1.03, 1.04] | 5 |
| mergesort_parallel | 4 | 1.732 | 1.710 | 0.994 [0.957, 1.01] | 4 |
| mm_divide_and_conquer | 4 | 0.602 | 0.605 | 1.01 [1, 1.01] | 4 |
| issue-52937 | 4 | 9.470 | 9.552 | 1.01 [1, 1.01] | 4 |
<!-- /table -->

<!-- table M1 run=trusted -->
<!-- /table -->

<!-- table M1 run=probe -->
<!-- /table -->

## The options and what each takes out

| build | store | pool allocation | serial mark | full collection at 30 threads | system image text |
| --- | --- | --- | --- | --- | --- |
| `WITH_GC_REGIONS=0`, the default | base | base | base | base | base |
| `WITH_GC_REGIONS=1` | +0.045 ns | +0.34 ns | +1.4 % | +8 % | +8.9 % |
| `WITH_GC_REGIONS=1 WITH_GC_REGION_BARRIER=0` | +0 | +0.26 ns | +1.7 % | +9 % | +2.7 % |

The barrier option removes the store's cost and two thirds of the image
growth; it does not touch the collector's cost, which is the census filter
and the page and corpse tests. A program that never uses regions and wants
none of it builds without the flag, and gets the code of base, object for
object.
