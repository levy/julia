# Persistent reactive materialization of a system image

The companion of [hypothesis-case.md](hypothesis-case.md). That plan asked
whether the invalidation cone of an edit is small. It is, and it is measured.
This plan says what to build on that answer.

## The shape of the system

Two questions, kept apart. This division is the spine of the design.

> **The reactive compiler database answers:** which compiler artifacts are still
> valid?
>
> **PackageCompiler answers:** given a set of valid artifacts and a few new ones,
> how do I materialize a runnable system image?

PackageCompiler stops being the thing that discovers what to reuse. It becomes
the finalizer. Nothing rebuilds a system image in order to find out what could
have been kept.

```
    source tree
         │
         ▼
  semantic dependency graph        (Method → MethodInstance → inference
         │                          → optimized IR → LLVM → object)
         │
  content-addressed store          persistent across processes
         │
         │  only the artifacts that changed
         ▼
  PackageCompiler as materializer
         │
         ▼
   system image / application
```

The store is persistent. A system image is a **snapshot** of the store, the way
a commit is a snapshot of a Git object database. Making a new image never mutates
an old one, so rollback is free and one store can materialize several images.

## Read this before anything else: what the problem actually is

The measurements move the target. Inside a live Julia process the compiler
already does what this design wants:

- One edit to the routing model leaves **98.63% to 100%** of its 16 155 compiled
  `MethodInstance` values valid.
- The edit itself costs **0.8 ms to 2.0 ms**, because Julia re-infers eagerly at
  the redefinition.
- The prediction of what dies is **exact** when it walks the backedges.

So the compiler is not the problem. **The process is.** All of that state dies
when Julia exits, and PackageCompiler then rebuilds from nothing. Package images
persist a part of it, at package granularity, and only for code that lives in a
package.

Therefore state the target as a fresh process, and never as an edit in a live
session:

> Change one function. **Start a new Julia process.** Materialize the application.
> Beat what PackageCompiler does today, with package images enabled.

A measurement that edits in a live session and reports milliseconds measures
nothing, because Julia already gives that for free.

## The facts this design must be built on

Each one was measured on Julia 1.13.0-rc3, and each one contradicts an obvious
assumption.

**1. Depend on the backedges, never on the forward edges.** `mi.backedges` is
the reverse graph that Julia keeps and that `invalidate_backedges` walks. A
reverse graph made by turning `CodeInstance.edges` around is a *different set*: it
missed 11 of 222 invalidated nodes on the widest edit, among them a closure and
the `Base.collect` specializations compiled for it. The backedge walk missed
none. The forward edges say what an entry called; they do not say who waits on it.

**2. A constant is a validity condition, not an edge.** `const SCALE = 10` used
by `f(x) = x * SCALE` appears in no forward edge at all. Julia still invalidates
correctly: changing it closed the world of `f` and of `h`, left the unrelated `g`
open, and both callers saw the new value. The mechanism is
`Core.BindingPartition`, which carries `min_world` and `max_world`; a
redefinition opens a new partition and closes the old one. The binding's
`backedges` field was **undefined**, so the users of a constant can not be
enumerated from it.

  The consequence for the key: an artifact must record the **binding partitions
  it was compiled against, with their world ranges**, and check them on load.
  This is a validity check, not a graph edge, and a design that only stores edges
  will serve stale code after a constant changes.

**3. Two different signals mean "invalidated".** A method that *depends* on the
edited one keeps its `CodeInstance` and has `max_world` closed. The edited method
loses its specializations outright: they leave the cache chain while the object
still reads as open. Count both. Counting only closed worlds reported zero
invalidation for the very method that was edited.

**4. Julia pays at the edit.** The redefinition costs the cone; the next call
costs nothing. Time the edit or the load, never the call after it.

**5. `time_infer_self` does not sum.** Against 2.6 s of measured compilation the
sum of `time_compile` is 0.77 s, which is the right order, and the sum of
`time_infer_self` is 28.55 s, which is not. Weigh by code generation. An
inference cost that sums needs the timing tree of `@snoop_inference`.

**6. `MethodInstance` granularity is cheap enough.** The routing graph is 16 155
nodes and 52 443 edges, and harvesting it takes **46 ms**. This settles the
question of how fine the reactive layer should be: one cell per `MethodInstance`
costs nothing to walk. Do not put a cell on every compiler operation.

## The extension points that already exist

Stage 1 may need no patch to Julia at all.

- `CodeInstance.owner` is documented in `src/julia.h` as "compiler token this
  belongs to", with `jl_nothing` reserved for the native compiler. An external
  compiler puts its own entries there.
- `AbstractInterpreter` requires `cache_owner`, so a custom interpreter owns its
  own code cache without a fork.
- `Compiler/src/reinfer.jl` already validates external entries on load and
  re-infers only the stale ones. That machinery is the model to copy.

The unproven half is not interception. It is **serialization**: writing a
`CodeInstance` to disk and revalidating its worlds in a new process. Julia does
this for package images in `src/staticdata.c`, and that is the code to read.

## The stages

Build in this order, and stop at any gate that fails.

### Stage 1 — a persistent inference cache

Prove the smallest end-to-end claim: start a new process, load the store, reuse
inference results, and recompute only the cone of the edit.

- Write an `AbstractInterpreter` with its own `cache_owner`.
- Record, for each entry, its backedges and the binding partitions it read.
- Serialize and reload. Revalidate on load the way `reinfer.jl` does.
- No PackageCompiler, no object files, no linking.

**Gate 1.** In a fresh process, does the cache return more than it costs to
validate? Measure cold inference against warm inference, both in a new process.

### Stage 2 — persistent optimized IR

Move the boundary up one step, so that an edit which changes native code but
leaves the IR valid reuses the IR. The key must not mention anything only the
native step cares about, such as the processor target.

### Stage 3 — persistent object code

Cache the output of the code generator. A hit then skips the whole back end.

**This is where the design meets its hardest constraint, and it should be faced
here rather than discovered in Stage 4.** Julia's `--output-o` emits **one**
object for the whole image; there is no supported way to get one object per
`MethodInstance` out of it. The link side is ready —
`create_sysimg_from_object_file` already takes a `Vector` of object files and
links them with `--whole-archive` — but nothing produces the parts. Stage 3 must
answer: can the code generator be made to emit per-artifact objects, and at what
cost in image size and start-up? If it can not, the design stops at Stage 2 and
is still worth having.

### Stage 4 — PackageCompiler as materializer

Give PackageCompiler a new entry point beside `create_app`:

```julia
materialize(store, snapshot; output = "myapp")
```

It receives a set of object artifacts, some reused and some new, and links them.
It does not decide what to compile.

Two pieces of the ground work already exist in the PackageCompiler branch beside
this one:

- the fresh base system image is cached in the depot and keyed by the Julia
  commit, the processor target and the build flags, so the stable half of the
  image is already reused across builds;
- the copies of an application already run beside the compiler, so materialize
  time is compiler time and nothing else.

## Development mode and release mode

Two ways to use the same store, and they want different materializations.

**Development.** Do not build a monolithic image after every change. Keep a
stable base image, the persistent store, and load new native code beside it. The
edit-and-run cycle then costs the cone and the load, and nothing else.

**Release.** Compact the store and materialize one image through PackageCompiler.

This keeps the image format out of the incremental path. The image is an output
of the store and never the store itself.

## What not to build

- Do not rewrite inference. Do not rewrite the LLVM integration.
- Do not invent a dependency system. Julia has one, and it is more correct than a
  new one will be for a long time. Read `mi.backedges`.
- Do not make every compiler operation a cell.
- Do not key anything on a file timestamp or a source hash. A source hash of `f`
  is unchanged when `SCALE` changes, and the native code of `f` is then wrong.

## The artifact key

```
key = hash(julia commit, LLVM version, processor target, build flags,
           method definition, specialization,
           the keys of everything it depends on,
           the identity of every binding partition it read)
```

The last line is the one that is easy to leave out and that makes the cache
unsound.

## Where the code goes

Three parts, so that the Julia patch stays small and last.

- `ReactiveCompiler` — the store, the artifact addresses, the instrumentation and
  the cache policy. Depends on no fork. `src/GraphHarvest.jl` and
  `src/MethodEdit.jl` in this directory are its first pieces.
- `ReactivePackageCompiler` — the materialize entry point and the object
  collection. Sits beside the PackageCompiler work on the `parallel-build`
  branch.
- A patch to Julia — only what the first three stages prove is missing. Write it
  last.

## Milestones

- [ ] **M1** — a fresh process reuses inference results for a program of at least
      10 000 `MethodInstance` values, and recompiles only the cone of a
      one-function edit. Sound against a constant change as well as a method
      change.
- [ ] **M2** — the same for optimized IR.
- [ ] **M3** — answer whether per-artifact object emission is possible at all.
      Stop here honestly if it is not.
- [ ] **M4** — `materialize(store, snapshot)` links a mixture of reused and new
      objects into a working application, and beats `create_app` with package
      images enabled, measured from a fresh process.

## Decisions found during the work

(Record decisions here as the work proceeds.)
