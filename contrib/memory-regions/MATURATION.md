# Maturing the region collector into a runtime feature

This branch (`region-maturation`, off `memory-regions`) takes the region
prototype from "an unsafe opt-in with an operating contract" toward "a
runtime feature with no cost when unused, full benefit when used alone,
and coexistence with the stock collector." The plan and its acceptance
tests are in `plan/pending/region-gc-maturation.md`; this file is the
result. No pull request is part of it: any upstreaming is the author's
manual act.

Every claim below is a test in this directory, run on the isolated core
(the environment of `MEASUREMENTS.md`), single- and multi-threaded.

## Stage 1 — soundness

- **A window follows its task, not its thread** (`task_window_test.jl`).
  The region state moved onto the task; a task switch parks it and
  installs the arriving task's; an open window pins its task (sticky),
  restored at close. Two tasks interleave on one thread, each in its own
  region, across yields.
- **An escape is a leak, never corruption** (`escape_test.jl`). A store
  whose child is younger than its parent violates the rule. A runtime
  flag arms at the first `region_set`; the write-barrier lowering emits
  one predicted branch on it, with a cold call that compares the two page
  tags; an illegal store quarantines the child region — its reset and
  census refuse, its memory is retained, and a one-time warning names the
  types. The counterexample everyone types first — a region-0 `Dict`
  resized inside a window — runs correctly and leaks exactly its tables.
- **Malloc'd data dies with its region** (`malloced_test.jl`). A memory
  with malloc'd data allocated in a region joins the region's own list;
  the reset frees all of it, the census the dead. The old
  header-recycled-under-the-malloc-list corruption is a passing test.
- **Finalizers run at the region's boundaries** (`finalizer_test.jl`).
  Registration on a region object goes to the region's list; the reset
  runs them all on whole objects, the cooperative census the dead ones;
  the census marks the listed closures so a survivor's finalizer is not
  swept. The stop-the-world census refuses a region that has finalizers.

## Stage 2 — coexistence with no contract

`stockgc_test.jl`. `GC.gc(true)` and `GC.gc(false)` run at any moment —
windows open, a live Simulation region — and the census after them is
exact. A bracket parks every stopped thread's window and installs region
0 (the sweep prologue needs `norm_pools`), then clears the low header
bits of every region page the mark touched (`has_marked` is the card, so
this stays proportional). The quiescence contract is gone. Two repairs
the tests forced: the census claims a task whatever its bits (a stock
collection leaves tasks old-marked), and restores each task's exact prior
bits.

## Stage 3 — tasks and threads

`parked_task_test.jl`. A task that closed its window and parked with
region references on its stack is now a root: all three scanners queue
`live_tasks`. Cross-thread references into a region and finalizer-held
region references are escapes — quarantined, impossible in a disciplined
program — so cross-thread root scans are not the census's business.

## Stage 4 — evidence

**The showcase: wholesale death, one `@with_region` wrap.** The
GCBenchmarks shapes the regions were built for, region mode against the
stock collector on this binary:

| workload | stock | regions |
| --- | --- | --- |
| binary tree (temp trees, GCBench) | 0.47 s, 31 collections | **0.32 s, 0 collections** |
| linked list (134 M nodes, all die at once) | 2.19 s, 1.76 s in GC | **0.42 s, 0 collections** |

**Endurance, the HIL profile, on the full maturation runtime with the
barrier armed.** 30 minutes, 18 M events at one per 100 µs: **0 slot
misses**, worst completion lateness 46.8 µs against the 100 µs slot, RSS
flat to 0.0 MB. The armed barrier and the coexistence brackets cost the
hard-real-time loop nothing.

**The cost to ordinary Julia that never uses a region.** The same
GCBenchmarks serial set, vanilla `v1.13.0-rc3` against this binary, min of
three interleaved runs on the isolated core:

| benchmark | mature / vanilla |
| --- | --- |
| append | 1.01 |
| strings | 1.00 |
| binary tree (BST insert) | 1.04 |
| bigint pollard | 1.05 |
| big_arrays single_ref | 1.08 |
| big_arrays many_refs | 1.24 |

Read honestly: on the four realistic workloads the region runtime is
within measurement noise of vanilla — the zero-cost claim holds there.
The two `big_arrays` benchmarks are GC stressors that touch 100-million
-element structures and do almost nothing else, and they expose the two
places the region machinery adds a per-item cost:

- `single_ref` (mark-bound: one array, 100 M identical references) cost
  the scoped-census page-tag check once per array slot; hoisting it out
  of the mark loop took it from 1.19 to 1.08, the rest being the leaf
  path and noise.
- `many_refs` (allocation-bound: 100 M distinct tiny objects) costs the
  one extra pointer load the region fast path carries (`active_pools`
  instead of the inline `norm_pools`); at 100 M allocations of nothing
  else it is 1.24, and it is the reason a stock-only build matters.

**Two escape hatches to literal zero.** The store barrier compiles out
(`make` with `JL_NO_REGION_STORE_BARRIER`) for a build that never wants
regions; the allocation indirection is the remaining target for the same
treatment. Start time is unchanged (0.06 s both), and the runtime library
grows 0.8 % (11.62 → 11.72 MB).

## Where it stands

Stages 1–3 are done and proven; stage 4 is measured. What remains before
this could be a feature is not correctness but polish and scope: the
allocation fast path's zero-cost mode, a broader benchmark sweep, and the
subsystems the prototype still declines (weak references, the id dict,
serialization, precompile images). The plan carries the list.
