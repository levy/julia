# Persistent reactive materialization of a system image

The companion of [hypothesis-case.md](hypothesis-case.md). That plan asked
whether the invalidation cone of an edit is small. It is, and it is measured.
This plan says what to build on that answer.

The system as built — the design, the invariants and the reasons, without
the chronology — is described in
[doc/architecture.md](../../doc/architecture.md). This plan stays the
chronological record.

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

**14. Two builds of the same source give different object code, for three
reasons, and none of them is the code.** Measured in M0 on the routing model,
one partition, 55 306 functions, with the tools in `tool/m0_*.py`:

- The LLVM module that code generation emits is identical in 99.98% of its
  functions. The 10 that differ are `_enum_hash` instances: `@enum` folds
  `hash(T)` into an immediate, and `tn->hash` mixes in `build_id.lo`, which
  `module.c` draws from `jl_hrtime()` and `jl_rand()` for every module the
  process creates (`datatype.c:84`, `module.c:512`, `base/Enums.jl:219`). A
  reused object would carry the hash of an old process.
- After the LLVM pipeline, 96.3% are identical. Every difference is the slot
  that a root got in the GC frame: `ColorRoots` in
  `src/llvm-late-gc-lowering.cpp` walks `std::map<Value*, int>` containers
  ordered by pointer. The back end adds nothing of its own: the stack offsets,
  the `vmovups`/`vmovaps` choice, the schedule, the register assignment and the
  spills all follow the slot layout. With the slot layout masked, 99.2% of the
  functions are identical at the pass level and 98.5% at the object level.
- With eight partitions, another 2.5 points are lost: a function is optimized
  in the partition it landed in, so its inlining and its `_j_const` references
  depend on the partition.

Two more names are counters and not content: `get_pointer_to_constant` names a
merged constant `_j_const#<count>` (`codegen.cpp:2093`), and a string is
`_j_str_<content>#<count>`.

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

**Done, 2026-09-05.** The builds are `tool/m0_build.jl`; the comparisons are
`tool/m0_objdiff.py` (bytes with the relocations masked), `tool/m0_asmdiff.py`
(the disassembly with every symbol reference canonical) and `tool/m0_bcdiff.py`
(the bitcode before and after the pipeline); the keys are `tool/m0_keys.jl` on
`src/ReadKey.jl`. `--output-unopt-bc`, `--output-bc` and `--output-o` can be
written by one build.

1. Same source, one partition: 96.4% identical; 98.5% with the frame slots
   masked. Eight partitions: 93.9% and 95.3%. The causes are fact 14.
2. One edit (`pk.hop_count += 1` to `+= 2` in `routing_handle!`): 96.3% and
   98.4%, the same as the noise. Above the noise of a third build, the edit
   changes one function, `julia_routing_handle!`; its `jfptr` adapter is
   unchanged. The cone of a class C edit is one object.
3. Keys, 16 011 nodes in 15 790 components, the largest 173, computed in
   5.4 s: the key-changed set is `{routing_handle!}`, the invalidated set is
   `{routing_handle!}`, and both differences are empty. Julia invalidates the
   replaced method by killing its typemap entry; the code instances of the
   replaced method keep `max_world == ∞`, and no caller had a backedge to it.
4. Nothing differs because of a read that the key misses. The differences are
   the three causes of fact 14, and one read that code generation folds: the
   `build_id` of a module, through the type hash of an `@enum`.

The gate is passed for the keys exactly, and for the objects at 98.5% with
the frame slots masked, with the remainder explained. One lesson of the
harness: the key computation runs Julia code, `sprint(show, ::Expr)` among it,
and that code is a node of the graph. Compile the harness before the first
harvest, or twelve nodes of `Base` change key without an edit.

Build cost on this machine, the numbers to beat: eight threads 103 s and
8.3 GB; one thread 265 s to 280 s and 6.3 GB to 8.2 GB.

### Stage 1 — layout-independent objects

The Julia patch, in `src/aotcompile.cpp`, `src/staticdata.c`,
`Compiler/src/typeinfer.jl` and `Compiler/src/precompile.jl`. The design is
the entry "2026-09-05, Stage 1 design" below; the parts:

- [x] the new build B boots from the image A (`julia -J A.so --output-o B.a`)
      with `JULIA_REACTIVE_REUSE=1`; the runtime keeps a copy of the parsed
      image and the world counter after the restore;
- [x] `jl_reactive_image_ids(ci, ...)` maps a code instance whose native
      pointers are in A's function table to A's function ids;
- [x] `compile!` reuses a code instance that is valid in the world and has
      image ids, and returns the reused list beside `codeinfos`;
- [x] `jl_create_native` rewrites the ids of the delta to the append-only id
      spaces of A: function ids `+ nfvarsA`, global slots `+ ngvarsA`, shards
      `+ nshardsA`, and prepends A's live slot values to the roots;
- [x] every defined global object of the delta gets the suffix `.r<nshardsA>`
      after `makeSafeName`, so that A's objects and B's objects link together;
- [x] the image header and the shard table of B count A's shards and B's
      shards together; the delta calls a reused function by the symbol
      that the image names for it (the direct call of Stage 2; the
      `emit_tojlinvoke` trampoline stays for three shapes);
- [x] link A's text objects with B's `sysimg.o`, `metadata.o` and delta into
      `B.so`; boot; run the routing example.

**Gate 1.** A rebuild with no edit links every text object of the previous
build with a fresh `sysimg.o` and `metadata.o`, boots, and runs the
application. **Passed 2026-09-05**, by `tool/m1_gate1.sh`; the numbers are in
the entry "2026-09-05, Gate 1" below. The delta of a rebuild with no edit is
309 functions at the first rebuild, 6 at the second and 0 at the third.

### Stage 2 — the delta of an edit is the cone

A rebuild that boots from the previous image has the key for free. Julia's
own invalidation bounds the `max_world` of every code instance that an edit
reaches through the backedges, and a code instance that is not valid in the
world of the build is not reusable. So the cone is never computed as such; it
falls out of the reuse test of Stage 1. The recorded-read key of the design
stays for the store of Stage 3 and Stage 4, where a fresh process has no
image to inherit the invalidation from.

- [x] `tool/m0_build.jl` applies the edit inside the build (`RC_EDIT=1`) and
      prints the cone: the specializations of the replaced method, the code
      instances that the edit closed, and the method instances that the
      scenario makes after the edit;
- [x] `tool/m1_gate1.sh` builds E from `D.so` with the edit, F from `sys.so`
      with the edit, and compares the delta of E with the cone.
- [x] the delta calls a reused specialization by its symbol: the image
      names every function of its table (`jl_fvar_names_<shard>`, image
      format version 2), `resolve_workqueue` declares the image's symbol
      for a callee with image ids, and the link binds the hidden
      declaration to the text object of the earlier build. Done
      2026-09-05; the entry "2026-09-05, the direct call" below.

**Gate 2.** After a one-function edit of the routing model, the number of
emitted functions equals the size of the cone, and `create_sysimg_object_file`
costs the heap, the link and the cone. The 343 s of a full emission is the
number to beat. **Passed 2026-09-05**; the numbers are in the entry
"2026-09-05, Gate 2" below. The delta of E is 14 functions for 7 method
instances, all in the cone; E takes 19.0 s and 1.1 GB, F 119.8 s and 8.0 GB,
and both run the model to the same hash with the edit applied.

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

**Mostly dissolved by the chain, 2026-09-05.** A build that boots from the
previous image loads nothing from source: the front of the Gate 1 and Gate 2
rebuilds is 1.3 s against 27 s in the full build, and against the 113 s + 41 s
of the PackageCompiler lane. What remains of the serial front in the chain is
the workload itself. The three options above stay only for the recorded-read
store, where a build without a previous image wants to skip inference.

### Stage 4 — the materialize entry point

The workflow of a real edit, in one call. The order that Gate 2 dictated:
boot from the previous image, apply the source changes, run the workload,
emit the delta, and link.

**Built 2026-09-05**, in this directory, as the standalone driver
`src/Materialize.jl` with `src/SourceDiff.jl` and `tool/m4_child.jl`:

- A **store** is a directory that persists across processes. `store.toml`
  names the patched Julia, the project, the packages, the tracked source
  files with the module that includes each, and the workload; one snapshot
  per build holds its text objects, its linked image, and a copy of the
  tracked sources.
- `materialize(store)` spawns a fresh child that boots from the image of the
  latest snapshot, applies the changes of the tracked files, runs the
  workload, and emits the delta at exit; the driver links the text objects
  of the whole chain with the fresh `sysimg.o` and `metadata.o`. An empty
  store gives the full build through the same path.
- `SourceDiff.changed_expressions` compares two versions of a file without
  line numbers, descends into `module` blocks, and answers only the changed
  top-level expressions with the module path of each. The child evaluates
  exactly those, in their modules. A removal is reported and not applied.

**Gate 4.** After the M0 edit applied to the file on disk, `materialize`
emits the cone of Gate 2 and nothing else, the image runs the edit, and a
further no-edit materialize converges to an empty delta. **Passed
2026-09-05** by `tool/m4_gate.sh`; the numbers are in the entry "2026-09-05,
M4" below. The edit build takes a 20.8 s wall against 117.2 s for the full
build on the same lane.

**Open.** The entry point lives beside the M0 tools, not inside
PackageCompiler; the executable bundle of `create_app` (the launcher, the
copied artifacts) is not produced — the product is the image plus a runner.
Two pieces of the ground work for that integration exist on the
`parallel-build` branch: the fresh base system image is cached in the depot
and keyed by the Julia commit, the target and the build flags; and the
copies of an application run beside the compiler.

### Stage 5 — PackageCompiler compiles the application incrementally

The M4 loop, moved into PackageCompiler, on the application that ships: the
`routing` sample binary of omnet-julia (`bin/build_omnet_legacy_sample
routing`, 390 s incremental today, bundle 736 MB). The builder writes the app
package `build/app/routing` (module `RoutingApp`, workload as a
`@compile_workload`); `create_app` compiles it; the executable loads
`lib/julia/sys.so` of the bundle by that fixed path. So a rebuild after an
edit only needs to replace that one file.

The plan, on the `reactive` branch of PackageCompiler (worktree
`package-compiler-reactive`):

- `materialize_app(package_dir, app_dir; tracked, workload, ...)`. With no
  store: run `create_app` as today, and keep the object archive — the text
  objects and the tracked sources become snapshot 1 of a store inside the
  bundle. With a store: spawn the `--output-o` child from the bundle's own
  `sys.so` with `JULIA_REACTIVE_REUSE=1` (an environment wrap, no code
  change), give it a generated script that applies the tracked diffs and
  runs the workload inline (the M4 child), and link the ancestor text
  objects in front of the delta archive into a fresh `sys.so`. The bundle,
  the libraries and the executable are not touched.
- Two small seams in `create_sysimage`: `keep_object_archive` (copy the
  archive before the `finally` deletes it) and `extra_object_files`
  (prepended to the link). `create_app` passes both through.
- The child of a rebuild runs no separate trace process: a trace against the
  old image would trace the old code. The workload runs inside the child,
  after the apply, as in M4.
- `SourceDiff.jl` is vendored into the branch; the copy in this directory
  stays the original.

**Gate 5.** Build the routing sample once through `materialize_app` (the
full path). Apply the `packet.hop_count += 1` → `+= 2` edit of
`sample/legacy/routing/Routing.jl` on disk. Materialize again: the rebuild
must cost about the workload, the delta must be the cone plus nothing of the
machinery, and the rebuilt binary must run. The 390 s of the incremental
`create_app` is the number to beat. **Passed 2026-09-05** by
`tool/m5_gate.sh`; the numbers and the findings are in the entry
"2026-09-05, M5" below. The steady rebuild is 12 s against 155 s for the
full build on the same lane, and the rebuilt binary doubles the measured
hop mean exactly.

### Stage 6 — the two Stage 1 hazards

Gate 2 left two hazards open, because the routing edit does not reach them.

**Hazard (a), a direct call from the delta to a reused symbol.** A read of
`resolve_workqueue` and of the call emitters of `codegen.cpp` finds that the
system-image path never emits a call by symbol name to a function that is not
in `compiled_functions` of the same build: a callee without code in the
module gets the `emit_tojlinvoke` trampoline, or the `invoke` pointer of its
code instance. So the hazard is not a link error. It is two questions: does
every call shape reach the reused code through that route, and what does
the trampoline cost per call. Both are answered by a test package,
`tool/m6_hazard/HazardApp`, whose one tracked file `src/shapes.jl` holds
fourteen call shapes across the reuse boundary: a `@noinline` callee, an
inlined callee, a `@nospecialize` callee, a constant, a `@cfunction`,
keyword arguments, varargs, `invoke`, an opaque closure, a static parameter,
a finalizer, a reverse call (reused code dispatches into a function of the
delta), the cone (a reused caller inlined the edited leaf), and a
`@ccallable` method. A `bench` line measures nanoseconds per call for a
reused callee against a callee of the delta. `shapes-after.jl` is the
edited file: every shape changes its value in a way that only the new code
gives.

**Hazard (b), the alias of a redefined `@ccallable` method.** Stage 1
skipped the ccallable item when the method was older than the base world.
That rule is wrong for a redefined method: its `primary_world` is new, so
the item is emitted, `jl_generate_ccallable` defines the alias with the
plain name again, and the link sees the symbol twice. The rule moves to the
C side and asks the previous image: `jl_reactive_image_exports(name)` looks
the name up in the loaded image (`staticdata.c` keeps the handle of the
image), and `jl_generate_ccallable` returns without a wrapper and without
an alias when the image exports the name. The Julia side always pushes the
ccallable item. The alias of the previous image stays correct for a
redefined method: the wrapper behind it resolves its target through
`jl_get_abi_converter` in the current world. `JULIA_REACTIVE_TIMINGS=2`
reports `reactive: ccallable <name> is exported by the previous image; no
new alias`; `julia_main` gets the same line on every rebuild.

**Gate 6.** `tool/m6_gate.sh`: `materialize_app` founds the store of
HazardApp, the binary prints the before-values of the fourteen shapes; the
edit replaces `shapes.jl`, the rebuild must report the skipped alias of
`hazard_entry`, the binary prints the after-values; the reverse edit gives
the before-values again. The bench line gives the trampoline cost.
**Passed 2026-09-05**: 14 of 14 shapes in each of the three runs, the alias
skipped on both rebuilds, the trampoline at 43 ns per call against 2.6 ns.
The numbers and one new finding — the side effects of the rebuild workload
persist in the image — are in the entry "2026-09-05, M6" below. The direct
call of Stage 2 then replaced the trampoline: the same gate gives 1.0 ns
against 1.0 ns, in the entry "2026-09-05, the direct call".

### Stage 7 — the builder

The M5 gate drove PackageCompiler by hand. Stage 7 puts the reactive build
behind the builder of omnet-julia, on the branch `reactive-builder` of the
`omnet-julia-m1` worktree: `build_executable(; reactive = true)` and
`bin/build_omnet_legacy_sample routing --reactive`.

- `source/build/Reactive.jl`. `tracked_sources(package)` walks the root
  file of a package for every literal `include("…")` at the top level of a
  module, follows the included files, and names the dotted module of each.
  The root file is not tracked: its top level is `module Pkg … end`,
  evaluated in `Main`, and the app image binds no package in `Main`. An
  `include` outside every module, or with an argument that is not a string
  literal, is named in a warning and not tracked. `write_rebuild_workload`
  writes `rebuild_workload.jl` beside the app package: `using` of every
  package, then the workload expression. `_materialize!` is the counterpart
  of `_compile!`: the same arguments reach `materialize_app`.
- `Executable.jl`. `reactive` refuses `trim`, `incremental = false`, and a
  `tracked` list without `reactive`. A store that was founded for another
  app package is refused: the builder compares the modification times of
  the app `Project.toml` and module file before and after it writes them,
  and a store under an output whose app files changed is not a rebuild of
  that store. The build record says `reactive: founded by
  PackageCompiler.materialize_app; a later build of the same output
  compiled the edit only`.
- `build_binary.jl`. `--reactive` refuses `--distribution` and
  `--no-incremental`.
- `environment/tool/Project.toml` takes PackageCompiler from
  `workspace/package-compiler-reactive`, a superset of the
  `cached-base-sysimage` branch that the environment used before.

**Gate 7.** `tool/m7_gate.sh`: the tool environment resolves; `--reactive
--no-compile` writes the app package and names the tracked files; the
founding build; the binary runs the Backbone configuration at hop mean
2.308011; the `+= 2` edit of `Routing.jl`; the same command rebuilds the
delta; hop mean 4.616022; the reverse edit and 2.308011 again.

**Passed 2026-09-05**: the founding build in 6 min 22 s, the edit rebuilt in
17.9 s, the reverse edit in 16.7 s, and the hop mean went 2.308011 →
4.616022 → 2.308011; the numbers are in the entry **2026-09-05, M7** of the
decision record.

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
as the stages find reads. Stage 0 found one: the `build_id` of a module, which
enters the hash of every type of the module and is folded as an immediate into
`hash(::MyEnum)`. Stage 1 removes the read rather than records it; a read of a
random value would give every key a new value in every process.

An object key hashes all three levels. An inference key hashes the first two,
and never the target.

## Where the code goes

- A patch to Julia — Stage 1 and the code generation recorder. It comes first,
  not last, because nothing can be reused without it. Keep it in
  `src/aotcompile.cpp`, `src/staticdata.c` and a few accessors of
  `src/codegen.cpp`.
- `ReactiveCompiler` — the store, the recorded reads, the keys, the replay and
  the cache policy. `src/GraphHarvest.jl`, `src/MethodEdit.jl` and
  `src/ReadKey.jl` in this directory are its first pieces: the graph, the edit
  and the inference key of a component. `src/SourceDiff.jl` and
  `src/Materialize.jl` are the M4 pieces: the changed expressions of a file,
  and the store with the materialize driver.
- `ReactivePackageCompiler` — the executable bundle around the materialize
  entry point. Sits beside the `parallel-build` branch; still open.
- `tool/m0_*` — the Stage 0 measurement: the builds, the three comparisons and
  the key run. They stay, because Stage 1 and Stage 2 are measured with them.
- `tool/m4_child.jl` and `tool/m4_gate.sh` — the materialize child and the M4
  gate.
- `tool/m5_gate.sh` — the routing sample binary through `materialize_app`.
- `tool/m6_hazard/` and `tool/m6_gate.sh` — the HazardApp package (every
  call shape across the reuse boundary, a redefined `@ccallable`) and its
  gate.
- `tool/m7_gate.sh` — the routing sample through the builder of omnet-julia
  (branch `reactive-builder` of `omnet-julia-m1`).

## Milestones

- [x] **M0** — the ceiling is measured: determinism, the identical fraction after
      one edit, and key-changed equals invalidated. Done 2026-09-05: 98.5% of
      the objects identical with the frame slots masked, 96.4% without; one
      edit changes one object; key-changed = invalidated = `{routing_handle!}`.
- [x] **M1** — a rebuild with no edit reuses every text object of the previous
      build and the image runs. Done 2026-09-05: B links A's eight text
      objects, reuses 37334 code instances, emits 309 functions, and runs the
      routing model with A's network hash; 19 s and 1.1 GB against 120 s and
      8.0 GB for A. The third rebuild emits nothing.
- [x] **M2** — a rebuild after a one-function edit emits only the cone, and the
      emission time is reported against 343 s. Done 2026-09-05: E emits 14
      functions for the 7 method instances of the cone, `jl_emit_native` takes
      0.0 s against 10.2 s for the full build F on eight threads (343 s on one
      thread in M0), and E.so runs the edit at the speed of D.so.
- [x] **M3** — the serial front is cut by the cheapest of the three ways.
      Done 2026-09-05, by a fourth way that dissolves it: the materialize
      child boots from the previous image and loads nothing from source. The
      front of the edit build is 1.3 s against 27.4 s in the full build and
      against the 113 s + 41 s of the PackageCompiler lane.
- [x] **M4** — `materialize(store, snapshot)` links reused and new objects into a
      working application, and beats `create_app` with a warm base cache,
      measured from a fresh process on the same lane. Done 2026-09-05:
      `materialize(store)` turns an on-disk edit into a bootable image in a
      20.8 s wall and 1.1 GB against 117.2 s and 8.0 GB for the full build
      of the same edit on the same lane (and `create_app` adds its 113 s +
      41 s front on top of such a build). The delta is the cone of Gate 2
      exactly. The `create_app`-style executable bundle stays open.
- [x] **M5** — `materialize_app` in PackageCompiler rebuilds the `routing`
      sample bundle after an on-disk edit for about the cost of the
      workload, against 390 s for today's incremental `create_app`. Done
      2026-09-05: the steady rebuild is 12.0 s to 13.2 s and 1.3 GB against
      155 s and 9.7 GB for the full build through the same entry point; the
      rebuilt binary runs at once and its `hopCount` mean doubles exactly
      with the edit, and returns exactly with the reverse edit.
- [x] **M6** — every call shape reaches reused code across the reuse
      boundary, the rebuild of a redefined `@ccallable` method links, and
      the trampoline cost per call is measured. Done 2026-09-05 by
      `tool/m6_gate.sh`: 14 of 14 shapes before, after and after the reverse
      edit; the alias of `hazard_entry` skipped on both rebuilds; a call
      from the delta into reused code costs 43 ns against 2.6 ns inside
      the reused code. Found on the way: the rebuild workload's side
      effects persist in the image and accumulate along the chain.
- [x] **M7** — `bin/build_omnet_legacy_sample routing --reactive` founds the
      store on the first build and rebuilds the delta on the second, through
      the builder alone. Gate 7 is `tool/m7_gate.sh`. Done 2026-09-05: the
      founding in 6 min 22 s, the rebuild of the edit in 17.9 s, the reverse
      edit in 16.7 s; the hop mean doubled and came back.

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

**2026-09-05, M0.**

- The routing example of omnet-julia, sequential mode, is the subject: 16 011
  method instances in the graph that the edges reach from the two root modules,
  55 306 functions in the image, because the image also holds all of Base.
- Three comparison tools, because each hides a different thing. Bytes with the
  relocations masked (`m0_objdiff.py`) still see a resolved same-section call.
  The disassembly with every symbol canonical (`m0_asmdiff.py`) sees only the
  instructions. The bitcode (`m0_bcdiff.py`) at both levels says where a
  difference is born. The numbers of the plan are the disassembly numbers.
- Two builds of the same source, one partition: 96.4% identical, 98.5% with
  the frame slots masked. Eight partitions: 93.9% and 95.3%. Unoptimized
  bitcode: 99.98%, ten functions, all `_enum_hash`. Optimized bitcode: 96.3%,
  and 99.2% with the slot mask, the rest phi order and `jfptr` slot indexes.
  Object: 96.4%. The codegen is deterministic but for the enum hash, the
  pipeline is not (fact 14), and the backend adds no noise.
- One edit changes one object, `julia_routing_handle!`, and no adapter. Third
  build against the second: the same 96.3%. The cone of a class C edit is one
  function, as the design assumes.
- The keys: 15 790 components, the largest 173 (the `show`/`print` cluster of
  Base), 5.4 s for all, deterministic in one process. After the edit: one key
  changed, one node invalidated, the same node, zero on each side of the
  difference. Gate 0 holds exactly for the keys.
- Constants are named by counter, `_j_const#<count>` and `_j_str_<content>#N`,
  in `get_pointer_to_constant`. `m0_objdiff.canonical` folds both. Stage 1
  names them by content.
- Julia's replacement semantics, `jl_method_table_invalidate`: the callers'
  code instances get a `max_world`, the typemap entry dies, and the replaced
  method's own code instances keep `max_world == ∞`. A harness that counts
  invalidated nodes by `max_world` alone reports zero; count the replaced
  method by identity as well.
- The key computation is Julia code and is part of the graph it measures:
  `sprint(show, ::Expr)` gets a code instance during the first key run, and
  twelve nodes above it change key with no edit. The harness now compiles
  itself before the first harvest. A store that keys its own methods has the
  same hazard: harvest after the harness is warm, or key the harness apart.
- The `Method` type of Julia 1.13 has no `deleted_world`; the replaced method
  is found by identity of `def`.
- Build cost to beat: eight threads 103 s and 8.3 GB; one thread 265 s to
  280 s and 6.3 GB to 8.2 GB. The key run costs 75 s of wall time and 0.6 GB
  of memory, of which the keys are 5.4 s; the rest is the load and two runs of
  the scenario.

**2026-09-05, Stage 1 design.** Found by a read of `aotcompile.cpp`,
`staticdata.c`, `processor.cpp`, `codegen.cpp`, `typeinfer.jl` and
`precompile.jl`. It replaces the seven bullets of the first draft.

- *The new build boots from the old image.* B is `julia -J A.so --output-o
  B.a script.jl`, not a fresh process that loads the packages from source.
  The reused code instances are then live objects with a native pointer, and
  the runtime knows their function ids. A fresh process would have to match
  code instances across two heaps by content; the image does that for free.
  The delta of a build with no edit is the cone that the harness itself JITs.
- *No image format change.* A's objects keep their tables, `jl_fvar_idxs_<i>`,
  `jl_gvar_offsets_<i>` and the rest. B's image uses three append-only id
  spaces, each based on A's count: function ids start at `nfvarsA`, global
  slot ids at `ngvarsA`, shard numbers at `nshardsA`. The header of B says
  `nshardsA + threadsB` shards, `nfvarsA + nfvarsB` functions, `ngvarsA +
  ngvarsB` slots; the shard table of B declares the extern tables of every
  shard, and the linker resolves A's from A's objects. The loader,
  `parse_sysimg`, fills `fvars[fidxs[i]]` per shard and asserts that no slot
  is empty; A's objects hold every function, so no hole appears. Every image
  has at least one shard, so `nshardsA` grows strictly across A, B, C and
  serves as the tag of a build.
- *Symbol uniqueness by a suffix, not by counter seeding.* The rename loop of
  `jl_create_native_impl` gives every defined global object internal linkage
  and a safe name; when `nshardsA > 0`, the name gets `.r<nshardsA>`. The
  aliases of `@ccallable` names are not touched. The partitioner promotes a
  private constant that a second partition references to a hidden external
  symbol, so the suffix must cover the constants too; it does. The unnamed
  globals of the multi-thread path, `jl_ext_<n>`, and the shard suffixes
  `_<i>` get the same treatment. No name-based lookup of these globals exists
  after the rename: `jl_fvars`, `jl_gvars` and the index tables are created
  later, and `jl_small_typeof` is a declaration.
- *The ids.* `get_fvars_gvars` reads the position of a function in `jl_fvars`
  as its id and ignores the contents of `jl_fvar_idxs`; `verify_partitioning`
  indexes vectors of the delta's size. Both keep the local positions.
  `construct_vars` writes `jl_fvar_idxs_<i>` and `jl_gvar_idxs_<i>` as the
  position plus the base; the one-thread path writes an iota from the base.
  The bases travel as module flags on the data module, absent on a stock
  build and on the `sysimg` and `metadata` modules, so those paths do not
  change. The descriptor gets the three bases as fields, copied to locals
  before `compile` deletes it.
- *The runtime side.* `jl_restore_system_image` copies the parsed image into a
  static before the stream restore sets `gvars_base` to `NULL`; the world
  counter after the restore is the base world. `jl_reactive_image_ids(ci,
  &invoke_id, &spec_id)` returns nonzero when `ci->specptr.fptr` is an entry
  of A's function table, found by a sorted address map built once, and
  `ci->invoke` is `jl_fptr_args`, `jl_fptr_sparam`,
  `jl_f_opaque_closure_call`, or an entry with a smaller id. The debug assert
  of the writer, `specfptr_id > invokeptr_id`, holds for A's ids because the
  wrapper of a function is emitted before the function. A's live slot values,
  `*(gvars_base + gvars_offsets[i])`, are prepended to the roots of B, so that
  the serializer records the object each reused slot names; the runtime of B
  fills A's slots from B's heap, in B's process, as it does today.
- *The Julia side.* `compile!` asks `ci_reactive_reusable(ci, world)`: the
  owner is `nothing`, `max_world` is infinite, `min_world` is at most the
  world, and the runtime returns image ids. A reusable code instance is marked
  inspected, pushed to `reused`, and skipped; its edges are not walked,
  because A's object already holds its callees. The MI branch takes the cached
  code instance when it is reusable, else infers. `typeinf_ext_toplevel` and
  `compile_and_emit_native` return `Core.svec(codeinfos, reused)` in reactive
  mode, which `jl_create_native_impl` tells apart from a `Vector{Any}`. A
  `@ccallable` item is skipped when its method's `primary_world` is at most the
  base world: its alias and wrapper are in A's objects. Const-API code
  instances stay on the stock path: the writer handles them by flag and never
  looks them up.
- *Calls from the delta into A.* `resolve_workqueue` gives a callee that is not
  in `compiled_functions` the `emit_tojlinvoke` trampoline through the code
  instance's `invoke` pointer. That is the correct fallback for Stage 1; a
  direct call to the reused symbol, or an external-function slot, is a Stage 2
  choice. The slot route needs the external-function part of
  `jl_root_new_gvars` to run for a non-incremental image after
  `jl_update_all_fptrs`; it runs only for the incremental path today.
- *Withdrawn.* The `build_id` bullet and the `ColorRoots` bullet: reuse is
  decided by the world age and by the positional identity of the image, never
  by a byte comparison, so a non-reproducible byte is not a blocker. The
  content-named constants: the suffix makes the counter names link, and the
  M0 tools already fold the counters. The counter seeding in `codegen.cpp`:
  a suffix does the same with no change to the counter.
- *Scope.* One target, `-C native`, on the same machine; B's
  `jl_dispatch_target_ids` replaces A's. The switch is the environment
  variable `JULIA_REACTIVE_REUSE=1`; `JULIA_REACTIVE_TIMINGS=1` prints the
  time of the front, of `jl_emit_native` and of each dump phase.

**2026-09-05, Stage 1 implementation.** Facts found while the patch was
written; none changes the design.

- *A code instance can appear twice in `reused`.* `CompilationQueue(queue;
  interp)` starts each world pass with an empty inspected set, so the two world
  passes of `typeinf_ext_toplevel` can both visit one code instance. The
  duplicate is harmless: `reactive_rebase` inserts the same ids into
  `jl_fvar_map` twice.
- *A reuse miss is not an error.* `get(code_cache(interp), mi, nothing)`
  returns the first entry of the chain that is valid in the world and has
  `inferred`. When a newer code instance without native code sits before A's,
  the MI branch infers again and the delta grows by one function. So
  `reactive_cached_ci` walks the whole chain of the method instance for a
  code instance that is valid in the world and has image ids, and the code
  instance branch of `compile!` reuses such a sibling of the code instance
  it was given. The run time takes the same path: `jl_method_compiled_callptr`
  walks the chain for a code instance with an `invoke`. Gate 1 counts the
  reused list against the function count of A to see the misses.
- *`@ccallable` aliases are a Stage 2 hazard.* `jl_generate_ccallable` makes a
  `GlobalAlias` with external linkage and the plain ccallable name; the rename
  loop suffixes global objects only, so an alias keeps its name. Stage 1 skips
  the item when the method is older than the base world, and the wrapper that
  `lam == NULL` produces dispatches dynamically. Stage 2 must skip or rename
  the alias of a redefined `@ccallable` method, or the link sees it twice.
- *Two reuse paths are out of scope.* A package image (`external_linkage`)
  silently takes the stock path; reactive reuse with `--trim` stops with an
  error, because the trim verifier walks the edges that reuse skips.
- *The build of Julia itself.* `sys-o.a` boots from `sysbase.so`, so
  `reactive_image_loaded` is set during `make`; the environment variable is
  unset there, and every `jl_reactive_*` query returns zero. The M0 archives
  came from the juliaup 1.13.0-rc3; Gate 1 uses the patched `usr/bin/julia`
  and a stacked depot, `JULIA_DEPOT_PATH=<out>/depot:~/.julia:`, so the rc4
  caches do not clobber the rc3 caches of the user. A first non-empty entry
  removes `~/.julia` from the depot list, so the user depot must be named.

**2026-09-05, Gate 1.** Passed by `tool/m1_gate1.sh` on the routing model at
omnet-julia e21ba2cd, in a detached worktree `omnet-julia-m1` beside the
checkout; the live checkout moved to a state that does not load while the
gate ran. Eight image threads, `-C native`, the build lane.

Four builds in a chain: A from `sys.so`, B from `A.so`, C from `B.so`, D from
`C.so`. Each image links the text objects of every build before it, its own
text objects, and its own `sysimg.o` and `metadata.o`. Every image links with
no linker output, is 303 MB, boots, and runs the model to the network hash
`92a8205a91b44af2524c1b843e2df7b0` in 14.7 s and 0.31 GB. The M0 archives
give the same hash, so the rc4 build and the rc3 build run the same model.

| step | wall | peak RSS | result |
| --- | --- | --- | --- |
| build A from `sys.so` | 119.7 s | 8.0 GB | 8 shards, 52962 functions, 14615 slots; front 27.3 s, `jl_emit_native` 10.4 s |
| build B from `A.so` | 19.6 s | 1.1 GB | 37308 code instances reused; delta 309 functions, 240 slots (179 roots, 3 edges); front 1.3 s; header 16 shards, 53271 functions, 14855 slots |
| build C from `B.so` | 19.1 s | 1.1 GB | 37482 reused; delta 6 functions, 5 slots (4 roots, 0 edges); header 17 shards, 53277 functions, 14860 slots |
| build D from `C.so` | 19.0 s | 1.1 GB | 37486 reused; **delta 0 functions, 0 slots**; header 18 shards, 53277 functions, 14860 slots |

The delta of a rebuild with no edit converges to zero in three builds. The
report `reactive: delta ... const, shadowed, roots, edges`
(`JULIA_REACTIVE_TIMINGS=1`; level 2 lists each code instance and, with
`reactive enqueue:`, names the code instance that put a root on the worklist)
gives the causes. Before the two fixes below, the delta of B was 516 functions
and the delta of C was 26 functions.

- *The passes run in two worlds.* `jl_create_native` passes the current world
  and the world of the compiler (`jl_typeinf_world`), and
  `typeinf_ext_toplevel` runs a pass in each. The pass in the world of the
  compiler infers the callees of Base again in that world and creates code
  instances that are already stale for the application. A count of roots
  counts a code instance once per pass, so 179 root lines are 98 method
  instances.
- *Cause 1, a stale code instance.* A's pass in the world of the compiler
  compiled `∉(Symbol, Set{Symbol})` for the worlds 3210:14334, while the
  application calls the code instance for 14335 and after, which A inlined
  and never emitted. In B, `enqueue_specialization!` sees the `invoke` of the
  stale code instance and enqueues the method instance; the pass in the
  current world then compiles the other code instance. The fix: a code
  instance of the loaded image whose `max_world` is below the base world
  (`ci_reactive_stale`) does not enqueue by itself. The method instance
  still goes to the worklist, marked in `reactive_stale_roots`, so that the
  pass in the world of the compiler reuses the stale code with its ids and
  `compile!` infers nothing for it in the other world. The criterion "a
  sibling is reusable in some pass world" was rejected: a code instance that
  an edit invalidates has `max_world` at or above the base world, and the
  Stage 2 cone must recompile it.
- *Cause 2, a precompile request served at run time.* `_generate_from_hint`
  sets `precompile` on a code instance after the worklist closed, for
  example on `==(Unitful.Dimensions{Mass}, Dimensions{Mass})` and on
  `reactive_cached_ci`; the next build enqueues it. The fix: the writer of a
  reactive build clears `precompile` on a code instance that gets no native
  pointer and is not a builtin. A request for a signature that is not
  compileable, such as `zip(Vector{Symbol}, Vararg{Any})`, drops off the
  next worklist too, which loses nothing.
- *The residue of B is the run time of A.* Of the 98 method instances that B
  compiles, 89 have a code instance whose `inferred` is `nothing`: the run
  time of A compiled them in the JIT and dropped the source, and the stock
  predicate compiles such a method instance. A is not a reactive build, so
  its writer keeps its `precompile` flags too (3 roots). B pays once; C
  reuses all of them.
- *The residue of C is code emitted in one world.* B emits code for
  `iterate(Generator{Vector{Any}, symbol_to_globalref})` in the current
  world, which makes the method instance a root of C; the pass of C in the
  world of the compiler finds the older code instance of A without code and
  compiles it. `reactive_cached_ci` itself is compiled at run time in B, the
  first build that runs it. D reuses both. A skip for a code instance
  without code that is bounded below the base world would save the six
  functions of C, but the stock build compiles them, so the residue stays.

**2026-09-05, Gate 2.** Passed by `tool/m1_gate1.sh` on the same worktree,
lane and thread count as Gate 1. The chain A, B, C, D of Gate 1 ran again
with the same deltas (309, 6, 0 functions), then two builds with the edit of
M0, `pk.hop_count += 1` to `+= 2` in `routing_handle!`: E from `D.so`, and F
from `sys.so` as the full build that E is measured against. The edit is
applied inside the build, before the scenario, by `tool/m0_build.jl` with
`RC_EDIT=1`: the definition is read back from the file of the method, the
text is replaced, and the result is evaluated again in the module of the
method; 2.7 ms, the world counter moves from 69212 to 69217.

| step | wall | peak RSS | result |
| --- | --- | --- | --- |
| build E from `D.so`, edit | 19.0 s | 1.1 GB | 37510 reused; **delta 14 functions, 49 slots** (8 roots, 0 edges); front 1.3 s, `jl_emit_native` 0.0 s; header 26 shards, 53334 functions, 14931 slots |
| build F from `sys.so`, edit | 119.8 s | 8.0 GB | 8 shards, 53009 functions, 14637 slots; front 27.2 s, `jl_emit_native` 10.2 s |
| run E.so | 14.8 s | 0.34 GB | Avg hops 6.09, hash `92a8205a91b44af2524c1b843e2df7b0`, sequential time 14.55 s |
| run F.so | 14.9 s | 0.35 GB | Avg hops 6.09, the same hash, sequential time 14.69 s |

- *The cone, measured.* The build script prints three sets. The replaced
  method keeps one specialization, `routing_handle!(EventContext{Sequential},
  Vector{RoutingNode}, Int, Packet, VectorFileWriter, Vector{NodeVectors})`.
  The edit closes two code instances, the closures of `queue_receive!` and of
  `app_generate!` that call it. The scenario then makes 27 new method
  instances: the new `routing_handle!`, its two new closures, the two
  specializations of the capture closure `CaptureModule.var"#16#17"` on the
  new closure types, and 22 callees of the new code, such as
  `schedule_event!` and `ScheduleRecord` on the new closure types.
- *The delta is the cone.* The 8 root lines of E are 7 method instances: the
  3 replaced or closed, and 5 of the new ones; `routing_handle!` is a root
  once per world pass. No root is outside the cone, and every closed code
  instance is emitted again. The 22 other new method instances are inlined
  into the roots and get no function of their own, and no run compiles them
  later: `--trace-compile` on a run of E.so and on a run of F.so lists only
  the `print` calls of the harness. E emits 14 functions: a specialized
  signature and a generic wrapper for each root. The calls from the delta
  into the reused code go through 21 `tojlinvoke` trampolines, on
  `schedule_event!`, `app_receive!`, `queue_start_tx!`, `_growend!` and
  the throw helpers among others.
- *The delta costs nothing measurable.* E takes 19.0 s, D took 19.0 s; 14.5 s
  of both is the scenario, 1.3 s the front, the rest the heap. The full build
  F takes 119.8 s with the same scenario inside, so the build around the
  scenario is 4.5 s against 105 s. `jl_emit_native` is 0.0 s against 10.2 s
  on eight threads, and 343 s on one thread in M0. The link of E.so takes
  about 1 s.
- *The image runs the edit at full speed.* The average hop count goes from
  3.05 to 6.09 in the build of E, in the run of E.so and in the run of F.so;
  the network hash does not cover hop counts, so it stays. The run of E.so
  takes 14.55 s against 14.57 s for D.so and 14.69 s for F.so, so the
  `emit_tojlinvoke` trampoline on the calls from the delta into the reused
  code is not visible in this model. The run makes 3 method instances, the
  `print` calls of the harness, as every run of the chain does.
- *The edited method has no file.* A method evaluated from text has the file
  `none`, so a run from E.so or F.so cannot read the definition back. The
  harness skips the read when the file does not exist and refuses `RC_EDIT`
  in that case: an edit on top of an edit is a later measurement.
- *Every build carries the harness.* The two functions of the harness are
  defined under `@isdefined`, so that a build that boots from a previous
  image keeps the compiled functions and the delta holds the cone alone. The
  price is that a change of the harness needs the chain from A again.
- *The key of Stage 2 is the world.* No recorded read was needed: the edit
  bounds the `max_world` of the closed code instances, the reuse test of
  Stage 1 rejects them, and inference makes the new ones. The recorded-read
  key stays in the design for the cross-process store. Two Stage 1 hazards
  are still open and are not exercised by this edit: a direct call from the
  delta to a reused symbol instead of the trampoline, and the alias of a
  redefined `@ccallable` method. Both closed the same day: the entries
  "2026-09-05, M6" and "2026-09-05, the direct call".

**2026-09-05, M4.** Passed by `tool/m4_gate.sh` on the same worktree, lane
and thread count as the earlier gates. The chain is now driven by
`materialize(store)`: s1 the full build, s2 to s4 with no change, then the
M0 edit applied to `sample/legacy/routing/scenario/routing.jl` on disk, s5
with the edit, s6 with no change, and the same edit as a full build into a
second store as the baseline.

| step | wall | peak RSS | result |
| --- | --- | --- | --- |
| s1, full build | 118.2 s | 8.0 GB | child 116.7 s, extract 0.1 s, link 0.6 s; image 305 MB |
| s2 / s3 / s4, no change | 20.6 / 20.4 / 20.0 s | 1.1 GB | delta 176, 4, 0 roots — the Gate 1 convergence |
| s5, the edit | 20.8 s | 1.1 GB | 1 expression found and applied in 2.8 ms; delta 8 root lines = 7 method instances, 0 outside the cone; front 1.3 s, `jl_emit_native` 0.0 s, 37604 code instances reused |
| s6, no change | 20.4 s | 1.1 GB | delta 0 roots |
| full build of the edit | 117.2 s | 8.0 GB | front 27.4 s, `jl_emit_native` 10.0 s |

The images of s5 and of the full build both run the model at 6.09 average
hops with the network hash of the chain; s1 runs it at 3.05. The workload of
s5 makes the 27 new method instances of Gate 2, and the runs make 2 print
instances, as every run of the chain does.

- *The diff is blind to line numbers, and the evaluation is not.* The
  comparison strips every `LineNumberNode`, so an edit near the top of a
  file does not drag every later definition into the delta. The evaluation
  uses the parse of the new text with the file name set, so a redefined
  method keeps a real `file` and `line`. The "file `none`" fault of the
  Gate 2 harness is gone with the harness: an edit on top of an edit reads
  back, because the child compares stored text with disk text and never
  reads a definition out of a method.
- *A tracked file names its module.* `routing.jl` is included into `module
  Routing` of the package file; no parse of the file itself can know that.
  The store config carries one dotted module path per tracked file, and the
  diff's own module descent stacks on top of it.
- *The machinery must warm itself with content.* The first gate run put 20
  extra roots into the delta of the edit build: the diff machinery itself,
  compiled on its first real edit. Running the diff on unchanged files in
  every build cut that to 11 — the specializations on non-empty diffs (the
  `Set` and `Dict` helpers on the pair tuples, `defined_name`, two print
  shapes) still compiled late. A synthetic non-empty diff in every build
  (`m4_warm`), with the same argument types as the real calls and the same
  report lines, cut it to 0. This is the Gate 0 lesson for the third time:
  the harness is part of the graph it measures, and an empty-input warm-up
  does not compile the non-empty arms.
- *A removal is reported, not applied.* Julia has no cheap way to undefine a
  method in the build child. A definition that the new text drops (and that
  no changed definition of the same name replaces) is printed as
  `m4: removed`, and the old method stays in the image until a full build.
- *The gate leaves nothing behind.* The gate edits the pinned worktree in
  place and restores it with git at the end; the store keeps a copy of the
  sources per snapshot, so a run of an old snapshot still compares against
  the sources it was built from.

**2026-09-05, M5.** Passed by `tool/m5_gate.sh` on the build lane, eight
image threads. The subject is the `routing` sample binary: the builder
writes `build/app/routing` with `--no-compile`, and every build goes through
`PackageCompiler.materialize_app` on the `reactive` branch (worktree
`package-compiler-reactive`, from `cached-base-sysimage`).

| step | wall | peak RSS | result |
| --- | --- | --- | --- |
| full build, store founded | 155.0 s | 9.7 GB | `create_app` + text objects + sources; front 36.4 s, `jl_emit_native` 15.8 s |
| first rebuild (the edit) | 13.2 s | 1.3 GB | edit applied in 3.2 ms; delta 383 roots: the cone + the one-time residue |
| steady rebuild (edit or reverse) | 12.0 s to 12.5 s | 1.3 GB | delta 16 to 18 roots; 43000 code instances reused; front 2.1 s, `jl_emit_native` 0.1 s |
| rebuild with no change | 12.2 s | 1.3 GB | delta 14 roots: the workload floor |
| smoke (`--build-info`) | 0.2 s | | after every swap |
| one simulation (`-c Backbone`) | 63 s | 0.7 GB | hop mean 2.308011 before, 4.616022 after the edit — exactly double — and 2.308011 again after the reverse edit |

- *The cone of this application is the `new` set alone.* The engine
  dispatches on the module type at every gate, so no caller holds a
  backedge to `handle_message!`: the edit closes zero code instances. The
  replaced-method lookup also finds nothing, because the sample extends
  `NetworkModule.handle_message!` by a dotted name that the defining module
  does not bind. The workload then makes the new instances — 47 on the
  first edit, 7 in the steady state — and the delta covers them.
- *The first rebuild absorbs the run-time residue of the full build.* Its
  delta had 186 roots outside the cone: the JIT of the full build's own
  child, and the first compilation of the rebuild machinery. This is s2 of
  the M4 chain, seen once per store.
- *A script workload has a floor.* `Batch.jl` defines anonymous closures at
  its top level, and every rebuild re-evaluates them: 7 method instances
  per rebuild, forever (the first rebuild reports `1 shadowed`). The M4
  workload — one call of a package function — converges to zero. Rule for
  the builder: a workload file for the rebuild child must only call package
  functions.
- *What changes on a rebuild is one file.* The store lives inside the
  bundle (`reactive-store/`: text objects and tracked sources per snapshot,
  no images), and a rebuild replaces `lib/julia/sys.so` and nothing else;
  the executable, the libraries and the artifacts stand.
- *The PackageCompiler diff is two seams and two files.* `create_sysimage`
  gets `keep_object_archive` (copy the archive before the `finally` deletes
  it) and `extra_object_files` (linked in front of the delta, never
  deleted); `create_app` passes the first through. `reactive.jl` holds the
  store and the driver, `reactive_child.jl` the child definitions,
  `SourceDiff.jl` is vendored. `JULIA_REACTIVE_REUSE=1` is a `withenv`
  around one call.
- *The child of a rebuild imports nothing into Main.* The previous image
  carries the Main bindings of its own build; the child resolves the root
  module of a tracked file through `Base.loaded_modules`, and the warm
  exercises that branch.

**2026-09-05, M6, the test package.** Facts found while `HazardApp` was
written and run on the JIT, before the gate.

- *A `const` opaque closure at the top level of a precompiled package is a
  stock fault.* `const reused_oc = @opaque (x::Int) -> x + 100` in a package
  faults at the call in a fresh process, on the reactive Julia and on the
  stock 1.13.0-rc3 alike. The package makes the closure in a function
  (`make_oc()`) instead. This is a bug of Julia and not of the patch; it is
  not reported upstream.
- *The workload of the founding build and the workload of a rebuild are two
  arguments.* The `workload` of `materialize_app` drives the rebuild child
  only; the founding build compiles what `precompile_execution_file` runs.
  The gate passes one file, `workload.jl`, as both: `using HazardApp;
  HazardApp.report()`, plain calls, as rule 3 of the harness says.
- *One specialization for the binary and the workload.* `run_all(io)` on
  `stdout` would compile at run time, because `stdout` has no fixed type.
  `report()` runs the shapes into an `IOBuffer` and `julia_main` prints the
  string, so the workload and the binary share one code path.
- *A missing `@ccallable` entry is not an error in the REPL.* The shapes run
  in a session whose image has no `hazard_entry`; the `ccallable` shape
  answers `-1` there and the real value in the built binary.

**2026-09-05, M7, the builder.** Facts found while the builder was
integrated, before the gate.

- *The root file of a package is not tracked.* Its top level is evaluated in
  `Main`, which binds no package in the app image; an edit to the root file
  (a new `include`, a new `using`) needs a founding build. The routing
  sample gives 34 tracked files; `Imports.jl` is tracked three times,
  once per module that includes it, and each entry names its own module.
- *The rebuild workload is the founding workload, written as a file.* The
  builder already has the workload as an `Expr` for the `@compile_workload`
  of the app module; `write_rebuild_workload` writes the same expression
  after a `using` of every package, so the two workloads cannot drift.
- *A store belongs to one app package.* The builder writes the app package
  with `write_if_changed`; when the write changed the `Project.toml` or the
  module file and a store exists under the output, the store was founded
  for another package, and the build refuses instead of linking a delta of
  the wrong program in front of the wrong image.
- *`--reactive` refuses what the reactive path cannot serve.* A distribution
  is a copy of a bundle tested outside the checkout, and a store inside the
  copy would be a store of the copy; `--no-incremental` and any `trim` are
  refused by the compiler itself.
- *The tool environment moved to the reactive PackageCompiler.* The branch
  `reactive` of `package-compiler-reactive` holds every commit of
  `cached-base-sysimage`, so a stock build through the same environment
  does not change.
- *`test/build.jl` covers the text and the refusals, not a build.* The one
  error of the suite in this environment is older than the change: the
  source build of the reactive Julia ships no `juliac` script.

**2026-09-05, M6.** Passed by `tool/m6_gate.sh` on the build lane, eight
image threads, after the Julia rebuild with the ccallable rule.

| step | wall | peak RSS | result |
| --- | --- | --- | --- |
| founding build of HazardApp | 127 s to 134 s | 5.9 GB | `create_app` with the base image from the depot cache; front 47.9 s to 49.3 s, `jl_emit_native` 18.3 s to 19.0 s |
| run, before | 0.5 s | 0.22 GB | 14 of 14 shapes; bench 2.62 ns/call reused, 3.24 ns/call the other loop |
| rebuild, the edit | 25.5 s to 25.8 s | 0.75 GB | 5 expressions applied in 64 ms, cone 5 replaced, 6 closed; 36 new method instances; delta 185 roots, 4 edges (the first-rebuild residue); front 2.6 s, `jl_emit_native` 0.1 s; 27084 code instances reused |
| run, after | 0.9 s | 0.26 GB | 14 of 14 shapes; bench 2.59 ns/call reused, **42.5 to 44.5 ns/call from the delta** |
| rebuild, the reverse edit | 23.8 s to 24.1 s | 0.73 GB | delta 15 to 19 roots, 0 edges |
| run, restored | 0.9 s | 0.26 GB | 14 of 14 shapes; bench 2.6 against 43.6 ns/call |

- *Every call shape crosses the boundary.* A `@noinline` callee, an inlined
  callee, `@nospecialize`, a constant, a `@cfunction`, keyword arguments,
  varargs, `invoke`, an opaque closure, a static parameter, a finalizer,
  the reverse direction through a dynamic call, the cone of an inlined
  leaf, and the `@ccallable` method all give the new value after the edit
  and the old value after the reverse edit. The link never sees a reused
  symbol from the delta, so hazard (a) is not a link hazard; it is a cost.
- *The trampoline costs 40 ns per call.* `bench_delta` is delta code that
  calls the reused `@noinline bench_callee` through `emit_tojlinvoke`:
  43 ns per call. `bench_reused`, the same loop inside the reused code,
  costs 2.6 ns. So a non-inlined call from edited code into code that the
  previous image holds is about 16 times a direct call: `jl_invoke` boxes
  the arguments and goes through the generic wrapper. The routing model
  does not see it (Gate 2: 14.55 s against 14.57 s), because its hot loop
  is inside reused code. A direct call to the reused specialization by its
  symbol is the Stage 2 fix, done the same day: the entry "2026-09-05, the
  direct call" below.
- *The ccallable rule holds.* `jl_generate_ccallable` reports `reactive:
  ccallable hazard_entry is exported by the previous image; no new alias`
  on both rebuilds, the link has no
  duplicate symbol, and `ccall` through the alias of the founding image
  gives 2 after the edit and 1 after the reverse edit: the old wrapper
  serves the redefined method. `julia_main` gets the same line.
- *The side effects of the rebuild workload persist in the image.* The
  finalizer shape adds to a global `Ref`. The founded binary starts at 0,
  because `create_app` runs the workload in a trace process and the image
  build executes precompile statements only. The rebuilt binary starts at
  2: the rebuild child runs the workload in the process whose heap becomes
  the image, and the child ran the edited `driver` once. The reverse edit
  starts at 3. This is the `@compile_workload` semantics of a package
  image, plus accumulation: a package image starts every precompile from
  a clean load, and a chain of rebuilds does not. Two ways: accept and
  document (the workload must leave no state, as it must in a
  `@compile_workload`), or a trace child before the build child — the
  same apply of the tracked diffs, the workload under `--trace-compile`,
  and the build child then executes the statements and runs nothing. The
  second way gives the founding semantics exactly, at the cost of one
  more process start and the workload once more; the build child then
  compiles the statements and does not run the simulation, so the
  routing rebuild moves from about 12 s to an estimated 16 s to 20 s.
  Decided 2026-09-05: the first way, see the entry below.
- *A test file must be committed before a gate restores it.* The gate's
  restore step is `git checkout`; an uncommitted edit of the test package
  is undone by it, and the restored run then tests the old text.

**2026-09-05, M7.** Passed by `tool/m7_gate.sh` on the build lane, eight
image threads, through `bin/build_omnet_legacy_sample routing --reactive`
of the `reactive-builder` branch (commit `d4352a0b` of `omnet-julia-m1`).
The gate's own log holds the first 60 lines of each build log only; the
numbers below are from `$OUT/m7/build-*.log`.

| step | wall | peak RSS | result |
| --- | --- | --- | --- |
| `--reactive --no-compile` | 9.4 s | 0.56 GB | the app package written; 34 tracked files, `Imports.jl` once for each module that includes it |
| founding build | 6 min 22 s | 9.6 GB | `create_app` with a fresh depot: the base image cache is built first; the record says `founded by PackageCompiler.materialize_app` |
| run, before | 3 min 1 s, user 180 s | 0.6 GB | `hopCount` mean 2.308011, 1222019 events, network hash `b21df42f…` |
| rebuild, the `+= 2` edit | 17.9 s | 1.36 GB | 1 expression applied in 2.2 ms, world 39301 → 39302, cone 0 replaced, 0 closed; 47 new method instances; delta 392 roots, 7 edges, 1 shadowed (the first-rebuild residue); front 2.3 s; 42643 code instances reused |
| run, after | 1 min 3 s, user 63 s | 0.6 GB | `hopCount` mean 4.616022, exactly double, same hash and event count |
| rebuild, the reverse edit | 16.7 s | 1.32 GB | delta 16 roots, 0 edges; 7 new method instances |
| run, restored | 1 min 3 s | 0.6 GB | `hopCount` mean 2.308011 |

- *The builder rebuilds through the same command.* The user types the
  command that founded the store, and the second build compiles the edit
  only. The founding is slower than M5 (155 s) because the gate starts
  from an empty depot and the base image cache is built first; a second
  founding in the same depot would cost the M5 number.
- *The steady rebuild is 17 s.* The M5 gate measured 12 s to 13 s by hand
  with the same edit. The builder adds the `--no-compile` front of the
  tool script: `Pkg.instantiate`, the load of `OmnetBuilder`, the walk of
  the tracked sources, and the writes of the app package. The
  `--no-compile` step alone takes 9.4 s with the Julia start; about 5 s of
  it is in addition to what the M5 gate paid.
- *The founded binary ran three times slower, in every phase.* The
  before-run took 180 s of user time against 63 s for the rebuilt binary
  and 63 s for the founded binary of M5. The setup phase, which runs no
  edited code, was also three times slower (`network=3.21 initialize=11.37`
  against `1.10/3.88`), the network hash and the event count are the same,
  and the restored binary on the same lane ran in 63 s. A uniform slowdown
  of the setup and the run is an external cause, not a difference of the
  image: CPU 16 of the lane carried a Java process at 52% for two hours,
  its SMT sibling is CPU 0, and the machine reported 63% frequency scaling.
  Observed, not reproduced: the store holds the restored image now, not
  the founded one. Settled by the re-founding of the entry "2026-09-05,
  the direct call": on a quiet lane the founded binary ran in 62 s.

**2026-09-05, the rebuild workload leaves no state.** The user chose the
first way for now: accept and document. The rule is the one that
`@compile_workload` already puts on a package: a rebuild workload calls
package functions, and every global it touches is back at its value when
it returns. The routing workload complies; it runs a simulation to its end
and keeps nothing. The harness does not check the rule — a check would
need a snapshot of the heap before and after the workload, and the cost
of that is the cost of the trace child. The trace child stays the
documented other way, for a workload that needs state it cannot undo.
Recorded as harness rule 8 in `doc/architecture.md`.

**2026-09-05, the direct call.** The Stage 2 item that M6 left open: the
delta calls a reused function by its symbol, not through the
`emit_tojlinvoke` trampoline. Commit `bca1430d75` of `reactive-compiler`;
the gates ran from fresh foundings, because the image format changed.

- *The image names its functions.* `CloneCtx::emit_metadata` writes
  `jl_fvar_names_<shard>` beside `jl_fvar_idxs_<shard>`: the symbol of
  each entry of `fvar_ptrs`, NUL-terminated, in the order of the table.
  `jl_image_shard_t` gets the field `fvar_names`, `jl_image_fptrs_t` the
  array `names`, `parse_sysimg` fills it from the shards, and the image
  header is version 2 (an older image is refused). The names are those of
  the base target: a multi-target `cpu_target` would give the delta the
  base clone of a reused function. The cost is about 1 MB for the 90k
  names of the routing image.
- *`resolve_workqueue` declares the symbol.* For a callee that
  `jl_reactive_image_ids` maps into the image, `jl_reactive_image_fname`
  gives the name: a specsig caller gets the specialization, a boxed caller
  the wrapper, and a `jl_fptr_args` callee the specialization with
  `preal_specsig = false`, which the stock adapter path then wraps. The
  declaration is hidden and `dso_local`, and the link binds it to the text
  object of the earlier build. `proto.specsig` is deterministic per code
  instance (`uses_specsig` of the ABI), so it matches the compiled callee.
  The name carries the marker `reactive.image.` until the final name pass
  of `jl_create_native_impl` has suffixed the delta's own definitions, and
  the pass then strips the marker; an assertion checks that the delta does
  not define the name. Three shapes keep the trampoline: a
  `jl_fptr_sparam` callee, an opaque-closure callee, and a caller that is
  an opaque closure. `TIMINGS=1` prints `reactive: N direct calls into the
  loaded image, M reused callees through the trampoline`.
- *A single-thread delta is linkable too.* `partitionModule` promotes every
  definition to a hidden external symbol, and the single-thread path of
  `add_output` (a module of weight below 1000) kept local linkage, so a
  small delta's functions were not callable by the next build. The
  single-thread path now promotes the same way, and the `jl_ext_` naming
  of unnamed globals moved before the fork of the two paths.
- *Every gate needs a fresh founding.* The stdlib package images and every
  store built before this commit carry the version 1 header; the `.ji`
  check on the git commit string recompiles the depot, and `parse_sysimg`
  refuses an old store image with `Image file is not compatible`.

M6 again, `tool/m6_gate.sh` into a fresh `m6b` on the build lane, eight
image threads, load average 2 (the morning runs were on a loaded lane):

| step | wall | peak RSS | result |
| --- | --- | --- | --- |
| founding | 1 min 2 s | 6.0 GB | the store founded; front 18.3 s, `jl_emit_native` 6.7 s |
| run, before | 0.17 s | 0.22 GB | 14 of 14 shapes; bench 0.8 ns/call reused, 0.8 ns/call the other loop |
| rebuild, the edit | 8.8 s | 0.77 GB | 5 expressions in 30.7 ms, cone 5 replaced, 6 closed; 36 new method instances; delta 185 roots, 4 edges; 27087 reused; **138 direct calls, 0 trampolines**, `julia_bench_callee_37610` among them |
| run, after | 0.19 s | 0.22 GB | 14 of 14 shapes; bench **1.0 ns/call reused, 1.0 ns/call from the delta** (43 ns before) |
| rebuild, the reverse edit | 8.2 s | 0.74 GB | delta 15 roots, 0 edges; 15 direct calls, 0 trampolines |
| run, restored | 0.19 s | 0.22 GB | 14 of 14 shapes; bench 0.99 against 0.99 ns/call |

The delta's text objects define `T` symbols with the `.r8` and `.r16`
suffixes, the names table of the delta holds the suffixed names, and the
reverse-edit delta references `julia_bench_callee_37610` of the founding
as an undefined symbol that the link resolves. The ccallable alias is
skipped on both rebuilds as before.

M7 again, `tool/m7_gate.sh` into a fresh `m7b`, same lane and load:

| step | wall | peak RSS | result |
| --- | --- | --- | --- |
| founding build | 2 min 37 s | 9.5 GB | fresh depot, base image cache first |
| run, before | 62 s, user 62 s | 0.69 GB | `hopCount` mean 2.308011 |
| rebuild, the `+= 2` edit | 17.3 s | 1.32 GB | 1 expression in 2.2 ms, world 39301 → 39302; 47 new method instances; delta 392 roots, 7 edges, 1 shadowed; 42644 reused; **363 direct calls, 0 trampolines** |
| run, after | 62 s | 0.69 GB | `hopCount` mean 4.616022 |
| rebuild, the reverse edit | 16.4 s | 1.28 GB | delta 16 roots, 0 edges; 53 direct calls, 0 trampolines |
| run, restored | 62 s | 0.70 GB | `hopCount` mean 2.308011 |

The founded binary ran in 62 s of user time, the same as the rebuilt
binaries: the 180 s of the morning was the lane, as the M7 entry supposed.
The run time of the routing model does not move with the direct call; its
hot loop is inside reused code, so the trampoline never was on its path.

**2026-09-05, the continuation.** The next plan is
`robust-incremental-compiler.md`: the invariant of semantic equality, the
catalog of changes, the rebuild without execution, the recorder of
top-level evaluation, the fresh function table, and the server. It takes
over the open items of this plan: the two-edit chain, the removal of a
method, root files, and harness rule 8.
