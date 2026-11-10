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
| 1 | A name that leaves a `using` or `export` line stays. A removed struct, constant or global stays. The rebuild prints "not applied, the binding stays". | Move `foo` from module `A` to module `B`. `A` still exports its old `foo`. A module with `using A, B` sees two `foo`, and Julia can not choose. A whole build has one. | `child.jl:874` | Read, Log (29 times); the example needs Test |
| 2 | A constant keeps the value that the old code made. An edit of a function evaluates no initializer again. | `const BINDINGS = _make_open_page_bindings()`. Edit the function. The rebuilt program has the old bindings. In the sources, 129 constants take their value from a call in one line: 78 call `_color`, and 17 call another function or constructor of the tracked packages. | `child.jl:997-1032` has no case for a changed method | Read |
| 3 | A macro expansion keeps the old code of its helper function. Only a change of the `macro` item itself evaluates its users again. | `macro document(args...) _document_expr(args; ...) end`. An edit of `_document_expr` changes what 788 `@document` items expand to. The rebuild evaluates none of them. | `child.jl:899-916` | Read |
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
| 12 | A start with an overlay does work for the whole image, not for the overlay only: a checksum over the whole overlay (198 MB today), a pass over each of the 222 894 entries of the function table and over each of the 64 034 slots of the base, a walk of each function name. The overlay holds 70 MB of lists that this start never reads. | `staticdata.c:7577`, `:3220`, `:6657`; `processor.cpp:672` | Read (audit); 72 ms with no overlay, 150 ms after a one-line edit; no time for today's overlay |
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
| 32 | A save has a floor that follows the size of the image and not the edit: three walks of each specialization, one LLVM module for each code instance that answers a constant, the names of the whole image in each overlay. A save of a one-line edit of the IDE takes 3.3 to 6 s. | `precompile.jl`, `aotcompile.cpp:999`, `aotcompile.cpp:1325` | Read (audit) |

### Tests

| # | what happens | state |
| --- | --- | --- |
| 22 | No gate builds the program in the form of the build scripts: the image inside the program, prelinked, the overlay applied in place. The word `prelink` is in no gate script, and `test/prelink` has no overlay. The gates start the image with `julia -J`, which is another load path. On the overlay of the IDE the two paths end with different code pointers for 6 441 code instances. | Read; the count is the audit's |
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

- **D1. The reach by name gives the code that an item runs (R1).** The ledger
  builds a graph from the syntax of the tracked files: each method item points
  at the global names of its body. The *reach* of an item is each name that it
  can arrive at through that graph, from its initializer, from its statement,
  from the body of each macro that it expands, or from the body of its
  generator. When an apply changes a function, a type or a binding, each item
  whose reach holds that name is evaluated again.

  ```julia
  const BINDINGS = _make_open_page_bindings()   # reach: _make_open_page_bindings,
                                                # and each name of its body, and so on
  # an edit of a function in that reach → `const BINDINGS` is evaluated again
  ```

  The reach is larger than the truth, so some items are evaluated with no
  need. That costs little: Julia keeps a constant whose new value is equal
  (`jl_egal`, `src/module.c:583`), keeps a struct of the same shape, and the
  method filter keeps a method of the same code. A method that extends a
  function of an untracked module, such as `Base.show`, counts under the
  types of its signature too, because untracked code calls it.

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
- **D8. Two new gates (R8).** The *program gate* builds the small test program
  through `ProjecturedBuilder`, as the build scripts do, edits it, starts the
  prelinked program with its overlay, and decodes each method source inside
  the program. The *replay gate* makes a whole build at an old commit of a
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
- [ ] **Step 3: one test for each finding 1 to 9, 25 to 27 and 29, which fails
  first.** Each is a small edit of the test program, compared through the
  oracle or through the list of what the program compiles at run time. A
  finding whose test passes on the branch leaves the plan, with a note.
- [ ] **Step 4: the server runs the installed harness (D7).** Test: a store
  that an older build of Julia founded applies an edit with a changed harness,
  and the overlay holds no function of the harness. This step is early so
  that each later fix reaches the stores of the owner with no whole build.
- [ ] **Step 5: an apply is all or nothing, and each input is known (D4, D5;
  findings 7, 8, 28 to 30, 34, 36).** The server starts with one collector
  thread. A changed signature of a `@ccallable` function is refused. A build
  prints the level of its code when it is not the level of the whole build.
  Test: a failed edit, then its fix, give the image of a whole build; a
  changed Manifest entry stops the build with its name; the program applies
  its overlay with the variable of finding 34 set, and stops on an overlay of
  another base.
- [ ] **Step 6: removals (D2; finding 1, refusal C5).** Test: the moved
  function of finding 1; a removed struct; a renamed module.
- [ ] **Step 7: the code that an item runs (D1, D3; findings 2 to 6, 9, 20).**
  The reach graph, kept in the store by the hash of each file so that a new
  server does not parse 1030 files. The groups of the statements. The read
  rule skips `/proc`, `/sys` and `/dev`. Test: the tests of Step 3, and the
  count of items that the replay gate evaluates with no need.
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
