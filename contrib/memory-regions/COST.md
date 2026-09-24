# The cost of regions that a program does not use

A julia built with `WITH_GC_REGIONS=1`, on a program that never opens a
window, runs the stock collector with a few hooks in it. This document says
what such a program pays, in memory and in time, and which build option
takes which part out. Every number was measured on 2026-09-25 on the master
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
| master | 2,752,678 | -0.05 % | 24,147,941 | +0.00 % |
| base | 2,753,991 | +0.00 % | 24,147,293 | +0.00 % |
| checked | 2,810,682 | +2.06 % | 26,367,269 | +9.19 % |
| trusted | 2,777,389 | +0.85 % | 24,877,329 | +3.02 % |
| probe | 2,808,674 | +1.99 % | 26,370,037 | +9.20 % |
<!-- /table -->

The system image is the larger item: 9.2 % more text with the barrier
built, 3.0 % without it. The difference between the two is the guard at
every barrier site of the compiled code of Base; the 3.0 % is the region
runtime and the hooks.

## Time

Every cell below is the paired difference or ratio "the region build with
no window open against base", over ten rounds, the machine idle, from
[`MEASUREMENTS.md`](MEASUREMENTS.md) E2.

**The unit costs.** The store costs its guard, 0.043 ns, and nothing at all
without the barrier. A pool allocation costs 0.17 ns with everything built,
0.13 without the barrier and 0.11 in the probe, whose allocator is base's:
the allocator's own share is a few hundredths of a nanosecond, one load and
one add, and the region code around an allocation is the rest; a
constructor of two boxed fields pays two allocations and one guard. The
serial mark costs 1.2 to 1.3 ms of 65, the census filter in the claim, and
nothing when the filter is folded.

<!-- table E2-unit-attribution -->
| cost | unit | regions built, barrier built − base | regions built, no barrier − base | regions built, allocator and filter off − base |
| --- | --- | --- | --- | --- |
| store_disarmed | ns/store | 0.043 [0.0396, 0.0448], sign 0.002 | -0.00045 [-0.00165, 0.00055], sign 0.34 | 0.044 [0.0425, 0.0447], sign 0.002 |
| alloc_stock | ns/object | 0.17 [0.157, 0.231], sign 0.002 | 0.13 [0.12, 0.509], sign 0.002 | 0.109 [0.092, 0.118], sign 0.002 |
| construct_two | ns/object | 0.406 [0.376, 0.432], sign 0.002 | 0.366 [0.326, 0.391], sign 0.002 | 0.197 [0.147, 0.264], sign 0.002 |
| box_twin | ns/object | 0.325 [0.29, 0.354], sign 0.002 | 0.138 [0.0825, 0.163], sign 0.002 | 0.246 [0.196, 0.304], sign 0.002 |
| stock_mark | ms/collection | 1.23 [0.825, 1.41], sign 0.021 | 1.32 [0.98, 2.01], sign 0.002 | -0.395 [-1.27, 0.09], sign 0.34 |
<!-- /table -->

**The parallel collection.** A full collection of the same heap, at 1 to 30
threads. The cost grows with the thread count: 1 to 2 % at one thread, 6 to
8 % at thirty, with or without the barrier; the probe, which folds the
census filter, costs 3 % at thirty. So 3 to 5 points of the thirty-thread
cost are the census filter in the mark loop and 3 are the collector's other
checks.
This is the number a reviewer will question first, and it is the one the
regions have not yet reduced.

<!-- table E2-parallel-attribution -->
| threads | regions built, barrier built / base [95 %] | regions built, no barrier / base [95 %] | regions built, allocator and filter off / base [95 %] |
| --- | --- | --- | --- |
| 1 | 1.01 [1, 1.02] | 1.02 [1.01, 1.02] | 0.989 [0.981, 0.996] |
| 4 | 1.02 [1.01, 1.03] | 1.02 [1.02, 1.03] | 0.99 [0.988, 0.997] |
| 8 | 0.989 [0.939, 1.05] | 1.03 [0.99, 1.05] | 1.01 [0.968, 1.05] |
| 16 | 1.04 [1.03, 1.07] | 1.05 [1.02, 1.11] | 1.02 [1, 1.05] |
| 30 | 1.06 [1.04, 1.09] | 1.08 [1.07, 1.09] | 1.03 [1.02, 1.08] |
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
| alloc_stock | ns/object | 1.07 [1.01, 1.08], sign 0.002 | 0.007 [-0.375, 0.01], sign 0.34 |
| construct_two | ns/object | 2.11 [2.05, 2.17], sign 0.002 | 0.052 [0.015, 0.091], sign 0.021 |
| construct_shared | ns/object | 2.35 [2.33, 2.4], sign 0.002 | -0.0395 [-0.0615, -0.006], sign 0.11 |
| box_twin | ns/object | 1.9 [1.86, 1.93], sign 0.002 | -0.028 [-0.056, 0.0075], sign 0.34 |
| finalizer_register | ns/object | 1.18 [1.02, 1.21], sign 0.002 | 0.006 [-0.034, 0.055], sign 1 |
| store | ns/store | 1.05 [1.04, 1.05], sign 0.002 | -0.00035 [-0.00135, 0.00025], sign 0.51 |
<!-- /table -->

**The GC benchmark suite.** Eleven benchmarks of GCBenchmarks, six on one
thread and five on four, ten paired rounds; the cell is the ratio of the
minima over the rounds, region build over base. Seven of the nine are
within 1 % on the build with the barrier; `many_refs`, which allocates
large arrays of references, pays 2 % with the barrier and without it and
nothing in the probe; `pollard` pays 7 % with the barrier, 6 % in the probe
and 12 % without the barrier in this run, where two rounds of ten fell far
off. pollard is bound by the collector and by the malloc of its BigInt
limbs, and five paired runs with the collector's counters say what the
gap is: every region build does eleven collections where base does ten,
over the same allocation volume within 11 KB, and the eleventh is about 15
of the 38 ms; the rest is 4.7 % more instructions, in the registration of
the finalizer that every BigInt carries and in the mark of the finalizer
list, and 4 % more page faults. The collector's heap target follows its
own timing, so the threshold of the eleventh collection falls differently
on a build whose mark costs a little more; the early return of the
finalizer hook, the census filter and the inlining of the mark-bit
functions were each built and measured as the cause, and none is.

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

## The options and what each takes out

| build | store | pool allocation | serial mark | full collection at 30 threads | system image text |
| --- | --- | --- | --- | --- | --- |
| `WITH_GC_REGIONS=0`, the default | base | base | base | base | base |
| `WITH_GC_REGIONS=1` | +0.043 ns | +0.17 ns | +1.9 % | +6 % | +9.2 % |
| `WITH_GC_REGIONS=1 WITH_GC_REGION_BARRIER=0` | +0 | +0.13 ns | +2.0 % | +8 % | +3.0 % |

The barrier option removes the store's cost and two thirds of the image
growth; it does not touch the collector's cost, which is the census filter
and the page and corpse tests. A program that never uses regions and wants
none of it builds without the flag, and gets the code of base, object for
object.
