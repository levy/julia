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

### Step 3: the rebuild logic

- [ ] Copy `SourceDiff.jl`, `child.jl`, `replay.jl`, `server.jl` and
      `entrypoints.jl` from `stdlib/ReactiveCompiler` of `merged-next`. Do not
      copy `patch.jl`, because package patches are not in the new design.
- [ ] Replace each runtime function that only the fork has:

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

- [ ] Write down here each rule of the change catalog that stock master must
      refuse and the fork applies.

Gate: the unit tests of the rebuild logic pass on the build of Step 1.

### Step 4: the driver

- [ ] Move the store, the inputs, the record of the builds, the status, the
      early end when nothing changed, the watch and the command line from the
      PackageCompiler fork into `CompilerServer.build`, `CompilerServer.watch`
      and `julia -m CompilerServer`.
- [ ] Make the products with stock PackageCompiler (`create_sysimage`,
      `create_app`) and with the stock precompile. CompilerServer.jl needs no
      fork of PackageCompiler.

Gate: `build`, `status` and `watch` work on `HazardApp`.

### Step 5: the checks

- [ ] Move `tool/oracle.jl`, the cases of `gate_cases.sh` and of
      `gate_replay.sh`, `HazardApp`, `CaseApp` and `CaseLib` into the tests of
      CompilerServer.jl.
- [ ] Compare the state of the server after each edit with a fresh process that
      loads the final sources: the same method tables, roots, output and
      globals.

Gate: each case gives the digest of the fresh process, or it is a refusal that
`must-refuse.txt` or Step 3 lists.

## Part 3: the texts of the issues

### Step 6: the evidence branch and issue 0

- [ ] Make the branch `compiler-server-evidence` at master. Put on it the
      measurements that the texts quote: the cascade on 1.13 (99 cache files,
      about 280 s), the rebuild of the fork (21 s against 117 s), and the cases
      of Step 5.
- [ ] Write issue 0 from the draft in the note, in one screen.

Gate: the owner approves the text. A send is a separate word of the owner.

### Step 7: the issues about the module identity, B, C and D

- [ ] Module identity: start from the text of step S5 in
      `maturity-and-determinism.md` of the branch `determinism-experiment`, and
      measure again on master. It is a second issue of A, beside #63149.
- [ ] B, C and D: one screen each.

Gate: the owner approves the four texts.

## Part 4: the pull requests

### Step 8: A, the names from content

- [ ] Check #63150 against the master of Step 1 again, and answer its review.
- [ ] On `pr-reproducible-names`: give constants (`_j_const`) and strings
      (`_j_str`) names from their content in place of a counter. Add a test that
      builds one image twice and compares the object files.
- [ ] Write the text of the pull request.

Gate: the test passes; the suites of Step 1 show no new failure; the owner
approves the text.

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
