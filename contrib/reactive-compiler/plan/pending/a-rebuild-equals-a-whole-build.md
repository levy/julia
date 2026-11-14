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
| 42 | A loop of a root file that exports names is not run again when the names change. | The root file of the kernel exports each name of `KernelModule` in a loop. After 28 commits the rebuilt program exports 717 names and the whole build 728, and two constants are missing from the package module. | R1; no case in `child.jl` | Seen on real commits. Closed on the branch by Step 7: the replay gate gives 728 names |
| 43 | A line that a macro writes into the code as a number stays when the item moves. The rebuild gives a moved item its new lines in the line table, but it does not evaluate the item again. | `@warn "an evaluation observer failed"` in `_notify_evaluation`. A commit adds three lines above it. The log message of the rebuilt program names line 729, that of the whole build 732. Three methods of the kernel after 28 commits; the sources of projectured-julia hold 124 log macros in 55 files. | no case in `child.jl`; the replay takes a user of a tracked macro only | Seen on real commits. Closed on the branch `rebuild-equals-moved-lines`: the replay compares the expansion of each moved item that holds a macro call at its two places (Step 2) |
| 44 | **The ledger gives a method to the item at its lines, and the item that defined the method can be another one.** A method that the expansion of a macro defines carries the lines of the function that builds the expansion. When that function changes, the apply deletes the method with the old methods of the function. Findings 40 and 41 are two faces of this. | `_emit_accessors` builds `getproperty` for each `@document` struct. A commit changes `_emit_accessors`. The rebuilt image has no `getproperty` for four structs, and a read of a field of such a struct takes the general method. | `rc_assign_methods!`, `rc_owns`, and the end of `rc_apply_tracked`, in `child.jl` | Seen on real commits, and both forms in the gate program. Closed on the branch by D13: an item owns the methods that it defined (Step 6) |
| 45 | A rebuild that loads the sources of the harness leaves the code that Base compiled for the types of that harness in the image: 465 functions and about 2 MB. A chain of whole images adds them at each rebuild. | Gate C in a tree whose Julia holds an older harness: 175.9 MB, then 2 MB more after each rebuild. | `rc_remove_harness!` | Measured. *Proposed by the assistant:* Step 10 takes it, with the test that says that a type is dead |
| 46 | The compiler server evaluates each apply in its one task, so what the program stores in the task stays from one apply to the next. After a struct changes, the new code finds a value of the old type there. | The kernel keeps a `Vector{ReactiveCell}` in `task_local_storage()`. The rebuild of the commit that changes `ReactiveCell` stops with a `TypeError`. | `rc_serve` in `server.jl`; `rc_trial!` in `replay.jl` | Seen on a real commit (the replay over the platform, Step 2). Closed on the branch `rebuild-equals-moved-lines`: an apply and each part of the trial evaluate with an empty storage of the task |
| 47 | The id of a log statement counts its expansions in the process. A server that evaluates a function with a log macro a second time gives the statement the next id, and a whole build has the first one. Two prints of the replay for one user of a macro whose expansion logs never compare equal. | `_notify_evaluation` of the kernel after three commits that move it: other code in the chain of one server, the same code from a new server. | `Base.CoreLogging.log_record_id` | Seen on real commits. Closed on the branch: an apply and each print of the replay start with an empty registry of log ids (Step 6) |
| 48 | The overlay of a large rebuild has root tables with stale bytes: two of 857 tables that grew inside their memory. It is the kind of fault of finding 33, in a case that Step 1 did not close. | The rebuild of the commit that changes the struct `ReactiveCell`, 17 commits after the whole build of the platform. | `staticdata.c`, the writer of the constant data of an overlay; `tool/overlay_check.py` finds it | Seen one time on a real commit (the replay over the platform, Step 6), and a second time on 2026-11-12 with the images kept. **It is a fault of the check and not of the overlay:** each grown table has the new block of roots, and the base holds the same two numbers at that place in 2 tables. The check is corrected (82d3089eaa, Step 6). Closed |
| 49 | A function that changes places between the module that defines it and a module that imports it by its name stops the rebuild. In one direction the rebuild fails with an error of Julia, in the other one it is refused. | `ReferenceModule` had `import ..DocumentModule: search_documents`; the commit takes the function out of `DocumentModule` and defines it in `ReferenceModule`. The rebuild says "invalid method definition in ReferenceModule: exported function DocumentModule.search_documents does not exist". The commit that moves it back is refused: "the module binds search_documents already; Julia ignores a conflicting import". | `child.jl`: `rc_name_removals` kept the import of before when the module defines the name now; the check of an import ran before the name removals | Seen on three real commits (the replay over the kernel with the removals, Step 6); closed on the branch |
| 50 | A method of another module that names a moved struct in its signature stays a method for the struct of before. The expression of the method has the same text, so nothing evaluated it again. | `struct Token` moves from the module `Left` to the module `Right`; `Both` uses the two and has `weigh(token::Token) = token.weight`. After the rebuild `Both.weigh(Right.Token(8))` is a `MethodError`; a whole build gives 8. | `child.jl`: the check of how the names of an expression resolve covered only a module with a changed `using` | Found by reading, confirmed by a gate case that failed first (Step 6); closed on the branch |
| 51 | **Julia fails when it resolves a declared name again in modules that use each other.** The pass that follows a changed binding to the modules that use its module comes back to a binding that it resolved already, and an assertion fails. The error that the person sees is "MethodError: no method matching string(::Expr)", because the message of the assertion is made in the world of the compiler. The released Julia 1.13.1 does the same. | `module R; export f; end`, `module K; using ..R; using ..P; export f; end`, the parent `P` has `using .K`, and both resolved `f`. Then `global f` in `R` fails. In the kernel, `KernelModule` uses each module of its parent and the parent too, and the parent uses `KernelModule`; the rebuild that defines `search_documents` again in the module that exports it reaches the case. | `Compiler/src/bindinginvalidations.jl`, `invalidate_code_for_globalref!` | Seen on the three commits of finding 49, after its correction; a script of ten lines shows it; closed on the branch (ec197346b0), with a test in `test/rebinding.jl`. A report to upstream Julia is the decision of the owner |
| 52 | A name that the call of a macro binds and its source does not show gets a new value, and the expressions that name it stay as they were. The harness knew one name for each expression: the name that the source shows. | `@theme struct ConversationTheme … end` defines `ConversationTheme` and `ScaledConversationTheme`. A change of `ReactiveCell` gives the second type a new identity and leaves the first. `AgentWorkToWidget(theme::Union{ConversationTheme, ScaledConversationTheme})` in another module keeps the type of before in its signature, so a call with a value of the new type is a `MethodError`; a whole build has the new type. The same for the alias `ICCellVector` that `@document struct CellVector` defines, and the methods `ICCellVector(…) = …`. | `child.jl`, `rc_evaluate_next!`: the dependents of an evaluation came from the name of the item | Found by the replay over 18 platform commits with the comparison (24 method lines of 27 297); confirmed by a gate case that failed first; closed on the branch (Step 6) |
| 53 | **An expression that the rebuild evaluates again sees the definitions that come after it in the load order.** A whole build evaluates an expression with the code that it loads before the expression. A rebuild evaluates it in a process that holds the whole program. The result differs when the evaluation calls a function that a later expression gives a method. | `@document struct CellVector` is at line 32 of `CellVector.jl`. The macro asks `get_cell_layout_field_type(Val(:Vector))` for each field that is a `Vector`, and line 150 of the same file has the method that answers `CellVector`. A whole build expands line 32 before that method exists. The rebuild of the commit that changes `ReactiveCell` expands line 32 again, gets `CellVector`, and the constructor wraps its own vector: `CellVector(Any[1, 2])` throws `DeclaredTypeMismatchException` in the rebuilt image and gives a list of 2 elements in a whole build. | `replay.jl` names the limit in its header; no rule of the harness covered it | Found by the comparison of the replay over the platform (4 method lines of `CellVector.jl:32`), confirmed by a call in both images. The owner said to go on with it on 2026-11-12. Closed on the branch for an expression whose text the edit leaves as it is: the apply finds it and refuses (Step 6). For a text of the edit, two checks refuse it (Step 3, 2026-11-13): the text of before must define again what the program holds for it, and the text of now must give the same result in a program that holds no method and no name of what comes after it. Open: a text of the edit that reads a value that a later statement wrote |
| 54 | A deleted method stays in the method table of an overlay. The save takes a closed entry out of its chain by a recorded change of the pointer that leads to it, and a save by pages writes only the objects of the pages that the process wrote. A pointer in an object of another page keeps the bytes of the base. Dispatch does not use a closed entry, so no call goes wrong; `Base.visit` counts it. | After the rebuild of the commit that changes `ReactiveCell`, 2 of 2 754 deleted methods are still in the table: the program counts 23 824 methods, a whole build 23 822. | `staticdata.c`, `reactive_pages_begin`: the recorded field changes did not mark their pages | Found by the comparison of the replay over the platform (the output of the program); closed on the branch (d7a821790b), see Step 6 for the test |
| 55 | A declaration that changes its kind stops the rebuild with an error of Julia: a global that becomes a constant, a constant that becomes a global, a typed global that gets another type. Julia changes no such declaration in a module that holds the name. | `global StringType = String` becomes `const StringType = AbstractString`. The server answers "cannot declare StringType constant; it was already declared global", and the build stops. | `child.jl`, `rc_evaluate_next!`: the changed item was evaluated over the binding of before | Found by the gate of the edit cases (the test set "Global binding invalidation" of Revise); closed on the branch (ca86d3657f, Step 3) |
| 56 | A name that leaves a module does not give the name back to the export of a used module that it hid. `Base.delete_binding` leaves a guard, which no export passes. And a method that an edit writes with the module of its function counted as a binding of the name in its own module. | An edit removes `const view = "shadow"`: `view` is then not defined, where a whole build has the `view` of Base. An edit writes `Base.iterate(x::Foo) = …` in place of `iterate(x::Foo) = …`: the function of the module stays with no method, and a caller gets a `MethodError`. | `child.jl`, `rc_remove_name!`, `rc_given_names`, and the pairing of an old expression with a changed one | Found by the gate of the edit cases (the test sets "Retract removed bindings" and "Orphaned binding realias" of Revise); closed on the branch (ca86d3657f, 14f260af38, Step 3) |
| 57 | A rebuild that is refused, or whose trial stops, wrote the new lines of the methods of the moved expressions into the server before it refused. The server kept them, and the next save wrote them into the image. | The step `order` of `gate_runs.sh` is refused, and its text is 4 lines longer above the methods of `order.jl`. After the next save, those methods have the place `order.jl:13` where a whole build has `order.jl:9`. | `child.jl`, the pairing of the ledgers in `rc_apply_tracked` | Found by the gate step for finding 7; closed on the branch (6f1972c48c, Step 5) |
| 58 | **A source file that the build does not track is no input of the store, so its edit is lost with no word.** The walk of the includes reads the text of the sources. It tracks no file whose path the text computes: an `include` in a loop, a path from a function, an `include` with a function of its expressions. The walk warns at the whole build. A rebuild then compares the tracked files only. The same holds for each file of a path package when the build does not track the dependencies. | `for name in ("one", "two") include(joinpath("computed_include", name * ".jl")) end`, then an edit of `two.jl`: the rebuild prints "applied 0 expressions", makes a snapshot, and the program answers `(1, 2)` where a whole build answers `(1, 20)`. | PackageCompiler, `tracked_sources` and `_reactive_inputs` | Found by the new cases of the gate of the edit cases (the test sets "Computed include path" and "include with mapexpr" of Revise); closed in PackageCompiler on the branch `live-harness` (Step 3) |
| 59 | A file whose `include` line moves to another module stays in the module of before. The apply pairs the file of before with the file of now by the path alone, finds the same text, and evaluates nothing. | `include("part.jl")` moves from `module First` to `module Second`: the rebuilt program has `First.part` and no `Second.part`; a whole build has `Second.part` only. | `child.jl`, `rc_match_files` | Found by the new case `moved_include` of the gate (the test set "Moved include" of Revise); closed on the branch (Step 3) |
| 61 | **An expression whose text stays and whose place in the load order changes is not evaluated again.** A whole build evaluates it at its new place, where it sees other definitions. The ledger compares texts, so a moved method, a moved expression or a moved `include` line changes nothing in the rebuild. | `pick(x) = 1; const PICKED = pick(1); pick(x::Int) = 2`, and the edit moves the last line above the constant: a whole build gives `PICKED == 2`, the rebuild keeps 1 and prints "applied 0 expressions". | `child.jl`, `rc_apply_tracked`: no rule for the order of the expressions that the edit leaves as they are | Found by a reading of the code for the open part of finding 53 (2026-11-13); closed on the branch (Step 3, rule H4) |
| 1 | A name that leaves a `using` or `export` line stays. A removed struct, constant or global stays. The rebuild prints "not applied, the binding stays". | Move `foo` from module `A` to module `B`. `A` still exports its old `foo`. A module with `using A, B` sees two `foo`, and Julia can not choose. A whole build has one. | `child.jl:874` | Read, Log (29 times); the example needs Test. Closed on the branch by D2: an expression that left takes its methods and its names with it (Step 6) |
| 2 | A constant keeps the value that the old code made. An edit of a function evaluates no initializer again. | `const BINDINGS = _make_open_page_bindings()`. Edit the function. The rebuilt program has the old bindings. In the sources, 129 constants take their value from a call in one line: 78 call `_color`, and 17 call another function or constructor of the tracked packages. | `child.jl:997-1032` has no case for a changed method | Read. Closed on the branch by Step 7 (`gate_runs.sh`) |
| 3 | A macro expansion keeps the old code of its helper function. Only a change of the `macro` item itself evaluates its users again. | `macro document(args...) _document_expr(args; ...) end`. An edit of `_document_expr` changes what 788 `@document` items expand to. The rebuild evaluates none of them. | `child.jl:899-916` | Read; seen on real commits in the replay gate (Step 2), and in the IDE store on 2026-11-10. Closed on the branch by Step 7 (`gate_runs.sh`) |
| 4 | A changed top-level statement adds to the effect of the old one. | `register!(TABLE, a)` becomes `register!(TABLE, b)`. The table of the rebuild holds `a` and `b`. A whole build holds `b`. | `child.jl:649-659` (ids `X`, `D2`) | Read. Closed on the branch by Step 7 for a statement that names a tracked global; another one is refused (`S1`) |
| 5 | A value of a struct type that changed stays inside a global, when a function made the value. | `const DEFAULT = make_default()` gives a `Theme`. `Theme` gets a field. `DEFAULT` holds an old `Theme`, and no method of the new type accepts it. | the limit that `doc/architecture.md` names | Read. Closed on the branch by Step 7 (`gate_runs.sh`) |
| 6 | A generated function keeps the old answer of its generator when a helper of the generator changes. The save also removes the old helper from the method table with no look at the world in which the generator runs, so a new specialization can stop with "method too new". | the same as 3, for `@generated` | no case in `child.jl`; `staticdata.c:1016` | Test. The first sentence is closed on the branch by Step 7 (`gate_runs.sh`); the save and "method too new" have no test yet |
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
| 10 | The harness keeps a cache from the text of each statement of the trace to the type that the text gave in the whole build. After an edit changes a struct, the cache still gives the old struct. The statement fails, or it compiles code for the old struct, and the new struct gets no compiled code. `--refresh-trace` does not heal it, because the new statement has the same text. | 150 statements failed today, 137 of them in the owner's packages. 63 are functions of the SDL backend: `_compute_dirty_change`, `_record_painted_element!`, `_take_wheel_run!`. They name `SdlBackend` and `SdlWindowResources`, which changed and have no type parameter, so the text of each statement is still right. The program compiles its paint path at each start. | `child.jl:1136-1159` | Read, Log. Measured on the platform: 1 136 of 2 268 roots after the commit that changes `ReactiveCell`. The table is closed on the branch (86b5d06977, see Step 6): the session drops it when a constant gets another value |
| 11 | A statement whose text is no longer right stays lost. A struct with one type parameter for each field, as each `@document` struct has, changes its text with each new field. New code behind a dynamic call has no statement at all. Both wait for a person who runs `--refresh-trace`. The rebuild writes the count into the server log and nowhere else. | `collect_ini_file_entries(::LegacyProjectIniFiles{ReactiveCell{Any}, …})` after the struct got a field | `child.jl:1197`, `reactive.jl:285` | Log |
| 25 | An edited method starts with no compiled code. It gets code from the trace and from the callers that the rebuild compiles again. Code that the whole build compiled for the old method by another way is not compiled for the new one: a finalizer, a callback, a dynamic call from an unchanged caller. The old method still lists those specializations when the apply replaces it. | Edit the body of a function that only a `finalizer(f, x)` of an unchanged function names. | `child.jl:994`, `typeinfer.jl:1939` | Read (audit) |
| 26 | In the overlay form, new code calls an old function with boxed arguments through `jl_invoke`. A whole build makes a direct call. The same path cost 43 ns against 2.6 ns in the bench of gate M6. Most functions on mutable documents have boxed arguments. The count line of the build prints 0 for these calls. | An edited function calls an unchanged `handle!(document, event, context)` in a loop. | `codegen.cpp:5378` ("TODO: Add !specsig support"), `aotcompile.cpp:504` | Read. Closed on the branch by D11 (1fd1c54bd7, Step 9): the call goes through a slot; 2.0 ns against 1.55 ns from old code in the bench of gate M6 |
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
| 24 | The `sizes` step of gate C fails on the branch: 100 568 bytes of growth against a bound of 35 136. | Closed on 2026-11-13 (Step 2): two leaks of the harness and a bound that took too little for a slot. Each rebuild left the module of a check of the warm-up in the image, and the roots of 22 methods of Base held dead code of the whole build. The chain now grows about 50 KB in 18 rebuilds, which is the cost of its 810 slots, and the gate passes |
| 60 | The gate of the edit cases tested less than its result said. A store founds again by itself when its image grew 25 % since its whole build. The program of the gate is small, so the bound came after about 24 rebuilds, two times in a run of 44 cases. Each such whole build took each edit of before into the chain, and the comparison at the end then tested only the cases after the last one: 3 of 44. This was a run through a child, where each rebuild writes a whole image. The runs of 2026-11-12 (36 and 37 cases) went through a server with overlays, where the growth counts one overlay; their logs are gone, so no record says that they founded again. The same form with 45 cases and the guard does not found again (2026-11-13). | Found on 2026-11-13, when two cases that must lose an edit ended equal to the whole build. The gate now gives its store a bound that it does not reach, and a whole build of the store in the middle of a run is a fault; `gate_runs.sh` has the same guard. The replay gate already counted such a commit. The first strict run found finding 59 |

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
- **D13. A method keeps the place of the expression that defined it (finding
  44; the owner's answer to Q2, on 2026-11-11).** The runtime knows the
  top-level expression that it evaluates. When it defines a method, the method
  keeps the file and the first line of that expression, in two new fields
  (`toplevel_file`, `toplevel_line`). The file and the line that a method has
  now stay what they are: the place of its text, which the line table and a
  moved item need. The two differ for a method that the expansion of a macro
  defines.

  - The place is that of the source: a line number node of the form that the
    loader gives to the evaluation sets it, and a line number node inside the
    result of a lowering does not, so a macro that returns top-level forms
    with its own lines changes nothing. An `eval` inside a top-level
    expression keeps the place of that expression. Outside each top-level
    evaluation there is no place, and a method that the program defines at run
    time has none.
  - The ledger takes the methods of an item from the definer: the methods
    whose top-level place is the file and the first line of the item. A whole
    build and a rebuild give the same answer. The harness evaluates an item
    with its place, and a kept method takes the place of the new definition.
  - A moved item gives its new first line to the methods that it defined, and
    its shift to the lines of the methods whose text is inside it. These are
    two sets now.
  - The place is one value of the process, as the line of the last resort
    error message is. Two tasks that evaluate top-level expressions at the
    same time can give a method the place of the other one. A package loads in
    one task, and so does an apply.

  The image holds two more fields for each method, so a store needs one whole
  build with the new Julia.

## The open questions

Two decisions are the owner's. Q1 sets what property 3 means and what a
rebuild costs; it has its answer, (b), since 2026-11-13. Q2 came with finding
44, on 2026-11-10, and sets how the rebuild knows the methods of an
expression; it has its answer.

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

*On 2026-11-13 the owner chose (b): "the recording is initiated manually, the
performance degrades gradually, so it's not an issue".* A rebuild runs no
workload. It says how many statements of the trace it lost and how to record
again, and a person starts the recording when the program is slow enough to
need it. Built in PackageCompiler (branch `live-harness`): the whole build
records the count of the statements that did not compile in it
(`founding_lost`), each rebuild prints `lost_statements`, and when it is more,
an info line names `refresh_trace` and the list in the store
(`reactive-store/trace.jl.unresolved`). In `gate_runs.sh` the first edit loses
4 statements (a moved type, a removed function, a closure with a new name),
and each later rebuild says so.

**Q2. How does the rebuild know which expression defined a method (finding
44)?** The ledger finds the methods of an item by file and line. A method that
the expansion of a macro defines carries the lines of the function that builds
the expansion, so the ledger gives it to that function. Two relations are
mixed here. The *place* of a method is where its text is; the line table and
a moved item need it, and the file and the line of the method give it. The
*definer* is the top-level expression whose evaluation made the method; the
apply needs it when it deletes the old methods of a changed or removed item,
and when it looks for the items that define a method on a changed type.

- (a) **Julia records the definer.** When the runtime defines a method, it
  knows the top-level expression that it evaluates: it prints "in expression
  starting at" from the same fact. The method keeps the file and the first
  line of that expression. The ledger then reads the definer of each method,
  after a whole build as after a rebuild. The cost: a change of the runtime
  and of the image, a `make`, and one whole build of each store.
- (b) **The replay finds the definer again.** The fork of the replay
  evaluates the form of before the edit of each changed or removed item under
  a filter that records what it defines, and reports those methods. No change
  of the runtime. The cost: one more evaluation for each changed item in each
  rebuild, and the definer of an item that the apply does not evaluate stays
  a guess by lines.
- (c) **A narrower line rule.** An item owns a method at its lines only when
  the method is of the function that the item defines. No evaluation and no
  change of the runtime. It is a rule about names, and a macro or a statement
  that defines methods has no name to compare.

My recommendation is (a). The fact exists when the method is defined, and (a)
keeps it; (b) and (c) search for it again. (a) is also the only one that
gives the definer of an item that no apply evaluated, which the dependents of
a changed type need, and it adds no work to a rebuild.

*On 2026-11-11 the owner chose (a).* D13 states it, and Step 6 builds it.

One correction needs no answer and is built: a method that an evaluation of
the apply defines again with the same code is never deleted, whoever has it
at its lines. It closes the first form of finding 44, where the user of the
macro is evaluated again. The second form, where the user is not evaluated
again, waits for Q2.

## Steps

The work is in a worktree of `merged-next`, with worktrees of
PackageCompiler and projectured-julia beside it. Each step is a commit, with a
test that fails before the change.

On 2026-11-10, after Step 1, the owner said "Yes and continue": the push of
Step 1, and the work goes on with the next steps in their order. Q1 is still
open; Step 10 needs its answer. Q2 has its answer, (a), since 2026-11-11.

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

  *Gate C passes again (finding 24, 2026-11-13).* The step `sizes` now
  records the sections of the image at each rebuild, and keeps the images
  that `KEEP` names. Two images of the chain, 16 rebuilds apart, compared by
  a walk of their objects, show what grew:

  | what grew in 18 rebuilds | bytes | cause |
  | --- | --- | --- |
  | the image data (`.ldata`) | 93 096 of 107 768 | objects that stay |
  | 2 modules for each rebuild, with 6 bindings, 8 partitions and 2 functions | about 56 000 | `rc_warm` checks the docstring of a module header with a module `D` that it makes. A docstring puts its module on `Base.Docs.modules`, a list that is a root of the image, and each rebuild process warms up |
  | the slots: 45 for each rebuild | about 48 000 | a slot is never freed; it costs 59 bytes, and the bound took 32 |

  A third thing came up in the same search and is no growth of the chain:
  the image of the whole build held 294 code instances that no world runs,
  below 40 roots of 22 methods of Base. Julia appends to the roots of a
  method and takes nothing out, and the inferred code of a method names the
  code instances of its callees through its roots, so the root of a callee
  that was compiled again stays. The whole build of the gate program made
  them when it loaded its packages. `rc_drop_dead_roots!` empties each such
  root that no inferred code of a live code instance of the method names, at
  the end of each apply and before the write of a server. The first rebuild
  drops them: the image is 620 KB smaller from there on.

  *As closed (84c35442f6, 557581e73a, b7df0bd555, 2f66e95952).* The module
  of the check leaves the list after the check. The bound of the gate is 64
  bytes for a slot and 1 024 bytes for a rebuild: 70 272 bytes for this
  chain, which grows 48 152 to 51 696 bytes. The leak of the module
  (107 768 bytes) still passes the bound. Ruled out on the way: the
  partitions of the bindings (a name holds at most 4), the values of the
  slots (the slots of the last rebuilds hold no new object), and dead code
  in the lists of callers (the writer prunes those).

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

  *The 13 methods with other code, sorted (2026-11-10).* A probe printed the
  lowered code of each one from the rebuilt image and from the whole build.
  Ten are noise of the comparison, and three are a real difference:

  | count | what differs | what it is |
  | --- | --- | --- |
  | 9 | a name such as `#s131`, which the lowering gives to an argument or a type variable that the source does not name | noise: the counter of the process. `oracle.jl` drops it now |
  | 1 | the number that `@enum` writes into the hash method of the enum type `_CellState` | noise: the hash of a type follows the build id of its module, which each compile of the package draws again. The two whole builds of the control agreed only because they took the same compiled file from one depot. The control build compiles the tracked packages again now, and the fact goes to its noise list |
  | 3 | the line of a log macro, as a number in the code: 729 in the rebuilt image, 732 in the whole build | real: finding 43 |

  With the two repairs, the kernel run of 28 commits has 3 methods with the
  same signature and other code, in place of 13. All three are finding 43.

  *The moved expressions, as built (finding 43; decided in the build, by the
  assistant).* An expression that an edit leaves as it is and moves to
  another line or file, and that holds a macro call outside a docstring, is
  a *moved macro user* (`rc_is_moved_macro_user` in `child.jl`). The fork of
  the replay expands each one at its place of before the edit and at its
  place of now (`rc_moved_difference` in `replay.jl`). The print of a line
  number node is the same at each line, so the two prints differ exactly
  when a macro put the line or the file into the code as a value. Such an
  expression joins the changes with the id `D1`. Three points follow:

  - An edit that moves a macro user takes the ledger of every file, and the
    replay runs for it with no other change, because a dependent of the
    moved expression can be in any file.
  - A docstring is a macro call in the syntax, and its record keeps the line
    of its expression. The rule looks through it: the line in the record of
    a docstring stays as the last evaluation wrote it. Nothing in the three
    repositories reads that line.
  - A renamed file is another place too, so a log macro of a renamed file
    gets the new file name.

  The other choice was to leave the line as it is and to call it line
  information, as the lines inside a quoted expression. It was not taken,
  because a person reads the line of a log message and opens that line.

  *The cost on the IDE* (`replay/ide_line_probe.jl` of the session, read
  only): of 27 302 items, 5 497 have a docstring, 2 842 hold a macro call
  outside a docstring, and 173 hold their place in the expansion: 120
  methods with a log macro, 42 types of `@theme`, 11 statements of
  `@domain`. They are in 118 files, with 10 at most in one file. So an edit
  that adds a line evaluates 10 items again at most, and one or two in most
  files. The two expansions of all 2 842 take 14 s in a process that never
  ran the macros; one file has a small part of them.

  *The gate.* `tool/gate_runs.sh` has the file `lines.jl` with
  `noted_line() = @__LINE__`. The first edit of the gate puts two comment
  lines above it, with the other edits. With the rule, the rebuilt program
  names line 5, as the whole build does, and the chain equals the whole
  build in the four checks (24 methods, the roots, 16 lines of output, 12
  globals); the rebuild says `11 candidates, 11 compared, 1 moved, 9
  differ`. The step `move` is a second edit that puts one more comment line
  above the function and changes nothing else: the rebuild says `0
  compared, 1 moved, 1 differ`, evaluates the function again as `D1`, and
  the program names line 6. The gate passes in both forms, through a child
  with whole images and through a server with overlays. With the harness of
  before the rule, the same gate stops at the rebuilt program: it prints
  `line = 3`, where line 5 is expected.

  *Finding 40, found: the ledger gives a method to the item at its lines
  (finding 44).* The log of the replay over the 28 commits shows where the
  missing methods went:

  ```
  rc: change A4 DocumentMacro.jl:294 _emit_accessors, 1 methods, 4 deleted
  ```

  `_emit_accessors` is a function of the `@document` macro. It builds the
  `getproperty` method of a struct inside a `quote`, so that method carries
  the file and the line of the quote. The ledger gives an item each method
  whose line is inside the lines of the item, so the item `_emit_accessors`
  has the `getproperty` methods of four structs as its own methods. A commit
  changes `_emit_accessors`. The apply deletes each old method of a changed
  item. The four structs were evaluated again, and the filter kept their
  `getproperty`, because its code is the same; the change of
  `_emit_accessors` deleted it after that. The image of the new server
  lacks `getproperty` for `SelectionDocument`, `FieldReferenceStep`,
  `RangeReferenceStep` and `TypeReferenceStep`.

  The two constructors of `RootedOperation`, which the chain of one server
  lacks, went the same way. The list of the commits is not one line of
  history: the checkout of commit 20 takes the struct away, and commit 21
  brings it back. The removal is not applied (finding 1), so the two
  constructors stay at their lines, and the ledger gives them to the item
  that is at those lines in the file of commit 20. At commit 21 the struct
  defines them again, the filter keeps them, and the change of that other
  item deletes them.

  *The two forms of finding 44, in the gate program.* Two macros define
  methods inside a `quote` of a function of `helpers.jl`, and the edit
  changes that function:

  ```julia
  function accessor_code(name)          # the edit changes the first method
      return quote
          $(esc(Symbol(name, :_first)))() = 1        # 2 after the edit
          $(esc(Symbol(name, :_second)))() = 10
      end
  end
  function steady_code(name)            # the edit adds a check, and the
      return quote                      # expansion stays the same
          $(esc(name))() = 7
      end
  end
  # users.jl, which no edit changes:  @accessors pair      @steady steady_value
  ```

  | | a whole build | the rebuild, before the corrections |
  | --- | --- | --- |
  | `pair_first()`, `pair_second()` | 2 and 10 | 2 and *no method* |
  | `steady_value()` | 7 | *no method* |

  The rebuild says `change A4 helpers.jl:44 accessor_code, 2 methods, 1
  deleted` and `change A4 helpers.jl:53 steady_code, 1 methods, 1 deleted`.
  `pair_second` is the first form: its user is evaluated again, the filter
  keeps the method, and the change of `accessor_code` deletes it.
  `steady_value` is the second form: its user is not evaluated again, and
  the change of `steady_code` deletes its method.

  *The kept methods, as built (the first form; decided in the build, by the
  assistant).* A method that an evaluation of the apply defines again with
  the same code is a method of the sources of now. The filter gives it the
  file and the line of the new definition, and each change and each removal
  that names it as an old method loses it (`rc_method_filter`,
  `rc_evaluate_next!` in `child.jl`). Before, only the change that
  evaluated it let it go. With this, the rebuilt program prints `2 and 10`.
  The case `@steady` is out of the gate program until Q2 has its answer;
  the session keeps it as a patch.

  *Gate C grows by 2 MB for each rebuild in this tree, and the cause is the
  loaded harness (finding 45).* Gate C ran with a census of the image after
  each rebuild (4 cycles, 8 rebuilds). The loadable size goes from 175.9 MB
  to 189.4 MB: 1.9 MB to 2.0 MB more after each rebuild, in each part of the
  image (the image data 12.0 MB, the code 1.0 MB). Nothing of the tracked
  package grows: 121 bindings, 52 of them with a generated name, 69
  methods, each count the same after each rebuild. Each rebuild emits 465
  functions for an edit of 6 expressions. They are functions of Base that
  were compiled for the types of the harness: after 10 rebuilds the image
  holds 10 copies of each one, as
  `_collect(Type{RcItem}, Generator{Filter{…}, Vector{RcItem}})`, each for
  the types of another loaded harness. The Julia of the worktree holds the
  harness of its last `make`, so each rebuild of a store of this tree loads
  the sources of the harness (Step 4), and `rc_remove_harness!` deletes the
  methods of the harness, and not the code that Base compiled for its
  types. An overlay holds that code once: the 4.5 MB that Step 4 measured.
  A chain of whole images adds it at each rebuild.

  So gate C can not judge finding 24 in this tree until a `make` gives the
  Julia of the tree the harness of the tree. The run of 2026-11-09, with
  100 568 bytes after 9 cycles, was before Step 4. Gate C now runs under
  `bounded-run` and edits a copy of its program in `$OUT/src`.

  *The replay over the platform package (2026-11-10; 25 commits, e0f6014fb
  to 406d4f868, the kernel and the platform tracked; 35 min, peak 14.0 GB of
  a cap of 14 GB).* The whole build takes 6 min with a peak of 12.6 GB. The
  program counts 4 480 names and 23 692 methods.

  - 24 rebuilds apply, none is refused, and one fails: finding 46. The
    commit 1df4c59c8, which the chain of the kernel refused, applies.
  - The rebuild time follows the distance from the whole build: 7 s to 11 s
    for the first six commits, then 28 s to 37 s from commit 8 on, where a
    struct gets a field. After the store founds again at commit 18, the
    rebuilds take 6 s to 20 s. The replay is 2.0 s to 4.4 s of each one
    (1 212 candidates; one run compares 1 206 of them in 4.4 s).
  - Against the whole build of the last commit, the seven commits after
    commit 18 give: the same 4 489 names, the same 148 globals, the same
    state of each root (1 313 compiled, 46 not there, 4 inferred, in both),
    and 27 400 methods against 27 350. The 50 more methods are those of
    finding 44: closures and methods of an expansion that an evaluation
    left behind (as 110 closures of `print_document` against 96), and three
    methods on the type `StartSettings` of before its change. One method
    has other code.
  - The control found the hash methods of two enum types as noise, as on
    the kernel.

  Two faults of the gate itself showed and are corrected. The oracle read a
  root in `Main`, where no package of the platform has a name, so 1 356 of
  its roots did not resolve; it now reads a root in a module that binds
  each loaded package. And the log of the server of a failed rebuild was
  lost when the store founded again; the gate keeps it now.

  *Finding 46: the server keeps what the program stores in its task.* The
  rebuild of 00d0f77e0, which changes the struct `ReactiveCell`, stops:

  ```
  TypeError: in typeassert, expected Vector{ReactiveCell},
  got a value of type Vector{@world(ReactiveCell, 39759:43325)}
  ```

  The kernel keeps the stack of the cells that compute in the storage of
  the task: `get!(() -> ReactiveCell[], task_local_storage(), …)::Vector{ReactiveCell}`.
  The server evaluates each apply in its one task, so a vector that an
  evaluation of before the change made is still there, with the element
  type of before the change. The log of that server is lost, so the
  evaluation that made the vector is not named. A whole build and a child
  start with an empty storage. The fork of the replay has the same fault
  inside one apply: it evaluates code of before the changes and code of
  after them in one task.

  *The gate case.* `markers.jl` of the gate program keeps a
  `Vector{Marker}` in the storage of the task, and an initializer of
  `users.jl` puts a value there. The first edit changes the function that
  makes the value, so the server evaluates the initializer in its task.
  The step `retype` then gives `Marker` a field. Through a server, on the
  harness of before the rule, the rebuild stops as the real one did:
  `TypeError: in typeassert, expected Vector{RunLib.Marker}, got a value of
  type Vector{@world(RunLib.Marker, 39759:40492)}`, in the apply, and the
  trial of the replay stops with the same error for a vector that it made
  itself.

  *The storage of the task, as built (decided in the build, by the
  assistant).* Each part of an apply that evaluates the program at one
  state of its code gets an empty storage of the task
  (`rc_with_empty_task_storage`): the evaluation of the queue in the apply;
  the part of the trial before the changes; the part of the trial after
  them. The task gets its storage back after the call. A second rule
  closes a hole that the fault showed: a trial that stops at an error is no
  proof that the apply meets the same error. When the trial stopped and the
  apply ends with no error, the apply now fails, because the trial compared
  no expression after the place where it stopped. A trial that ends with no
  answer at all is still a warning; Step 5 decides both together, with the
  apply in a fork.

  With the two rules, `gate_runs.sh` passes in both forms, with each step
  as expected and the four checks equal (34 methods, the roots, 18 lines of
  output, 13 globals).

  *Open in this step:* the reason of the size of gate C after a `make`; the
  profile of the apply.
- [ ] **Step 3: one test for each finding 1 to 9, 25 to 27 and 29, which fails
  first.** Each is a small edit of the test program, compared through the
  oracle or through the list of what the program compiles at run time. A
  finding whose test passes on the branch leaves the plan, with a note.

  *The cases of Revise (asked by the owner on 2026-11-12).* The server half
  of the harness does the job of Revise.jl: find the changed top-level
  expressions, evaluate them, delete what left. So Revise 3.18 gives two
  lists at no cost: its page of documented limits, and the edit cases of its
  test suite.

  *The limits of Revise as a checklist.* Each limit is an edit that a
  rebuild must apply as a whole build does, or refuse.

  | limit of Revise (`docs/src/limitations.md`) | here | test |
  | --- | --- | --- |
  | a changed macro, or a changed function that a generator calls, does not reach its users | D1, the replay | `gate_runs.sh`: `@accessors`, `@steady`, `staged` |
  | code whose existence depends on data (`tf = true; if tf f() = 1 else f() = 2 end`) | the statement names the global, so it is a dependent of the global | none: a case to add |
  | a change of an alias or a constant that a type definition names does not reach the type | the constants that an evaluation binds again (finding 52) | `gate_runs.sh` has the alias that a macro defines; the alias in plain text is a case to add |
  | code that runs in a task keeps its world | no part of a build; the server has the storage of its task (finding 46) | `gate_runs.sh`: `markers.jl` |
  | Distributed workers and functions with no name | no part of a build | none |
  | a removed `include` is seen for a literal path only | C4: an `include` whose path the harness can not read is refused | none: a case to add (a removed `include`, a computed path) |
  | a precompile by another process discards the baseline | the store keeps a copy of each tracked source | Step 5 (each input is known) |
  | a new package extension needs a Manifest update | F3, and the Manifest as an input (D5) | Step 5 |
  | a name removed from `export` (before Julia 1.14) | D2 | `gate_runs.sh`: `moved.jl` |
  | `include(mapexpr, filename)` (before Julia 1.14) | refused as C4, because the harness reads the form with one argument | none: a case to add |
  | `struct` definitions (before Julia 1.12) | B2 with the dependents | `gate_runs.sh`: `Theme`, `Marker` |

  *The edit cases of the test suite of Revise.* `test/runtests.jl` has 145
  test sets. The ones that are an edit of a source text are the cases to
  take; the others test the watch of files, the REPL, Pkg, Git and
  Distributed, which a build has not. The cases, by the name of the test set:
  - signatures and methods: "Signature extraction", "Signature
    instantiation", "Multiple definitions", "Method deletion", "Method
    deletion specificity", "Duplicate macro-defined methods", "Changing
    @inline annotations", "External method tables", "Cross-module extension";
  - types: "Default constructors for macro-generated types", "Default
    constructors for reused loaded types", "Recursive types", "struct inner
    functions", "Modify @enum", "Struct redefinition plus new struct", the
    five "struct revision" sets, "type scan world-age";
  - names: "Retract removed bindings", "Retract import shared across files",
    "Global binding invalidation", "Import switch", "Retracted import during
    type deletion", "Orphaned binding realias", "Gensym names in source";
  - macros and evaluated code: "Revising macros", "More arg-modifying
    macros", "Module-local eval", "Evaled toplevel", "@__FILE__";
  - modules and files: "Multimodule include", "New submodules", "Submodule
    in same file", "baremodule", "module style 2-argument includes", "include
    with mapexpr", "Removed include", "Removed include, still included",
    "Moved include", "Computed include path", "Revision order", "New include
    order";
  - docstrings and lines: "Module docstring", "Changing docstring", "New
    documented binding", "Docstring attached to signatures", "Macro
    docstrings", "Line numbers".

  *The gate of the edit cases, as built (`tool/gate_cases.sh`,
  `tool/r1_cases`; the owner agreed to the use of the cases on
  2026-11-12).* The application `CaseApp` loads the path package `CaseLib`.
  Each file of `CaseLib/src/cases` holds one module with a function `shown`,
  and the file of the same name in `cases-after` holds the module after its
  edit. The gate founds the program, takes each case in its turn with one
  rebuild through a server, founds the edited sources two times (the second
  one is the control of the noise of the oracle), and compares the method
  tables, the output and the globals. A refusal keeps the text of before
  for its case and is counted. Another failure founds the chain again and
  fails the gate at its end. The roots are counted and not failed: an edit
  gives the program values of other types to print, and only a new trace
  names their methods (Step 10, Q1).

  The table has 36 cases: 2 from the page of limits (code whose existence
  depends on a global; an alias that a type names), 33 that say again the
  edit of a test set of Revise, with no code of Revise, and 1 from a fault
  of this work (the argument of a macro that looks like a global). Two test
  sets ("Multiple definitions", "Duplicate macro-defined methods") define
  one method two times, which a package can not hold, so they are no case.
  The cases of files and includes (a removed, moved or computed `include`,
  `include` with a map function) need more than one file for a case and are
  not in the table yet.

  | the 35 cases | first run | with findings 55 and 56 |
  | --- | --- | --- |
  | applied, refused, failed | 34, 1, 0 after the rule of finding 55; the case of that finding failed before it | 34, 1, 0 |
  | lines of the output that differ, of 35 | 2 | 0 |
  | method lines (151), globals | equal | equal |
  | roots that the chain lacks | 9 | 9 |

  *All gates on the build at fbf0b0c1df (2026-11-12), with the harness of
  the build.* The gate of the edit cases with 36 cases: 35 applied, 1
  refused, no fault, and the method tables (157 lines), the output (36
  lines) and the globals equal. `gate_runs.sh` through a server and through
  a child: each step as expected, the four checks equal. The replay over
  the 28 commits of the kernel: no refusal, no fault, the chain and a new
  server equal a whole build. The replay over the 18 commits of the
  platform: 17 applied, 1 refused (finding 53), no fault, each check equal.

  The refused case changes a `baremodule` into a `module` (C5, the header
  of a module). The cases found two faults:

  *Finding 55: a declaration of another kind.* `global StringType = String`
  becomes `const StringType = AbstractString`, and the rebuild stops with
  the error of Julia. Before the evaluation of a changed `const` or
  `global`, the binding of before now leaves when the declaration of now is
  of another kind: a constant over a global, a global over a constant, a
  typed global with another type (`rc_drop_other_declaration!`). A whole
  build has only the declaration of now.

  *A fault of the first form of that rule, which the platform replay
  found.* The rule read the kind of the item of now and the binding of the
  module. The kind of an item comes from its text, and the platform has the
  line `@insertion TextBlock = @selected TextBlock(…)`: the argument of the
  macro looks like a global with the name of the struct, and the macro
  binds no global. When a rebuild evaluated that line again, the rule took
  the struct `TextBlock` out of its module, and two rebuilds of the
  platform chain stopped with "`TextBlock` not defined". The rule now takes
  a plain declaration only (no macro call holds it, other than its
  docstring), whose text of before declared the name in the other kind,
  and a binding that is what the text of before declared. A case of the
  gate has the trap (`macro_argument_like_a_global`). One form stays with
  no rule: the ledger reads a typed assignment with no keyword
  (`x::Int = 1`) as a method, so its change of type is not seen as a
  declaration.

  *Finding 56: a name that leaves gives the name back.* Two cases printed an
  error in the rebuilt program. A removed `const view = "shadow"` left the
  name `view` not defined, where a whole build has the `view` of Base:
  `Base.delete_binding` leaves a guard, which hides the export of a used
  module. Revise meets the same thing and evaluates a `using` line in its
  place. The runtime function `jl_reactive_binding_leave` now replaces the
  binding with the implicit resolution of the new world, which is the state
  of a module that never bound the name. The second case writes
  `Base.iterate(x::Foo) = …` in place of `iterate(x::Foo) = …`. Its new text
  binds no name in the module (`is_qualified_method`), and the old
  expression of a change now comes up for the removal of its name too.

  *The second round of the gate (2026-11-13): 45 cases, and a strict gate.*
  The gate was not strict (finding 60): in a run through a child, its store
  made a whole build by itself two times, and the comparison then tested the
  last cases alone. The gate now gives its store a bound that it does not reach, and
  counts a whole build of the store in the middle of a run as a fault. The
  first strict run found finding 59. The new cases:

  | case | what the edit does | a rebuild now |
  | --- | --- | --- |
  | `edited_reader_of_a_later_method` | changes the text of an expression that reads a later method | refuses (finding 53) |
  | `new_reader_of_a_later_method` | makes an expression read a later method | refuses (finding 53) |
  | `typed_global_other_type` | gives a typed global with no keyword another type, and removes another one | applies |
  | `removed_include`, `new_include` | takes a file out; adds a file with its `include` line | applies |
  | `moved_include` | moves an `include` line to another module | applies (finding 59) |
  | `computed_include`, `include_with_map` | changes a file whose path the text computes, or that `include` reads through a function | stops and names the file (finding 58) |

  | the run of 45 cases, with the harness of the folder | result |
  | --- | --- |
  | applied, refused or stopped, faults | 39, 6, 0 |
  | method lines (183), output (45 lines), globals | equal |
  | roots that the chain lacks (counted, Step 10) | 10 |
  | the store founds again by itself | never |

  *Finding 53 for a text of the edit (proposed by the assistant; built on
  the branch, the owner did not see it yet).* An item whose text the edit
  changes, and a new item, have no result of before to compare with. Two
  checks now refuse such an item when its evaluation reads a method that
  comes after it:

  - *The text of before.* The second fork of the replay, in the program of
    before the edit, also evaluates the text of before of each changed item
    for which the program holds methods (`rc_edited_checks`). When that text
    does not define again what the program holds, the item reads what the
    apply can not give it, and its edit is refused. This finds an edit of an
    expression that reads a later method already.
  - *The text of now, with nothing after it* (`rc_order_check!`, at the end
    of the trial). For each candidate of the replay that the apply evaluates
    with a text of the edit, the fork takes the result in the whole program:
    the expansion, the value of the initializer, the definitions of a
    statement. Then it deletes each method that an item after the candidate
    in the load order defined, and takes the result again. A whole build
    gives the item the second program. When the two results differ, the
    apply refuses: "its evaluation gives another result in a program that
    holds no method of what comes after it". The candidates go from the last
    one to the first one, so each method is deleted one time.

  The cost: the deletion of 13 518 methods of 13 loaded packages takes 2.1 s
  in one process, 155 µs for each method, and the code of Base runs at once
  after it. The check runs only when an edit changes or adds a candidate of
  the replay: an item that calls a tracked macro, an initializer that runs
  code and names a tracked name, or an `eval` statement. In the gate, 4 of
  the 45 rebuilds ran it, each in 0.03 s for about 100 methods.

  *Its limits.* The second program lacks the methods of what comes after the
  item, and nothing else. A text of the edit that reads a later name
  (`isdefined`), a later type (`subtypes`) or a value that a later statement
  wrote is not found. An `include` line that moves inside its module changes
  the place of each item of its file in the load order, and no check
  evaluates those items.

  *Finding 58, as closed (PackageCompiler, branch `live-harness`).* Julia
  records each file that a package included in the header of the cache of
  the package, with its size and its checksum, and the image names that
  cache (`Base.pkgorigins`). After a whole build, a process on the new image
  reads the headers (`_reactive_untracked_sources`). Each source file of the
  package of the build or of a path package that the walk did not track
  becomes an input of the store, with the print of the text that the build
  loaded. A rebuild whose such file differs stops and names it, as for each
  other input (D5). The whole build prints the list of those files.

  *Finding 59, as closed.* `rc_match_files` pairs a file of before with a
  file of now by the path and the module. A file whose module changes is a
  removed file of the module of before and an added file of the module of
  now: its methods and names leave the first module, and the second module
  evaluates it.

  *The typed assignment.* The ledger read `x::Int = 1` as a method, because
  the left side of a method with a return type has the same head. It is a
  global when the left side of `::` is a name (`entry_kind`), so the rule of
  finding 55 now covers a typed global with no keyword.

  *Not in the gate.* A file that two modules include: the walk of the
  includes stops the whole build with an error for it, so no rebuild meets
  it.

  *Rule H4: an expression at another place of the load order (finding 61,
  proposed by the assistant).* The apply pairs each expression of now with
  its expression of before by the text. When the order of the pairs is
  another one, some expressions moved: the expressions outside a longest run
  that keeps its order (`rc_order_moves`). Each pair of a moved expression
  and an expression that is now on its other side is a pass. For a pass:

  - an expression that runs tracked code when it is loaded, a candidate of
    the replay, is evaluated again at its new place (change H4). The check of
    the load order (`rc_order_check!`) takes it, as it takes a text of the
    edit: when its result reads a method that comes after its new place, the
    apply refuses;
  - a plain statement that passed another statement or a definition of a
    binding joins the statement group as a changed statement (D3), with its
    text at its place of before as the old statement. The group makes the
    state of its globals again in the new order, or its check refuses;
  - another expression (a method, a type, a constant with no call) runs no
    tracked code when it is loaded, so its result stays.

  An item of the set `order_moved` is not at its place of before, whatever
  change evaluates it, so the check of the text of before in the program of
  before (`rc_check_again!`) does not take it. The apply takes the items of
  every file when a changed file has expressions in another order
  (`rc_has_order_change`).

  *The gate cases (`order_*` of `gate_cases.sh`, 2026-11-13).*

  | case | the edit | the harness of before | with H4 |
  | --- | --- | --- | --- |
  | `order_macro_use_passed` | moves a method above a use of a macro that asks for it | `plain`, a whole build `wrapped` | applied, `wrapped` |
  | `order_initializer_passed` | moves `pick(x::Int) = 2` above `const PICKED = pick(1)` | 1, a whole build 2 | applied, 2 |
  | `order_initializer_left` | moves it below the constant | 2, a whole build 1 | refused (the check of the load order) |
  | `order_statements_swapped` | swaps two `push!` statements | `(:first, :second)` | applied through the statement group, `(:second, :first)` |
  | `order_include_swapped` | swaps two `include` lines | 1, a whole build 2 | applied, 2 |

  With the harness of before each rebuild printed "applied 0 expressions",
  and the output of all five cases differed from a whole build. With H4 the
  method tables (197 lines), the output (50 lines) and the globals equal a
  whole build.

  *The later names (2026-11-13).* The check of the load order now also
  takes out each name that a later `const`, `global` or type gives its
  module, when no item at or before the place gives the same name
  (`rc_first_places`, `rc_hide_after!`). The name leaves as the name of an
  expression that left does, so the module is as one that never bound it.
  Two cases: `new_reader_of_a_later_name`, an edit that makes the use of a
  macro ask `isdefined` for a constant that comes after it, was applied with
  the harness of before and printed `true` where a whole build prints
  `false`; it is refused now. `order_name_passed`, the constant moved above
  the use, is applied, and the output equals a whole build.

  *A false refusal of the first form, which gate B found.* The print of
  what an `eval` statement defines holds the names of its module, so that
  the trial sees a statement that binds another name. The check takes the
  later names out of the module, so that list differed in the two programs
  by construction, and gate B refused its edit of an `@eval` loop above
  `const NOTE`. A whole build has none of the later names at the place of
  the statement, so the check now leaves them out of both prints
  (`left_out` of `rc_definitions_print`). The case
  `edited_eval_before_a_constant` holds the trap.

  The gate of the edit cases did not see it: it failed on an applied case
  that must be refused, and counted a refusal of any other case. It is
  strict both ways now: a case that `must-refuse.txt` does not name must be
  applied, so a refusal that loses an edit which a rebuild can take is a
  fault too. `baremodule_to_module` (the header of a module, C5) joins the
  list.

  *A definition that moves below a use (2026-11-13).* A `const`, a
  `global` or a type that moves below an item that names it in a signature,
  a field, an initializer or a statement gives a whole build that stops at
  that item, while the process of a rebuild holds the name. The apply now
  refuses such a move (H4), unless an item before the user gives the same
  name. The case `order_definition_left` moves a struct below a method whose
  signature names it: the harness of before applied it ("applied 0
  expressions"), and it is refused now.

  *Its limits.* The check takes no value out that a later statement wrote,
  and a plain statement that calls a function with a later method is not
  checked.

  *The tests of the branch (2026-11-13, the build at d096c893c8 with the
  harness of the build).*

  | test | result |
  | --- | --- |
  | `gate_cases.sh`, 54 cases, through a server and through a child | pass: 45 applied, 9 refused as `must-refuse.txt` says, no fault; 211 method lines, 54 lines of output and the globals equal a whole build |
  | `gate_runs.sh`, through a server and through a child | pass |
  | `gate_prelinked_chain.sh`, `oracle_gate.sh`, `gate_b.sh` | pass |
  | `gate_c.sh` | pass: 48 752 bytes of growth in 18 rebuilds, bound 70 272 |
  | `gate_replay.sh`, 28 commits of the kernel | pass: no refusal; the chain of 28 rebuilds and a new server equal a whole build |
  | `gate_replay.sh`, 17 commits of the platform | pass: no refusal; the chain of 17 rebuilds and a new server equal a whole build in 27 289 method lines, 147 globals and each of 2 268 roots |

  Rule H4 acted on one real commit: in the platform replay one commit moved
  6 expressions, and one of them was evaluated at its new place. The 28
  commits of the kernel move no expression in the load order.

  *The cost of the later names.* In the platform replay the check of the
  text of now ran in 14 of 17 rebuilds and took out 334 to 1 722 names and
  5 135 to 26 062 methods, in 2.5 s to 20.4 s, most often 13 s to 14 s. With
  methods alone it took 1.8 s to 9.4 s. A name costs about 7 ms, because its
  leave invalidates the code that names it. The rebuilds of the platform take
  24 s to 60 s, about 7 s more than without the rule. This is a point for
  Step 8: the check can take out only the names and the methods of the
  modules that the evaluation of the item reads, or take them out in one
  pass with one invalidation.

  *Landed (2026-11-13, with the word of the owner: "yes, land it").*
  `merged-next` moved forward to b592d8a55b, with the libraries and the
  images of the build at d096c893c8, and the caches of the standard
  libraries made again. Checked in the installed Julia: REPL, Pkg and Test
  load in 0.4 s, the print of the harness of the image equals that of its
  folder, and `rc_order_moves`, `rc_drop_dead_roots!` and `rc_first_places`
  exist. Not pushed.

  *The tests of the branch (2026-11-13, the build at 28ef014c3d with the
  harness of the build, PackageCompiler at 588a846e).*

  | test | result |
  | --- | --- |
  | `gate_cases.sh`, 45 cases, through a server with overlays | pass: 39 applied, 6 refused or stopped, no fault, no whole build of the store; 183 method lines, 45 lines of output and the globals equal |
  | `gate_cases.sh`, 45 cases, through a child | pass, with the same counts |
  | `gate_runs.sh`, through a server and through a child | pass: each step as expected, with the step `late`; the four checks equal (75 method lines, 5 roots, 29 lines of output, 13 globals) |
  | `gate_replay.sh`, 28 commits of the kernel | pass: no refusal, no fault; the chain of 28 rebuilds and a new server equal a whole build (3 448 method lines, 13 globals) |
  | `gate_replay.sh`, 18 commits of the platform | 17 applied, 1 refused (finding 53, the known expression), no fault. The refused commit is the last one, so the chain is a whole build of that commit and the comparison tests no rebuild |
  | `gate_replay.sh`, the 17 commits of the platform before the refused one | pass: no refusal, no fault; the chain of 17 rebuilds and a new server equal a whole build (27 289 method lines, 147 globals, each of 2 268 roots) |
  | `gate_prelinked_chain.sh`, `oracle_gate.sh`, `gate_b.sh` | pass |
  | `gate_c.sh` | fails at its step `sizes`, as before: 107 792 bytes of growth in ten cycles, against a bound of 35 136 (finding 24). Its other steps pass. One cause is ruled out: a name of the image holds at most 4 partitions after 20 rebuilds, so the values of before of the changed names do not pile up |

  The two checks of finding 53 for a text of the edit refuse no commit of
  the two replays. Their cost on real commits:

  | | the kernel, 28 rebuilds | the platform, 17 rebuilds |
  | --- | --- | --- |
  | rebuilds that ran the check of the text of now | 1 | 12 or more |
  | methods that it deleted | 2 027 | 5 135 to 26 062 |
  | its time | 0.32 s | 1.8 s to 9.4 s, most often 6 s to 7 s |
  | the check in the program of before the edit | each rebuild, below 0.1 s | each rebuild, 0.5 s on average, 3.7 s at most |

  So a rebuild of the platform that changes an expression with a macro of
  the tracked code takes about 6 s more, of 27 s to 39 s. The time is the
  deletion of the methods: about 0.36 ms for each method in that image. A
  cheaper form deletes only the later methods of the functions that exist
  at the place of the item; it is a point for Step 8, because it needs a
  rule for when a function exists, and a wrong rule misses a read.

  *The comparison of a replay after a refusal (a part of finding 60).* A
  refused commit founds the chain again, as a build of the owner does. The
  comparison at the end then tests the rebuilds after that whole build
  alone. In the platform replay the refused commit is the last one of the
  18, since the check of finding 53 exists (2026-11-12). So the result
  "each check equal" of the platform replays of 2026-11-12 and of this
  round compares two whole builds. The gate now prints how many rebuilds
  the chain holds since its last whole build, and the replay over the 17
  commits before the refused one tests the chain.

  *Landed (2026-11-13, with the word of the owner: "Land and continue").*
  `merged-next` moved forward to 8e3f565fde, with the libraries and the
  images of the build at 28ef014c3d, and the caches of the standard
  libraries made again. Checked in the installed Julia: REPL, Pkg and Test
  load in 0.3 s, the print of the harness of the image equals that of its
  folder, `rc_order_check!` exists, and `x::Int = 1` is a global. Not
  pushed. PackageCompiler `live-harness` (588a846e) is not pushed, so a
  build of the owner has findings 58 and 8 and the mark of a pending
  snapshot only after its push.
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

  *The owner's goal for this part (2026-11-12): a merged branch that gives
  correct incremental builds and passes the tests; a public version is not
  important now.* So Step 5 comes before the steps for the rebuild time.

  *As built (2026-11-12; the Julia fork 6f1972c48c, 637ec89ea8, 871b4ebe58;
  PackageCompiler, branch `live-harness`, 7474fc67 and a8f16459).*

  | finding | what the build does now | where | test |
  | --- | --- | --- | --- |
  | 7 | The trial of the replay evaluates each change in a fork, for each apply that has one. When it stops or ends with no answer, the process evaluates nothing and answers the error. A server whose request fails while its heap holds an apply that no save wrote exits (`RC_APPLY_OPEN`). | `replay.jl`, `child.jl`, `server.jl` | `gate_runs.sh`, step `fail` |
  | 57 (new) | A refused rebuild had written the new lines of the methods of moved expressions, and the new name of a renamed file, before it refused; the next save wrote them. The apply writes them when it begins. | `child.jl`, `place_moves` | `gate_runs.sh`: the steps `order`, `fail` and the comparison |
  | 8 | The whole build records a print of each input: the build of Julia, the project file, the Manifest entry of each package, the preferences files, the workload, each statements file. A rebuild whose inputs differ stops with their names and the option of a whole build. | PackageCompiler `_reactive_inputs` | `gate_runs.sh`, step `input` |
  | 39 | A whole build copies the tracked sources before the first load of the packages, and a rebuild before its request. | PackageCompiler `_materialize_full`, `_materialize_delta` | none of its own |
  | 28 | A rebuild whose code level differs from the level of the whole build prints both. | PackageCompiler `_materialize_rebuild` | none |
  | 29 | A changed signature of a `@ccallable` function is refused (A4). | `child.jl`, `rc_classify` | `gate_cases.sh`, the case `c_entry_signature`, which must be refused |
  | 30 | The server starts with `--gcthreads=1`. | PackageCompiler | none |
  | 34 | The mode of the image write comes from the flag `--reactive-image` alone, so a program loads its image and its chain in one way. | `staticdata.c` | `gate_prelinked_chain.sh`, step `environment` |
  | 36 | An overlay records the checksum of its base image, and the loader stops on another base. | `staticdata.c` | `gate_prelinked_chain.sh`, step `other-base` |

  *Finding 7, before and after.* With the harness of before, the chain of
  the gate holds the method of the failed edit and the lines of the refused
  edit: 10 method lines differ from a whole build. With the apply that is
  all or nothing, the four checks are equal through a server and through a
  child.

  *The tests of the branch (2026-11-13, the build at de6331d52a with the
  harness of the build, PackageCompiler at a8f16459).* The owner asked for a
  branch that passes the tests, so each gate that needs no store of the omnet
  build ran one time, and the tests of Julia itself ran on the fork and on
  the Julia that the fork starts from.

  | test | result |
  | --- | --- |
  | `gate_runs.sh`, through a server and through a child | pass: each step as expected, the four checks equal (74 method lines, 5 roots, 29 lines of output, 13 globals) |
  | `gate_cases.sh`, 37 cases | pass: 35 applied, 2 refused (the header of a module, and the C entry that must be refused) |
  | `gate_replay.sh`, 28 commits of the kernel | pass: no refusal, the chain and a new server equal a whole build |
  | `gate_replay.sh`, 18 commits of the platform | pass: 17 applied, 1 refused (finding 53), each check equal. The refused commit is the last one, so this comparison is of two whole builds (see Step 3, finding 60) |
  | `gate_prelinked_chain.sh` | pass, with the steps `environment` and `other-base` |
  | `oracle_gate.sh` | pass |
  | `gate_i1.sh`, `gate_const.sh`, `gate_e.sh`, `gate_harness.sh`, `gate_server.sh` | pass (on the landed head 06e95728b3) |
  | `gate_b.sh` | its four checks are equal; two expectations were of before this plan and are corrected: a generated function has 2 methods (the definer of a method), and a removed `using` takes its names (D2) |
  | `gate_c.sh` | fails at its step `sizes`: the image grows 104 440 bytes in ten cycles, against a bound of 35 136 (finding 24, open, Step 10) |
  | `gate_d.sh`, `gate_f.sh`, `gate_g.sh`, `gate_h.sh`, `gate_cli.sh`, `gate_i2.sh` | not run: they build in the omnet checkout of the owner |

  Gates B, C and the oracle gate edit `tool/m6_hazard` of their tree in
  place and restore it with git, so they run from a copy of the tools that
  is a git tree of its own, with a link to the `usr` of the build.

  *The tests of Julia.* 33 test sets of `test/runtests.jl` that touch the
  runtime, the compiler and the load of images (core, compiler, worlds,
  rebinding, precompile, reflection, staged, ccall, loading, cmdlineargs,
  misc, syntax, enums, interpreter, opaque_closure, atexit, gc, threads,
  stacktraces, backtrace, docs, exceptions, errorshow, show, namedtuple,
  keywordargs, subtype, specificity, ambiguous, compileall, relocatedepot,
  meta), with 4 workers:

  | | Julia 1.13.0-rc4 (8f33e09afe) | the fork (`merged-next`, 06e95728b3) |
  | --- | --- | --- |
  | tests that pass | 9 770 156 | 9 809 249 |
  | `cmdlineargs.jl:1366` (`--bug-report=rr-local`) | fails | fails |
  | `threads.jl:435` (thread counts under a CPU mask), 3 times | fails | fails |
  | `loading` | passes | passes after `make -f pkgimage.mk release` in the installed tree |
  | `compileall`, alone | passes, peak 10.5 GB | passes, peak 10.7 GB |

  So the fork fails what the Julia of before fails on this machine, and
  nothing more. Two results of the first run were faults of the run and not
  of the fork: the installed tree had the caches of the standard libraries
  of an older image, because a landing copies the libraries and the images
  and not those caches, so `loading` failed three times; and the memory cap
  of the run stopped the process of `compileall`. A landing now makes the
  caches again.

  *Landed (2026-11-13, with the word of the owner).* `merged-next` moved
  forward to the head of the branch (74fe0958b6). The installed tree got the
  three libraries and the six image files of the build at de6331d52a, each by
  a copy and a rename, and then `make -f pkgimage.mk release` there made the
  caches of the standard libraries again (1 min 13 s, peak 4.4 GB). Checked
  in the installed Julia: REPL, Pkg and Test load in 0.3 s, the print of the
  harness of the image equals the print of its folder, and `RC_APPLY_OPEN`
  exists. The overlay header has one more field in a place that was
  reserved, so an old store still loads; but the print of the build of Julia
  is another one, so each store that PackageCompiler of `live-harness`
  rebuilds asks for a whole build. Not pushed.

  *What stays open in this step.*
  - PackageCompiler has the two commits on the branch `live-harness`. The
    build environments of the owner take PackageCompiler from another branch
    by its address, so a real build gets findings 8, 28, 30 and 39 only
    after a push and an update of those environments.
  - The print of the build of Julia is the commit of its binaries. A store
    that was founded by another commit stops and asks for a whole build.
    This is what D5 says, and it ends the rebuild of an old store with the
    harness of a new Julia (Step 4) outside a test: after each landing, each
    store needs a whole build.
  - *Closed on 2026-11-13 (PackageCompiler, branch `live-harness`):* a
    failure of the client after the save of the server (the link of an
    overlay) left a server whose last save the store does not name. The
    session file of the server now holds `pending`, the number of the
    snapshot, from the apply until the store names the snapshot. A build
    that finds the mark starts a new server from the last snapshot of the
    store. A refused apply takes the mark off, because it changes nothing.
    The step `late` of `gate_runs.sh` makes the link fail with a folder at
    the place of its output file.
  - Finding 39 has no test: it needs an edit during a build.
- [x] **Step 6: the definer of a method, and removals (D13, D2; findings 1,
  40, 41, 44, refusal C5).** *Done (2026-11-12): D13 and D2 are built, and
  the replays over the kernel and the platform apply each commit. The owner
  asked for the landing two times on 2026-11-12: `merged-next` got
  8b35e07154, and then the check of finding 53, the gate of the edit cases
  and findings 55 and 56 (95c23ad112), each time with the built libraries
  and images of the commit. One difference from a whole build
  stays, finding 53, which is no part of D13 or D2.* First D13: the two fields of a method, the place
  in the runtime, the ledger by the definer. Test: the case `@steady` of
  `gate_runs.sh`, which the rebuild of today answers with "no method"; the
  replay gates, where the count of the methods of the chain must come to
  that of the whole build. Then D2. Test: the moved function of finding 1; a
  removed struct; a renamed module.

  *D13, as built (2026-11-11; d17f1c03a7 the runtime, 3e06951cc9 the
  harness, on the branch `rebuild-equals-step-4`).*

  - **The runtime.** `Method` has the fields `toplevel_file` and
    `toplevel_line`. The top-level evaluation keeps the place of the
    expression that it evaluates now in two values of the process
    (`jl_toplevel_expr_file`, `jl_toplevel_expr_line` in `toplevel.c`), and
    `jl_method_def` copies them into the method. A count of the open
    evaluations of lowered code tells a line number node of the source from
    one of an expansion. `Core.eval` keeps the place and gives it back; the
    C loader of a file sets it for each form; the body of a module gives
    the place of the module expression back.
  - **A direct test** (`replay/definer_test.jl` of the session) loads two
    files and checks 16 cases: a plain method, a documented one (the line
    of the docstring), a method of an expansion (the place of the user, the
    text in the macro file), a method of an `@eval` in a loop (the place of
    the loop), a method in a module, a keyword method with its body and its
    closure (one place), a macro that returns top-level forms with its own
    lines (the place of the call), the constructors of a struct, a
    generated method and the method of its generator, a method after an
    `include` (its own line again), and a method that the program defines
    outside a top-level evaluation (no place). All pass. Each of the 10 079
    methods of Base has a place.
  - **The harness.** The ledger takes the methods of an item from the
    definer (`rc_methods_by_definer`, `rc_assign_methods!`): the methods
    whose top-level place is the file and the first line of the item.
    `rc_owns`, which gave a macro its methods by their names, is gone. The
    harness evaluates an item with its place (`rc_evaluate_item`). A kept
    method takes both places of the new definition. An unchanged item that
    moved gives its new first line to the methods that it defined, and its
    shift to the methods whose text is inside it (`rc_methods_by_text`). The
    methods on a changed type count as inside when a tracked expression
    defined them: a method that a macro of another package made no longer
    refuses the change, as it did for 1df4c59c8 in the chain of the kernel.
  - **The oracle** prints the definer in each method line, so each gate
    compares it with the whole build.
  - **The gate.** `gate_runs.sh` has the case `@steady` again. The rebuild
    says `change A2 helpers.jl:53 steady_code, 1 methods`, with no method
    deleted, and `steady_value()` gives 7. The gate passes in both forms,
    with each step as expected and the four checks equal (37 methods with
    their definers, the roots, 19 lines of output, 13 globals). After the
    step `move`, the moved function has the definer `lines.jl:6` in the
    chain and in the whole build.

  *The replay gates with D13 (2026-11-11).* Each method line of the oracle
  holds the definer now, so the comparison is more strict than before. The
  counts of the kernel of before D13 are also of before the two repairs of
  the oracle, which took 20 lines away.

  | | the kernel, 28 commits | | the platform, 7 commits after a whole build | |
  | --- | --- | --- | --- | --- |
  | | before D13 | with D13 | before D13 | with D13 |
  | methods of the chain | 3 524 | 3 455 | 27 400 | 27 352 |
  | methods of the whole build | 3 449 | 3 449 | 27 350 | 27 350 |
  | method lines that differ, one server | 129 | 39 | 52 | 4 |
  | method lines that differ, a new server | 80 | 30 | 49 | 2 |
  | methods that the chain lacks, other than the moved `search_documents` | 2 (one server), 4 (a new server) | 0 | 0 | 0 |

  The constructors of `RootedOperation` and the four `getproperty` methods
  are there. What still differs has three causes, and one of them is new:

  - *Finding 1, for D2:* `search_documents` is still in the module that it
    left, with its keyword methods and the closures of the old functions
    (most of the 39 lines of the kernel); the constructor of a struct that
    a commit removed stays (`_PlaceBlocks`, 1 line of the platform).
  - *A fault of the first form of D13, corrected:* the forms in the body of
    a module with a docstring had the place of the docstring. A docstring
    is a macro call, and the body of the module is inside its result, so no
    line number node of the body set the place. In the whole build
    `ReferenceModule.__init__` had the definer `ReferenceModule.jl:1`, and
    in the chain, where the harness evaluated it with its place, line 145;
    a closure of a statement of such a body stayed after its statement was
    evaluated again (`KernelModule.jl:1`, `PlatformModule.jl:16`). The body
    of a module now sets the place also inside a macro call: the ledger
    takes the forms of such a body as items too.
  - *Finding 47, new:* the three log functions of the kernel and one of the
    platform have other code in the chain of one server, and the same code
    from a new server.

  *Finding 47: the id of a log statement counts its expansions.* A log
  macro gives its statement an id: the hash of the module, the level and
  the message, and the next free number when the registry of the process
  already holds that id (`Base.CoreLogging.log_record_id`). A whole build
  expands each statement one time in the process that compiles its package.
  A server evaluates `_notify_evaluation` at each commit that moves it, so
  the id in its code is the second or the third one. The replay has the
  same fault in its prints: two expansions of one user of a macro whose
  expansion holds a log statement never compare equal. *As built, by the
  assistant:* the evaluations of one apply share one registry of log ids
  that starts empty, as the forms of a package do, and each print of the
  replay has its own (`rc_with_fresh_log_ids`). The limit: two statements
  of one package with the same module, level and message keep one id when
  only one of them is evaluated again.

  *The failed rebuild of the platform, the second time.* The rebuild of
  00d0f77e0 no longer stops with the `TypeError` of finding 46. It stopped
  at the new check of a stopped trial: the trial refused `B2 Geometry.jl:8
  Inset: the untracked Theme.jl:86 convert names the type`, and the apply
  did not. The trial evaluates a statement that defines methods to take
  its print, and it did that with no place, so the kept method got the
  place of the script of the server as its definer, and then counted as a
  method of no tracked file. Each evaluation of the trial has the place of
  its item now (`rc_evaluate_at`). `gate_runs.sh` has a statement that
  defines a method on the type that the edit changes.

  *The two corrections, seen to fail first.* Through a server, with the
  harness of before the place in the trial, the first rebuild of the gate
  stops as the rebuild of the platform did: `the replay stopped (B2
  helpers.jl:15 Theme: the untracked users.jl:64 theme_height names the
  type (found in the apply)) and the apply did not`. With the rule of the
  log ids taken out, the gate ends with one method of other code in the
  chain, `logged_line`.

  *The kernel again, with the corrections.* The chain of one server has
  3 454 methods against 3 448, and 30 method lines differ; a new server
  gives 3 451 and 27 lines. 24 of the lines are the moved
  `search_documents`. The others are closures with the place
  `ReferenceSearch.jl:17`, which is no first line of an expression in the
  last commit: an expression that a commit removed left them. No log
  function and no method of the body of a module differs. What stays is
  for D2.

  *The platform again, with the corrections.* The rebuild of 00d0f77e0, the
  commit that changes `ReactiveCell`, applies now. The gate still counts it
  as a fault, for another reason: `overlay_check.py` finds wrong entries in
  its overlay (finding 48), so the store founds again there. For the seven
  commits after it, one method line differs from the whole build, in the
  chain of one server and from a new server: the constructor of the struct
  `_PlaceBlocks`, which a commit removed (finding 1, for D2). The names,
  the 148 globals and the roots are as before.

  *Finding 48: the overlay of a large rebuild has stale root tables.* The
  check of the overlay of 00d0f77e0 says: `root tables: 857 grew inside
  their memory, 2 of them hold stale bytes`. The overlays of the 17 commits
  before it have none (128 grown tables in the one before). This is the
  kind of fault of finding 33, which Step 1 closed for the case that it
  had; two tables of 857 still lose a write. The replay gate keeps the
  images of a rebuild that goes wrong now (`$OUT/fault-<n>`), for a look
  at the two tables.

  *Gate C with the installed harness (finding 24).* After a `make`, the
  rebuilds of gate C load no sources of the harness. Ten cycles give
  108 120 bytes of growth between the first and the last reverse, against
  a bound of 35 136: about 6 KB for each rebuild, as on 2026-11-09. Each
  rebuild adds 45 slots and about 54 objects of the image; the function
  count stays (39 660 text symbols). Two rebuilds with no edit add 70 KB
  and 4 KB, and the next cycle takes 56 KB away again: the size of the
  image data moves by tens of KB between two rebuilds with no growth of
  what the program holds. What the 54 objects are is not found; the writer
  has no count by type. It stays open, for Step 10.

  *D2, as built (2026-11-11; c337037a86 the runtime, 54f9305f14 the
  harness).* The test that fails first is the file `moved.jl` of the gate
  program:

  ```julia
  module Left;  export travel;  travel() = 1;  end   # the edit moves travel to Right
  module Right; export stay;    stay() = 2;    end
  module Both;  using ..Left, ..Right;  journey() = travel() + stay();  end
  module Onlooker;  using ..Right;  end              # the edit removes the using line
  struct Gone;  value::Int;  end                     # the edit removes these two
  const GONE = Gone(1)
  module Before;  inside() = 4;  end                 # the edit names it After
  ```

  | | a whole build | the rebuild, before D2 |
  | --- | --- | --- |
  | `Both.journey()` | 3 | `UndefVarError`: two modules export `travel` |
  | `names(Left)`, `isdefined(Left, :travel)` | no `travel`, false | `travel`, true |
  | `Gone`, `GONE`, `Before` in the package | not there | all three there |

  - **The methods.** Each removed expression is a removal of the methods
    that it defined: also a struct with its constructors, a constant with
    the closures of its initializer, and a statement that defined methods.
    Before, only a method was one. D13 gives these methods; the lines of an
    expression could not.
  - **The names.** The names that the removed expressions gave their
    modules leave when no expression of the edited sources gives them again
    (`rc_name_removals`, `rc_remove_name!` in `child.jl`). A type, a
    constant, a global, a function, a macro and a module lose their binding
    (`Base.delete_binding`); a function goes only when the module defined
    it, so a method that extended a function of another module takes
    nothing with it. An exported name loses its export; a name of a `using`
    with names or of an `import` loses its binding; a `using` line with no
    names loses its entry in the using list. The names inside a removed
    module go before the module. An expression that moved to another file
    of the same module gives its name again there, so the name stays.
  - **The runtime** has the two functions of the decision
    (`jl_reactive_module_unexport`, `jl_reactive_module_unuse` in
    `src/module.c`). Each one makes its change in a new world, and the
    names that came through the export or through the using list resolve
    again, as they do when an `export` or a `using` is added.
  - **A renamed module** is the removal of the old module and a new module.
    A header that changes and keeps its name (`module` to `baremodule`) is
    still refused with C5: the expressions inside have the same path and
    the same text, so nothing says that they must be evaluated again.
  - **The gate** passes in both forms, with each step as expected and the
    four checks equal (46 methods, the roots, 25 lines of output, 13
    globals). The rebuild says, for one edit: `the exported name travel
    leaves RunLib.Left`, `the bound name travel leaves RunLib.Left`, `the
    using leaves RunLib.Onlooker`, `the bound name Gone leaves RunLib`, and
    so on, with `change B2 moved.jl:27 Gone (removed), 2 methods deleted`.

  *The replay over the kernel with the removals, and the names that
  change their source (2026-11-11; findings 49 and 50).* The same 28
  commits of the kernel, with D2 in the harness. The image of the chain is
  the image of a whole build for the first time: 3 448 method lines, the
  output and the 13 globals are equal, for one server and for a new server.
  But three commits did not apply, and the gate made a whole build for each
  one. All three move `search_documents` between `DocumentModule` and
  `ReferenceModule`, which imported it by its name:

  ```julia
  # before the commit                           # after the commit
  module ReferenceModule                        module ReferenceModule
  using ..DocumentModule                        using ..DocumentModule
  import ..DocumentModule: search_documents     export search_documents
  end                                           search_documents(obj, predicate) = ...
                                                end
  ```

  | commit | the direction | the rebuild, before | a whole build |
  | --- | --- | --- | --- |
  | a375217d6, 660b68779 | to the module that imported it | fails: "exported function DocumentModule.search_documents does not exist" | `ReferenceModule` has its own function |
  | 55d18341c | back to the module that it came from | refused, C3: "the module binds search_documents already" | `ReferenceModule` imports the function |

  D2 as built took a name of an import out only when no expression of the
  edited sources gave the name in any way. Here an expression gives it in
  another way: the module defines it now. The model is the one of D2,
  stated for this case too: *after the apply, each name of a module has the
  source that the edited sources give it, and each expression that
  resolves a name in another way than before is evaluated again.*

  - **An import that left takes its name with it also when the module
    defines the name now.** A method or a macro of a name that the module
    imports is a method of the function of another module, so it binds no
    name; the binding of a function that the module defined goes when the
    module imports the name now (`rc_given_names`, `rc_name_removals`).
  - **A name that an import of the edited sources gives again** stays
    until that import is evaluated. The import of before goes there, and
    only when the import of now names another binding, because Julia
    ignores an import that conflicts with one that exists
    (`rc_drop_replaced_imports!`). So an import line that gets one more
    name takes no name out, and no code that uses the other names is
    compiled again. The first import of the load order that gives a name
    decides it, as in a whole build.
  - **The check of an import against the names of its module** (the C3
    refusal) runs after the name removals are known, and does not count a
    name that the apply takes out before the evaluation
    (`rc_refuse_import_conflicts!`). An import of a name that the module
    still defines by an expression that stays is refused as before.
  - **How the names resolve is recorded before the removals** and compared
    after them, in every module when a name leaves a module, and as before
    in a module with a changed `using` (`rc_record_resolutions!`,
    `rc_enqueue_resolved_differently!`). Each expression that resolves a
    name in another way joins the queue at its place in the load order. A
    method that an unchanged expression gave the imported function is
    defined again for the function of its module, and the method of before
    is deleted. A method of a third module that names a moved struct in its
    signature is defined again for the struct of the new module (finding
    50). An expression that only calls a moved function is evaluated again
    too; the filter keeps its method, because the code and the signature
    are the same.

  The gate program has both cases in `moved.jl`. The modules `Early` and
  `Late` hand over two functions, one in each direction, and `Late` gives
  each one a method whose text stays. The module `Left` gives the struct
  `Token` to `Right`, and `Both` names it in a signature. With the harness
  of before, the rebuild of the first case fails with the error of the
  kernel commits, and the second case prints `token = MethodError of
  Right`, where a whole build prints `token = 8 of Right`. The rebuild
  says now: `the imported name carry leaves RunLib.Late`, `the bound name
  bring leaves RunLib.Late`, `change C3 moved.jl:46 carry (resolves carry
  differently), 1 methods, 1 deleted`, `change C3 moved.jl:21 weigh
  (resolves Token differently), 1 methods, 1 deleted`, `change C3
  moved.jl:20 journey (resolves travel differently), 1 methods, 1 kept`.

  *A defect of Julia in the way (finding 51).* With the two corrections
  the gate passed, and the three commits of the kernel still failed, with
  "MethodError: no method matching string(::Expr)" in the definition of the
  moved function. The cause is in Julia and not in the fork. When a binding
  changes, `invalidate_code_for_globalref!`
  (`Compiler/src/bindinginvalidations.jl`) resolves the name again in each
  module that uses the module of the binding, and goes on to the modules
  that use that one. Two cases bring it to a partition that it must not
  walk, and an assertion fails; the text of the assertion is made in the
  world of the compiler, which has no `string` for it, so the person sees
  the `MethodError`.

  ```julia
  # 1. modules that use each other          # 2. a module that imported the name before
  module P                                   module Source; export moved; moved() = 1; end
  module R; export f; end                    module User; using ..Source; import ..Source: moved; end
  module K; using ..R; using ..P; export f; end   Base.delete_binding(User, :moved)
  using .K; export f                         Base.delete_binding(Source, :moved)
  end                                        isdefined(User, :moved)
  isdefined(P.K, :f); isdefined(P, :f)       @eval Source global moved
  @eval P.R global f     # fails             @eval Source moved() = 2     # fails
  ```

  | | Julia 1.13.1, and the fork before | the fork now |
  | --- | --- | --- |
  | case 1 | `MethodError: no method matching string(::Expr)` | `P.K.f()` and `P.f()` give 1 |
  | case 2 | the same error | `User.moved()` gives 2 |

  - *Case 1.* The pass comes back to a binding that it resolved already in
    this pass. The kernel has the cycle: `KernelModule` uses each module of
    its parent, the parent is among them, and the parent uses
    `KernelModule`. The pass now skips a partition that starts after the
    world of before the change (ec197346b0).
  - *Case 2.* Only an explicit import records an edge on the binding that
    it imports, and the edge stays when the import goes. The pass queued
    such a binding with its latest partition as the old and the new one,
    and then closed that partition. The loop over the edges now skips a
    binding whose latest partition is an implicit import; the loop over
    the modules resolves it (4f46c3669b).
  - `test/rebinding.jl` has both cases and passes 76 of 76. A report of the
    two cases to upstream Julia is a decision of the owner.

  *One fault of the first form of the check for every module.* It read the
  module that binds each name of each expression. Julia refuses that for a
  constant that a module takes from several modules ("Constant binding was
  imported from multiple modules"), and the platform has such constants:
  four rebuilds of the platform chain failed. The check now records only
  the names that leave, in every module, and each name in a module with a
  changed `using` or with a `using` that left. A constant is compared by
  its value and a global by the module that binds it (`rc_resolved`): two
  modules that give a function or a type of one name give two values.

  *The replay over the kernel with all corrections (2026-11-11).*

  | | before D2 | D2 as built | with findings 49 to 51 |
  | --- | --- | --- | --- |
  | commits that the chain applied | 28 of 28 | 25 of 28 | 28 of 28 |
  | refused, failed | 0, 0 | 1, 2 | 0, 0 |
  | method lines that differ, one server | 39 | 0, after 3 whole builds | 0 |
  | method lines that differ, a new server | 30 | 0, after 3 whole builds | 0 |
  | output, globals | equal | equal | equal |

  This is the first replay over real commits in which each commit applies
  and the image of the chain is the image of a whole build. The control
  still shows 1 fact that differs between two whole builds of one commit
  (the place of `Base.Enums._enum_hash` for `_CellState`), and the roots
  differ in 23 of 300 tables, counted and not failed.

  *The chain of 18 commits of the platform, to the commit that changes
  `ReactiveCell` (e0f6014fb to 00d0f77e0), with all corrections.* Each of
  the 18 rebuilds applies, with no refusal and no fault, and the overlay
  check of each one is clean. The last rebuild evaluates 2 294 expressions
  in 2 min 33 s. This chain is the one that showed finding 48 the day
  before: then 2 of 857 root tables held stale bytes, with the constant
  data 384 bytes into a page; now 0 of 862 do, with the constant data
  2 688 bytes into a page. One rebuild of that commit from a whole build
  of the commit before it is clean too. So finding 48 is not reproduced in
  two tries, and it stays open: the place of the constant data in its page
  is the one difference that the two runs show.

  *The gate* passes through a child and through a server with the last
  form of the harness: each step as expected, and the four checks equal (58
  method lines, 3 roots, 27 lines of output, 13 globals). With the harness
  of before finding 49 the rebuild of the gate edit is refused ("the module
  binds bring already").

  *The replay over the platform with the comparison (2026-11-11).* The
  chain of 18 platform commits ran with the whole gate: the last commit
  founded at a whole build, a control build, and the comparison.

  | | harness a57094b4d1, 18 commits | with finding 52, the last commit alone |
  | --- | --- | --- |
  | commits applied, refused, failed | 18, 0, 0 | 1, 0, 0 |
  | method lines that differ, of 27 297 | 24 | 5 |
  | globals (147), roots (2 268) | equal, 1 136 roots differ | equal, 0 roots differ |
  | methods that the program counts | 23 822, as the whole build | 23 824 against 23 822 |

  All 24 lines come from the last commit, which changes `ReactiveCell`: the
  rebuild evaluates 2 294 expressions. A replay over 25 commits did not show
  them, because its store founded again by itself one commit later. The 24
  lines have four causes, and the work on them closed three older findings
  too. The paragraphs below give each one; the last table of this part has
  the result with all corrections.

  *Finding 52: a name that the call of a macro binds.* 13 lines are
  methods with a type of before in their signature
  (`@world(ScaledConversationTheme, 39978:53111)`), and 6 are the methods
  of the aliases `ICCellVector` and `MCCellVector`, which
  `@document struct CellVector` defines. The harness took the dependents of
  an evaluation from the one name that the source of the item shows.

  ```julia
  @theme struct ConversationTheme … end       # binds ConversationTheme and ScaledConversationTheme
  AgentWorkToWidget(theme::Union{ConversationTheme, ScaledConversationTheme}) = …
  # ReactiveCell changes → ScaledConversationTheme is a new type, ConversationTheme stays
  # before: the method keeps the type of before        now: the method is evaluated again
  ```

  *The constants that an evaluation binds again, as built (decided in the
  build, by the assistant).* After the evaluation of an item, the harness
  reads the bindings of the module of the item (`rc_rebound_constants`): a
  constant whose partition started after the world of before the
  evaluation, and whose value is not identical to the value of that world,
  is bound again. Julia starts no partition for an identical value, so a
  struct that is defined again with the same fields is not in the list, and
  an alias of the same structure is not. A constant that Julia dates back to
  the worlds before its definition was no constant there
  (`rc_constant_in`). Each such name gives its dependents:
  - the items that resolve the name into what they define, from one index
    of the items by name for each apply (`rc_items_by_name!`): a name of
    the signature, of the fields or of the initializer, and the function or
    the type of a method definition, so a method of an alias follows the
    alias;
  - when the value of before is a type as its definition made it
    (`rc_is_defined_type`), the methods that mention that type in their
    signature, as before; a method of an untracked file refuses the apply.
  A global that is no constant keeps the rule by the name of its item,
  because its value can change with no new binding. The rule replaces the
  two rules of before: a type by the name of its item, and each constant
  item with no check of its value. The module of the item is the limit: a
  constant that an evaluation binds in another module through `eval` is not
  read.

  *The gate case.* A macro of `markers.jl` defines two types and an alias
  from one struct (`@paired struct Badge`: `Badge`, `ScaledBadge`,
  `MarkedBadge`). The second type has a field of the type `Marker`, which
  the step `retype` changes. `users.jl` has a method that names the second
  type in its signature and a method of the alias. With the harness of
  before, the binary prints `badge = MethodError` after the step `retype`.
  With the rule, each step is as expected through a server, and the four
  checks are equal (67 method lines, 3 roots, 28 lines of output, 13
  globals).

  *A fault of the oracle.* One line is the method `print_document` of a
  tree, with the same statements on both sides. The lowering keeps a
  function with no name that captures a variable in a slot whose name is the
  gensym counter alone (`Symbol("1843")`), and the digest of the oracle did
  not drop that counter. It does now (55531e697c).

  *Finding 54: a deleted method that an overlay keeps.* The program counts
  2 methods more than a whole build: `_make_row_band` and
  `make_slot_store_operation` with types of before in their signatures,
  closed by the apply. The save takes a closed entry out of its chain by a
  recorded change of the pointer that leads to it (`record_field_change`),
  and a save by pages or as an overlay writes only the objects of the pages
  that the process wrote. A pointer in an object of another page kept the
  bytes of the base. Dispatch does not use a closed entry; `Base.visit` and
  the count of the program do. `reactive_pages_begin` now marks the page of
  each recorded field change inside the tracked region (d7a821790b). The
  changes that the walk of the save records later (the chain of the code
  instances of a method instance, the lists of a module) are not marked:
  no run showed a code instance of this kind. The run that kept the 2
  entries, made again on the new runtime, writes 1 page more "for a field
  that the save changes", keeps no closed entry, and the program counts
  23 822 methods, as a whole build. The fault needs an object on a page that
  the process did not write, so it shows in some runs only: the same commit
  with the harness of the build keeps no entry with or without the rule.

  *Finding 10 shows in the roots, and the rule of finding 52 closes its
  first part.* The founding precompiles the trace through the harness, so
  its image holds the table from the text of each statement to the type
  that the text gave (`RC_TRACE_CACHE`), and the statements that failed
  (`RC_TRACE_FAILED`). A server that starts from that image precompiles a
  statement by a lookup in the table. After the rebuild that changes
  `ReactiveCell`, each statement that names a changed type has the same
  text, and the table gives the type of before.

  | the one commit, from a whole build of the commit before | harness of the build | harness loaded from its folder |
  | --- | --- | --- |
  | statements precompiled, not resolved | 1 754, 514 in 12.7 s | 1 861, 407 in 27.0 s |
  | method instances that the trace made | 23 696 | 44 344 |
  | roots that differ from a whole build, of 2 268 | 1 136 (1 131 absent) | 0 |

  A harness that is loaded from its folder is a new module with an empty
  table, so it resolves each statement again. This is why the run with
  `JULIA_REACTIVE_HARNESS` hid the fault, and why a build of the owner,
  which uses the harness of the build, has it: the program compiles half of
  its roots again at each start after such a rebuild.

  *The table of the statements, as built (decided in the build, by the
  assistant; it is the first use of D10 in a wider form).* What the
  session keeps of the statements holds for one state of the bindings. When
  an evaluation gives a constant another value (`rc_rebound_constants`), or
  a name leaves a module, the harness drops the table and the statements
  that failed (`rc_forget_statements!`). A new name drops only the
  statements that failed, and a name that Julia generates drops nothing: it
  has a counter, and no statement of before names the new one. D10 asks for
  a test of each kept type ("a type is dead when its name no longer gives
  it"). The rule here drops the whole table in the same case, and it also
  covers a statement that names a function or a constant with another
  value. Step 10 can replace it with the test of D10 when it builds that
  test for its two other uses. Findings 11, 25 and 27 are not touched: a
  statement whose text is no longer right stays lost.

  *The gate case.* The program calls `badge_sum` through `invokelatest`,
  so the trace has the statement
  `precompile(Tuple{typeof(RunLib.badge_sum), RunLib.ScaledBadge{Int64}})`,
  and the step `retype` gives `ScaledBadge` a new identity. A plain call or
  a call behind `Base.inferencebarrier` gives no statement: Julia compiles
  the one method into its caller. With the harness of the build of before,
  the server log has `rc: trace unresolved` for the statement, and the
  roots check of the gate fails: the root is absent in the chain and
  compiled in the whole build. The fault shows only with the harness of the
  build, so this case needs a gate run with no `JULIA_REACTIVE_HARNESS`.

  *Finding 48 is a fault of the check (2026-11-12).* The run that tested the
  table of the statements stopped at the overlay check: `root tables: 1171
  grew inside their memory, 2 of them hold stale bytes`, with the constant
  data 3 072 bytes into a page. The gate kept the two images this time.

  ```
  root table of method at 155193808: length 2 -> 4, new elements [0, 2],
      base bytes there [0, 2], roots of the base 2
  ```

  A process that precompiles no package gives a method one block of roots
  with the key 0, which starts after the roots of the base
  (`add_root_block` in `method.c`). So the two new elements of a grown
  table are known: 0 and the count of the roots of the base. All 1 171
  grown tables of this overlay have exactly that block. In 1 169 the base
  holds other bytes at that place, and in 2 it holds the same two numbers,
  in the unused part of the memory of the table. The check counted a table
  as stale when its new bytes equal those of the base, so it failed on
  those 2. The overlay is right. The check now compares the new elements
  with the block that they must be (82d3089eaa), and passes on the kept
  images. A table that grew by more than one block, or whose count of roots
  the check can not read, keeps the rule of before. The first sighting had
  the same count of 2 and no detail; the two tries that did not reproduce
  it had no table over equal bytes.

  *Finding 53: an expression that is evaluated again sees the definitions
  that come after it.* 4 lines are methods that
  `@document struct CellVector` defines at line 32 of `CellVector.jl`, with
  other code than in a whole build.

  ```julia
  @document struct CellVector{T} <: ListDocument      # line 32
      elements::Vector = Cell[]
  end
  get_cell_layout_field_type(::Val{:Vector}) = CellVector   # line 150
  ```

  The macro asks `get_cell_layout_field_type(Val(:Vector))` for the field.
  A whole build expands line 32 before line 150 exists, so the field holds
  a plain vector. The rebuild expands line 32 again in a process that holds
  the whole program, so the answer is `CellVector`, and the constructor
  wraps its own vector.

  | `CellVector(Any[1, 2])` | result |
  | --- | --- |
  | in the image of a whole build | a list of 2 elements |
  | in the image of the rebuild | `DeclaredTypeMismatchException` |

  So the rebuilt program is wrong, and not only another image. The fault is
  older than this work: the header of `replay.jl` names the limit ("the
  replay runs in a world that holds the whole program"), and the run with
  the harness of before has the same 4 lines. No expression of the two
  replays showed it before, because the gate program counts names and
  methods and calls nothing of the platform. Of the 2 309 expressions that
  this rebuild evaluated, this is the only one whose methods differ from
  those of a whole build.

  A live process can not give an expression the state of its place in the
  load order: each method of the base has the world of the load. So the
  rule that is in reach finds such an expression and refuses the apply; the
  store then founds again, which is always right.

  *The check of what the apply evaluates again, as built (proposed by the
  assistant; the owner said "continue finding" to it on 2026-11-12).* The
  trial of the replay writes a line for each change that evaluates an item
  with the text of before: a dependent, a candidate whose result differs, a
  moved expression. The process then runs a second fork, in the state of
  before the changes (`rc_check_again!`, `rc_again_check!` in `replay.jl`).
  The fork evaluates each of those items in the load order, and compares
  the methods that the evaluation defines with the methods that the program
  holds for the item (`rc_methods_print`): the signature and the lowered
  code of each method, with a type on which the item defines methods
  counted by their code, so a function with no name is the same at each
  evaluation. An item that throws there, or that defines other methods, is
  a refusal with the id of its change: "its evaluation in the program of
  before the edit defines other methods than the program holds for it; only
  a whole build evaluates it at its place in the load order". The refusal
  names the first item in the load order; the log names the items after it
  that differ too, because the fork keeps what it evaluated. A check that
  ends with no answer is a refusal. A moved item is evaluated with its
  expression of before.

  *Its limits.* The check compares methods and not the value of a constant
  or the effect of a statement: D1 and D3 have those. An item whose text
  the edit changes has no result of before, so a new dependence on a later
  definition in an edited text is not found. The check costs one more
  evaluation of each item in a fork.

  *The gate case.* `order.jl` of the gate program has the use of a macro
  that asks a function for a layout, and the method that gives the answer
  for that name comes after the use. The step `order` changes a struct that
  the use names in a signature. With the harness of before, the rebuild
  passes and the program prints `layout = wrapped`, where a whole build
  prints `plain`. With the check, the rebuild is refused with the reason
  above, the program stays as it was, and the four checks are equal (74
  method lines, 5 roots, 29 lines of output, 13 globals). The three
  rebuilds before that step check 20, 2 and 4 expressions and name none.

  *On the platform (the commit that changes `ReactiveCell`, from a whole
  build of the commit before).* The check evaluates 2 296 expressions in
  60 s and names 7: `CellVector.jl:32`, and the six methods of the aliases
  `ICCellVector` and `MCCellVector` in the lines after it, which follow
  from it. It names no expression with no need. The rebuild is refused, and
  the whole build that follows has the right `CellVector`. So a change of
  the cell core of the kernel now costs a whole build and gives a right
  program; an edit that does not make the rebuild evaluate line 32 again
  is not touched. The platform can also make line 32 independent of the
  load order, and then such a rebuild applies.

  *The two replays with the check (the harness of the build at
  7b469b9767).* Over the 28 commits of the kernel, the gate passes with no
  refusal: the chain of one server and a new server equal a whole build
  (3 448 method lines, the output, 13 globals). Over the 18 commits of the
  platform, the gate passes for the first time: 17 commits apply, the
  commit that changes `ReactiveCell` is refused for `CellVector.jl:32` and
  founded again, and the method tables (27 295 lines), the output, the 147
  globals and all 2 268 roots equal a whole build. So the check refuses no
  commit of the two replays with no need.

  *The replay over the 18 platform commits with all corrections
  (2026-11-12, the harness of the build at 86b5d06977, the runtime at
  d7a821790b, the check at 82d3089eaa).*

  | | 2026-11-11, harness a57094b4d1 | with all corrections |
  | --- | --- | --- |
  | commits applied, refused, failed | 18, 0, 0 | 18, 0, 0 |
  | method lines that differ, of 27 297 | 24 | 4, all of finding 53 |
  | output of the program, globals (147) | equal | equal |
  | roots that differ, of 2 268 | 1 136 | 0 |
  | closed entries in the method table | 0 | 0; 17 of the 18 saves wrote a page for a field that the save changes |
  | the overlay check of the last rebuild | not run with the new rule | 1 161 grown tables, each with its new block |
  | the last rebuild | 2 294 expressions in 2 min 37 s | 2 309 expressions in 3 min 9 s, 1 876 statements precompiled |

  The last rebuild takes 32 s more: it evaluates 15 expressions more, and
  it compiles the roots of the changed types, which the rebuild of before
  left to each start of the program. The step `fresh` of this run founded
  again by itself (the image grew 58.3 %), so no new server applied the 18
  changes at once; `JULIA_REACTIVE_COMPACT` can give a run with that
  comparison. The gate ends with a failure, as it must while finding 53 is
  open.

  *Open, from this work.* A plain statement that names a moved name is
  evaluated again like each other expression, and what it did before is
  not taken back: D3 takes back the statements that changed or left, and
  this one has the same text. No commit of the two replays has such a
  statement. The check of an import against the names of its module reads
  the form `import A: f` and not the form `import A.f`.

  *A trap of the build.* A change of the layout of `Method` needs the image
  files of the build made again from the compiler: `sysimage.mk` makes the
  compiler image from the sources of the compiler only, so a `make` loaded
  the image of the old layout with the new runtime and waited on the lock
  of a method without end. Before the `make`: remove
  `usr/lib/julia/basecompiler*`, `sysbase*`, `sys-o.a` and `sys.so`. The
  same is needed in the worktree of the installed Julia when this lands.

  *Limits.* The place is one value of the process (D13). The package patch
  of Stage J (`patch.jl`) records the moved lines of the text of a method
  and not yet the moved line of its definer; Stage J is not in this plan.
- [x] **Step 7: the code that an item runs (D1, D3; findings 2 to 6, 9, 20).**
  The replay of D1. The groups of the statements. The read rule skips
  `/proc`, `/sys` and `/dev`. Test: `tool/gate_runs.sh`, the tests of Step 3,
  and the count of items that the replay gate evaluates with no need.

  *Done on the branch `rebuild-equals-step-4`, which is not landed. The open
  points are at the end of the step. The first form of D1, the reach by
  name, was measured and does not hold. On 2026-11-10 the owner approved the
  replay in its place, and D1 now states it. The reach left the tree
  (`reach.jl`, `tool/reach_report.jl`); the commit 253973cd88 holds it.*

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

  *The statements, as built (D3; `rc_statement_group!` in `child.jl`,
  `rc_check_statement_group` in `replay.jl`).* A *statement* here is a
  top-level expression of another form that holds no macro call and no
  `eval`, and is no `precompile` call: `push!(REGISTRY, :a)`,
  `SEEN[:a] = 1`, a loop of such calls. When an edit changes or removes one:

  - the definition of each tracked global that the old or the new statement
    names joins the changes, with the id `S1`. Its evaluation makes the
    global again, and the rule of the dependents of a binding then runs each
    statement that names it, in the load order. A statement that names one
    of these globals brings the other globals that it names;
  - a statement that names no tracked global is refused with `S1`: the
    rebuild can not take back what it did.

  *Added in the build, by the assistant: the check of the group.* Before the
  changes, the fork of the replay evaluates the definitions of the group
  again with the statements of before the edit, and takes the print of the
  value of each tracked global before and after. A global that gets another
  value has a writer that the names do not show, and the rebuild is refused
  with `S1`. A fork that gives no answer is a refusal too, when the edit has
  such a group.

  *The limit that stays.* A statement can write, by a key, into a table that
  it does not name: `register_palette!(RADIX_PALETTE)` writes into the table
  of the palettes. When such a statement changes, the old entry stays, and
  the check does not see it, because the old statement writes the same
  entry again. The IDE has 8 statements of this kind.

  *The gate with the statements.* `tool/gate_runs.sh` has a third file,
  `statements.jl`: a list that two statements fill, a table that one
  statement fills, and a call that writes into a list that it does not
  name. On the harness of before the rule, the rebuilt program printed
  `registry = first second third` and `seen = 1`. With the rule it prints
  `first third` and `0`, as the whole build does; the rebuild says `S1` for
  the two definitions and runs `push!(REGISTRY, :first)` again. The step
  `refuse` changes the call that names no global: the rebuild is refused
  with `S1`, and the program stays as it was. The chain equals the whole
  build in the four checks (23 methods, the roots, 15 lines of output, 12
  globals). The gate passes in both forms: through a child with whole
  images, and through a server with overlays.

  *The other gates with the statement rule in the harness.*

  - Gate I1 (`gate_harness.sh standard`) passes through a server and through
    a child: the four checks are equal. The overlays have 24.5 MB and
    24.1 MB with loaded sources, where they had 23.5 MB and 22.5 MB before
    the rule. The rebuilds took 11.4 s and 6.3 s in a server and 6.5 s in a
    child. These times do not compare with the times above: each part took
    about two times as long as before, also the parts that the rule does
    not touch (the save 3.3 s against 1.4 s, the scan 0.07 s against
    0.04 s), and other jobs ran on the machine.
  - The replay gate over the same 28 commits of the kernel gives the same
    result as before the rule, line for line: no refused rebuild, no fault,
    728 exported names, the globals equal, the same methods that differ, 19
    roots of 300 not compiled (13 min 13 s, peak 9.2 GB). The rule acted in
    no rebuild: none of the 28 commits changes or removes a statement of
    this kind. So the rule refuses no real commit of this range, and the
    range does not test it; `gate_runs.sh` does.
  - *The count of what the replay evaluates* in that run, from the log of
    the server of the chain: 25 rebuilds ran a replay, they compared 859
    candidates in all, and 24 differ. 17 rebuilds found none. One replay
    takes 0.21 s to 0.79 s there.

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

  *Open after this step.*

  - Finding 41 grew from 61 methods to 83 in the chain of one server: the
    replay evaluates more items again, and a method with a generated name
    that the old evaluation made stays. *Proposed by the assistant:* Step 6
    takes it, as a removal of what the old evaluation of an item made.
  - Finding 9, the second half: a file that an item reads through a
    computed path. *Proposed by the assistant:* Step 5 takes it, with the
    other inputs.
  - A statement that writes, by a key, into a table that it does not name
    (8 statements of the IDE). No step has it; it goes to "Not in this
    plan" unless the owner wants a rule for it.
  - The time of the replay on the IDE, about 16 s for an edit at the start
    of the load order: Step 8, with the two ways that the cost paragraph
    names.
  - Finding 20: the 9.6 s of the log line are not found. The next rebuild of
    the IDE shows them.
  - The tests of Step 3 for the findings 2 to 6 and 9 as separate small
    edits. `gate_runs.sh` holds one case of each of the findings 2 to 6
    now. The second half of finding 6, the save that removes the old helper
    of a generator, has no test yet.
- [ ] **Step 8: the rebuild time (D6, D9; findings 14, 16, 18 to 21, 32, 35,
  37).** First the measurement of one rebase of the IDE store by hand. Then
  the request `rebase` of the server, the link, the program, the swap of the
  base in the store, the bound, and the check of the room. The build with no
  change ends early. The profile of Step 2 names the three largest parts of
  the floor of a save, and the step removes them. Test: the program gate with
  a rebase between two edits; the oracle after it; the start time equals that
  of a whole build; an edit that passes the room rebases and the program
  starts.

  *The cost of the check of the load order (2026-11-13, the owner said "Yes"
  to Step 8).* The check takes the later methods and the later names out of
  the program, one by one, and each one cost a pass over a whole table:

  | what leaves | cost of one | why |
  | --- | --- | --- |
  | a method (`Base.delete_method`) | 0.36 ms on the platform | the runtime visits the whole method table to find the entry, and the whole dispatch cache to close its entries |
  | a name (`jl_reactive_binding_leave`) | about 7 ms on the platform; 1.9 ms in a module of 20 000 methods | the compiler scans each method of the module whose code names one of its bindings, once for each name |

  Two runtime functions take them out in one pass, in one new world, each
  only for the check, in a fork that writes no image:
  `jl_reactive_methods_disable` (`gf.c`, one visit of each method table and
  of its cache for all methods) and `jl_reactive_bindings_hide` (`module.c`,
  the invalidation of each name with no pass over the methods of the module,
  and then one pass of the harness for all names, `rc_invalidate_named!`).
  Each one does what the function of one item does for each item; on a
  module of 20 000 methods and 1 000 constants, one pass for all names took
  0.025 s against 1.9 s. The harness checks the count that the batch of
  methods answers and deletes the methods one by one when it differs, and
  takes the names out one by one when the runtime has no batch.

  *A fault on the way.* The first batch of methods stored `(void*)1` as the
  value of its hash table, which is the value of "not found" of the runtime,
  so it disabled no method. The round on that build applied two cases that
  must be refused (a read of a later method); the strict gate of the edit
  cases found it, and the case `new_reader_of_a_later_constant_in_a_function`
  covers the invalidation of compiled code for the names.

  | the platform replay, 17 rebuilds | before (d096c893c8) | the batches (dd4d6bdd3f) |
  | --- | --- | --- |
  | the check of the text of now, in all | 166 s | 16 s |
  | the longest check | 20.4 s | 4.7 s |
  | the rebuilds, in all | 564 s | 480 s |

  The rebuilds of the platform now take about as long as before rule H4 and
  the later names. Three commits (12 to 14) took 7 s to 13 s more than in
  that round; their replay took 5 s to 8 s, so the difference is in another
  part, and jobs of another session ran on the machine at the same time.
  Each gate of the round on dd4d6bdd3f passes.

  *Landed (2026-11-13, with the word of the owner: "Land and continue").*
  `merged-next` moved forward to b74e779ddd, with the libraries and the
  images of the build at dd4d6bdd3f (the runtime library changed: the two
  batches), and the caches of the standard libraries made again. Checked in
  the installed Julia: REPL, Pkg and Test load in 0.3 s, the harness of the
  image equals its folder, and both batch functions exist. Not pushed.

  *A build with no change does no work (D9, finding 14; PackageCompiler,
  branch `live-harness`).* A rebuild now ends before the server, the save and
  the link when the sources are those of the last snapshot: the same tracked
  files with the same roots and texts, each file that a top-level expression
  of them reads with the same content, and the same trace. Each snapshot
  records the print of the trace, so a new recording (`refresh_trace`) is a
  change; a snapshot of before the record never ends early. The inputs of the
  store are checked first, so a changed input still stops the build. The
  option `rebuild_unchanged` (`JULIA_REACTIVE_REBUILD_UNCHANGED=1`) turns the
  early end off, for the steps of a gate that ask a server for a save with no
  change: the decoy and the signal of `gate_server.sh`, the new server of
  `gate_replay.sh` and the fix after a failed edit in `gate_runs.sh`.

  The small test reads a file at load now (`greeting.txt`), and two steps of
  `gate_runs.sh` test D9: `same`, a rebuild with no edit, must end early and
  leave the image and the chain as they are; `read`, a change of the read
  file alone and its revert, must rebuild each time and evaluate the reader
  again. In gate C a rebuild with no edit ended early in 4.6 s and left the
  image as it was.

  The gates that the early end touches pass on the build at dd4d6bdd3f with
  PackageCompiler c374f7e5 (2026-11-14): `gate_runs.sh` through a server
  and through a child with the steps `same` and `read`, gate C, the server
  gate (the decoy gets `status` and `quit`, the signal reaches the server),
  gate B (the step `mat-s4` after `refresh` rebuilds, because the trace
  changed), and the replay over 28 commits of the kernel, whose new server
  applies each change since the founding.

  *Not built:* the second half of D9, a check of the times of the tracked
  files in the run scripts before they start Julia. The build scripts of the
  owner start Julia with the builder of `projectured-julia`, which knows
  where the bundle is, so the check belongs in those repositories.

  *The parts of a rebuild of the platform (2026-11-14, the replay over 17
  commits, overlays through a server, the build at dd4d6bdd3f).*

  | rebuilds | the client, outside the server | the apply (the replay in it) | the save (the code of the delta in it) | in all |
  | --- | --- | --- | --- | --- |
  | 1 to 7, before the large commit | about 5 s | 1.5 s to 10.9 s (0.6 s to 5.3 s) | 2.9 s to 8.8 s (0.5 s to 3.7 s) | 10 s to 25 s |
  | 8, the commit of 250 expressions | about 5 s | 19.5 s (8.4 s) | 20.8 s (10.9 s) | 45 s |
  | 9 to 17, small commits after it | about 5 s | 3.9 s to 9.7 s (3.0 s to 5.8 s) | 21.0 s to 22.3 s (10.8 s to 11.5 s) | 31 s to 37 s |

  The save holds each function that changed since the whole build (finding
  18): after the large commit the delta has about 2 400 functions, and each
  later save compiles them all again, 11 s, and writes 2.5 s of heap. So one
  large edit makes each later rebuild about 20 s longer, until the next whole
  build. The rebase of D6 is the answer of the plan: a save in the whole
  form makes the image of now the base, and the overlay starts empty again.
  The client side, about 5 s, is the start of Julia, the load of
  PackageCompiler, the walk of the tracked files, the checks of the inputs
  and the link of the overlay.

  *D6 as built (2026-11-14; PackageCompiler, branch `live-harness`, f9a20afc
  and d667fb87; the fork 761134a7c6 and bb30a1268f; by the assistant within
  the approved D6).* In the overlay form, after the save of a rebuild:

  1. The measure is the code of the overlay against the code of the base:
     the size of the text objects of the last snapshot, which hold each
     function that a change compiled since the base, against the size of the
     text objects of the base (`_reactive_delta_share`). The size of the
     overlay is no measure: it has a part that follows the base, the lists
     of the whole image, and an overlay of one expression of the kernel was
     6 % to 9 % of the base. Each rebuild prints `code_percent`.
  2. Past the bound (`rebase`, `JULIA_REACTIVE_REBASE`, 2 %), the server
     stops, and a child in the whole form starts from the base image and
     applies each change since the base, as a new server does. Its image
     takes the place of the base. Its snapshot holds the text objects of the
     old base too and becomes the first snapshot of the store; the chain is
     empty; the archive for the program, the archive of the save with the
     text objects of the base, is written last, so the builder of the owner
     links and prelinks the program again, as after a founding, with no
     change of the builder. The next rebuild starts a new server from the
     new base.
  3. A rebase that fails leaves the overlay of the rebuild in place, with a
     warning. The growth of an overlay store no longer starts a whole build.

  One fault came up on the way: a child writes its image at its exit, after
  its apply, so the image held the flag of an open apply as true, and a
  server from a rebased image refused each apply. The flag is of one
  process now: it is false at the end of the apply of a child and at the
  start of each server.

  | the replay | rebases | result |
  | --- | --- | --- |
  | 28 commits of the kernel, bound 0.5 % | 25 | the program linked again and right after each; the chain and a new server equal a whole build |
  | 17 commits of the platform, bound 2 % | 2, at commits 7 and 8 | the chain and a new server equal a whole build in 27 289 method lines |

  | the platform, 17 rebuilds | without rebase | with rebase |
  | --- | --- | --- |
  | commits 9 to 17, small edits after the commit of 250 expressions | 31 s to 37 s each | 12 s to 19 s each |
  | the rebuilds that moved the base (7, 8) | 25 s, 45 s | 60 s, 88 s |
  | all 17 rebuilds | 459 s | 379 s |

  A rebase costs about 35 s to 43 s on the platform, once, and each later
  rebuild is about 18 s shorter. On the kernel a rebase costs 8 s to 10 s.

  *The round on the build at 761134a7c6 with PackageCompiler d667fb87
  (2026-11-14).* Each of 11 gates passes: the gate of the edit cases through
  a server and through a child (55 cases, 45 applied, 10 refused as they
  must be), `gate_runs.sh` in both forms with the steps `same` and `read`,
  the prelinked gate, the oracle gate, gates B and C, the server gate, the
  replay of the kernel (3 rebases with the default bound) and the replay of
  the platform (2 rebases); both chains and their new servers equal a whole
  build.

  *What stays open in Step 8.* The measurement of a rebase of the IDE store
  needs a whole build of the IDE with the Julia of now (D5 stops its store).
  The client side of a rebuild, about 5 s, and the floor of a save (finding
  32), the ledger (finding 20) and the apply (finding 21) are not changed. The
  check of the run scripts before Julia starts (D9) belongs in the
  repositories of the owner.

  *Landed (2026-11-14, with the word of the owner: "Yes and continue").*
  `merged-next` moved forward to 27c0f4ff81, with the libraries and the
  images of the build at 761134a7c6, and the caches of the standard
  libraries made again. Checked in the installed Julia: REPL, Pkg and Test
  load in 0.3 s, and the harness of the image equals its folder. Not pushed.
  D9 and D6 are in PackageCompiler, branch `live-harness`, which is not
  pushed either.
- [ ] **Step 9: the overlay form: the call and the start (D11, D12; findings
  12, 13, 26).** Test: the bench of gate M6 with a callee of boxed arguments,
  in the overlay form against a whole build; the start time of the program
  gate against the size of its overlay; the count of the patches of a
  one-line edit.

  *The start with an overlay, measured (2026-11-14, the prelinked program of
  the replay over 17 commits of the platform, with the rebases of D6; the
  middle of 9 starts).* The base alone starts in 30 ms with a peak of 379 MB.
  Two causes of the cost of an overlay are closed:

  - *The checksum (D12, finding 12).* The identity of the loaded image takes
    a checksum of each overlay, and the loader computed it over the whole
    blob, so a start read each byte of it. The writer now computes it with
    the blob in memory and keeps it in the last free field of the header
    (`blob_checksum`, 4297b70926). On one overlay, as written and as a copy
    with the field zero: 28 MB less peak, and up to 20 ms.
  - *The patches that change nothing (finding 13).* In a state with
    overlays the extent of the sysimg spans the const data, so the writer
    gave a reference to a const object of the base the form of the sysimg,
    where the base file holds a reference into the const data: two words
    for one place. 381 090 of 597 851 patched words of an overlay of the
    platform were such words. `reactive_pages_base_ref` tests the const data
    first now (8b2303e1ee).

  | the last overlay of the platform replay | before | now |
  | --- | --- | --- |
  | patched objects | 285 750 | 34 288 |
  | patched words that differ from the base | 597 851 | 214 448 |
  | a start with the overlay | 60 ms to 90 ms, 543 MB to 614 MB | 50 ms, 516 MB |

  Two runs of the replay before the fix gave overlays of 7.9 MB and 45.6 MB
  of new objects for the same commits; the run after it, 7.9 MB. The cause
  of the larger one is not found. Open in this step: the lists of the whole
  image in each overlay (29 MB), the call through a slot (D11, finding 26),
  and 10 182 words of the base file that still hold the tag BaseRef.

  Each of 11 gates passes on the build at 8b2303e1ee with PackageCompiler
  d667fb87 (2026-11-14), with 3 rebases in the replay of the kernel and 2 in
  the replay of the platform; both chains and their new servers equal a
  whole build. An overlay of before still loads: its field `blob_checksum`
  is zero, and its references to const objects in the form of the sysimg
  name the same places.

  *Landed (2026-11-14, with the word of the owner: "Yes").* `merged-next`
  moved forward to 533ef035fb, with the libraries and the images of the
  build at 8b2303e1ee, and the caches of the standard libraries made again.
  Checked in the installed Julia: REPL, Pkg and Test load in 0.26 s, and the
  harness of the image equals its folder. Not pushed.

  *The passes of a start under an overlay (2026-11-14, a profile of 20
  starts of the same program with `perf`, in cycles for each start, with one
  thread of OpenBLAS).* A start with the overlay took 233 M cycles, the base
  alone 127 M. The extra parts:

  - 53 M: the copies of the pages that the patches write. The patches of
    the overlay write 9 155 pages of the program (35.8 MB), and the first
    write to each page copies it. The patches are real changes of the
    state: 9 630 entries of method tables with a new `max_world`, about
    2 900 methods with a new line, the fields `left` and `right` of about
    5 800 old symbols, and arrays and memory. This part follows the change,
    and a rebase (D6) removes it.
  - 20 M: the pass over the function table, which read each of its 98 435
    code instances. 97 554 entries reuse a function of the base, and each of
    them has the code instance of its entry in the base, by construction:
    the writer fills the reuse table from the functions of the reused code
    instances (`reactive_rebase` in `aotcompile.cpp`), and a prelinked
    program takes one overlay over the base. Such an entry now takes its
    method instance from the function record of the base, which the
    pre-relocation wrote, when no patch writes its code instance; the start
    copies that record before the overlay writes over the end of the blob
    (a37408e71f). A table of the pages that a patch writes keeps the search
    of the patches off most entries (9bff013a4a). The pass costs 4 M now.
    `tool/overlay_check.py` tests the rule for each rebuild of the replay
    gate: a reused function of a base code instance must have the entry of
    the base.
  - 18 M: the slot pass of the chain, which put the value of each of the
    64 034 slots of the base in the set of global roots. The base has no
    external-function slot, and a start of the base alone roots no slot.
    The pass now starts at the overlay (a37408e71f).
  - 12 M: the delta lists, which follow the size of the overlay.

  | 20 starts of the program of the platform replay | user cycles | kernel cycles | CPU time | peak memory |
  | --- | --- | --- | --- | --- |
  | the overlay, before | 199 M | 87 M | 59.1 ms | 516 MB |
  | the overlay, now | 168 M | 85 M | 52.7 ms | 435 MB |
  | the base alone | 122 M | 26 M | 30.7 ms | 374 MB |

  The full lists of the whole image are 25.5 MB of the overlay of 50.9 MB.
  A prelinked start reads none of them since the checksum is in the header,
  and the server reads them for its next save. They cost space on the disk
  and time of the save, not time of the start.

  Each of 11 gates passes on the build at 9bff013a4a with PackageCompiler
  d667fb87 (round r36, 2026-11-14), with 3 rebases in the replay of the
  kernel and 2 in the replay of the platform. The oracle and gate B first
  stopped at their first step: the copy of the tools that the round ran had
  no `usr` and no git tree, which these two gates read. They passed on the
  same copy with both added. `tool/overlay_check.py` of a659deae01 on the
  last overlay of each replay: 97 556 reused functions of the platform and
  47 103 of the kernel, each one of the code instance of the base. The two
  replays ran again with the check of a659deae01 after each rebuild (round
  r36b): 25 checks of the kernel and 15 of the platform, the rebuilds that
  did not move the base. Each check finds 0 reused functions of another code
  instance than in the base, and the two replays pass.

  *The call through a slot (D11, finding 26; 1fd1c54bd7).* In the overlay
  form, `emit_invoke` calls a callee of the loaded image with boxed arguments
  through a slot, as it calls a callee with a specialized signature. The
  loader fills the slot with `specptr.fptr` of the code instance, which is the
  function of boxed arguments. A package image keeps the `jl_invoke`
  trampoline for such a callee (*by the assistant:* package images are out
  of this plan). The build prints the count of the slots and of the
  trampolines that stay; a trampoline that stays is a `jl_fptr_sparam` or an
  opaque-closure callee. Gate M6 has a new call shape `boxed`: a function of
  three mutable arguments that returns `nothing`, and a bench of it from old
  code and from new code. Round r37 (2026-11-14, the build of 1fd1c54bd7):

  | gate M6, ns per call | old code | new code |
  | --- | --- | --- |
  | whole form, after the edit | 1.57 | 1.55 |
  | overlay form, after the edit | 1.55 | 2.0 |

  The rebuild of the edit in the overlay form has 72 slots, 5 of them for a
  function of boxed arguments, `reused_boxed!` among them. The rebuild of the
  restore in that form applies nothing: a rebuild with no server loads the
  base image and applies the change since its sources, and the restore gives
  those sources again. The gate tests the slot at the edit only.

  *The full lists (D12).* An overlay held the full lists of its state and the
  delta lists. *Decision by the assistant:* no overlay holds the full lists.
  A loader that is not prelinked makes them: it keeps each position of the
  lists of the state that the overlay extends that is below the end of the
  base objects and outside each run of the overlay, and adds the delta lists
  (`reactive_overlay_merge_lists`). The delta lists hold each position past
  that end and each one in a run, so the two parts share no position. Before
  the change, a script tested the rule on the overlays of rounds r36 and
  r36b: in each of 5 overlays, the merge gives the positions of the full
  lists, in each of the four lists, and the same fixups.

  | overlay | full lists | delta lists |
  | --- | --- | --- |
  | gate of the prelinked program | 7.7 MB | 0.18 MB |
  | gate of the runs, through the server | 7.8 MB | 0.24 MB |
  | gate of the edit cases | 8.0 MB | 0.29 MB |
  | replay of the kernel, 28 commits | 9.5 MB | 0.27 MB |
  | replay of the platform, 17 commits | 26.0 MB | 0.76 MB |

  A list goes down at about 50 places inside some objects, so the writer of
  the delta lists, which moved its run index forward only, could miss a
  position in a run behind the index. None of the 5 overlays has such a
  position. The writer and the merge now use one test, which finds the run
  again when a position goes down (`reactive_runs_meet`). An overlay of an
  earlier build loads with its full lists.
- [ ] **Step 10: the roots follow the edit (D10; findings 10, 11, 25, 27,
  31).** The dead-type test and its three uses. A statement whose code
  instance of the image has no machine code is compiled. ~~Each rebuild prints
  the statements that stay lost and writes them into the record of the
  store.~~ *Done (2026-11-13): the store keeps the list, and the build prints
  the count and the way to record again (see Q1).* The replay gate counts
  what the program still compiles at run time against a whole build. Q1 has
  the answer (b), so a rebuild does no refresh and no second save. The rest of
  this step makes fewer statements lost; with (b) a lost statement costs some
  speed until the next recording, so it waits behind the steps of
  correctness.
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
