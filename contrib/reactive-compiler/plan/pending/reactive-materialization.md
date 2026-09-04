# Persistent reactive materialization of a system image

The companion of [hypothesis-case.md](hypothesis-case.md). That plan asked
whether the invalidation cone of an edit is small. It is, and it is measured.
This plan says what to build on that answer.

Reviewed on 2026-09-04 against the source of Julia 1.13 and against the measured
phases of a PackageCompiler build. The review moved the target, reordered the
stages and replaced the hand-written artifact key with a recorded read set. The
section "Decisions found during the work" lists every change and its reason.

## The shape of the system

Two questions, kept apart. This division is the spine of the design.

> **The reactive compiler store answers:** which compiler artifacts are still
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
  recorded read set per artifact     (what inference and code generation
         │                            read to make it)
         │
  content-addressed store            persistent across processes;
         │                            holds emitted object code
         │  only the artifacts whose reads changed
         ▼
  PackageCompiler as materializer    links reused objects + new objects
         │                            + a fresh heap
         ▼
   system image / application
```

The store is persistent. A system image is a **snapshot** of the store, the way
a commit is a snapshot of a Git object database. Making a new image never mutates
an old one, so rollback is free and one store can materialize several images.

## Where the time goes

A `create_app` of `examples/MyApp`, native target, warm base cache, in the
8-CPU build lane (measured on the `parallel-build` branch of PackageCompiler):

| Phase | Time | Share |
| --- | --- | --- |
| `ensurecompiled` | 113 s | 22% |
| `run_precompilation_script` | 41 s | 8% |
| `create_sysimg_object_file` | 343 s | 67% |
| link, executable, copies | about 10 s | 2% |
| **total** | **509 s** | |

`MyApp` is a trivial application. The object archive is 342 MiB. Almost none of
it is the application.

The reason is in `Compiler/src/precompile.jl`. The `--output-o` child calls
`compile_and_emit_native`, which walks every loaded module
(`collect_all_method_defs(nothing, mod_array)`), and `enqueue_specialization!`
takes every `CodeInstance` whose `invoke` pointer is set. That includes all the
code that came from the base system image. `jl_emit_native` then generates LLVM
IR for all of it in one thread, and the partitions are optimized in parallel.
**Every build re-emits Base.**

So the reuse that matters is the reuse of **emitted object code**, and the code
to reuse is mostly Base and the packages, which no edit touches. Reuse of
inference results is a second-order term: the sum of `time_compile` over the
whole routing model is 0.77 s.

The in-process measurements still hold. One edit leaves 98.63% to 100% of the
16 155 compiled `MethodInstance` values of the routing model valid, the edit
costs 0.8 ms to 2.0 ms, and the backedge walk predicts the cone exactly. They say
that the *set* to re-emit after an edit is small. They do not make a build fast,
because today nothing keeps the emitted code.

State the target as a fresh process, never as an edit in a live session:

> Change one function. **Start a new Julia process.** Materialize the application.
> Beat `create_app` with a warm base cache, measured on the same lane.

## The facts this design must be built on

Facts 1 to 6 were measured on Julia 1.13.0-rc3. Facts 7 to 13 were read in the
source of the same Julia. Each one contradicts an obvious assumption.

**1. Depend on the backedges in a live process.** `mi.backedges` is the reverse
graph that `invalidate_backedges` walks. A reverse graph made by turning
`CodeInstance.edges` around missed 11 of 222 invalidated nodes on the widest
edit. The backedge walk missed none. The missed nodes were specializations of
closure methods that the edit also replaced, and code compiled for them.

**2. A constant is a validity condition, not an edge.** `const SCALE = 10` used
by `f(x) = x * SCALE` appears in no forward edge. Julia still invalidates
correctly, through `Core.BindingPartition` and its world range. The binding's
`backedges` field was undefined.

**3. Two different signals mean "invalidated".** A dependent keeps its
`CodeInstance` and gets `max_world` closed. The edited method loses its
specializations outright. Count both.

**4. Julia pays at the edit.** Time the edit or the load, never the call after.

**5. `time_infer_self` does not sum.** Weigh by `time_compile`.

**6. `MethodInstance` granularity is cheap.** 16 155 nodes, 52 443 edges, 46 ms
to harvest. One cell per `MethodInstance` costs nothing to walk.

**7. `--output-o` already writes many objects.** `jl_dump_native_impl` writes one
archive with the members `text#0.o` to `text#N.o` (one per image thread),
`metadata.o` (the image tables) and `sysimg.o` (the serialized heap). The
partitions refer to each other by symbol name with hidden visibility
(`materializePreserved`). The link side of PackageCompiler,
`create_sysimg_from_object_file`, takes a `Vector` and links with
`--whole-archive`. "One object" was the wrong blocker.

**8. What is unstable between two builds is the real blocker.**

- Names. Every emitted function and every global slot carries the value of one
  process-wide counter, `globalUniqueGeneratedNames`: `j_<name>_<n>`,
  `jfptr_<name>_<n>`, `jl_global#<n>` (`codegen.cpp`, `cgutils.cpp:404`).
- Partition membership. `partitionModule` balances by weight, so a function moves
  between `text#i.o` files from one build to the next.
- Tables. `construct_vars` bakes `jl_fvars` and `jl_gvar` index tables into every
  partition, and the indices are the emission order of that build. The heap in
  `sysimg.o` names a function by its index and fills every `jl_global#` slot from
  a relocation list in the same order.

An object from build A therefore can not be linked into build B, even when its
machine code is identical. This is a stable-interface problem, not a compiler
problem.

**9. The emission worklist is a Julia array.** `jl_create_native` calls
`compile_and_emit_native`, which returns the list of code to emit, and
`jl_emit_native(codeinfos, ...)` emits exactly that list. A materializer can
decide in Julia what to emit.

**10. Worlds do not cross processes. Edges do.** `Compiler/src/reinfer.jl`
re-verifies every edge of a loaded `CodeInstance` against the current world:
`verify_method_graph`, `verify_call`, `verify_invokesig` and
`binding_was_invalidated`. It reads `codeinst.edges`. Package images depend on
this check, so it is the validity check that exists for inference results.

**11. A custom `cache_owner` is the wrong tool for an application.**
`enqueue_specialization!` skips a `CodeInstance` whose owner is not `nothing`,
with the comment "from a foreign interpreter", and runtime dispatch reads only
the native cache. The store must observe the native cache.

**12. Package images are coupled by build id.** `stale_cachefile` rejects an
image when a dependency has a different build id. A rebuild of one package
therefore invalidates every image above it, with or without a code change.
Content keys remove that cascade. It is a second prize.

**13. Julia tracks one stage, rediscovers part of it, and leaves the last stage
blank.** Inference records calls, invokes and method-table queries in `edges`. A
constant read is not recorded: when a binding changes,
`invalidate_method_for_globalref!` walks every scanned method of the module and
scans its lowered source for the `GlobalRef`
(`Compiler/src/bindinginvalidations.jl`). Code generation records nothing. What
the object of `g` depends on — the calling convention of its callee `f`, type
layouts, the code generation parameters, the target — is written down nowhere.

## The store is a cell store

The plan of 2026-09-03 gave a hand-written key:

```
key = hash(julia commit, LLVM version, processor target, build flags,
           method definition, specialization,
           the keys of everything it depends on,
           the identity of every binding partition it read)
```

That formula is a list of dependencies that a person maintains. Its first draft
forgot the binding partitions, and fact 13 says that the code generation stage
has dependencies nobody has listed. Each omission is a hole through which the
store serves stale code.

Use the cell model of ProjecturEd instead. A computed cell records every cell it
reads while it computes, and it is valid while every recorded read still gives
the same value. The store persists that: an artifact is a value plus its
recorded reads, and each read is a query and the hash of its value.

**What the model deletes.** The store has no invalidation code.

- Validity is a pull. Run the recorded reads again and compare the hashes. The
  function that records the reads in the producing process is the function that
  checks them in the consuming process. One code path, not a record path and a
  verify path.
- No backedges are stored. A pull never needs to find dependents.
- No worlds, no "closed world" detection, no cone computation. A miss is a key
  that is absent. Fact 3 is a fact about the runtime; the store never meets it.
- Inference can be skipped. The stored read list makes the key computable
  before the computation runs: replay the previous reads, and if every hash
  matches, reuse the value. This is what Stage 3 needs, and nothing else.

This is also the model of Salsa in rust-analyzer.

**Where the model stops.** Julia's own machinery stays: `mi.backedges`,
`invalidate_backedges`, `bindinginvalidations.jl`, `reinfer.jl` and the world
ages. They serve a running process with live redefinition and running frames,
and a world age is how dispatch selects code for a task. The store never
redefines anything; a build process defines everything once. The store does not
replace that code. It consumes `edges` as the recorded reads of inference, and
it adds recorders only where Julia records nothing. `edges` plus `reinfer.jl`
is already the cell model for one stage, written by hand per kind of edge.

**One mismatch.** A cell graph has no cycles. Mutually recursive methods are a
cycle. Julia's inference and `verify_method_graph` both treat a strongly
connected component as one unit, and the store must do the same: one cell per
component.

The rules of the model, applied here:

- **A cell is a query with a value, never a data structure.** "The methods that
  match this signature in this table" is a query, and its value is the match
  list. "No other method matches" is then a recorded value, so negative
  dependencies are covered. `verify_call` in `reinfer.jl` is exactly this check
  for one kind of query.
- **The key is derived, not designed.** The key of an artifact is the hash of its
  recorded reads. Nothing is listed by hand.
- **Record at choke points, not at every operation.** The compiler reads outside
  state through a small number of accessors. A recorder that is active while one
  artifact is produced, and that is called from those accessors, sees every read.
  Do not make every compiler operation a cell.
- **A query must survive a process.** A cell in the editor holds a live
  reference; a recorded read here must name its query in a form a new process
  can resolve — a signature and a method table, a module path and a name, a
  type. Design the query names first.

Three levels, each with its own recorder:

| Level | What is read | Who records it today | What to build |
| --- | --- | --- | --- |
| build | Julia commit, LLVM version, target, flags, base image id, package list | nothing | a few static cells |
| inference | callees, invoke signatures, method-table queries, binding partitions | `edges` for the first three; a source scan for bindings | a `GlobalRef` scan of the lowered code, turned into recorded partition reads |
| code generation | the callee's calling convention, type layouts, `cgparams`, `ccall` targets, the objects behind the global slots | nothing | a recorder at the choke points of `codegen.cpp`, active per `CodeInstance` inside `jl_emit_native` |

For the inference level, keep Julia's `edges`. They are the compiler's own record
of its reads, `reinfer.jl` verifies them, and every package image already stands
on them. Add only the binding reads, which Julia rediscovers by a scan of the
lowered code; the same scan, run once at record time, turns them into recorded
reads with the partition's restriction hashed as the value.

For the code generation level the recorder is also the **discovery tool**. Nobody
knows the complete list of what code generation reads. Stage 0 finds it
empirically, by a diff of two builds; the recorder then makes it explicit.

## The design, corrected

### Two names, two purposes

- The **symbol** of an emitted function comes from the identity of its
  `MethodInstance`: the signature, the module and the name of the method. It is
  stable between builds. An object that calls `f` keeps linking when `f` changes.
- The **store key** of an emitted object comes from its recorded reads. It
  changes when anything it read changes. It decides reuse.

Identity-based symbols add no unsoundness: when the method of `f` changes, every
caller of `f` is invalidated by the backedges anyway, so no reused caller ever
links to a callee that changed under it.

### The unit of reuse

Three candidates. Stage 1 must choose by measurement.

1. One object per `CodeInstance`. More than 100 000 archive members. The linker
   handles it; the archive does not stay small.
2. Stable groups. Partition by a stable rule, such as the module of the method,
   instead of by weight. A change re-emits the groups it touches.
3. Delta objects. Keep the previous objects as they are. Emit every miss into one
   new object. Make the emitted symbols weak, and link the delta first, so that
   the new definition wins and no old object is rewritten. Dead code accumulates
   until a compaction.

Candidate 3 is the recommendation for development mode, because it rewrites
nothing. Release mode compacts: it re-emits everything with stable names into
stable groups.

### The materialization

```
new image = sysimg.o    (the heap; always rebuilt, seconds)
          + metadata.o  (the tables; always rebuilt, built from names)
          + the text objects the store already holds
          + one delta object for the misses
```

The heap is always rebuilt. It is the full state of the process, and it is
cheap. The reused objects must not depend on its layout. That is the whole
content of Stage 1.

## The stages

Build in this order, and stop at any gate that fails. The Julia patch comes
first, because fact 8 says nothing can be reused without it.

### Stage 0 — measure the ceiling

No change to Julia.

1. Build the routing application twice from the same source. Compare the
   emitted functions after the counter suffixes and the `jl_global#` numbers are
   canonicalized. This measures determinism. A build that is not deterministic
   can not be reused.
2. Build it again after a one-function edit of class C. Count the functions
   that are identical after canonicalization.
3. In one process, with the harness of `tool/prove_routing.jl`, compute the
   recorded-read key of every `CodeInstance` before and after the edit. The set
   of changed keys must equal the set of invalidated nodes. Zero missed, as with
   the backedge walk.
4. For every function that differs between the two builds although its key did
   not change, find the read that explains the difference. That list is the
   input of the code generation recorder.

Use `--output-asm` or `--output-bc`; the archive members can be split by
function with a script.

**Gate 0.** At least 98% of the functions are identical after canonicalization,
and the key-changed set equals the invalidated set. If not, find why before
building anything.

### Stage 1 — layout-independent objects

The Julia patch, in `src/aotcompile.cpp` and `src/staticdata.c`:

- name every emitted function and global slot by identity, not by counter;
- replace the weight-balanced partition by the unit of reuse chosen above;
- build the `jl_fvars` table in `metadata.o` from symbol names, so that a reused
  object needs no index table of its own;
- make the global slots re-bindable: record, for every `jl_global#` slot, the
  object it names in a form a new process can resolve, so that a new heap can
  fill the slots of an old object.

**Gate 1.** A rebuild with no edit links every text object of the previous
build with a fresh `sysimg.o` and `metadata.o`, boots, and runs the
application.

### Stage 2 — key-driven delta emission

The materializer computes the recorded-read key of every `CodeInstance` in the
fresh process. A hit reuses the object from the store. A miss goes to the delta
object. The cone is never computed as such; it falls out of the key comparison.

**Gate 2.** After a one-function edit of the routing model, the number of
emitted functions equals the size of the cone, and `create_sysimg_object_file`
costs the heap, the link and the cone. The 343 s of a full emission is the
number to beat.

### Stage 3 — the serial front

`ensurecompiled` (113 s) and `run_precompilation_script` (41 s) load the
packages and the application from source, because `get_julia_cmd` passes
`--pkgimages=no`. Three ways to cut it, to be chosen by measurement after
Stage 2:

- load package images in the build child;
- inference cells in the store: replay the stored reads of an inference
  artifact, and reuse its value when every hash matches;
- a compiler process that stays alive between builds, so that the in-process
  cache is the store. This does not shorten the emission, because
  `--output-o` re-emits everything, and a heap with disabled methods needs care.

### Stage 4 — PackageCompiler as materializer

Give PackageCompiler a new entry point beside `create_app`:

```julia
materialize(store, snapshot; output = "myapp")
```

It receives the text objects of a snapshot and a delta, and links them. It does
not decide what to compile. Two pieces of the ground work already exist on the
`parallel-build` branch: the fresh base system image is cached in the depot and
keyed by the Julia commit, the target and the build flags; and the copies of an
application run beside the compiler.

## Development mode and release mode

Julia already has a development mode: package images and Revise. What this
design adds is a unit smaller than a package, and no build-id cascade.

**Development.** Deltas accumulate on a stable base image. The edit-and-run
cycle costs the cone, the heap and the link.

**Release.** Compact the store and materialize one image with stable groups.

This keeps the image format out of the incremental path. The image is an output
of the store and never the store itself.

## What not to build

- Do not rewrite inference. Do not rewrite the LLVM integration.
- Do not invent a dependency graph for inference. Julia has one, `reinfer.jl`
  verifies it, and every package image stands on it. Add recorded reads only
  where Julia records nothing.
- Do not make every compiler operation a cell. Record at the choke points.
- Do not start with a persistent inference cache. It attacks the smallest term.
- Do not use a custom `cache_owner` for the application. The emitter and the
  runtime skip foreign entries.
- Do not key anything on a file timestamp or a source hash. A source hash of
  `f` is unchanged when `SCALE` changes, and the native code of `f` is then
  wrong.

## The recorded reads, by level

A build-level read names the Julia commit, the LLVM version, the processor
target, the build flags and the build id of the base image.

An inference-level read names, for a `CodeInstance`: the lowered code of its
method and its signature; each edge as `reinfer.jl` reads it; and each binding
partition that the lowered code refers to, with the hash of the partition's
restriction as the value.

A code generation read names what the recorder saw: the calling convention of
every callee, the layout of every type it touched, the `cgparams`, the `ccall`
targets and the identity of every object behind a global slot. The list grows
as Stage 0 finds reads.

An object key hashes all three levels. An inference key hashes the first two,
and never the target.

## Where the code goes

- A patch to Julia — Stage 1 and the code generation recorder. It comes first,
  not last, because nothing can be reused without it. Keep it in
  `src/aotcompile.cpp`, `src/staticdata.c` and a few accessors of
  `src/codegen.cpp`.
- `ReactiveCompiler` — the store, the recorded reads, the keys, the replay and
  the cache policy. `src/GraphHarvest.jl` and `src/MethodEdit.jl` in this
  directory are its first pieces.
- `ReactivePackageCompiler` — the materialize entry point and the delta
  handling. Sits beside the `parallel-build` branch.

## Milestones

- [ ] **M0** — the ceiling is measured: determinism, the identical fraction after
      one edit, and key-changed equals invalidated.
- [ ] **M1** — a rebuild with no edit reuses every text object of the previous
      build and the image runs.
- [ ] **M2** — a rebuild after a one-function edit emits only the cone, and the
      emission time is reported against 343 s.
- [ ] **M3** — the serial front is cut by the cheapest of the three ways.
- [ ] **M4** — `materialize(store, snapshot)` links reused and new objects into a
      working application, and beats `create_app` with a warm base cache,
      measured from a fresh process on the same lane.

## Decisions found during the work

**2026-09-04, review.**

- The target moved from "reuse inference" to "reuse emitted object code". The
  measured build spends 67% in `create_sysimg_object_file`, and
  `enqueue_specialization!` shows that it re-emits Base every time.
- The stages were reordered. The Julia patch is first, because fact 8 says no
  object can be reused before names, partitions and tables are stable. The
  persistent inference cache moved to Stage 3 as one option among three.
- "Stage 1 may need no patch" was withdrawn. A custom `cache_owner` is skipped
  by the emitter and by dispatch (fact 11).
- "Check their worlds on load" was withdrawn. Worlds do not cross processes;
  `reinfer.jl` replays the edges against the current world (fact 10).
- The hand-written key was replaced by a recorded read set, on the user's
  proposal to use the cell model of ProjecturEd. The compiler records the
  inference reads, rediscovers the binding reads by a source scan, and records
  no code generation read (fact 13). The cells go where the blanks are.
- The store became a cell store with no invalidation code, on the user's
  second point: a pull over stored reads replaces backedges, worlds, the cone
  and a separate verify path. Julia's runtime machinery stays, because it
  serves live redefinition, which the store never does. A strongly connected
  component of methods is one cell.
- "One object out of `--output-o`" was withdrawn as the blocker. The output is
  already an archive of partitions (fact 7). The blocker is the counter-based
  naming and the index tables (fact 8).
- Symbols are named by identity and store keys by content. The two were one
  thing in the first draft.
