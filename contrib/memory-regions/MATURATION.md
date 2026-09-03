# Maturing the region collector into a runtime feature

This branch (`region-maturation`, off `memory-regions`) takes the region
prototype from "an unsafe opt-in with an operating contract" toward "a
runtime feature with no cost when unused, full benefit when used alone,
and coexistence with the stock collector." The plan and its acceptance
tests are in `plan/done/region-gc-maturation.md`; this file is the
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
  The guarantee covers construction too: a constructor store of an
  already-boxed child once skipped the barrier (a fresh young parent
  needs no generational barrier, and the region barrier rode on it), so
  a region-0 object built with a younger-region field escaped uncaught
  and the reset dangled it. The barrier now fires for a boxed pointer
  child at construction. The cost is a boxed-pointer-field construction
  paying the arming check in the default build: measured worst case (two
  such fields, tight loop, isolated core) +1.4 ns/object, 42.4 → 43.8 ns,
  and `JL_NO_REGION_STORE_BARRIER` removes it. A region-only construction
  intrinsic would cut this to the bare flag check (~0.7 ns; the arming
  check is irreducible while the barrier is compiled in), and is the
  recorded zero-cost follow-up if the construction cost proves to matter.
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
| binary tree (BST insert) | 1.01 |
| bigint pollard | 1.06 |
| big_arrays single_ref | 0.98 |
| big_arrays many_refs | 0.92 |

Read honestly: on the four realistic workloads the region runtime is
within measurement noise of vanilla, and the two `big_arrays` stressors
— 100-million-element structures, almost nothing else — sit at vanilla
or below. The zero-cost claim holds on this set. One honest caveat sits
outside it: the construction barrier (stage 1) adds ~1.4 ns to a
boxed-pointer-field construction in the default build — below this set's
noise, but real on construction-dense code, and the reason a zero-cost
construction intrinsic is the recorded follow-up. `JL_NO_REGION_STORE_BARRIER`
removes it, as it does the store barrier.

The stressors are mark-bound, and the seam that decides them is
inlining, not a check: the work-stealing queue's push and pop copy each
element with a `memcpy` whose size is a call parameter. The queue
operations are `FORCE_INLINE` and the scoped-census filter is outlined
(`gc_scoped_claim`, NOINLINE), so the mark drain compiles as in vanilla
— the size is a constant, the copy folds to one store, and a stock mark
pays one predicted branch per object for the region machinery. Left to
the compiler's inline budget, the filter's body tips the drain over and
every marked object pays a real call and a size-checked copy; that is
worth about 40 % of a 35 M-object mark, and no per-slot load hoist can
buy it back.

`many_refs` lands below 1.0 because the allocation phase of that shape
runs about twice as fast on this binary (~175 against ~350 ms for 35 M
small objects, collector off; stable over three interleaved runs). A
bisect names the mechanism: the deferral re-arm of the guards commit.
On vanilla, `maybe_collect` fires on `heap_size >= heap_target`, and
with the collector disabled the heap sits above its target, so every
allocation re-enters `jl_gc_collect` only to return on the disable
counter — about 20 ns each. `gc_defer_collection()` re-arms the target,
so a `GC.enable(false)` loop allocates at full speed. The benchmark
disables the collector during construction; any workload that does the
same inherits the gain.

**Two escape hatches to literal zero.** The store barrier compiles out
(`make` with `JL_NO_REGION_STORE_BARRIER`) for a build that never wants
regions, and so does the allocation indirection (`JL_NO_REGION_ALLOC`:
the pool address computes exactly as vanilla and `jl_gc_region_set`
refuses with -1) — though the indirection measures at no cost on this
set. Start time is unchanged (0.06 s both), and the runtime library
grows 0.8 % (11.62 → 11.72 MB).

**The broader sweep.** The remaining serial benches and the
multithreaded set, same protocol. Serial: `linked/list` and `TimeZones`
do not run in this environment on either binary (the harness's
memory-pressure callback aborts `list`; `TimeZones` needs its package,
unavailable offline). Multithreaded, `-t4`, min of three interleaved:
`mergesort_parallel` 0.97, `mm_divide_and_conquer` 1.06, `issue-52937`
at parity within the bench's ±15 % spread on non-isolated cores
(medians 12.0 against 11.8 s over eight runs); `objarray` and both
`binary_tree` benches abort on both binaries under the pressure
callback. No multithreaded regression.

## Where it stands

Stages 1–3 are done and proven; stage 4 is measured. What remains before
this could be a feature is not correctness but polish and scope: a
broader benchmark sweep, and the subsystems the prototype still declines
(weak references, the id dict, serialization, precompile images). The
plan carries the list.
