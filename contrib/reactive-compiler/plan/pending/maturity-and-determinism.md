# Maturity for upstream, and a result that a reviewer can check

The reactive compiler works and is measured. It is not ready for a pull request
to Julia, and the reason is not the code. This plan makes the work reviewable,
and it makes the product of a rebuild checkable.

## What a reviewer stops at today

| what | number |
| --- | --- |
| lines added over `8f33e09afe` | 17 491 over 94 files |
| `src/staticdata.c` | +2748 lines |
| tests under `test/` | 0 |
| lines in `doc/` or `NEWS.md` | 0 |
| reactive checks inside shared serializer code | 69 |
| constructs that need Linux and x86-64 | 31 |
| new stdlib in the system image | 1, about 1900 lines |

Three stops follow from that table. No test can run in Julia's CI, because the
proof of this work is nine shell gates that need a forked PackageCompiler and a
private application. No measurement shows that a stock build does not regress.
The parts that carry the feature need Linux and x86-64.

One objection is deeper than all three. A stock image is a pure function of its
inputs. A reactive image is the heap of a process that ran for hours, written to
a file. The speed comes from that fact. A reviewer will ask what makes the
rebuilt image equal to a fresh build, and the answer must be a check that runs,
not a paragraph.

## The two tracks

Track A makes the work reviewable. Track B makes the result checkable. Track B
is the one that decides whether Track A can ever end in a merge, so the two run
together.

# Track A — maturity

## A1 — the two PackageCompiler pull requests

`parallel-build` (6 commits) and `cached-base-sysimage` (3 more) carry no
reactive dependency. They are the mature part of the whole campaign.

1. Take the campaign files out: `plan/pending/*.md`, `plan/pending/ensurecompiled.jl`.
2. Take `examples/MyApp/Manifest.toml` out. An example does not carry a lock
   file upstream.
3. Write a test for each change that a test can reach: the cache of the base
   system image, the object archive that `create_sysimage` keeps, the private
   build directory that a failure drops.
4. Measure again on a clean checkout, with the numbers that go into the pull
   request body: the build before, the build after, the machine.
5. Send two pull requests, in order. The second stands on the first.

## A2 — the two micro-fixes to Julia

Each is small, each stands alone, and each needs a test of its own.

| fix | what it is worth |
| --- | --- |
| `src/gf.c`: store a flag only when it changes | a write to an object of a loaded image dirties a copy-on-write page for nothing; every process that loads a package image pays it |
| `src/cgmemmgr.cpp`: the child of a fork opens its own `/proc/self/mem` | a fork of a process with the JIT memory manager writes to the parent's memory today |

Take the reactive condition out of the first hunk of the `gf.c` fix. Measure the
pages that stay shared, on a process that loads a package image twice.

## A3 — the design note, and the question

Write two screens, not an essay. Cut
[doc/architecture.md](../../doc/architecture.md) to about 60 lines: what a
reactive build is, the four write modes, the measured numbers, and the guarantee
that Track B gives. End with one question: would the core team accept a stateful,
incremental image path in the tree at all?

Send it before you write more code for upstream. A "no" makes the fork the
correct home, and then Track A ends after A1 and A2.

## A4 — a test that Julia's CI can run

The feature has no in-tree user, so it has no test. Give the stdlib a driver
small enough to found a store and rebuild it with no external package:

1. `ReactiveCompiler.found(package_dir, out; tracked, workload)` — the founding
   of a one-file package, through the same child as PackageCompiler uses.
2. `ReactiveCompiler.rebuild(out)` — one apply and one save.
3. `test/reactive.jl`: found a package of two functions, edit one, rebuild,
   check the oracle digest against a founding of the same sources, and run the
   binary. Give it a bound of five minutes.

The test is also the in-tree user that A2's third candidate (the section
override of the loader) needs.

## A5 — the stock build does not regress

Measure, do not argue. Build the same system image twice with the branch and
twice with `8f33e09afe`, on the same lane, with the flags off. Report the
seconds and the size. Sixty-nine branches in the serializer probably cost
nothing; the pull request needs the number, not the word "probably".

## A6 — the platform

State what the feature needs: `dl_iterate_phdr`, `/proc/self/mem`, `mprotect`
with a fault handler, and an ELF writer. Make every other platform a clean
refusal at the flag, not a build error. Say in the note that the design is not
bound to Linux, and name what a second platform would take.

## A7 — the driver leaves the PackageCompiler fork

`src/reactive.jl`, `src/reactive_cli.jl` and `src/trimmed_wrapper.c` load their
harness by UUID, so they do nothing on a stock Julia. Move them into a package
of their own. Then A1's two branches carry no reactive code at all, and the fork
of PackageCompiler can go.

# Track B — a result that a reviewer can check

## The ladder

Each level is a property, a gate that proves it, and a cost. A reviewer accepts
the product at the level that the gates reach, not at the level that the design
hopes for.

| level | the property | the gate | state |
| --- | --- | --- | --- |
| 0 | the same edit from the same snapshot gives the same bytes | two rebuilds, `cmp` the overlays | to build |
| 1 | the binary runs the same as a fresh build | the same workload on both, output compared | partly, in Gate H |
| 2 | the heap is semantically equal to a founding | the oracle: methods, roots, globals | **done**, Gates B, C, D |
| 3 | the native code of every live specialization equals a fresh compile | an object diff over every function | to build |
| 4 | the heap is structurally isomorphic to a founding | a canonical walk with a permutation map | to design |
| 5 | the image is byte-identical to a fresh build | — | **not a goal** |

Level 5 is out of reach and out of scope. An image carries object identity, hash
order, world counters and gensym counters. Say so once, in the note, with the
reason.

## B0 — the baseline: is a stock image reproducible?

Do this first, because it sets the bar. Build the same trivial application twice
with a stock Julia, and compare the two images byte for byte. Do the same for a
package image.

- If a stock image is not byte-reproducible, the reactive image can not be held
  to a higher standard. That is the strongest sentence in the design note, and
  it costs one hour to earn.
- If a stock image is byte-reproducible, level 0 and level 3 become the
  properties that matter most, and the plan says so.

## B1 — level 0: the rebuild is deterministic

Run the same apply and the same save twice, from the same snapshot, in two
processes. Compare the two overlays byte for byte.

1. A difference here is a defect of the writer, not of the design.
2. The likely sources are the order of a hash table, a pointer in a key, a
   timestamp, and the path of a temporary file.
3. Fix each one until the two overlays are equal, or record why one can not be.

The gate is `tool/gate_det.sh`. It is cheap: two rebuilds of one edit.

## B2 — the classifier of differences

Write `tool/image_diff.py`. It takes two images and prints one line per
difference, with the class of each:

| class | example | expected |
| --- | --- | --- |
| identity | an object id, a pointer key | yes |
| order | a hash table that rehashed | yes |
| world | a world counter, a capped bound | yes |
| counter | a gensym counter | yes |
| code | the bytes of a function | **no** |
| shape | an object that one image holds and the other does not | **no** |

The tool turns "the images differ" into "the images differ in four expected
classes and in nothing else". That sentence is what a reviewer can accept.

## B3 — canonicalize what is cheap to canonicalize

Every class that B2 finds and the writer can remove makes the claim stronger.
Take them one at a time, cheapest first, and measure the cost of each on the
save:

1. rehash the tables of the image in a canonical order at the save
2. reset the counters that a module keeps, when nothing refers to them
3. drop the tables of the trace and the ledger before the write (already done
   for the trim memo)
4. normalize the world bounds of a dead entry

Stop when the cost of the next one is more than the save can pay. Record what
stays and why.

## B4 — level 3: the machine code

The oracle is silent about the machine code: it compares the lowered code and
says nothing about the bytes. Close that hole, because a stale reuse is exactly
the fault a reviewer fears.

1. Extract the text of every live specialization from both images.
2. Normalize the relocations, as `tool/m0_objdiff.py` does for two builds.
3. Compare. A difference names the function.

A found difference is a real defect. An accepted difference needs a reason in
the log: a different optimization level, or a call that resolves to a symbol in
one image and to an address in the other.

## B5 — level 1: the same behavior, over many edits

Gate H compares one number after one edit. Make it a population.

1. Take a package with a workload that prints a large, sensitive result.
2. Generate 200 random edits from the catalog of Gate B: a body, a signature, a
   new method, a deleted method, a constant, a type, a macro, a using.
3. After each edit, run the reactive binary and a fresh build of the same
   sources, and compare the output byte for byte.
4. Report the count. "Two hundred edits, two hundred equal outputs" is the
   sentence that a practical reviewer wants.

The cost is the fresh builds. Run it once per week, not per commit.

## B6 — level 4: structural isomorphism

Design first, build later. Walk both heaps from the same roots, in the same
order, and pair the objects. Two heaps are isomorphic when the walk pairs every
object and every field, with a permutation of the identities alone.

- The walk must be canonical: the order of a table must not decide the pairing.
- The report names the first pair that does not match, and the path to it.
- The cost is one walk of each heap; the routing image holds about 65 000
  functions, so the walk must be iterative, not recursive.

This is the strongest checkable claim short of byte equality. Build it after B2
and B3, because canonicalization removes most of the noise it would report.

## B7 — the provenance of a binary

A reviewer trusts an artifact that says what it is made of. The store already
holds the material: the tracked sources, their hashes in `reads.txt`, the spec
of every snapshot, and the trace.

1. Put a record into the image: the founding's source hashes, one line per
   snapshot with the files it applied, the compiler version, and the flags.
2. Give the binary a flag that prints it: `<app> --build-provenance`.
3. Give the builder a verify pass: read the record, hash the sources on disk,
   and report the files that moved since the snapshot that compiled them.
4. Print the level of the ladder that the build reached.

This is small, it is cheap, and the binary then says what it is made of. Do it early:
it helps the user of a store as much as it helps a reviewer.

# The order of the work

1. B0, the baseline. One hour, and it decides how the note argues.
2. B1 and `tool/gate_det.sh`. Level 0 is the cheapest strong property.
3. B7, the provenance record. Small, and useful to the daily loop.
4. A3, the design note and the question. Send it with B0, B1 and the ladder in
   it.
5. A1, the two PackageCompiler pull requests. They do not wait for an answer.
6. A2, the two micro-fixes.
7. B2 and B3, the classifier and the canonicalization.
8. A4, the in-tree test; A5, the regression measurement; A6, the platform.
9. B4, the machine code; B5, the population of edits.
10. B6, the isomorphism, if the answer to A3 was not "no".
11. A7, the driver leaves the fork.

## What this plan does not do

- It does not claim byte equality with a fresh build. Level 5 is not a goal.
- It does not rewrite the campaign into upstream shape. That work follows the
  answer to A3, and it is larger than this plan.
- It does not change the reactive design. Every item here measures, checks or
  records what the design already does.
