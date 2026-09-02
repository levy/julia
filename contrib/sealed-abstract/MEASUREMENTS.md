# Measurements

The numbers behind the design, with how to reproduce each. Everything was
measured on one 32-thread x86_64 Linux machine with Julia 1.13.0-rc3
(juliaup channel `1.13`). Times are wall clock. A number without a date is
from the campaign (August 2026); a dated number was re-measured then.

Two programs appear:

- **the probe** — the abstract-six-subtypes program `probe.jl` generates.
  In this repository; `./sealed.sh build` and `./sealed.sh compare`.
- **the flagship** — a routing simulation over a discrete-event simulator
  and a projectional editor stack, about 300 000 lines. It lives in the
  simulator's repository, not here; its numbers are quoted because it is
  the program this toolchain was built against. "Phase N" names its
  build ladder: phase 0 loads the packages, 1 bakes the parsed network
  description in, 2 parses the configuration at run time, 3 builds the
  network at run time, and the full entry records result files.

## The probe: stock against sealed (re-measured 2026-09-02)

| toolchain | verifier errors | binary |
| --- | --- | --- |
| stock juliac | 8, no binary | — |
| sealed | 0 | 1 800 632 B, runs (exit 21) |

Reproduce: `./sealed.sh setup && ./sealed.sh build && ./sealed.sh compare`.

## Verified dynamic dispatch against flattening (2026-08-24)

The flagship at 3 178 116 events, network hash bit-identical to the C++
reference kernel at every scale:

| build | binary | run time |
| --- | --- | --- |
| wide calls flattened to isa-chains | 6.4 MB | 1.06-1.08 s |
| wide calls dynamic, targets compiled | 3.4 MB | 0.235-0.260 s |
| the C++ kernel | — | 0.669 s |

The flattened chains measured 144-166 KB of code per event-loop
specialization. This measurement is why `SEALED_DYNAMIC_THRESHOLD`
exists.

## Record each target once

A declined split re-records its targets at every visit of every call
site. One flagship build recorded 852 832 881 targets for 45 771 distinct
instances — about 6.8 GB of pointers — and filtering them took 1079 s,
81 % of the build. With the IdSet dedup at the push site, peak resident
memory fell from 17-22 GB to 1 GB. The regression cases were unchanged in
feature, time and space. Memoising `specialize_method` was also tried and
bought nothing (1.72 s against 1.68 s on `bench_sealed.jl`, K=20 S=50),
so it is not in the tree.

## The compiler infers itself during precompilation

| quantity | before | after |
| --- | --- | --- |
| `activate!(codegen = true)` | 20.5 s | 0.03 s |
| empty program build | 18 s | 6 s (stock juliac: 7 s) |
| `features.jl` build | 18 s | 7 s |
| buildscript body | 12.7 s | 3.16 s |
| one regress case | ~17 s | ~6.5 s |
| peak memory | 1207 MB | 926 MB |

## Where the fixed build cost goes

Phase stamps on flagship phase 0, a program that only loads its packages:

    precompile-env          0.37 s
    load-compiler           0.10 s
    activate                0.01 s
    sealed-setup            0.04 s
    load-program           12.90 s
    subtype-map-and-warm    0.63 s
    trim-lists              0.93 s

The 12.90 s splits in two: 3.6 s was the sealed world being on while the
program loads (removed — the buildscript now turns it on after the load;
measured 12.90 s baseline, 9.29 s with `SEALED_WORLD=0`, 9.67 s with the
split limit at 4), and 8.9 s is Julia not reusing package images while
generating output, which stays open — a sysimage that carries the
packages is what would remove it.

## The split budget

Flagship phase 3 with the splitter at 20 000 passed fifteen minutes
without reaching the compile loop and was killed; at Julia's stock limit
of 4 it finished in 125 s. The build time is flat from limit 4 to 96 and
does not finish at 128. The widest abstract type in that image has 151
members, six times the next widest — the width report
(`SEALED-UNION widest`) exists because of this cliff. No standalone
example reproduces the cliff: five shapes were built and none reacts to
the limit, because the mechanism needs width and scale together (a
17 000-edge graph re-inferred at every widened site). That is recorded as
a genuine exception to reproduce-before-fix.

## The repair pass

About 0.86 KB of binary per repaired instance and no measurable build
time. On the `union_product.jl` cases (a record of n optional strings):

| n | combinations | repaired instances | binary |
| --- | --- | --- | --- |
| 2 | 4 | 0 (the optimizer inlines them) | 1742 KB |
| 6 | 64 | 128 | 1849 KB |
| 10 | 1024 | 2048 | 3514 KB |

Reproduce: `./product.sh`.

## Coverage accounting

Flagship phase 3 with `SEALED_COVERAGE=1`:

    SEALED-COVERAGE 14078 sites  required=2113441  traced=143  enumerated=2113298

Two million targets enumerated from the sealed method table against 143
answered by evidence, to produce 1694 compiled instances — the
enumeration does roughly a thousand times the work that survives it. The
widest sites are `getproperty` on an abstract IO or a NamedTuple at
about 1400 targets each, and Base's numeric tower
(`Tuple{Type{<:Number}, Number}`, 158 members) is present in every build
whatever the program does. The accounting itself costs about 20 % (the
same phase 130 s → 156 s), so it is off by default.

## The seal constructs, each measured as a pair

| pair | without the seal | with it |
| --- | --- | --- |
| `unreachable_debug` / `residual_sealed` (`seal_residual`) | 381 instances, 272 errors | 280 instances, builds |
| `buildtime_index` / `buildtime_sealed` (`seal_buildtime`) | 299 roots, 29 build-time trace entries | 269 roots, 0 |
| `union_cross_product` / `union_cross_generic` (`seal_collapse`'s target shape) | 216 enumerated combinations, fails past the budget | one widened body, passes |

On the flagship, `seal_collapse(_apply_word, 2, 3)` turned a
53 × 53 = 2809-combination site into one widened body
(`SEALED-REPAIR-WIDEN 2809 -> 1`), and the phase-3 error count walked
98 → 28 → 13 → 8 → 6 → 4 → 0 as the seal file grew. Phase 3 builds at 0
errors, 9 056 240 B.

Reproduce the pairs: `./ladder.sh` (each pair is two examples).

## The trace as evidence, and reproducibility

Seeded, `buildtime_index` fails — every trace entry is compiled whether
or not a site needs it. On the frontier loop it passes at 283 instances
against 299, because nothing asks for the 29 build-time entries. The two
loops are otherwise identical on every example at every level —
verified by running the ladder under both (`SEALED_LOOP=frontier
./ladder.sh` selects the second).

Sorting the trace buckets by `objectid` did not make builds reproducible:
four recompiles of one source gave 283, 283, 290, 283 instances (and the
290 failed). Sorted by the printed form: 283 four times. The drain had
the same defect earlier — error counts swung between 1 and about 120 on
identical inputs until the batch was sorted.

## The edge lookup, bounded

With `SEALED_EDGE_LOOKUP=1` (site limit 64, budget 4096): flagship
phase 3 pulls nothing and builds at 0 errors; the full flagship pulls 9
targets at its three over-budget sites, 0 refused, 0 errors, and the
result files keep the oracle hashes. Unbounded, the lookup did not
converge. The recording half costs a dictionary push per resolved call
and is off during an ordinary build; the flagship recording holds 20 758
sites and 63 726 targets.

## The generic fallback, refuted for splats

`residual_splat`: 2 errors with the fallback off, 75 with it on, 69 with
the element type known. Base's varargs `+` recurses through `afoldl`,
which is itself unbounded, so a stem does not close it. The flag and
these numbers stay (see the commit that adds it); the construct that
would close honest splats is `seal_arity` (DESIGN.md §45), not built.

## The flagship today (2026-09-02)

Rebuilt from the simulator repository against this branch's tip: the
two-process build (coverage run, then one juliac that records and
builds) completes in 263 s, one repair round (148 unresolved calls)
converges, 0 verifier errors, 14 268 856 B. The binary's event counts and
network hashes equal the C++ reference kernel's:

| simulated time | events | network hash |
| --- | --- | --- |
| 1 s | 14 | `d322a500fa64a67266a56bc3711b5a8f` |
| 100 s | 3 150 | `71d2b9bf42c2db93b2c6d6f97af0c214` |
| 1 000 s | 31 640 | `dd2fc4e75208437d8f80a683f20390a7` |

## The suite

`./regress.sh` pins feature, time and space against `baseline.tsv` and
runs the seeded ladder; `SEALED_LOOP=frontier ./ladder.sh` runs the
other loop. At this branch's tip (2026-09-02): FEATURE, TIME and SPACE
unchanged; the seeded ladder has the one pre-existing mismatch —
`buildtime_sealed` at the trace level (README.md records it) — and the
frontier ladder has none.
