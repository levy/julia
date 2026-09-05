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
| the measurement subject | worktree `omnet-julia-m1`, pinned at `e21ba2cd` |
| the gates | `tool/m0_*` (measurement), `tool/m1_gate1.sh` (chain + edit), `tool/m4_gate.sh` (materialize), `tool/m5_gate.sh` (the binary) |

## The runtime patch

The patch lives in `src/aotcompile.cpp`, `src/staticdata.c`,
`Compiler/src/typeinfer.jl` and `Compiler/src/precompile.jl` of this
branch. `JULIA_REACTIVE_REUSE=1` turns it on; `JULIA_REACTIVE_TIMINGS=1`
prints the front, the emission and the delta (`=2` lists every code
instance of the delta and every enqueue cause).

- **A rebuild boots from the previous image** (`julia -J A.so --output-o
  B.a`). The reused code instances are then live objects with native
  pointers, and the runtime maps them to the function ids of the image. A
  fresh process would have to match code instances across heaps by content.
- **Append-only id spaces.** The image format does not change. B's function
  ids start at A's count, its global slots and shards likewise, and every
  defined global object of the delta gets the suffix `.r<nshards>`. So A's
  objects and B's objects link together, and the shard count is the tag of
  a build. This exists because two stock builds cannot share one object:
  every emitted name carries a process-wide counter, the partitions are
  balanced by weight, and the index tables bake the emission order.
- **The reuse test is the world.** A code instance is reused when its owner
  is `nothing`, it is valid in the build's world, and the runtime returns
  image ids for it. Julia's own invalidation bounds `max_world` through the
  backedges, so the cone is never computed — it falls out of the reuse
  test. No recorded-read key is needed while a previous image exists.
- **Calls from the delta into reused code** go through the
  `emit_tojlinvoke` trampoline. Measured: not visible in the run time of
  the routing model.
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

## The numbers (build lane, 8 image threads)

| workflow | full build | steady rebuild | check |
| --- | --- | --- | --- |
| routing example image (M4) | 118 s, 8.0 GB | 20-21 s, 1.1 GB | delta = the cone exactly; hops 3.05 → 6.09; same network hash |
| routing sample binary (M5) | 155 s, 9.7 GB | 12-13 s, 1.3 GB | `hopCount` mean 2.308011 → 4.616022, exactly double, and back |

The apply itself costs 1-3 ms; the rebuild time is the workload plus about
5 s of front, heap and link.

## Known limits

- **One Julia, one target.** A chain is bound to the Julia build and the
  processor target that started it (`-C native` on this machine).
- **Two Stage 1 hazards are untested:** a direct call from the delta to a
  reused symbol instead of the trampoline, and the alias of a redefined
  `@ccallable` method.
- **`--trim` refuses reactive reuse** — the trim verifier walks the edges
  that reuse skips. The trimmed flagship binary is its own milestone.
- **Method removals are not applied**; dead methods stay until a full
  build.
- **No cross-process store without an image.** The recorded-read (cell
  model) store of the design is not built; it is what removes the need for
  a previous image and for the build-id cascade of package images.
- **The builder does not call `materialize_app` yet** — the M5 gate drives
  PackageCompiler directly; `OmnetBuilder` integration is open.
