# The measurements of the memory-region runtime

This file is the complete record of what the runtime of this branch
measures, with the script that produced each number, the log it wrote, and
the reading. The README holds the headline tables; this file holds
everything behind them, so a reader can check any number against its log
and repeat it. Every number was measured on the finished runtime of this
branch — there are no numbers from intermediate states; the plans in
`plan/done/` record how the work went, for whoever cares.

**Machine, build, and discipline.** One machine: AMD Ryzen AI MAX+ 395
(16 cores, 32 threads with SMT on, one NUMA node), 64 GB, Ubuntu 26.04.1
LTS, kernel 7.0.0-30-generic, this branch built from source on
`v1.13.0-rc3`. Every run is single-threaded, pinned to an isolated core
under `SCHED_FIFO` with the memory locked — the environment section of the
real-world chapter states every setting and the file it lives in. The
logs in `logs/` are the files the scripts wrote, unedited; `run.sh`
reproduces them in order. Measured 2026-09-01.

**The metric.** The event latency distribution of a discrete-event run —
p50, p99, p99.9, p99.99, max — measured per event with `time_ns` into
preallocated vectors, so the harness itself allocates nothing per event.
Collector time is attributed per event from `Base.gc_num().total_time`
deltas. The pacing target that every tail is judged against is 100 µs per
event: the target of a simulator that drives hardware in the loop.

**The model.** A gate-as-action event kernel (`kernel.jl`), a self-ticking
source, a relay chain, and a recording sink that KEEPS one record per
delivery — the kept records give the collector real work — and makes
transient garbage per event. Variants differ in how they allocate:
`model_alloc.jl` allocates per event (the baseline), `model_pooled.jl`
reuses one packet and preallocated result columns (the hand-pooled upper
bound), `model_clean.jl` follows the region discipline, and
`stage3_model.jl` is the disciplined model with an explicit Event-region
scratch section in the sink. The models pass their scratch through an
opaque `@noinline` consumer, so allocation elision can not delete the
work being measured.

**Reading a log.** Each log prints the percentiles, the max, the number of
events over the 100 µs target, the collection count and total collector
time, and — under regions — the overflow-page count, which must be zero.

## The yardstick: the stock collector, and the hand-pooled upper bound

`harness.jl alloc 20000000` and `harness.jl pooled 20000000` — logs
`logs/harness_alloc.log`, `logs/harness_pooled.log`. 20 M events; the same
traffic and the same kept information; `pooled` reuses one packet with
results in preallocated columns.

| | alloc, stock collector | pooled by hand |
| --- | --- | --- |
| p50 | 60 ns | 60 ns |
| p99 | 90 ns | 71 ns |
| p99.9 | 581 ns | 100 ns |
| p99.99 | 881 ns | 1774 ns |
| max | **13.7 ms** | **325 µs** |
| collections | 12, 18.7 ms in total | **0** |
| events over 100 µs | 24 | 7 |

The yardstick sets the pass line for everything below: a maximum under
the 100 µs target, or a residual tail attributed to something other than
collection. Pooling by hand removes the collections and most of the
maximum; its price is that every allocation site becomes ownership
bookkeeping. The regions exist to reach the same tail with the model
keeping its ordinary allocating code.

## The discipline checker, in the compiler only

`hook_patch.py` builds a working copy of the swappable Compiler with one
hook: the optimized IR of every method passes through an installed
function. `region_check.jl` installs the instrumentation — every `:new`
registers the object and checks its embedded references, `memorynew`
registers the fresh `Memory`, `setfield!` and `memoryrefset!` check parent
against child — and `checker_run.jl` drives a model under it. 5 000
events, 1 291 methods instrumented, 77 070 checks at run time. The
checker is compiler-side: its results do not depend on the runtime.

| model | violations | what they are |
| --- | --- | --- |
| `alloc` | 10 014 at 3 sites | in-flight events stored into the queue (2 sites); the results vector growing under Event (1 site) |
| `clean` | **0** | messages `@in_region SIMULATION`, containers pre-sized |

Three design facts came out of the list: cross-event traffic can not live
in the Event region; container growth from a younger region is a
violation class of its own; an isbits record is region-clean by
construction.

## The tail, one Bool apart

`stage3_run.jl baseline 20000000` and `stage3_run.jl regions 20000000` —
in `logs/run_sh.log`. The model keeps pooled messages and isbits result
columns and allocates ordinary per-event scratch in the sink; the only
difference between the two runs is one `Bool`. The region window lives in
the model, and the swap and the reset run inside the measured window.

| | baseline (collector on) | regions |
| --- | --- | --- |
| p50 | 50 ns | 60 ns |
| p99 | 71 ns | 91 ns |
| p99.9 | 251 ns | 130 ns |
| p99.99 | 1 313 ns | 1 282 ns |
| max | **4.78 ms** | **9.9 µs** |
| events over 100 µs | 17 | **0** |
| collections | 17, 19.9 ms in total | 0 |
| overflow pages | — | 0 |

One `Bool` takes the maximum from 4.78 ms to 9.9 µs: the region window
costs ~10 ns of median and removes the collector from the loop entirely.
No event in twenty million exceeds a tenth of the pacing target.

**Safety batteries.** `stage3_safety.jl`: with
`jl_gc_region_set_debug(1)`, a reset while a live reference still points
into the region is refused and the offender is named by type; the reset
succeeds once the reference dies; an explicit check reports zero
afterwards. `v2_regression.jl`: reset every iteration, 3 M cycles, an
explicit collection after quiesce, plus the swap-only and the live-object
variants — the reproducers of two collector-interplay defect classes.
Both print `ALL PASS`; `run.sh` runs both first.

## The barrier trap

`stage4_trap.jl` with the hooked compiler. The store of a region-1
`Vector{Float64}` into a region-0 `Holder` traps —
`region violation at Base.setproperty!:58: region 0 Holder <- region 1
Vector{Float64}` — and the legal direction, an old child into a young
parent, passes. The trap ends the process with the error, so the test's
exit code 1 is the pass. Enforcement is a compile-time-inserted check and
a development mode; the measured region runs carry none. Compiler-side,
like the checker: the trap needs the hooked build.

## The paced run: one event per 100 µs slot

`stage4_paced.jl baseline|regions 1000000` — logs
`logs/paced_baseline.log`, `logs/paced_regions.log`. 1 M events, 100 s of
wall clock, each event in its own 100 µs slot; the lateness column is
what the hardware feels — how late an event COMPLETES against its slot
deadline.

| | alloc model, collector on | regions |
| --- | --- | --- |
| collections | 1, of 1.2 ms | **0** |
| slot misses | 20 (0.002 %) | **0** |
| lateness p99.9 | 795 ns | 221 ns |
| lateness max | **1.26 ms** | **4.3 µs** |

The regions run misses no slot in a hundred seconds and its worst
lateness is 4.3 µs against a 100 µs slot. The baseline's one collection
costs a 1.26 ms lateness spike — twelve slots.

## Endurance: 30 minutes paced

`stage4_endurance.jl 18000000` — log `logs/endurance30.log`. 30 minutes
at one event per 100 µs, 18 M events, the collector off, `Sys.maxrss`
sampled every 10 s into preallocated columns, latencies in a fixed log2
histogram so the harness itself can not grow.

| | value |
| --- | --- |
| RSS at t = 10 s / at t = 1800 s | 301.7 MB / **301.7 MB** (second-half growth 0.0 MB) |
| allocated per event | 29.3 B, all recycled by the reset |
| collections | **0** |
| slot misses | **0** in 18 M slots |
| latency p50 / p99.9 / max | ≤ 128 ns / ≤ 256 ns / 14.6 µs |
| worst completion lateness | 96.8 µs — under the 100 µs slot |

On the disciplined path nothing accumulates, so no maintenance collection
is ever needed: the reset returns the same pages every slice.
## The census: collect one region alone

`stage5_scoped.jl` — the knobs and the variants are its header comment. A
Simulation-region table of K live records with one replacement per event
(the replaced record becomes region garbage), Event-region scratch reset
per slice, a census every `every` events.

### Against a full collection

The reference is a full `GC.gc()` over the same heap
(`stage5_scoped.jl full`), in `logs/run_sh.log`; the census is the
cooperative entry at K = 10 000:

| | full `GC.gc()` | cooperative census of Simulation |
| --- | --- | --- |
| pause p50 | 2.598 ms | **0.036 ms** |
| pause max | 9.105 ms | **0.046 ms** |

The freed-cell count equals the dead-record count exactly, the table
checksum is correct, and `jl_gc_region_verify` is clean after every
census. The pause is O(region live), not O(heap) and not O(garbage).

### The pause, dissected, and the live-set law

`jl_gc_region_stat` breaks the census into phases; `run.sh` sweeps the
live-set size. At K = 10 000 the phases are ~32 µs mark, ~5 µs sweep,
0.1 µs entry. Three design decisions set that shape, each in its runtime
commit: the sweep is O(dead pages) — a page the mark never touched parks
on the fresh list wholesale, without being reset, and only pages with
survivors are walked cell by cell; an object whose type has no pointer
fields gets its mark bit and page metadata inline in the filter, with no
queue round trip — most of a record-heavy live set; and the marking is
non-atomic, because the census contract holds one mutator, so the atomic
exchange that guards racing markers guards nothing here. The garbage
count does not appear in the pause: 100 000 dead cells per census and
zero give the same numbers.

| live objects | pause p50 | pause max | mark | sweep |
| --- | --- | --- | --- | --- |
| 10 000 | 36 µs | 46 µs | 32.4 µs | 4.6 µs |
| 1 000 | 5 µs | 16 µs | 4.6 µs | 1.4 µs |
| 300 | **3 µs** | 12 µs | 2.7 µs | 1.1 µs |

The law: **pause ≈ 2–3 µs + ~3.3 ns × live objects**, flat in the
garbage. The cooperative entry (`jl_gc_region_collect_coop`) is the one a
single-threaded engine calls at an event boundary it owns: no rendezvous,
no `mprotect`, only the caller's execution roots scanned; it refuses with
-4 if another thread runs managed code and excludes concurrent
collections through the region window counter. The stop-the-world entry
(`jl_gc_region_collect`) exists for engines that are not alone.

### Throughput: what a window costs, and what the census returns

`stage5_scoped.jl autopool | coop | pooled`, 5 M events, K = 10 000, in
M events/s. `autopool` is the baseline: the stock collector on, no
explicit collections, and — like `coop` and `pooled` — no per-event
timing (`auto` times every event for the real-world matrix and is not
comparable on throughput). `coop` allocates per event, opens two windows
per event, and pays a census every 100 000 events; `pooled` updates the
records in place — no region garbage, no census.

| garbage per event | stock collector | coop (regions, census) | pooled (regions, in place) |
| --- | --- | --- | --- |
| ~100 B | **57.61** | 20.34 | 32.65 |
| ~1.7 KB | 12.75 | 18.3 | **27.96** |

Regions are not a throughput feature at light garbage: the stock nursery
amortizes ~100 B per event almost for free, and the toy handler, at
~20 ns of real work, opens two windows per event. At recording-class
garbage the region build wins in wall time while the census pause stays
in the tens of microseconds.

### Slice-batched resets: the knob

`stage5_scoped.jl batch 5000000 100000 10000 W B` against
`stage5_scoped.jl autopool 5000000 100000 10000 W` — the identical
handler, one Event window and one reset per B events against the stock
collector. W scales the garbage per event (W = 3 ≈ 100 B, W = 200 ≈
1.7 KB). In M events/s:

| B | ~100 B/event | ~1.7 KB/event |
| --- | --- | --- |
| stock collector | 57.61 | 12.75 |
| 1 | 28.75 | 24.38 |
| 100 | 78.75 | 48.5 |
| 1 000 | 81.08 | 44.17 |

The law: the per-event window tax is ~10/B ns, and the optimum sits where
the slice footprint fits the cache (B ≈ 1 000 at 100 B/event ≈ 100 KB;
B ≈ 100 at 1.7 KB/event ≈ 170 KB). Past the optimum the slice spills
L2/L3 and the advantage fades. The reset at the boundary is O(1) —
~21 ns however large the slice — so the slice size is a pure cache knob.

## A region-native model, and its C++ counterpart

`stage6_region_native.jl region|stock 5000000` and
`stage6_equivalent.cpp` (`g++ -O2`) — logs `logs/stage6_region.log`,
`logs/stage6_stock.log`, `logs/stage6_cpp.log`. The dyna-shaped question:
packets with a payload are allocated NATURALLY at send and dropped at
delivery — no pool, no reuse, no ownership bookkeeping — and the C++
counterpart does exactly what a C++ simulator does: new and delete per
packet.

| | Julia, stock collector | Julia, regions | C++, new/delete |
| --- | --- | --- | --- |
| events / s | 58.3 M | **82.6 M** | 58.4 M |
| census p50 / max | — | 3.2 µs / 6.6 µs | — |

The region build outruns the C++ counterpart by 1.4×: a bump allocation
into a region page is cheaper than a general-purpose `new`, and the slice
reset is cheaper than per-packet `delete`. The stock-Julia and C++
columns tie.

