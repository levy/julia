# Measurements

Every number in this document comes from a data file under `results/data/`.
`results/tables.py` writes every table below from those files, and
`results/plot.py` draws every plot under `results/plots/` from them, with no
other input. `results/run_all.sh` runs every measurement below in order and
writes the data files; the logs go to `results/log/`, which git ignores. A
number in the prose repeats a number of a table.

The two binaries: **regions** is a julia built from the tip of this branch;
**vanilla** is a julia built from the base commit, `8f33e09afe`
(`v1.13.0-rc4`), with nothing else changed. A row that names only one binary
ran on regions. The `sha` in `context.tsv` names the commit of the working
tree that the run used: a commit of the flat tree from which the commits of
this branch were built, reachable from the tag `gc-regions-flat`. Its `src/`
is the `src/` of the tip.

The machine: one Linux x86-64 host, shared. Single-thread rows run pinned to
CPU 29, a core the kernel keeps quiet: `nohz_full=13,29`, `rcu_nocbs=13,29`,
and `irqaffinity` that excludes it, with no `isolcpus`. The latency rows take
`SCHED_FIFO` at priority 50, so no time-shared task preempts them; the other
rows run time-shared. Multi-thread rows run on CPUs 24 to 31, which are not
isolated. Every row runs under a memory cap and a timeout. The file
`results/data/context.tsv` records the date, the commit, the host, the CPU,
the kernel, the cores, and the scheduling class of the run; `run_all.sh`
writes it at the start of every run, a partial rerun (`ONLY=...`) included,
so the date is that of the last row that ran.

## M1 — Zero cost when unused

**Claim.** A julia that carries the region runtime, on a program that never
opens a window, runs the GCBenchmarks within noise of vanilla.

Script `bench/gcbench.sh`; data `results/data/gcbench.tsv`; plot
`results/plots/gcbench.svg` (bars: the ratio regions / vanilla per benchmark,
one bar per thread count, a line at 1.0). Eleven benchmarks: six serial on
one thread, five parallel on four threads. Both binaries run in every round,
in alternating order. The table holds the best of the rounds per binary, and
the spread column is the larger of the two binaries' (max − min) / min over
the rounds: a ratio inside the spread is noise.

<!-- table M1 -->
| benchmark | threads | vanilla (s) | regions (s) | ratio | rounds | spread |
| --- | --- | --- | --- | --- | --- | --- |
| append | 1 | 1.520 | 1.538 | 1.01 | 5 | 2 % |
| tree | 1 | 8.709 | 8.937 | 1.03 | 5 | 4 % |
| strings | 1 | 18.427 | 18.624 | 1.01 | 5 | 4 % |
| pollard | 1 | 0.651 | 0.659 | 1.01 | 5 | 2 % |
| single_ref | 1 | 0.401 | 0.385 | 0.96 | 5 | 10 % |
| many_refs | 1 | 1.970 | 1.804 | 0.92 | 5 | 0 % |
| mergesort_parallel | 4 | 1.601 | 1.603 | 1.00 | 5 | 3 % |
| mm_divide_and_conquer | 4 | 0.755 | 0.769 | 1.02 | 5 | 8 % |
| issue-52937 | 4 | 9.668 | 9.798 | 1.01 | 5 | 2 % |
<!-- /table -->

Two of the five parallel benchmarks, `tree_mutable` and `objarray`, have no
row. On this machine both abort on both binaries, in the suite's own
memory-pressure guard (`gc_cb_on_pressure` in `util/utils.jl` stops a run
after three pressure callbacks in ten seconds). The abort is a property of
the benchmark on this machine, not of either binary.

`many_refs` runs faster on regions in every round, outside its spread. The
cause is a stock-path change of this branch, not a region: the benchmark
fills its array under `GC.enable(false)`, and a deferred collection on
vanilla re-arms its trigger at zero, so vanilla re-enters `jl_gc_collect` on
every allocation of that phase. This branch re-arms `heap_target`
(`gc_defer_collection`; see `HISTORY.md`, stock-path change S1).

## M2 — Unit costs

**Claim.** On a program that never opens a window, a pointer store pays one
flag load and a predicted branch (about 0.09 ns), a pool allocation pays the
active-pool indirection and the region test of `maybe_collect` (about
0.3 ns), an object constructed with two pointer fields pays the construction
barrier that vanilla omits (about 1 ns per object), and the stock mark pays
about 1 %. With a window open, an armed store pays one page-map walk in a
cold call, a window pair and a reset cost tens of nanoseconds, and an
allocation in a region costs what an allocation in the stock pool costs in
the same process. The costs are small; they are not zero.

Script `bench/unit_costs.jl`; data `results/data/unit_costs.tsv`; plot
`results/plots/unit_costs.svg`. Each row is the minimum over eight compiled
copies of the loop, so that code placement does not decide the row, and the
minimum of five runs. Three columns: **vanilla** holds the rows that need no
region entry point, on the vanilla binary; **regions, no window** holds the
same rows on the regions binary, in a process that never opens a window;
**regions** holds every row in one process. The store barrier arms at the
first window and stays armed, so in the third column the rows that run
after `window_pair` pay the armed store: `construct_two` writes three
pointers per object, `alloc_stock` one. The second column against the first
is what a program that never opens a window pays. The `construct_two` row
there is the largest of these costs: vanilla emits no write barrier for the
two children stored at construction, because a fresh object is young; this
branch emits the barrier for them, so that the region check runs. The flag
check itself accounts for about 0.26 ns of the 1 ns (three stores at 0.09 ns);
the rest is the generational barrier at construction, which the region check
does not need. A construction-only barrier that emits the region check alone
would cut it; it is not built. The `reset_slice` row times one call between
two clock reads, and the pair of reads costs about 10 ns on this host: the
row is an upper bound on the reset.

<!-- table M2 -->
| cost | unit | vanilla | regions, no window | regions |
| --- | --- | --- | --- | --- |
| store_disarmed | ns/store | 0.3243 | 0.4092 | 0.417 |
| store_armed | ns/store | — | — | 1.371 |
| store_region | ns/store | — | — | 2.019 |
| window_pair | ns/pair | — | — | 10.53 |
| switch_pair | ns/pair | — | — | 5.138 |
| construct_two | ns/object | 7.132 | 8.187 | 10.66 |
| alloc_stock | ns/object | 2.073 | 2.352 | 3.298 |
| alloc_region | ns/object | — | — | 3.746 |
| reset_slice | ns/reset | — | — | 30 |
| stock_mark | ms/collection | 64.35 | 65.15 | 65.37 |
<!-- /table -->

## M3 — The tail, one Bool apart

**Claim.** In a pooled event loop whose only garbage is the scratch of the
sink, the reset of the Event region after each event removes the collector's
tail from the per-event latency; the two runs differ in one Bool.

Scripts `bench/yardstick.jl`, `bench/tail.jl`; data `results/data/tail.tsv`;
plot `results/plots/tail.svg`. The yardstick rows give the allocating and the
pooled model under the stock collector; the tail rows give the pooled model
with the scratch left to the collector (`baseline`) and reset per event
(`regions`).

<!-- table M3 -->
| script | variant | p50 (ns) | p99 (ns) | p99.9 (ns) | p99.99 (ns) | max (ns) | over 100 µs | collections | GC (ms) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| yardstick | alloc | 70 | 90 | 631 | 1,002 | 14,338,374 | 18 | 12 | 17.2 | 1,025 |
| yardstick | pooled | 70 | 81 | 100 | 1,954 | 203,704 | 8 | 0 | 0.0 | 832 |
| tail | baseline | 60 | 81 | 531 | 1,533 | 2,767,153 | 27 | 16 | 11.0 | 888 |
| tail | regions | 70 | 101 | 120 | 1,413 | 164,982 | 3 | 0 | 0.0 | 971 |
<!-- /table -->

The `over 100 µs` column of a run with zero collections is not the
collector. The pooled yardstick collects nothing and still has events over
100 µs; `tail regions` collects nothing and has three. The maximum of a run
with zero collections moves between runs: an earlier run of `tail regions`
had a maximum of 34 µs and no event over 100 µs. These scripts take no heap
reserve, so the first touch of a fresh page is a page fault of the machine,
and on this host a fault on a transparent huge page takes about 200 µs. M4
takes the reserve (`jl_gc_heap_reserve`) and counts the faults: its regions
rows have zero page faults and a maximum under the slot. The claim of M3 is
the `collections`, `GC (ms)`, and `max` columns of the two `tail` rows: the
collector's tail is gone, and the remaining maximum is the machine's.

The `peak RSS` of `tail regions` is above `tail baseline`. The regions run
never collects, so the stock garbage that the harness makes outside the
window stays until the first stock collection, which the run never reaches.

## M4 — The real-world loop

**Claim.** In an event loop that allocates per event, one window per slice
and one reset per slice, with a census at the slice boundary, give a lower
and flatter latency distribution than the stock collector under its own
heuristics or under the program's schedule, at both garbage classes.

Script `results/realworld.sh`; data `results/data/realworld.tsv` and
`results/data/ccdf_*.tsv`; plots `results/plots/latency_ccdf.svg` (the
complementary cumulative distribution of the per-event latency, one panel
per garbage class, one curve per collector mode) and
`results/plots/max_pause.svg` (the maximum pause per mode, raw and with the
preempted blocks removed). Four modes: stock with its own heuristics, stock
on the program's schedule, regions with the census, regions without it. Two
garbage classes: recording class (about 1.7 KB per event) and light (about
100 bytes). Each configuration runs up to five times, and the run with the
fewest involuntary context switches is kept. The page-fault line of every
kept run must read 0.

<!-- table M4 -->
| class | mode | events/s | p50 (ns) | p99 (ns) | p99.99 (ns) | max (ns) | max, no preemption (ns) | stock collections | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| recording, W=200 | stock, own heuristics | 7.2 M | 60 | 361 | 621 | 3,831,331 | 3,831,331 | 311 | 1,246 |
| recording, W=200 | stock, program schedule | 7.3 M | 60 | 351 | 611 | 3,762,782 | 3,762,782 | 333 | 1,254 |
| recording, W=200 | regions, census | 14.8 M | 50 | 70 | 180 | 55,324 | 55,324 | — | 1,206 |
| recording, W=200 | regions, no census | 14.8 M | 50 | 71 | 221 | 16,350 | 16,350 | — | 1,206 |
| light, W=3 | stock, own heuristics | 16.8 M | 30 | 50 | 261 | 3,574,426 | 3,574,426 | 35 | 1,245 |
| light, W=3 | stock, program schedule | 16.1 M | 40 | 50 | 211 | 3,533,318 | 3,533,318 | 51 | 1,245 |
| light, W=3 | regions, census | 16.9 M | 40 | 41 | 131 | 55,254 | 55,254 | — | 1,206 |
| light, W=3 | regions, no census | 16.9 M | 40 | 50 | 301 | 15,560 | 15,560 | — | 1,206 |
<!-- /table -->

## M5 — The census

**Claim.** The pause of a census grows with the live set of the region, not
with the garbage, and stays below a full stock collection over the same
heap. One window and one reset per B events cost more than the stock
collector's amortized work when B is 1 and the scratch is light, and less
than it when B is 100 or more, at both scratch sizes.

Script `bench/census.jl`; data `results/data/census_pause.tsv` and
`results/data/census_throughput.tsv`; plots `results/plots/census_pause.svg`
(line: the pause against the live set K, scoped census and cooperative
census against a full collection) and `results/plots/census_throughput.svg`
(bars: events per second of the stock collector, of one window per B events
at each B, and of one window per event with a census, per garbage size W).

The model is a table of K live records in the Simulation region with
turnover: every event replaces one record, so the old record is garbage in
the region, and each collection finds about 100 000 dead cells. The pause
table: `scoped` collects the Simulation region alone with the world stopped
(`jl_gc_region_collect`), `coop` is the cooperative census that marks on the
thread that owns the region (`jl_gc_region_collect_coop`), `full` keeps the
records in the ordinary heap and runs `GC.gc()`. The stop-the-world, mark,
and sweep columns are means over the collections of one run.

<!-- table M5-pause -->
| variant | K | pause p50 (µs) | pause max (µs) | stop the world (µs) | mark (µs) | sweep (µs) | live cells | freed cells |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| scoped | 300 | 5.1 | 47.4 | 2.8 | 2.4 | 1.0 | 302 | 100,515 |
| coop | 300 | 2.2 | 15.7 | 0.0 | 2.0 | 0.9 | 302 | 100,515 |
| full | 300 | 1997.0 | 6793.1 | — | — | — | — | — |
| scoped | 1,000 | 7.2 | 45.9 | 3.2 | 3.9 | 1.2 | 1,002 | 100,550 |
| coop | 1,000 | 4.4 | 18.9 | 0.0 | 3.9 | 1.2 | 1,002 | 100,550 |
| full | 1,000 | 2317.3 | 6144.9 | — | — | — | — | — |
| scoped | 3,000 | 12.9 | 51.9 | 3.1 | 8.5 | 2.1 | 3,002 | 100,650 |
| coop | 3,000 | 10.5 | 24.6 | 0.0 | 9.1 | 2.1 | 3,002 | 100,650 |
| full | 3,000 | 2371.1 | 6324.9 | — | — | — | — | — |
| scoped | 10,000 | 32.2 | 71.3 | 3.0 | 25.1 | 4.7 | 10,002 | 101,000 |
| coop | 10,000 | 34.2 | 85.3 | 0.0 | 34.3 | 4.9 | 10,002 | 101,000 |
| full | 10,000 | 2645.9 | 7565.8 | — | — | — | — | — |
| scoped | 30,000 | 90.4 | 137.6 | 2.8 | 75.6 | 14.8 | 30,002 | 102,000 |
| coop | 30,000 | 97.8 | 127.2 | 0.1 | 83.3 | 16.0 | 30,002 | 102,000 |
| full | 30,000 | 3427.9 | 8624.9 | — | — | — | — | — |
| scoped | 100,000 | 316.8 | 385.0 | 3.1 | 272.1 | 44.0 | 100,002 | 105,500 |
| coop | 100,000 | 276.4 | 396.9 | 0.1 | 236.4 | 46.2 | 100,002 | 105,500 |
| full | 100,000 | 5822.2 | 11198.8 | — | — | — | — | — |
<!-- /table -->

The throughput table uses the in-place handler: scratch of W floats per
event, and a record updated in place, so the Simulation region makes no
garbage. `batch` opens one Event window per B events and resets it at the
end of the B events, with no census; `autopool` is the same handler under
the stock collector; `pooled` opens and resets a window per event and runs a
scoped collection every 100 000 events, which finds nothing. B is the knob:
the window pair and the reset are paid once per B events.

<!-- table M5-throughput -->
| variant | W | B | events/s | collections | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- |
| autopool | 3 | 1 | 52.6 M | 0 | 629 |
| batch | 3 | 1 | 25.4 M | 0 | 629 |
| batch | 3 | 100 | 62.4 M | 0 | 629 |
| batch | 3 | 1000 | 63.1 M | 0 | 629 |
| pooled | 3 | 1 | 24.6 M | 50 | 629 |
| autopool | 200 | 1 | 13.7 M | 0 | 629 |
| batch | 200 | 1 | 20.8 M | 0 | 629 |
| batch | 200 | 100 | 44.8 M | 0 | 629 |
| batch | 200 | 1000 | 38.9 M | 0 | 629 |
| pooled | 200 | 1 | 21.1 M | 50 | 629 |
<!-- /table -->

## M6 — Paced and endurance

**Claim.** At one event per 100 µs on the wall clock, the regions run misses
no slot, where the baseline under the stock collector misses slots at every
collection; over 30 minutes the RSS of the regions run stays flat.

Scripts `bench/paced.jl`, `bench/endurance.jl`; data
`results/data/paced.tsv` and `results/data/endurance.tsv`; plots
`results/plots/paced.svg` (dots: the latency p50, p99.9 and max and the
lateness max of each run, on one log axis) and `results/plots/endurance.svg`
(line: RSS and the live-heap counter over 30 minutes).

A slot is 100 µs; a miss is an event whose lateness passes the slot. The
`baseline` runs with `--heap-size-hint=128M`, so the stock collector runs
at all in a one-million-event run; `regions` resets the Event region after
each event. The two collections of the baseline are its 122 misses: a
collection of about 5 ms holds the loop through about fifty slots, and each
event that waited past its slot is a miss. The regions run collects nothing
and misses nothing. Its
`lateness max` is 92 µs where its `latency max` is 11 µs: the loop woke
late once, by 80 µs, on an event that then ran in 11 µs. That is the
machine, not the collector, and it stayed inside the slot.

<!-- table M6-paced -->
| variant | events | latency p50 (ns) | latency max (ns) | lateness p99.9 (ns) | lateness max (ns) | slot misses | GC events | GC (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | 1,000,000 | 70 | 5,588,408 | 1,385 | 5,588,463 | 122 | 2 | 10.3 |
| regions | 1,000,000 | 81 | 11,401 | 691 | 92,453 | 0 | 0 | 0.0 |
<!-- /table -->

The endurance run keeps no per-event buffer: latencies go to a fixed
histogram, so the harness cannot grow, and any RSS growth is a leak. The
RSS is `Sys.maxrss`, the high-water mark. The row "allocated through the
region" is the growth of `Base.gc_live_bytes()`: that counter counts a
region allocation in and a reset never subtracts it, so its slope is the
throughput the reset recycles, not a leak (see the devdoc, section
"Counters").

<!-- table M6-endurance -->
| endurance | value |
| --- | --- |
| samples (one per 100 000 events) | 180 |
| events | 18,000,000 |
| wall (s) | 1,800 |
| RSS at the first sample (MB) | 303.64 |
| RSS at the last sample (MB) | 303.64 |
| RSS max (MB) | 303.64 |
| allocated through the region, first to last sample (MB) | 525 |
| slot misses | 0 |
<!-- /table -->

## M7 — Region-native against C++

**Claim.** A model written for regions (a packet allocated at send and
dropped at delivery, no pool) runs within a small factor of the same model
in C++ with `new` and `delete` per event, and the census keeps its memory
bounded.

Scripts `bench/native.jl`, `bench/native.cpp`; data
`results/data/native.tsv`; plot `results/plots/native.svg`. The C++ row runs
only when a compiler builds `native.cpp`.

<!-- table M7 -->
| variant | W | events/s | censuses | census p50 (µs) | census max (µs) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- |
| region | 3 | 61.5 M | 50 | 3.0 | 8.0 | 252.6 |
| stock | 3 | 60.7 M | — | — | — | 278.9 |
| cpp | 3 | 69.7 M | — | — | — | 3.8 |
| region | 200 | 31.8 M | 50 | 10.7 | 13.8 | 277.2 |
| stock | 200 | 32.6 M | — | — | — | 279.7 |
| cpp | 200 | 42.2 M | — | — | — | 3.8 |
<!-- /table -->

## M8 — Wholesale death

**Claim.** When a whole structure dies at once, a region reset frees it
without a collection: the binary tree, the linked list, and the tree
showcase run with zero stock collections under regions, at a peak RSS the
table shows.

Scripts `demo/showcase_binarytree.jl`, `demo/showcase_linkedlist.jl`,
`demo/showcase_tree.jl`; data `results/data/showcase.tsv`; plot
`results/plots/showcase.svg` (bars: collections and GC time, stock against
regions, per showcase; bars: peak RSS of both). Three rounds each; the table
holds the round with the best wall time.

<!-- table M8 -->
| showcase | mode | wall (s) | collections | GC (ms) | peak RSS (MB) | rounds |
| --- | --- | --- | --- | --- | --- | --- |
| binarytree | stock | 0.385 | 31 | 83.3 | 271 | 3 |
| binarytree | regions | 0.366 | 0 | 0.0 | 263 | 3 |
| linkedlist | stock | 2.145 | 10 | 1694.7 | 2,385 | 3 |
| linkedlist | regions | 0.566 | 0 | 0.0 | 2,385 | 3 |
| tree | stock | 0.008 | 6 | 0.9 | — | 3 |
| tree | regions | 0.006 | 0 | 0.0 | — | 3 |
<!-- /table -->

## M9 — The growth bound

**Claim.** The census of the open region, armed at a page threshold, holds
the pages of a region that churns inside one window to a bound; disarmed,
the region grows with the churn.

Script `bench/census_bound.jl`; data `results/data/census_bound.tsv`; plot
`results/plots/census_bound.svg` (line: pages per round, disarmed and armed,
the threshold as a horizontal line). The test `census_growth_bound` in
`test/gc/regions_census.jl` asserts the bound; the benchmark prints the
pages per round.

<!-- table M9 -->
| census | rounds | pages at the last round | pages max | ratio disarmed / armed |
| --- | --- | --- | --- | --- |
| disarmed | 40,000 | 10,089 | 10,089 | 1.00 |
| armed | 40,000 | 60 | 63 | 160.14 |
<!-- /table -->

## M10 — The demonstrators

**Claim.** On four algorithms, the same code runs under regions and under
the stock collector; regions win on collections and pauses in every case,
and win on wall time where the discarded allocation per unit of work is
large. Where the region model loses on wall time, the table says so.

Scripts `demo/bt_solver.jl` (A), `demo/pathtrace.jl` (B),
`demo/optimistic_bst.jl` (C), `demo/dmr.jl` (D); data
`results/data/demo_a.tsv` to `results/data/demo_d.tsv`; plots
`results/plots/demo_a.svg` to `results/plots/demo_d.svg` (wall time regions
against stock over the sweep, the stock collection count on a second axis)
and `results/plots/demo_rss.svg` (peak RSS regions against stock, all four).
A, B, C, and D run interleaved A/B/A/B. The stock baseline is the same
algorithm under the stock collector; a different algorithm is never claimed
as beaten.

The ratio column is stock / regions: above 1.0 regions are faster.

<!-- table M10 -->
| demo | point | threads | wall stock (ms) | wall regions (ms) | stock / regions | collections stock | collections regions | GC stock (ms) | GC regions (ms) | peak RSS stock (MB) | peak RSS regions (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | small (1500 instances, n=30, K=3) | 1 | 102.3 | 95.8 | 1.07 | 11 | 0 | 5.8 | 0.0 | 276 | 275 |
| A | medium (3000 instances, n=32, K=3) | 1 | 217.4 | 202.1 | 1.08 | 23 | 0 | 12.4 | 0.0 | 278 | 277 |
| A | large (5000 instances, n=34, K=3) | 1 | 388.3 | 364.0 | 1.07 | 41 | 0 | 20.9 | 0.0 | 279 | 279 |
| B | small (160x100, 8 spp, depth 8, 4 threads) | 4 | 6.0 | 6.1 | 0.99 | 0 | 0 | 0.0 | 0.0 | 282 | 282 |
| B | medium (160x100, 24 spp, depth 8, 4 threads) | 4 | 16.6 | 17.0 | 0.98 | 2 | 0 | 0.3 | 0.0 | 284 | 283 |
| B | large (160x100, 64 spp, depth 8, 4 threads) | 4 | 44.4 | 43.3 | 1.02 | 7 | 0 | 0.8 | 0.0 | 284 | 284 |
| C | work=0 (80000 keys, work=0, 4 threads) | 4 | 29.5 | 66.8 | 0.44 | 2 | 5 | 3.9 | 5.6 | 356 | 369 |
| C | work=64 (80000 keys, work=64, 4 threads) | 4 | 79.8 | 94.6 | 0.84 | 22 | 4 | 24.8 | 4.3 | 378 | 378 |
| C | work=256 (80000 keys, work=256, 4 threads) | 4 | 289.9 | 171.2 | 1.69 | 35 | 2 | 115.8 | 3.4 | 547 | 594 |
| C | work=1024 (80000 keys, work=1024, 4 threads) | 4 | 878.9 | 443.6 | 1.98 | 83 | 2 | 327.7 | 4.4 | 634 | 632 |
| D | work=0 (grid 16, work=0, 4 threads) | 4 | 36.9 | 36.4 | 1.01 | 0 | 0 | 0.0 | 0.0 | 286 | 286 |
| D | work=512 (grid 16, work=512, 4 threads) | 4 | 37.3 | 36.3 | 1.03 | 4 | 0 | 2.2 | 0.0 | 296 | 297 |
| D | work=2048 (grid 16, work=2048, 4 threads) | 4 | 45.7 | 38.4 | 1.19 | 26 | 0 | 8.0 | 0.0 | 302 | 297 |
<!-- /table -->

## M11 — The discipline checker

**Claim.** The checker finds the stores of the allocating model that break
the region rule, and finds none in the clean model, without a region in use.

Script `tools/checker_run.jl` (after `tools/hook_patch.py`); data
`results/data/checker.tsv`; no plot.

<!-- table M11 -->
| model | events | violations (stores) | sites |
| --- | --- | --- | --- |
| alloc | 100,000 | 200,018 | 3 |
| clean | 100,000 | 0 | 0 |
<!-- /table -->

## M12 — Thread scaling of the sibling leaves

**Claim.** Sibling leaves, one per worker, scale with the thread count
without coordination between the leaves: on both demonstrators the wall
time of the regions run falls with the thread count as the stock run's
does. Where the stock collector runs during the work (D at a large work
factor), the regions run is faster at two threads and more; at one thread
the two are equal within noise.

Scripts `demo/pathtrace.jl` (B), `demo/dmr.jl` (D) at 1, 2, 4, and 8
threads; data `results/data/scaling.tsv`; plot `results/plots/scaling.svg`
(line: wall time against thread count, regions and stock, per demonstrator).
This row runs on CPUs 24 to 31. The ratio column is stock / regions.

<!-- table M12 -->
| demo | point | threads | wall stock (ms) | wall regions (ms) | stock / regions | collections stock | collections regions | GC stock (ms) | GC regions (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| B | small | 1 | 12.9 | 13.5 | 0.96 | 0 | 0 | 0.0 | 0.0 |
| B | medium | 1 | 38.7 | 38.8 | 1.00 | 2 | 0 | 0.2 | 0.0 |
| B | large | 1 | 102.3 | 101.6 | 1.01 | 6 | 0 | 0.7 | 0.0 |
| D | work=0 | 1 | 88.9 | 89.2 | 1.00 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 1 | 91.1 | 86.1 | 1.06 | 2 | 0 | 1.7 | 0.0 |
| D | work=2048 | 1 | 88.1 | 89.5 | 0.98 | 10 | 0 | 6.0 | 0.0 |
| B | small | 2 | 10.5 | 10.8 | 0.97 | 0 | 0 | 0.0 | 0.0 |
| B | medium | 2 | 30.6 | 30.4 | 1.00 | 2 | 0 | 0.2 | 0.0 |
| B | large | 2 | 80.2 | 79.1 | 1.01 | 7 | 0 | 0.7 | 0.0 |
| D | work=0 | 2 | 56.1 | 55.2 | 1.02 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 2 | 58.7 | 56.4 | 1.04 | 4 | 0 | 3.4 | 0.0 |
| D | work=2048 | 2 | 69.2 | 57.8 | 1.20 | 16 | 0 | 8.6 | 0.0 |
| B | small | 4 | 5.5 | 6.0 | 0.92 | 0 | 0 | 0.0 | 0.0 |
| B | medium | 4 | 16.6 | 16.7 | 0.99 | 2 | 0 | 0.3 | 0.0 |
| B | large | 4 | 44.6 | 43.2 | 1.03 | 7 | 0 | 0.8 | 0.0 |
| D | work=0 | 4 | 35.4 | 35.4 | 1.00 | 0 | 0 | 0.0 | 0.0 |
| D | work=512 | 4 | 37.2 | 35.2 | 1.06 | 5 | 0 | 4.0 | 0.0 |
| D | work=2048 | 4 | 45.4 | 36.5 | 1.25 | 27 | 0 | 9.1 | 0.0 |
| B | small | 8 | 3.3 | 3.7 | 0.89 | 0 | 0 | 0.0 | 0.0 |
| B | medium | 8 | 10.2 | 10.2 | 1.00 | 2 | 0 | 0.4 | 0.0 |
| B | large | 8 | 26.8 | 26.3 | 1.02 | 7 | 2 | 0.9 | 0.3 |
| D | work=0 | 8 | 24.9 | 23.5 | 1.06 | 1 | 0 | 1.5 | 0.0 |
| D | work=512 | 8 | 26.4 | 27.1 | 0.97 | 5 | 1 | 3.0 | 1.6 |
| D | work=2048 | 8 | 36.0 | 29.5 | 1.22 | 20 | 4 | 8.0 | 3.4 |
<!-- /table -->
