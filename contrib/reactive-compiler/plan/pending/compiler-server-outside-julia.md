# A compiler server outside Julia

Status: an exploration with the owner, started 2026-11-20. The owner approved
the plan of issues and pull requests at the end of this note. No step of it is
executed yet, and no text went upstream. The note records the facts, the
options, the architecture and that plan, so that the next discussion starts
from here.

## The goal

The owner asked for this: a package outside Julia, CompilerServer.jl, that
gives reactive and incremental compilation of Julia packages and binaries on top
of stock Julia. Julia gets only a small change that its developers can accept.
The fork stays the place for experiments.

## What the fork does now

The branch `merged-next` (Julia 1.13.0-rc4) has two incremental paths:

- **The program image.** A rebuild starts from the last image, evaluates only
  the changed top-level expressions, compiles only the code that the change
  made invalid, and links the old machine code again.
- **The package files.** An edit of a package makes a small patch file beside
  its cache file. Julia loads the patch right after the cache file. The package
  keeps its identity, so the packages above it stay valid. A patch of a toy
  package took less than one second.

Where the code lives. The faster-start work, about 550 lines, is separate and
not counted.

| part | size | can a package hold it? |
| --- | --- | --- |
| Julia runtime, C and C++ | about 4,600 lines, 3,200 of them in `src/staticdata.c` | no |
| Base and the compiler front, Julia code inside the system image | about 1,100 lines | no, because they call the new runtime functions |
| the rebuild logic: source diff, change rules, trial in a fork, server | about 5,300 lines of Julia, the stdlib `ReactiveCompiler` | yes, with fallbacks for the runtime additions |
| PackageCompiler driver | about 1,550 lines in two new files, 17 small changes | yes |

The package path needs only a small part of the runtime: about 110 lines of C
in `gf.c`, `module.c`, `staticdata_utils.c` and `toplevel.c`, and about 500
lines in `base/loading.jl`.

## Facts checked in the stock 1.13 source

1. A cache file names the objects of the files below it by byte offset into
   their data (`add_external_linkage` and `get_item_for_reloc` in
   `src/staticdata.c`).
2. The identity of a file (its build id) is the checksum field of its header
   and a random number. The loader does not compute the checksum of the data
   again to compare it with the field. It checks only the checksum of the whole
   file and of its code file (`isvalid_file_crc`, `isvalid_pkgimage_crc` in
   `base/loading.jl`), and a writer can compute both again.
3. A file records the identity of each file below it. The loader refuses the
   file when a loaded file below has another identity (`stale_cachefile`). This
   is the cause of the cascade: one changed package makes each package above it
   compile again. On the platform of projectured, a one-line edit of the
   platform compiles 99 cache files again, about 280 s.
4. The loader checks the sources of a package by their size and hash.
5. At load, Julia checks each compiled function of a file against the methods
   that it called, through the method objects (`verify_call` in
   `Compiler/src/reinfer.jl`). A method that is marked as replaced makes the
   function invalid, and Julia compiles it again when it runs.
6. Four checks stop these actions: the replacement of a method, the deletion of
   a method, an evaluation in a closed module, and a new global in a closed
   module (`src/gf.c`, `src/toplevel.c`, `src/module.c`). Each check applies only
   while the process writes a package cache file
   (`jl_options.incremental && jl_generating_output()`). A normal session and a
   process that writes a program image can do all four. The reason for the
   checks: a package file holds only what its new modules added, so it can not
   express a change to an older file.
7. The writer of a package file keeps a new method of an existing function only
   when the module of the method is new in the process
   (`jl_collect_methcache_from_mod` in `src/staticdata_utils.c`).
8. The writer keeps the compiled code of a method of an earlier package when a
   `precompile` call in the process asked for it, or when code of the new module
   calls it (`queue_external_cis`, `has_backedge_to_worklist`).
9. Julia puts the compiled functions of a file into a few large sections, links
   them into one code file, and deletes the object file. A call between two
   functions of one code file leaves no record.
10. Stock Julia has entry points that compile without an install in the
    process. `jl_emit_native` emits the code of a list of inferred code
    instances into an LLVM module; its comment names GPUCompiler.jl as a user.
    `jl_set_typeinf_func` installs another entry point of inference. An
    `AbstractInterpreter` with its own `cache_owner` keeps its results apart
    from the native cache. `--image-codegen` makes the JIT generate code in the
    form of an image.

From the fork's own measurements (`plan/done/reactive-materialization.md`):

- Code generation records nothing of what it depends on: the calling convention
  of each callee, the layouts of the types, the code generation parameters, the
  target.
- Two builds of the same sources give different object code, for three reasons:
  the order of the GC root slots follows pointers
  (`src/llvm-late-gc-lowering.cpp`), the hash of a type mixes in the random part
  of the identity of its module (for example `@enum`), and some generated names
  carry counters.

## Answers given in the discussion

- **Does the server compile without a load?** No. The server evaluates each
  changed expression in its module, so the new methods exist in its process.
  Julia can compile only methods that exist in the process. What the server
  avoids is a run of the program: it calls `precompile` and does not call the
  functions. The four checks (fact 6) do not stop it, because it writes a
  program image and not a package file.
- **After a rewrite of the package files, does more code compile on the fly
  than before the edit?** Only the code of the packages above that called the
  changed code, which Julia drops at load (fact 5). A second compile can close
  that gap with stock Julia: it loads the new files, calls `precompile` for each
  dropped function, and Julia keeps that code (fact 8). One gap stays: a whole
  compile runs the precompile workloads, so it also compiles functions that are
  reached only through calls that Julia resolves at run time.

## The options discussed

| option | Julia change | gives | acceptance by the Julia developers |
| --- | --- | --- | --- |
| A. Julia allows the four actions of fact 6 for one declared package; our tool merges the result into ordinary package files | about 110 lines of C, and a small option that gives each function its own section | packages | low: our tool writes Julia's private format, so a broken file looks like a fault of Julia, and Julia gets no feature that its tests can show |
| B. Patch files in Julia: a compile writes the changes to methods and names of compiled packages, and the loader applies them after those packages | about 600 lines in the fork | packages; binaries if a patch can apply on top of the program image | medium: one concept, testable in Julia's CI, useful for Revise users |
| C. The writer of a program image reuses the machine code of the loaded image (the fork's binary path) | about 4,600 lines of C | binaries, fastest start | low: large, and upstream PR #64840 changes the same code |
| D. Package files name the objects of other files by name, not by offset | large change of the loader, slower loads | no cascade, for every user, with no tool | uncertain: long review |
| E. A tool rewrites the package files from its own store of compiled parts, keyed by content | as A, and more for the machine code | packages and binaries from one mechanism | as A |

Notes on the options:

- With A or E, a rewritten file can keep the old offsets and identity of the
  changed package (fact 2). Then no file above needs a rewrite. Or it can get a
  clean layout, and the tool fixes the offsets in each file above.
- The merge of A or E must also mark the replaced methods as deleted, and the
  code that called them as invalid. Julia does not compare the content of a
  file with its identity, so a mistake gives a wrong program and no error.
- A store keyed by content shares compiled parts between worktrees and
  branches. Today each new worktree compiles all packages again, because a
  cache file records the absolute paths of its sources.

## The proposed architecture: compile apart from load

The owner proposed this direction: an interface that separates compilation
from the load into the process, from the write of a package file, and from the
read of a package file. The rest of this section is my proposal.

### The five stages of a compile in Julia

1. Parse the text.
2. Lower the syntax and expand the macros. A macro is a function of the
   program, so this stage runs program code.
3. Evaluate the top level: define the types, methods, constants and names. This
   stage runs program code too: initializers, `@eval` loops, reads of files.
4. Infer a method instance at a world. The result is inferred code and its
   edges. The edges are the reads that inference made.
5. Generate machine code from the inferred code.

Stages 1 to 3 define the program. Julia defines a program only by running code,
so these stages must run in a process, and their result lives in the heap of
that process. Stages 4 and 5 are functions of the definitions at a world. They
can run in the same process without a run of the program, and without an
install of their results (fact 10).

Today the two products mix the stages. A program image is the heap of a process
after all stages. A package file is the part of the heap that its new modules
added. The process that compiled a product also writes it, and a product names
the products below it by offset. So a product can not take a compiled part from
somewhere else, and a change below makes each product above invalid.

### The target

```
sources --> stages 1-3 --> definitions in a process, by world
                                |
                                +--> stage 4 --> inferred code + its reads ----+
                                |                                              +--> store, keyed by content
                                +--> stage 5 --> object + slot table + reads --+
                                                                               |
    products, linked from the store <------------------------------------------+
    (a running session, a package file, a program image)
```

Three rules:

1. A compiled part names each thing outside itself by a key, not by a pointer
   or an offset. A module has its path as key, a name its module and symbol, a
   method its function and signature, a method instance its method and types,
   and a code instance the hash of its content.
2. A compiled part records its reads, and its key is the hash of its inputs.
   For inference the reads exist: they are the edges. For generated code they
   must be added (see the facts above).
3. A part is valid while its reads give the same answers. For inference,
   Julia's own check at load (`verify_method`) is this check, so the store does
   not need a second one.

| inside Julia | outside, in CompilerServer.jl |
| --- | --- |
| the five stages | the store and its keys |
| the formats of package files and program images, with their writers and readers | which parts to compile, when, and in which order |
| the checks of validity: edges and worlds | the source diff, the change rules, the server |
| the interfaces between the stages and the products | the link step that chooses which parts go into which product |

### Steps in the official Julia

The sizes are my estimates. Steps 4 and 5 are not in the fork.

Compiled code as parts:

1. **Generated code that does not depend on the process.** Fix the three causes
   of different object code. Small; three independent pull requests. Julia gets
   builds that it can reproduce.
2. **An official interface that compiles without an install.** Take what exists
   (inference of a list of method instances at a world, `jl_emit_native`), and
   give it documentation, tests and a stable place. Small to medium. The GPU
   and differentiation packages already use these entry points.
3. **Generated code reports its slot table and its reads.** For each function:
   the Julia object that each slot needs, each callee and its calling
   convention, the type layouts, the parameters, the target. Medium. Julia gets
   a way to check that compiled code is still valid.
4. **An install of compiled code in a running process.** The JIT links a given
   object, binds its slots to objects of the session, and sets the code of the
   code instances, with no LLVM. Medium. Julia gets a cache of compiled code
   that survives a restart.
5. **The writers take compiled code from outside.** A package file and a program
   image take the machine code of a function from a given object, and do not
   compile it again. Large. Julia gets whole builds with no new compile of
   unchanged code.

Edits without the cascade, one of three:

6. **B, patch files in Julia.** About 600 lines in the fork.
7. **D, references by name between package files.** Large.
8. **The edit applied at load by CompilerServer.jl.** Julia keeps the old
   package file, and the tool evaluates the changed expressions right after
   the package loads (`Base.package_callbacks`, as Revise does). Then it
   installs the compiled code of the changed parts from the store (step 4), so
   nothing compiles on the fly. Julia needs only a small hook in Base that lets
   a tool keep a cache file whose sources changed. A tool can also do this with
   no change in Julia: the session loads the packages from a copy of the old
   sources. A development binary works the same way: the program image of the
   last whole build, and the edits applied at its start. The start gets slower
   as the edits grow, until the next whole build in the background.

With steps 1 to 4 and option 8, the file formats stay inside Julia, and no new
file format enters Julia. CompilerServer.jl then holds all of the reactive
part: the store, the server, the rules, the edits that it applies at load, and
the whole builds in the background.

The owner chose another way for the edits: the definitions become parts too,
and a link writes the products (issue D below). Options 6 to 8 stay as
alternatives.

## Products as if compiled from scratch

The owner asked whether a written package file or binary can hold no obsolete
part, as after a compile from scratch, and whether its write can be fast.

- Today Julia writes a product as a snapshot of the heap of the process that
  compiled it. After an edit, that heap holds the history: deleted methods, old
  versions of names, the types of old closures, compiled code that is no longer
  valid. A writer of a snapshot must prune each of these, and the fork keeps
  some residue, for example the global slots of dead functions.
- A link starts from the current definitions and takes only the parts that they
  reach. A part that nothing reaches stays out, so nothing needs a prune. The
  fork shows this already for machine code: the new function table names only
  the live functions, and the linker drops the rest.
- Steps 1 to 5 make the compiled code parts. The definitions (types, methods,
  names, constant values) still live in the heap of the process. They need one
  more step: definitions as parts (issue D below).
- Without that step, a tool can evaluate the definitions again from scratch for
  each product and take only the compiled code from the store. That product is
  clean too, but each written file costs its evaluation and Julia's writer, and
  so does each file above it. From the measured shares of the platform package
  (evaluation 5.6 s and serial output about 24 s of the 80.5 s of its precompile
  list), that is about a third to a half of a whole compile today.
- With definitions as parts, a rebuild evaluates the changed expressions,
  compiles the code that the change made invalid, and links. The fork's write
  by pages, which copies the clean part of the heap, writes the heap of the
  routing image in 0.7 s against 3.4 s for a whole write. A link from parts is
  not measured.
- The precompile workload still needs a run, because it finds the functions
  that only calls at run time reach. A person runs it again when necessary, as
  in the fork.
- The owner accepted that a whole build also goes through the same link. Then
  the proof that a rebuild equals a whole build is a byte comparison of two
  files. The comparison with a stock build stays a comparison of content,
  because Julia's writer orders the objects in another way.

## The issues and the pull requests

The owner likes steps 1 to 5, wants the result for binaries and for packages
that Julia loads, and approved this plan. It follows the rules of the region GC
work:

- one pull request for each issue, with its parts as commits;
- a pull request opens only after the one before it merged, so nothing stacks;
- an issue is one screen: problem, measurement, proposal, questions;
- a pull request body has 10 to 30 lines, with no bold and no table of costs;
- the measurements go on a branch of `levy/julia`, and the text links them.

The work moves to Julia master first, because the fork is on 1.13. The sizes
are estimates.

| | issue: what we ask | value for Julia alone | pull request and its parts | size | needs |
| --- | --- | --- | --- | --- | --- |
| 0 | the design: compile apart from load, with three questions | it decides the direction | none | – | – |
| A | two builds of the same sources give different machine code (step 1); this is the open issue JuliaLang/julia#63149, so step A continues it | package files and images that a build can reproduce | done: #63150 (open) sorts the GC root slots, the work list of a build and the global slots; #63151 (merged) keeps the inference times out of the image; to send: the issue about the random part of the module identity in type hashes (its text is ready), then one pull request that gives names of constants and strings from their content | small | nothing |
| B | code can not be compiled, described and installed apart from the load (steps 2 to 4) | one stable interface for GPUCompiler.jl, Enzyme.jl and juliac; a cache of compiled code that survives a restart; an answer to "why did this compile again" | 1. the interface: infer and generate code for a list of method instances, with no install; 2. generated code reports its slots and what it read; 3. an install of inferred code and machine code in a running process, with no LLVM | medium, new work | a yes to issue 0 |
| C | the writers compile each function again (step 5) | a whole build that does not compile cached code again | 1. each function gets its own section and a name from its key; 2. the writers of package files and of system images take the code of a function from a part | large; the fork has a form of it for images | B merged |
| D | definitions can only be written as a snapshot of a process heap | no precompile cascade; products that a byte comparison can check; a tool to inspect cache files | 1. a reader and writer of Julia's formats at the level of objects; 2. the definitions of a top-level expression as a part with keys, and generated names from content; 3. package files and system images written by a link of parts | large, new design | C merged |

Two consequences matter for the acceptance:

- The loader does not change. A linked product is an ordinary package file or
  system image.
- No exception to the four checks of fact 6 is necessary. The server compiles
  in a process where Julia allows edits, and the products come from the link,
  not from that process.

What CompilerServer.jl can do after each pull request:

- After A: nothing visible yet. The keys of compiled code become reliable.
- After B: a session takes compiled code from the store and does not compile it
  again. The cascade stays.
- After C: a whole build of the package files or of a binary takes all
  unchanged code from the store. The cascade stays, but each file in it costs
  only its evaluation and its write.
- After D: after an edit, the server compiles only the changed code, and the
  link writes new package files and a new binary as if from scratch, with no
  cascade and no obsolete part. A rebuild and our own whole build give the same
  bytes.

A draft of issue 0. On GitHub each paragraph is one line.

```
Title: Compile apart from load: compiled parts that a link writes into package files and system images

Problem: one edit in a low package makes Julia compile again each package above it, because a cache file names the files below it by identity and by byte offset. In one of our projects, a one-line edit compiles 99 cache files again, in about 280 s. A system image has the same problem: a rebuild compiles each function again.

Measurement: a fork of 1.13 that reuses the compiled code of the last image rebuilds an application image in 21 s instead of 117 s. Details: <link to the evidence branch>.

Proposal: separate the compile from the load and from the write of products.
- Inference and code generation give parts that do not depend on the process: inferred code and machine code, each with a list of what it read.
- A part names other objects by a key (module path, name, method signature, types), not by a pointer or an offset.
- Julia writes package files and system images by a link of parts. The loader does not change.
- A package outside Julia keeps a store of parts and decides what to compile again. The existing edge check of Julia decides which parts are still valid.

Steps: #63149 reproducible generated code (#63150 and #63151 are its first pull requests). #B compile, describe and install code apart from the load. #C the writers take compiled code from parts. #D definitions as parts, and products written by a link.

Questions:
1. Is this direction acceptable to you?
2. Where must the interface live: in Compiler.jl, or in Base.Experimental?
3. Are keys for definitions acceptable, or do you prefer another way to remove the cascade?
```

## What the fork has of A to D

Checked on 2026-11-20 in the branches `merged-next`, `determinism-experiment`,
`pr-reproducible-image-code` and `pr-codeinstance-build-times`.

| item and part | in the fork |
| --- | --- |
| A. a stable order of the GC root slots, the work list and the global slots | done, 63 lines; pull request #63150 |
| A. no inference times in the image | done; merged as #63151 |
| A. no random part of the module identity in type hashes | measured; the text of an issue is ready; no fix |
| A. names of constants and strings from content | not done |
| A. checks of the result | on `determinism-experiment`: two rebuilds give the same bytes; the machine code of a rebuild differs from a fresh build no more than two fresh builds differ from each other; the heaps of a rebuild and of a whole build hold the same objects |
| B. an interface that compiles without an install | not done: the fork compiles inside its own process, through changes to the compiler front |
| B. generated code reports what it read | a prototype only: `src/ReadKey.jl` computes a key for each compiled function and compares it with Julia's invalidation |
| B. an install of compiled code without LLVM | not done; the nearest is the loader of the fork, which applies an overlay of compiled code at start |
| C. one section and one name for each function | done for the program image: one function table with names, and a link that drops dead functions; the names carry a build tag, not a key |
| C. the writer takes code from parts | done for the program image: it reuses the machine code of the loaded image, and new code calls it by name; not done for package files; the parts are earlier builds of the same output, not parts with keys |
| D. a reader and writer of the formats at the level of objects | pieces only: the writers by pages and by overlay rewrite objects and merge the lists of pointers; a tool lists each object of the heap |
| D. definitions as parts | the logic exists: which top-level expression made which methods and names, what it read, and when it must run again (about 5,300 lines); the parts with keys and the names from content do not exist |
| D. products written by a link | machine code yes, for the program image; the heap no: the fork writes it whole, by pages, or as an overlay |

Most of the part that CompilerServer.jl would hold exists: the server, the
source diff, the change rules, the trial of an edit, the reads, the store with
its record of builds, the command line, the driver in PackageCompiler, the gates
and the oracle. It uses runtime functions that only the fork has.

## The upstream history

| number | title | state on 2026-11-20 |
| --- | --- | --- |
| JuliaLang/julia#63147 | gf: fix crash on a compile hint with a `where` | open, no comment |
| JuliaLang/julia#63149 | The generated code of a system image is not reproducible | open issue |
| JuliaLang/julia#63150 | Make image builds reproducible: sort three lists that follow object addresses | open, a review started |
| JuliaLang/julia#63151 | staticdata: do not store the inference times in the image | merged 2026-10-11 |
| JuliaLang/julia#63152 | cgmemmgr: a forked child opens its own /proc/self/mem | closed, not merged |
| JuliaLang/PackageCompiler.jl#1125 | Speed up builds: cache the fresh base sysimage and overlap the copies | closed, replaced by #1126 |
| JuliaLang/PackageCompiler.jl#1126 | Cache the fresh base sysimage between non-incremental builds | merged 2026-09-14 |
| JuliaLang/PackageCompiler.jl#1127 | ensurecompiled: load the packages instead of precompiling them | closed, not merged |

What the comments say, and what follows for this plan:

- On #63149, one reviewer wrote that a fully reproducible compiler is "close to
  not planned". Another one answered that reproducible builds are nice. Our
  answer there: the goal is to remove the causes that are cheap to remove, not
  full determinism, so that a comparison of binaries becomes useful.
- On #63150, the reviewer of the image format, who also wrote #64840, wrote that
  small steps toward reproducible builds are a good idea, but doubted that a
  deterministic write of an image is tractable. Issue D answers this doubt: a
  link orders the objects by key, not by the order of a walk of the heap.
- On #63152, the same reviewer wrote that much more goes wrong when a Julia
  process forks, and closed it. So CompilerServer.jl must not depend on a fork:
  the trial of an edit and the write of a product run in separate processes.
  The server of the fork writes each image from a fork today, so that changes
  too.

Two more texts exist. The work is announced on Discourse: "Building an
incremental sysimage in seconds instead of minutes"
(https://discourse.julialang.org/t/building-an-incremental-sysimage-in-seconds-instead-of-minutes/139352).
A note for the core team, `doc/upstream-note.md` on the branch
`determinism-experiment`, is ready and not sent; issue 0 replaces it. The text
of the issue about the module identity is step S5 of Track C in the plan
`maturity-and-determinism.md` on that branch.

## Open questions

1. Do the Julia developers accept this direction? Issue 0 asks it. The
   reviewer of the image format must also accept a link ordered by key as the
   answer to the doubt on #63150. Item A3 of
   `maturity-and-determinism.md` says the same: send a short design note before
   more code for upstream.
2. Where must the interface live: in Compiler.jl or in Base.Experimental?
   Issue 0 asks it.
3. How much compiled code of the packages above stays valid after a typical
   edit? Not measured. This number decides the size of the compile after an
   edit.
4. How does a definition part capture the effect of top-level code on the state
   of other modules? The fork handles this for its tracked sources, but not
   across packages.
