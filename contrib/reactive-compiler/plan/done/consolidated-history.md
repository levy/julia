# Consolidate the reactive-compiler branch

The branch works. Its history is hard to follow. This plan cuts the same tree
into a short series that an external reader can read, one commit per mechanism.

## What the branch holds today

| number | what |
| --- | --- |
| 116 | commits over `8f33e09afe` (`release-1.13`, 1.13.0-rc4) |
| 94 | files changed, 17491 lines added, 203 removed |
| 71 | new files, 13 of them executable |
| 0 | files deleted or renamed |
| 23 | files that existed before and now differ |

Three properties make the series hard to follow.

1. Only 35 of the 116 commits change a line of Julia. The other 81 change the
   campaign tree alone, and 27 of those change only the plan or the
   architecture document. They sit between the code commits and break the line
   of the work.
2. One mechanism arrives in many steps. 35 commits change `src/staticdata.c`.
   The page writer takes eleven of them, and three of those repair the same
   window of an object rewritten in place.
3. A repair follows the commit that it repairs. A reader meets the fault first,
   then the repair, and must hold both to read the next commit.

## The rule

**Commits 1 to 15 must reproduce the tree of `2e0b8cfcc4` byte for byte.**
`2e0b8cfcc4` is the tip of the branch before this plan. Commits 1 to 15
reorder, merge and split the 116 commits below it. They change no line of code,
no file name and no file mode.

The check is one command, and it must print nothing:

```
git diff 2e0b8cfcc4 <commit 15>
```

Commits 16 to 19 change the tree on purpose. They are the cleanup, and each one
stands alone above the check.

**Done.** `git diff 2e0b8cfcc4 4aeb3a2ec9` prints nothing.

### The cleanup

- **The two finished plans move to `plan/done/`.** `hypothesis-case.md` and
  `reactive-materialization.md` record work that is complete. Two files name
  them: `doc/architecture.md` twice, and `src/reactive.jl` of PackageCompiler
  once. The move updates both.
  `robust-incremental-compiler.md` stays in `plan/pending/`, because its status
  section still holds open items.
- **`contrib/reactive-compiler/README.md` is new.** It says what each directory
  holds, which tool a gate still runs, and which tool belongs to a dead end. It
  is the first file an external reader opens.
- **The gates lost the paths of one machine.** Every gate took its output
  directory from the scratchpad of one session, and the PackageCompiler and
  omnet checkouts from one home directory. A gate now writes under
  `$TMPDIR/reactive/<gate>` and takes a neighbour checkout beside its own.
  `OUT`, `PC` and `OMNET` still name another place. This commit was not in the
  first form of the plan; the paths came to light during the work.

### What stays out

- **The tools of the dead ends stay.** `tool/m0_*`, `tool/phase1_*`,
  `tool/prove_*`, `tool/why_missed.jl`, `src/GraphHarvest.jl`,
  `src/MethodEdit.jl`, `src/ReadKey.jl` and the gates M1 to M7 are the
  instruments of the measurements that the two finished plans report. A reader
  who checks a number needs them. The README names their state, which is the
  cost they carry.
- **The base stays at 1.13.0-rc4.** A rebase onto a newer upstream Julia changes
  the product, and every measurement of the campaign holds against this base.

## The target series

Nineteen commits: fifteen that hold the tree of `2e0b8cfcc4`, and four that
clean it. The order is the order of a reader: the controls, then the runtime in
the order the machine uses it, then the record, then the cleanup.

### The product

| # | subject | paths | folds |
| --- | --- | --- | --- |
| 1 | The reactive flags of julia, and the variables behind them | `src/jloptions.{c,h}`, `base/options.jl`, the option accessors of `src/staticdata.c` | 599bc97f9a |
| 2 | A process keeps the image it booted from, and maps a code instance to its function ids | `src/staticdata.c`, `src/julia_internal.h` | 5088e2e8ff, f05a0e135a, 47853bdc06, 693dd120d4 |
| 3 | The compiler front reuses the code instances of that image | `Compiler/src/{typeinfer,precompile}.jl`, `src/method.c`, `src/precompile.c` | 03d7ef70d2, f05a0e135a, 47853bdc06, c0b3834c2b, 52bf6889a3, f7a879c3e9, b89d8c6396, 48c8dc1543 |
| 4 | The delta emits into the append-only id spaces of the base, and calls a reused function by its symbol | `src/aotcompile.cpp`, `src/processor.{cpp,h}`, `src/llvm-multiversioning.cpp`, `src/codegen.cpp` | 7258cf94b0, bca1430d75, 693dd120d4, 47853bdc06, 8411112a03, 1845419f54 |
| 5 | The reactive image format: one function table, and the dead code left out | `src/staticdata.c`, `Compiler/src/precompile.jl` | 693dd120d4, 243ea3db9d, c6ed07c93f, 52bf6889a3 |
| 6 | A save writes a named output from a forked child | `src/staticdata.c`, `src/cgmemmgr.cpp` | d551e37c5a, 8b1f215a82, f7a879c3e9 |
| 7 | The image written by pages: the dirty pages of the heap, and the window of an object rewritten in place | `src/staticdata.c`, `src/signals-unix.c`, `src/gf.c`, `src/julia.h` | 94cee84daf, b73232c869, 3dca77f71f, 3d3e3e6092, 2ff4e1fbf8, 56aa67b807, bc8b63e775, 6ec6bdcde2, f7c45bd094, c6b98b565e, d42a74fbf7 |
| 8 | The overlay image and its chain: the base in a region, the patch as word runs | `src/staticdata.c`, `src/aotcompile.cpp` | 1eac8a3604, d007511dce, 2f8566b504, ced30a627e, 296fc2eb21, ecc29bc64b, b5b6ce413d, fbab24ed24, 8b68d6edaf, 843c307ac9 |
| 9 | The trimmed product of a save, and the refusal that names its cause | `Compiler/src/{typeinfer,precompile,verifytrim}.jl`, `src/staticdata.c` | a858af0ae0, a83259c6c7 |
| 10 | The memo of the trim pass: the code instances the image served | `Compiler/src/{typeinfer,precompile}.jl`, `src/staticdata.c` | 504b564f3e, bca774c4ff |
| 11 | The stdlib ReactiveCompiler, and `julia --reactive-server=<socket>` | `stdlib/ReactiveCompiler/`, `base/{sysimg,client}.jl`, `stdlib/stdlib.mk`, `stdlib/Makefile` | 9c32c24ff8, 997be08e90, ea4dd73c7b, f7198b47ce |

### The record

The four commits below take the final content of their paths. They need no
hunk work.

| # | subject | paths |
| --- | --- | --- |
| 12 | The hypothesis, and the probes that measured it | `plan/pending/hypothesis-case.md`, `src/{GraphHarvest,MethodEdit,ReadKey}.jl`, `bench/SynthApp/`, `tool/phase1_*`, `tool/prove_*`, `tool/why_missed.jl`, `tool/m0_*` |
| 13 | The materialization campaign, and the gates M1 to M7 | `plan/pending/reactive-materialization.md`, `src/{Materialize,SourceDiff}.jl`, `tool/m1_gate1.sh`, `tool/m4_*`, `tool/m5_gate.sh`, `tool/m6_gate.sh`, `tool/m6_hazard/`, `tool/m7_gate.sh` |
| 14 | The oracle, and the gates of the stages A to H | `tool/oracle.jl`, `tool/oracle_gate.sh`, `tool/gate_[bcdefgh].sh`, `tool/gate_cli.sh`, `tool/trim_app/`, `tool/cone_probe.jl`, `tool/server_request.py`, `tool/heap_chain.py` |
| 15 | The plan of the robust incremental compiler, and the architecture document | `plan/pending/robust-incremental-compiler.md`, `doc/architecture.md` |

### The cleanup

| # | subject | paths |
| --- | --- | --- |
| 16 | The two finished plans are done, and the document names their place | `plan/done/{hypothesis-case,reactive-materialization}.md`, `doc/architecture.md` |
| 17 | The gates find their neighbours from the checkout, and write under TMPDIR | `tool/*.sh`, `tool/cone_probe.jl` |
| 18 | A README of the campaign: what it built, and what still runs | `README.md` |
| 19 | The plan of this consolidation, done | `plan/done/consolidated-history.md` |

### Why the flags come first

A commit must compile. `src/staticdata.c` reads `jl_options.reactive_image_write`
from commit 7 on, so the field must exist before it. The whole block of fields
lands in commit 1, and `src/julia_internal.h` declares the whole block of
functions in commit 2. A field that nothing reads and a declaration that nothing
calls both compile and link.

## The method

Do not replay the old commits. Cut the final diff instead. Every commit then
holds final code, and no reader meets a state that a later commit replaces.

Each of the 71 new files belongs to exactly one target commit, so a checkout of
the path is enough. Only 5 files carry more than one mechanism:

| file | hunks at `-U0` | owners |
| --- | --- | --- |
| `src/staticdata.c` | 115 | 1, 2, 5, 6, 7, 8, 9, 10 |
| `src/aotcompile.cpp` | 49 | 4 |
| `Compiler/src/typeinfer.jl` | 17 | 3, 5, 9, 10 |
| `Compiler/src/precompile.jl` | 14 | 3, 5, 9, 10 |
| `src/precompile.c` | 4 | 6, 7 |

The other 18 modified files have one owner each.

A hunk is too coarse a unit. One hunk of `src/staticdata.c` adds 803 lines and
another 648, and each of them holds the functions of several mechanisms. Cut
every hunk at the definitions of the final file instead, which gives 346
chunks, and take the comment block above a definition with it.

**The owner of a line is the commit that wrote it.** `git blame` on the final
file names that commit, and a table maps each pair of an original commit and a
file to a target commit. The 35 commits that changed Julia need 60 such pairs,
because five of them changed more than one mechanism at once. A first attempt
took the owner from the name of the function that contains the chunk; it left
172 of the 346 chunks open, so the blame replaced it.

Three cases stay for the hand:

1. A line that blame gives to an upstream commit. A branch edit that moved
   upstream code keeps the old author. Such a line takes the owner of its
   neighbours inside the same chunk. There are 12 of them.
2. A chunk that deletes lines and adds none. Blame says nothing about a
   deletion. There are 4, and `git log -S` names the commit that removed each.
3. `src/aotcompile.cpp`. The emission of the delta, the one function table of
   the format and the ELF data object share their local variables, so the whole
   file is one owner: commit 4.

**A definition must not be later than its earliest use.** The first cut put the
globals of the overlay in commit 8, and the page writer of commit 7 names three
of them in one condition. A check reads the final file, takes the owner of every
definition and the owner of every use, and reports a use that comes first. Ten
symbols failed it, and a loop moved each definition to the commit of its
earliest use, until nothing moved. A global that nothing reads yet compiles, so
a definition can always go earlier; a line of a condition can not go later.

The chunks split further at every change of owner, which gives 527 pieces. The
replay writes a shared file as the base file plus every piece that a commit with
that number or a lower one owns. It applies the pieces by their line number in
the base file, so no context ever has to match, and for the highest number every
file equals the old tip byte for byte.

## The stages

### Stage 0 — the rescue point  — **done**

1. The tag `reactive-compiler-detours` holds the old tip `c226ce0006`, which
   is `2e0b8cfcc4` with the first two commits of this plan. Keep the tag local.
   Do not push it.
2. Make a scratch worktree at the base:
   `git worktree add <scratchpad>/consolidate --detach 8f33e09afe`.
3. Do every step below in that worktree. The built `usr/` of
   `julia-reactive-compiler` must not move.

Warning: never add `contrib/reactive-compiler/tool/__pycache__/` or
`tool/m6_hazard/HazardApp/Manifest.toml` to the index. They are untracked and
they stay untracked.

### Stage 1 — the map of the owners  — **done**

1. Cut the diff of the 5 shared files into chunks at the definitions of the
   final file: 346 of them.
2. Take the owner of every line from `git blame` and the table of the pairs.
3. Decide the three cases that blame leaves open, above.
4. Split every chunk at a change of owner: 519 pieces, each with one owner.

### Stage 2 — the replay tool  — **done**

`<scratchpad>/replay.py` takes a commit number, and for each shared file it
writes the base file plus every piece that a commit with that number or a lower
one owns. `replay.py check` proves the tool: for the highest number, all five
files equal `git show 2e0b8cfcc4:<path>` byte for byte.

### Stage 3 — the new series  — **done**

For each target commit, in order:

1. Check out the final content of the paths that the commit owns whole.
2. Write the five shared files with `replay.py`.
3. Stage the paths of that commit alone, by name.
4. Commit with the subject of the table and a body of at most six sentences.

The series runs from `922061515d` (the flags) to `4aeb3a2ec9` (the plan and the
document). `src/staticdata.c` divides as 61, 190, 379, 21, 872, 968, 37 and 128
lines over the commits 1, 2, 5, 6, 7, 8, 9 and 10.

### Stage 4 — the identity check  — **done**

1. `git diff 2e0b8cfcc4 4aeb3a2ec9` prints nothing.
2. `git status --porcelain` prints nothing.
3. `git log --stat` shows the file scope of the table, commit by commit.

### Stage 5 — the cleanup commits  — **done**

1. `610726bef6` moves the two finished plans into `plan/done/` and updates the
   two links of `doc/architecture.md`.
2. `a19a976665` takes the scratchpad of one session and the home directory of
   one machine out of the gates.
3. `a499bf2c73` writes `README.md`: what the campaign built, where the product
   lives in the branch, what each directory holds, the gate to run first
   (`tool/gate_c.sh`, which needs no omnet checkout), and the tools of the dead
   ends.
4. This plan comes last, at `plan/done/consolidated-history.md`.

### Stage 6 — the branch  — **done**

1. In `julia-reactive-compiler`, with a clean tree: `git reset --hard <new tip>`.
   The source files do not change, so git rewrites none of them and the build in
   `usr/` stays valid.
2. Check that `src/staticdata.c` keeps its modification time.
3. `git push --force-with-lease origin reactive-compiler`.
4. Keep the tag `reactive-compiler-detours` local. Do not push it.

Warning: do not run `make` after the move. The rewrite gives every commit a new
hash, so `make` regenerates `base/version_git.jl` and rebuilds the system image,
about 40 minutes. The build that exists stays correct, because no source file
changed. The rebuild waits for the next real source edit.

### Stage 7 — the test at the end  — **done**

The tree is the tree that was built and gated, so no gate can fail for a reason
this plan created. Run two gates once, with the build that exists, to prove that
the move broke nothing:

1. `tool/gate_h.sh` — the server started by a flag, and a rebuild driven by the
   Python client alone.
2. `tool/gate_cli.sh` — `julia -m PackageCompiler` on the routing store and on
   TrimApp.

Both pass on the build that exists. Gate H rebuilds the routing sample through
the socket alone: the apply is ok, the save takes 0.8 s, the overlay links as
`sys.12.so`, and the hop mean goes from 2.308 to 4.616, which is exactly the
edit. Gate CLI runs its thirty checks — a rebuild, a watch, a stop, a founding
of TrimApp, a kill in the middle of a founding, and a founding again — without a
failure. Both gates also prove the new defaults of the paths.

No commit of the series is built. The check of the order above is what stands
for it: no commit names a symbol that a later one defines.

### Stage 8 — PackageCompiler  — **done**

The branch `reactive` of `package-compiler-reactive` holds 34 commits over
`b072ac8` of `cached-base-sysimage`. They touch 7 files, and 1150 of the 1607
new lines are one new file. Cut them into 6 commits by the same method:

1. The store, the founding and the delta of a rebuild.
2. The compiler server as the compiler of a build.
3. The image write modes: pages, and the overlay chain.
4. The compact policy, and the founding staged beside the app.
5. The trimmed product, its launcher and its memo.
6. The command line `julia -m PackageCompiler`, and the documentation.

The header comment of `src/reactive.jl` names
`plan/pending/reactive-materialization.md`. Stage 5 moves that file, so commit 6
of this series writes the new path.

Leave the 8 commits of `cached-base-sysimage` alone. They are another feature,
and they carry their own base.

The series is `29b9acf` to `5d5c1b4`, and a seventh commit, `8c57dde`, writes the
new path of the record that Stage 5 moved. `git diff cc2f081 5d5c1b4` prints
nothing. One deletion of `src/PackageCompiler.jl` carries no blame, and
`git log -S` names the commit that made it.

### Stage 9 — omnet  — **done**

The branch `reactive-builder` of `omnet-julia-m1` holds 14 commits over
`e21ba2cd`. Cut them into 4:

1. The reactive builder in the build system.
2. The build command line: the bare rebuild, `--found`, `--trim`, `--dev`,
   `--watch`.
3. The tests of the build.
4. The guide, and the plan of the interface.

Every file of this branch has one owner, so the series takes no blame and no
replay: four checkouts of paths. The series is `37358938` to `59134c85`, and
`git diff d0eddc1f 59134c85` prints nothing. The plan of the interface lands
in `plan/done/` at once, where the old series moved it later.

### Stage 10 — close

**Done.** The three branches carry their new series, `reactive-compiler` is
pushed, and the two gates pass. The three tags and branches of the old history:
`reactive-compiler-detours` in the Julia checkout, and the reflog of the two
others.

## The cheaper alternative, and why this plan does not take it

An interactive rebase keeps the 116 commits in their order, squashes each
repair into the commit it repairs, and folds every plan commit into the record.
It costs about two hours and no hunk work. It ends with about 30 commits.

This plan does not take it, because the result still shows a reader three
writes of the same page window and two forms of the overlay patch. The detour
would be shorter, not gone. The full cut costs about a day, most of it
in the 215 hunks of Stage 1, and it ends with final code in every commit.
