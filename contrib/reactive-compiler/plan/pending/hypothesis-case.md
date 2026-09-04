# A reactive, persistent Julia compiler — the hypothesis case

## The claim

> If compiler results are persistent, content-addressed cells with explicit
> dependency edges, then a change to a few methods invalidates only a small part
> of the compiled artifacts. A large application then rebuilds in seconds and not
> in minutes.

The experiment must not start with a rewrite of the Julia compiler. It must start
with a number that says whether the rewrite is worth it.

## Read this first: Julia 1.13 already does much of this

The plan changes shape once you look at what the compiler holds today. Check
`src/julia.h` and `Compiler/src/`. A `CodeInstance` already carries:

- `def` — the `MethodInstance` it belongs to.
- `edges` — the forward dependency edges. **The dependency graph exists.**
- `min_world` and `max_world` — the world range in which the result is valid.
  This is the invalidation mechanism of Julia.
- `inferred` — the inferred IR, sometimes compressed, sometimes dropped.
- `time_infer_total`, `time_infer_self`, `time_infer_cache_saved` and
  `time_compile` — **the cost of this one entry, in seconds.**
- `owner` — "compiler token this belongs to". An external compiler puts its own
  entries here. `jl_nothing` is reserved for the native compiler.
- `flags` — bit `0b100` says the entry came from an image, bit `0b1000` says the
  native code is valid.

Julia also gives you:

- `Compiler/src/reinfer.jl` and `insert_backedges`, which validate the cached
  entries of a package when it loads and re-infer only the stale ones.
- `jl_debug_method_invalidation(1)` in `src/gf.c`, which logs every invalidation.
- `AbstractInterpreter` and `cache_owner`, which let an external compiler keep its
  own cache without a fork of the compiler.

Two consequences follow, and they are the most important sentences in this plan.

**1. The baseline must run with package images on.** Julia already caches native
code for each package, checks it when the package loads, and re-infers what went
stale. A comparison against `--pkgimages=no`, or against a PackageCompiler
system-image build, wins by a large factor and proves nothing. The claim under
test is narrower and sharper:

> Per-`MethodInstance`, content-addressed persistence beats per-package,
> world-age validation after a small edit.

**2. Do not build the instrumentation. Harvest it.** The graph and the per-entry
cost are already in memory after a build. Phase 1 reads them.

This was checked on Julia 1.13.0-rc3, not assumed. For

```julia
f(x) = x * 0.73
g(x) = f(x) + 1
h(x) = g(x) * 2
h(1.0)
```

the `CodeInstance` of `h` answers:

```
edges            = svec(CodeInstance for MethodInstance for g(::Float64),
                        CodeInstance for MethodInstance for *(::Float64, ::Int64))
time_infer_total = 0.001268
time_infer_self  = 0.0003722
time_compile     = 0.01103
min/max world    = 39140 / 18446744073709551615
owner            = nothing
```

The edges point at other `CodeInstance` values, so the graph walks directly. The
times come out of the `UInt16` fields with `reinterpret(Float16, …)`. Phase 1 is
therefore a read, not a build.

## The applications

Do not write a synthetic 100 000-line application. Three real ones are here, and
they specialize heavily:

| Application | Lines of Julia |
| --- | --- |
| `omnet-julia` | 239 522 |
| `projectured-julia` | 167 543 |
| `inet-julia` | 61 310 |

Use `omnet-julia` as the large case. Use `inet-julia` as the medium case.

Write **one** small synthetic application as well, perhaps 2000 lines. Its only
job is to place an edit at a known position in the dependency graph. In a real
application you can not choose where a function sits; in the synthetic one you
can. Use it to check that the measurement code reports what you expect.

## The edit classes

Test five positions in the graph, not one function.

| Class | The edit | What it tests |
| --- | --- | --- |
| A | A leaf function body, `x * 0.73` to `x * 0.74` | The best case. A tiny cone. |
| B | A function that about 100 methods call | A middle cone. |
| C | A generic method, `f(x::AbstractArray)` | A wide cone. |
| D | A field type in a `struct` | The nasty case. |
| E | A `const` value | Whether the graph tracks compiler-visible values. |

Two of these classes deserve a warning before you measure them.

**Class D may not be representable at all.** A change to a `struct` makes a new
type. Every method signature that names the type becomes a new signature, and
every content-addressed key that mentions it changes. The cache sees everything
as new work, correctly. Do not treat a poor result here as a defect. Report it as
a limit of the approach and say so early.

**Class E depends on how the constant reaches the code.** If inference put the
value into the IR, the edit invalidates every user. If the code reads the binding
at run time, it invalidates nothing. Record which of the two happened. Julia 1.13
tracks binding invalidation in `Compiler/src/bindinginvalidations.jl`; read it
before you interpret the result.

## Phase 0 — freeze the baseline

1. Choose one application and one entry point that compiles a large part of it.
2. Record the Julia version, the flags, the machine, and the CPU affinity.
3. Measure a cold build and a warm build, **with package images on**.
4. Measure a warm build after each of the five edits.
5. Record the wall time and the CPU time of each.

This table is the thing every later number is compared against. Without it the
experiment can not fail, and an experiment that can not fail is not one.

Note the measurement hazard found during the PackageCompiler work on this
machine: the wall clock of a build moves by a factor of two or three with the
other work on the machine. Interleave A, B, A, B. Prefer the CPU-time and
cost-in-seconds metrics, which do not depend on the load.

## The property, proved

Before any measurement of scale, prove the property the whole idea rests on:
**an edit to `f` must leave unrelated code compiled.** If Julia recompiled
everything, no cache design would help, because invalidation would not follow the
dependency graph.

`tool/prove_unrelated.jl` sets up four functions, each with a body of 400
statements so the cost is visible:

- `f` — the leaf that is edited;
- `h` — calls `f`, so it must lose its compiled code;
- `g` — unrelated to `f`, so it must keep it;
- `k` — calls `g` and not `f`, so it must keep it too.

Every check passes on Julia 1.13.0-rc3:

- The forward-edge graph predicts the cone `{f, h}`. The invalidation log of
  `jl_debug_method_invalidation` names exactly `{f, h}`. **The paper cone and the
  real one agree.**
- `g` and `k` keep the very same `CodeInstance` object, by identity, and their
  `max_world` stays open.
- `h` has its `max_world` closed, and gains a second `CodeInstance` afterwards.
- `g` and `k` gain no new `CodeInstance`, and `g` answers the same value.

**Julia pays for an edit at the edit.** The redefinition itself took 5.5 ms,
while the first call of `h` afterwards took 0.01 ms. Julia re-infers what it
invalidates when the method is redefined, not when the code is next called. Any
measurement of "time to rebuild after an edit" must therefore time the edit or
the load, and not the call that follows.

## The property at scale: the routing model

The small proof settles that Julia invalidates correctly. The question at scale is
how much of a real application survives one edit, and whether the forward-edge
graph still predicts the cone.

`tool/prove_routing.jl` loads `OmnetLegacyRoutingExample`, runs the
`routing_small` scenario to compile the model, and then edits three methods. An
edit re-evaluates the method from its own source (`src/MethodEdit.jl`), which
bumps the world counter and invalidates the same set as a real change, and leaves
the program meaning what it did.

The graph holds **16 155 MethodInstance values and 52 443 edges**.

| Edit | Predicted | Invalidated | Survived | Missed | Edit |
| --- | --- | --- | --- | --- | --- |
| A leaf, `naive_fib` | 5 | 5 | **99.97%** | 0 | 0.8 ms |
| B middle, `routing_handle!` | 2 | 0 | **100.0%** | 0 | 2.0 ms |
| C widest, `_seam` (40 callers) | 212 | 222 | **98.63%** | 11 | 0.7 ms |

Every edit really replaced its method: the old `Method` object left the table in
all three cases, and the script checks this. Without that check a re-parse that
defines a *new* method instead of replacing the old one reports a cone of zero
and looks like a triumph.

**The property holds.** One edit to a real application leaves between 98.6% and
100% of the compiled code valid.

**The leaf is predicted exactly.** Five predicted, five invalidated, none missed
and none over.

**Nothing depends on the forwarding handler.** Editing `routing_handle!`, the
method every forwarded packet passes through, invalidated nothing at all. The
graph agrees: it records no caller. The simulator reaches its handlers by dynamic
dispatch, so no static edge exists. In this architecture the model code is
already cheap to change, and a cache would have nothing to rebuild.

**The forward-edge graph under-predicted, and the reason was that it was the
wrong graph.** On the widest edit, 222 nodes were invalidated and a graph built
by reversing the forward `edges` reached only 212. Eleven nodes were hit that it
did not reach, about 5% of the cone, among them a compiler-generated closure
`OmnetSimulator.NetworkModule.#_emit##8` and specializations of `Base.collect`,
`grow_to!` and `collect_to!`.

The first guess was wrong. It looked like abstract dispatch through the method
table, because `store_backedges` registers such a call as a pair of an invoke
signature and a `MethodTable`, and the decoder dropped those. The data refused it:
of the eleven missed nodes only three carried an abstract-dispatch edge, and all
eleven carried the same reason, `jl_method_table_disable`.

The real answer is simpler. **Julia keeps its own reverse graph and does not
derive it from the forward edges.** `mi.backedges` on a `MethodInstance` lists the
callers, `invalidate_backedges` in `src/gf.c` walks exactly that when a method is
replaced, and `get_next_edge` in `src/method.c` gives its encoding: a
`CodeInstance` entry is a caller, and a type entry is an invoke signature whose
caller is the entry after it. A reverse graph made by turning the forward edges
around is a different set, because it can only reach callers that the forward walk
had already found.

`GraphHarvest.backedge_cone` walks the backedges instead, and it needs no graph at
all: the answer is reachable from the seed `MethodInstance` values alone. Measured
against the same three edits:

| Edit | Reversed forward edges | Backedges of Julia |
| --- | --- | --- |
| A leaf | hit 5, missed 0, over 0 | hit 5, **missed 0**, over 0 |
| B middle | hit 0, missed 0, over 2 | hit 0, **missed 0**, over 2 |
| C widest | hit 211, **missed 11**, over 1 | hit 222, **missed 0**, over 2 |

**The backedge prediction is sound on every edit.** What over-approximation
remains is two nodes, and over-approximation is safe: it rebuilds a little more
than it must, and never leaves stale code.

The lesson for the design is direct. A cache must key its dependencies on the
backedges of Julia, not on the forward `edges` of a `CodeInstance`. The forward
edges say what an entry called. They do not say who is waiting on it.

## Phase 1 — answer the question before you build anything

This is the highest-value step, and it needs no cache, no store and no fork.

1. Build the application in one Julia process.
2. Walk every `MethodInstance` and its `CodeInstance` entries.
3. Read `edges` and build the graph.
4. Read `time_infer_total` and `time_compile` and give each node a cost.
5. Apply each edit class on paper: mark the changed methods, then take the
   transitive closure over the reverse edges.
6. Report, for each edit class:
   - the count of invalidated `MethodInstance` values, and the fraction;
   - the **cost** of the invalidated set, and the fraction of total cost.

The second number matters far more than the first. A cone of 5% of the nodes that
holds 60% of the cost is a bad result that a node count hides.

**Gate 1.** Compare the cost fraction against what Julia already achieves in
Phase 0. If a leaf edit invalidates a large share of the cost, no cache design
rescues it, and the project should stop or change its target. Write the number
down and decide in the open.

Cross-check the paper cone against reality with
`jl_debug_method_invalidation(1)`: make the edit for real and compare the logged
invalidations against the predicted set. If they disagree, the graph reader is
wrong, and every later number would have been wrong too.

## Phase 2 — one cell, native code only

Only if Gate 1 passes.

Keep the compiler exactly as it is. Let it infer everything. Cache only the last
artifact.

Define one cell:

```
CompileCell
    key           content address
    method        which method
    specialization  which signature
    dependencies  the keys it read
    object_code   the artifact
```

A first key, deliberately rough:

```
key = SHA256(julia version, LLVM version, target, compiler flags,
             method definition hash, specialization)
```

Do not chase a perfect key yet. The question is whether the architecture works.

Put the artifacts in a content-addressed store under
`~/.julia/reactive-compiler/`. A cell is immutable: a key names an artifact and
never names a different one. A change makes a new key and a new artifact. Publish
each artifact with a rename, so that two builds at once can share the store. (The
PackageCompiler base-sysimage cache had exactly this bug, and two agents on this
machine hit it.)

**Gate 2.** Measure the five edits again. Compare against Phase 0.

## Phase 3 — move the boundary up

Cache two steps instead of one:

```
MethodInstance  ->  optimized IR  ->  native code
```

An edit that changes the native code but leaves the IR valid then reuses the IR.
This is where the design starts to earn its keep, and it is also where the key
gets hard: the IR key must not mention anything that only the native step cares
about, such as the processor target.

## Phase 4 — capture the dependencies automatically

Stop listing dependencies by hand. Write an `AbstractInterpreter` with its own
`cache_owner`, and record an edge whenever a compiler computation reads another
cell. The supported hook is already there; this phase needs no fork.

At this point compare your recorded edges against `CodeInstance.edges`. They
should agree. If yours are wider, you over-invalidate; if narrower, you are
unsound, which is worse.

## Phase 5 — the real claim

The strong form of the hypothesis is not "a cache makes Julia faster". It is:

> Build cost is about proportional to the transitive invalidation cone of the
> edit.

Test that directly. Make twenty or more edits of varied size. For each one plot
the cost of the invalidated set against the measured build time. A straight line
through the origin is the result that would matter. Scatter means some hidden
fixed cost dominates, and you must find it before you claim anything.

## What we measure

Four numbers, in order of how much they mean:

1. **Cost reuse.** Reused seconds divided by total seconds, from the
   `time_infer_*` and `time_compile` fields.
2. **Cone size.** Nodes invalidated by one edit, and their share of cost.
3. **Compiler CPU time saved.** Cold CPU time minus incremental CPU time. This is
   better than wall time, which the linker, the filesystem and the neighbours all
   disturb.
4. **Wall time.** Last, and only when interleaved.

## What we do not build

Not in this experiment:

- a rewrite of inference;
- a rewrite of the LLVM integration;
- a rewrite of PackageCompiler;
- a new linker.

The order is: instrument, observe, cache, reuse. Move compiler computations into
real cells only after the numbers justify it.

## Risks

**The world-age model is both the competitor and the ground.** An edit bumps the
world counter and closes the `max_world` of existing entries. A content address is
a different notion of identity. How the two live together is the hard design
question, and Phase 4 is where it must be answered, not assumed.

**The link step does not disappear.** Perfect reuse still has to produce a
runnable artifact. `jl_dump_native` serializes one heap. Reuse of separate object
cells needs either incremental linking or the package-image path. Measure the
link cost in Phase 0 so that it can not surprise you later. On this machine a
system-image link measured under two seconds, which is small, but an app is not a
system image.

**Compressed and dropped IR.** `CodeInstance.inferred` may be a compressed string,
may be `jl_nothing` because the result was dropped to save space, or may be a
`UInt8` cost estimate. A cache of IR must handle all three.

## The first milestone

State it narrowly, so that it can be judged:

> Take a Julia 1.13 application. Change one leaf function. Restart Julia. Reuse
> cached native code for every `MethodInstance` that is still semantically valid,
> and beat the package-image baseline of Phase 0 by a large factor.

If a cold build takes minutes and the one-function edit then takes seconds
**measured against package images, not against a cold compiler**, the idea is
worth the larger project. The next question is then how far up the pipeline the
same model can be pushed.

## Progress

- [ ] Phase 0 — freeze the baseline, package images on.
- [ ] Phase 1 — harvest the graph and the costs. Report the cone of each edit class.
- [x] **Gate 1, first half** — the property holds. One edit to a real application
      of 16 155 compiled MethodInstance values leaves 98.6% to 100% of them valid,
      and the graph predicts a leaf edit exactly. Continue.
- [x] **Gate 1, second half** — the prediction is now sound. The reversed forward
      edges missed 11 of 222 nodes on the widest edit; the backedges of Julia miss
      none on any of the three. Key a cache on `mi.backedges`, never on the
      forward `edges`.
- [ ] Phase 2 — the native-code cell.
- [ ] **Gate 2** — measure the five edits again.
- [ ] Phase 3 — the inferred-IR cell.
- [ ] Phase 4 — automatic dependency capture through `AbstractInterpreter`.
- [ ] Phase 5 — the proportionality test.

## Decisions found during the work

(Record decisions here as the work proceeds.)
