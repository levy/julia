# Memory regions with a monotonic reference rule: the goal and the design

## The goal

A discrete-event simulator that drives hardware in the loop must answer every
event within a fixed slot — 100 µs is the target this work was built against.
Julia's stock collector can not promise that: on the workloads that motivated
this branch the worst observed collection pause was 19.5 ms, and an explicit
collection on a nearly empty session already costs several milliseconds. The
usual mitigation, an event path that allocates nothing, works but forbids
recording results — which is the point of a run.

This branch adds **regions** to the stock collector: sets of objects with one
common lifetime, ordered from long-lived to short-lived. One rule keeps them
safe, and everything else follows from the rule. The prototype's aim was to
prove one thing — that a paced run gets a bounded event-latency tail — and to
measure what the mechanism costs. Both are recorded in `MEASUREMENTS.md`,
added at the end of this branch. This document is the semantic design: it
says what the rules are and why they work, before the runtime carries them
out. The runtime that follows in the next commits is a prototype of exactly
this design, one idea per commit.

## Start from what you know

A reader who knows how a mark-and-sweep collector works can read the design
through that lens, phase by phase, before the rules.

You know why mark-and-sweep pauses hurt. The mark walks everything
reachable from ALL roots — globals, the whole object graph — so it is
O(live heap). The sweep is O(heap). And a collection fires when an
allocation trips a counter, so it lands wherever the program happens to
be. Generational collection improves the average by betting that young
objects die, but it pays for the bet with a write barrier and remembered
sets, and the full collections still come.

Now add ONE rule to the heap, and watch what happens to each phase.

## The one rule

Partition the heap into regions ordered by lifetime — for the simulator:
`Permanent > Engine > Simulation > Event` — and forbid every pointer from
an older region to a younger one. Pointers only go young → old. That is
the entire design. Everything else falls out of it, one consequence per
phase of the collector:

| mark-and-sweep concept | what the rule turns it into |
| --- | --- |
| remembered sets | **gone** — the edges they track are illegal, so they cannot exist |
| freeing a dead generation | **reset**: no old object CAN point in, and younger regions are already empty, so everything inside is garbage by construction — the whole region frees in O(pages) **without marking anything** |
| marking the heap | **a scoped mark of one region**: globals live in Permanent and cannot point down, so the roots shrink to the thread stacks; the walk stops at any older object, because older is live by definition — the mark is O(one region's live set) |
| the sweep | only that region's own pages; a page with no marked cell frees in O(1) and returns to the allocator |
| the write barrier | changes meaning: the generational barrier says "remember this edge", this one says "this edge is a BUG" — it traps in development builds and does not need to exist in production |

## The mapping onto a simulator, and the punchline

The **Event region** is a nursery with a guaranteed 100 % death rate:
every transient a handler allocates dies before the event ends. A nursery
collection where nothing survives needs no mark at all — so it
degenerates into a reset of the bump cursors that reuses the same few
pages, about 10 nanoseconds, every event or every slice.

The **Simulation region** holds one run's state. When it churns, run the
scoped mark — this branch calls it a census, because the cost is per
LIVE object, about 6 ns each, flat in the amount of garbage. Everything
that must outlive the run is banned from living here by the rule itself,
which is exactly what makes the region resettable between repetitions.

**Engine and Permanent are never traced by anything, ever.** That is
where the sysimage-sized part of every full mark went, and it simply
disappears. The engine holds no pointer into the model — it names modules
and events through plain integers (isbits handles), which the rule does
not constrain — and the model is kept alive by its region, not by
reachability: memory in a region exists until the region resets,
referenced or not. Reachability matters only to the census, whose roots
(the driver's stack) do hold the run.

And because the engine is single-threaded and calls the census itself at
an event boundary it owns, there is no stop-the-world either: the
cooperative entry is two stores and a counter, 0.2 µs.

## The model

Memory is divided into **regions**. A region is a set of objects with one
common lifetime. The regions form a chain from the longest lifetime to the
shortest:

    Permanent > Engine > Simulation > Event

Every managed object belongs to exactly one region for its whole lifetime.
There is no promotion and no migration: the region is chosen at allocation and
never changes.

**The reference rule.** An object may reference only objects whose lifetime is
at least as long as its own:

    Event      → Simulation, Engine, Permanent, Event   legal
    Simulation → Engine, Permanent, Simulation          legal
    Engine     → Permanent, Engine                      legal
    Permanent  → Permanent                              legal

    Permanent  → Engine                                 illegal
    Engine     → Simulation                             illegal
    Simulation → Event                                  illegal

The hierarchy can generalize to a tree of lifetimes. Then the rule is: a
reference may point only to an object whose region is an **ancestor of the
referrer's region, or the same region**. Two sibling regions may not reference
each other, because neither outlives the other by construction. This
specification uses the chain, because the simulator needs
`Simulation → Engine` references and the chain grants them.

## The six rules

1. **Ownership.** Every managed object belongs to exactly one region.
2. **Allocation.** Every allocation goes into the dynamically current region.
   This covers the allocations the compiler makes implicitly: tuples,
   closures, boxes, arrays, exceptions.
3. **Reference monotonicity.** For every managed reference `a → b`, the region
   of `b` is an ancestor of the region of `a`, or the same region.
4. **Write enforcement.** Every managed pointer store checks rule 3 and traps
   on violation. A scalar store needs no check. A store to a global binding is
   a store into Permanent, so a global may never hold a younger object.
5. **Region reset.** A region may be reset only when no live execution root
   points into it and no live younger object references into it. Rule 3
   guarantees that no OLDER region can hold a reference into it, so reset then
   frees the whole region without tracing anything. Two ways establish the
   younger half of the precondition: every younger region is already reset, or
   a walk of the live younger sets proves that no reference enters (see
   "Scoped collection").
6. **Collection.** A region's collector needs only two root sets: the
   execution roots of every task whose dynamic region extent includes this
   region or a descendant — the CURRENT region of the task is not enough,
   because a task that entered this region and then nested into an older
   extent still holds references in its stack — and explicitly registered
   roots. No heap reference from an older region can exist (rule 3); younger
   regions are either quiesced or walked as root carriers.

Rule 4 is what makes the design different from a generational collector. A
generational write barrier says "this write makes collection harder; record
it". This barrier says "this write is illegal". Because of that, `reset!` is
not a heuristic; it is a proven-safe lifetime operation.

## Why the barrier carries the whole system

Allocation placement and reference legality are two separate mechanisms:

- **Allocation** only decides where a new object lives. A constructor needs no
  region knowledge. An Event object may hold references to Simulation, Engine
  and Permanent objects freely — those all satisfy rule 3.
- **The barrier** independently rejects the illegal direction. A constructor
  called under `with_region(simulation)` that receives an Event object traps
  at the store, so no constructor can smuggle a short-lived reference into a
  long-lived object.

An escaping result is therefore never promoted. Code that produces a value the
simulation must keep allocates it in the Simulation region from the start:

    with_region(simulation_region) do
        result = Result(copy(x), copy(y))       # x, y were Event objects
        results[event_id] = result
    end

The copies are the honest cost of the discipline, and the barrier makes the
cost explicit at the exact line where a lifetime crosses.

## The API

    root_region()            -> Region           # Permanent
    Region(parent::Region)   -> Region
    current_region()         -> Region
    with_region(r) do ... end                    # dynamically scoped, per TASK
    reset!(r)                                    # rule 5
    collect!(r)                                  # rule 6
    region(x)                -> Region           # diagnostics

`current_region` belongs to the task, not to the thread, because tasks migrate
between threads. The intended shape of the event loop:

    engine     = Region(root_region())
    simulation = Region(engine)
    event      = Region(simulation)

    while running
        with_region(event) do
            process_event!(...)
        end
        reset!(event)
    end

The reset stands AFTER the dynamic extent, so no stack or register can still
point into the region. Code that never calls `with_region` runs entirely in
the root region and behaves like ordinary Julia; the mechanism extends the
language, it does not fork it.

## The root rule, named cases

Rule 5 says "no live execution root". Three cases need to be called out,
because each one has silently broken systems of this kind:

- **Tasks.** A task started under `with_region(event)` holds event references
  in its stack. `reset!(event)` must refuse while such a task is live. Refusal
  is the right first semantics; region-owned tasks can come later.
- **Exceptions.** An exception allocates in the current region (rule 2). An
  exception that propagates OUT of the `with_region(event)` extent is a live
  root into Event at the reset point. The event loop must catch at the region
  boundary and either handle there or re-raise a copy allocated in an older
  region.
- **Finalizers.** An object with a finalizer cannot be freed by a trace-free
  reset without either running the finalizer at reset or forbidding finalizers
  outside the root region. This specification forbids them outside the root
  region.

## Scoped collection

A tracing collection does not have to cover the whole chain. It can target any
contiguous segment of regions, because the invariant fixes the direction of
every edge:

- **The roots of a segment.** References into a segment can come only from
  regions YOUNGER than it and from execution roots — rule 3 forbids an older
  source. So the walk starts from the live execution roots and traverses the
  live younger sets to find their edges into the segment. Younger objects are
  walked as root carriers; they are not collected. A segment that excludes the
  root region can skip the global roots entirely: a global lives in Permanent
  and cannot reference downward into the segment.
- **The old boundary.** An edge that crosses the segment's old end stops the
  walk. An older region is implicitly live; nothing in it needs marking.
- **The fallback.** The degenerate segment is the whole chain: a full walk
  from every root. Any smaller segment is the same walk with the two cuts
  above.

**The region-liveness optimization.** Give every region an ENTERED flag. The
walk sets the flag when a root or an edge enters the region. After the walk, a
region whose flag stayed clear, which holds no execution root and is not the
root region, is unreachable AS A WHOLE: it resets in one operation, and its
interior is never traced. The proof is stable under a stop-the-world walk,
because an unreachable region cannot become reachable again — no older region
may store toward it (rule 3), and the younger regions hold no path to it that
the walk did not see.

This relaxes the strict reset order. A MIDDLE region can reset while a younger
region stays live, when the walk of the live younger sets proves that no
reference enters it. The cost shape is favorable exactly where the simulator
needs it: proving a region dead costs the walk of the live YOUNGER sets, not
the size of the region — and in the simulator the younger set (Event) is
small while the middle region (Simulation) is large.

**The simple default.** Without the walk, reset and collection follow the
chain from the youngest end:

    reset!(event)  →  collect!(simulation)  →  collect!(engine)  →  collect!(permanent)

A region is collected only after every younger region is quiesced. Scoped
collection generalizes this discipline; it does not replace it as the default,
because the default needs no walk at all.

## The mapping onto the simulator

The mapping the motivating simulator uses.

| region | holds | reset when |
| --- | --- | --- |
| Permanent | modules, types, methods, the loaded model set | never |
| Engine | the engine, the future event set, the module index | the process ends |
| Simulation | one run's network, parameters, rng state | between repetitions |
| Event | one event's transients: messages in flight, boxes, temporaries | after every event |

Recorded results must outlive the run that produced them, so they belong to
Engine or to Permanent, not to Simulation — the reader that consumes them
outlives the reset between repetitions.

## What the model developer pays

The bill, grounded in what the disciplined prototype models actually had
to change: **lifetime awareness at allocation sites — the same discipline
C++ ownership demands — paid only where an object outlives the event, with
a machine that names every mistake.** Three rules cover it:

1. **Transients cost nothing.** Arrays, closures, boxes, exceptions,
   temporaries inside the event — ordinary Julia, no annotations,
   reclaimed by reset. This is most of a handler's code.
2. **What outlives the event must say so.** An in-flight message is pooled
   or allocated under the Simulation region; a kept result is written as
   isbits into a pre-sized column — region-clean by construction — or
   copied out at the boundary. The copy is the honest cost, and the
   barrier points at the exact line.
3. **Long-lived containers do not grow mid-event.** Growth allocates the
   fresh `Memory` in the current region; pre-size, or grow at boundaries.

Two prohibitions come enforced: no finalizers on region objects (the
registration throws), and no reset while a reference lives (the debug scan
refuses and names the offender by type). The window plumbing is NOT the
model's job — the engine owns the windows, the slice resets, and the
census; the batch demo handler contains zero region calls. The code delta
in the prototype: the clean and the violating model are the same size, and
the pooled pattern is what a performance-minded developer writes anyway.

Testing: the dev loop is the checker — run the model under the hooked
compiler and read a ranked violation list by (site, parent type, child
type); the full routing model reduced to two structural classes in one
run. Violations are traps, not exceptions: a compiled `try`/`catch` does
not see the store barrier or the finalizer gate, so tests assert
process-level failure. Ordinary behavior tests run unchanged — real model
state escapes and crosses safepoints; only tests OF the region machinery
and benchmarks must pin allocations against the optimizer
(`Base.donotdelete`, `GC.@preserve`, an opaque callee — the idioms are
documented in the safety battery).

**And the same model runs under the stock collector at zero cost.** Region
support is a build capability: with it off, the engine opens no windows
and resets nothing, the model's own placement points compile away (the
prototype models differ by one constant `Bool`), and the barrier and the
checker are development tools that no production build carries either way.
What remains of the discipline under the stock collector is pooling,
pre-sizing, and isbits results — which are exactly the allocation hygiene
that makes the stock collector fast too. One model source serves the
batch build and the hardware-in-the-loop build; the capability decides
which memory regime it runs under.

## Prior art

The design is region-based memory management with an enforced assignment rule.
The nearest ancestors, so the known failure modes come with the idea:

- **Tofte–Talpin regions** (the MLKit): regions with stack discipline,
  inferred statically. Here the placement is explicit and dynamic instead.
- **RTSJ scoped memory**: the same reference rule, enforced by the same kind
  of barrier (`IllegalAssignmentError`). Its documented pain is exactly this
  design's cost: a callee cannot RETURN a fresh object to a longer-lived
  caller without the caller choosing the region. The explicit
  `with_region` + copy at the boundary is the same answer RTSJ practice
  converged on.
- **Arena allocators** (and `Bumper.jl` in Julia today): the reset semantics
  without the barrier. Bumper relies on the programmer not to leak; this
  design makes the leak a trap at the store.

## Where this generalizes

**Sibling regions, and a tree of lifetimes, at no new cost.** The
mechanism is identity, not nesting: a page carries the number of the
region that claimed it, every region owns its pool cursors and its page
chain, and a switch is one pointer store. The runtime imposes no order on
the regions - the order lives entirely in the one rule. So a tree of
lifetimes - a Simulation holding many independent Flows, each with its
own Event scratch - is already representable: siblings never reference
each other (the rule forbids it in both directions), each resets in O(1)
independently, and the census of one sibling sweeps only its own chain
and never walks another's pages. What a tree needs beyond this prototype
is small and local: the comparisons that today read "younger = larger
number" (the checker, the trap, the rule-5 scan) become an ancestor
test, and the region count stops being a small constant.

**The stock collector is the one-region special case.** With exactly one
region - region 0 - every mechanism degenerates: the page tag is always
zero, the guards guard nothing, `active_pools` never leaves `norm_pools`,
and no reset or census ever runs. This is not a thought experiment: every
stock-collector column in `MEASUREMENTS.md` runs on this branch in
exactly that state, and matches the vanilla yardstick. Read in the other
direction, it is a unification: the stock collector could be *defined* as
the regions collector with one region, and lifetime-shaped policies
become configuration instead of a fork.

**The API can compile to nothing.** The Julia face is a handful of
`ccall` wrappers. Behind one build flag they become constant no-ops:
`@with_region` reduces to its body, the dead branches fold, and a program
written with regions runs unchanged on the stock collector - the
discipline stays checkable, because the checker is compiler-side and
needs no runtime at all. On the runtime side the only hot-path residue of
the mechanism is the `active_pools` indirection, one load, which a
stock-only build constant-folds away. Opting out costs nothing; opting in
is a scheduling decision, not a rewrite.

## Regions as a graph, collected like objects

The generalization above keeps the region graph fixed. One step further
lurks a general idea: **choose the granularity at which liveness is
computed.** A collector computes liveness over a graph; the object graph
has billions of nodes, and everything expensive about collection is a
function of that size. Let regions form a graph — an edge from region A
to region B when some object in A references an object in B — and
collect at the region level: trace the region graph from the root
regions, free every unreached region wholesale. That graph has thousands
of nodes, so the collection costs microseconds by construction, and the
pause is O(regions + stack roots) — independent of the heap size AND of
the live-object count. Nothing in a conventional collector has that
property. The two extremes bracket the dial: one region per heap is the
stock collector; one region per object is classic tracing. The chain of
this design is one point on the dial; the graph is the whole dial.

The design question is single: how does the mutator maintain the region
edges? Three regimes.

1. **Declared: the mutator maintains nothing.** The chain (and the tree,
   and any DAG declared by the programmer or inferred by a compiler in
   the Tofte–Talpin sense) fixes the region graph a priori. A store can
   only conform to the declared graph or be a bug, so the barrier traps
   in development and compiles to nothing in production. This is the
   regime this prototype lives in.
2. **Recorded: the barrier coarsens.** For a dynamic graph, the barrier
   on `a.f = b` compares two page tags (`region_of` is O(1) here) and,
   when they differ, sets one bit in a per-region-pair table. The
   economy is that the bit SATURATES: a remembered set records every
   old-to-young edge because objects are fine-grained; the quotient
   records one fact per region pair, so a phase-structured program pays
   the slow path a handful of times and never again. Overwrites never
   decrement — a region's out-edges are processed in bulk when the
   region dies, and stale edges are floating garbage at region
   granularity. Counts (Gay–Aiken region reference counting) are
   optional: cycles in the region graph defeat counts, and a trace of a
   graph this small makes them unnecessary.
3. **Degenerate: per-object regions.** The quotient is the identity and
   the scheme collapses into ordinary tracing or reference counting —
   the toll both extremes pay is the reason the middle exists.

**The census is the edge-refresher.** The census already walks exactly
the live objects of one region; while it walks, it can rebuild that
region's out-edge set precisely, discarding the edges only dead objects
held. So the floating garbage of regime 2 is bounded by the census
cadence: the instrument that reclaims intra-region turnover also keeps
the region graph honest. This is how distributed collectors work — local
collections clean the stub/scion tables that inter-space references live
in, and a global trace over the spaces catches cycles. A dynamic region
graph is an in-process distributed GC, with regions as the spaces.
Pony's ORCA (per-actor heaps, freed wholesale when the actor dies) and
Verona (region forests owned through bridge objects) are the modern
relatives; generational GC is the two-region special case whose
remembered set nobody quotiented.

The honest costs, so the idea stays sharp. In regime 2 the barrier
returns — a predicted branch per reference store, and it can no longer
compile to nothing. Floating garbage exists at region granularity until
a census or a region death clears it. And the scheme has no story for an
object that outlives its region: an escapee pins the whole region, and
the fixes — promotion, or a census that copies escapees out —
reintroduce object-level work, which is the toll booth at the exit of
every region design. What the runtime of this branch already owns is
every primitive the idea needs — the O(1) region tag, the wholesale
free, the root-scanning census; the only genuinely new object is the
pair table.

## Coexistence with the stock collector

Today the operating contract says: collect only when the regions are
quiesced. Nothing fundamental forces that — it is a prototype boundary,
and exactly two invariants break when an ordinary collection runs over
live regions: the mark leaves stale bits on region objects that the
sweep never clears (and a stale bit hides a live subgraph from the NEXT
mark — corruption, not a leak), and a region object aged to "old" would
enter the remembered set, whose entry dangles after a reset.

Three designs remove the contract. (1) Clean up after the mark: walk the
region chains and clear the bits, and never remset a region object -
O(region live) per collection. (2) Side bitmaps: mark region objects in
a per-page side bitmap cleared in O(pages) - headers stay virgin.
(3) **Regions as roots** - the one the rule hands us. Rule 3 makes the
heap-region reference structure one-directional: no region-0 object can
point into a region, while region objects point freely out. So for the
stock collector, region objects are never targets that need marks - they
are only sources: scan the regions' allocated cells as an extra root
array, mark what they reference in region 0, touch no region header.
Coverage through the regions is transitive by enumeration, not by
traversal: every region cell is a root, so region-to-region edges need
no walk. Dead region objects keep their referents alive until the reset
- floating garbage bounded by the slice and census cadence, which is
already the regions' contract.

Option 3 legalizes `GC.gc(true)` and `GC.gc(false)` alike, windows open
or not. The young collection inherits a scan cost proportional to the
regions' allocated bytes; the cure is dirty cards on region pages only
(one small store-barrier branch for writes into region objects), or the
per-region outsets of the region-graph section - the census, which
already walks the live set, keeps either one honest.

**The three modes, and what each costs the mutator.** With the collector
off and regions alone (the HIL mode, measured): the window pair 5-10 ns,
the reset ~21 ns per slice, no store barrier, allocation often faster on
recycled cache-hot pages - net one nanosecond of median at light garbage
and a win at recording-class, with only the census as a pause. With the
stock collector alone and region support merely compiled in (measured -
every stock column of the record runs in this state): one foldable
pointer load, not measurable; a stock-only build folds it to literally
zero, and an empty region set is an empty root scan. With both together
(designed, not built): the mutator still pays only the region calls it
makes; the stock collector's pauses grow by the region root scan -
proportional to region bytes without the cards, to dirty region pages
with them - and region memory itself is still reclaimed only by reset
and census.

## The road upstream

What a Julia PR would face, ranked by how hard it bites. First, the
category: this is an UNSAFE OPT-IN feature - production soundness rests
on a discipline the runtime does not enforce - and every serious
objection lives in that asterisk.

1. *Pure Julia code must not corrupt memory.* Inside a window every
   store is potentially a rule violation, and a violation is silent
   corruption. `@inbounds` is local and auditable; a window is a dynamic
   extent that swallows every callee.
2. *Composability, the sharp form of 1.* A library called inside a
   window allocates into the region without knowing regions exist: a
   `Dict` that resizes inside an Event window leaves its new table in
   Event; an exception thrown out of a window outlives its region;
   boxes and closures allocate implicitly. The first counterexample
   anyone will type is the resizing `Dict`, and the PR must have an
   answer before it exists.
3. *Task migration.* The window state is per-thread-heap in this
   prototype, but tasks migrate; it must be per-task state, switched at
   yield points.
4. *Escape has no defined behavior.* An object that outlives its region
   is UB today. The bar upstream will set: a violation may cost
   performance or leak - never corrupt. That means promotion, or a
   production-affordable checked mode.
5. *The known holes*: arrays with malloc'd data dying in a region;
   finalizers (and the nothrow registration gate); weak references, the
   id dict, serialization, precompile images - each subsystem needs a
   region story.
6. *Maintenance.* The change cross-cuts a collector in active rework,
   with MMTk as the sanctioned extension path. Expect: "make it an MMTk
   plan or extend the GC interface" - question 1 of the upstream list
   anticipates exactly this.
7. *The multithreading gap.* The cooperative census is single-mutator by
   contract; `live_tasks` and finalizer lists are not walked.
8. *Zero-cost skepticism.* One workload convinces nobody; the claim
   needs the full benchmark suite, package load times, and code size,
   and a build flag that forks CI is a cost of its own.

What would make it land, mapped against the list: per-task window state
(3); defined escape behavior (1, 4, and it tames 2); regions-as-roots
with cards so coexistence has no contract at all; the malloc'd-data and
finalizer holes closed (5); packaged behind the GC interface or as an
MMTk plan (6); and the unification as the pitch - the stock collector IS
the one-region special case, measured - so the proposal reads as a
generalization the collector already satisfies, not as a second
collector. The staged path is in `plan/pending/upstream-pr.md`.

## What is deferred

- **Concurrent sibling event regions** (one per worker task). The chain comes
  first; sibling regions add an ownership rule for cross-region writes.
- **Barrier elision.** A store whose operands the compiler proves same-region
  or older-region needs no check. Correctness first.
- **Per-object region metadata.** `region(x)` needs the runtime to answer
  where an object lives; the cost of that answer is an implementation
  question, not a semantic one.

