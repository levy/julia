# The reactive compiler, as built

This document describes the system as it stands and the reasons behind its
shape. The chronological record — what was tried, measured and decided, gate
by gate — lives in
[plan/pending/reactive-materialization.md](../plan/pending/reactive-materialization.md)
and in [plan/pending/hypothesis-case.md](../plan/pending/hypothesis-case.md).
Read this file to work on the system; read the plan to learn how it got here.

## What this is

A persistent, reactive materialization of Julia system images. A build is a
snapshot of a store, the way a commit is a snapshot of a Git object
database. After a source edit, a rebuild boots from the previous image,
applies only the changed expressions, and emits only the invalidation cone
of the edit. Everything else — most of Base, the packages, the application —
links again from the object code of the earlier snapshots.

The measured effect: the routing example image rebuilds in 21 s against
117 s, and the `routing` sample binary bundle rebuilds in 12 s against
155 s, on the same lane. A rebuilt binary runs the edit at full speed.

## Where everything lives

| what | where |
| --- | --- |
| the patched Julia (1.13.0-rc4) | worktree `julia-reactive`, branch `reactive-compiler`; built in `usr/` |
| the campaign: plan, code, gates, this document | `contrib/reactive-compiler/` in the same branch |
| the store and driver of M4 | `src/Materialize.jl`, `src/SourceDiff.jl`, `tool/m4_child.jl` |
| the modified PackageCompiler (M5) | worktree `package-compiler-reactive`, branch `reactive`, branched from `cached-base-sysimage` of `package-compiler` |
| its new code | `src/reactive.jl` (driver + store), `src/reactive_child.jl` (child), `src/SourceDiff.jl` (vendored copy) |
| the measurement subject | worktree `omnet-julia-m1`, branch `reactive-builder` from `e21ba2cd` |
| the builder integration (M7) | `source/build/Reactive.jl`, `source/build/Executable.jl`, `source/tool/build_binary.jl` of that branch |
| the hazard test package (M6) | `tool/m6_hazard/HazardApp` and its edited file `tool/m6_hazard/shapes-after.jl` |
| the gates | `tool/m0_*` (measurement), `tool/m1_gate1.sh` (chain + edit), `tool/m4_gate.sh` (materialize), `tool/m5_gate.sh` (the binary), `tool/m6_gate.sh` (the hazards), `tool/m7_gate.sh` (the builder) |

## The runtime patch

The patch lives in `src/aotcompile.cpp`, `src/staticdata.c`,
`src/codegen.cpp`, `Compiler/src/typeinfer.jl` and
`Compiler/src/precompile.jl` of this branch. `JULIA_REACTIVE_REUSE=1`
turns it on; `JULIA_REACTIVE_TIMINGS=1` prints the front, the emission and
the delta (`=2` lists every code instance of the delta and every enqueue
cause).

- **A rebuild boots from the previous image** (`julia -J A.so --output-o
  B.a`). The reused code instances are then live objects with native
  pointers, and the runtime maps them to the function ids of the image. A
  fresh process would have to match code instances across heaps by content.
- **Append-only id spaces.** B's function ids start at A's count, its
  global slots and shards likewise, and every defined global object of the
  delta gets the suffix `.r<nshards>`. So A's objects and B's objects link
  together, and the shard count is the tag of a build. This exists because
  two stock builds cannot share one object: every emitted name carries a
  process-wide counter, the partitions are balanced by weight, and the
  index tables bake the emission order. The image format changes in one
  place: version 2 adds the names table of the next bullet.
- **The reuse test is the world.** A code instance is reused when its owner
  is `nothing`, it is valid in the build's world, and the runtime returns
  image ids for it. Julia's own invalidation bounds `max_world` through the
  backedges, so the cone is never computed — it falls out of the reuse
  test. No recorded-read key is needed while a previous image exists.
- **The delta calls reused code by symbol.** The image names every
  function of its table: each shard carries `jl_fvar_names_<shard>`, the
  symbol of each entry of `fvar_ptrs`, and `parse_sysimg` keeps the names
  beside the pointers (image format version 2, about 1 MB for 90k names).
  When `resolve_workqueue` meets a callee with image ids, it declares the
  image's symbol instead of an `emit_tojlinvoke` trampoline: a specsig
  caller gets the specialization, a boxed caller gets the wrapper, and a
  `jl_fptr_args` callee gets the specialization through the adapter that
  the stock path already has. The declaration is hidden and `dso_local`,
  so the link binds it to the text object of the earlier build and the
  call is a plain `call`. The declared name carries the marker
  `reactive.image.` until the delta's own definitions get their
  `.r<nshards>` suffix, so a delta name never collides with an image name.
  Every definition of a delta is a hidden external symbol on both output
  paths (`partitionModule` did that with more than one image thread; the
  single-thread path now does the same), so a later build can call it.
  Three shapes keep the trampoline: a `jl_fptr_sparam` callee, an
  opaque-closure callee, and a caller that is itself an opaque closure.
  `TIMINGS=1` prints `reactive: N direct calls into the loaded image, M
  reused callees through the trampoline`; `=2` names each direct call.
  Every call shape — inlined, `@noinline`, `@nospecialize`, keyword,
  varargs, `invoke`, opaque closure, static parameter, `@cfunction`,
  finalizer, and the reverse direction — reaches its callee (M6), and the
  bench loop of the delta costs the same as the loop inside reused code.
- **A `@ccallable` name is defined once.** The previous image's text
  already exports the alias of every `@ccallable` method it knew, and
  `jl_generate_ccallable` asks `jl_reactive_image_exports(name)` before it
  emits a wrapper: an exported name gets no second alias. The old wrapper
  serves a redefined method, because it resolves its target through
  `jl_get_abi_converter` in the current world. `TIMINGS=2` reports
  `reactive: ccallable <name> is exported by the previous image; no new
  alias` — for `julia_main` on every rebuild.
- **The heap (`sysimg.o`) and the tables (`metadata.o`) are always
  rebuilt.** They are cheap, and the reused objects must not depend on
  their layout.

## The store and the chain

A store is a directory that persists across processes. One snapshot per
build holds the **text objects** that the build emitted and a **copy of the
tracked sources**. An image is never kept per snapshot: the latest image is
the live one, and a rebuild links

    ancestors' text objects + the delta + fresh sysimg.o + metadata.o

The heap and the tables of an old build are never linked again. Dead code
accumulates in the old text objects until a full build; that is the
development mode of the design, and compaction is the release mode (open).

## The source diff

`SourceDiff.changed_expressions(old, new, path)` answers only the changed
top-level expressions, each with the module path that leads to it.

- **The comparison ignores line numbers.** An edit near the top of a file
  moves the line of every later expression; a line-aware comparison would
  report the whole file.
- **A `module` block is not one unit.** The walk descends into a module
  that both versions hold, so an edit of one function changes one
  expression.
- **The evaluation keeps real file names.** The parse names the file, so a
  redefined method has a readable `file` and `line`, and an edit on top of
  an edit works — the child compares stored text against disk text and
  never reads a definition back out of a method.
- **A removal is reported and not applied.** Julia has no cheap way to
  undefine a method in a build child; the old method stays until a full
  build. A changed definition does not count as a removal of its old form.
- **A tracked file names its including module in the config.** A file that
  a package includes (`routing.jl`, `Routing.jl`) cannot name its own
  module; no parse can recover it.

## The child harness — the rules to remember

These rules came out of the gates, each after a measured failure.

1. **The harness is part of the image.** Every definition of the child is
   behind an `@isdefined` guard, so a rebuild keeps the compiled functions
   and the delta holds the cone alone. The price: a change of the harness
   does not reach an existing store — the chain must start again from a
   full build.
2. **Warm with content, not with empty inputs.** The machinery must run on
   a synthetic non-empty diff in every build, with the same argument types
   as the real calls, and print the same report shapes. An empty-input
   warm-up does not compile the non-empty arms, and the first real edit
   then carries the machinery in its delta. This lesson appeared three
   times (the key harness of M0, the diff of M4, the resolver of M5).
3. **A workload must only call package functions.** A workload script that
   defines closures at its top level re-evaluates them on every rebuild —
   a small permanent floor in the delta (7 instances with `Batch.jl`). A
   workload of plain calls converges to an empty delta.
4. **The rebuild child imports nothing into `Main`.** The previous image
   already carries the Main bindings of its own build. The child resolves
   the root module of a tracked file through `Base.loaded_modules`.
5. **The first rebuild of a store absorbs the run-time residue of the full
   build** (the code its child JIT-compiled and dropped). Expect one large
   delta (about 180 roots), then convergence.
6. **The founding workload and the rebuild workload are two arguments.**
   `materialize_app`'s `workload` drives the rebuild child only; the
   founding build compiles what `precompile_execution_file` runs. Pass the
   same file as both, or the founding build compiles nothing of the
   program and the first rebuild carries it all.
7. **Do not hold an opaque closure in a top-level `const` of a package.**
   Stock Julia (1.13.0-rc3 too) faults at the call in a fresh process.
   Make the closure in a function. This is a fault of Julia, not of the
   patch.
8. **The side effects of the rebuild workload persist in the image, and
   accumulate along the chain.** The rebuild child runs the workload in
   the process whose heap becomes the image. The founding build does not:
   `create_app` traces the workload in another process and the image
   build executes precompile statements only. So a global that the
   workload mutates starts the rebuilt binary at the mutated value, and
   the next rebuild adds to it (M6: a counter at 0, 2, 3 along founding,
   edit, reverse edit). The rule, decided 2026-09-05: a rebuild workload
   must leave no state, as a `@compile_workload` must. It calls package
   functions, and every global it touches is back at its value when it
   returns. The routing workload complies: it runs a simulation to its
   end and keeps nothing.

## The two entry points

**`Materialize.materialize(store)`** (M4) — the image workflow. The store
is self-contained (`store.toml` names the Julia, the project, the packages,
the tracked files, the workload); the product is an image plus a runner.

**`PackageCompiler.materialize_app(package_dir, app_dir; tracked,
workload, ...)`** (M5) — the application workflow. The first call runs
`create_app` and founds the store inside the bundle (`reactive-store/`);
every later call rebuilds the delta and replaces exactly one file,
`lib/julia/sys.<ext>`. The executable, the libraries and the artifacts
stand. The diff to stock PackageCompiler is two keywords —
`keep_object_archive` (copy the object archive before the build deletes
it) and `extra_object_files` (linked in front of the delta, never deleted)
— plus the three new files; `JULIA_REACTIVE_REUSE=1` is a `withenv` around
one call, and the rebuild runs no separate trace process, because a trace
against the old image would trace the old code.

**`OmnetBuilder.build_executable(; reactive = true)`**, or
`bin/build_omnet_legacy_sample routing --reactive` (M7) — the builder
workflow, on the branch `reactive-builder` of omnet-julia. The builder
computes the tracked list itself: `tracked_sources(package)` walks the root
file of each package for every literal `include` at the top level of a
module, follows the included files, and names the dotted module of each.
The root file is not tracked — its top level runs in `Main`, and the app
image binds no package there — so a new `include` or `using` needs a
founding build. The rebuild workload is the founding workload written to
`rebuild_workload.jl` after a `using` of every package. `reactive` refuses
`trim`, `incremental = false`, `--distribution`, and a store that was
founded for another app package (the builder compares the modification
times of the app files before and after it writes them). The tool
environment takes PackageCompiler from `package-compiler-reactive`.

## The numbers (build lane, 8 image threads)

| workflow | full build | steady rebuild | check |
| --- | --- | --- | --- |
| routing example image (M4) | 118 s, 8.0 GB | 20-21 s, 1.1 GB | delta = the cone exactly; hops 3.05 → 6.09; same network hash |
| routing sample binary (M5) | 155 s, 9.7 GB | 12-13 s, 1.3 GB | `hopCount` mean 2.308011 → 4.616022, exactly double, and back |
| HazardApp binary (M6) | 62 s, 6.0 GB (127-134 s on a loaded lane) | 8-9 s, 0.77 GB (24-26 s loaded) | 14 of 14 call shapes give the new value, and the old one after the reverse edit; 138 direct calls, 0 trampolines |
| routing binary through the builder (M7) | 2 min 37 s, 9.5 GB (fresh depot: the base image cache first; 6 min 22 s loaded) | 16-17 s, 1.3 GB | the same `hopCount` check as M5, by `bin/build_omnet_legacy_sample routing --reactive` twice; 363 direct calls, 0 trampolines; every run 62 s |

The apply itself costs 1-3 ms; the rebuild time is the workload plus about
5 s of front, heap and link. The builder adds about 5 s more: the Julia
start, `Pkg.instantiate`, the load of `OmnetBuilder`, and the walk of the
tracked sources.

A non-inlined call from the delta into reused code costs the same as the
same call inside reused code: **1.0 ns against 1.0 ns** (M6 bench, direct
call; the trampoline that the direct call replaced cost 43 ns against
2.6 ns on a loaded lane). The edit rebuild of M6 makes 138 direct calls and
0 trampolines; the reverse edit 15 and 0. The routing rebuild of M7 makes
363 and 0. The run time of the routing model does not change with the
direct call (62 s before, after and restored): its hot loop is in reused
code.

## Known limits

- **One Julia, one target.** A chain is bound to the Julia build and the
  processor target that started it (`-C native` on this machine). The
  names table holds the names of the base target, so with a multi-target
  `cpu_target` the delta would call the base clone of a reused function.
- **The image format is version 2.** An image without the names table
  does not load (`Image file is not compatible with this version of
  Julia`); a store founded before it needs a founding build.
- **`--trim` refuses reactive reuse** — the trim verifier walks the edges
  that reuse skips. The trimmed flagship binary is its own milestone.
- **Method removals are not applied**; dead methods stay until a full
  build.
- **The rebuild workload's side effects persist** (rule 8). Accepted
  2026-09-05: the rule on the workload is the fix for now. The other way,
  with the founding semantics exactly, is a trace child before the build
  child: the same apply of the tracked diffs, the workload under
  `--trace-compile`, and a build child that executes the statements and
  runs nothing. It costs one more process start and the workload once
  more; estimated for the routing rebuild: 12 s → 16-20 s. Take it when
  a workload needs state that it cannot undo.
- **Three call shapes keep the trampoline**: a `jl_fptr_sparam` callee, an
  opaque-closure callee, and a caller that is an opaque closure. Each costs
  about 40 ns per non-inlined call from the delta.
- **No cross-process store without an image.** The recorded-read (cell
  model) store of the design is not built; it is what removes the need for
  a previous image and for the build-id cascade of package images.
- **An edit to a root file, a new `include`, or a new `using` needs a
  founding build.** The builder tracks the included files of a package and
  not its root file. Remove `reactive-store/` under the output, or build
  into another output.
- **The builder integration lives on a branch of the pinned worktree**
  (`reactive-builder` of `omnet-julia-m1`, from `e21ba2cd`), not on the
  main line of omnet-julia.
