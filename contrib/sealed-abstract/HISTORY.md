# History

The main line of this branch shows the system, not the search for it.
This document preserves the search: the layouts that came before, the
approaches that were tried and refuted, and the corrections — including
the ones where the instrument itself lied. The branch was rebuilt as a
direct series on 2026-09-02; everything below is from the campaign that
produced it (August 2026).

## The layouts before this one

The sealed compiler had three homes. First a set of Python patch scripts
(`sealed_patch.py` through `sealed_patch9.py`) that rewrote a gitignored
working copy of the Compiler package: `setup` deleted the copy and
replayed the patches. That scheme destroyed a session's uncommitted work
at least once (the measuring instrument had to be rebuilt from scratch),
could hold only one patch level at a time, and could not express that a
patch pairs with a particular model commit. Second, a vendored copy of
the patched Compiler inside the model repository's tree, tracked by git —
levels became commits. Third, this branch: the changes live in
`Compiler/` and `contrib/juliac/` of the Julia repository itself, and the
ladder lives beside them, so a checkout tests itself.

The base patch (`sealed_patch.py`, dropped in the rebuild) did one thing:
raise `max_methods` at a call site whose argument type is an abstract
type other than `Any`. Everything else grew from what that turned out not
to solve.

## The original spike, and what it proved

The question was whether `--trim` can accept an abstract element type. A
probe (still in the tree) answered: yes for a plain hierarchy, no for a
parametric one — a single match whose signature has free type parameters
is not a method-count problem, so no limit helps
(`parametric_check.jl`). Three traps from the spike still constrain the
code: a limit raised everywhere makes inference split `println(Any...)`
and the build never ends; `widenconst` raises an error on a `Vararg`
entry; and `Base.Experimental.entrypoint` pushes roots into the builtin
`Base.Compiler`, not the loaded one, which produces a clean verifier
report, no code, and a link failure — a fourth way to misread a build
log.

## The nine patch levels

What each level of the original series added, in one line each:

1. the base patch applied to a copied Compiler and juliac;
2. the substitution at inference — an abstract type IS its union of
   concretes (teaching only the verifier produced binaries that died
   with `MissingCodeError`);
3. verified dynamic dispatch — wide splits flattened to isa-chains
   measured 6x slower, so the wide call stays dynamic and its warm-run
   targets are compiled;
4. the sorted drain, the membership keep-list and the cellfree rules
   (each guard bought a measured collapse: 22 -> 110 without the
   coverage skip, 1040 -> 240 without the roots scope);
5. one drain exclusion for the editor's selection module;
6. `SEALED_BUILD_THREADS` — a parallel-engine warm run deadlocks at
   juliac's pin of one thread, silently, for 38 minutes;
7. two verifier skips for the flagship's reference-pattern printers and
   erased all-`Any` kernel instances;
8. the repair pass;
9. record each dispatch target once (852 832 881 records, 6.8 GB, fell
   to 1 GB peak).

## The instrument lied, twice

Routing phase 3 was reported at **1 error** for days. Adding the
why-chain took it to **197** — a printing change can not do that, so the
count was never real: the error count is incremented as errors are
PRINTED, and the diagnostic threw partway through error #1, taking the
whole verification with it, with no "Trim verify finished" line to say
so. The same session had already produced a silent variant: an omitted
import made every chain throw `UndefVarError` into the one catch that
prints "SEALED-DESC-DETAIL failed" — 314 of them, saying nothing.

Then **197 became 780**. `verify_print_error` walks the same parent map
the why-chain walks, with no cycle guard; the document printer shows a
field that is a document, so the map cycles, and the walk appended stack
frames until the OS killed the process — 385 million iterations on the
first error, child exit 137, swap exhausted. Nothing was ever thrown,
which is why two commits of try/catch changed nothing: it was a hang
treated as an exception. 780 was the first count produced by a report
that ran to the end. Both rules that came out of this are structural
now: a diagnostic must not be able to kill the report, and every walk
over the parent map expects cycles.

A smaller one of the same family: every ladder count was one too high,
because the header line of the table matched the example-counting
pattern. 25 examples, not 26.

## Refuted, with the numbers

- **Trace filtering by display names**, tried twice (98 and 114 errors):
  it removes true evidence. A document really is printed during the
  recording run; the trace entry is honest, and the question "why is
  this compiled" becomes "why does the recording run print a document" —
  a question about the program, not the compiler.
- **Two push-site guards** (skip Core/Base at the warm-instance pushes):
  editing them in and out measured 73 691 against 77 262 pushes and
  meant nothing, because editing the compiler changes what the build
  session itself compiles, which moves every count by more than the
  guard. As a runtime switch on one compiler it is a no-op on the
  examples; the switch and the warning stay, the guards do not.
- **The compiler-only generic arm**: compiling the method's own widened
  signature under the split-budget fallback builds clean and the binary
  dies at run time — dispatch specializes on the concrete argument
  types and falls into a JIT the binary does not contain. The generic
  step needs the program (`seal_collapse` setting nospecialize bits).
- **The generic fallback for splats**: 2 errors off, 75 on, 69 with the
  element type known. Base's varargs `+` recurses through `afoldl`.
  Kept behind a flag with the numbers.
- **Memoising `specialize_method`** in the record-once work: 1.72 s
  against 1.68 s. Not included.
- **A permissive drain root filter**: one example went from 273
  instances to 3544 and from a clean failure to a compiler crash.
- **An instance bound as a split detector**: the splitter inlines its
  cases, so instance counts do not move when a product explodes — only
  the compiler's own counter sees it, which is why examples declare
  `SPLIT-CASES`.

## Wrong hypotheses, and what ended them

Five hypotheses about one flagship build were formed from symptoms and
each cost a 318-second build to refute; provenance tagging ended the
class. A promise (`seal_residual` on `Base.show_vector`) was believed
applied for an hour while it never fired — no `SEALED-RESIDUAL` line;
the entry change was reverted rather than left doing nothing, and the
lesson (silent non-application) shaped the seal-file error rules. An
early bisect blamed the edge-table lookup for a signal-4 crash when the
actual cause was a `DataType` assert fed a `UnionAll` — two things had
changed at once, and the recovery was credited to the wrong one. The
seeded loop once ran against `Base.Compiler`'s `add_entrypoint` instead
of the loaded compiler's, worked by accident, and the frontier path
threw on every entry while a catch swallowed the reason.

## Nondeterminism, found twice

Identical builds disagreed twice: the drain's error count swung between
1 and about 120 on identical inputs (unsorted IdDict order), and later
the trace arm gave 283-pass / 290-fail on the same source (an
`objectid` sort, which is stable only within a process). Every small
instance-count delta measured before the printed-form sorts could have
gone either way; verdicts were unaffected. The flagship phase counts
were each taken once in that era.

## The recorder, before edges

As a root list, the trace put 8645 package instances into a phase-1
binary that reads one number out of a finished index — a trace entry
was an entrypoint, so nothing ever asked whether a site needed it. As a
bare target list it also could not answer declined sites (the recorder
walked `main`'s closure and dropped a method reached only through a
field, which the build then compiled zero times). Site-keyed edges and
the frontier loop's consult-at-the-site rule are the answers; the
seeded loop and the old semantics are kept as the cross-tested baseline.

## Leftovers this rebuild repaired

The move into this repository left a machine-absolute path to
`julia-config.jl` in the driver (now resolved from `Sys.BINDIR`),
execute bits on six driver files from a stray `chmod`, the spike-era
README describing a layout that no longer exists, and `sealed_patch.py`
itself — summarized above, dropped from the tree.
