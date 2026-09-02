# The sealed compiler

This branch makes `juliac --trim=safe` accept programs that dispatch on
abstract types. It changes `Compiler/` and `contrib/juliac/`, and it carries
its own test suite in this directory. A checkout of the branch tests itself.

Read the branch commit by commit: each commit adds one mechanism and states
its reason. This file gives the goal and the map. [DESIGN.md](DESIGN.md)
holds the design decisions. [MEASUREMENTS.md](MEASUREMENTS.md) holds the
numbers and how to reproduce them. [HISTORY.md](HISTORY.md) holds what was
tried and rejected.

## The problem

`--trim=safe` refuses a binary that could reach code the image does not
contain. A dynamic dispatch on an abstract type is exactly that: inference
can not name the targets, so the verifier reports an unresolved call and the
build fails.

The stock answer is to rewrite the program: replace every abstract field
element type with a `Union` of concrete types, and thread that union through
every container and every signature. The motivating program — a
discrete-event simulator with a projectional editor, about 300 000 lines —
did this for one type and the result was reflection, memoization on the
world counter, and a type parameter on every touched struct. That cost
repeats for every abstract type. The compiler has the information; the
program must not carry it by hand.

## The idea, in one paragraph

At build time the world is closed: every package is loaded, and no new
subtype of the program's own abstract types can appear. So the compiler can
treat **an abstract argument type as the union of its concrete subtypes**
("the sealed world"), enumerate the targets of each call, compile them, and
either resolve the call statically or leave it dynamic with a **verified**
target set: the verifier accepts a dynamic call when every matched method
has a compiled instance in the image. Where enumeration is too wide, the
build does not refuse: the call **falls down a lattice of evidence** —
proven by inference, enumerated from the sealed world, observed by a
recorded trace, promised by the program in a seal file — and every level of
that descent is bounded and reported.

## What is here

| area | content |
| --- | --- |
| `Compiler/src` | the sealed world, the split budget, verified dynamic dispatch, the repair pass, the two compile loops, the trace and edge evidence, the promises, and diagnostics that explain every error |
| `contrib/juliac` | the driver and buildscript: the subtype map, the warm-instance table, the seal-file plumbing, phase timers |
| `contrib/sealed-abstract` | this directory: the harness, the probes, the trace tooling, the example ladder, and the regression suite |

Everything is behind `SEALED_*` switches. `SEALED_WORLD=0` turns the whole
apparatus off and the toolchain behaves like stock juliac.

## How to run it

The branch needs Julia 1.13 (the compiler is a swappable package since
1.12; everything here is measured on 1.13.0-rc3 via juliaup).

```
./sealed.sh setup        # create env2, the project that loads Compiler/ from this repository
./sealed.sh build        # build the abstract-six-subtypes probe: 0 errors, the binary runs
./sealed.sh compare      # the same program under stock juliac: 8 errors, no binary
./regress.sh             # feature, time and space against baseline.tsv, plus the ladder
./ladder.sh              # the example ladder alone; SEALED_LOOP=frontier selects the second loop
```

`sealed_paths.sh` finds the compiler two directories up, so no sibling
checkout is needed. Set `SEALED_JULIA` to test another checkout.

## The policy levels

Every example in `examples/` declares which levels must pass:

- **proven** — the sealed apparatus off, stock inference limits. What the
  compiler can prove without any closed-world assumption.
- **sealed** — the sealed world on. Abstract types are their subtype
  unions; wide calls stay dynamic with verified targets.
- **trace** — a recorded run supplies observed dispatch targets as
  evidence that a declined site can consult.

An example that passes a level it declared to fail is a MISMATCH: it stops
testing its mechanism, and the ladder reports it.

## Status

The flagship program (a routing simulation over the simulator and editor
stack) builds at 0 verifier errors, about 14 MB, and its binary reproduces
the C++ reference kernel's event counts and network hashes exactly. The
regression suite pins feature, time and space for the small cases.

Open, and declared where it applies:

- `residual_splat` fails at every level. A varargs call through Base's
  numeric tower has no closing mechanism yet (DESIGN.md §45).
- `trace_typeparam` strictly needs a trace: dispatch on `Type{...}` values
  is invisible to the sealed enumeration.
- `buildtime_sealed` mismatches at the trace level on the seeded loop
  (on the frontier loop it passes everywhere). The declaration and the
  compiler diverged in the final commits of the campaign, after the last
  full ladder run. The failure is identical from the ladder's old home
  against the same compiler, so it is not the move.
- Parts of the image-admission policy name the flagship's editor layer
  (see DESIGN.md §P). Turning those rules into program-side declarations
  is the next generalization step.
