# Design

This document states the decisions and the reasons. The code carries the
same reasons next to the lines they constrain; this is the connected view.
The section register at the end resolves the `§N` references that appear in
code comments.

## Substitute at inference, not at the verifier

The first attempt taught the verifier to accept dynamic calls on abstract
types. The build then passed and the binary died at the first dispatch with
`MissingCodeError`: acceptance does not compile targets. The substitution
must happen at inference, before method matching, so that each split
resolves concretely and is compiled. `abstract_call_gf_by_type` replaces an
abstract argument type with the union of its concrete subtypes
(`SEALED_SUBTYPES`), memberwise inside unions. `Any` is never substituted:
raise the limit at every call and inference tries to split `println(Any...)`
across a hundred methods, and the build does not finish.

The subtype map is computed by the buildscript after the user program
loads, and only for types whose root module is neither `Core` nor `Base`.
The program's own world is closed at that point; `Function` and `Integer`
are not, because Base abstract types have subtypes no walk can see.

## Keep a wide call dynamic, and verify it

The optimizer flattens a union split into an `isa` chain. For wide unions
that is the wrong code: 144-166 KB per event-loop specialization, and 6x
slower than the same dispatch through the method cache. So above
`SEALED_DYNAMIC_THRESHOLD` the call stays dynamic, the matched methods'
warm-run instances are pushed as compile targets, and the verifier accepts
the call because every matched method has a compiled instance in the image.
The world is closed, so run-time dispatch can not reach uncompiled code.

Two laws follow, and both were paid for in failed builds:

- A dynamic call has no backedges, so a declined site never fires again
  during the trim. The warm run of the build entry is the only harvest.
- The warm run must construct the exact types `main` constructs. A
  specialization that differs one type parameter deep builds at 0 errors
  and dies at the first dispatch with `MissingCodeError`.

## Price a split before you make it (§8)

Several substituted arguments at one call multiply. The compiler multiplies
the union widths first (`SEALED_SPLIT_CASES`); a site over the budget keeps
its abstract argument types, stays dynamic, and is answered further down
the lattice. Compiling one widened body is always cheaper than enumerating
thousands of concrete ones. This is a fall, not a refusal.

`SEALED_SPLIT_LIMIT` is separate from `max_methods`, so a build can hold
inference to the stock union splitter. That separation is what makes the
`proven` policy level real (§42).

## The lattice of evidence (§23, §42)

A dispatch site is closed by the strongest evidence available:

1. **proven** — inference resolved the call; an `:invoke` edge exists.
2. **sealed** — the closed-world enumeration of the method table.
3. **trace** — a recorded run observed the target at this site.
4. **declared** — the program promised it in a seal file.

`SEALED_EVIDENCE_ORDER` consults trace before sealed. The campaign plan
argued the other order (a seal speaks about a whole domain, a trace about
one run). The disagreement is recorded in a table so that it can change,
and eventually become cost-based.

The three policy levels of the ladder (§42) are cuts through this lattice:
`proven` = level 1 only, `sealed` = 1-2 plus promises, `trace` = 1-4.

## Bounded effort at every boundary (§35)

Every mechanism that can cascade carries a budget, and every refusal is
counted and reported: the split budget, the repair limit
(`SEALED_REPAIR_LIMIT`), the edge lookup (`SEALED_EDGE_SITE_LIMIT` per
site, `SEALED_EDGE_BUDGET` per build), and the diagnostic print caps.
Unbounded, the edge lookup pulled the closure of the whole recorded graph
and never converged.

## The repair pass

The optimizer materializes a union split as branches only while the
combinations stay small (measured: 9 yes, 16 no). Above that it leaves one
dynamic call, and every concrete use inlined to a `:new`, so no instance
was ever compiled for the method. The verifier, in repair mode, records the
widened signature instead of erroring; `typeinf_ext_toplevel` expands it
with `switchtupleunion`, compiles the concrete instances, and verifies for
real. One instance at the widened signature is not enough: the runtime
specializes on the actual argument types.

Widening through `get_compileable_sig` happens only where effort stops —
at a site over the repair limit. Widening every site would compile generic
bodies where concrete ones resolve, and a generic body has more unresolved
calls, not fewer. `get_compileable_sig` is the same normalization dispatch
performs, so it honors `nospecialize` — declared in the source, or set by
`seal_collapse` (§46).

## Seals: what the program knows (§45, §46, §47)

A seal is a claim the program states and the compiler applies. The
vocabulary lives in `seal_hints.jl`; under stock Julia every seal is a
no-op, so the same program text runs everywhere. A build names a seal file
with `SEALED_SEAL_FILE`, so claims need not be written into the program.

- `seal_buildtime(expr)` — this work runs at build time only; the recorder
  must not turn its instances into entrypoints. The argument is an
  expression, not a block: Julia infers a whole top-level statement before
  the call runs, so a closure body can never be snapshot. `Core.eval`
  moves the compilation inside the window.
- `seal_residual(within, f; from, at)` (§47.3) — this call site only ever
  receives the listed types. Keyed by (calling method, called function): a
  global claim about `Base.show` is false, because everything calls it.
  `at` names the argument positions, because one union rarely flows into
  all of them. The narrowing reuses the abstract-as-union substitution;
  only the replacement set differs. Inferring the call as `Union{}` was
  the first design and does not work: `Union{}` says a call does not
  return, not that it does not happen.
- `seal_argument(f, pos, T)` — what the callee's own parameter is,
  wherever it is called. A union-typed callee narrows only if every member
  promises the position; one member's word would be false for the others.
  A position every member promises `Union{}` can never be occupied, so the
  call never happens and inference answers "never returns". The promise is
  applied in inference and in the verifier, through one function — the two
  compute a site's type separately, and a promise honored in only one of
  them narrows what is compiled while the other reports the underived
  types.
- `seal_instances(P, [P{A}, P{B}, ...])` — the instantiations a parametric
  type has in the image. `switchtupleunion` splits a `Union`, not a
  `UnionAll`, so a free type parameter otherwise yields nothing to
  compile.
- `seal_collapse(f, positions...)` — set the method's `nospecialize` bits.
  The generic step of the lattice needs the program: compiling a widened
  instance answers nothing when the method still specializes, and the
  compiler can not retrofit `@nospecialize` onto declared typed
  parameters.

## Two compile loops (§21-38)

`compile_seeded!` is the stock shape: roots seeded first, static edges
followed, the drain of declined sites folded in. `compile_frontier!`
(solver.jl) holds one worklist of obligations, each carrying the evidence
that justified it, and every unresolved call goes through one
`resolve_dispatch`. The principle (§31): solve the frontier, never the
program. `compile!` is a dispatcher over the two, so a build can not mix
them; `SEALED_LOOP` selects, and the two are cross-tested against each
other on the ladder.

## The trace is evidence, not roots (§26)

The seeded loop registers every trace entry as an entrypoint, so a
recorder defect can bloat a binary and nothing ever asks whether a site
needed the entry. On the frontier loop a declined site consults the trace:
an entry no site demands is never compiled, so an over-broad trace costs
nothing, and recorder precision stops mattering.

A recorded edge is keyed by (caller method signature, statement index) —
the source location. The argument types can not be the key: the site
resolves narrow while recording and is declined wide while building. Sites
are recorded in inference (`abstract_call_gf_by_type` sees calls the
inliner never processes) and indexed by the called function's type, or
every call in the program is a candidate.

## Determinism

Identical inputs must build identical binaries. Both drains sort their
batches by the printed form of the signature, and dispatch-tuple instances
sort first so a concrete instance is compiled before its widened cousin.
`objectid` is not a content hash across processes — sorted by it, the same
source gave 283 instances and a pass, then 290 and a failure.

## Diagnostics that explain themselves

Five wrong hypotheses about one build came from guessing provenance out of
symptoms. So: every compiled instance carries why it entered
(`SEALED_PROVENANCE`), every verifier error walks its parent chain to a
root and across the registration boundary into the recording run
(`SEALED-WHY`), every error names its statement (an index shifts with
every seal), and the missing method is named, not only the caller. Two
rules were learned the hard way and are now structural: a diagnostic must
not be able to kill the report (every walk is wrapped and capped), and a
walk over the parent map must expect cycles — the document printer shows a
field that is a document.

## The build must be observable

One clock over parent and child (`SEALED_T0`), a stamp at every phase, a
progress line every few seconds from the frontier loop, and a per-instance
time dump (`SEALED_ITEM_DUMP`). The median instance costs 0.03 ms and the
mean is carried by a handful of enormous ones, so only the distribution
says anything. `SEALED_COVERAGE=1` accounts how each site was closed:
required, traced, enumerated — the enumerated column is the cost
`seal_residual` exists to remove.

## Image-admission policy is not all mechanism (§P)

The drain filter (`sealed_keep`) and two verifier skips encode knowledge
of the flagship's split between its run path and its editor layer:
display-named methods, macro-expansion machinery (`CellStructModule`,
`DocumentModule._emit_*`), `SelectionModule`, reference-pattern printers
(`ReferenceModule._show_*`), reactive-cell-carrying signatures, and erased
(all-`Any`) kernel instances. These rules are honest and each carries its
measured reason, but they name one program's modules inside the compiler.
The generalization is known: turn each rule into a program-side
declaration with the seal vocabulary, the way `seal_residual` already
replaces trace filtering. Until then, a program with a different editor
layer edits `sealed_keep`.

## The section register

The campaign plan lived in the flagship's repository and numbered its
sections; code comments cite those numbers. The cited sections are
restated here so this branch is self-contained.

| § | statement |
| --- | --- |
| §0 | Restructure code so the compiler can see through it — the cheap half of every fix. |
| §5, §5c | A union element type trims; an abstract element type does not. The rule this branch removes. |
| §6b | The recorder's closure walk and the build's must agree, or entries are dropped that the build needs. |
| §8, §8a-c | The union-product failure classes: a binary operator over a wide union (U²), a parametric constructor over P union parameters (V^P), a record of n optional fields (2ⁿ). `union_product.jl` generates §8c. |
| §21-38 | The demand-driven solver: obligations, evidence arms, one resolve_dispatch. |
| §23 | The evidence order. The plan wrote PROVEN > SEALED > TRACE; the table consults trace first; recorded, not resolved. |
| §26 | Trace edges are keyed by call site (signature, pc), and a declined site asks for its own targets. |
| §31 | Solve the frontier, never the program. |
| §35 | Every boundary gets bounded effort, and every refusal is counted. |
| §37 | Trace merging: several recorded runs as one evidence set. Open. |
| §42 | The policy levels: proven, sealed, trace. |
| §45 | `seal_arity`: close a varargs call by declaring its arities. Open; `residual_splat` is its test. |
| §46, §46.2 | `seal_collapse`: the generic step needs the program to set nospecialize bits; a collapsed body must narrow its own arguments. |
| §46.4 | Coverage accounting: required, traced, enumerated, per site. |
| §47.1 | A finite domain could take a closed dispatch table. Open. |
| §47.3 | `seal_residual`: close a site over what covers it. |
| §P | The image-admission policy above: flagship-informed, to become declarations. |
