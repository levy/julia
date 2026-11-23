# Better builds and development cycles of the test project

Status: proposed 2026-11-22, not started. It takes over the open steps of
`compiler-server-on-julia-master.md` (Step 12 T4 and Step 13) and its open
defects.

## The request

The owner, 2026-11-22:

> Make building better by optimizing these goals simultaneously:
> - maximise parallel agent build throughout
> - minimise single user initiated build time
> - maximise use of fast incremental reactive
> - minimise use modified Julia, modifications should be simple and few to allow PRs
> - use separate compiler server package for incremental and reactive compilation
> - minimise binary differences between incremental and plain build for binary executables and package binaries
> - minimise binary executable size
> - minimise package binaries size
> - maximise coverage of precompile workload for real use
> - minimise binary startup time, aim for less than 100ms
> - minimise screen refresh time, aim for less than 30ms
> - minimise compilation during application use
> - minimise automatic test selection for changes during development
> - minimise test build time
> - minimise test duration but aim for correctness
> - minimise development cycle time, change, build, test, repeat
> - minimise peak memory consumption during build
> - maximise CPU utilisation during build
> - maximise parallel build throughout
> - minimise application memory consumption due to compiled stuff
> - maximise testing of features and performance guards
> - imitate whole development lifecycle, worktrees, initial build, changes, incremental builds, rebuilds, starts, etc.
>
> Note these goals can be in conflict, so search for the best balance.

And: "let's focus on our test project first and ignore projectured for some
time. We need to make building and development cycle better for the test
project first in every possible way."

So the scope is the generated project of `bench/` in CompilerServer.jl, with
the tools that build it: CompilerServer.jl and the Julia branch
`pr-linked-products`. Projectured is out of scope until the owner says
otherwise.

The owner, 2026-11-23, on where this work must end:

> I expect this work to lead to a final result where an incremental small
> change in a large project like projectured or omnet can be written into an
> executable binary or package binary within seconds just like the merged
> branch of the Julia repo could do that. We will work until we reach that
> goal. But until then, let's focus what we are doing now.

So the test project stays the scope of this plan, and each step is judged by
whether it moves toward that end: the build of a small edit must lose its fixed
cost (a new process for each package file, a whole PackageCompiler run for each
executable).

The owner, 2026-11-23 at noon, when I asked which way to take for the second
pass of an executable build (110 s after an edit, 72 s for stock):

> what? we want to have a reactive incremental compiler which produces
> binaryes in a few seconds not 100 seconds. we should go that direction

So the order of the steps changes. S6, the reactive cycle, is the next step,
and its target is seconds from an edit to the package files and to the
executable of the test project. The open items of S3 and S4 (the second pass,
the size of the image, the rest of the first build) wait: they tune builds
that take a minute. The owner also asked for a file with the current numbers
(times, memory), open in the editor: `STATUS.md` in the CompilerServer.jl
worktree, not tracked.

## What exists, and what we measured

The mechanisms:

| mechanism | state |
|---|---|
| A store of parts, shared by all worktrees (a pool with versions, a manifest for each product, the cleanup) | works: a new worktree keeps all 1,603 parts and compiles none; two builds at the same time succeed |
| Writers of package files and of system images that take the machine code of each function from its part | work: the output equals the output of stock in each step |
| The identity of the code of a record: the interface of the callees that the code calls, the identity in depth of the callees that it inlined | works: an edit rebuilds only its parts (0 to 12 for most edits, 160 for lines that move) |
| Compile apart and install in a running process (the JIT path) | works in the tests; it does not check the identity of the code |
| A link of package files from stored pieces (Step 11, `link.jl`) | the linked file equals a whole build in every byte; with fixed object ids, two whole builds are equal |
| Fixed object ids (an option of the Julia branch) | two whole builds are equal in every byte; about 3 % more write time |
| The harness: the generated project, the scenarios, the guard against stock (`bench/`) | 129 checks pass; the gaps have names and bounds |
| The Julia branch `pr-linked-products` against master `2aa7c9fd5b` | 18 files, 1,241 lines added and 41 removed, 20 commits (3 of them are PR #63150) |

The measures (the small project: three packages in a chain, about 1,100
functions; 4 cores; one run of each step). A time is the wall time of the
package writes of one step:

| measure | stock | parts |
|---|---|---|
| a writer of GenLow (about 530 functions), 0 new parts | 0.91 s to 0.94 s | 0.79 s |
| the LLVM work in that writer | 0.24 s (0.9 s CPU on 4 threads) | 0.005 s |
| the provider in that writer (the check of the parts, the table) | none | 0.13 s to 0.29 s |
| an edit of a comment (three writers) | 2.92 s, CPU 5.11 s | 2.70 s, CPU 2.81 s |
| an edit of the body of a leaf function | 2.94 s | 3.05 s (12 new parts) |
| lines that move | 3.05 s | 3.25 s (160 new parts) |
| the first build (an empty store) | 3.89 s | 6.57 s |
| a new worktree | 3.89 s | 3.60 s |
| the `.so` of GenLow | 300,168 bytes | 643,696 bytes |
| the `.ji` of GenLow | 2,217,055 bytes | 0.2 % more |

The open defects and gaps:

- The image of parts is not equal in bytes to the whole build of parts (seen
  in the system image gate: 275.3 MB against 269.5 MB). No guard compares
  these bytes.
- The image of a system image holds the provider module and its tables
  ("CompilerServerParts" 1,073 times).
- The `.so` files are 2.1 times as large as stock: the part symbols are
  exported, and the unwind tables and the symbol table are larger.
- A writer still compiles 12 to 33 methods of Serialization with the JIT (30 ms
  to 100 ms).
- A backtrace in a worktree names the files of the worktree that compiled a
  part first.
- `install_apart` does not check the identity of the code.
- The project has no tests, no executable, no session of use and no frames, so
  10 of the 22 goals have no measure yet.

## Where the time of a cycle goes

A writer of a package file does these things in order:

1. It starts a Julia process.
2. It loads the package files of the dependencies.
3. It evaluates the source of the package: it parses and lowers the code and
   defines the methods and the types.
4. It runs the workload, or compiles the recorded list of calls.
5. It infers the code.
6. LLVM optimizes the code and makes the machine code.
7. It serializes the objects, links the image and writes the files.

Parts skip only item 6, which is about a quarter of a writer of GenLow. An edit
in GenLow makes GenMid and GenApp stale too (the rule of Julia), so each edit
pays three writers, each with items 1 to 7. So the next large gains must skip
work at a higher level:

| lever | what it skips | state |
|---|---|---|
| machine code from parts | item 6 | built |
| inference results from records | item 5, and most of item 4 | not built (the idea "the provider runs before inference") |
| a resident server that keeps the worktree loaded | items 1 to 3 for the cycle, and the writers until the products are needed | a server exists in CompilerServer.jl, not joined with the store |
| a package file reused whole, by the content of its inputs | items 1 to 7 for an unchanged package in a new worktree | not built; Julia rejects a file whose sources have another path |

The time of items 1 to 5 and 7 is not measured apart yet. Step 1 measures it,
and the order of Steps 4 to 6 can change with those numbers.

## The conflicts, and the balance that I propose

| conflict | the balance (my proposal) |
|---|---|
| fine reuse (one part for each function) against small products and bytes close to stock | the store keeps one part for each function; the product packs the parts as stock packs one module: hidden symbols, no extra names, compact unwind tables. The size bound is stock plus a small named gap |
| equal bytes against stock, or against our own whole build | an incremental product equals our whole build in every byte (a hard guard); against stock, the content is equal and the byte difference is measured and kept small |
| more precompiled code (coverage, no compilation in use, short frames) against size, build time and memory | a recording of the session of use decides what is precompiled; only what a recording shows goes in |
| fewer Julia changes against speed | the Julia changes stay in four themes, each one a small PR; the speed comes from the package (the store, the server, the reuse of inference) |
| parallel agents against the build of the single user | agents run at a lower CPU weight, inside the 48 GiB total; the build of the user gets a memory reserve and the cores first |
| fewer tests for each change against correctness | the tests are selected by what each test ran; the full suite runs before a land; the edits of the harness check that the selection misses no failure |
| a fast first build against one part for each function | a first build with an empty store must not be slower than stock: either the emission gets as cheap as stock, or the first build is a stock build and the parts come after it |
| the peak memory against the CPU use | many small writers in parallel, and the emission threads inside the budget; the store is on disk |
| a short start of the executable against a large image | one image for the executable, with only what the recording needs; the time of the start is measured part by part |

## Proposed decisions

These are my proposals. With the approval of the plan, they are decisions.

- **PD1.** The test project is the reference for every goal: a change of the
  build tools lands only when the guards of the test project pass.
- **PD2.** Each goal has a measure with a definition, a guard against stock,
  and, where stock is still better, a named gap with a bound.
- **PD3.** An incremental product equals our whole build in every byte. Against
  stock, the content is equal (the same method instances with code, the same
  machine code for each function where the layout allows it), and the byte
  difference is measured by kind.
- **PD4.** Reuse at the highest level that holds: a whole package file, then the
  inference results, then the machine code.
- **PD5.** Two ways into the store: the resident server for the cycle of the
  user, and batch writers for agents and full builds. Both write the same
  parts.
- **PD6.** The store keeps one part for each function; the products pack the
  parts close to the size of stock.
- **PD7.** The Julia changes stay in four themes, each one a small PR: A
  reproducible code, B compile and install apart from load, C writers that take
  code from parts, D definitions as parts and a link. A new hook needs a reason
  in this plan and a decision of the owner. No issue and no PR is opened (D12).
- **PD8.** Tests are selected by what each test ran; the full suite runs before
  a land.
- **PD9.** The application of the test project precompiles what a recording of
  its session of use compiles; the start, the frames, the compilation in use
  and the memory are guards.
- **PD10.** Agents run at a lower CPU weight than a build of the user, inside the
  total of `bounded-run` (48 GiB, the owner 2026-11-22), with a reserve for the
  user.

## The measures

Each measure runs on the generated project, for stock and for our build, in
`bench/`; `measures.jl` holds its definition.

| goal | measure | first target |
|---|---|---|
| parallel agent build throughput | the cycles (edit, build, selected tests) that N worktrees finish in one hour, N = 2, 4, 8, inside the budget | above stock for each N |
| single user build time | the wall time of the build of one worktree after an edit, alone and while N agents run | below stock in each scenario |
| use of the fast incremental way | the share of the functions whose code comes from the store or the server, and the share of the cycles that need no writer | measured; no bound yet |
| modified Julia | the lines that differ from master, by PR theme | each theme one small PR |
| a separate compiler server package | the logic outside Julia: all but the hooks | each mechanism is in CompilerServer.jl |
| binary differences | the bytes that differ between an incremental product and our whole build (package files and the executable); the difference against stock, by section | 0 bytes; against stock, measured |
| executable size | the bytes of the executable and its image | within stock and a named bound |
| package binary size | the bytes of the `.ji` and `.so` files of each package | within stock and a named bound |
| coverage of the workload for real use | the method instances that the session of use compiles with the JIT in the executable | 0 |
| startup time | the median wall time from the start of the executable to its first line, of 10 starts | below 100 ms, and not above stock |
| screen refresh time | the time of each frame of the frame loop, the first and the 99th percentile | below 30 ms, the first frame too |
| compilation during use | the count and the time of the JIT compilations in the session of use | 0 |
| automatic test selection | the tests that run for each edit, of all; the failures that the full suite finds and the selection misses | fewer than all; 0 missed |
| test build time | the wall time to make the test environment ready after an edit | below stock |
| test duration | the wall time of the selected tests, and of the full suite | below stock |
| development cycle time | the wall time from the save of an edit to the end of the selected tests | below stock in each edit |
| peak memory during build | the largest resident size of one build process, and the sum over the processes at the same time | below stock |
| CPU use during build | the CPU time over the wall time and the cores of the job | above stock |
| parallel build throughput | the builds that N worktrees finish in one hour | above stock |
| application memory from compiled code | the resident size of the executable at its first line and after the session of use | not above stock |
| tests of features and guards | the goals with a guard, the gaps with a name and a bound | all 22 goals |
| the whole life cycle | the scenarios of the harness | each scenario of Step 1 |

## Steps

- [x] **S1. The test project covers the whole life cycle, and each goal has a
      measure.**
      - The generator makes a test suite for each package (a test set for each
        unit, with the expected values that it knows), an executable of GenApp
        (with stock PackageCompiler, and with our build), a session of use
        (calls that the workload makes and calls that it does not make), and a
        frame loop (a frame is computed from a state, many times).
      - Kinds of code for deep inlining, and the medium size (about 5,000
        functions).
      - The scenarios: the first build, each edit and its taking back, a new
        worktree, another commit, N worktrees at the same time (N = 2, 4, 8),
        the build of the executable after each edit, the starts, the session of
        use, the frames, the full test suite and the selected tests.
      - A breakdown of the time of each writer into items 1 to 7 above, for
        stock and for parts.
      - Gate: one run gives the table of the measures above, for stock and for
        our build, with the definition of each number.
      Facts found in the work (CompilerServer.jl worktree
      `CompilerServer.jl-test-project`, branch `test-project-builds`, commits
      `177cc63`, `24aa3f9`):
      - The items of a writer (`bench/phases.jl`; medians of 3 runs, 4 cores;
        parts with 0 new parts; in s):

        | item | GenMid stock | GenMid parts | GenLow, no workload |
        |---|---|---|---|
        | process start | 0.066 | 0.066 | 0.069 |
        | load of the dependencies | 0.121 | 0.124 | 0 |
        | source and workload | 0.523 | 0.522 | 0.487 |
        | provider | 0 | 0.140 | 0 |
        | LLVM of the image | 0.246 | 0.012 | 0.250 |
        | rest (selection, serialization, link, write) | 0.139 | 0.124 | 0.113 |
        | total | 1.093 | 0.987 | 0.919 |

        For GenLow, parts are slower than stock (0.943 s against 0.933 s): the
        load of CompilerServer in the writer costs 0.116 s.
      - The workload adds only 0.02 s to 0.03 s, and with no workload the image
        still has 362 of its 370 compiled functions: `report1` to `report8`
        take no argument, so the writer compiles them and their callees
        anyway.
      - The item "source and workload" is mostly JIT compilation: a normal
        process that loads GenLow from its source takes 0.47 s, of which 0.375
        s is compilation of 274 methods with the JIT. The cause is the code
        that runs at the top level: the constants (`Dict`, `IdDict`,
        comprehensions over the types of each unit), the calls of the macros.
        So the largest cost that is left in a writer, in the tests and in use
        is the JIT, and the levers of S5 change: a code provider for the JIT
        (ask the store before a method compiles) would remove it in each of
        them. It needs one small hook in Julia; the decision point of S5
        holds.
      - The session of use and the frames compile 270 methods with the JIT
        from package files, and 23 in the executable, with stock and with
        parts: the workload does not cover the use (S8).
      - The executable (GenApp, small, 8 cores, one build each): stock 75.0 s
        for the first build and 70.6 s after an edit, image 188,551,856 bytes,
        app folder 860 MB, start 80 ms; parts 241.6 s for the first build and
        60.3 s after an edit, image 291,769,512 bytes, start 101 ms. The larger
        image of parts costs about 20 ms of start, so S3 is also start-time
        work. The build of the executable is the largest cost of a cycle that
        needs it.
      - N agents (each makes a worktree, edits a leaf function, builds and runs
        the tests; cycles in an hour on 8 cores): stock 1,103, 1,891 and 2,835
        for 2, 4 and 8; parts 1,074, 2,059 and 3,719.
      - The gate run (2026-11-22, `24aa3f9`, small, 8 cores, one run of each
        step, `--executable some --agents 2,4,8`, 190 checks pass;
        `bench/report.jl`, the medians over the steps of each group;
        `bench/measures.jl` defines each number):

        | goal | stock | parts | parts/stock |
        |---|---|---|---|
        | the build of an edit, wall s | 2.86 | 2.54 | 0.89 |
        | the build of an edit, CPU s | 5.01 | 2.80 | 0.56 |
        | the build of an edit, CPU use | 0.22 | 0.13 | 0.60 |
        | the build of an edit, peak MiB of one writer | 338 | 355 | 1.05 |
        | the first build, wall s | 3.70 | 5.36 | 1.45 |
        | the cycle of an edit (build and full tests), s | 3.49 | 3.18 | 0.91 |
        | the full test suite, s | 0.62 | 0.65 | 1.05 |
        | the package files, `.ji` bytes | 6,712,819 | 6,723,507 | 1.00 |
        | the package files, `.so` bytes | 922,200 | 1,989,024 | 2.16 |
        | the session of use from package files, JIT compilations | 270 | 270 | 1.00 |
        | the first frame from package files, ms | 11.47 | 10.95 | 0.95 |
        | the slowest frame from package files, ms | 28.11 | 21.42 | 0.76 |
        | the session from package files, peak MiB | 369 | 377 | 1.02 |
        | the executable, first build s | 74.83 | 241.02 | 3.22 |
        | the executable, build after an edit s | 70.59 | 59.83 | 0.85 |
        | the executable, build peak MiB | 5,596 | 4,886 | 0.87 |
        | the executable, image bytes | 188,551,624 | 291,731,608 | 1.55 |
        | the executable, app folder bytes | 860,064,529 | 963,244,513 | 1.12 |
        | the executable, start ms | 80.0 | 101.4 | 1.27 |
        | the executable, JIT compilations in use | 23 | 23 | 1.00 |
        | the executable, first frame ms | 11.82 | 11.59 | 0.98 |
        | the executable, peak MiB | 367 | 377 | 1.03 |
        | 2 agents, cycles in an hour | 1,048 | 1,080 | 1.03 |
        | 4 agents, cycles in an hour | 1,925 | 2,062 | 1.07 |
        | 8 agents, cycles in an hour | 2,943 | 3,801 | 1.29 |
        | 8 agents, the longest build s | 6.94 | 4.53 | 0.65 |

        Goals with no measure in the run yet, each in its own step: the byte
        difference between an incremental product and a whole build (S2), the
        selection of tests (S7), the build of the user while agents run (S9),
        and the lines of the Julia changes (S10; now 18 files, 1,241 lines
        added, 41 removed).

- [x] **S2. An incremental product equals the whole build in every byte.**
      - A guard compares the bytes of each package file and of the executable
        with those of a whole build of the same sources, in each scenario.
      - Find and remove each difference: the provider module in the image, the
        order of the code, the versions of the parts, the build ids.
      - A comparison of content against stock: the method instances with code,
        and the machine code of each function; the byte difference by section.
      - Decision point: if the writer with parts can not give equal bytes, the
        products are made by the link of Step 11. I report it, and the owner
        decides.
      - Gate: 0 bytes of difference in each scenario; the difference against
        stock is reported by section.
      Facts found in the work (CompilerServer.jl `4e299b7` to `1ec2a8a`, Julia branch
      `e2c61fc4af` to `dde6b68e60`):
      - All writers run with `--deterministic-object-ids=yes`; with no fixed
        ids, no two builds can be equal. A file names the path of its depot,
        so the builds that are compared write into one depot.
      - Two whole builds with parts are equal in every byte (all six files
        of the test project): the parts are in the order of the list of the
        writer, and the build id of each file comes from its content. Two
        stock builds differ in 39 kB to 46 kB of each `.ji`, from their random
        build ids.
      - F2 and F5 are in the Julia branch (the owner approved them). The call of
        the provider leaves no trace in the image: the roots that its code
        makes get no tag of the package, the code that it infers is no new code
        of the package, and its objects get provisional ids that the table does
        not record. The writer of a package file loads the provider by name at
        exit (`jl_set_code_parts` with `(package id, function name,
        arguments)`), so a package file with parts requires only the modules of
        stock. The writer must get the very object that the prelude keeps (an
        element of an array): a tuple gets a new box at the `ccall`, and the GC
        freed that box before the writer called it.
      - With F2 and F5, a rebuild (each part held) differs from a whole build in
        about 40 kB of each `.ji` (before: 830 kB, 97 kB and 534 kB). F6 (the
        search): the extra types are gone. The rest is one byte in each of 8
        `UnionAll` types of GenLow. Upstream Julia (#63932, 2026-11-11) keeps
        three facts about the structure of a `UnionAll` in a hidden field when
        a caller asks for them, and the writer saves the field as it finds it.
        The emission of new parts asks one more fact. The build id of a file
        comes from its content, so it differs too, and the code of the file
        names the build id in each block of method roots.
      - The writer computes the three facts of each `UnionAll` before it saves
        them (`jl_unionall_compute_flags`, Julia branch `6f0e495eaf`; the owner
        approved it). `compilecache_with_parts` gives its writer
        `--deterministic-object-ids=yes` itself.
      - The guard (CompilerServer.jl `b71fb9f`): after each step of parts, the
        harness builds the same sources again with an empty store into the
        same depot and compares the six package files. The 21 steps in the
        first worktree are equal in every byte.
      - The 4 steps in other worktrees differed (a new worktree of the same
        commit, of another commit, and two at the same time; 38 kB to 513 kB of
        the six files). 841 of the 1,627 parts held the absolute path of the
        source folder of the worktree that compiled them in their line tables;
        the path was their only difference. The version of a part does not
        cover its object, so a new worktree took these parts with the path of
        the first worktree, and in worktree B some frames of `report1` and
        `pick1` (`Base.StackTraces.lookup`) named the files of worktree A. Most
        frames were right, because `lookup` builds them from the `DebugInfo`
        of the code instance when the code gives a statement index; 28 of
        2,036 frames came from the line table.
      - Way 1 of the decision (the owner approved it): a part names each source
        file of a package relative to the package (Julia branch `dde6b68e60`,
        CompilerServer.jl `c9fe441`). `jl_set_image_source_paths` registers
        prefix rewrites for the debug info of code for an image, and the writer
        with parts names each file of a loaded package `@<name>/<uuid>/<path
        in the package>`. `Base.fixup_package_path` maps such a name to the
        file in the folder of that package, and `Base.StackTraces.lookup`
        applies it to the frames from the line tables. A new setting of the
        part names (`source_names`) keeps the old objects out of use. Now the
        objects of a part are equal in each worktree, and a test checks that
        no object names the folder of a worktree and that the frames in another
        worktree name its own file.
      - With it, each of the 25 steps of parts, in each worktree, writes the
        bytes of a whole build of the same sources (`whole_bytes_differ` 0).
      - A defect of the harness, found here: a child process on Linux reports
        the peak of its parent as its own `Sys.maxrss()` when that is larger
        (a child of an 828 MiB parent reported 828 MiB; of a small parent, 224
        MiB). The session of use reported the peak of the harness process,
        which is larger when it measures parts, after stock: 415 against 380
        MiB. The session now reports its own peak (`VmHWM`): about 325 against
        323 MiB. The peak of a writer holds: the build process stays at 230 MiB
        or less, below each writer.
      - The report against stock (`bench/against_stock.jl`, on the run of
        `c9fe441`, small project, the base sources): both versions have machine
        code for the same 1,261 method instances; 496 have the same bytes, 320
        the same size, 444 are smaller with parts (38,115 bytes in all) and 1
        larger (16 bytes); the machine code is 295,941 bytes with stock and
        257,842 with parts. The `.ji` files are 3.7 kB larger each. The `.so`
        files of parts are 1,066,504 bytes larger (1,988,632 against 922,128),
        by section: the symbol tables `.symtab`, `.strtab`, `.dynsym`, `.dynstr`
        and `.gnu.hash` +744 kB, the unwind tables `.eh_frame` and
        `.eh_frame_hdr` +284 kB, `.bss` +17 kB (the slots of the parts),
        `.text` +13 kB, the debug sections -4 kB. These are the items of S3.
      - The executable is not compared in S2: its build process loads the
        provider, and a system image keeps each module that is loaded, so the
        image of a rebuild and of a whole build hold other provider tables. The
        comparison moves to S3, which takes the provider out of the image.
      - The names of the callees from the edges of the code instances, in place
        of the inference of the provider, left 91 functions without their
        parts and made a whole build non-deterministic: the inference stays.
      - The 63 tests pass; the harness (`--executable none --agents 2`) passes
        its 211 checks.
      - The harness found one more defect of its own in the full run: the build
        of the executable compiled the packages into the depot of the step, in
        its own environment and with no `.so` files, and the comparison took
        that newer `.ji` file. The build of the executable now takes a depot of
        its own (CompilerServer.jl `b657cc5`).
      - The gate run (2026-11-22, `b657cc5`, Julia branch `dde6b68e60`, small,
        8 cores, one run of each step, `--executable some --agents 2,4,8`):
        215 checks pass; each of the 25 steps of parts, in each worktree, is
        equal to a whole build in every byte. The goals (`bench/report.jl`):

        | goal | stock | parts | parts/stock |
        |---|---|---|---|
        | the build of an edit, wall s | 2.85 | 2.66 | 0.93 |
        | the build of an edit, CPU s | 5.00 | 2.89 | 0.58 |
        | the build of an edit, peak MiB of one writer | 339 | 349 | 1.03 |
        | the first build, wall s | 3.70 | 5.43 | 1.47 |
        | the cycle of an edit (build and full tests), s | 3.48 | 3.29 | 0.95 |
        | the package files, `.so` bytes (the first build) | 921,520 | 1,989,008 | 2.16 |
        | the session of use, peak MiB (its own) | 325 | 326 | 1.00 |
        | the executable, first build s | 75.9 | 239.1 | 3.15 |
        | the executable, build after an edit s | 70.4 | 59.8 | 0.85 |
        | the executable, image bytes | 188,578,848 | 292,041,640 | 1.55 |
        | the executable, start ms | 80.6 | 98.3 | 1.22 |
        | the executable, peak MiB (its own) | 232 | 277 | 1.19 |
        | 8 agents, cycles in an hour | 2,735 | 3,623 | 1.32 |
        | 8 agents, the longest build s | 7.59 | 4.68 | 0.62 |

        Against stock (`bench/against_stock.jl`, the same run): machine code for
        the same 1,261 method instances; 494 with the same bytes, 320 the same
        size, 446 smaller with parts (38,060 bytes) and 1 larger (16 bytes).
        The `.so` files of parts are 1,067,488 bytes larger, by section: the
        symbol tables +744 kB, the unwind tables +284 kB, `.bss` +17 kB,
        `.text` +13 kB. The peak of the executable is now its own (`VmHWM`):
        with the larger image of parts it is 19 % above stock, an item of S3.

- [ ] **S3. Small products.**
      - The image does not hold the provider or its tables.
      - The executable of a rebuild equals that of a whole build in every byte
        (from S2): the guard of the bytes also compares the executable.
      - The part symbols are hidden (the emission in the Julia branch, and a
        lookup of the install that finds hidden symbols); the unwind tables and
        the symbol table get as small as those of stock.
      - Measure the choices for the executable: the level of debug
        information, and `--trim` where it keeps the session of use correct.
      - Gate: the package files and the executable are within the bounds of the
        size of stock that S1 sets.
      Facts found in the work (CompilerServer.jl `06736aa`):
      - The image of the executable of parts held the provider module
        `Main.CompilerServerParts` (190 methods) and its globals: about 158 MB
        by `Base.summarysize` (the table of the writer 102 MB, the caches of
        the type texts 24 MB and 18 MB, the part names 6 MB). The provider now
        empties its caches at the end of its call (`apart_forget_caches!`):
        the image is 244,890,768 bytes (before: 292,041,640; stock
        188,578,848), the start to the line `ready` 87.3 ms (before: 101.6 ms;
        stock 80.8 ms), its own peak 263 MiB (before: 295; stock 250).
      - A system image saves the storage of the root task (`root_task->tls`)
        and restores it at load. So the table, which the writer needs until it
        has saved the image, was still in the image there (`Base.roottask` held
        about 60 MB by `Base.summarysize`).
      - The writer copies the bytes, the paths and the names of the table when
        it gets it; after that it needs only the Julia objects of the slots,
        until it saves the heap, and the image saves these objects anyway as
        the values of its slots. A probe (not committed): codegen gives the
        table of a native code (`jl_get_llvm_code_parts`), and
        `jl_create_system_image` roots it in its own frame until the image is
        saved; the provider keeps nothing (5 files, about 25 lines). The
        executable (a whole build, because a new system image of Base gives new
        part names): the image is 230,698,912 bytes, its heap 163,796,688
        (stock 153,741,920), the start 84.5 ms (stock 81.6 ms), its own peak
        258 MiB (stock 250), and its output is that of stock. The 63 tests
        pass.
      - Left in the heap, about 10 MB: the entries of the dispatch caches from
        the work of the provider (the method table is about 15 MB larger by
        `Base.summarysize`), the code of the provider (190 methods and 819
        specializations), and 7,676 more method instances. Left in the file:
        the symbol tables, the unwind tables and the debug information of the
        parts.
      - The owner approved the probe: Julia branch `0e707a7430`, CompilerServer.jl
        `b09342c`.
      - The dynamic symbol table of the image held 136,581 symbols of parts
        (48,378 functions and 88,203 slots; stock: 8 symbols), because the part
        symbols were protected. And each of the 25,046 objects of the parts had
        its own copy of the 7 helpers of 16-bit floats that codegen adds to each
        module (`injectCRTAlias`, internal): 175,000 local functions, each with
        a symbol and an unwind entry. Each object had its own `ccall` slots too
        (8,556 against 809).
      - A probe (not committed, 2 files): the functions and the slots of a part
        are hidden, and `jl_install_objects` looks them up among all symbols of
        its JITDylib; the 7 helpers are `linkonce_odr`, hidden and in a COMDAT
        group where the format has groups, so the link keeps one copy. The
        install already finds the code that a process has through its code
        instances (`apart_existing_address`), not by `dlsym`.
      - With it, on the same system image of Base (GenApp, small, whole builds):
        the image is 211,016,944 bytes (stock 188,590,976; before the probe
        230,698,912), 8 dynamic symbols, the start 85.4 ms (stock 80.8 ms), its
        own peak 232 MiB (stock 228 MiB), and its output is that of stock. The
        three `.so` files of the packages are 1,014,816 bytes (stock 915,304;
        before 1,989,008); their unwind tables and dynamic symbols are those of
        stock, and their `.text` is 60 kB smaller. The 63 tests pass, and the
        harness (`--executable none --agents 2`) passes its 211 checks.
      - Left in the image against stock: the heap +10.5 MB (`.ldata`: the code
        of the provider and the entries of the dispatch caches of its work),
        `.symtab` and `.strtab` +5.6 MB (154,303 symbols against 65,488: the
        local symbols of the functions and slots of the parts), the debug
        information +4.5 MB (a compile unit for each part), `.rela.dyn` +1.4
        MB and `.bss` +0.8 MB (the slots of the parts).
      - The owner approved the probe: Julia branch `67820a0472`.
      - The start scales with the heap of the image: in 10 loads of each image
        (`perf`, 20 kHz, `julia -J <image> -e ""`), parts take 7 % more samples
        than stock, +7.6 % in the kernel (page faults, 57 % of all) and +5 % in
        `jl_read_reloclist` (25 % of all); the heap is 6.8 % larger. The
        dynamic loader takes 0.07 ms in both. So the start reaches stock only
        when the heap does.
      - What the heap holds more (a census of the objects that the roots reach;
        it counts 6.6 MB of the 10.5 MB): 17,528 method instances that stock
        does not have, with their tuple types (19,510 more `DataType`s, 23,988
        more `SimpleVector`s, 5,345 more `Type{T}` kinds). 9,887 of them are of
        Serialization and 3,828 of Base, with no code instance: dispatch made
        them, for one `Type{X}` value each (for example
        `serialize(::Serializer{IOBuffer}, ::Type{GenApp.Counter6})`). The
        provider writes its records with Serialization, reads them back in a
        rebuild, and checks that each value of a new part reads back equal
        (`apart_round_trip`); on this Julia each `Type{X}` value has a kind of
        its own (`Core.TypeEgal{X}`), so each gets its own specialization of
        `serialize`, `deserialize`, `sertag` and others. Most of the other
        method instances have code that the provider made in its run (1,833
        inferred ones of Base), and the provider module has 190 methods.
      - Decision point (the owner decides):
        1. The store writes its records in a format of its own, with no
           Serialization: a type as its text or key, by code with no
           specialization for each type (a new format of the store). This also
           takes the JIT of Serialization out of each writer that makes new
           parts. Then I measure what is left.
        2. A Julia change: the writer of a system image leaves out what the
           provider made (the method instances and the code instances of its
           call, their cache entries, and its module). A larger change in
           several places of the writer.
      - The owner chose way 1 (CompilerServer.jl `9b6e724`, store format 4).
        The records and the manifests are only written and read by this
        package; the writer of a product only gets the table and the objects.
        `codec.jl` takes each value with `@nospecialize` and passes values only
        to builtins and to functions with `@nospecialize`: one specialization
        for each kind of value. A type is its structure (the reference of its
        type name and its parameters; `Type{X}` of kind `TypeEq` and
        `Core.TypeEgal{X}` each with a tag, because signatures of method
        instances hold the second kind); the wrapper of a type name reads back
        as that very object, because a `UnionAll` is not interned and an image
        saved a copy as another object (the rebuild then differed in 550 kB of
        each `.ji`); a struct is its type and its fields. A test set checks the
        kinds of values, the same bytes, the identity of a wrapper, and no new
        specialization for more type values. The package no longer loads
        Serialization.
      - With it: the 158 tests pass; the harness (`--executable none --agents
        2`) passes its 211 checks, each step equal to a whole build. The build
        of an edit takes 2.53 s (stock 2.85 s; before 2.57 s), its CPU 2.70 s
        (stock 4.99 s), the peak of one writer 331 MiB (stock 340 MiB; before
        347 MiB), the first build 4.96 s (stock 3.69 s; before 5.43 s), the
        cycle of an edit 3.15 s (stock 3.46 s), 2 agents 1,127 cycles in an hour
        (stock 1,109). The executable (a whole build on the same Julia as
        stock): the image 206,811,256 bytes (stock 188,590,976), its heap
        159,683,880 (stock 153,743,728), the start to the line `ready` 79.6 ms
        (stock 81.2 ms; medians of 7), its own peak 228 MiB (stock 228 MiB), its
        output that of stock, its first build 217.1 s (before 243.1 s).
      - The executable of a rebuild (the same store, the same folder) differs
        from that of a whole build: its image is 148 kB smaller, and 113 MB of
        its bytes differ. Two stock builds differ in 1,454,103 bytes of the
        image, and in 66 bytes with `--deterministic-object-ids=yes`; the build
        of an image with parts now has that option too (CompilerServer.jl
        `0e1058b`), and the difference stays. The cause is the provider in the
        build process: the image keeps what its run made, and that depends on
        whether it emits new parts or checks held ones. Against stock the image
        holds 3,797 more method instances (before the format of our own:
        17,528) and about 3.3 MB more objects by the census: Base code inferred
        for the types of the provider (1,726 inferred instances), its 190
        methods, and 167 instances for one type value each.
      - Decision point (the owner decides): the executable equals a whole build
        only when its image holds nothing of the provider. That needs a Julia
        change: the writer of a system image leaves out the provider module
        with its methods, and the method instances, code instances, cache
        entries and types that only the provider made. The other way: the
        image keeps the provider, and the comparison of the executable is a
        named gap.
      - How the writer filters already (read 2026-11-22): it asks the compiler
        for the code instances of the image before it calls the provider, saves
        for each method instance exactly those (`jl_rewrite_mi_caches`,
        upstream), and gives each other method instance an empty cache; a type
        of a type cache and a backedge are saved only when something else needs
        them. One more pruning exists only for `--trim`
        (`jl_prune_method_specializations`): a method instance is saved only
        when something else needs it.
      - The experiment (CompilerServer.jl `78dfe0e`, no Julia change): the prelude
        loads nothing; the writer includes the files of the provider at its
        exit, after the selection. The image is 203,562,344 bytes for a whole
        build and 203,455,560 for a rebuild (stock 188,590,976), its heap
        157,811,744 (stock 153,743,728), the start 79.3 ms (stock 80.3 ms), its
        own peak 227 MiB (stock 228), its output that of stock; a whole build
        takes 205.5 s, a rebuild 54.7 s. Against stock the image holds 3,067
        more method instances in a rebuild and 4,100 in a whole build; all but
        35 have no code instance (shells from the run of the provider). 1,151
        are only in the whole build and 118 only in the rebuild: the byte
        difference of the two.
      - Left for an equal executable, each a small change of the Julia branch
        (the owner decides): 1. the pruning of `--trim` for each image with a
        selection, so no shell is saved; 2. no method that is newer than the
        selection (the methods of the provider); then the byte comparison shows
        what else the run of the provider changes.
      - The probe of the first change (the owner approved it; not finished, not
        in the Julia branch; kept as `docs/probes/weak-specializations.patch` of
        CompilerServer.jl, commit `6924e54`). It is not the small change that I
        expected:
        - With it an executable builds and runs; 2,623 method instances with no
          code go that the stock image also has; the image goes from 203.6 MB
          to 201.9 MB.
        - The entries of the dispatch cache still refer to the shells of the
          provider's run: 2,121 extra method instances stay in a rebuild and
          3,110 in a whole build. With the whole dispatch cache dropped (a
          measurement only: the image then starts with a cold cache), no method
          instance is only in the whole build, 33 are only in the rebuild, and
          the image is 195.1 MB. So the dispatch cache needs the same rule: an
          entry only for a method instance that the image has code for. It has
          its own structure in `src/gf.c`.
        - The pruning of `--trim` is not correct for an image that compiles
          more code when it runs: a build of Julia itself with the probe fails.
          A method that keeps no specialization got a copy of the shared empty
          vector (fixed in the probe); the second stage still crashes in
          `jl_specializations_get_linfo_`. The next step there is a debug build
          of Julia.
        - The Julia tree is back at `67820a0472` and builds; the 158 tests of
          CompilerServer.jl pass on it.
      - Decision point (the owner decides): go on with these Julia changes for
        an equal executable (a medium change, general, in the writer and in
        `src/gf.c`), or keep the comparison of the executable as a named gap
        and go on with the next steps. The executable already starts as stock
        and has its peak; its image is 203.6 MB against 188.6 MB.
      - The owner: add a log of what goes into an image, and hunt the byte
        equality down. The log (`--trace-image-objects=<file>`, Julia branch
        `137800835e`; a tool, not for upstream): a line for each object that the
        writer saves, with its place, its type, a name with no address and its
        referrer. `bench/image_log.jl` (CompilerServer.jl `c50f02d`) compares
        two logs and maps each byte that differs to its object.
      - What the log found, each in one comparison:
        1. A rebuild put copies into the slots of the parts: a value that a
           record holds reads back as a copy (1,722 expressions, 714 unions,
           323 `UnionAll` types, 308 type variables, 39 regular expressions).
           Now a new part resolves its slots from its record too
           (CompilerServer.jl `a6db749`). The rebuild then holds 651 objects
           that the whole build does not (before: 7,251).
        2. Two rebuilds, each with all its code from parts, differed in 131
           bytes. 6 were stored ids of empty memories that the provider's code
           made first: a permanent object stored an id from its address while
           the ids were frozen. 3 were build ids of modules made at run time,
           from the clock (the two modules of the build script of
           PackageCompiler and the module of the provider). Both fixed in the
           Julia branch (`459678ed26`, 38 lines, in the code of the fixed ids).
           1 was the temporary name of our prelude, now a name from its text in
           the store (CompilerServer.jl `0f160c1`).
        3. Now two rebuilds differ in 50 bytes, in 5 places: the build id note,
           two checksums, and the temporary path of the build script of
           PackageCompiler (a string and a symbol). Two stock builds differ in
           these too.
      - What is left between a whole build and a rebuild (the objects that only
        one image saves, of 1.63 million): 1,151 method instances only in the
        whole build and 110 only in the rebuild, 1,067 and 50 entries of the
        dispatch cache, 32 code instances only in the rebuild (held by the
        roots of the methods of the provider), and the vectors, memories and
        debug information below them. All of it is what the run of the provider
        makes: a whole build runs the emission, a rebuild runs the checks of the
        held parts.
      - Decision point (the owner decides) for that rest:
        1. The image is always written by a process that takes each part from
           the store. The reactive cycle of S6 gives that: the server compiles
           the new parts, and the writer of an image only takes parts. Until
           S6, a build that made new parts in the writer of an image can write
           the image once more (57.7 s more for the executable of the test
           project). No Julia change.
        2. Julia changes that leave out what the run of the provider makes: the
           method instances, the entries of the dispatch cache, the roots, the
           methods (the probe of the first one is not finished).
      - The owner chose way 1 (2026-11-22): "Yes, I hope that won't make the
        performance worse. Let's see".
      - Way 1 is done, with no change of Julia (CompilerServer.jl `4dc7a07`,
        `abaa8c1`; 166 tests pass):
        - `create_sysimage_with_parts` and `create_app_with_parts` run the
          build once more when the process that wrote the image made new parts
          (`apart_image_passes`).
        - A build of the code of the store made 128 parts again each time, so
          each build needed the second pass. The causes, found with debug
          lines of the provider: 100 parts had an edge to
          `Base.type_parameter(::Type{Type{T}})`, where `T` is the type
          variable of the wrapper `Type`, and a free type variable read back as
          a new object; 13 had the null address as a constant; the other 15 can
          serve no build (the literal `Dict` of an `@enum`, a `BigFloat`
          constant, a type of the module with no path of the build script of
          PackageCompiler, the method `Base.include` that Base deleted).
        - The format of a store (format 5) holds a type variable of a wrapper
          as that very object, and the null address.
        - The writer compiles a function itself when the newest version of its
          part was made from the same code and serves no build, or when the
          format does not hold the interface of the function: 17 of the 32,198
          functions of the executable. So a build of the code of the store
          makes no part.
      - The result (test project, small, 8 cores): the image of a whole build
        and the image of a rebuild differ in 50 bytes of 203,407,912, the same
        50 bytes as two rebuilds and as two stock builds (the name of the
        temporary folder of PackageCompiler). The guard compares the image of
        each executable step with a whole build and takes at most 64 bytes:
        218 checks pass. The four Julia changes that were planned for an equal
        executable (weak specializations, the rule for the dispatch cache, the
        correct pruning, no method newer than the selection) are not needed
        for it; `docs/julia-changes.md` keeps them as possible gains of size.
      - The cost (the harness, wall time of the build of the executable):

        | step | stock | parts | passes | new parts in the image writer |
        |---|---|---|---|---|
        | the first build | 76.6 s | 266.4 s | 2 | 32,197 |
        | after an edit of a leaf function | 70.5 s | 109.4 s | 2 | 17 |
        | the edit taken back | 70.9 s | 55.5 s | 1 | 0 |
        | a new worktree, the same commit | 75.8 s | 115.2 s | 2 | 3 |

        A pass with all parts held takes about 55 s. So the second pass costs
        about 55 s in each step that makes a new part in the writer of the
        image: the build after an edit is then 1.55 times stock.
      - Why the writer of the image makes new parts when the writers of the
        package files made theirs before:
        - The image has specializations that no package file has, from the
          workload of the executable. After the edit of a function that callers
          inline, the package writers made 5 parts and the writer of the image
          needed 8 more (`GenLow.pick1(::Rational{Int64})`, `GenLow.report()`,
          `GenMid.report1()`, `GenApp.julia_main()` and others).
        - Inference gives a function other code in another worktree:
          `GenApp.julia_main` has 57 edges in the first worktree and 60 in each
          other one (it inlines `println` there). The image of stock differs
          between worktrees too (188,582,768 and 188,583,416 bytes).
      - Decision point (the owner decides): the second pass is the price of
        equal bytes until S6 makes the parts before the image is written.
        1. A setting: the second pass runs only on request (for a release, and
           in the guard); the build of the edit cycle takes one pass (55 s), and
           its image differs from a whole build by what the run of the provider
           makes.
        2. Keep the two passes for each build until S6.
        3. Do S6 next, before the other items of S3.

        Asked 2026-11-23, with my recommendation (way 1). The owner gave no
        answer before the night and said to continue as planned: the question
        waits, each build keeps its two passes, and the work goes on with the
        other items of S3.
      - The guard has bounds for the sizes now (CompilerServer.jl `f36cf00`):
        each measure of `GEN_MEASURE_BOUNDS` is not above stock in the same
        step, or inside the bound of its gap: the package files (`.ji` 1.01,
        `.so` 1.13), the image of the executable (1.09), its folder (1.02), its
        build (3.7 for the first one, 1.7 for a later one), its build peak, its
        start, its peak, and the JIT compilations in use. 338 checks pass on the
        run of 2026-11-23.
      - Where the 14.8 MB of the image above stock are (the executable of the
        test project, 203,407,912 against 188,592,352 bytes; sections of the
        two files, and the logs of their objects):

        | what | bytes above stock | cause |
        |---|---|---|
        | `.symtab` and `.strtab` | 5.37 MB | 149,827 symbols against 65,614: 85,997 slots of parts (stock has 8,815 slots in all), and each part has its own symbols of the `ccall` slots |
        | the debug sections | 4.5 MB | a compile unit for each part: its own abbreviations, line program header, name tables |
        | the objects of the heap | 2.75 MB | what the run of the provider leaves: its module (0.90 MB: 222 methods, their bindings, code instances and types) and the code of Base for its types (1.85 MB: 2,467 method instances, 3,377 types, 1,448 entries of the dispatch cache, with inferred code) |
        | the tables after the objects of the heap | 1.6 MB | the slots and the functions of the parts in the tables of the image |
        | `.rela.dyn`, `.lrodata`, `.data.rel.ro`, `.eh_frame` | 2.4 MB | a relocation and a table entry for each slot and each function of a part |
        | `.text` | -1.9 MB | |

        A part has a slot of its own for each object that its code names, so
        the image has 9.8 times the slots of stock, each with a symbol, a
        relocation and a table entry: about 8 MB of the 14.8 MB follow from the
        slots.
      - The level of the debug information (`-g0` in the arguments of the
        image build; both images built again; the whole run of the executable,
        median of 7, is 558 to 565 ms for all four):

        | | image, level 1 | image, level 0 | a stack trace at level 0 |
        |---|---|---|---|
        | stock | 188,592,352 | 181,243,864 | function names, no file and no line |
        | parts | 203,407,912 | 191,666,896 | no frame of the image (built with the fault below) |

        Level 0 is no choice for a product that must show where an error is.
        `--trim` is not measured: `create_app` of PackageCompiler has no way
        for it, and the trim needs a build script of its own.
      - A fault found on the way: a stack trace in an executable with parts
        had no inlined frames and no method instances. The list of code of the
        writer of an image names a code instance more than once (50 thousand
        items for 32 thousand functions). The branch gives each item two
        indexes in the table of function pointers of the image, and only the
        last pair gets the code instance. The lookup of a frame takes the first
        index with the address of the function. So 23,197 of 24,577 function
        pointers found no code instance (stock: 0 of 12,631), and the table had
        99,937 indexes, 51,910 of them with no code instance. The package files
        do not have the fault.
        - A probe in the Julia tree (6 lines in `jl_create_native`, in code
          that the branch added; `docs/probes/one-table-index-for-each-code-instance.patch`
          of CompilerServer.jl): the table takes a code instance once. With it
          no pointer misses, the stack trace is that of stock, and the image is
          2.27 MB smaller (201,136,368 bytes). The 166 tests of CompilerServer.jl
          and the `compile_apart` tests of Julia pass.
        - The generated app now prints a stack trace of an error in compiled
          code (the line `trace` of `GenApp.julia_main()`), and the harness
          compares it with stock in the session of use and in the executable
          (`use_trace`, `exe_trace`). The guard has `exe_trace` as a known
          failure until the fix is in the branch (CompilerServer.jl `2f565bf`): on
          the committed Julia branch 362 checks pass, and the 4 executable steps
          report the known failure.
        - The harness with the probe (2026-11-23, executables with the
          comparison, 2, 4 and 8 agents): 365 checks pass. The image is
          201,193,792 bytes against 188,640,320 of stock (1.07; before 1.08),
          the start 76.0 ms against 79.6 ms, the stack trace is that of stock in
          the 4 executable steps and in the 23 sessions of use, and the image of
          each step differs from a whole build in 49 or 50 bytes.
        - The owner approved the fix on 2026-11-23: Julia branch
          `dd7c4b9ec4`. The guard has no known failure now, and the stack trace
          of the executable equals that of stock in each step (CompilerServer.jl
          `09a3f24`).
      - What the stack trace in the app showed next: the first stack trace of a
        process reads the debug information of the image, and the image with
        parts has a compile unit for each part. In the executable of the test
        project the first stack trace takes 35.9 ms and 34 MiB with stock, and
        49.4 ms and 69 MiB with parts (the second one 0.4 ms in both). So the
        peak of the executable, which now has a stack trace in it, is 283 MiB
        against 250 MiB (with no stack trace: 227 against 228). The guard has
        it as a gap with the bound 1.2.
      - A fault that the harness found on 2026-11-23, on the Julia branch
        with the two fixes (`ff99565fbb`): the image of the executable of the
        second worktree differed from a whole build in 112 bytes (the bound is
        64). 368 of 369 checks pass; this is the one that fails.
        - The 112 bytes: 50 as between two stock builds, and 62 in the numbers
          of the names of 30 adapter functions (`j_13_gfthunk` against
          `j_61_gfthunk`). The code is equal.
        - Cause: stock codegen names the adapters of a `@cfunction` with a
          counter of the process, and a part keeps them as local definitions.
          So the bytes of a part with a C callback depend on which parts the
          process made before it. The smallest example: one part, emitted two
          times in one process, gives two objects that differ in 1 byte.
        - Why it shows only now: the app records its session since S8, so the
          image has four functions that write to a terminal or a pipe, each
          with a C callback. The build of the second worktree listed them at
          another place: they are near text symbol 4,376 of the 48,444 of the
          image, by address, against 13,961 and 22,953 in the first worktree.
          A whole build there numbers their
          adapters in its own order; a rebuild takes the parts with the
          numbers of the process that made them. The fault is older than the
          two fixes: an edit that moves such a function in the list shows it
          too.
        - The same commit in a second worktree gives 0, 1 or 3 new parts, by
          the run (8 runs: 3, 0, 0, 0, 0, 1, 3, 0). With a new part the build
          takes two passes (about 115 s against about 62 s). The cause is the
          fact above
          that inference gives a function other code in another worktree; why
          it differs between runs is not known.
        - A probe in the Julia tree (10 changed lines in `emit_part_module`,
          in code that the branch added, and a test in `compile_apart`;
          `docs/probes/local-names-from-the-part.patch` of CompilerServer.jl):
          a definition that a part keeps for itself gets the name
          `jl_local#<index>`, by its place in the module of the part. With it:
          the two objects of the smallest example are equal; the image of the
          executable is 44,016 bytes smaller (201,686,216 against 201,730,232);
          the output and the stack trace of the executable are the same; a
          build of the package files with each part in the store takes the
          same time (3.48 s against 3.53 s, the median of 8 builds each, in
          turn); the 166 tests of CompilerServer.jl and the `compile_apart`
          tests pass.
        - A harness run with a first form of the probe (names that also hold
          the name of the part; the image was 0.46 MB larger): 366 of 369
          checks pass, and the image of each step differs from a whole build
          in 48 to 50 bytes. In that run the second worktree listed the code
          in the order of the first, so the run does not test the fix; the
          smallest example does. The 3 checks that fail are times, above their
          bounds by 0.1 to 4.5 %; the machine was busier, and the measure in
          turn shows no cost.
        - The owner approved the probe on 2026-11-23: Julia branch
          `d697d45a14`, with a test in `compile_apart`; change 24 of
          `docs/julia-changes.md` (CompilerServer.jl `9777558`).
        - The harness on that state: all 369 checks pass. The run had the case
          that failed before: the second worktree listed the four functions at
          another place again (text symbols 3,950 to 3,997 against 13,977 to
          23,025 in the first worktree) and made 4 new parts, and its image
          differs from a whole build in 49 bytes. The machine was busy in that
          run (load 16 to 20), so its times are no measure of the speed.
      - The bounds of the guard after the two fixes (CompilerServer.jl
        `09a3f24`): the image of the executable 1.07 (before 1.09), its first
        build 2.2 (before 3.7), a later build 1.6 (before 1.7).
      - Proposals for the size, each a change of how the branch emits a part
        (the owner decides; none is started):
        1. One slot for one object in an image, as stock has: the name of a
           slot comes from the key of its object, not from its part, and the
           link keeps one copy. It removes most of the 8 MB of the slots. It
           changes the objects of the store and the call of the emission.
        2. The debug information of the parts in a form that costs less: no
           name tables (about 1 MB of the file), and a table of the address
           ranges of the units, so that the first stack trace need not read
           each unit (the 35 MiB and 13 ms above; not tried).
        3. The image leaves out what the run of the provider made (2.75 MB):
           the changes of `docs/julia-changes.md` that were planned for equal
           bytes.
      - Left of S3: the decisions above, and the gate of the sizes with the
        bounds that they give.

- [ ] **S4. A first build that is not slower than stock.**
      - Measure where the time of the emission of all parts goes (the LLVM work
        of each object, the keys, the records, the round trips, the files).
      - Either make the emission as cheap as stock, or make the first build a
        stock build and the parts after it, on the free cores.
      - Decision point: I report both ways with their numbers, and the owner
        decides.
      - Gate: the first build with an empty store is not slower than stock.
      Facts found in the work (2026-11-23):
      - Where a build of the executable spends its time (test project, small,
        8 cores; the stages from the output of PackageCompiler, the timers of
        the provider and the image timings of Julia):

        | stage | stock | parts, each part in the store | parts, an empty store |
        |---|---|---|---|
        | before the image process | 2.7 s | 2.0 s | 2.0 s |
        | the image process until the machine code: its start, the load of the packages from their sources, the statements of the workload, inference | about 34 s | 34.1 s | about 34 s |
        | the machine code | 21.7 s: LLVM in 8 threads, 147.7 s of CPU time | 7.9 s: the provider checks 32,197 records | 167 s: the provider (emission 142.8 s, files of the store 8.9 s, checks 6.7 s, table 4.0 s, records 2.8 s) |
        | the heap of the image, the object files, the link | in the rest | 8.7 s | about 9 s |
        | all | 68.9 s | 53.9 s | about 212 s, then the second pass |

        A build with each part in the store runs on one core: 55 s of wall
        time, 54 s of CPU time.
      - Why the emission was slow. In the 146 s of the emission the main thread
        of the writer had 112 s of CPU time, and the worker threads 170 s
        together (1.2 cores; stock has 147.7 s for the same functions). A
        profile of the main thread: about 80 % of its time in
        `emit_part_module`, almost all of it for the map of the names of all
        code instances, which the branch made again for each part: 32 thousand
        parts with 50 thousand names each. The code generation had under 3 %
        of the samples.
      - A probe in the Julia tree (22 changed lines in code that the branch
        added; `docs/probes/one-names-map-for-each-emission-call.patch` of
        CompilerServer.jl): the map is made once for each call of
        `jl_emit_objects`. The whole build of the executable, with its two
        passes: 172.5 s (before: 258 s); the main thread has 31 s of CPU time in
        the emission.
      - With it, larger groups of parts for each call (CompilerServer.jl only;
        before: 4 parts for each thread). The whole build of the executable and
        the peak of a writer in the first build of the package files (stock:
        335 MiB, bound 1.15), by the parts for each thread in a group:

        | group | whole build of the executable | peak of a package writer |
        |---|---|---|
        | 4 | 172.5 s | 366 MiB |
        | 16 | 159.7 s | 367 MiB |
        | 32 | 149.5 s | 376 MiB |
        | 64 | 145.8 s | 387 MiB |

        The group is 32 now. The first build of the package files takes 4.9 s
        with each group (stock 3.7 s).
      - The harness with both probes of the Julia tree and groups of 64
        (2026-11-23): the first build of the executable 156.3 s (stock 76.0 s;
        before 266 to 272 s), after an edit 109.1 s (2 passes), with no new
        part 56.2 s, a whole build in the comparison 148 s (before 258 s), the
        image of each step 49 or 50 bytes from a whole build. 364 of 365 checks
        pass; the one that fails is the peak of the first build of the package
        files (394 MiB), which the group of 32 keeps at 376 MiB.
      - What is left of the first build against stock (about 70 s), each with
        its way:
        1. The second pass, 54 s: it goes when S6 makes the parts before the
           image is written, or with the setting of the open question of S3.
        2. The emission, about 44 s against 22 s: the code generation of the
           next parts while the worker threads compile (one pipeline in
           `jl_emit_objects` in place of groups) gives about 31 s.
        3. The first pass writes and links an image that the second pass
           writes again: about 9 s.
        4. The other way of this step, a first build by stock with the parts
           made after it: the executable is there after about 70 s, but it is
           not the executable of a rebuild in every byte; the parts cost one
           more build process of about 92 s on the free cores.
      - The owner approved the fix on 2026-11-23: Julia branch `ff99565fbb`.
      - The harness on that state (2026-11-23; test project, small, 8 cores,
        groups of 32 parts for each thread, wall time of the build of the
        executable):

        | step | stock | parts | passes |
        |---|---|---|---|
        | the first build | 78.4 s | 160.8 s | 2 |
        | after an edit of a leaf function | 72.2 s | 110.3 s | 2 |
        | the edit taken back | 71.3 s | 56.9 s | 1 |
        | a new worktree, the same commit | 77.5 s | 114.6 s | 2 |

        A whole build in the comparison takes 149 to 151 s. The first build is
        2.05 times stock (before the fix: 3.3 times).
      - Decision point (the owner decides): which of the ways 1 to 4 to take.

- [ ] **S5. Inference results from records.**
      - A writer takes the inference results of each function whose record
        holds, and infers only the others; the records check the identity of
        the code in depth, as the check of the parts does now. This also gives
        `install_apart` the check of the identity.
      - Decision point: the hook in Julia must be small and simple; if it is
        not, I stop and report.
      - Gate: the writers of an edit infer only the new parts; each output
        equals stock; the time of item 5 drops as S1 measures it.

      Facts found before the work (2026-11-23; nothing is built):
      - The hook is in stock Julia: `jl_set_typeinf_func(f)`, which is exported
        and which `Compiler.activate_codegen!()` uses. The runtime calls
        `f(mi, world, source_mode, trim_mode)` when it needs the code of a method
        instance, and takes the code instance that `f` answers. So a package can
        answer from the store first, and call the inference of Julia for the
        rest: no change of Julia for the hook.
      - The hook sees the requests of the runtime, not the inference of a
        callee inside the compiler. That fits: a function whose result comes
        from the store needs no inference of itself or of its callees.
      - What an answer from the store needs, each a question of design:
        1. The stored results of a method instance with no return type known:
           the name of a part holds the return type, so the store needs an
           index by method and types.
        2. The check of a record from records alone: the check of today
           (`apart_record_holds`) reads the code instances that inference made
           (their edges, and the identity of the code of the callees in depth).
        3. The code instance from the record, with the machine code of its
           part in the process (`jl_install_objects` of the branch), before the
           workload of a package runs.
        4. The inferred source, which later inference inlines: a record holds
           none, so a caller that is inferred new would get other code than in
           a whole build.
      - What it can save: of the 34 s that a build of the executable needs
        before its machine code, and of the 0.84 s of a writer of one package
        file, the part that is inference. That part is not measured alone yet.

- [ ] **S6. The reactive cycle.**
      - The compiler server of CompilerServer.jl keeps the worktree loaded,
        applies each edit, compiles only what the edit makes invalid, writes
        the new parts into the store, and runs the selected tests in the
        process that is already loaded.
      - The package files and the executable are made from the store after
        that, on the free cores, and S2 checks their bytes.
      - Gate: the cycle time of each edit is below stock; the products equal a
        whole build in every byte.

      Facts found before the work (2026-11-23; a measure only,
      `bench/reactive.jl` of CompilerServer.jl `fbfdbab`):
      - CompilerServer.jl has the loaded process already: `rc_load_tracked`
        loads the packages of a worktree from their sources, and
        `rc_apply_request` applies an edit (the ledger of the top-level
        expressions, and the replay of the items whose result an edit changes).
        The measure adds the store: after each apply the process runs the
        workload of the packages again and calls the provider of a writer with
        its own code instances, so the store gets the parts of its code. Then
        the writers of the package files build as in the harness.
      - It works from end to end on the test project: the 10 edits of
        `edits.jl` and their takings back are all applied.
      - A fault found on the way and repaired: the loaded process gave a
        package no origin, so `pkgdir` was nothing, each method had the absolute
        path of its file as its place, and no part of the store had a name of
        that process.
      - With no edit, the loaded process takes 1,606 of the 1,627 parts of the
        writers from the store: the two sides agree on the names and on the
        records. The loaded process has 4,039 more functions, which it compiled
        with the JIT and no package file has.
      - After an edit, the loaded process makes parts that the writers then
        take. The parts that the writers still make:

        | edit | the writers alone | after the loaded process |
        |---|---|---|
        | the body of a leaf function | 12 | 2 |
        | the body of a function that callers inline | 5 | 2 |
        | the bottom of a chain of inlined functions | 2 | 1 |
        | the type of a field of a struct | 7 | 3 |
        | lines that move | 168 | 168 |
        | a file with a new name | 168 | 168 |

      - What the cycle costs in the loaded process today, for an edit of a
        body: the apply about 8 s, the workload 0.4 s, the parts about 2 s.
        The writers after it take 2.6 to 2.8 s, as with no loaded process. So
        it is no gain yet. The causes:
        1. The apply: 0.2 s for a comment, 3.5 s for lines that move, about 8 s
           for a body. The checks of the replay start two processes that load
           the program of before the edit from its sources (4.5 s and 3.9 s in
           one measured apply).
        2. The parts: after an edit of a body the loaded process makes about
           630 parts, 576 of them with names that no build had before (the
           apply evaluates about 25 expressions again, and the code of them and
           of their callers gets new names).
        3. Lines that move, and a file with a new name: the methods of the
           loaded process keep their old places, and the place of a method is
           in the name of its part.
        4. The list of functions: the loaded process has what its session
           compiled, the writer has what the workload of its package compiled.
      - Design questions for the owner, before the work of this step: how the
        replay gets the program of before the edit with no new load; which
        list of functions the loaded process compiles; how a method keeps its
        place when its lines move; who writes the package files and the image
        after the loaded process (a writer process of today takes 0.84 s for a
        package and 54 s for the executable with each part in the store).

      Facts of 2026-11-23, noon, after the owner made this step the next one
      (`bench/reactive.jl` with the memory of the process; the machine was
      busy, load 13 to 23, so each time is an upper bound):
      - The loaded process: the load of the 3 packages from source 5.45 s, the
        first workload 1.2 s, resident memory 725 MiB after the load and
        1,069 MiB after 20 applies (about 17 MiB for each apply).
      - The apply of an edit of a body takes 11.6 s there (about 8 s on a
        quiet machine), but its own work is 0.40 s: "applied 25 expressions
        and 0 removals in 401.2 ms". The rest is the two check processes,
        each of which loads the project again.
      - The 25 expressions: the edited method, and 24 expressions of
        `src/part2.jl` of the three packages whose result the trial found
        changed (8 for each package). They are right to evaluate again.
      - The 576 parts with new names after an edit of a body (192 for each
        package whose expressions the apply evaluates again): each of the 24
        expressions has an anonymous function at the top level, and Julia
        names it with a counter of the module (`GenLow.var"#159#160"`). The
        new evaluation gives it the next numbers, so the function and the
        code of Base for it (`iterate`, `collect_to_with_first!`, `grow_to!`,
        8 functions for each) have types that no build has. A writer process
        gives them the numbers of a load from the start. So these parts serve
        no build: about 2 s of the cycle is lost on them. The parts of really
        changed code are about 60 (the writers alone make 21).
      - The apply already knows what it made invalid: 172 method instances of
        methods that it defined again ("cone replaced") and 145 whose code
        the edit closed ("cone closed"). The measure does not use that list:
        it gives the provider all 7,168 functions of the process, and the
        provider checks each record again (1.44 s with nothing to do).
      - The start of a binary by its shape (time to the first line, median of
        7 starts, the same busy machine): Julia with the base image 104.5 ms;
        the base image and the 3 package files of the project 132.7 ms; the
        first line of the app from them 133.9 ms. The executable with one
        image for all: 78.2 ms (stock), 80.2 ms (parts), on a quiet machine.
      - What follows for the work, with no decision needed: the loaded process
        gives the store only the parts of the code that the apply made
        invalid, and keeps the result of each record check for a code
        instance that stays valid.
      - Decision points (the owner decides): the shape of the binary in the
        cycle of seconds (asked 2026-11-23); how the check of an apply gets
        the program of before the edit with no new load; names of anonymous
        functions of the top level that do not come from a counter.
      - The provider with only the new code (CompilerServer.jl `79fe1ab`,
        `bench/reactive.jl`; CPU time of the loaded process, because the
        machine ran other jobs): a function with a new code instance since
        the last call goes to the provider, the others not. With no edit:
        0.08 s (all 7,168 functions: 2.7 to 3.2 s). After an edit of a body:
        827 functions, 672 new parts, median 6.3 s (all functions: 6.6 to
        10.0 s, and that list grows with each apply, from 7,732 to 10,342 in
        6 applies). The cost is the new parts: 576 of code with counter names
        and about 110 of functions that call such code, which are made again
        at each edit. Without the 576 (a filter by the form of the name, for
        the measure): 203 functions, 120 new parts, median 2.5 s. The code
        that the edit really changed is about 60 parts. So the names from a
        counter are the next blocker of this stage.
      - The owner, 2026-11-23, about the question of the shape: "I need more
        documentation, especially diagrams, to understand the whole build
        process. [...] I can't decide becuase I don't understand what's going
        on." The answer is `docs/architecture.md` of CompilerServer.jl
        (`6197728`), with nine diagrams: the stages of a build, what depends
        on what, the files, stock Julia, the merged branch and
        CompilerServer.jl side by side, four case studies, and the three
        decisions with their options. The question of the shape waits until
        the owner read it.
      - The owner read it, 2026-11-23: "decision 1: all shapes should be
        possible like in merged branch, no? decision 2: I don't understand why
        would a forked child write the parents memory? copy-on-write?
        decision 3: fix the counter issue".
        - Decision 1 (the owner): each shape of the binary must be possible.
          The shapes are writers behind one front (the loaded process that
          applies the edit and makes the parts of the cone); only the order of
          the writers is open.
        - Decision 2: the owner is right that a fork is copy-on-write. The one
          exception is the JIT: on Linux it writes new code through a handle
          of `/proc/self/mem` that it opened at its start, and after a fork
          that handle still names the memory of the parent. Measured
          (`test/gates/fork_compile.jl` of CompilerServer.jl, 40 forks, parent
          and child each compile 30 new functions, one Julia thread, one GC
          thread): a plain fork fails (children: illegal instruction; the
          parent: segmentation fault); when the child first opens its own
          `/proc/self/mem` and puts it on the same handle number (`open`,
          `dup3`, `close` from Julia code), 0 of 40 children fail and all
          1,200 functions of the parent are right. So the checks of an apply
          can run in a fork with no change of Julia. Asked 2026-11-23: do I
          use it. The owner: "yes".
          Done (CompilerServer.jl `42e980e`): `rc_in_copy` of `src/replay.jl`
          forks where the process can fork (Linux, one Julia thread, a JIT
          that writes through `/proc/self/mem`), and else starts a new process
          as before. The child repairs the handle first, collects no garbage,
          answers through a pipe and leaves through `_exit`. 167 tests pass
          (one new: an apply whose checks fork, in a process that compiles new
          code after the forks). The gate of the edit cases passes with
          `--threads=1`: 43 applied, 12 refused, each as expected, and the
          program equals a fresh load. Measured on a busy machine (load 26 to
          29), the edit of a body: an apply takes 3.0 to 4.0 s (before, on the
          same machine: 11 to 19 s; about 8 s on a quiet one). Of that: the
          trial 2.1 s, the check of the load order 0.3 s, the evaluation of
          the changed expressions 0.3 s.
          What is left: the trial evaluates each expression whose result can
          depend on an edit (97 here) and compares the results. It does not
          know which of them the edit can reach, so its time grows with the
          project. A record of what each such expression ran, taken at the
          load, can limit the trial to the expressions that the edit reaches;
          not designed.
        - Decision 3 (the owner): fix the names from a counter.
          The cause is wider than the counter (`test/gates/closure_names.jl`
          of CompilerServer.jl `4df9d06`). Julia names a closure by the history
          of the process, with two rules: at the top level a counter of the
          module (`jl_module_next_counter`), and inside a function `f` the
          first name `f##0`, `f##1`, ... that the module does not have
          (`julia-module-unique-name` in `src/ast.c`). The definition
          `f(v) = map(x -> x + 1, v)`, evaluated three times in one process,
          gives `#f##0#f##1`, `#f##2#f##3` and `#f##4#f##5`. So each edit of a
          function with a closure gives, in the loaded process, a name that no
          writer process has. The ways (section 11.5 of
          `docs/architecture.md`): the loaded process gives an expression the
          names of its first evaluation (needs a way to set the counter and to
          free the old names: two small Julia changes); names from the place
          of the definition (a change of the lowering); or the loaded process
          writes the products itself in a fork, so that no name must agree in
          the cycle of the person. Not chosen yet.

      The image of the executable from a fork of the loaded process
      (2026-11-23; the owner approved the experiment: "Yes"; CompilerServer.jl
      `f79b8fa`, `bench/fork_image.jl`):
      - The way: the loaded process runs in the output mode of the image
        process of PackageCompiler (`--output-o`, `--pkgimages=no`, one Julia
        thread, one thread of the collector, the prelude of the provider). For
        a save it forks. The fork repairs the handle of the JIT, does the end
        of the script of the image process, points the image writer at a new
        archive (it writes the field `outputo` of `jl_options`) and calls
        `jl_write_compiler_output`, which Julia exports. The archive links as
        PackageCompiler links its own. No change of Julia.
      - It works: the executable with the image of a save gives the output of
        its sources, with no edit and after the edit of the body of a leaf
        function; it compiles 1 function when it runs.
      - A fault of the provider, found and repaired on the way: a process that
        defined a method again holds the method that dispatch finds and the one
        that it replaced; Julia keeps the code instances of both, and both have
        one part name (the same place and types). The provider gave both the
        machine code of the first in the list, so a dynamic call of the edited
        function ran the old code (4 of the 5 numbers of the output were new,
        the picture was old). Now a name stands for the code instances of the
        method that dispatch finds (`apart_dispatch_finds`), and the writer
        compiles the function of the replaced method itself. 172 tests pass.
      - The cost (busy machine, load 5 to 13): a save 59.5 to 68.6 s, of which
        50.6 to 59.2 s until the provider ends and 8.9 to 9.4 s for the heap
        and the objects; the link 3.8 s; the apply 3.0 s. So about 67 s from
        the edit to the executable (the writer way: 56.9 s with no new part,
        110.3 s with one). The image has 229 to 232 MB against 201.7 MB: it
        holds CompilerServer.jl and the measure script too. The job peaks at
        6.1 GiB.
      - Why the 50 to 59 s: the image writer of Julia infers the code of each
        selected function before it calls the provider, and the provider
        checks the record of each of the 36,700 functions. Both are work for
        code that did not change, and the fork does it again at each save.
      - What does not help: an inference of all code in the loaded process
        before the save. Julia does not keep the result between two calls
        (99,166 functions: 28.8 s, then 27.6 s again; 1.1 GB more memory for
        each call).
      - What helps, by the measure: the provider answers before inference,
        from a table that the loaded process keeps (a code instance that is
        still valid has its checked part). Then the fork infers and checks
        only new code, and about 13 s are left (heap, objects, link): the
        floor of one image for all. This is the form of the hook that the
        review of 2026-11-22 proposed ("the provider answers the list to
        compile with the table", `docs/julia-changes.md`), and it is a change
        of the Julia branch.
      - Also open for this way: the image keeps the replaced methods and the
        code that the loaded process itself needs (CompilerServer.jl); the
        merged branch prunes them in its image writer.
      - Decision point (the owner decides): the change of the hook in the
        Julia branch, after a probe.

      An option to investigate (the owner, 2026-11-23: "We should also
      consider storing the inferred types, etc and other intermediate steps in
      1-5 as you mentioned if that makes the process faster. Add this to the
      plan as an option to investigate."). Not started.
      - What it is: the stages 1 to 5 of a build (start, load of the
        dependencies, evaluation of the source, workload, inference) leave
        their results only in the memory of the process that did them. The
        store keeps only the result of stage 6, the machine code. The option:
        the store also keeps results of the earlier stages, so that a later
        process takes them and does not make them again.
      - The results that a store can keep, by stage:

        | stage | its result | where it stands today |
        |---|---|---|
        | 3 evaluation | the objects that one top-level expression makes: methods, types, constants, the types of closures | the "definition part" of `docs/linked-products.md`: a design, not built |
        | 3 evaluation | the machine code that the top level itself runs (the JIT compiles 274 methods in a load of GenLow: 0.375 s of 0.47 s) | not kept; a code provider for the JIT could give it from parts (`jl_install_objects` of the branch) |
        | 4 workload | the list of the calls that the workload compiled | kept as statements in the executable build; a package writer runs the workload each time |
        | 5 inference | the typed code of each function, with its edges | step S5: a record holds the results of inference for the install; the hook `jl_set_typeinf_func` is in stock Julia |

      - What to measure first: the time of each stage alone, in a package
        writer and in the image process of an executable (inference is not
        measured alone yet), and then the time that each stored result saves.
      - How it joins the other work: with a fork, the loaded process holds
        these results in memory and a copy of it can write a product, so the
        cycle of one person does not need them from a store. A batch writer
        (an agent, a new worktree, a first build) has no loaded process, and
        there a store of these results is the way to skip the stages.
      - Decision point (the owner decides): after the measure, which results
        go into the store.

- [ ] **S7. The selection of tests and the test builds.**
      - Record what each test ran, once for each full run: the methods whose
        lines it reached.
      - For an edit, select the tests that ran a changed method, or a method
        whose identity of code changed.
      - The edits of the harness that change results make the full suite fail:
        the selection must include each test that fails.
      - Gate: no failure is missed; fewer tests run than the full suite; the
        test build time and the test duration are below stock.

- [ ] **S8. The application.**
      - Record the JIT compilations of the session of use and of the frames,
        and add them to the recorded list of the package that sees their
        types.
      - Measure the start part by part: the load of the image, the
        initialization of the packages, the first line.
      - Decision point: if the start can reach 100 ms only with a change of how
        Julia loads an image, I report it, and the owner decides (the earlier
        rule takes nothing from the pre-relocation of the fork).
      - Gate: no JIT compilation in the session of use; each frame below 30 ms;
        the start below 100 ms, or a named gap; the memory of the executable
        not above stock.

      Facts found in the work (2026-11-23; the first item):
      - What a session compiled before: the executable 25 functions with the
        JIT (stock the same), the session from package files 272. In the
        executable: the 16 painters of the frames (`leaf1(::Int)` and others,
        which the workload inlines and the frames call with dynamic dispatch),
        the output of a number to the standard output (a dynamic call for each
        kind of stream), and one call of the start code.
      - A rule of Julia that decides the form of the recording: a package file
        keeps the code of a callee of a dynamic call only when a `precompile`
        statement of the package that has the method names it. A run of the
        session in the writer of the application keeps no painter of the
        package below, and a statement in the application for a method of the
        package below keeps none either.
      - So the generated project now has (CompilerServer.jl `78d80e7`):
        1. the application runs its session once in its own precompile
           workload, and compiles its run for each kind of stream that the
           standard output can be (a terminal, a pipe, a file);
        2. each package has a recorded list for its own methods: the painters;
        3. the executable has a recorded list of the calls that no workload
           compiles (`statements.jl`, a `precompile_statements_file` of
           PackageCompiler): the output of a number to each kind of stream,
           and the call of the start code.
      - The result (harness of 2026-11-23, stock and parts the same): the
        executable compiles no function in its session, with a file and with a
        pipe as its output (before 25); its first frame takes 7.7 ms (before
        11.7 ms), its slowest frame 8.5 ms, its start 76 ms with parts and
        79 ms with stock. The session from package files compiles 1 function
        (before 272; the one left is a function of Base for the text of an
        error), its first frame takes 7.7 ms (before 11.5 ms), its slowest
        frame 12.1 ms (before 29.1 ms), its peak is 265 MiB (before 353 MiB).
        The guard fails when the executable with parts compiles a function in
        its session; 362 checks pass on the run, 366 with that check.
      - Of the gate: no JIT compilation in the session of use, each frame
        below 30 ms and the start below 100 ms hold. The memory of the
        executable is above stock: 275 MiB against 240 MiB, the gap of the
        debug information of the parts (S3).
      - The cost: the writer of the application runs the session, so each
        build of the chain is longer, for stock and for parts: the cycle of an
        edit 4.28 s and 4.08 s (before 3.47 s and 3.14 s), the first build
        4.83 s and 6.87 s (before 3.7 s and 4.9 s), the `.ji` files 8.3 MB
        (before 6.7 MB), the peak of a writer 488 MiB and 466 MiB (before 334
        and 328 MiB).
      - Not done: the recording as a tool (a run of the session under
        `--trace-compile`, and its statements sorted into the lists of the
        packages); here the generator writes the lists. The start part by
        part.

- [ ] **S9. Parallel agents and the single user.**
      - `bounded-run` gets a CPU weight for the jobs of agents and a reserve for
        a build of the user.
      - The scenarios of N worktrees measure the throughput, the CPU use, the
        peak memory, and the build time of the user while agents run.
      - Decision point: the reuse of whole package files in a new worktree
        needs package files that do not depend on the path of the worktree.
        Julia rejects them now. I measure what that costs and report it before
        any Julia change.
      - Gate: the throughput is above stock for each N, and the build of the
        user is below stock while agents run.

- [ ] **S10. Few and small Julia changes.**
      - List each change of the Julia branch with its theme (A to D), its lines
        and its test; remove each change that the final design does not need.
      - Gate: a table of the four themes, each with its lines and its test, and
        no change outside them.
      - The list lives in `docs/julia-changes.md` of CompilerServer.jl (the
        owner asked for one place, 2026-11-22; commit `8f4d452`). It splits the
        changes into the minimum (11 changes, 1,101 lines), equal bytes (9
        changes, 454 lines), not needed now (1 change, 32 lines) and not
        written yet. Each commit of the Julia branch updates it.
      A review before the end (2026-11-22; the owner asked for it): the branch
      `pr-linked-products` at `67820a0472` against the upstream master
      `2aa7c9fd5b`, which did not move: 25 commits, 22 files, 1,435 lines added
      and 46 removed. The whole diff was read. The lines of a group are the sum
      of the added lines of its commits (later commits replace some).

      | group (theme) | lines | CompilerServer needs it | a test in the Julia tree | the case for upstream |
      |---|---|---|---|---|
      | A1. the order of the work list, of the GC frame slots, of the global slots (pull request #63150, open), of the tables and of the list of the emitted code | 127 | yes, for equal bytes | none | strong: each one removes an order that follows addresses; no option |
      | A2. fixed object ids, and no byte that the process did not set (`--deterministic-object-ids`) | 293 | yes, for equal bytes | none | the hardest: an option that reaches `builtins.c`, `toplevel.c` and the GC |
      | A3. the writer computes each memoized fact of a `UnionAll` | 17 | yes, for equal bytes | none | good: small, and the image gets the full memo |
      | B. compile apart: `jl_emit_object`, `jl_emit_objects`, `jl_install_objects`, hidden symbols | 550, 108 of them tests | yes: the core | 2 test sets (`compile_apart`) | good: an entry point beside `jl_emit_native`, which other compilers use already |
      | B. the source names of an image, and the map back in a stack trace | 62 | yes: a part fits each worktree | none | good in principle (no absolute path in an image); the form of the name needs their word |
      | C. the writer takes code from parts: `jl_set_code_parts`, the call of the provider, the shard of the parts, the root of the table | 506 | yes: the core | none | the weakest form now (below) |
      | D. a reader of images by object: `jl_object_image_offset`, `jl_image_object_at` | 32 | no: only the link cascade of `link.jl` calls them, and only a gate test runs it | none | none without the link |

      What the review found:
      - Each group but D is needed. Nothing is missing for the package files, and
        nothing for an equal executable: S3 reached it with no change of Julia
        (the image is written by a process that only takes parts). Two small
        changes can make the image smaller (weak specializations, and no method
        that is newer than the selection).
      - C has the weakest form for upstream. `jl_set_code_parts` keeps the
        provider in a static pointer that the GC does not see, and its comment
        asks the caller to keep "that very object" alive in a box. It takes three
        forms (a table, a function, a package by name). The code generator calls
        `Base.require`. The C++ code matches the table against the list (about 75
        lines), also by method instance, a path that CompilerServer no longer
        uses. Upstream moved the driver of an image build into Julia
        (`compile_and_emit_native` in `Compiler/src/precompile.jl`), which makes
        the list and the order of the code: a hook there is Julia code, with no
        static pointer and no `require` from C++, and the provider can answer the
        list to compile with the table. After the experiment, one form is enough.
      - A2: the zero bytes of a new object are set on the path of each allocation
        (one test of the option for each process), only in the stock GC and not
        in the MMTk GC. One option does two things (ids and zero bytes).
      - A1: the sort key of the work list (file, line, name) is the same for two
        method instances of one method; their order then follows the input.
      - B: CompilerServer calls only `jl_emit_objects`; the single
        `jl_emit_object` serves two tests.
      - The change of the helpers of 16-bit floats (one copy for each image)
        also changes stock images on each platform; only Linux x86-64 was built
        and run. The same holds for each other change.
      - `Base.fixup_package_path` makes a string for each frame that a stack
        trace takes from a line table, in each process; a first test of the
        first byte removes that.
      - Tests in the Julia tree exist only for B. A pull request for A needs a
        test that builds a small package twice and compares the bytes; C a
        package file with its code from parts; the names a frame that maps back.
      - No change adds a line to the documentation or to NEWS yet.
      - The suites of Julia that the changes can reach, run for the first time
        on this branch (`compile_apart`, `stacktraces`, `cmdlineargs`,
        `precompile`, `gc`, `subtype`, `loading`, `errorshow`; 8 cores): 489,206
        checks pass, 49 are marked broken upstream, and 1 fails. The failure is
        the test of `--bug-report=rr-local` in `cmdlineargs`: the `rr` recorder
        does not know the CPU of this machine ("AMD CPU type 0x70f00 unknown"),
        so it is no fault of the branch.

- [ ] **S11. The end.**
      - One run of the harness with all measures, the guards, and the named
        gaps; the numbers go into this plan.
      - The plan `compiler-server-on-julia-master.md` and this plan move to
        `plan/done/`.

## Notes for the work

- Each run goes through `bounded-run`, inside the total of 48 GiB.
- Each number in a report says what it measures (`bench/measures.jl`).
- Each step is committed on its own, with its gate result in this plan.
- Nothing is pushed without the word of the owner.
