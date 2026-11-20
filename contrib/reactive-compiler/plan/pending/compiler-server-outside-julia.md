# A compiler server outside Julia

Status: an exploration with the owner, started 2026-11-20. Nothing in this note
is decided, and it has no steps to execute yet. It records the facts, the
options and the proposed architecture, so that the next discussion starts from
here.

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

## Open questions

1. Is a slower start of a development binary acceptable until the next whole
   build? The owner answered "maybe". Not measured.
2. How much compiled code of the packages above stays valid after a typical
   edit? Not measured. This number decides the gain of each option.
3. Which goal comes first: reuse of compiled code (steps 1 to 5), or edits
   without the cascade (one of steps 6 to 8)?
4. Do the Julia developers accept this direction at all? Item A3 of
   `maturity-and-determinism.md` already says: send a short design note before
   more code for upstream.
