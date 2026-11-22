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

- [ ] **S2. An incremental product equals the whole build in every byte.**
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
      Facts found in the work (CompilerServer.jl `5dbe593`):
      - All writers run with `--deterministic-object-ids=yes`; with no fixed
        ids, no two builds can be equal. A file names the path of its depot,
        so the builds that are compared write into one depot.
      - Two whole builds with parts are now equal in every byte (all six files
        of the test project): the parts are in the order of the list of the
        writer, and the build id of each file comes from its content. Two
        stock builds differ in 39 kB to 46 kB of each `.ji`, from their random
        build ids.
      - A rebuild (each part held) differs from a whole build only in its `.ji`
        files (GenLow 830 kB of 2.3 MB, GenMid 97 kB, GenApp 534 kB); the
        `.so` files differ only in the checksum of the heap. Three causes:
        1. The provider runs in the scope of the write, so each id that it
           gives to an object with no natural key (its tables, Serialization,
           the walk over the globals) moves the counter of that scope, and the
           writer gives other ids to the objects of the image. A fix needs a
           small Julia change (F2): while the provider runs, an object with no
           id gets a provisional one that the table does not record.
        2. The emission of new parts makes types that go into the image: the
           whole build of GenLow has 3 `DataType`s, 3 `SimpleVector`s and 9
           `Union`s more (unions of the types of `report1` to `report8`, and
           tuple types over them, from the loop of `report()`). Not from the
           inference of the provider: an inference of all functions in the
           rebuild did not change it. Where the image takes them from is not
           found yet (F6).
        3. Not a difference between the two, but a defect of each package file
           with parts since Step 10: the writer records each loaded module of
           an image as a requirement (`write_mod_list`), and the prelude loads
           CompilerServer, Serialization, TOML, Dates and Printf. So each
           process that loads such a file loads CompilerServer, and another
           file of Serialization makes the loader reject it (the test steps of
           the harness then wrote stock files). A fix needs a small Julia
           change (F5): the writer leaves out the modules that the prelude
           loaded.
      - The names of the callees from the edges of the code instances, in place
        of the inference of the provider, left 91 functions without their
        parts and made a whole build non-deterministic: the inference stays.
      - Decision point: F2 and F5 are new hooks of the Julia branch (themes A
        and C), so the owner decides. The other way of this step is the link
        of Step 11 for the package files.

- [ ] **S3. Small products.**
      - The image does not hold the provider or its tables.
      - The part symbols are hidden (the emission in the Julia branch, and a
        lookup of the install that finds hidden symbols); the unwind tables and
        the symbol table get as small as those of stock.
      - Measure the choices for the executable: the level of debug
        information, and `--trim` where it keeps the session of use correct.
      - Gate: the package files and the executable are within the bounds of the
        size of stock that S1 sets.

- [ ] **S4. A first build that is not slower than stock.**
      - Measure where the time of the emission of all parts goes (the LLVM work
        of each object, the keys, the records, the round trips, the files).
      - Either make the emission as cheap as stock, or make the first build a
        stock build and the parts after it, on the free cores.
      - Decision point: I report both ways with their numbers, and the owner
        decides.
      - Gate: the first build with an empty store is not slower than stock.

- [ ] **S5. Inference results from records.**
      - A writer takes the inference results of each function whose record
        holds, and infers only the others; the records check the identity of
        the code in depth, as the check of the parts does now. This also gives
        `install_apart` the check of the identity.
      - Decision point: the hook in Julia must be small and simple; if it is
        not, I stop and report.
      - Gate: the writers of an edit infer only the new parts; each output
        equals stock; the time of item 5 drops as S1 measures it.

- [ ] **S6. The reactive cycle.**
      - The compiler server of CompilerServer.jl keeps the worktree loaded,
        applies each edit, compiles only what the edit makes invalid, writes
        the new parts into the store, and runs the selected tests in the
        process that is already loaded.
      - The package files and the executable are made from the store after
        that, on the free cores, and S2 checks their bytes.
      - Gate: the cycle time of each edit is below stock; the products equal a
        whole build in every byte.

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
