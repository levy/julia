# Measurements

Every number in this document comes from a data file under `results/data/`,
and every plot under `results/plots/` is drawn from those files by
`results/plot.py` with no other input. `results/run_all.sh` runs every
measurement below in order and writes the data files; the logs go to
`results/log/`, which git ignores.

The two binaries: **regions** is a julia built from the tip of this branch;
**vanilla** is a julia built from the base commit, `8f33e09afe`
(`v1.13.0-rc4`), with nothing else changed. A row that names only one binary
ran on regions.

The machine: one Linux x86-64 host, shared. Single-thread rows run pinned to
CPU 29, a core the kernel scheduler never uses (`isolcpus`, `nohz_full`,
`rcu_nocbs`), under `SCHED_FIFO` when the machine grants it. Four-thread rows
run on CPUs 24 to 27, which are not isolated. Every row runs under a memory
cap and a timeout. Under each table one line gives the date, the commit, the
cores, and the command.

## M1 — Zero cost when unused

**Claim.** A julia that carries the region runtime, on a program that never
opens a window, runs the GCBenchmarks within noise of vanilla.

Script `bench/gcbench.sh`; data `results/data/gcbench.tsv`; plot
`results/plots/gcbench.svg` (bars: the ratio regions / vanilla per benchmark,
one bar per thread count, a line at 1.0). Eleven benchmarks: six serial on
one thread, five parallel on four threads. Both binaries run in every round,
in alternating order; the table holds the median of the rounds.

| benchmark | threads | vanilla (s) | regions (s) | ratio |
| --- | --- | --- | --- | --- |
| | | | | |

## M2 — Unit costs

**Claim.** The unit costs of the runtime are: a disarmed store pays one
predicted branch; an armed store pays one page-map walk in a cold call; a
window pair and a reset cost tens of nanoseconds; an allocation in a region
costs what an allocation in the stock pool costs; the stock mark does not
change.

Script `bench/unit_costs.jl`; data `results/data/unit_costs.tsv`; no plot.
Each row is the minimum over eight compiled copies of the loop, so that code
placement does not decide the row. The vanilla column holds the rows that
need no region entry point.

| cost | unit | vanilla | regions | ratio |
| --- | --- | --- | --- | --- |
| | | | | |

## M3 — The tail, one Bool apart

**Claim.** In a pooled event loop whose only garbage is the scratch of the
sink, the reset of the Event region after each event removes the collector's
tail from the per-event latency; the two runs differ in one Bool.

Scripts `bench/yardstick.jl`, `bench/tail.jl`; data `results/data/tail.tsv`;
plot `results/plots/tail.svg`. The yardstick rows give the allocating and the
pooled model under the stock collector; the tail rows give the pooled model
with the scratch left to the collector (`baseline`) and reset per event
(`regions`).

| script | variant | p50 (ns) | p99 (ns) | p99.9 (ns) | p99.99 (ns) | max (ns) | over 100 µs | GC (ms) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | |

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

| class | mode | events/s | p50 (ns) | p99 (ns) | p99.99 (ns) | max (ns) | max, no preemption (ns) | stock collections | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | |

## M5 — The census

**Claim.** The pause of a census grows with the live set of the region, not
with the garbage, and stays below a full stock collection over the same
heap; the throughput of a loop with a census per slice sits between the
stock collector and the hand-pooled loop.

Script `bench/census.jl`; data `results/data/census_pause.tsv` and
`results/data/census_throughput.tsv`; plots `results/plots/census_pause.svg`
(line: the pause against the live set K, scoped census and cooperative
census against a full collection) and `results/plots/census_throughput.svg`
(bars: events per second of stock, cooperative census, batched census, and
pooled, per garbage size W).

| variant | K | pause p50 (ms) | pause max (ms) | mark (µs) | sweep (µs) | live cells | freed cells |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

| variant | W | B | events/s | p99.9 (ns) | max (ns) | over 100 µs | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |

## M6 — Paced and endurance

**Claim.** At one event per 100 µs on the wall clock, the regions run misses
no slot, where the baseline under the stock collector misses slots at every
collection; over 30 minutes the RSS of the regions run stays flat.

Scripts `bench/paced.jl`, `bench/endurance.jl`; data
`results/data/paced.tsv` and `results/data/endurance.tsv`; plots
`results/plots/paced.svg` (the lateness distribution of both runs) and
`results/plots/endurance.svg` (line: RSS and live bytes over 30 minutes, the
pages the reset returned on a second axis).

| variant | events | latency p50 (ns) | latency max (ns) | lateness p99.9 (ns) | lateness max (ns) | slot misses | GC events | GC (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | |

| endurance | value |
| --- | --- |
| events | |
| wall (s) | |
| RSS at start (MB) | |
| RSS at end (MB) | |
| RSS max (MB) | |
| slot misses | |

## M7 — Region-native against C++

**Claim.** A model written for regions (a packet allocated at send and
dropped at delivery, no pool) runs within a small factor of the same model
in C++ with `new` and `delete` per event, and the census keeps its memory
bounded.

Scripts `bench/native.jl`, `bench/native.cpp`; data
`results/data/native.tsv`; plot `results/plots/native.svg`. The C++ row runs
only when a compiler builds `native.cpp`.

| variant | W | events/s | censuses | census p50 (ms) | census max (ms) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- | --- |
| | | | | | | |

## M8 — Wholesale death

**Claim.** When a whole structure dies at once, a region reset frees it
without a collection: the binary tree, the linked list, and the tree
showcase run with zero stock collections under regions, at a peak RSS the
table shows.

Scripts `demo/showcase_binarytree.jl`, `demo/showcase_linkedlist.jl`,
`demo/showcase_tree.jl`; data `results/data/showcase.tsv`; plot
`results/plots/showcase.svg` (bars: collections and GC time, stock against
regions, per showcase; bars: peak RSS of both). Three rounds each; the table
holds the median.

| showcase | mode | wall (s) | collections | GC (ms) | peak RSS (MB) |
| --- | --- | --- | --- | --- | --- |
| | | | | | |

## M9 — The growth bound

**Claim.** The census of the open region, armed at a page threshold, holds
the pages of a region that churns inside one window to a bound; disarmed,
the region grows with the churn.

Script `bench/census_bound.jl`; data `results/data/census_bound.tsv`; plot
`results/plots/census_bound.svg` (line: pages per round, disarmed and armed,
the threshold as a horizontal line). The test `census_growth_bound` in
`test/gc/regions_census.jl` asserts the bound; the benchmark prints the
pages per round.

| armed | rounds | pages at the last round | pages max | ratio disarmed / armed |
| --- | --- | --- | --- | --- |
| | | | | |

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

| demo | point | threads | wall stock (ms) | wall regions (ms) | ratio | collections stock | collections regions | GC stock (ms) | GC regions (ms) | peak RSS stock (MB) | peak RSS regions (MB) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | | | | | |

## M11 — The discipline checker

**Claim.** The checker finds the stores of the allocating model that break
the region rule, and finds none in the clean model, without a region in use.

Script `tools/checker_run.jl` (after `tools/hook_patch.py`); data
`results/data/checker.tsv`; no plot.

| model | events | violations (stores) | sites |
| --- | --- | --- | --- |
| | | | |

## M12 — Thread scaling of the sibling leaves

**Claim.** Sibling leaves, one per worker, scale with the thread count
without coordination between the leaves; the stock collector's pauses grow
with the thread count on the same code.

Scripts `demo/pathtrace.jl` (B), `demo/dmr.jl` (D) at 1, 2, 4, and 8
threads; data `results/data/scaling.tsv`; plot `results/plots/scaling.svg`
(line: wall time against thread count, regions and stock, per demonstrator).
This row runs on CPUs 24 to 31.

| demo | threads | wall stock (ms) | wall regions (ms) | collections stock | collections regions | GC stock (ms) | GC regions (ms) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| | | | | | | | |
