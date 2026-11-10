# A rebuild equals a whole build

`bin/build_projectured` and `bin/build_omnet_ide` build a program in two ways.
The first build compiles the whole program. The code calls it a *founding*;
this plan calls it a **whole build**. Each later build is a **rebuild**: it
compiles the edit and writes an *overlay*, a file with the changes since the
whole build, which the program applies at each start.

The owner asked on 2026-11-09 for a build that has four properties:

1. **Correct.** The rebuilt program is the program that a whole build of the
   same sources gives.
2. **Starts fast**, because its image is pre-relocated.
3. **Runs as fast** as the program of a whole build.
4. **Takes most changes.** A rebuild applies most kinds of edit, so a whole
   build is rare.

This plan reads the build against those four properties, lists what it found,
and gives the steps that close the gaps. It is not approved. No step is
started.

## The parts, in short

[doc/architecture.md](../../doc/architecture.md) has the full description.

- The **store** is the folder `reactive-store` under the output. It holds the
  machine code of the whole build, a copy of the tracked sources, and the
  *trace*.
- The **trace** is a list of `precompile(...)` statements. The whole build
  records it from one run of the workloads. A rebuild compiles each statement
  again after the edit. A call that no statement names is compiled by the
  program at run time.
- The **server** is a compiler process that stays between builds. It loads the
  image of the whole build and evaluates the changed top-level expressions.
- The **ledger** is the list of the top-level expressions of the tracked files
  (the *items*), each with its kind and its methods. The rules of the ledger
  decide which items a rebuild evaluates again.
- The **save** writes the overlay. On Linux the program holds the image of the
  whole build, already relocated (*prelinked*), and applies the one overlay in
  place.

The code is in three places: the fork of Julia (branch `merged`: `src/`,
`Compiler/src/`, `stdlib/ReactiveCompiler/`), PackageCompiler (branch
`reactive`: `src/reactive.jl`), and `ProjecturedBuilder`
(`source/tool/builder/ReactiveBuild.jl` of projectured-julia), which
`OmnetBuilder` calls.

## What the IDE store shows

The numbers are from `build/omnet_ide/reactive-store` of omnet-julia on
2026-11-09. The whole build ended at 15:24. The last rebuild ran at 21:49 with
a new server.

| what | value |
| --- | --- |
| the whole build | 1 h 01 min, peak 22.9 GB |
| changed items since the whole build | 622: 159 struct shapes, 152 changed signatures, 150 new methods, 74 method bodies, 41 `using` or `export` lines, 23 removed methods, 12 new files |
| the rebuild in the server | 92 s: the apply 53.7 s, the save 38.5 s |
| parts of the apply | ledger 9.6 s (all 1030 files), evaluation 7.7 s, trace 19.2 s, about 16 s in no printed part |
| the overlay | 251 MB: 199 MB of data, 16 MB of code |
| the bound that starts a whole build with no request | 25 % of the image of 1576 MB: 394 MB |
| the trace | 21 733 statements; 150 no longer name a method |
| removed or changed lines that the rebuild did not apply | 29: 17 `using`, 10 `export`, 2 struct types |

The start time is known only for a small overlay: 72 ms after a whole build
and 150 ms with the overlay of a one-line edit (the IDE, 2026-11-02). No
measurement exists for an overlay of 251 MB.

Four faults reached the IDE build on 2026-11-08 and 2026-11-09. All four are
fixed. No gate found one of them:

- a crash at the start of the program after a rebuild (a reference to array
  memory in an overlay on a prelinked image);
- a new module with an `import` stopped the rebuild;
- the rebuild evaluated the changes in the wrong order;
- a build sent its edit to an older server.

## Findings

Each finding has a number that the steps use. "Read" means that the code shows
it with no doubt. "Log" means that the log of the IDE store shows it. "Test"
means that it needs the test of Step 3 before a fix. "Audit" marks what one of
two code audits of 2026-11-09 found and I did not read again line by line.

### Correct

| # | what happens | example | where | state |
| --- | --- | --- | --- | --- |
| 33 | **An overlay loses writes into the constant data of the base image.** The constant data holds the number tables of the image: the root tables of the methods, and the key sets that find a binding or a specialization. It does not start at a page limit. For each of its pages the writer reads the "written" mark of the real page that holds the first byte, and 81 % of the bytes are in the next real page. | The overlay of the IDE of 2026-11-09 21:51. 74 methods of the base got new entries in their root table; 54 of them hold old bytes there. 302 bindings and 1 919 specializations are missing from their key sets. A wrong root table gives a crash in `lookup_root`, the place of the crash of 2026-11-08, when the program compiles that method. A missing key makes a second, empty binding or a second compile. | `staticdata.c:350`, `:462`, `:4241`, `:4308` | Read, and counted on the files of the IDE by the audit; I ran the count of the root tables again: 54 of 74 |
| 34 | The program does not apply its overlay when `JULIA_REACTIVE_IMAGE_WRITE=overlay` is in its environment. It prints one line and runs the code of the whole build. | a shell in which a gate ran | `staticdata.c:7719`, `:7273` | Read |
| 35 | No save checks the room that the program keeps for an overlay: 64 MB of constant data and 256 MB of objects. The rebuild succeeds, and each start of the program stops with "no room". The overlay of today uses 30 % and 21 %. | about 2 000 changed items, or one new table of 45 MB | `staticdata.c:4566`, `:7582` | Read |
| 36 | The program matches an overlay with its base by three sizes. It applies an overlay of another whole build of the same sizes with no message. | an old `sys.<n>.so` beside a new whole build | `staticdata.c:7570` | Read |
| 37 | Under overlays, a save that can not write an object back in its place stops the build, and each later build, until a whole build. | a `BigInt` of the base on a written page; a module with more `using` lines than its object has room for | `staticdata.c:2253`, `:2580`, `:5122` | Read (audit) |
| 39 | A whole build copies the tracked sources into its store at its end, after the hour of the build. An edit of a tracked file during the build is in the copy and not in the image, so no later rebuild applies it. | Another session lands a commit while the IDE founds. | `reactive.jl:232-251`: `create_app`, then `_reactive_copy_sources` | Read |
| 40 | **The image of a rebuild depends on the way to it.** One server that takes 28 commits one by one, and a new server that takes the same 28 commits at once, give two different images, and neither is the image of a whole build. | The kernel, 354c83ba6 to 0af15983d. The first image has 3 509 methods and lacks the two constructors of the new struct `RootedOperation`; the second has 3 470 and holds them; the whole build has 3 449. The commit 1df4c59c8 is refused after 28 commits in a server and applied after 3. | the replay gate of Step 2 | Seen on real commits |
| 41 | Methods that a macro made stay when their item is evaluated again. Such a method carries a line of the source of the macro, or `none:0`, so no item of the ledger owns it, and the new evaluation adds a copy. | 61 extra methods after 28 commits in one server, 22 in a new server: closures and keyword methods of `@document` and `@cell_struct` structs. | `rc_owns` and `rc_assign_methods!`, `child.jl:306-324` | Seen on real commits |
| 42 | A loop of a root file that exports names is not run again when the names change. | The root file of the kernel exports each name of `KernelModule` in a loop. After 28 commits the rebuilt program exports 717 names and the whole build 728, and two constants are missing from the package module. | R1; no case in `child.jl` | Seen on real commits |
| 1 | A name that leaves a `using` or `export` line stays. A removed struct, constant or global stays. The rebuild prints "not applied, the binding stays". | Move `foo` from module `A` to module `B`. `A` still exports its old `foo`. A module with `using A, B` sees two `foo`, and Julia can not choose. A whole build has one. | `child.jl:874` | Read, Log (29 times); the example needs Test |
| 2 | A constant keeps the value that the old code made. An edit of a function evaluates no initializer again. | `const BINDINGS = _make_open_page_bindings()`. Edit the function. The rebuilt program has the old bindings. In the sources, 129 constants take their value from a call in one line: 78 call `_color`, and 17 call another function or constructor of the tracked packages. | `child.jl:997-1032` has no case for a changed method | Read |
| 3 | A macro expansion keeps the old code of its helper function. Only a change of the `macro` item itself evaluates its users again. | `macro document(args...) _document_expr(args; ...) end`. An edit of `_document_expr` changes what 788 `@document` items expand to. The rebuild evaluates none of them. | `child.jl:899-916` | Read; seen on real commits in the replay gate (Step 2), and in the IDE store on 2026-11-10 |
| 4 | A changed top-level statement adds to the effect of the old one. | `register!(TABLE, a)` becomes `register!(TABLE, b)`. The table of the rebuild holds `a` and `b`. A whole build holds `b`. | `child.jl:649-659` (ids `X`, `D2`) | Read |
| 5 | A value of a struct type that changed stays inside a global, when a function made the value. | `const DEFAULT = make_default()` gives a `Theme`. `Theme` gets a field. `DEFAULT` holds an old `Theme`, and no method of the new type accepts it. | the limit that `doc/architecture.md` names | Read |
| 6 | A generated function keeps the old answer of its generator when a helper of the generator changes. The save also removes the old helper from the method table with no look at the world in which the generator runs, so a new specialization can stop with "method too new". | the same as 3, for `@generated` | no case in `child.jl`; `staticdata.c:1016` | Test |
| 7 | An apply that fails stays in the server. The server answers `error` or `refused` and serves the next request on a heap that holds half of the edit. | An edit adds a method and has a mistake in a later file. The build fails. The fix removes the method again. The method stays in the server, and in each later image. | `server.jl` `rc_serve`; `child.jl:972`, `child.jl:1001-1005` | Read |
| 8 | The store does not record its inputs outside the tracked files: the versions of the registry packages in the Manifest, the preferences, the Julia build, the build options, the text of the workload. A change of one is not applied and not refused. | `Pkg.update` moves a registry package. The rebuild keeps the old version in the image. | `reactive.jl:252-260` is all that the store records | Read |
| 9 | The files that a top-level item reads are a guess: each string literal that names a file. | The read list of the IDE store holds `/usr/bin/time` and `/proc/sys/kernel/perf_event_paranoid`. A file read through a computed path is not in it. | `SourceDiff.jl:429` | Read, Log |
| 29 | A `@ccallable` function whose signature changed keeps the C entry of the whole build. The build looks at the name only. | `foo(x::Cint)::Cint` becomes `foo(x::Cdouble)::Cdouble`. A C caller gets the old entry. | `codegen.cpp:7886` | Read |
| 30 | The fork of a save has no guard against the collector threads. The server starts with `--threads=1`, but `JULIA_NUM_GC_THREADS` of the shell still counts. | A server started from such a shell can hang in a save. | `reactive.jl:809`, `cgmemmgr.cpp:408` | Read (audit); Test |

The plan `robust-incremental-compiler.md` has the rule "apply or refuse,
never ignore". Findings 1 to 5 and 8 are the places where the rebuild ignores.

The audit of the writer and the loader also found parts that are right on the
overlay of the IDE. No reference to array memory is split between the base and
the overlay, so the fault of 2026-11-08 is closed. The lists of the overlay
and of the base name the same positions. The tables that a hash finds do not
depend on an address.

### Runs as fast

| # | what happens | example | where | state |
| --- | --- | --- | --- | --- |
| 10 | The harness keeps a cache from the text of each statement of the trace to the type that the text gave in the whole build. After an edit changes a struct, the cache still gives the old struct. The statement fails, or it compiles code for the old struct, and the new struct gets no compiled code. `--refresh-trace` does not heal it, because the new statement has the same text. | 150 statements failed today, 137 of them in the owner's packages. 63 are functions of the SDL backend: `_compute_dirty_change`, `_record_painted_element!`, `_take_wheel_run!`. They name `SdlBackend` and `SdlWindowResources`, which changed and have no type parameter, so the text of each statement is still right. The program compiles its paint path at each start. | `child.jl:1136-1159` | Read, Log |
| 11 | A statement whose text is no longer right stays lost. A struct with one type parameter for each field, as each `@document` struct has, changes its text with each new field. New code behind a dynamic call has no statement at all. Both wait for a person who runs `--refresh-trace`. The rebuild writes the count into the server log and nowhere else. | `collect_ini_file_entries(::LegacyProjectIniFiles{ReactiveCell{Any}, …})` after the struct got a field | `child.jl:1197`, `reactive.jl:285` | Log |
| 25 | An edited method starts with no compiled code. It gets code from the trace and from the callers that the rebuild compiles again. Code that the whole build compiled for the old method by another way is not compiled for the new one: a finalizer, a callback, a dynamic call from an unchanged caller. The old method still lists those specializations when the apply replaces it. | Edit the body of a function that only a `finalizer(f, x)` of an unchanged function names. | `child.jl:994`, `typeinfer.jl:1939` | Read (audit) |
| 26 | In the overlay form, new code calls an old function with boxed arguments through `jl_invoke`. A whole build makes a direct call. The same path cost 43 ns against 2.6 ns in the bench of gate M6. Most functions on mutable documents have boxed arguments. The count line of the build prints 0 for these calls. | An edited function calls an unchanged `handle!(document, event, context)` in a loop. | `codegen.cpp:5378` ("TODO: Add !specsig support"), `aotcompile.cpp:504` | Read; the cost in the owner's code needs a measurement |
| 27 | `precompile` does nothing for a code instance of the image that has no machine code. The statement counts as compiled, the program compiles the call at each run, and a refresh changes nothing. | A new dynamic call to a small function that the whole build always inlined. | `gf.c:4025` | Read (audit); Test |
| 28 | `JULIA_REACTIVE_DELTA_OPT` in the environment lowers the level of the rebuilt code, and no line of the output says it. | A variable that a gate run left makes each rebuild compile at `-O1`. | `Executable.jl:327`, `reactive.jl:111` | Read |

The code generation itself gives no slower code: the audit found the same LLVM
passes and the same level for the code of a rebuild as for a whole build, and
Julia runs no pass that needs caller and callee in one module.

### Starts fast

| # | what happens | where | state |
| --- | --- | --- | --- |
| 12 | A start with an overlay does work for the whole image, not for the overlay only: a checksum over the whole overlay (198 MB today), a pass over each of the 222 894 entries of the function table and over each of the 64 034 slots of the base, a walk of each function name. The overlay holds 70 MB of lists that this start never reads. | `staticdata.c:7577`, `:3220`, `:6657`; `processor.cpp:672` | Read (audit). Measured on the IDE on 2026-11-10 (`--build-info`, the middle of 9 starts): 70 ms and a peak of 282 MB with no overlay; 164 ms and 961 MB with the overlay of a save with no change; 280 ms and 1 168 MB with the overlay of 634 changed items |
| 13 | 81 % of the patches of an overlay change nothing: 1.33 of 1.64 million patches write the same reference to a constant object in another form. This is why a one-line edit patches 543 000 to 766 000 objects. Without them a start still copies 42 105 pages (164 MB) in place of 49 404. The real changes are 181 000 code instances that the edit made invalid, and 523 000 references to new objects, most of them new callers in the caller lists of base objects. | `staticdata.c:1676` | counted on the overlay of the IDE (audit) |
| 14 | The run scripts rebuild before each start. A build with no edit takes 10 to 17 s, and it does a save. | `_materialize_delta` has no early exit | Read |

### Takes most changes

The catalog of `robust-incremental-compiler.md` has 24 kinds of change. A
rebuild applies 18 of them in full and three in part (C3, C4, C5). It ignores
the removal side of C3 (finding 1). It refuses these:

| refused | what it is | cost today |
| --- | --- | --- |
| F1 | a module option: `@compiler_options`, `@optlevel`, `@max_methods` | a whole build |
| F3 | a `using` of a package that `Project.toml` does not name; a new version of a registry package (not seen at all, finding 8) | a whole build |
| C3 | an `import` of a name that the module binds from another place | a whole build |
| C4 | an `include` whose path the walk can not compute | a whole build |
| C5 | a changed module header, other than its docstring | a whole build |
| B2 | a struct that a method of an untracked file names | a whole build |

Two more causes start a whole build, and they are the common ones:

| # | what happens | state |
| --- | --- | --- |
| 15 | A change of the harness (`stdlib/ReactiveCompiler`) reaches a store only through a whole build, because the server runs the copy of the harness that its image holds. Three whole builds of the IDE on 2026-11-09 had this cause. Each fix of this plan is such a change. | Read |
| 16 | A whole build starts with no request when the overlay passes 25 % of the image. | Read |
| 17 | The store keeps no record of a refusal or of the cause of a whole build. So nobody knows how often each kind occurs. | Read |

### Rebuild time

| # | what happens | where | state |
| --- | --- | --- | --- |
| 18 | The overlay holds each change since the whole build, so each save compiles all of them again: 38.5 s at 622 items. The time grows until the next whole build. | the choice of 2026-10-31: one overlay from the image of the whole build | Log |
| 19 | A new server applies each change since the whole build: 53.7 s today. | the same | Log |
| 20 | The ledger reads each tracked file when one change has dependents by name: 9.6 s. A new server reads them all again. | `rc_needs_all_files` | Log |
| 21 | The apply compares each old method with each signature of the ledger. The cost grows with the square of the size of the edit. About 16 s of the apply of today are in no printed part. | `child.jl:1068-1076` | Read; the time needs a profile |
| 31 | After a struct changed, each rebuild infers and compiles the specializations on the old struct again, which nothing can call. The cache of finding 10 adds more of them. Today 159 struct shapes changed; the part of the 38.5 s is not measured. | `precompile.jl:430`, `typeinfer.jl:1860` | Read (audit) |
| 38 | Each save compiles 2 293 functions again that the image of the whole build does not hold as machine code, with no change of a source. A save with no change takes 6.2 s on the IDE: 1.3 s front, 1.4 s emission, 1.4 s heap, 1.6 s machine code. Its overlay patches 143 689 objects and holds 66 MB of lists. | the server log of the baseline of Step 2 | Log |
| 32 | A save has a floor that follows the size of the image and not the edit: three walks of each specialization, one LLVM module for each code instance that answers a constant, the names of the whole image in each overlay. A save of a one-line edit of the IDE takes 3.3 to 6 s. | `precompile.jl`, `aotcompile.cpp:999`, `aotcompile.cpp:1325` | Read (audit) |

### Tests

| # | what happens | state |
| --- | --- | --- |
| 22 | One gate builds the program in the form of the build scripts: `contrib/merged/gate_prelinked_chain.sh` links the image into a program, prelinks it, and starts it with the overlay of a rebuild. It compares the lines that the program prints and nothing else, and its edit is two method bodies, which grow no table of the base. So it found neither the fault of 2026-11-08 nor finding 33. It links with commands of its own, not through `ProjecturedBuilder`. The other gates start the image with `julia -J`, which is another load path; on the overlay of the IDE the two paths end with different code pointers for 6 441 code instances. *Corrected on 2026-11-10: the first text of this row said that no such gate exists. I looked in `contrib/reactive-compiler/tool` alone.* | Read; the count is the audit's |
| 23 | Each gate edits a small test program with edits written for the gate. No gate applies real commits. All four faults of the list above came from real commits. | Read |
| 24 | The `sizes` step of gate C fails on the branch: 100 568 bytes of growth against a bound of 35 136. | recorded 2026-11-09 |

## The model

Eight rules. Each one is a property that a whole build has and a rebuild must
keep.

- **R1. An item is evaluated again when something that its last evaluation
  used changed.** An evaluation uses the text of the item, the bindings that
  its names resolve to, the files that it reads, and the **code that it
  runs**. The ledger knows the first three. Code runs when Julia evaluates an
  initializer or a statement, when it expands a macro, and when it calls a
  generator. Findings 2, 3, 5 and 6 are one missing rule.
- **R2. A removal is a change, and the rebuild applies it.** Julia 1.13 has the
  parts: `Base.delete_binding`, the export flag of a binding partition, and a
  last world on each entry of the `using` list of a module.
- **R3. A statement that writes shared state is evaluated together with the
  other writers of that state.** The state of a global is made by its
  definition and by each statement that names it, in the load order.
- **R4. An apply is all or nothing.** After a failed build, the server holds
  what it held before.
- **R5. A build knows each of its inputs.** An input that changed, and that a
  rebuild can not apply, stops the build with its name.
- **R6. The roots follow the edit.** After a rebuild, the image holds compiled
  code for each call that the image of a whole build holds.
- **R7. The base moves forward with no whole build.** The cost of a rebuild
  and of a start follows the size of the last edits, not the time since the
  whole build.
- **R8. A test builds what the scripts build, from the commits that the
  repository has.**

## Decisions

These are my proposals. The owner approves them with the plan.

- **D1. A replay finds the items whose evaluation gives another result (R1).**
  *The owner approved this rule on 2026-11-10, in place of the reach by name.*
  A rebuild that changes something does again the part of an evaluation that
  has a result, and compares the result with the one of before the edit:

  - it expands each item that calls a tracked macro, and evaluates the item
    again when the expansion differs;
  - it evaluates each initializer that runs code and names a tracked name,
    and binds the constant or the global again when the value differs;
  - it evaluates each `@generated` method again, because the generator runs
    in the world of its method;
  - it evaluates each statement that defines through `eval`, and keeps the
    result when a method of other code comes out of it.

  ```julia
  const BINDINGS = _make_open_page_bindings()   # evaluated before and after the edit
  # the two values differ → `const BINDINGS` is evaluated again
  ```

  The replay goes through the items in the load order, together with the
  changes of the edit, so an item sees each change that a whole build loads
  before it. Two values are compared by their structure and never by a
  method of the program: a type counts by its identity, so a value of a
  struct that changed differs from each old value.

  The replay runs in a fork of the process, as the apply of D4 does. The fork
  does the evaluations and tells the process which items differ. So no
  evaluation of the replay stays in the image: no second effect of an
  initializer, no closure type, no compiled code.

  The replay is larger than the truth in one way, and smaller in two. An item
  that differs is evaluated again with no need when Julia then keeps what it
  had. An initializer that gives another value at each evaluation is left as
  it is, with a line in the log. A plain call statement is not run again
  when a function that its callee calls changes (D3 is the rule for the
  statements).

  *Rejected: the reach by name.* It was the first form of this decision: a
  graph from the syntax of the tracked files, in which an item reaches each
  name of the code that its evaluation can run. Step 7 has the measurement:
  on real commits it chooses about 2 700 items for each edit, because a type
  connects each function that prints or makes a value of it.

  *Rejected:* a record of the methods that each evaluation runs. It is exact,
  but the whole build loads the packages from their package images, so
  nothing recorded what their top level ran.
- **D2. A change that leaves a name behind is applied as a removal (R2).** The
  rebuild computes the names that left a `using` or an `export` line, and the
  removed types, constants and globals. It closes each one in the world of the
  apply. Two small functions join `src/module.c`: one clears the export flag
  with a new partition, one closes an entry of the `using` list. A changed
  module header then becomes a removal of the old module and a new module, so
  the refusal C5 goes too.
- **D3. A changed or removed statement evaluates its group again (R3).** The
  group is the definitions of the tracked globals that the statement names,
  and each statement that names one of them, closed over both. The apply
  evaluates the definitions first and the statements after, in the load
  order. A statement that names no tracked global and is not a `precompile`
  call writes state that the rebuild can not make again: the rebuild refuses
  it with a new id.
- **D4. The apply runs first in a fork of the server (R4).** The server has a
  safe fork for the save. The fork evaluates the edit and exits. An error or a
  refusal there leaves the server as it was. The server evaluates the edit
  only after the fork did. If the apply of the server fails all the same, the
  server exits, and the next build starts a new one.

  *Rejected:* one fork that does the whole of a build (apply, trace, save),
  with a server that never applies. It is simpler, but each build then applies
  and infers each change since the base again.
- **D5a. A whole build copies the tracked sources before it loads them
  (finding 39).** An edit that arrives later is then a change for the next
  rebuild.
- **D5. The store records a print of each input (R5):** the Julia build, the
  Manifest entry of each loaded package that is not tracked, the preferences
  of the loaded packages, the build options, the text of the workload and of
  the app files. A rebuild compares them. A difference stops the build with
  the name of the input and the option `--found`. It does not start a whole
  build by itself. The same rule holds at a start of the program: an overlay
  carries the checksum of its base, and the program stops on another base
  (finding 36). The way that the program loads its image depends on the
  program and on its chain file, and on no variable of the environment
  (finding 34).
- **D6. The base moves by a *rebase* (R7).** A rebase is one save of the
  server in the whole form: the heap as a new image, linked with the stored
  machine code and the code of the overlay, then the program linked and
  prelinked again. No inference and no code generation of the unchanged
  program runs. My estimate for the IDE is 1 to 2 minutes; Step 8 measures it
  first. After a rebase the overlay is empty, the start is the start of a
  whole build, and a rebuild is small again. A build rebases by itself when
  the overlay passes a bound that Step 2 measures. The bound of 25 % that
  starts a whole build goes. The bound is below the room that the program
  keeps for an overlay, and each save checks that room before it writes
  (finding 35). A save that can not write an object back in its place
  rebases too, in place of a stop (finding 37).

  This keeps the choice of the owner of 2026-10-31: each rebuild writes one
  overlay from the base image. It changes what happens when the overlay is
  large: a rebase of minutes in place of a whole build of an hour.

  A whole build stays for: a new Julia, a refused change, and a request
  (`--found`).
- **D7. The server runs the harness of the installed Julia (finding 15).**
  When the sources of the harness in the image differ from the installed
  ones, the server loads the installed sources into a module of its own and
  serves from it. The save deletes the methods of that module in its fork, as
  the warm-up of the harness does for its test module now, so the image and
  the overlay hold nothing of it. A fix of the harness then reaches a store
  with the next rebuild.

  *As built (Step 4):* the rebuild child loads the sources too, not only the
  server, because a build with no server has the same need. The overlay holds
  no method of the loaded module. It does hold the code that Base compiled for
  the types of the module in that build, about 390 small functions and 4 MB
  in the gate. They do not add up from build to build. The dead-type test of
  Step 10 can remove them.
- **D8. The program gate checks the image, and a new gate replays commits
  (R8).** The *program gate* is `contrib/merged/gate_prelinked_chain.sh`
  (finding 22). It gets an edit that writes into a table of the base, the
  check of `tool/overlay_check.py` after the rebuild, and a start of the
  prelinked program that decodes each method source inside the program. The
  *replay gate* is new. It makes a whole build at an old commit of a
  real package, rebuilds at each later commit, and compares the result with a
  whole build of the last commit through the oracle. It runs each chain two
  ways: one server through all commits, and a new server at the end. On
  2026-11-08 the owner declined a regression test for one fault; that test
  needed a gate of this kind. This decision asks again, because four faults
  in two days passed the gates that exist, and finding 33 is in the program
  of today.
- **D9. A build with no change does no work (finding 14).** The driver ends
  before the save when no tracked file and no input changed. The run scripts
  compare the times of the tracked files with a stamp of the store before
  they start Julia.
- **D10. One test says that a type is dead, and three places use it (R6;
  findings 10, 25, 31).** A type is dead when its name no longer gives it.

  ```julia
  # before the edit:  SdlModule.SdlBackend  → the struct of the whole build
  # after the edit:   SdlModule.SdlBackend  → a new struct; the old one is dead
  ```

  - The cache of the trace evaluates the text of a statement again when the
    type that it holds names a dead type.
  - When the apply replaces a method, it compiles the argument types of each
    compiled specialization of the old method for the new method, with each
    dead type replaced by the type that its name gives now.
  - The compile queue skips a specialization whose argument types name a dead
    type.

  A wrong guess here costs one compile that nothing uses. It can not give
  wrong code, because a statement of the trace is advice.
- **D11. In the overlay form, a call to an old function with boxed arguments
  goes through a slot (finding 26):** one load and one indirect call, as a
  call with a specialized signature does now. A rebase (D6) then makes each
  call of the overlay direct, because the whole form calls by name.
- **D12. A start does work for the overlay only (findings 12, 13).** The save
  computes the checksum and the header keeps it. An overlay for a program
  holds no full lists. The passes over the function table and over the slots
  take the entries of the overlay. A reference to a constant object has one
  form, so an unchanged one is no patch.

  *Rejected:* an overlay with final pages, as the base has (a prelinked
  overlay). The audit counted it for the overlay of today: 11 613 separate
  stretches of pages, or 333 MB when near stretches join. The address of the
  code of the overlay is not known at build time. And a rebase gives the same
  start for a large overlay.

## The open question

One decision is the owner's, because it sets what property 3 means and what a
rebuild costs.

D10 gets back, with no run of the program, each statement whose text is still
right and each specialization of an edited method. Finding 11 stays: a
`@document` struct that got a field, and new code behind a dynamic call. Only
a run of the program can find those.

**Q1. When does the image get the roots that only a run can find (R6, finding
11)?**

- (a) **The rebuild refreshes the trace by itself** when statements stayed
  lost: one run of the workload from the new image, then a second, small
  save. The rebuilt program is then as complete as that of a whole build. The
  cost is the time of the workload at each rebuild that adds a field to a
  struct that the trace names: about 2 minutes for the IDE.
- (b) **The rebuild says it and a person refreshes**, as now, but the build
  prints the lost statements and the command. This follows U5 of
  `compile-ahead.md` (a recording is made by hand, and before a release). The
  rebuilt program compiles the lost calls at each start until then.
- (c) **The program records what it compiles** at run time into the store,
  and the next rebuild adds it. No workload run. It is a new mechanism beside
  the recorded lists.

My recommendation is (a), with an option that turns it off. It is the only one
that gives property 3 with no action of a person, and it adds no mechanism.

## Steps

The work is in a worktree of `merged-next`, with worktrees of
PackageCompiler and projectured-julia beside it. Each step is a commit, with a
test that fails before the change.

On 2026-11-10, after Step 1, the owner said "Yes and continue": the push of
Step 1, and the work goes on with the next steps in their order. Q1 is still
open; Step 10 needs its answer.

On 2026-11-10, after the replay of Step 2 showed findings 40 to 42, the owner
approved another order: Step 4 first, then Step 7, then the other steps in
their order. Step 4 is first because each later fix of the harness then
reaches the stores with no whole build. Step 7 is next because the rule that
finds what an item runs closes the faults that the replay showed on real
commits. The numbers of the steps stay as they are.

- [x] **Step 1: the constant data of an overlay (finding 33).** *Done.* It is first,
  because each rebuilt program of today can hold the fault. The writer tests
  each real page that a page of the constant data touches. The check scripts
  of the audit are in `tool/audit-2026-11-09/` and become
  `tool/overlay_check.py`: it reads a base image and an overlay, and counts
  the root tables and the key sets that are wrong. Test:
  a server writes one byte of a base table at a chosen place, saves, and the
  check fails before the change. The change is in the writer alone, so the
  IDE needs a build of the library and one rebuild from a new server, and no
  whole build. The check on the new overlay of the IDE must count zero.

  *The owner approved this step alone on 2026-11-09. The work is in the
  worktree `julia-overlay-const-data`, branch `overlay-const-data`.*

  *The test, which fails first (2026-11-09).* `tool/gate_const.sh` builds the
  test program of gate I1 with a table of bytes in `DepLib`
  (`tool/const_table`). The edit of the gate adds a top-level statement that
  sets 64 bytes of the table, 8256 bytes apart. So each byte is on a page of
  its own with no write on the page before it, and the 64 bytes are at 64
  different places of a page. The rebuilt program must count 64. With the
  Julia of `merged-next` (91863c31f7) it counts 55. The constant data of that
  image starts 576 bytes into a page, and 9 of the 64 bytes are at a place
  below 576: the writer lost exactly those. `tool/overlay_check.py` counts 4
  specializations that are missing from their key sets in the overlay of
  that rebuild of one statement.

  *As built (2026-11-10, 4d56a98d60 the gate and the check tool, b17c03e72b
  the correction).* `reactive_range_dirty` in `src/staticdata.c` answers
  whether the process wrote a byte of a range. The copy of the written pages
  of the constant data and the list of its patched pages use it. A page of
  the sysimg starts at a page limit, so nothing changes for it. The format of
  an overlay and the loader stay as they are. The build of the worktree has
  no warning. *Measured with the corrected Julia:*

  - `gate_const.sh` passes: the rebuilt program counts 64, and
    `overlay_check.py` finds no wrong entry. The constant data of that image
    starts 3072 bytes into a page, so the old writer loses 48 of the 64
    bytes there.
  - Gate I1 with overlays and a server passes, with the four checks of the
    oracle equal, and `overlay_check.py` finds no wrong entry in its overlay.
  - A rebuild of the IDE store by hand, with each output in a scratch folder
    (a server on `founding.so`, the request of the rebuild of 2026-11-09
    21:49, the same 599 expressions and 23 removals): the overlay has no wrong
    entry, where the overlay of the store has 54 root tables, 1 919
    specializations and 302 bindings. The overlay is 2.4 MB larger.

  *Landed (2026-11-10, with the word of the owner).* `merged-next` moved
  forward to the branch (0afd58b859). The build of that checkout took 3 min
  29 s with a peak of 6.4 GB and no warning. `bin/build_omnet_ide` then
  rebuilt the IDE from a new server in 1 min 30 s with a peak of 7.2 GB: 634
  expressions and 23 removals, snapshot s8, and the program started.
  `overlay_check.py` on `lib/julia/sys.so` and the new `sys.8.so` finds no
  wrong entry: 73 root tables grew in place and none holds old bytes, and no
  specialization and no binding is missing. The check reads the image in its
  file form; it does not read the prelinked copy inside the program, and it
  says so. Not pushed: the push to `levy/julia` waits for the owner.
- [ ] **Step 2: the two gates and the baseline (D8).** The program gate on the
  test program of gate I1; it runs `tool/overlay_check.py` after each
  rebuild. The replay gate on the smallest real program whose whole build
  takes less than 5 minutes; the step picks it by measurement. The baseline
  on a copy of the IDE store: the rebuild time and the start time against the
  size of the overlay, at 1, 10, 100 and 600 changed items, and a profile of
  the apply and of the save (findings 21, 32). Gate C passes again or its
  bound changes with a reason (finding 24).

  *The program gate (2026-11-10, b17599c0f2).* `gate_prelinked_chain.sh` has
  the table edit, the `check` step and the `decode` step. With the writer of
  91863c31f7 it fails: the program counts 20 marks of 64, and 32
  specializations and 4 bindings are missing from their key sets. With the
  corrected writer it passes, and both programs decode 24 819 sources.

  *The replay gate (2026-11-10).* `tool/gate_replay.sh` clones a repository,
  writes a small program `ReplayApp` over one package of it, founds a store at
  an old commit, and rebuilds at each later commit through the server, as an
  overlay. The program has the form of the build scripts. After each rebuild
  the prelinked program and the launcher must print the same counts, and
  `overlay_check.py` must find no wrong entry. At the end the gate compares
  the chain with a whole build of the last commit through the oracle, decodes
  each source in the program, and then does the same again from a new server.
  A refused rebuild is counted, and the store founds again at that commit.
  The roots that the chain lacks are counted and not failed, until Step 10.

  *The first run: the kernel package of projectured-julia, five commits
  (140ae8853 to 00d0f77e0), 4 min 12 s, peak 8.7 GB.* No rebuild was refused
  and none failed. The chain is **not** equal to the whole build:

  - The program of the chain counts 728 exported names and 3 381 methods;
    that of the whole build 731 and 3 376.
  - 103 methods have another lowered code or another count. 69 of them are
    constructors of structs that `@cell_struct` or `@document` builds.
  - The cause of those, shown with one struct:

    ```julia
    @cell_struct struct EmptyReference <: Reference
        type::Any = nothing       # the macro gives the field the type `Cell`
    end
    # const Cell = ReactiveCell{Any}                       (ReactiveCell.jl:233)
    # the last commit changes the struct ReactiveCell
    # whole build:  fieldtypes(EmptyReference) == (Cell,)
    # chain:        fieldtypes(EmptyReference) == (the ReactiveCell{Any} of before the edit,)
    ```

    The text of the item names neither `ReactiveCell` nor `Cell`, so the
    rebuild does not evaluate it again. This is finding 3 with the type of
    finding 5, on a real commit.
  - The three missing names: the root file of the package exports each name
    of `KernelModule` in a loop. A commit adds an export, and the rebuild
    does not run the loop again (R1).
  - One server through the five commits and a new server at the end give
    the same image. 1 of 300 roots differs.

  *The same fault stops the rebuild of the IDE now (2026-11-10 08:53).* The
  commit that changes `ReactiveCell` is in the main checkout of
  projectured-julia since this morning. The apply of the IDE store stops
  with `MethodError: Cannot convert an object of type ReactiveCell{Any} to an
  object of type Cell`, in a top-level call of `FieldReferenceStep`
  (`ReferenceStep.jl:168`). Until D1 is built, only a whole build of the IDE
  gives a program again.

  *The baseline of the IDE store, as far as it goes.* The server listens 0.7 s
  after its start, with 1.3 GB. A save with no change: finding 38. The starts
  of the program: finding 12. The rebuild of 634 items at 08:10: the apply
  41.9 s, the save 35.0 s. The profile of the apply is not measured, because
  the apply fails now.

  *The oracle counted false differences, and the replay has a control now
  (2026-11-10).* The oracle hashed the names of the slots of a method with
  their counters, which differ between any two builds: about 216 false
  differences on the kernel. `oracle.jl` drops the counters of the slot names
  too. The step `control` of the replay gate founds the last commit a second
  time; a fact of the oracle that differs between the two whole builds is
  noise, and each comparison leaves it out. On the kernel the two whole builds
  agree in each fact.

  *The replay over 30 commits of the kernel (354c83ba6 to 00d0f77e0).* The
  whole build takes 1 min 45 s with a peak of 6.6 GB. 29 rebuilds apply 653
  expressions and 56 removals, each in 3 to 5 s. One rebuild is refused, at
  1df4c59c8 (`RangeReferenceStep` gets a field): "the untracked none:0
  RangeReferenceStep names the type (found in the apply)". The replay over
  five commits applied the same commit: finding 40.

  *The replay over the 28 commits before that one, with no refused rebuild
  and no error.* Against the whole build of the last commit (3 449 methods,
  728 exported names):

  | | one server, commit by commit | a new server, at once |
  | --- | --- | --- |
  | methods | 3 509 | 3 470 |
  | exported names | 717 | 717 |
  | methods that a macro left behind (finding 41) | 61 | 22 |
  | constructors of `RootedOperation` | missing | there |
  | methods of the moved function `search_documents` | in its old module | in its old module |
  | methods with the same count and other code | 13 | 13 |
  | constants missing from the package module | 2 | 2 |
  | roots of 300 that are not compiled | 19 | 19 |

  The 19 roots: 12 are inferred and not compiled, 7 have no method instance.
  The 13 methods with other code are not sorted yet; at least three differ
  only in a line number that the code holds.

  *Open in this step:* the 13 methods with other code; the replay over the
  platform package; the reason of the size of gate C; the profile of the
  apply.
- [ ] **Step 3: one test for each finding 1 to 9, 25 to 27 and 29, which fails
  first.** Each is a small edit of the test program, compared through the
  oracle or through the list of what the program compiles at run time. A
  finding whose test passes on the branch leaves the plan, with a note.
- [x] **Step 4: the server runs the installed harness (D7).** *Done, on the
  branches `rebuild-equals-step-4` of the Julia worktree and `live-harness` of
  PackageCompiler; not landed.* Test: a store
  that an older build of Julia founded applies an edit with a changed harness,
  and the overlay holds no function of the harness. This step is early so
  that each later fix reaches the stores of the owner with no whole build.

  *How it works.* The harness says the print of its sources
  (`ReactiveCompiler.HARNESS_PRINT`, one hash of its `.jl` files). A whole
  build records the print of the harness of its image as `harness` in
  `store.toml`. A rebuild compares it with the print of the sources that its
  Julia has. When the two differ, the rebuild loads the sources into a module
  of their own, `ReactiveHarness.ReactiveCompiler`:

  - the script of a rebuild child binds the module to `rc_harness`, calls it
    in place of the standard library, and ends with `rc_remove_harness!()`;
  - the server starts with a program, `serve.jl` in the store, in place of
    `--reactive-server`; the program opens the standard streams first, because
    the output mode runs no `__init__`;
  - `rc_save` calls `rc_remove_harness!()` in its fork, before the image is
    written. The function deletes each method of the loaded module and takes
    the module out of the list of the modules with documentation. The code
    that runs keeps its methods, because a deletion counts from the next
    world on.

  A store with no `harness` record, such as each store of before this step,
  loads the sources at each rebuild until its next whole build. A server
  starts again when the sources change. `JULIA_REACTIVE_HARNESS` names another
  folder of sources, for a test.

  *The gate* is `tool/gate_harness.sh`. It runs gate I1 four times with
  overlays: through a server and through a child, each with a copy of the
  sources that has another print, and each with the sources of the tree. It
  passed on the image of before the change, whose harness has no print and no
  `rc_remove_harness!`, and on the image of after it:

  | | server | child |
  | --- | --- | --- |
  | the chain against the whole build, four checks | equal | equal |
  | functions of the harness in the overlay | 0 | 0 |
  | wrong entries (`overlay_check.py`) | 0 | 0 |
  | the overlay, with the harness of the image | 15.0 MB | 14.6 MB |
  | the overlay, with loaded sources | 19.0 MB | 19.3 MB |
  | a rebuild, with the harness of the image | 3.0 s | 3.0 s |
  | a rebuild, with loaded sources | 4.9 s, then 2.7 s | 4.8 s each |

  The cost of loaded sources is about 2 s for each process that loads them,
  because the process compiles the harness, and about 4 MB in the overlay
  (see D7). The owner's IDE store has no `harness` record, so it loads the
  sources until its next whole build.
- [ ] **Step 5: an apply is all or nothing, and each input is known (D4, D5,
  D5a; findings 7, 8, 28 to 30, 34, 36, 39).** The server starts with one collector
  thread. A changed signature of a `@ccallable` function is refused. A build
  prints the level of its code when it is not the level of the whole build.
  Test: a failed edit, then its fix, give the image of a whole build; a
  changed Manifest entry stops the build with its name; the program applies
  its overlay with the variable of finding 34 set, and stops on an overlay of
  another base.
- [ ] **Step 6: removals (D2; finding 1, refusal C5).** Test: the moved
  function of finding 1; a removed struct; a renamed module.
- [ ] **Step 7: the code that an item runs (D1, D3; findings 2 to 6, 9, 20).**
  The replay of D1. The groups of the statements. The read rule skips
  `/proc`, `/sys` and `/dev`. Test: `tool/gate_runs.sh`, the tests of Step 3,
  and the count of items that the replay gate evaluates with no need.

  *In work. The first form of D1, the reach by name, was measured and does
  not hold. On 2026-11-10 the owner approved the replay in its place, and
  D1 now states it. The reach left the tree (`reach.jl`,
  `tool/reach_report.jl`); the commit 253973cd88 holds it.*

  *The test that fails first* is `tool/gate_runs.sh` with the program
  `tool/r1_runs`. One file holds six expressions, and the edit changes only
  the functions that they run, in another file. The rebuild of today leaves
  all six as they were:

  | expression | today | a whole build |
  | --- | --- | --- |
  | `const TABLE = make_table()` | 1 | 2 |
  | `const SCALED = scale(BOX[])`, a call on a value of an unknown type | 6 | 9 |
  | `answer_value() = @answer 10`, the macro expands through a function | 11 | 12 |
  | `const ANSWER = @answer 100` | 101 | 102 |
  | `const DEFAULT_THEME = make_theme()`, and the type gets a field | 1 field | 2 fields |
  | `@generated staged(x) = generated_body(x)` | 2 | 3 |

  *The reach by name, measured.* The harness had the graph of the first D1
  (`reach.jl`), and `tool/reach_report.jl` walked real commits with the
  tracked list of the IDE store and no build. Over 39 commits of
  projectured-julia, with 27 202 expressions in 1 030 files, each commit that
  changes code makes about 11 300 names "affected" and hits about 355
  constants, 32 globals, 429 statements, 595 methods and 1 269 types. The
  rule would evaluate about 2 700 expressions again for each edit. Three
  repairs were tried together: the scope rules of Julia, so that a local and
  a field are no name; a quote counts as data; a method of a Base function is
  filed under the types of its signature only. The count stays the same
  (8 800 names, 2 350 hits). The reason is in the code and not in the rule: a
  type is a hub. Each document type reaches `Base.show` of `Document`, which
  reaches the print functions, which reach each projection. So the reach by
  name can not choose the expressions; it can not be the test.

  *What the real code holds* (probes on the image of the IDE, read only):

  - The ledger of all 1 032 files parses in 0.97 s. Finding 20 gives 9.6 s
    for "the ledger reads each file"; the parse is not that time.
  - 29 tracked macros have 2 196 users. One pass of `macroexpand` over all of
    them takes 2.07 s. Two passes give the same expansions, after the
    generated names get numbers in their order.
  - 557 constants have an initializer with a call. 333 of them name a binding
    of a tracked module; these evaluate in 0.52 s (1.67 s the first time).
    Two evaluations give a value of the same structure for 515 of 560; the
    other 45 need care: a lock, a `gensym`, a closure, the free slots of a
    `Dict` of plain data.
  - The expansions hold 958 top-level calls, and each one is
    `Base.Docs.doc!`. About 80 expansions hold an initializer with a call
    (`@compile_ahead`, a `let`).
  - 443 statements: 420 are macro calls that define methods, 63 are loops
    (`@eval` definitions and exports), 8 are plain calls
    (`register_palette!(RADIX_PALETTE)`, four exports through `Core.eval`).
  - No tracked file has a `@generated` function.

  *The gate with the replay.* `tool/gate_runs.sh` passes through a child
  with whole images, and through a server with overlays
  (`JULIA_REACTIVE_SERVER=1`, `JULIA_REACTIVE_IMAGE_WRITE=overlay`): the
  rebuilt program prints the values of the whole build, and the chain equals
  the whole build in the four checks (22 methods, the roots, 12 lines of
  output, 9 globals). The program has five
  more expressions than the first form of the gate:

  | expression | before the edit | after it |
  | --- | --- | --- |
  | a loop that defines a method for each row of `loop_table()` | 1 method | 2 methods, other values |
  | a loop that exports each name of `exported_names()` | `TABLE` | `SCALED TABLE` |
  | `const HANDLERS = [x -> handle(x), x -> handle(x) + 1]` | stays; its functions call the new `handle` | |
  | `const STAMP = next_number(COUNTER)`, which counts its evaluations | 1 of 1 | stays 1 of 1 |
  | `const THEMES = Dict{Symbol, Theme}()` and the statement that fills it | 1 value with 1 field | 1 value with 2 fields |

  Gate I1 passes with the replay in the harness too, through a server and
  through a child (`gate_harness.sh standard`): the four checks are equal. With
  loaded sources its overlays have 23.5 MB and 22.5 MB, where Step 4 had
  19.0 MB and 19.3 MB: the code that Base compiles for the types of the
  loaded harness grew with the harness. Its rebuilds take 6.0 s and then
  3.2 s in a server, and 5.8 s in a child, where Step 4 had 4.9 s, 2.7 s and
  4.8 s.

  The rebuild says `11 candidates, 11 compared, 8 differ` and takes 0.17 s
  for the replay. `STAMP` shows that the fork keeps the evaluations of the
  replay out of the image: the counter of the rebuilt program is 1.

  *The replay gate with the replay* (`tool/gate_replay.sh`, the same 28
  commits of the kernel as in Step 2, no refused rebuild and no fault,
  8 min 42 s, peak 8.9 GB). Against the whole build of the last commit
  (3 449 methods, 728 exported names):

  | | one server, before | one server, now | a new server, before | a new server, now |
  | --- | --- | --- | --- | --- |
  | exported names | 717 | 728 | 717 | 728 |
  | constants missing from the package module | 2 | 0 | 2 | 0 |
  | methods | 3 509 | 3 524 | 3 470 | 3 471 |
  | methods that the whole build has not | | 102 | | 51 |
  | of those, with a generated name (finding 41) | 61 | 83 | 22 | 32 |
  | methods that only the whole build has | | 27 | | 29 |
  | roots of 300 that are not compiled | 19 | 19 | 19 | 19 |

  The exported names and the globals now equal the whole build: finding 42
  is closed. The new server names what the replay found: the two loops that
  export the names of the modules (`KernelModule.jl:15`,
  `ProjecturedKernel.jl:56`), of 54 candidates, in 1.1 s. The methods are
  still not equal, and the causes are those of Step 2: a method that a
  macro made stays when its item is evaluated again (finding 41; the count
  grew, because the replay evaluates more items again), the function
  `search_documents` stays in the module that it left (finding 1), the two
  constructors of `RootedOperation` are missing in the chain of one server
  (finding 40), and about 13 methods have other code. The log of the server
  of the 28 rebuilds was lost to the log of the new server; the gate keeps
  it from now on (`server-replay.log`).

  *The replay, as built* (`stdlib/ReactiveCompiler/src/replay.jl`).

  - **The candidates** come from the syntax of the ledger: an item that
    calls a tracked macro; a `const` or a `global` whose initializer holds a
    call and names a tracked name; a `@generated` method; a statement with
    `@eval` or `eval`. The IDE has 2 620 of them in 27 283 items: 2 196 macro
    users, 396 initializers, 64 statements and no generated method.
  - **The print** of a result is one number. For an expansion it is the
    print of the expanded code, with the lines of the item counted from its
    first line. For an initializer it is the print of its value. For a
    statement it is the print of the methods that it defines and of the
    names that its module binds and exports. A print reads fields, elements
    and the pairs of a `Dict`; it calls no method of the program. A type
    counts by the identity of its name; a type that the evaluation itself
    made, as a top-level `->` does, counts by the code of its methods; a
    generated name counts with no digits; a line number, a pointer, a task
    and a lock count as nothing more than their kind.
  - **The trial** first runs each statement once, and then takes the print
    of each candidate. A statement can do more in the whole program than it
    did when its package was loaded: a loop that exports the names of a
    module finds the names of the files after it. The trial then goes through the
    changes of the edit and the candidates together, in the load order. At
    the turn of a candidate it takes the print again. When the two differ, it
    takes a third one: a result that differs at each evaluation is no result
    of the edit, and the item stays, with a line in the log. Else the
    candidate is evaluated at once, as a change. A candidate before the
    first change in the load order has no print, because nothing can change
    its result.
  - **The fork.** The trial runs in a fork of the process
    (`jl_reactive_fork`, as the save does) and writes the items that differ
    to a pipe. The process then applies the edit with those items among its
    changes, and evaluates nothing else. What the fork prints goes to
    `<refusal file>.replay.log`. A fork that ends with no answer gives a
    warning, and the apply goes on with the changes of the edit alone.
  - **Each edit takes the ledger of every file** (`rc_has_change`), because a
    candidate can be in any file. An edit of comments and blank lines only
    still reads the changed files alone.
  - The rule that evaluates each user of a changed `macro` item stays as it
    was. The replay finds the other users.

  *Decided in the build, by the assistant.* The proposal said that the
  results of before the edit come from the last build of the same server.
  The replay runs in a fork in place of that, for three reasons that showed
  in the code. An initializer that is evaluated in the process leaves its
  effects in the image: a counter, an entry of a table. Each evaluation of a
  top-level `->` or of a comprehension makes a new type with a method, and
  code that Base compiles for it. And a print of before is good only for the
  state that it was taken in. The cost is that each fork takes both prints.

  *The cost on the IDE*, from two probes on its image that write no image
  (`replay/ide_probe.jl` and `ide_trial_probe.jl` of the session): the
  ledger of all files takes 1.0 s, the methods of its items 0.15 s, the
  candidates 0.27 s. One pass of the prints takes 3.5 s (2.9 s for the
  expansions), and 9 s the first time in a process, because the functions
  that the macros and the initializers call have no compiled code in the
  image. A whole trial in a fork takes 16.5 s for an edit at the start of
  the load order: 11.7 s for the statements and the prints of before, and
  4.8 s for the rest. Other jobs ran on the machine at that time. An edit
  late in the load order compares few candidates. This is more than the
  3 s of the proposal, because each fork compiles those functions again and
  takes both prints. Two ways to lower it belong to Step 8: a fork that
  takes the prints of before in the background after each build, and
  compiled code in the server for what the fork compiled.

  With a change that changes nothing, 0 of the 2 620 candidates of the IDE
  differ, so the replay evaluates no item with no need there. Before the
  trial ran each statement once ahead of the prints, one statement of the
  platform package differed in that probe: the loop after it exports one
  more name in the whole program than the image holds.

  *Finding 20, measured again* (`replay/ide_ledger_probe.jl` of the session,
  on the image of the IDE). The ledger of all 1 032 files takes 2.0 s in a
  new process: 1.1 s for the parse and the methods of the old items, 0.2 s
  for the files that the items read, 0.2 s for the diff, 0.15 s for the
  users of the macros, 0.2 s for the candidates. A later apply of the same
  server parses the changed files only. The 9.6 s of the log are not in
  these parts; the log line of the next rebuild of the IDE will show what
  is left. The read list of the IDE holds two files now, a source file and
  `/usr/bin/time`.

  *The read rule* skips a file under `/proc`, `/sys` or `/dev`
  (`ReactiveSourceDiff.read_paths`). A file that an item reads through a
  computed path is still not in the list (finding 9, the second half).
- [ ] **Step 8: the rebuild time (D6, D9; findings 14, 16, 18 to 21, 32, 35,
  37).** First the measurement of one rebase of the IDE store by hand. Then
  the request `rebase` of the server, the link, the program, the swap of the
  base in the store, the bound, and the check of the room. The build with no
  change ends early. The profile of Step 2 names the three largest parts of
  the floor of a save, and the step removes them. Test: the program gate with
  a rebase between two edits; the oracle after it; the start time equals that
  of a whole build; an edit that passes the room rebases and the program
  starts.
- [ ] **Step 9: the overlay form: the call and the start (D11, D12; findings
  12, 13, 26).** Test: the bench of gate M6 with a callee of boxed arguments,
  in the overlay form against a whole build; the start time of the program
  gate against the size of its overlay; the count of the patches of a
  one-line edit.
- [ ] **Step 10: the roots follow the edit (D10; findings 10, 11, 25, 27,
  31).** The dead-type test and its three uses. A statement whose code
  instance of the image has no machine code is compiled. Each rebuild prints
  the statements that stay lost and writes them into the record of the store.
  The replay gate counts what the program still compiles at run time against
  a whole build. Then the answer to Q1: with (a), the refresh and the second
  save.
- [ ] **Step 11: the record, the documents and the IDE.** The store keeps a
  line for each build: the kind, the changed items by id, the refusals, the
  times, the size of the overlay (finding 17). `doc/architecture.md` and the
  two build guides say what changed. Then a whole build of the IDE, the last
  one that this plan needs.

## Not in this plan

- The refusals F1 and C4, a new version of a registry package (F3), and a
  rebuild across a new Julia. The record of Step 11 says how often each one
  occurs.
- The time and the memory of a whole build itself.
- Package images through the store (Stage J), the session image for `jo`
  (Stage I3), and the trimmed product.
- A chain of more than one overlay, and a save that reuses the machine code
  of the save before it.
