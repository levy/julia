# The reactive compiler, as built

This document describes the system as it stands and the reasons behind its
shape. The chronological record — what was tried, measured and decided, gate
by gate — lives in
[plan/done/reactive-materialization.md](../plan/done/reactive-materialization.md)
and in [plan/done/hypothesis-case.md](../plan/done/hypothesis-case.md). The
plan
[plan/pending/a-rebuild-equals-a-whole-build.md](../plan/pending/a-rebuild-equals-a-whole-build.md)
holds the findings, the decisions and the open steps of the work that makes a
rebuild give the program that a whole build gives.
Read this file to work on the system; read the plans to learn how it got here.

## What this is

A persistent, reactive materialization of Julia system images. A build is a
snapshot of a store, the way a commit is a snapshot of a Git object
database. After a source edit, a rebuild boots from the previous image,
applies only the changed expressions, and emits only the invalidation cone
of the edit. Everything else — most of Base, the packages, the application —
links again from the object code of the earlier snapshots.

The first build of a store compiles the whole program. This document calls it
a **whole build**; the code and the older text call it a *founding*. Each later
build is a **rebuild**. A rebuild has one goal: the rebuilt program is the
program that a whole build of the same sources gives. A change that a rebuild
cannot apply is refused, and an input of the store that changed stops the
build with its name. "Known limits" lists what a rebuild does not see.

The measured effect: the routing example image rebuilds in 21 s against
117 s, and the `routing` sample binary bundle rebuilds in 12 s against
155 s, on the same lane. A rebuilt binary runs the edit at full speed.

## Where everything lives

| what | where |
| --- | --- |
| the patched Julia (1.13.0-rc4) | branch `merged-next`, worktree `julia-merged-next`; built in `usr/` |
| the campaign: plan, code, gates, this document | `contrib/reactive-compiler/` in the same branch |
| the plan of the work that makes a rebuild equal a whole build | `plan/pending/a-rebuild-equals-a-whole-build.md` |
| the harness: the ledger and classifier, the apply, the reads, the replay, the save, the trim entry points, the server | the stdlib `stdlib/ReactiveCompiler` of the patched Julia, built into the system image: `src/child.jl` (ledger, classifier, apply, reads, listing of the changes), `src/replay.jl` (the trial in a fork and the checks of the load order), `src/server.jl` (the server and the save), `src/patch.jl` (the patch of a package file and the record of its top-level reads), `src/SourceDiff.jl`, `src/entrypoints.jl`, `src/ReactiveCompiler.jl`; `julia --reactive-server=<socket>` runs its server |
| the runtime | `src/toplevel.c` (the place of the top-level expression, the record of reads), `src/method.c` (the method filter, the place of a method), `src/gf.c` (the leaf cache of dispatch, the batch that disables methods), `src/module.c` (the removal of names, the batch that hides names), `src/stackwalk.c` (the frames of a moved method), `src/staticdata.c`, `src/aotcompile.cpp`, `src/processor.cpp`, `src/codegen.cpp` (the image, the overlay, the delta), `base/loading.jl` (the listing beside a cache file), `base/iostream.jl` and `base/filesystem.jl` (the hooks in `open`) |
| PackageCompiler, the client | branch `reactive` of the fork `projectured/PackageCompiler.jl`: `src/reactive.jl` (the driver, the store, the inputs, the record of the builds, the status) and `src/reactive_cli.jl` (the command line) |
| the builder integration | `source/tool/builder/ReactiveBuild.jl` of projectured-julia (a fragment of `BuilderModule`), which the builder of omnet-julia calls; the scripts `bin/build_projectured` and `bin/build_omnet_ide` |
| the hazard test package | `tool/m6_hazard/HazardApp` and its edited files `tool/m6_hazard/shapes-after.jl`, `shapes-after-2.jl`, `changes-after.jl`, `changes-reformat.jl` |
| the gates that a change of the harness must pass | `tool/gate_runs.sh` (the code that an expression runs, the reads, the failed edit, the inputs, the early end, the new recording), `tool/gate_cases.sh` (a table of small edits, each applied as a whole build applies it or refused), `tool/gate_replay.sh` (the commits of a real package, one after the other, against a whole build of the last), `tool/gate_c.sh` (a chain does not grow), `tool/gate_b.sh` (the change categories and the refusals, through the oracle), `tool/oracle_gate.sh` with `tool/oracle.jl` (a two-edit chain against the whole build of the final sources: the same method tables, roots, output and globals), `tool/gate_harness.sh` (a rebuild that runs the harness of the installed Julia), `tool/gate_const.sh` with `tool/overlay_check.py` (the constant data of an overlay), `tool/gate_server.sh` (the server of a store), `contrib/merged/gate_prelinked_chain.sh` (a prelinked program under a chain) |
| the other gates | `tool/gate_d.sh`, `gate_f.sh`, `gate_g.sh` (ten edits through the server, the image written by pages, by overlay), `gate_e.sh` (the trimmed product), `gate_h.sh` (a client with the socket alone), `gate_cli.sh` (the command line), `gate_i1.sh`, `gate_i2.sh` (path packages and the IDE store) |
| the first store and its gates | `src/Materialize.jl`, `tool/m4_child.jl`, `tool/m0_*`, `tool/m1_gate1.sh`, `tool/m4_gate.sh` to `tool/m7_gate.sh`; [README.md](../README.md) lists them as the instruments of the measurements that `plan/done/` reports |

## The runtime patch

The patch lives in `src/aotcompile.cpp`, `src/staticdata.c`,
`src/processor.cpp`, `src/codegen.cpp`, `src/method.c`, `src/toplevel.c`,
`src/gf.c`, `src/module.c`, `src/stackwalk.c`, `base/loading.jl`,
`base/iostream.jl`, `base/filesystem.jl`, `Compiler/src/typeinfer.jl` and
`Compiler/src/precompile.jl` of this
branch. Every control is a flag of `julia` with a variable as its default
(`--help-hidden` lists them): `--reactive-server=<socket>` runs the compiler
server; `--reactive-image-format`
(`JULIA_REACTIVE_IMAGE=1`) selects the reactive image format for a
founding; `--reactive-reuse` (`JULIA_REACTIVE_REUSE=1`) turns the reuse on
for a rebuild (and implies the format); `--reactive-image=whole|pages|overlay`
(`JULIA_REACTIVE_IMAGE_WRITE`) is the way a save writes;
`--reactive-delta-opt=N` the level of the delta's code;
`--reactive-timings=1` (`JULIA_REACTIVE_TIMINGS`) prints the front, the
emission and the delta (`2` lists every code instance of the delta and
every enqueue cause); `--reactive-trim-memo`, `--reactive-heapdump` and
`--reactive-dirty-pages` name their files. A flag sets a field of
`jl_options`; an unset field reads the variable, so a gate drives a build
through the environment and a flag wins.

- **A rebuild boots from the previous image** (`julia -J A.so --output-o
  B.a`). The reused code instances are then live objects with native
  pointers, and the runtime maps them to the function ids of the image. A
  fresh process would have to match code instances across heaps by content.
- **The reactive image format (version 3).** A stock image spreads its
  function table over the shards of one build (`jl_fvar_ptrs_<s>`,
  `jl_fvar_idxs_<s>`, and the clone tables of a multi-target build), and
  two stock builds cannot share one object: every emitted name carries a
  process-wide counter, the partitions are balanced by weight, and the
  index tables bake the emission order. A reactive image holds **one
  function table in `metadata.o`**: `jl_fvar_ptrs` in id order, and
  `jl_fvar_names`, the NUL-joined symbol of every entry, which
  `jl_image_pointers_t` reaches through `fvar_ptrs` and `fvar_names`. No
  `fvar_idxs` exists, because the table is in id order. The shards keep
  only their global slots (`jl_gvar_offsets_<s>`, `jl_gvar_idxs_<s>`),
  and the header's `nshards` counts them; the function and clone fields
  of a shard are null, and the loader takes the one target. Every
  function and every global goes in its own section (`FunctionSections`,
  `DataSections`), and the link runs with `--gc-sections`: the fresh
  table is the only root of a function, so a function that the table
  does not name — dead code of an old build — leaves with its section.
  `jl_reactive_image_format()` answers whether the running build writes
  this format; `JULIA_REACTIVE_IMAGE=1` selects it for a founding, reuse
  implies it, and a rebuild from a version 2 image is refused.
- **Fresh function ids, append-only global slots.** `reactive_rebase`
  numbers the functions of B: the reused ones first, in the order of the
  loaded image (which keeps a wrapper before its specialization), then
  the delta; `fvar_base` is the reused count. The global slots stay per
  shard and append-only: the old machine code addresses its
  `jl_sysimg_gvars_<s>` slots directly, so B's shards start at A's count
  (`shard_base`), and every defined global object of the delta gets the
  suffix `.r<nshards>`, the tag of a build. A dead function's globals
  keep a slot and a root until a founding: that is the residue that a
  founding compacts.
- **The reuse test is the world.** A code instance is reused when its owner
  is `nothing`, it is valid in the build's world, and the runtime returns
  image ids for it. Julia's own invalidation bounds `max_world` through the
  backedges, so the cone is never computed — it falls out of the reuse
  test. No recorded-read key is needed while a previous image exists.
- **The delta calls reused code by symbol.** The image names every
  function of its table (`jl_fvar_names`, about 1 MB for 90k names), and
  `parse_sysimg` keeps the names beside the pointers. The names of the
  reused functions travel in `jl_native_code_desc_t` to the emission.
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
  paths (`partitionModule` with more than one image thread, and the
  single-thread path), so a later build can call it.
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
- **A method filter answers an identical redefinition.** `jl_method_def`
  never skips a redefinition: an identical one moves the world and
  invalidates every caller for nothing (an `@eval` loop with one changed
  method, a dependent whose expansion did not change). `src/method.c`
  asks the Julia function of `jl_reactive_set_method_filter` before the
  insertion; the rebuild child installs `rc_method_filter`, which keeps
  the live method when the module, the signature, the method flags and
  the uncompressed IR are equal. The kept method takes the two places of the
  new definition (see "A method has two places") and its line table; its
  code instances keep their own line tables. A generated method is
  never kept.
- **The heap drops the closed entries and the invalid code instances.**
  `jl_method_table_disable` closes the typemap entry of a deleted method
  and invalidates its callers, but never bounds the code instances of the
  deleted method itself, and `Base.visit` walks closed entries; so a
  rebuild after a deletion would infer, name and serialize dead code. The
  reactive sysimage path of `staticdata.c` prunes before the walk: a
  typemap entry whose `max_world` is finite and does not hold
  `jl_typeinf_world` is dead, and so is a code instance that
  `codeinst_may_be_runnable` rejects. The prune unlinks a dead entry from
  its `next` chain in `defs`, in the method cache and in the leaf cache
  (`record_field_change`), and a dead code instance from `mi->cache` and
  `ci->next`. An emptied slot of a level hash or of the leaf cache becomes
  the tombstone of `iddict.c` (key `nothing`, value null): the leaf cache
  dereferences any non-null value, and `Base.visit` has no method for
  `nothing`. The front end (`collect_all_method_defs`) walks the entries
  itself in the reactive format and skips a method whose entry is valid
  in none of the build's worlds. The oracle counts what is left (`info
  dead N closed entries, M invalid code instances`): zero in a chain, as
  in a founding.
- **The `using` backedges and the scanned methods of a module are weak.**
  Every `Module()` does `using Base` and `using Core`, which pushes the
  module into `Base.usings_backedges`; the first compile of a method that
  names an implicit binding pushes the method into the `scanned_methods`
  of its module, and a deletion never removes it. Stock serializes both
  lists strongly, so every anonymous module of a rebuild (the warm-up, the
  object script) stayed in the image with its bindings, and a deleted
  method that was compiled once stayed with its code: 19 KB per no-edit
  rebuild. In a reactive image both lists are weak: the serializer queues
  the list and its memory, the members only when something else reaches
  them, and prunes the list to the serialized members once the heap is
  known, the way it prunes the backedge lists of a binding. Two more
  roots live in the tooling: a closure in the object script of
  PackageCompiler is a method, and a method-table entry roots its module
  (a loop replaced it); a `--output-o` process runs no `__init__`, so
  nothing registers the exit hook that deletes the temporary files of the
  process, and their paths stayed in `Base.Filesystem.TEMP_CLEANUP` (the
  object script purges the list before the write); and the child script
  kept its state in a global of `Main`, the set of every method instance
  of the rebuild (it clears the global). Two more are Julia's: the
  interference set of a method (`Method.interferences`, the intersecting
  methods) gains every later method with an intersecting signature, a
  deleted method included, and nothing removes a member, so a chain of
  redefinitions linked every dead method to the next; the set is weak in
  a reactive image, pruned to the serialized members like the lists
  above. And the compile pass runs once per world, the world of the
  compiler first; a `@ccallable` entry point resolved in that world names
  the method that dispatched there, the deleted one, and its code
  instance rooted the method with its text. A reactive build resolves an
  entry point in the latest world only, and compiles and reuses nothing
  for a method that the method table no longer holds (`jl_methtable_lookup`
  in the latest world; the dispatch status bits of a method restored from
  an image are cleared, so they cannot say): a deleted or replaced method
  keeps its code instances open, `jl_method_table_disable` bounds the
  callers only, and the previous image would serve them. The skip also
  drops the leftovers of Base's bootstrap, dead since the founding. What
  stays is the slot residue: a slot of the loaded image keeps its value,
  and the value of a slot of a dead function is kept with it (the
  founding's `@ccallable` wrapper keeps the founding's code instance of
  its target, and through it the deleted method: one, not one per
  rebuild). `JULIA_REACTIVE_HEAPDUMP=<path>`
  writes one line per object of the heap (address, type, size, a short
  head, and the object that reached it first); the diff of the dumps of
  two rebuilds names what a rebuild keeps, and `tool/heap_chain.py`
  follows the referrers of an object up to its root.
- **A method has two places.** The file and the line of a method (`file`,
  `line`) are the place of its text. Two more fields, `toplevel_file` and
  `toplevel_line`, hold the place of the top-level expression whose
  evaluation defined the method: the file and the first line of that
  expression. The two differ for a method that the expansion of a macro
  defines, because its text is in the macro and its definer is the user of the
  macro. The runtime knows the expression that it evaluates
  (`jl_toplevel_expr_file`, `jl_toplevel_expr_line` in `src/toplevel.c`). A
  line number node of the form that a loader gives to the evaluation sets the
  place; a line number node inside the result of a lowering does not, so a
  macro that returns top-level forms with its own lines changes nothing, but
  the body of a module is the exception: its forms set the place also inside a
  macro call. An `eval` inside a top-level expression keeps the place of that
  expression. Outside each top-level evaluation there is no place, and a
  method that the program defines at run time has none. The place is one
  value of the process, as `jl_lineno` is, and it is not thread safe: a
  package loads in one task, and so does an apply.
- **The runtime records the files that a top-level expression opens.** A build
  installs a `Vector{Any}` with `jl_reactive_set_read_record`. `open` of
  Base (`Filesystem.open` in `base/filesystem.jl` and `Base.open` in
  `base/iostream.jl`) asks `jl_reactive_records_reads`, and for a file that
  it opens for a read only it calls `jl_reactive_note_read`, which adds the
  file, the line and the path to the list: the place of the top-level
  expression that runs (the place that a method keeps as its definer) and the
  absolute path. With no list, or outside a top-level expression, nothing is
  recorded. The hook is in `open` of Base and not in the function of C
  that opens, because the runtime itself opens images and caches through that
  function, and those are no reads of a package.
- **The frame of a moved method names the line of now.** A rebuild keeps the
  machine code that the image holds for a moved method, and that code names
  the lines of its compile. `jl_lookup_code_address` and the print of a crash
  (`src/stackwalk.c`) find the line table of the method that the frame was
  compiled from. When the line table of the method now holds the same
  statements at another first line or in another file (the same statements,
  the same edges, each line of the file of the method at the same distance),
  the frame takes the shift and the file. This holds for the function of the
  frame and for each function inlined into it. The frames of interpreted
  inferred code and the print of inferred code (`code_typed`) are not
  corrected.
- **A new method closes the leaf-cache entries that it takes over, no
  more.** `jl_method_table_activate` closes an entry of the method cache and
  of the leaf cache of dispatch when its method instance is one that the new
  method takes over, and leaves the leaf cache in place. A leaf cache that
  an edit emptied would give the program the few entries that the rebuild
  process made after the apply, patch each closed entry of the base into the
  overlay, and send the first call of each other concrete signature through
  the slow path of dispatch.
- **Names leave a module, and a batch takes many methods and names out at
  once.** `jl_reactive_module_unexport`, `jl_reactive_module_unuse` and
  `jl_reactive_binding_leave` (`src/module.c`) take an export, a `using` and a
  bound name out of a module, in a new world. `jl_reactive_binding_leave`
  leaves the binding as one that the module never bound, so the export of a
  used module gives the name again, which the guard that
  `Base.delete_binding` leaves does not. The check of the load order of the
  replay needs the later methods and names out of a program; one by one, a
  method costs a pass over the whole method table and the dispatch cache, and
  a name a scan of each method of its module. `jl_reactive_methods_disable`
  (`src/gf.c`) disables a set of methods in one new world with one visit of
  each method table and its cache, and `jl_reactive_bindings_hide`
  (`src/module.c`) invalidates a set of names with no pass over the methods;
  the harness then does one pass for all names (`rc_invalidate_named!`). Only
  the check calls them, in a fork that writes no image. On a module of 20 000
  methods and 1 000 constants, one pass for all names took 0.025 s against
  1.9 s for the names one by one.
- **In the overlay form, a call to an old function with boxed arguments goes
  through a slot.** A callee of the loaded image with boxed arguments gets a
  slot in the overlay (`jl_reactive_overlay_mode` in `src/codegen.cpp`): one
  load and one indirect call, as a call with a specialized signature does,
  where a package image calls it through the `jl_invoke` trampoline. The bench
  loop of gate M6 measures 2.0 ns against 1.55 ns from old code.
- **An overlay names its base, and a start reads only what it applies.** The
  header of an overlay holds the checksum of the base that its writer loaded
  and the checksum of its own blob. The loader applies an overlay to that base
  only: two whole builds can have the three sizes of the header in common. A
  start takes the identity of an overlay from the field and reads no byte of
  the overlay that it does not apply.
- **The heap (`sysimg.o`) and the tables (`metadata.o`) are always
  rebuilt.** They are cheap, and the reused objects must not depend on
  their layout.

## The store and the chain

A store is a directory that persists across processes. One snapshot per
build holds the **text objects** that the build emitted, a **copy of the
tracked sources**, the **listing of the files that the top-level expressions
read** (`reads.txt`, see "The reads") and the **listing of the changes** that
the apply made (`changes.txt`); the store holds one **trace**, `trace.jl`, the
roots of the image, the **record of the builds** (`builds.txt`) and
`store.toml`, which names the config, the inputs of the whole build and the
snapshots. An image is never kept per snapshot: the latest image is the
live one, and a rebuild links

    ancestors' text objects + the delta + fresh sysimg.o + metadata.o

The heap and the tables of an old build are never linked again. The old
text objects are a library of named functions: the fresh table names the
live ones, and `--gc-sections` drops the rest at the link, so the image
of a chain holds one definition per live function and does not grow with
the edits. The dead sections stay in the objects of the store, and the
global slots of a dead function stay in the image, until a founding.

**The trace is the set of roots, and no build executes the program.** The
founding runs the workload once in a throwaway process under
`--trace-compile`, from the base image and the source-only cache, so that
every specialization the workload executes is compiled there and recorded;
the statements, with the entry of every executable, are the precompile
statements of the founding and the store's `trace.jl`. A rebuild child
applies the diff and precompiles every statement of the trace: a statement
that the image compiles is a lookup, a statement that the edit invalidated
infers its cone again, and the write of the image compiles what inference
made. So the heap of a rebuilt image holds no execution state, exactly as
the heap of a founding. A specialization that no statement names — one
that an edit introduced, reached by a dynamic call — is compiled by the
binary at run time until `refresh_trace(app_dir)` runs the workload once
more from the current image: what the image already compiles is not
recorded, so the new statements join the old ones, and an old statement
that no longer precompiles from the image is dropped.

An edit can make a statement of the trace stop precompiling: a type that
moved, a function that left, a struct whose type parameters changed with a
field. The whole build counts the statements that did not compile
(`founding_lost` in `store.toml`). A rebuild lists its unresolved statements in
`trace.jl.unresolved` beside the trace and prints their count
(`lost_statements`); when the count is above that of the whole build, an info
line names `refresh_trace` and the listing. A rebuild runs no workload and
records no new statement: a person runs `refresh_trace` when the program is
slow enough to need it, and until then the program compiles the lost calls
when it runs them. The harness keeps, for the session, the type that each
statement gave and the statements that did not resolve; it drops both when a
constant gets another value or a name leaves a module.

## The inputs of a store

A whole build records a print of each input that is not a tracked source
(`inputs` in `store.toml`, from `_reactive_inputs`): the build of Julia, the
project file, the Manifest entry of each package, the preferences files
(`LocalPreferences.toml`, `JuliaLocalPreferences.toml`), the text of the
workload, the statements files, and each source file that the image was made
from and the build does not track. The walk of the includes reads the text of
the sources, so it tracks no file whose path the text computes (an `include`
in a loop, a path from a function). Julia records each included file in the
header of the cache file of its package, with its size and its checksum; the
build reads those headers, and the packages whose sources a person edits (the
package of the build and each package that the Manifest names by a path)
give the untracked files. A rebuild takes the prints again and compares them.
A rebuild with another print stops before the apply, names the input, and
names the option that founds the store again (`founding = true`, `--found` in
the build scripts). It does not start a whole build by itself. The stop adds a
`stopped` line to the record of the builds.

A whole build and a rebuild copy the tracked sources into the snapshot before
they load them, so an edit that arrives during a build is a change of the next
rebuild.

## A build with no change

A rebuild with no change does no work. After the check of the inputs, the
driver compares the sources with those of the last snapshot
(`_reactive_unchanged_since`): the same tracked files with the same roots and
texts, each file that a top-level expression reads with the same content, and
the same trace. Each snapshot records the print of the trace, so a new
recording (`refresh_trace`) is a change. When nothing changed, the build ends
before the server, the save and the link, and says that the program stays as
it is. The option `rebuild_unchanged` (`JULIA_REACTIVE_REBUILD_UNCHANGED=1`)
turns the early end off, for a test that asks a server for a save with no
change. A build with no change adds no line to the record of the builds.

## The base of an overlay store

In the overlay form each rebuild writes one overlay from the base image, so
each save compiles again each function that changed since the base. After a
rebuild the driver measures the code of the overlay against the code of the
base (`_reactive_delta_share`): the size of the text objects of the last
snapshot, which hold each function that a change compiled since the base,
against the size of the text objects of the base. The size of the overlay is no
measure, because it has a part that follows the base, the lists of the whole
image. Each rebuild prints the share as `code_percent`.

Past the bound (`rebase`, `JULIA_REACTIVE_REBASE`, 0.02, that is 2 %) the base
moves forward. The server stops, and a child in the whole form starts from the
base image, applies each change since the base, as a new server does, and
writes a whole image. That image takes the place of the base. Its snapshot
holds the text objects of the old base too, and it becomes the first snapshot
of the store; the chain of overlays is empty. The archive for the program
(`keep_object_archive`) is written last, so that the builder links and prelinks
the program again, as after a whole build. The next rebuild starts a new server
from the new base. A rebase that fails leaves the overlay of the rebuild in
place and warns; the next build tries again. On the platform of
projectured-julia a rebase costs 35 s to 43 s, once, and each later rebuild is
about 18 s shorter; on the kernel it costs 8 s to 10 s. The growth of an
overlay store never starts a whole build. A store in the whole or the pages
form founds again by itself after `compact` saves or when its image grew by the
fraction `compact` names (`JULIA_REACTIVE_COMPACT`, 50 saves and 0.25 by
default).

## The record of the builds

The store has one text file, `builds.txt`, with one line for each build. A
build appends its line at its end. The fields of a line have a tab between
them: the time, the kind, and then fields of the form `name=value`.

| kind | when | fields |
| --- | --- | --- |
| `whole` | a whole build made the store | `cause`, `seconds`, `statements`, `image_bytes` |
| `rebuild` | a rebuild made a snapshot | `snapshot`, `form`, `seconds`, `changes`, `overlay_bytes`, `code_percent`, `growth_percent`, `lost` |
| `base` | the base of an overlay store moved forward | as a rebuild |
| `refused` | the apply refused the edit | `reasons` |
| `stopped` | an input of the store changed | `inputs` |
| `recorded` | `refresh_trace` recorded the workload again | `statements`, `kept`, `dropped`, `added` |

`changes` holds the count of the changes of each id of the catalog, as
`A2:14,C1:3,E1:1`. The harness lists the changes of an apply in `changes.txt`
beside the read listing of the snapshot, with the id, the place and the note of
each change, and the driver counts the ids from that file. A whole build takes
the record of the store that it replaces, and gives its own line the cause of
the whole build, so the record shows why the store was made again. A build with
no change has no line, and a build that fails (an edit that throws at its load,
a link that fails) has none. The file has no bound; a line has about 200
bytes. `build_record(app_dir)` answers the lines as a list, and
`print_store_status` prints how often each kind occurs, with the causes of the
whole builds, the ids of the refusals and the inputs of the stops.

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
- **The files match by path, then by content.** A renamed file is a move
  of its expressions, and a lone leftover pair is a file that was renamed
  and edited.
- **A tracked file names its including module in the config.** A file that
  a package includes (`routing.jl`, `Routing.jl`) cannot name its own
  module; no parse can recover it.

## The ledger and the classifier

The rebuild child keeps a **ledger** of the tracked sources: for each
top-level expression (an *item*), its kind and defined name, and its methods.
The rules read the other facts from the expression when they need them: the
heads of the macros that it expands, the names of its type level (signatures,
field types, initializers), and the names that it mentions
(`macro_heads`, `type_level_names` and `all_names` of `ReactiveSourceDiff`).
The old ledger comes from the store's copy of the sources and the live method
table. A method belongs to the item whose evaluation defined it: a method keeps
the place of its top-level expression (`toplevel_file`, `toplevel_line`), and
the ledger gives an item the methods whose place is the file and the first
line of the item (`rc_methods_by_definer`, `rc_assign_methods!`). So a method
that the expansion of a macro defines belongs to the user of the macro, and
not to the function that builds the expansion, and the method of a generator
belongs to the item that defines the generated method. A generator with no
place has no item, and it leaves with its generated method
(`rc_delete_method`). A server keeps the ledger from one apply to the next
(`keep_ledger`); a process that writes its image next keeps none, because it
would be in the image.

The **classifier** (`rc_classify`) gives every change an id of the catalog
of `plan/pending/robust-incremental-compiler.md`, and the report is one
`rc: change <id> <file>:<line> <name> (<note>)` line per change. The apply
(`rc_apply_tracked`) runs in this order:

1. The match of the old file list with the new one: by path and module, then
   by content (a renamed file), then a lone leftover pair. A file whose
   `include` line moves to another module is a removed file in the module of
   before and an added file in the module of now.
2. The diff of each matched pair by key, and the classification of each
   changed or removed item. A refusal stops here, before any evaluation.
3. The statement group, for the statements that the edit changed or removed.
4. The replay: a trial in a fork that finds the items whose text stays and
   whose evaluation gives another result (see "The replay").
5. The apply, in the load order (`RcLoadOrder`): the removals delete their
   methods and take their names out of their modules first, then each change
   is evaluated in its module, and the dependents that the evaluation reveals
   join the queue.
6. The new ledger, the deletion of the old methods that no evaluation
   replaced, and the listings of the reads and of the changes.

The load order of the founding:

- a package comes after the packages that it loads, in the order of
  `Base.loaded_modules_order` of the process; a package that is not loaded
  comes last;
- when the ledger holds every tracked file, the items of an included file
  come at the line of its `include`, so a `using` after an `include` comes
  after the module that the included file defines;
- when the ledger holds the changed files alone, no expression changed, and
  the files of a package keep the order of the tracked list, which lists a
  file before the files that it includes.

The changes and their dependents:

- a removed expression deletes its methods, and takes out of its module the
  names that it gave (a type, a constant, a global, a name of a `using` or an
  `export` line), when no expression of the edited sources gives them again.
  A function that moves to another module leaves the first module with its
  methods and its export, so a module that uses both modules does not see two
  functions of the name. A `using` that left closes its entry in the module,
  and each name that came from it resolves again. Julia keeps a guard on a
  deleted binding, which hides the export of a used module, so the removal of a
  name uses the functions of the runtime that give the name back to that
  export;
- a changed expression deletes its old methods. An old method that the
  evaluation replaced leaves at its replacement: Julia keeps a replaced method
  in the table until its deletion, a lookup of its function is valid only from
  the world of that deletion on, and a generator runs in the first world of its
  generated method, so the code of a generator that calls a changed function
  must be valid in that world. An old method with no replacement of its
  signature leaves at the end of the apply. A method that an identical
  redefinition kept is neither replaced nor deleted;
- a changed declaration that changes its kind (a global that becomes a
  constant, a constant that becomes a global, a typed global that gets another
  type) deletes the binding of before first (`rc_drop_other_declaration!`),
  because Julia changes no such declaration in a module that holds the name;
  a whole build has only the declaration of now;
- a type whose shape changed re-evaluates every tracked expression that
  names it, and every method of a tracked expression whose signature holds
  it; a changed abstract type does the same for its subtypes, transitively; a
  type with the same shape is a change of its constructors alone. The
  dependents come from the bindings that the evaluation gives another value
  (`rc_rebound_constants`), and not from the name that the source shows: the
  call of a macro can bind names that its source does not show, as a macro
  that defines two types;
- a changed `using` or `import` re-evaluates every expression of the module
  whose free names resolve differently after it, and so does a name that
  leaves a module. A name that two imports give is decided by the first
  expression of the load order that gives it, as in a whole build;
- a changed macro re-evaluates every expression that expands it,
  transitively; the heads are syntactic;
- a changed or removed statement evaluates its group again (see "The statement
  group");
- a file that an expression reads and that has another content re-evaluates
  its reader (see "The reads");
- an unchanged expression that moved gives the methods that it defined its
  new first line, and the methods whose text is inside it a shift of their
  lines. The apply gives a moved method a new line table: a copy of the table
  of before, with each line of the file of the method moved by the shift, and
  the new file for a renamed file. The method of each opaque closure in its
  code moves with it. The line tables of the code instances stay as they are,
  because the machine code that the image reuses was compiled from them. A
  reformat applies nothing else. The apply writes these places when it begins,
  after the trial: a refusal or a trial that stops leaves each method at its
  place;
- an unchanged expression that moves in the load order, before or after
  another one, is evaluated at its new place, because a whole build gives it
  the code that it loads before that place. An item that runs tracked code
  when it loads (a candidate of the replay) is evaluated again, and a plain
  statement joins the statement group. A definition that now comes after an
  item that names it in a signature, a field, an initializer or a statement is
  refused.

A **refusal** stops the child before any evaluation (`rc: refuse <id>
<where>: <reason>`, exit 3), the parent removes the snapshot, adds a `refused`
line to the record of the builds, and errors with a whole build as the advice.
Refused: a module option, `__precompile__` included (`F1`); a `using` of a
package that is not in the image (`F3`); an import that conflicts with a
binding of the module (`C3`); an `include` of an untracked file (`C4`); a
changed module header or any other top-level expression of a root file
outside its module (`C5`); a type whose redefinition reaches a method of an
untracked file (`B2`); a changed signature of a `@ccallable` function, whose
C entry the whole build made by its name (`A4`); a statement that names no
tracked global, or whose state does not come back (`S1`); a definition that
comes after an item that names it (`H4`); an expression that the checks of
"The replay" cannot give the state of its place. An apply of a package patch (`write_package_patch`)
takes only the new, changed or removed method, the changed constant and the
changed macro, with the expressions that name them (`PATCH_CHANGES`), and
refuses every other change.

## The statement group

A statement that changes the state of a global does its effect at its place in
the load order, and the effect stays when the statement changes. The state of a
tracked global is made by its definition and by each statement that names it.
When the edit changes or removes a statement, the apply takes back what the
statement did: the group is the definitions of the tracked globals that the
statement names, and each plain statement that names one of them, closed over
both (`rc_statement_group!`). The apply evaluates the definitions first and the
statements after, in the load order. Before the changes, a check evaluates the
definitions with the statements of before the edit and compares the value of
each global with the value that it had (`rc_check_statement_group`): a global
that does not come back has a writer that the rebuild does not find, and the
edit is refused. A statement that names no tracked global and is not a
`precompile` call has an effect on a value that the rebuild cannot make again,
and the rebuild refuses it.

## The reads

A top-level expression can read a file when a package loads: a constant that
holds the text of a file is an example. A changed file must evaluate its
reader again.

- **The runtime records the reads.** A build installs a list in the runtime
  (`jl_reactive_set_read_record`). The `open` of Base names each file that it
  opens for a read only, and the runtime adds the file to the list with the
  place of the top-level expression that runs: the file and the first line of
  that expression. The record finds a reader through any function and any
  computed name, and it takes no file that only the running program reads.
- **Where the record runs.** A whole build does not evaluate the sources of a
  package in its own process: it loads each package from its cache file. So the
  process that makes the cache file installs the list while it loads the package
  (`Base.include_package_for_output`), and writes at its end a listing of the
  reads of the package beside the cache file (`Base.package_reads_file`, the name
  of the cache file with `.reads`; written by `rc_write_package_reads`).
  `Base.compilecache` moves the listing with the cache file and removes it with
  an evicted one. A whole build takes the listing of each package that it loaded
  (`rc_write_loaded_reads`), and keeps the reads of the tracked sources
  (`rc_found_reads`). A cache file with no listing stops the whole build: each
  process of this Julia that makes the cache file of a package writes the
  listing, also an empty one, so a cache file without it came from a copy. A
  rebuild installs the list while it evaluates the changes
  (`rc_start_read_record`, `rc_stop_read_record`). A patch build of a package
  takes the listing of the file that it patches as the old listing. Julia's
  check of a cache file does not change: a changed read file does not make a
  cache file out of date.
- **The listing.** The listing of a snapshot, `reads.txt`, has one line for
  each read: the print of the content of the file, the line and the source
  file of the expression, and the path, with a tab between them. A file with
  another print evaluates its expression again (rule E1), and the new
  evaluation gives the reads of the expression again. An expression that the
  edit leaves, and that no change evaluates, keeps its reads; a moved one keeps
  them at its new place.
- **The print.** The print of a read file is a hash of its content. A process
  learns the path of a read only when the read occurs, so it cannot take the
  print before the load, as a build does for the sources. A file with a
  modification time not earlier than the start of the build gets the print
  `changed`, which equals no content, so the next rebuild evaluates its reader
  again. A file that is not there has the print `absent`.
- **Not a read of the package:** a file of a place outside the tracked sources;
  a tracked source; a file under `/proc`, `/sys` or `/dev`; and a file that a
  `using` or an `include` expression opens, because that is the load of
  packages, whose inputs are the inputs of the store.
- **Not covered.** A decision by `isfile`, `stat` or `readdir` with no open; a
  library of C that opens a file by itself; a function that keeps what it read,
  so that a second evaluation opens no file. A whole build that finds a cache
  file fresh has the text that the cache file read, as Julia has for each read
  file that no `include_dependency` names; the print is that text's, so the
  next build finds the changed file. A package with `__precompile__(false)` has
  no cache file, so its reads are unknown.

## The replay

The ledger compares the text of an item. An evaluation has a result that the
text does not show, when Julia runs code for it: the expansion of a macro, the
value of an initializer, the body that a generator answers, the methods and
the names of an `eval` statement. A function that this code runs can change
while the text of the item stays. The replay (`replay.jl`) does the evaluation
again before the apply and compares the two results.

- A **candidate** is an item with a result that tracked code can change
  (`rc_candidates`): a user of a tracked macro, an initializer that runs code
  and names a tracked name, a `@generated` method (or a method that the
  program holds a generator for, as one that a macro defines), and a
  statement that defines through `@eval` or `eval`. The macros and the names
  are tracked by name alone, with no module: a candidate that needs no
  evaluation costs its print, and never a wrong result.
- The **print** of a result is a number that two results of the same structure
  share (`rc_print`). It reads the fields of a value, and calls no method of the
  program. A type counts by its identity, so a value of a struct that changed
  differs from each old value.
- The **trial** (`rc_trial!`) takes the print of each candidate, applies the
  changes of the edit, and takes the print of each candidate again at its place
  in the load order. A candidate whose print differs is evaluated at once, as
  a change, so the candidates after it see its new result. A whole build gives
  an item the code that it loads before the item, and the trial gives it the
  same.
- The trial runs in a **fork** of the process (`rc_in_fork`, `jl_reactive_fork`).
  It writes the items that differ, and the process applies the edit with those
  items among its changes (`rc_replay!`). Nothing that the trial evaluates stays
  in the process: no second effect of an initializer, no type of a closure, no
  compiled code. The trial and each print start with an empty storage of the
  task (`rc_with_empty_task_storage`), so a value of a type of before the edit
  never meets the code of after it; and with an empty registry of log ids
  (`rc_with_fresh_log_ids`), so a log statement has the id that a whole build
  gives it.
- The difference has a letter (`rc_candidate_difference`, `rc_replay_change`):
  `e`, the expansion gives other code; `v`, the initializer gives another
  value, and the item is a change of a constant (`C1`) or of a global (`C2`);
  `s`, the statement defines a method of other code, or binds or exports
  another name; `g`, a generator runs in the world of its method, so a method
  that a change made is new to it; `l`, the expansion of a moved item holds the
  place of the item (`rc_moved_difference`), as a log macro puts its line into
  its expansion. A result that differs between two evaluations in the same
  world (a counter, a clock, a random number) is no result of the edit: the
  item stays as it is, with a line in the log.

The replay runs in a process that holds the whole program, and a whole build
evaluates an item in a process that holds the items before it. Two checks
refuse what the apply cannot give the state of its place:

- the items that the apply evaluates again with the text of before are
  evaluated in a second fork, in the state of before the changes
  (`rc_again_check!`), and the methods that each one defines must be the methods
  that the program holds for it. An item that fails reads something that the
  apply cannot give it again: a definition that comes after it, a counter, the
  time. The text of before of an item whose text the edit changes has the same
  check;
- the text of now of such an item, and the text of a new item, have a check of
  their own (`rc_order_check!`). The fork takes the result of the item in the
  whole program, then takes out of the program each method that an item after
  it in the load order defined (`jl_reactive_methods_disable`), and each name
  that a later `const`, `global` or type gives its module
  (`jl_reactive_bindings_hide`), and takes the result again. A whole build gives
  the item the second program, so an item whose two results differ is a
  refusal. The check takes no value out that a later statement wrote: a read of
  such a value is not found.

A trial that stops (an error, a refusal) leaves the process as it was. The
apply then stops with the reason, and the log of the replay is the file
`<refusal file>.replay.log`.

## An apply is all or nothing

The process that writes an image next must hold the edit whole or not at all.
The replay evaluates the edit in a fork before the process writes anything: a
trial that stops leaves the process as it was before the request. The moves of
lines and the evaluations begin after the trial ended. A flag, `RC_APPLY_OPEN`,
says that the process holds an apply that no save wrote. A server that holds
one answers a new `apply` with an error; a server whose request fails while it
holds one exits,
and the next build starts a new server from the last snapshot of the store. The
client marks the session of the server with the snapshot that it is making
(`pending`) from the apply until the store names the snapshot; a build that
ends in between, by an error of the link or by a signal, leaves the mark, and
the next build starts a new server too. A refused apply leaves the server as it
was.

## The child harness — the rules to remember

These rules came out of the gates, each after a measured failure.

1. **The harness is part of the image, and a rebuild runs the harness of
   the installed Julia.** The code of the harness is compiled into the image
   (the `precompile` calls of `ReactiveCompiler.jl`), so a rebuild keeps the
   compiled functions and the delta holds the cone alone. The store records
   the print of the harness of its image (`HARNESS_PRINT`: a hash of the `.jl`
   files of the harness with their names). When the installed Julia has
   sources with another print, the rebuild loads these sources into a module
   of its own (`ReactiveHarness`) and runs that module: the child script, the
   server (a program in place of the entry `--reactive-server`) and the
   refresh. `JULIA_REACTIVE_HARNESS` names another folder of sources. The
   harness deletes the methods of that module before the image is written
   (`rc_remove_harness!`), so the image holds no method of it, and a change of
   the harness reaches a store with its next rebuild. A server runs the
   harness that it loaded at its start, so a change of the sources starts a
   new server.
2. **Warm with content, not with empty inputs.** The machinery must run on
   a synthetic non-empty diff in every build, with the same argument types
   as the real calls, and print the same report shapes. An empty-input
   warm-up does not compile the non-empty arms, and the first real edit
   then carries the machinery in its delta. This lesson appeared three
   times (the key harness of M0, the diff of M4, the resolver of M5).
3. **A workload must only call package functions.** A workload script that
   defines closures at its top level traces their thunks as roots that no
   later process can precompile. A workload of plain calls converges to an
   empty delta.
4. **The rebuild child imports nothing into `Main`.** The previous image
   already carries the Main bindings of its own build. The child resolves
   the root module of a tracked file through `Base.loaded_modules`.
5. **The first rebuild of a store absorbs the run-time residue of the full
   build** (the code its child JIT-compiled and dropped). Expect one large
   delta (about 180 roots), then convergence.
6. **The workload is one argument, and the trace is its product.**
   `materialize_app`'s `workload` is traced at the founding and by
   `refresh_trace`; `precompile_execution_file` is refused, and the
   statements of `precompile_statements_file` join the trace. A store
   whose trace misses a root compiles that root at run time, in every run,
   until a refresh.
7. **Do not hold an opaque closure in a top-level `const` of a package.**
   Stock Julia (1.13.0-rc3 too) faults at the call in a fresh process.
   Make the closure in a function. This is a fault of Julia, not of the
   patch.
8. **No build executes the program.** A build that ran the workload in the
   process whose heap becomes the image would start the rebuilt binary at the
   mutated value of each global that the workload changed, and each rebuild
   would add to it. The rebuild child precompiles the trace instead. The M6
   gate fails on a `state` other than 0.

## The command line

`julia -m PackageCompiler <verb> <app_dir> [options]` (Stage H,
`src/reactive_cli.jl` of the branch): `build` founds the store when the app
directory holds none — `--package=<dir>` names the package, its tracked
sources are the includes of its root file (`tracked_sources`), `--workload`
the script the founding traces — and rebuilds otherwise; `status` prints
the store; `stop` stops its server; `watch` builds once and rebuilds on
every change of a tracked file until Ctrl-C. The options are the keywords
of `materialize_app`. `create_app` takes `reactive = :auto`: a store under
the app directory makes a build a rebuild. The options `--no-server`,
`--image=<mode>` (the default is `overlay`), `--delta-opt=<n>`, `--found`,
`--compact=<n>,<f>` and `--trim` set the keywords of a rebuild; `status`
prints how often each kind of build occurs (see "The record of the builds").
The builder of projectured-julia calls the same functions.

## The entry points

**`PackageCompiler.materialize_app(package_dir, app_dir; tracked,
workload, ...)`** — the application workflow. The first call runs
`create_app` and makes the store inside the bundle (`reactive-store/`);
every later call rebuilds the delta and replaces exactly one file,
`lib/julia/sys.<ext>`, with the overlay and its chain beside it in the overlay
form. The executable, the libraries and the artifacts stand. The diff to
stock PackageCompiler is two keywords — `keep_object_archive` (copy the object
archive before the build deletes it) and `extra_object_files` (linked in front
of the delta, never deleted) — plus the files `src/reactive.jl` and
`src/reactive_cli.jl`; the reuse, the way of the write and the delta's level are
flags of the child's command line. The whole build traces the workload before
`create_app` and keeps the trace in the store; the rebuild runs no trace
process, because a trace against the old image would trace the old code;
`refresh_trace(app_dir)` traces from the current image on request. A rebuild
checks the inputs of the store, ends early when nothing changed, and moves the
base forward when the overlay passes its bound (see the sections of those
names). `track_dependencies = true` adds the sources of every path package of
the Manifest to the tracked files, on the whole build and on each rebuild.

**`ProjecturedBuilder.build_executable(; reactive = :auto, ...)`** — the
builder workflow, in `source/tool/builder/` of projectured-julia
(`Executable.jl` and `ReactiveBuild.jl`); `bin/build_projectured` and
`bin/build_omnet_ide` call it. A build makes a store when the output holds none
and the Julia is the reactive one, and rebuilds whenever the output holds one.
The builder computes the tracked list itself: `tracked_sources(package)` walks
the root file of each package for every literal `include` at the top level of a
module (and for a path that the walk computes without running the package:
`@__DIR__`, `joinpath` of strings, a `const` of the module that holds such a
path), follows the included files, and names the dotted module of each. The
root file comes first, with the empty module path: its top level is the
`module` block itself, so an `include` or a `using` that joins the module body
is a change of a tracked file that the rebuild applies or refuses. An
`include` of another path is not tracked; the walk names it, and the build
records the source as an input of the store, so a change of it stops the
rebuild. The workload of the trace is `trace_workload.jl`, which the builder
writes: a `using` of every package, and the call `run_package_workload()` of each
package that compiles ahead. The whole build traces that file, and
`--refresh-trace` traces it again from the current binary; no build executes
it. A rebuild goes through the compiler server, writes an overlay beside the
image (`image = :overlay`; the program holds the image of the whole build and
applies the overlay at its start), and compiles the edit at the `-O` level of
the build or a lower one (`delta_optimization`). `--found` makes the whole
build again. `reactive` refuses `trim`, `incremental = false`,
`--distribution` and the performance counters. The `[sources]` of
`environment/build/Project.toml` name the PackageCompiler that a build loads.

**`Materialize.materialize(store)`** — the image workflow of the first store
(`src/Materialize.jl`, with `tool/m4_child.jl`). The store is self-contained
(`store.toml` names the Julia, the project, the packages, the tracked files, the
workload); the product is an image plus a runner. The README lists it among the
instruments of the measurements that `plan/done/` reports.

## The compiler server

A store can keep a compiler process: the server of the stdlib
`ReactiveCompiler` (Stage D of the plan, a runtime entry since Stage H),
which `julia --reactive-server=<socket>` runs on the image of the last
snapshot in the output mode of the rebuild child (`--output-o` for its
whole life, `JULIA_REACTIVE_REUSE=1`). `materialize_app(...; server = true)`,
or `JULIA_REACTIVE_SERVER=1`, starts it that way, detached, its log in the
store, and records the session (the socket, the base snapshot, the pid) in
`server.toml`; a later call reuses the server that answers. A call that
starts a new server first sends `quit` to any process that answers on the
socket path, and removes the path, so it talks only to the server that it
starts. A founding stops the server of the store that it replaces. The log
takes stdout and stderr through one open file, so their lines keep their
order. `tool/gate_server.sh` tests these three rules. Any build tool
can start and drive it the same way (`tool/gate_h.sh` does, with the
Python client alone). The socket is a Unix socket in the
temp directory (a socket path holds 107 bytes); both sides use raw
`socket`, `connect`, `read` and `write` calls, one request per connection,
one line each way, no libuv.

The client restarts the server before an apply when the server has made 200
saves (`JULIA_REACTIVE_SERVER_SAVES`) or holds 16 GB of resident memory
(`JULIA_REACTIVE_SERVER_RSS_KB`), because the code of every save and every old
method version stays in its memory. It restarts it too when the last snapshot
of the server is not the last of the store, when the server was started for
another image form, another level of the delta or another harness, and when the
session holds a pending snapshot. A store whose image holds another harness
than the installed Julia has gets a server that loads the sources of that
harness (a program `serve.jl` in the store, in place of the entry
`--reactive-server`).

- `apply <spec.toml>` runs `rc_apply_tracked` and the trace on the
  arguments of the spec, the same the child script embeds. The trial of the
  apply runs in a fork, so a refused or failed apply leaves the server as it
  was (see "An apply is all or nothing"). The ledger of the tracked sources
  stays from one apply to the next (`keep_ledger`), and the first apply of a
  server takes it from the store's copies, as the child does; the parsed
  signatures of the trace are cached, and a statement that did not resolve
  stays failed for the session until a constant gets another value or a name
  leaves a module.
- `save <archive>` forks through `jl_reactive_fork` (cgmemmgr.cpp): the
  child opens its own `/proc/self/mem` (the JIT writes code through that
  descriptor, and after a fork it names the parent's memory), runs the
  tail of the object script, points the output at the archive
  (`jl_reactive_set_output`) and writes it with the exit path of the
  compiler, then `_exit`s; an error in the child ends it with 1. The parent
  keeps its heap, its ledger and its compiled code.
- `trim <archive> [dir]` forks the same way with `jl_options.trim` set for
  that write only (`jl_reactive_set_trim`): the fork includes the two
  `juliac` patch files from `dir`, registers the trim entry points
  (`trim_entrypoints!`), writes the trimmed archive, and sends the
  verifier's messages to `<archive>.log`. A verifier error is a refusal.
- `status` answers the world, the saves and the resident size; `quit`
  clears the output and exits. `tool/server_request.py` sends a request.

The reuse test of a save sees the image the server loaded as image code:
the code instances of a delta exist in the parent, but the slot values of
the emitted text are objects that codegen made in the child, so the next
save cannot reuse the text. A delta holds every change since the server
started, one image per save links the founding's texts, the deltas of the
base chain and the new delta, and a snapshot records its base; a chain
entry's base is the snapshot before it. The front of a save reuses the
image's code by a direct list (Compiler/src/precompile.jl): the walk of
the methods costs milliseconds, and the compile pass sees the new code
only. What a save cannot avoid is the heap of the image: 3 million
objects in 3.2 s on the routing sample.

## The numbers (build lane, 8 image threads)

| workflow | full build | steady rebuild | check |
| --- | --- | --- | --- |
| routing example image (M4) | 118 s, 8.0 GB | 20-21 s, 1.1 GB | delta = the cone exactly; hops 3.05 → 6.09; same network hash |
| routing sample binary (M5) | 155 s, 9.7 GB | 12-13 s, 1.3 GB | `hopCount` mean 2.308011 → 4.616022, exactly double, and back |
| HazardApp binary (M6) | 61-67 s, 6.0 GB (127-134 s on a loaded lane) | 8-9 s, 0.77 GB (24-26 s loaded) | 14 of 14 call shapes give the new value, and the old one after the reverse edit; `state` 0 in every run; 178 direct calls, 0 trampolines |
| routing binary through the builder (M7) | 3 min 3-12 s, 9.4 GB (fresh depot: the base image cache first; 6 min 22 s loaded) | 18-19 s, 1.3 GB (the child 8-10 s) | the same `hopCount` check as M5, by `bin/build_omnet_legacy_sample routing --reactive` twice; 347 direct calls, 0 trampolines; every run 61-63 s, with or without `--refresh-trace` |

The apply itself costs 1-3 ms; the rebuild child is the trace plus about
5 s of front, heap and link: the precompile of the 3203 statements of the
routing trace costs 1.4 s, and 0.7 s after a refresh dropped the 914
Unitful statements that `--trace-compile` prints unparsable. The builder
adds about 9 s: the Julia start, `Pkg.instantiate`, the load of
`OmnetBuilder`, and the walk of the tracked sources.

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
  reactive format holds no clone tables, so `create_sysimage(reactive_image
  = true)` refuses a `cpu_target` with more than one target, and a
  non-Linux host (`--gc-sections`).
- **The image format is version 3.** A stock build writes version 2, and
  a rebuild from a version 2 image is refused. The residue of a chain is the global
  slots of the dead functions: a slot is never freed, and the edit of
  Gate C leaves 45 slots per rebuild. Gate C bounds the growth of a chain
  by 32 bytes per slot and 512 bytes per rebuild (the objects that a
  process holds at exit: an IO buffer, a symbol).
- **A store pins its paths.** A snapshot records the absolute paths of
  the tracked files and of the project; a checkout that moves needs a
  founding build. The tools derive the checkout from their own location.
- **The trimmed product** (`trim = :on`, Stage E). A save writes a second,
  trimmed archive from a fork with `jl_options.trim` set. The verifier
  takes a reused code instance with inferred IR as a compiled callee and
  walks the `:invoke` targets of that IR; a reused code instance without IR
  is recompiled fresh. The trimmed image links the base chain and the
  trimmed archive, never the untrimmed delta, into `<app_dir>/trimmed`; its
  launcher (`trimmed_wrapper.c`) calls the exported `julia_main` directly,
  because a trimmed image has no evaluator. An edit that makes a static
  call site dynamic is refused with the verifier's reason (T1). The routing
  sample is not trim-clean with the stock verifier; Gate E runs on
  `tool/trim_app/TrimApp` instead. A no-server delta build after a chain
  carries the residue of the untrimmed chain deltas it links, which a
  founding resets. Under overlays the trimmed write is whole all the same
  (`jl_options.trim` turns the page and overlay modes off for the writer
  and the emitter) and reuses the founding image's functions alone: the
  texts of an overlay were compiled against the overlay's own slot table
  and cannot join a whole link, so the chain loader records the origin
  of every id of the composed table, `jl_reactive_image_ids` answers 0
  under trim for a function of an overlay, the compile pass serves it
  from its IR, and the link takes the founding's texts. The overlay of a
  save joins the chain only after the trimmed product is written. The pass
  keeps a memo (`<store>/trim-memo.txt`, `JULIA_REACTIVE_TRIM_MEMO`): the
  served code instances of the last accepted pass and their callees, by
  name; the next pass serves such a code instance without its IR (which
  the image mostly does not keep) and without a compile, enqueues its
  callees from the memo, and verifies only what the memo does not hold.
  The verifier's answer stands because the code of an image is immutable
  and an edit that changed a callee invalidated the caller. A refused
  pass writes nothing. The app's entry point must be `@ccallable`: the
  trimmer walks from the C-callable entry points, and a trimmed image
  without one is refused after the link.
- **A save writes the image by pages** (`image = :pages`, Stage F). The
  loader protects the sysimg section, the fault handler marks the pages
  the process writes, and the save copies the clean pages from the file
  of the base, rewrites the objects of the dirty pages in place, appends
  the new objects and merges the relocation lists. The const data and
  the symbols come from memory and the base (the loader never relocates
  them); the pointer elements of the base's bits memories are nulled in
  the copy. A page restored to its load state (a lock taken and
  released) counts clean by its hash. The object of the image's data is
  written as an ELF relocatable directly, and the image links with lld.
  On the routing sample a rebuild is 3.1 to 3.3 s (whole: 7.0 to 7.6);
  the heap write 0.7 s (whole: 3.4). What stays: the delta's codegen
  and archive (1.0 s), the front (0.7 s), and the first save of a chain
  appends 5 MB of rebuilt roots and caches.
- **A save writes an overlay** (`image = :overlay`, Stage G). The delta is
  a shared object of its own: the page patches of the sysimg and the
  const data, the new objects, the new symbols, the full merged lists,
  its own slot record, the fresh table with a reuse map for the
  functions of the chain, and the delta's code, which calls a reused
  function through the external-function slots of its image. The base
  loads into a region that keeps the blob's layout (a package image
  names a sysimage object by offset), with headroom for the const data
  and then the objects of the overlays; the chain file beside the image
  names the overlays, and the loader applies them in order and composes
  the function table. The whole image is never linked. The patches are
  the words of the rewritten objects that differ from their baseline, so
  the invalidation of a cone costs a word per code instance, not a page.
  A routing rebuild is 2.1 to 2.2 s with the delta's code at
  optimization level 1 (`JULIA_REACTIVE_DELTA_OPT`), 2.4 to 2.6 s at
  level 3: the compile of the edit's cone and its emission, not the
  image; a leaf edit rebuilds in about 1 s. The server's overlay is
  cumulative and replaces its previous one; a child's appends; a
  founding starts a chain.
- **The ledger sees the tracked sources alone.** A value of an old type
  inside an untyped container of a `const` is not found (the oracle's
  output check sees it); an untracked expander of a tracked macro is
  invisible, because an expansion leaves no trace in the expander's
  method; a macro that builds a `macrocall` at expansion time is not a
  head of the ledger.
- **A reformat leaves the quoted line numbers.** A `LineNumberNode`
  inside a quoted literal (the body of a macro, the answer of a
  generator) keeps the line of the last evaluation, unless the replay finds
  that the expansion of a moved item holds its place; the oracle strips
  quoted lines and drops the gensym counters (`var"##3#4"`), which a chain
  and a whole build count differently.
- **A replaced method must be deleted, not shadowed.** Julia does not
  close the world of a replaced typemap entry: both entries stay valid,
  and dispatch takes the newest one (`gf.c`, `get_intersect_visitor`).
  The apply deletes an old method of a changed expression at its
  replacement, and the others at the end of the apply, which closes their
  entries; the serializer drops a closed entry with its code instances. A
  method that stays shadowed (one that the apply did not delete) is still
  serialized, and the oracle counts it as `shadowed`.
- **The delta list names a method instance twice** when the main queue
  and the `invokelatest_queue` of `typeinf_ext_toplevel` both inspect it;
  the emission dedups by code instance, so the image holds one text
  function of it.
- **A root that the trace misses is compiled at run time** until
  `refresh_trace` runs. The rebuild infers what the trace names and what
  inference reaches from it; a specialization that an edit introduced
  behind a dynamic call is not in the old trace.
- **Three call shapes keep the trampoline**: a `jl_fptr_sparam` callee, an
  opaque-closure callee, and a caller that is an opaque closure. Each costs
  about 40 ns per non-inlined call from the delta.
- **No cross-process store without an image.** The recorded-read (cell
  model) store of the design is not built; it is what removes the need for
  a previous image and for the build-id cascade of package images.
- **No cross-process store without an image.** The recorded-read (cell
  model) store of the design is not built; it is what removes the need for
  a previous image and for the build-id cascade of package images.
- **A refused change needs a whole build**: a module option, a `using`
  of a package outside the image, a conflicting import, an `include` of an
  untracked file, a changed module header or root-file expression, a type
  that an untracked method names, a changed signature of a `@ccallable`
  function, a statement that names no tracked global, a definition that now
  comes after an item that names it, and an expression whose evaluation
  reads what comes after its place. An input of the store that changed (the
  build of Julia, the Manifest, the preferences, the workload, a source that
  the build does not track) stops the build too, and a rebuild across a new
  Julia is a whole build. Remove `reactive-store/` under the output, pass
  `--found`, or build into another output.
- **The replay does not find every difference.** An initializer that gives
  another value at each evaluation (a counter, a clock, a random number) stays
  as it is, with a line in the log. The check of the load order takes no value
  out that a later statement wrote, so an edited text that reads such a value
  is not found. The reads of a rebuild have the holes that "The reads" names.
- **One overlay, not a chain of overlays.** An overlay holds each change since
  the base, and a save compiles each of them again; the rebase bounds that cost.
  A save does not reuse the machine code of the save before it.
- **A build with no change ends inside Julia.** The early end comes after the
  start of Julia and the check of the inputs, about 5 s of the client side of a
  rebuild on the platform of projectured-julia. A check of the times of the
  tracked files in the build scripts before they start Julia is not built.
- **A rebuild that loads the sources of the harness leaves some of its code in
  the image.** The harness deletes its methods, but Base compiled code for the
  types of the loaded module: 465 functions and about 2 MB in gate C, which a
  chain of whole images adds at each rebuild.
