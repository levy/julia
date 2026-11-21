# The texts of the issues of compile apart from load

Drafts for JuliaLang/julia, for the plan
`plan/pending/compiler-server-on-julia-master.md` (Steps 6 and 7). Nothing here
is sent. Each text is one screen; on GitHub each paragraph is one line. The
evidence is the branch `compiler-server-evidence` of `levy/julia`
(`contrib/compiler-server/measurements.md`), which must be pushed before a text
links to it.

The issue about the module identity in type hashes is not needed: #65077
(merged 2026-11-20) seeds the hash of a type name from the hash of its module,
which comes from the name and the parent of the module.

## Issue 0: the design

```
Title: Compile apart from load: compiled parts that a link writes into package images and system images

Problem: one edit in a low package makes Julia compile again each package above it, because a package image names the images below it by identity and by byte offset. In one of our projects, a one-line edit compiles 99 package images again, which takes about 280 s on the longest chain. A system image has the same problem: a rebuild compiles each function again.

Measurement: a fork of 1.13 that reuses the machine code of the last image rebuilds an application image in 21 s instead of 117 s. On master, a package that applies each edit in a server process, as Revise does, gives a program equal to a fresh load of the same sources for 55 small edits and for 20 real commits of a package. Details: <link to contrib/compiler-server/measurements.md on the branch compiler-server-evidence of levy/julia>.

Proposal: separate the compile from the load and from the write of products.
- Inference and code generation give parts that do not depend on the process: inferred code and machine code, each with a list of what it read.
- A part names other objects by a key (module path, name, method signature, types), not by a pointer or an offset.
- Julia writes package images and system images by a link of parts. The loader does not change.
- A package outside Julia keeps a store of parts and decides what to compile again. The existing edge check of Julia decides which parts are still valid.

Steps: #63149 reproducible generated code (#63150 is open; #63151 and #65077 are merged). B: compile, describe and install code apart from the load. C: the writers take compiled code from parts. D: definitions as parts, and products written by a link. Each step is useful alone, and each gets its own issue and pull request.

Questions:
1. Is this direction acceptable to you?
2. Where must the interface live: in Compiler.jl, or in Base.Experimental?
3. Are keys for definitions acceptable, or do you prefer another way to remove the cascade?
```

## Issue B: compile, describe and install apart from the load

```
Title: Compile, describe and install code apart from the load

Problem: tools that compile Julia code for later or for another target (GPUCompiler.jl, Enzyme.jl, juliac) call internal entry points such as typeinf_ext_toplevel, jl_emit_native and jl_create_native. These change between releases. Their output is bound to the process: the machine code reaches Julia objects through slots that only this process can fill, and nothing records what the code depends on. So a tool can not keep compiled code for another session, and can not tell whether kept code is still valid.

Measurement: of the 80.5 s of the precompile list of our largest package, inference takes 39 s and LLVM about 12 s. Most of that code did not change since the last build. Details: <link>.

Proposal, one pull request in three parts:
1. An interface that infers a list of method instances at a world and generates their code, with no install in the process.
2. Generated code reports its slots (the Julia object that each one needs) and what it read: each callee and its calling convention, the type layouts, the code generation parameters, the target.
3. An install of inferred code and machine code in a running process: the JIT links the object and binds its slots, with no LLVM.

Value: one stable interface for the packages that compile Julia code; a cache of compiled code that survives a restart; an answer to "why did this compile again".

Questions:
1. Where must the interface live: in Compiler.jl, or in Base.Experimental?
2. Is an install of machine code that the JIT did not compile acceptable?
```

## Issue C: the writers take compiled code from parts

```
Title: The writers of package images and system images compile each function again

Problem: to write a package image or a system image, Julia compiles the machine code of each function of the image, also of a function whose code a loaded image already holds. It puts the functions into a few large sections, links them into one file, and deletes the object file. So no tool can reuse the machine code of one function in the next build.

Measurement: a fork of 1.13 gives each function its own section and a name in one function table, and links the machine code of the last image again. Its rebuild of an application image takes 21 s instead of 117 s, and the image does not grow with the edits, because the link drops each function that the table does not name. Details: <link>.

Proposal, one pull request in two parts:
1. An option that gives each compiled function its own section and a name from its key.
2. The writers of package images and of system images take the machine code of a function from a part (the form of the issue about compile apart from load), and do not compile it again.

Value: a whole build that compiles no unchanged code; smaller images, because the link drops dead functions.

Questions:
1. Is the cost of one section for each function acceptable for the stock build, with the option off by default?
2. Must the name of a function come from a hash of its content, or from its method instance?
```

## Issue D: products written by a link

```
Title: Package images and system images as a link of parts

Problem: a package image holds the new objects of its modules, and names the objects of the images below it by identity and byte offset. So a change below makes each image above invalid, also when its code did not change: in our project, a one-line edit compiles 99 package images again. An image is also a snapshot of the heap of the process that wrote it, so after an edit it holds the history of that process, and a tool must prune it.

Measurement: <link>.

Proposal, one pull request in three parts:
1. A reader and a writer of Julia's image formats at the level of objects, pointers and tables. The comment of staticdata.c that asks for a "package inspector" asks for the reader.
2. The definitions of a top-level expression as a part with keys, and generated names (the type of a closure) from content and not from a counter.
3. Package images and system images written by a link of parts that starts from the current definitions. The loader does not change: a linked image is an ordinary image.

Value: no cascade, because an image above links again when its own parts did not change; an image that a byte comparison can check against a whole build; a tool that inspects package images.

Questions:
1. Are keys for definitions acceptable?
2. How must a part hold the effect of top-level code on the state of another module?
```
