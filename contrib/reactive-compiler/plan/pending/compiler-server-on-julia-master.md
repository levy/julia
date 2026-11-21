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

- [x] On `pr-compile-apart`, part 1: the interface (D8). It infers a list of
      method instances at a world and generates their code with
      `jl_emit_native`, with no install in the process. (`jl_emit_object`,
      commit `e77ae1533c`.)
- [x] Part 2 (first of the three items in the order of the owner, 2026-11-21:
      the record, the objects for each part, then Step 10): generated code reports its slots (the Julia object of each slot)
      and what it read (each callee and its calling convention, the type
      layouts, the code generation parameters, the target). Done in
      CompilerServer.jl `92251f7`: the slots, each function with its calling
      convention, the edges of inference, the globals that the sources read,
      the definitions of the types, and the settings of the build.
- [x] Part 3: an install of inferred code and machine code in a running process.
      The JIT links the object and binds its slots, with no LLVM.
      (`jl_install_object`, commit `eeb2968d30`; the records of inference in
      CompilerServer.jl `1984d6c`.)
- [x] Tests in Julia's tree: compile a function apart, install it in a new
      process, call it, and check that no LLVM ran. (`test/compile_apart.jl`,
      commit `14687ab4f5`; the run of test/runtests.jl passes.)
- [ ] ~~CompilerServer.jl on `compiler-server-master`: after an edit, a session
      takes the compiled code of the edit from the store and compiles nothing.~~
      Dropped by the owner (2026-11-21): a faster running session is another
      product, and it does not bring the writing of binaries and package files
      closer. The install in a new process stays as the proof that the keys
      and the records give correct code in another process.
- [x] One stored object for each part, not one object for all: the parts call
      each other by symbols that a link resolves, as the parts of a stock image
      do, so that an edit compiles again only the parts that it changed. One
      object for each root repeats the shared code and takes 4 times the
      emission (30.8 s against 7.2 s on the kernel list). The owner decided
      (2026-11-21): a part is one function, one code instance. Done: Julia
      `ca20d6a9c0`, `5e30f7d3ea`, `7b54c22304`, `a6a7b7737e` on
      `pr-compile-apart`; CompilerServer.jl `80d8735`.
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

Facts found in the work (CompilerServer.jl `src/apart.jl`, commit `1984d6c`;
the gate `test/gates/apart_kernel.jl` on the 296 signatures of the kernel list,
in processes with `--pkgimages=no`, so the cache files hold inferred code and
no machine code):

- One object for all 290 method instances holds 1,233 functions in 2.5 MB. The
  compile takes 1.7 s of inference and 7.2 s of emission. 744 of the functions
  already have code in the process of the install (the system image), so about
  60 % of the emission is not needed. An object that calls such code by external
  links needs more work in `jl_install_object`.
- The JIT cost of the list is mostly inference: the baseline `precompile` loop
  takes 1.22 s. An install that infers again in its own process takes 1.1 s, so
  it gains only the LLVM part. The record of the inference results of each
  function removes the inference too.
- The install makes 334 code instances from the records with no inference, and
  the check of the loader (`scan_new_code!`) finds 333 valid. The install takes
  0.19 s: read 0.05 s, make 0.14 s, check 0.002 s, slots 0.013 s, link 0.009 s.
  The `precompile` loop after it takes 0.19 s, against 1.22 s, so the total is
  about 0.4 s, which is 67 % less.
- The keys of the slots: all 1,414 slots get a key. Three of them are roots of
  a method definition (the variables of a `let` block around
  `Base.CoreLogging.env_override_minlevel`). `Base.quoted_syms` is a `Set`, an
  immutable struct, so the walk of the constants takes every constant that is
  not plain bits.
- A key of one tuple type for each kind of key made the JIT compile
  `getindex`, `hash` and `isequal` for each key, and a dictionary keyed by
  types compiled `setindex!` 318 times (967 ms). One concrete key type and
  method instances as dictionary keys remove that.
- `Base.method_instance` on the abstract signature of an edge corrupts the
  method cache, and a later lookup crashes in `jl_lookup_cache_type_`. The
  install takes the specialization of the method for exactly the types
  (`Base.specialize_method`), with no dispatch.
- On master, `Serialization` breaks a type that holds the type variable of a
  struct, as the signature of an inner constructor `S{T}(x) where T` does: it
  reads back with a free `T`. Julia 1.13.1 reads it back right. The key of a
  method has its place, and the compile reads its store back and takes out
  what does not read back the same. Two constructor records still go (about
  0.12 s of JIT compile).
- A method key with only the signature finds a method defined again with
  another body, and the check of the edges then passes with old code. The key
  holds the hash of the compressed source of the definition, which is the
  same in two processes. The test package ApartApp checks this case.
- A return type with a free type variable never reads back equal. The record
  widens such a type to `Any` when the code returns a box; that is sound.
- A struct defined again with the same name gives another type under the
  same key, because a type key resolves by name. The record of the type
  definitions (part 2) closes this.

Facts of part 2 (CompilerServer.jl `92251f7`):

- The check of the loader assumes that a cache file and the package that loads
  come from the same sources (the cache file holds the checksums of its source
  files). A store has no such tie. So the record holds the settings of the
  build (Julia version and commit, the build id of the system image, the CPU
  and its features, the cache flags), the globals that each function reads,
  and the definitions of the types that it names.
- Inference folds a constant without an edge: `g(x) = min(x, L)` has an edge
  to the binding `L`, but `h() = ORIGIN.x` has none. Julia handles such reads
  per method, by a scan of the source. So the record holds the globals of the
  source of the method of each function and of the methods of its edges.
- The compressed source of a method refers to its roots by the build id of
  its cache file (`TAG_RELOC_METHODROOT` in `src/ircode.c`), which has a random
  part, and holds a string literal only as the index of a root. Its hash is
  not an identity of the definition. The hash comes from the uncompressed
  source; a method of Core or Base in the system image has the hash 0, which
  the build id of the system image in the settings fixes.
- The place of a method key holds the path of the file, so a package at
  another path does not reuse the store.
- The test package installs into a process whose package has, at the same
  place, another value of a constant, another order of the fields of a
  struct, another body of a generated function, or another string literal.
  With the checks, each case gives the result of a fresh process. A probe with
  the checks off installs the old code and gives a wrong result in each case.
- Cost on the kernel list: 2,739 globals and 605 type definitions; 0.2 s more
  in the compile and about 0.05 s more in the install. The first install in a
  process also spends about 0.2 s in the JIT for the install code of
  CompilerServer.jl itself; a workload in the cache file of CompilerServer.jl
  would remove it.
- Not covered yet: overlay method tables and opaque closures.

Facts of the objects of each part (Julia `pr-compile-apart` to `a6a7b7737e`,
CompilerServer.jl `80d8735`):

- One object for each function of the kernel list, with all 1,493 functions:
  16.0 s of emission and 11.9 MB, against 7.2 s and 2.5 MB for one object. A
  call of `jl_emit_object` has a fixed cost of 2.6 ms and a smallest object of
  4.4 KB. The link of 1,493 objects takes 0.1 s.
- The list of inference can hold two code instances of one method instance;
  one part serves both.
- A function of the system image needs no part: 743 of the 1,234 functions of
  the kernel list. With them out, the compile emits 491 parts in 3.5 s, 3.0 MB,
  which is less than one object for all (7.2 s). The install links 486 parts
  in 0.37 s, 162 calls link to code of the system image, and the precompile
  loop after it takes 0.2 s, against 1.22 s.
- `jl_invoke_api` answers -1 for code with a specialized signature: it knows
  only the trampolines of the runtime. The flags of the code instance tell the
  specialized signature (0b01) and complete code (0b10).
- In one object for all, a caller could pass its checks and call the old code
  of a callee whose record failed, by a direct call inside the object (a
  constant that a callee two calls deep reads). In parts such a call is a
  symbol with no definition, and the install keeps the caller out. The test
  package has that case.
- The build of the system image needs more than 6 GB with the default count of
  image threads; with `JULIA_IMAGE_THREADS=4` it peaks at 5.2 GB.

Facts for the objects of each part, found before the work:

- On master, a call to a function outside the object is direct when the
  callee is in the same object, goes through a table that the loader fills
  (`emit_pkg_plt_thunk`) when the callee is in another cache file, and goes
  through `jl_invoke` otherwise. Stock splits one image into parts that call
  each other directly by symbols that the linker resolves. So the objects of
  parts need a fourth form in `jl_emit_native`: a call to a function of
  another part, by a symbol that our link resolves, which gives the direct
  call of stock.

### Step 10: C, the writers take code from parts

- [x] On `pr-code-from-parts`, built on B here, part 1: each function gets its
      own section and a name from its key. Take the ideas of the fork's image
      format version 3 (one function table with names, calls by name), with no
      overlay, no writes by pages and no pre-relocation. Done as one object
      for each function (a part, with a name from its key) in one more shard
      of the file; a whole build writes its parts into the store
      (CompilerServer.jl `05255dc`).
- [ ] Part 2: the writers of package files and of system images take the code
      of a function from a part. Done for package files: Julia `b786281c96`
      and `c092fb0570` on `pr-code-from-parts`, CompilerServer.jl `e8ca6d7`,
      `00cca6e`, `da451de`. Open: system images.
- [ ] CompilerServer.jl: a whole build of a package file and of a binary takes
      all unchanged code from the store. Done for package files
      (`compilecache_with_parts`); open for binaries.

Gate: a package file and a system image written with all their code from the
store load and pass the tests of `HazardApp`, and their write runs LLVM for no
unchanged function. The pull request opens only after B is merged.

The system images (after Step 11, the owner: "Continue"), on `pr-linked-products`
and CompilerServer.jl `main`:

- [ ] S1. Measure a stock system image of HazardApp (`create_sysimage`,
      incremental, `cpu_target = "native"`, its workload as the precompile
      file): the time and the peak memory of the build, the count of the
      functions that the writer compiles, and the output of the workload.
- [ ] S2. `create_sysimage_with_parts`: the build process sets the provider in
      the mode of a system image (`-L` of a prelude). In that mode the provider
      makes parts also for the code of other images, because a system image
      can not call the code of a package file. A whole build writes the store,
      and a rebuild takes the parts that hold.
- [ ] S3. Gate: the system image of a rebuild with all its code from the store
      loads and gives the output of the stock image, and its writer compiles no
      unchanged function with LLVM; the time and the memory against S1.

Facts so far (S1, S2):

- S1: the stock system image of HazardApp takes 87.6 to 142.1 s, peaks at
  5.1 to 5.2 GB (`JULIA_IMAGE_THREADS=4`), compiles 21,766 functions, and is
  180 MB. The workload with an image gives another `ccallable` line than with
  no image, and its `bench:` lines hold timings: the gate compares two images.
- PackageCompiler starts the build process with `--pkgimages=no`, and the
  image holds every module that the process loaded: with parts, CompilerServer
  and PackageCompiler too.
- In the mode of a system image, the provider met values that a store can not
  hold: an implicit import that more than one module offers (`binding_module`
  throws), a constant `Cstring` (no `write`), and a type of an anonymous module
  (no read back). A value that holds an address now has no key, and the round
  trip check drops what a stream can not hold or read back.
- The whole build with parts made 38,734 parts in 782 s of emission, one at a
  time, and a store of 245 MB; it went past 7 GB 10 s after the store was
  written. With 8 GB, the provider alone is at 6.0 GB during the emission: it
  keeps each part, each record and the whole store in memory.

The owner, 2026-11-22: "We should try to avoid keeping everything in memory if
that's possible with using the file system or some other mechanism better.
Smaller peak allows more parallelization in the real system", and "Yes" to these
steps:

- [ ] M1. A store on the file system: a folder with one file for the object of
      each part and one for its record, named by the part, and an index with
      the settings, the tables of the globals and the types, the records of
      other images, and the list of the parts. The provider writes the files of
      a part as soon as it emits the part, and keeps only its name, its path,
      its calls and the objects of its slots. The compile apart of Step 9 takes
      the same store.
- [ ] M2. The table of the writer names the path of the object of a part, and
      the C side reads the object only when it writes the archive (a change of
      C, which belongs to `pr-code-from-parts`; here on `pr-linked-products`).
- [ ] M3. The round trip check of each part before its record is written: no
      buffer of all parts, and no copy of all of them.
- [ ] M4. In the mode of a system image, no second inference of the callees:
      each callee of a system image is in the list of the writer.
- [ ] M5. A rebuild reads the index and the records that it needs, and leaves
      the objects on disk.
- [ ] Gate: the whole build and the rebuild of S2 and S3, with the peak of the
      build process against S1 and against the build before M1.

For the future (written down by the owner's word, not a step of this plan):

- The bridge of the writer infers all code before it calls the provider, and
  that inferred code is most of the peak of a stock build. If the bridge called
  the provider before inference, with the list of the method instances, the
  provider could take a held part together with the record of its inference
  result (the records of Step 9, with which the install runs no inference), and
  the bridge would infer only the code with no held part. A rebuild after a
  small edit would then infer and compile only what the edit touches. It needs a
  change of the bridge (`compile_and_emit_native` in `Compiler/src/precompile.jl`
  and `jl_create_native`), and the check of a held part can then not compare
  with an inference of the writer: it must rest on the records alone, as the
  install of Step 9 does.

Facts of part 2 for package files (to Julia `c092fb0570`, CompilerServer.jl
`da451de`):

- The parts enter a package file as one more shard. A shard has a table of
  absolute function pointers and a table of slot offsets from the table
  itself, so a shard can name functions and slots of other objects of the same
  file, and the loader needs no change. The parts have one target, so the
  clone tables of their shard are empty; the writer must refuse parts for a
  cpu target with more than one target.
- `jl_set_code_parts` takes a function of this package, which
  `jl_create_native` calls after the bridge of the compiler, in the latest
  world, with the list of code that the file takes. A wrap of the bridge can
  not serve: the writer calls the bridge in the world of the compiler, where
  no method of this package exists. A hook at exit inferred the code itself
  and put more code into the file than the stock writer does.
- The function of the parts must have its code in the package file of
  CompilerServer: code that the writer infers before the function switches the
  tracking of new code off becomes code of the new file.
- The writer reads the objects of the slots after `jl_create_native`, so the
  table must live until the output is written.
- The indexes of the functions and the slots of the parts are fixed when
  `jl_create_native` runs; `jl_dump_native` appends more functions later. So
  the tables of the other shards have gaps, which `get_fvars_gvars` and
  `verify_partitioning` now accept.
- In the list of code, a C-callable alias is one item, not a pair.
- In code from a package file, a `ccall` of a `jl_` name with no library looks
  in `libjulia-internal`, which holds only the fallback of a function of the
  code generator. CompilerServer.jl calls these functions by their address in
  `libjulia`.
- The named symbols of a part are protected: the JIT still finds them, and the
  link of a file binds a call between parts directly, with no PLT.
- HazardApp with two precompile statements: the stock writer compiles 18
  functions in 0.35 s, the writer with parts compiles 1 in 1.44 s (the load of
  CompilerServer.jl in the writer is most of the time), and both files give
  the same output of the workload.
- ProjecturedKernel with its recorded list: the stock writer compiles 779
  functions in 5.0 s (1.19 MB); with the parts of a separate compile, the
  writer compiles 221 in 5.9 s (1.83 MB). 17 parts are refused because the
  inference of the writer gives other edges than the inference of the
  compile process (other callees), and the other functions have no part: the
  compile process does not choose the same set of functions as the writer.
  So the parts of a package file must come from a writer process: a whole
  build must write its parts (part 1 of this step).

Facts of a whole build that writes its parts (CompilerServer.jl `05255dc`):

- The provider of the writer takes the parts of the old store that hold,
  compiles each other function of the file as a new part from the code
  instance and the source of the writer, and writes the new store. Parts from
  a separate compile process do not fit: that process infers some functions
  otherwise, and chooses another set of functions.
- ProjecturedKernel (test/gates/parts_kernel.jl): the stock writer takes 6.0
  to 6.8 s and compiles 779 functions. The whole build with parts takes 16.2 s
  and writes 985 parts (7.9 s of emission, one function at a time). After an
  edit in a comment, in a string of code, or one that moves lines, a rebuild
  keeps 981 to 983 parts, compiles 2 to 4 new ones, and takes 7.5 to 9.1 s.
  The writer compiles 3 functions itself, which have no part. The precompile
  loop after the load spends the same 0.3 s of compile time with each file.
- Of a stock write of the kernel, the load of the source with its inference
  takes 3.4 s, and the rest, with the LLVM work, 2.5 s. Parts remove only the
  LLVM work. The provider adds about 2 s: the check of the held parts 0.6 s,
  the map of the constants 0.3 s, the inference of the closure 0.3 to 0.5 s,
  the round trip check 0.2 s, the read and the write of the store 0.3 s. So on
  the writer of stock Julia, parts give no faster write of one package file:
  the writer still runs the package and infers it. A write in seconds needs
  the inference results from the store too, and no run of the package: the
  link of step D.
- An edit that moves lines changes the place of each method below it, so
  their parts do not serve (2 in the case of the gate).
- The key of `Core.methodtable`, an edge of each dynamic call, must not need
  the map of the constants.

### Step 11: D, the design and its first part

- [x] Write the design of D as a document in CompilerServer.jl: the keys of
      definitions, the parts of a top-level expression, the effects on other
      modules, the names from content, the worlds of a link.
      (`docs/linked-products.md`, CompilerServer.jl `07f776f`; three open
      questions, with proposals.)
- [ ] On `pr-linked-products`, part 1: a reader and a writer of Julia's formats
      at the level of objects. (First, by the owner's choice of the prototype
      order: a reader of package files in Julia, `src/link.jl` of
      CompilerServer.jl `1f35304`, with two functions of `src/staticdata.c` that
      map an object of a loaded image to its offset and back, `b5ddc38ad0`.
      The C interface waits for what the prototype shows that it must give.)
- [x] A prototype of the link on two packages, A and B: edit A, link new files
      of A and B, and compare them byte for byte with our own whole build of the
      same sources. (Met with `--deterministic-object-ids=yes`, see the steps
      below: the linked LinkB is equal in each byte to the rebuild; our own whole
      build takes the build id from our writer, `link_build_id!`, as the design
      says.) (The cascade by a link of references is built: the gate
      `test/gates/link_cascade.jl`, CompilerServer.jl `1f35304`. The linked file
      loads and runs for each of three edits. It is equal in each byte to a
      stock write except in the object ids, which wait for a decision of the
      owner.)

The owner, 2026-11-21: a deterministic build is better, above all when an
incremental build equals a rebuild. After the estimate that upstream is not
likely to accept the change of `objectid` as it is: "Yes" to opt-in object ids
on our branch, with their cost measured first. The steps (on
`pr-linked-products`):

- [x] Deterministic object ids, opt-in. A Julia option makes a process that
      writes output give each new mutable object an id that does not come from
      its address. At the first ask, the id is `bitmix(scope, n)`: `scope` is
      the key of the top-level statement that runs, and `n` counts the ids of
      that key before. A table of
      the process holds the ids, and the GC sweep removes the entry of a dead
      object. `julia_cmd` passes the option to the precompile process.
      Proposed decisions:
      - The option is `--deterministic-object-ids={yes|no}`, default `no`.
      - The key of a statement is a hash of its module and of its form with
        no line numbers. A `module` statement takes only its name, and a
        `toplevel` form makes no key, so that the key of a statement does not
        depend on the other statements around it. (Found in the build: a key
        nested in the key of the statement around it differs between two
        processes, because the statement that starts a precompile process holds
        the depot path of that process.)
      - An object that no code asked for gets its id at the write, in the order
        of the heap, in the key of the write.
- [x] The gate `link_cascade.jl` with the option: the linked LinkB is equal in
      each byte to the rebuild, with no copy of the ids, and two whole builds of
      LinkB are equal, after one build id in both. (Julia `b0b587bf20`,
      CompilerServer.jl `171145f`: 0 bytes differ in each of the three edits,
      and the 9 objects of LinkA with an id that LinkB names keep it. With no
      option, 260 ids differ and none of the 9 keeps its id. The empty instance
      of a new memory type is a permanent object, `jl_gc_permobj`, which also
      takes its id from the table. The full build with the change takes 7 min,
      with a peak of 5.6 GB. The parts test of Julia (3 of 3) and the tests of
      CompilerServer.jl (45 of 45) pass.)
- [x] At the write, an object that no code asked for gets its id from the
      object that first reaches it and from the field. Gate: after an edit of
      LinkA that moves objects, each unchanged mutable object of LinkA keeps its
      id. (Done with another rule, Julia `07400635b9`, CompilerServer.jl
      `540d359`: an object that has a key by its kind takes `bitmix(key, n)` at
      the first ask, at any time: a method by its module, name and signature, a
      method instance by its method and types, a code instance by its method
      instance and owner, a binding by its module and name. In each of the three
      edits, each object of LinkA with an id keeps it: 27 or 28 with a key, and
      49 with no key (arrays, memories, binding partitions). Before this rule, 5
      of 27 with a key lost their id after the new function. The path ids are
      not built: the writer asks for ids of mutable objects in the fields of an
      immutable object before the write (the content hash of `dedup_by_content`),
      so a path id needs a change in the queue of the writer. The kernel package
      shows whether a larger package needs them.)
- [x] The cost on ProjecturedKernel: the time and the peak memory of a write
      with and without the option, the count of the object ids in the file, and
      what still differs between two whole builds with the option.
      (CompilerServer.jl `0889d22`, gate `test/gates/ids_kernel.jl`, three
      writes each: 6.01 to 6.05 s with the option, 5.84 to 5.95 s without it,
      about 3 % more; the precompile process peaks at 619 to 620 MiB, and at 614
      to 619 MiB without it. The file holds at least 72,087 object ids: that many
      differ between two whole builds without the option, and 7,567 with it.
      Other words differ in both: 163,317 and 189,155 words of the `.ji` file,
      the records of the functions and of the slots, and the size of the `.so`
      file. The first other difference is at byte 664 of the heap, so the order
      of the objects differs. 134,872 of the other words are in the sections after
      the objects, 32,251 are references, and 7,777 are type tags. The owner's PR
      #63150, branch `pr-reproducible-image-code`, sorts the work list of a
      build and the GC frame slots, which our branch does not have.)

- [x] Bring the three commits of #63150 (branch `pr-reproducible-image-code`)
      onto `pr-linked-products`, and measure the kernel again with
      `ids_kernel.jl`. For the table of the global slots, take the sort by name
      of #63150 in place of the order of the module of `f0a7bfd4b1`. (The owner:
      "Yes".) (Julia `9376816a09`, `8f619ca202`, `f8cec77e7c`, and `a6430b45de`;
      CompilerServer.jl `13a9ca3`.) Facts:
      - The first two commits apply with no conflict; the third replaces the
        order of the module for the slot table.
      - With them, the `.so` files of two whole builds of the kernel have the
        same code; they differ only in the checksum of the heap and the build id
        note (24 bytes).
      - Two more orders of addresses were left: `jl_get_llvm_cis` walked
        `jl_fvar_map`, a std::map keyed by the code instance (the list `new_ext`
        and the method instances of the writer), and the sort of the function
        table left the code instances with no function in the order of a
        DenseMap. `a6430b45de` fixes both.
      - With the option, two whole builds of the kernel now have the same order
        of their 152,226 objects and the same object ids. They differ in 102
        words (443 bytes): the random low half of the build id of the 24
        submodules (module byte 328), and 78 words of bytes that no one wrote:
        padding in the dump of a module (bytes 40, 368 and 384), padding after a
        `Bool`, the padding field `_` of a `ReentrantLock` (its constructor does
        not set it), and 16 words of constant data. Without the option, 67,774
        object ids and 110 other words differ.
      - The write takes 5.92 to 5.99 s with the option, and 5.94 to 6.14 s
        without it: the cost of the option is inside the noise.

The owner, 2026-11-21: "Yes" to the two causes that are left. The steps:

- [x] In a process with the option, a new object starts with zero bytes (the
      allocations of the GC: small, big, and the buffers of memory), and the
      writer writes zeros in each byte of an object that no field holds (the
      padding, by the layout of the type, also inside an inline field and in each
      element of a memory). (Julia `08c3a570ea`. Between the fields of an object
      the writer already wrote zeros; the padding inside an inline field, the
      bytes of an inline union after its value, the dump of a module and the
      unset padding field of a `ReentrantLock` were the ones that held old
      bytes.)
- [x] The build id of each submodule gets the same choice from content as the
      top module: `link_build_id!` gives each module of the file a low half from
      the low half of the top module and the hash of the module.
      (CompilerServer.jl `af59f5e`. The objects of the modules of a file share
      the type tag of the object of the top module; the places of the build id
      and of the hash in a module object come from a module of the process.)
- [x] Gate: two whole builds of ProjecturedKernel with the option are equal in
      each byte, after one build id; the cascade gate gives 0 bytes; the tests
      pass; the cost of the write with and without the option. (Two whole builds
      of the kernel: 0 bytes differ in the `.ji` file of 17,118,277 bytes and in
      the `.so` file; without the option, 67,774 object ids and 92 other words
      differ. A write takes 5.98 to 6.07 s with the option and 5.85 to 5.86 s
      without it, about 3 %; the peak of the precompile process is 626 to 630
      MiB with it and 620 to 630 MiB without it. The cascade gate gives 0 bytes
      in each of the three edits with the option, and 260 differing ids without
      it. The parts test of Julia (3 of 3) and the tests of CompilerServer.jl
      (45 of 45) pass.)

Landing (the owner, 2026-11-21: "Land and push and create remote repository for
compiler server under projectured GitHub user and ProjecturedRegistry"):

- `compiler-server-master` moved forward to `pr-linked-products` (`08c3a570ea`,
  18 commits on master `2aa7c9fd5b`); it and `pr-compile-apart`,
  `pr-code-from-parts` and `pr-linked-products` are on `levy/julia`.
- The repository `projectured/CompilerServer.jl` is public (in place of the
  `levy/CompilerServer.jl` of D3, by the owner's word); `main` = `af59f5e`.
- ProjecturedRegistry `42a565e` "New package: CompilerServer v0.1.0", tree
  `78a87590`, pushed.
- `merged-next`, with this plan and 183 commits of other work, is on
  `levy/julia` (the owner: "push").
- Not pushed: `compiler-server-evidence`, which waits for the owner (Steps 6
  and 7).

Gate: the prototype gives the same bytes, and the design document exists. Parts
2 and 3 of D get their own plan.

Facts of the design of D (CompilerServer.jl `07f776f`):

- A package file names an object of another image by the index of that image
  in its list of required modules and the word offset of the object in the
  heap of that image (`add_external_linkage`, `src/staticdata.c:1314`). So a
  change of A moves the offsets that B names, and the loader also checks the
  build id of A in the header of B.
- The heap of a split package file is in the `.ji` file; the `.so` file holds
  the native code and the checksum of the heap.
- The writer replaces worlds, code pointers and timings with fixed values, and
  the loader sets them: no byte of a file depends on worlds.
- Two stock writes of WriteApp differ in 2,110 of 47,258 bytes of the `.ji`
  file and in 43 of 20,008 bytes of the `.so` file. The random low half of the
  build id (`module.c:609`) appears 68 times: in the header, in the dump of the
  module, and as the key of the roots in each compressed method source.
- Proposed first prototype: the cascade by a link of references. A link of B
  maps each reference into the old A to a key, by a table that the write of A
  left, and the key to the offset in the new A. (The owner: "Yes".)

Facts of the first prototype (CompilerServer.jl `1f35304`, `pr-linked-products`
`f0a7bfd4b1`):

- LinkB names 16 objects of LinkA; each has a key, and each key finds its
  object in the new LinkA. Three edits of LinkA: no change, a new function at
  the end (it moves 4 of the objects, and the link changes 6 references), and
  another body of a function that LinkB does not call. In each, the linked LinkB
  loads from the linked file and gives the same output. The link takes about
  0.65 s; a stock write of LinkB takes about 0.76 s; both include the start of
  a process.
- The heap of B holds the low half of the build id of A as the key of the roots
  of the methods of A in the compressed sources of B. The link replaces it; the
  linked file did not load before this.
- Two writes of the same sources differ, word by word, in: the build id; the
  object id that the writer puts before each mutable object
  (`jl_object_id`, a hash of the address of a new object, `src/staticdata.c:1659-1671`),
  which the loader keeps so that `objectid`, `IdDict` and `Dict` of the image
  stay valid; three tables of `src/aotcompile.cpp` in the order of addresses
  (`ci_funcs`, `global_targets`, `call_targets`); and the checksums and the GNU
  build id note that follow from them. `f0a7bfd4b1` gives the three tables the
  order of the module (the order of emission).
- `lld --build-id` makes the note as the BLAKE3 hash (20 bytes) of the BLAKE3
  hashes of each MiB of the file, with the note set to zeros. `link_finish!`
  writes it again after a change.
- After the build id gets one value, the linked LinkB and a stock write of
  LinkB on the new LinkA differ only in the 260 object ids and in the checksums
  and the note that follow. With the object ids of the stock write, the `.ji`
  and the `.so` files are equal in each byte.
- A `Core.BindingPartition` of A has no key yet. A LinkB with an `IdDict`
  constant keyed by a `Ref` constant of LinkA names one, and the link stops
  with an error and writes no file.
- Open: the object ids. No link can give the bytes of a whole build in them
  unless they come from content. And a hash table of B whose key is a mutable
  object of A goes wrong after a link of B, because the new A gives that object
  another id.

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
