# The reactive compiler

A persistent, reactive materialization of Julia system images. A build is a
snapshot of a store, the way a commit is a snapshot of a Git object database.
After a source edit, a rebuild boots from the previous image, applies the
changed expressions alone, and emits the invalidation cone of the edit.
Everything else — most of Base, the packages, the application — links again
from the object code of the earlier snapshots.

| what | with the reactive compiler | with a fresh build |
| --- | --- | --- |
| the routing example image | 21 s | 117 s |
| the routing binary bundle | 12 s | 155 s |
| one edit of a hub method | 0.8 s, 37 functions of 65067 | — |

A rebuilt binary runs the edit at full speed: a call to a reused function costs
1.0 ns against 1.0 ns.

## Where to start

1. [doc/architecture.md](doc/architecture.md) — the system as it stands, and
   the reasons for its shape. Read this to work on it.
2. [plan/pending/robust-incremental-compiler.md](plan/pending/robust-incremental-compiler.md)
   — the stages, their gates, and the log of what each one measured.
3. `julia --help-hidden` of this branch — every control is a flag, and every
   flag has a variable as its default.

## What is where

The product is the branch itself, not this directory:

| what | where |
| --- | --- |
| the image format, the write modes, the save | `src/staticdata.c` |
| the delta and its id spaces | `src/aotcompile.cpp`, `src/processor.cpp` |
| the front that reuses the image's code | `Compiler/src/typeinfer.jl`, `Compiler/src/precompile.jl` |
| the flags | `src/jloptions.c`, `base/options.jl` |
| the harness and the server | `stdlib/ReactiveCompiler/` |
| the client that drives a build | PackageCompiler, branch `reactive` |
| the application that measures it | the omnet build, branch `reactive-builder` |

This directory holds the campaign that produced it:

| directory | what |
| --- | --- |
| `doc/` | the system as built |
| `plan/pending/` | the plan that still has open items |
| `plan/done/` | the record of the campaigns that are complete |
| `tool/` | the gates, the oracle, and the probes |
| `src/` | the Julia code of the campaign, before the harness became a stdlib |
| `bench/` | a synthetic package for the first measurements |

## The gates

A gate builds a store, edits it, and compares the result with a founding of the
same sources. The oracle digests an image — its method tables, its roots, its
output and its globals — so a difference is a fault of the reuse and of nothing
else.

| gate | what it proves | what it needs |
| --- | --- | --- |
| `tool/gate_b.sh` | one change of every category of the catalog | `tool/m6_hazard`, PackageCompiler |
| `tool/gate_c.sh` | the image of a chain does not grow, and holds one definition per live function | `tool/m6_hazard`, PackageCompiler |
| `tool/gate_d.sh` | ten edits through the compiler server | a founded routing store |
| `tool/gate_e.sh` | the trimmed product through the edits | `tool/trim_app` |
| `tool/gate_f.sh` | Gate D with the image written by pages | a founded routing store |
| `tool/gate_g.sh` | Gate D with the overlay image | a founded routing store |
| `tool/gate_h.sh` | a rebuild driven by a client that has the socket alone | a founded routing store |
| `tool/gate_cli.sh` | `julia -m PackageCompiler build`, `status`, `stop`, `watch` | a founded routing store |
| `tool/oracle_gate.sh` | a chain of two edits against the founding | `tool/m6_hazard`, PackageCompiler |

Run `tool/gate_c.sh` first. It needs this branch built in `usr/` and the
PackageCompiler checkout beside it, and nothing else. Every gate takes `OUT`,
`PC` and `OMNET` from the environment; the defaults are `$TMPDIR/reactive/<gate>`
and the checkouts beside this one.

## The tools of the dead ends

The tools below belong to questions that the campaign answered and left behind.
They are the instruments of the measurements that the plans in `plan/done/`
report, so a reader who checks a number needs them. No gate runs them, and they
are not maintained.

| what | the question it answered |
| --- | --- |
| `tool/phase1_*.jl`, `tool/prove_*.jl`, `tool/why_missed.jl`, `src/GraphHarvest.jl`, `src/MethodEdit.jl`, `bench/SynthApp` | does an edit to one function leave the rest of a build compiled? |
| `tool/m0_*`, `src/ReadKey.jl` | what is the ceiling of the reuse, and does the key of an object agree with Julia? |
| `tool/m1_gate1.sh`, `tool/m4_*`, `tool/m5_gate.sh`, `tool/m6_gate.sh`, `tool/m7_gate.sh`, `src/Materialize.jl` | the gates of the first store, before the oracle |
| `src/SourceDiff.jl` | the copy that `stdlib/ReactiveCompiler/src/SourceDiff.jl` replaced |
