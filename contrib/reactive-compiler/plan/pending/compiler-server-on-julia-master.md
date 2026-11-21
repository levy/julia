# CompilerServer.jl on Julia master, and the upstream issues and pull requests

Status: proposed on 2026-11-20, not started. The design is in
[compiler-server-outside-julia.md](compiler-server-outside-julia.md); this plan
executes it. Each decision below is proposed and is approved with the plan.

## The goal

1. CompilerServer.jl, a new repository, gives reactive and incremental
   compilation of Julia packages and binaries. It reuses the Julia code of the
   reactive compiler: the rebuild logic, the driver, and the checks.
2. It runs on Julia master. On stock master it applies edits and checks them,
   and its products come from whole builds. On our branches of master with the
   pull requests B and C, it takes compiled code from its store.
3. The texts of the issues and the branches of the pull requests A to C are
   ready. D has its design and its first part.

## What this plan does not do

- It takes nothing from the region GC work or from the pre-relocation work. No
  branch of this plan merges `merged-next`, `gc-regions-*` or
  `sysimage-prelink*`.
- It does not port the runtime patch of the fork (image format version 3,
  overlays, writes by pages, package patches). Steps C and D replace it with
  new interfaces.
- It sends nothing upstream and pushes nothing. Each send is a separate word of
  the owner.
- It does not change the builds that the owner makes with `merged-next` today.
- It does not build parts 2 and 3 of D. They need the answer to issue 0, and
  they get their own plan.

## Facts at the start

- Julia master is `d5db139799`, version 1.15.0-DEV, on 2026-11-20.
- #63150 (the three sort fixes) merges into that master with no conflict.
  #63151 is merged. #63149 is open.
- Master has `jl_emit_native` (`src/aotcompile.cpp`), `jl_set_typeinf_func`
  and `Base.delete_binding`. It has no function sections in its code output.
- The rebuild logic is the stdlib `ReactiveCompiler` of `merged-next`, about
  5,300 lines: `SourceDiff.jl` 533, `child.jl` 2,799, `replay.jl` 1,160,
  `server.jl` 314, `patch.jl` 384, `entrypoints.jl` 16, `ReactiveCompiler.jl`
  83.
- The driver is `src/reactive.jl` (1,367 lines) and `src/reactive_cli.jl` (180
  lines) of the PackageCompiler fork, branch `reactive`.
- The checks that need no runtime patch are `tool/oracle.jl` (300 lines),
  `tool/gate_cases.sh`, `tool/gate_replay.sh`, `tool/gate_runs.sh`, and the test
  packages `tool/m6_hazard/HazardApp` and `tool/r1_cases`.
- The rebuild logic calls these runtime functions that only the fork has:
  the fields `toplevel_file` and `toplevel_line` of `Method`;
  `jl_reactive_set_read_record`; `jl_reactive_set_method_filter`;
  `jl_reactive_module_unexport`, `_unuse` and `jl_reactive_binding_leave`;
  `jl_reactive_methods_disable` and `jl_reactive_bindings_hide`;
  `jl_reactive_fork`; `jl_reactive_set_output`, `_set_trim` and the trim memo;
  the package patch functions and `Base.package_*`.

## Decisions (proposed, approved with the plan)

- D1. The base is upstream master at the start of Step 1. Code from the fork
  comes in as a copy of Julia files, never as a git merge.
- D2. One worktree of the fork, `workspace/julia-compiler-server`, with these
  branches:
  - `compiler-server-master`: the integration branch, which merges the
    branches below so that CompilerServer.jl can test with them;
  - `pr-reproducible-names` (A), `pr-compile-apart` (B), `pr-code-from-parts`
    (C), `pr-linked-products` (D): each one starts from master.

  A branch that needs another branch is built on it here, and it moves to master
  after the other one is merged. No open pull request depends on another open
  pull request.
- D3. The repository is `workspace/CompilerServer.jl`, with the package
  `CompilerServer` under the MIT license. Its Julia compatibility is the master
  of Step 1. The repository `levy/CompilerServer.jl` on GitHub is made only on
  the owner's word.
- D4. On stock Julia, the methods of a top-level expression are the methods
  whose world of definition falls inside the evaluation of that expression. The
  server evaluates the tracked sources itself when it starts. The fields of
  `Method` that the fork added become an upstream request only if this way is
  too slow.
- D5. On stock Julia, the files that a package reads are only those that it
  names with `include_dependency`, as for stock Julia itself.
- D6. On stock Julia, an edit that needs a runtime function that stock does not
  have is refused, with a whole build as the advice. Examples are a removed
  export, a removed `using`, and a name that leaves a module and comes back
  through a `using`. `Base.delete_binding` and `Base.delete_method` serve where
  they are enough.
- D7. On stock Julia, the trial of an edit runs in a separate process. The fork
  of the process stays in `merged-next` only. After Step 9, a measurement
  decides whether CompilerServer.jl needs a fork (open question 5 of the note).
- D8. The interface of B lives in `Compiler` until issue 0 answers, because
  GPUCompiler.jl and other packages already use the entry points of
  `Compiler`.
- D9. A commit subject is `<area>: <feature> <part> hook: <what>` for a change
  to an existing file, and `<area>: <feature> <part>: <what>` for new code. The
  feature words are `reproducible`, `compile apart`, `code from parts` and
  `linked products`. A disclosure line that names Claude Code and the model ends
  each commit message and each pull request text, as in the region GC work.
  There is no `Co-Authored-By` trailer.
- D10. An issue is one screen: problem, measurement, proposal, questions. A
  pull request body has 10 to 30 lines, with no bold and no table of costs.
  Measurements go on the branch `compiler-server-evidence` of `levy/julia`, and
  the texts link to them. On GitHub, each paragraph is one line.
- D11. Nothing goes out without the owner's word: no push, no issue, no pull
  request, no repository on GitHub. Each send needs its own approval.
- D12 (the owner, 2026-11-21). No issue and no pull request is created in this
  plan: "let's work through this so we see what it costs and what it gives".
  The texts and the branches are made and measured, and nothing is sent.

## Practices

- Run Julia and each long run with `workspace/bin/bounded-run`.
- A build of Julia takes about one hour. After a change of the layout of a
  runtime type, remove the image files before the build.
- Julia's CI builds `src/` with warnings as errors, so read the warnings of each
  build.
- A test failure counts only against the baseline of Step 1.
- After each step: mark it done here, write down the facts found, and commit.

## Part 1: setup

### Step 1: the worktree of master, and its baseline  — done

- [x] Make the worktree `workspace/julia-compiler-server` with the branch
      `compiler-server-master` at the current upstream master.
- [x] Build it, and keep a private depot in
      `/var/tmp/julia-compiler-server-depot`.
- [x] Run `test/precompile.jl`, `test/cmdlineargs.jl`, `test/compiler/` and
      `test/loading.jl`. Write down here each failure of clean master.

Gate: the build has no warning in `src/`, and the baseline is in this plan.
Done, with the limit on the warnings that the facts below give.

The baseline of clean master `2aa7c9fd5b`, run on 2026-11-21 with
`test/runtests.jl precompile cmdlineargs loading compiler`, two workers
(`JULIA_CPU_THREADS=2`), a restart of a worker above 3.5 GB
(`JULIA_TEST_MAXRSS_MB=3500`), and a cap of 8 GB. All 24 test files ran to
their end in 7 min 44 s: 706,215 passes, 57 broken, and one failure.

- The one failure: `test/cmdlineargs.jl:2014`, the test of
  `--bug-report=rr-local`. The tool `rr` stops with "AMD CPU type 0x70f00 (ext
  family 0xb) unknown", because it does not know the processor of this
  machine, and the test accepts only two other causes. It is a fault of the
  machine, not of master, and a branch of this plan has it too.
- The test downloads the package `BugReporting` and its dependencies from the
  network into the depot.
- The peak was 8.0 GB, at the cap. A run with more workers needs a larger cap.

Facts found:

- Master moved after the plan was written. The worktree is at `2aa7c9fd5b`
  (2026-11-20), and the built Julia is `1.15.0-DEV.881`.
- The build runs with a cap of 8 GB and `make -j4`. Its peak was 7.9 GB, so 8 GB
  is the smallest cap for a build. A first try with 16 GB found no room,
  because another session held a cap of 20 GB.
- The build ran in two parts, because the owner stopped the first one. The log
  of the first part is lost. The second part has no warning in `src/` or
  `cli/`. For clean master, its own CI is the reference; the branches of this
  plan get the check of warnings when they change `src/`.
- The depot of each run is `JULIA_DEPOT_PATH=/var/tmp/julia-compiler-server-depot:`.
  The trailing colon keeps the depots of the built Julia after it.

### Step 2: the repository CompilerServer.jl  — done

- [x] Check that the name `CompilerServer` is free in the General registry (a
      read only).
- [x] Make `workspace/CompilerServer.jl` with a git repository, `Project.toml`
      with a new UUID, `src/CompilerServer.jl`, `test/runtests.jl`, a short
      README, the MIT license, and `plan/pending/` with a link to this plan.

Gate: `Pkg.test()` of the empty package passes on the build of Step 1.

Facts found:

- The name is free in the General registry, and no repository on GitHub has the
  name `CompilerServer.jl` (2026-11-20).
- The UUID is `b9f42e07-4c72-477d-b783-e20d04cdfd76`. The first commit is
  `1cfef11` on the branch `main`. Each commit message ends with the disclosure
  line of D9.
- `Pkg.test()` passes on `1.15.0-DEV.881`; the compatibility entry
  `julia = "1.15"` accepts that version.

## Part 2: CompilerServer.jl on stock master

### Step 3: the rebuild logic  — done

- [x] Copy `SourceDiff.jl`, `child.jl`, `replay.jl`, `server.jl` and
      `entrypoints.jl` from `stdlib/ReactiveCompiler` of `merged-next`. Do not
      copy `patch.jl`, because package patches are not in the new design.
- [x] Replace each runtime function that only the fork has:

  | the fork | stock master |
  | --- | --- |
  | `toplevel_file`, `toplevel_line` of `Method` | the world range of the evaluation (D4) |
  | `jl_reactive_set_read_record` | the files of `include_dependency` (D5) |
  | `jl_reactive_set_method_filter` | no evaluation when the lowered code equals the old one |
  | `jl_reactive_module_unexport`, `_unuse`, `jl_reactive_binding_leave` | a refusal (D6); `Base.delete_binding` where it is enough |
  | `jl_reactive_methods_disable`, `jl_reactive_bindings_hide` | `Base.delete_method` one by one; a refusal where stock has no way |
  | `jl_reactive_fork` in the trial | a separate process (D7) |
  | `jl_reactive_set_output`, `_set_trim`, the trim memo | removed: in this part, products come from whole builds |
  | the package patch functions, `Base.package_*` | removed |

- [x] Write down here each rule of the change catalog that stock master must
      refuse and the fork applies.

Gate: the unit tests of the rebuild logic pass on the build of Step 1. Done:
the 13 tests of CompilerServer.jl pass on `1.15.0-DEV.881` (commit `4844236`).

Facts found:

- The stock layer is `src/runtime.jl`. A marked evaluation (`rc_marked_eval`)
  puts a mark (a world and a place) before the evaluation, and before each
  form of the body of a module block. When the outermost marked evaluation
  ends, one walk of the method table gives each new method that is not in an
  image the place of the last mark before its world (`primary_world`), and
  then passes it to the filter. A nested evaluation, such as an `include` in a
  module body, only adds marks.
- The filter of identical redefinitions runs after the evaluation, with the
  world of before it. When it keeps the old method, it deletes the new one, so
  the old one is active again. So an identical redefinition moves the world
  three times where the fork moves it once, and it invalidates the callers;
  the program is the same.
- The loader is `src/loader.jl`: `Base.__toplevel__` takes the UUID and the
  edition of the package (`Base.locate_package_load_spec`), and each file is
  evaluated from its stored copy under its real path. An `include(path)` of a
  module body or of a file becomes a marked include. An `include` with two
  arguments (a `mapexpr`) is not marked and reads the disk. After the load, the
  triggers of the extensions and the callbacks of the package run under
  `Base.require_lock`, as Base does.
- Master changed the layout of the tables of a level of the method table: slot
  1 holds the index of the hash, and the values are on the odd slots from 3 on.
- Master has `Base.set_binding_visibility!(mod, name, :none)`, which takes an
  export back in a new world. So a removed export applies on master, and D6
  refuses less than the plan said.
- The docstring of `Base.delete_binding` on master says that its
  implementation is not complete. The removal of a name uses it.
- A check of the replay runs in a new process (`rc_in_process`). It loads the
  program from the copies of the request, runs the same apply, takes the
  answers of the server for the checks before it, writes its answer and exits.
  The trial and the check of the expressions of before the edit of a small
  package cost about 2 s together, nearly all of it the start of the two
  processes.
- The warm-up of the fork is also a self-test of the ledger, the trace and the
  filter. It runs once in each process, through the marks.
- No read of a file is recorded (D5). A file of `include_dependency` becomes
  an input of the store in Step 4.
- `patch.jl` and `entrypoints.jl` are not copied: the package patches are not
  in the new design, and the entry points serve only the write of a trimmed
  image, which comes with step C.
- The roots of dead code stay (`rc_drop_dead_roots!` is not called), because
  no image follows an apply.

The rules of the change catalog that stock master refuses and the fork
applies:

- C3, a removed `using`: stock Julia takes no `using` back.
- A removed name (a type, a constant, a global, an imported name) that a module
  used by its module exports: the guard that `Base.delete_binding` leaves hides
  that export.

The rules that stock master does not see, where the fork does:

- E1, a changed file that a top-level expression reads: no read is recorded.
  A file of `include_dependency` stops the rebuild (Step 4); another file is
  not seen, as for stock Julia itself.

### Step 4: the driver  — done

- [x] Move the store, the inputs, the record of the builds, the status, the
      early end when nothing changed, the watch and the command line from the
      PackageCompiler fork into `CompilerServer.build`, `CompilerServer.watch`
      and `julia -m CompilerServer`.
- [x] Make the products with stock PackageCompiler (`create_sysimage`,
      `create_app`) and with the stock precompile. CompilerServer.jl needs no
      fork of PackageCompiler.

Gate: `build`, `status` and `watch` work on `HazardApp`. Done: the gate
`test/gates/build_status_watch.jl` passes on 2026-11-21 (commit `3a97ffb`).
The whole build takes 163 s, a rebuild through the server 132 s, a build with
no change ends at once, the status prints the store, and the watch rebuilds
an edit in 120 s and stops the server at its end. The built application prints
the edited output after each rebuild. The peak is 6.5 GB.

Facts found:

- The newest driver is at `d34f59a8` of the branch `reactive` of the remote
  `projectured` (the worktree `package-compiler-live-harness`). The checkout
  `PackageCompiler.jl` is behind it, at `dd96ca2f`. The driver came from
  `d34f59a8` by a copy of its parts that serve no image: the store, the
  inputs, the record of the builds, the early end, the requests to the server,
  the snapshots, the walk of the tracked sources, the status, the watch and the
  command line.
- On stock Julia a rebuild still builds the application whole: the server
  applies and checks the edit, then stock `create_app` builds the application
  from its sources and the trace of the store. Steps B and C replace that whole
  build.
- The trace process of a whole build also lists the files of the cache files
  of the loaded packages (`Base.parse_cache_header(cache)[2][1]`). A file of a
  path package there that the build does not track, a file of
  `include_dependency` among them, is an input of the store (D5).
- Stock PackageCompiler 2.4.5 installs and loads on master. Its default
  processor target for an application starts with `generic`, which lacks the
  CX16 instruction that Julia master needs, and the build of the image stops
  at its start. The whole build of CompilerServer.jl takes `native` when the
  caller gives no target, as the command line of the fork did.
- The store records the keywords of `create_app` (`create_app` in the
  config), and a rebuild passes them again.
- The server runs in the environment of the package, with the environment of
  the build behind it in `JULIA_LOAD_PATH`, so it loads CompilerServer.jl too.
- CompilerServer.jl now depends on PackageCompiler, TOML, Libdl and SHA.

### Step 5: the checks  — done

- [x] Move `tool/oracle.jl`, the cases of `gate_cases.sh` and of
      `gate_replay.sh`, `HazardApp`, `CaseApp` and `CaseLib` into the tests of
      CompilerServer.jl.
- [x] Compare the state of the server after each edit with a fresh process that
      loads the final sources: the same method tables, roots, output and
      globals.

Gate: each case gives the digest of the fresh process, or it is a refusal that
`must-refuse.txt` or Step 3 lists. Done on 2026-11-21 (commit `cffe664`):

| gate | steps | result |
| --- | --- | --- |
| `test/gates/cases.jl`, the edit cases | 55 | 43 applied, 12 refused (the 10 of `must-refuse.txt` and 2 of stock master); the digest of 274 lines equals the fresh load, with no noise; 3 min 21 s, 1.2 GB |
| `test/gates/hazard.jl`, HazardApp | 7 | 4 applied, 3 refused (F1, B2, and the removed `using` of stock master); the digest of 123 lines equals the fresh load |
| `test/gates/hazard.jl ... data`, `data.txt` | 1 | the digest differs, as decision D5 says it must |
| `test/gates/replay.jl`, ProjecturedKernel | 20 commits | each applied; the digest of 3,531 lines equals the fresh load; about 3 min |

Facts found:

- The check is `CompilerServer.check_chain` (`src/check.jl`). It applies each
  edit in one process, as a server does, and compares the program with two
  fresh loads of the final sources through the loader of Step 3. The lines that
  differ between the two fresh loads are noise. The oracle is
  `CompilerServer.oracle_lines` (`src/oracle.jl`). An input that changed stops a
  step, as the driver stops a rebuild: a project file, a file that the load
  included and that is no tracked source, or tracked files that the walk can
  not find.
- No product is built: on stock master a product of each step would be a whole
  build of about two minutes. The checks of `gate_replay.sh` about overlays and
  pre-relocated programs are not ported, because stock master writes neither.
- The gates found five faults of the stock layer of Step 3, now fixed:
  1. The loader loaded `CaseApp` before `CaseLib`, so the `using` loaded
     `CaseLib` from its cache file, whose methods have no place; then a removal
     can not find its methods. The loader now loads each tracked package after
     the tracked packages that it depends on.
  2. An `include` with a `mapexpr` function, and an `include` inside a
     top-level loop or condition, read the disk without marks. They now load
     with marks, and a file that has no stored copy is recorded as an input.
  3. A module under a docstring is an argument of `@doc`, and its body got no
     marks. `ProjecturedKernel` is such a module.
  4. The refusal of D6 for a name that a used module exports ran in the world
     of the loop of the chain, which does not see the bindings of the earlier
     steps. It now runs in the newest world, and only for a name that the module
     holds as its own.
  5. The oracle ran in an old world and could not show the values of new types.
- The cases that stock master refuses and the fork applies:
  `orphaned_binding_realias` and `retract_removed_bindings` (an own binding
  leaves, and `Base` exports the same name), and the reverse edit of
  HazardApp (a removed `using`).
- The replay takes the commits of the main line (`git log --first-parent`).
  Without it, the list held commits of a side branch whose tree lacks
  `package/ProjecturedPrecompile`, and their environments did not load.
- The output of HazardApp has `bench:` lines that measure times; the gate
  leaves them out.
- The fixtures are in the package: `test/fixtures/r1_cases` and
  `test/fixtures/m6_hazard`, copied from the fork.

## Part 3: the texts of the issues

### Step 6: the evidence branch and issue 0  — done

- [x] Make the branch `compiler-server-evidence` at master. Put on it the
      measurements that the texts quote: the cascade on 1.13 (99 cache files,
      about 280 s), the rebuild of the fork (21 s against 117 s), and the cases
      of Step 5.
- [x] Write issue 0 from the draft in the note, in one screen.

Gate: the owner approves the text. A send is a separate word of the owner.
The owner approved the text on 2026-11-21. Nothing is sent.

Facts found:

- The branch `compiler-server-evidence` is at master `2aa7c9fd5b`, in the
  worktree `workspace/julia-compiler-server-evidence`, with
  `contrib/compiler-server/README.md` and `measurements.md` (commit
  `007cef27ca`). It is not pushed.
- The texts of all the issues are in `doc/compiler-server-issues.md` of this
  folder (commit `0304f23268`).

### Step 7: the issues about the module identity, B, C and D  — done

- [x] Module identity: start from the text of step S5 in
      `maturity-and-determinism.md` of the branch `determinism-experiment`, and
      measure again on master. It is a second issue of A, beside #63149.
- [x] B, C and D: one screen each.

Gate: the owner approves the four texts. The owner approved the texts of B, C
and D on 2026-11-21. Nothing is sent.

Facts found:

- The issue about the module identity is not needed. #65077 (maleadt, merged
  2026-11-20) seeds the hash of a type name from `module->hash`, which master
  derives from the name and the parent of the module, and no longer from the
  random `build_id.lo`. Its text says that four builds of the system image give
  identical hashes for 76,159 types. The `build_id.lo` of a module still comes
  from the clock (`src/module.c`), but no type hash reads it now.
- So three texts wait: B, C and D, beside issue 0.

## Part 4: the pull requests

### Step 8: A, the names from content

- [x] Check #63150 against the master of Step 1 again, and answer its review.
- [ ] On `pr-reproducible-names`: give constants (`_j_const`) and strings
      (`_j_str`) names from their content in place of a counter. Add a test that
      builds one image twice and compares the object files. Proposed: this part
      moves into Step 10 (see the facts).
- [ ] Write the text of the pull request.

Gate: the test passes; the suites of Step 1 show no new failure; the owner
approves the text.

Facts found:

- #63150 still merges with no conflict into master `2aa7c9fd5b`. It has no new
  comment since 2026-09-15, so nothing waits for an answer.
- The names of the constants and strings are private globals. In a stock
  package image built by this master, `_j_const` and `_j_str_` are in no
  string, no symbol and no section name, so the counter does not change the
  bytes of a stock image. The fork measured them in the LLVM module and with
  one section for each global. A pull request for the names alone would show
  no effect on stock Julia. Proposed: the names from content move into part 1
  of step C (Step 10), where each function and each global gets its own named
  section and the names become part of the bytes. Then step A has no pull
  request left in this plan, beyond #63150.

### Step 9: B, compile apart from load

- [ ] On `pr-compile-apart`, part 1: the interface (D8). It infers a list of
      method instances at a world and generates their code with
      `jl_emit_native`, with no install in the process.
- [ ] Part 2: generated code reports its slots (the Julia object of each slot)
      and what it read (each callee and its calling convention, the type
      layouts, the code generation parameters, the target).
- [ ] Part 3: an install of inferred code and machine code in a running process.
      The JIT links the object and binds its slots, with no LLVM.
- [ ] Tests in Julia's tree: compile a function apart, install it in a new
      process, call it, and check that no LLVM ran.
- [ ] CompilerServer.jl on `compiler-server-master`: after an edit, a session
      takes the compiled code of the edit from the store and compiles nothing.
- [ ] Measure a trial and a write in separate processes (D7).

Gate: the tests pass, the CompilerServer.jl check passes, and the owner approves
the text. The pull request opens only after issue 0 has a yes, or on the owner's
word.

Facts found before the work (the design is `docs/compile-apart.md` of
CompilerServer.jl, commit `a5e7d3d`):

- Master has more than this step assumed: inference with a cache owner of its
  own (`typeinf_ext_toplevel`, as `--trim` uses it), `jl_emit_native` and the
  tables of its output (`jl_get_llvm_gvs`, `jl_get_llvm_external_fns`), and a C
  API of the JIT that adds an object file (`JLJITAddObjectFile` in
  `src/llvm_api.cpp`, `JuliaOJIT::addObjectFile`).
- The gaps are three: no entry point turns inferred code into an optimized
  relocatable object (only the image writer does, with the data of an image);
  nothing records what generated code read; nothing sets the `invoke` and
  `specptr` of a code instance to linked code.
- Master uses LLVM 23. LLVM.jl may not support it, so a prototype in the
  package uses `ccall` into the C APIs.

### Step 10: C, the writers take code from parts

- [ ] On `pr-code-from-parts`, built on B here, part 1: each function gets its
      own section and a name from its key. Take the ideas of the fork's image
      format version 3 (one function table with names, calls by name), with no
      overlay, no writes by pages and no pre-relocation.
- [ ] Part 2: the writers of package files and of system images take the code
      of a function from a part.
- [ ] CompilerServer.jl: a whole build of a package file and of a binary takes
      all unchanged code from the store.

Gate: a package file and a system image written with all their code from the
store load and pass the tests of `HazardApp`, and their write runs LLVM for no
unchanged function. The pull request opens only after B is merged.

### Step 11: D, the design and its first part

- [ ] Write the design of D as a document in CompilerServer.jl: the keys of
      definitions, the parts of a top-level expression, the effects on other
      modules, the names from content, the worlds of a link.
- [ ] On `pr-linked-products`, part 1: a reader and a writer of Julia's formats
      at the level of objects.
- [ ] A prototype of the link on two packages, A and B: edit A, link new files
      of A and B, and compare them byte for byte with our own whole build of the
      same sources.

Gate: the prototype gives the same bytes, and the design document exists. Parts
2 and 3 of D get their own plan.

## Part 5: the end

### Step 12: the measurement and the end of the plan

- [ ] On `compiler-server-master`, measure CompilerServer.jl with B and C: an
      edit in the package that `gate_replay.sh` replays, a package above it,
      and a binary. Count how much compiled code of the package above stays
      valid (open question 3 of the note).
- [ ] Put the numbers on the evidence branch.
- [ ] Move this plan to `plan/done/`.

Gate: the numbers are on the evidence branch, and each step above is marked
done or has its reason.
