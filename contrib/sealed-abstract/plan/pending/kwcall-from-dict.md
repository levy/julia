# Close the keyword class: construction from a dict of union-typed values

**Status: pending.** The example is in (`examples/kw_from_dict.jl`,
fail/fail/fail with `TRACE-ROOTS Main`); the mechanism is not.

**The class.** A program builds objects from a `Dict{Symbol, V}` a
configuration answered, `V` a small union — the C++-INET parameter shape.
Two shapes fail:

1. custom builders passing dict values RAW as keywords, so the keyword
   tuple carries union-typed slots and the kw sorter has no compilable
   instance;
2. the generic fallback `T(name; values...)`, whose `Core.kwcall` stem no
   evidence arm answers: the sealed enumeration does not model kw
   plumbing, the repair pass cannot split a kw signature
   (`SEALED-REPAIR-NOMI`), and the trace's kw-body instances are dropped
   by the root filter (`sealed_keep` keeps no Core-owned instance; the
   unfiltered ladder trace level DOES pass, which is the measured proof
   of where the gap sits).

**Found by** the 10BASE-T1S phase-3 build (inet-julia, 16 errors, seeded
and frontier agreeing — the class is loop-independent).

**Probe facts (2026-09-02, measured on the example):**

- The trace RECORDS the concrete kwcall tuple the binary needs —
  `Tuple{typeof(Core.kwcall), @NamedTuple{tag::String, limit::Int64},
  Type{Sink}, Symbol}` is entry 1 of the 15 — so the evidence exists.
- The kw sorter methods are MODEL-owned (`which` reports `module=Main`
  for both constructors), so the registration root filter passes them;
  "Core-owned" was wrong in the first statement of this plan.
- The blast radius is DRAIN-borne: with roots on, the errors' hosts are
  Base display machinery entered as `:drain` (1209 of the explained
  errors) — declined `(f::Any)(x::Any)` sites inside instances compiled
  at ABSTRACT signatures (the custom methods' own
  `AbstractDict{Symbol, V} where V` stems) pull the build session's
  warm Base instances through the membership keep.
- So the precise defect: instances of the builder methods are compiled
  at their WIDENED (declared) signatures although every call site
  resolves concretely, and their bodies' kw plumbing is unresolvable
  there. The lever is to stop the widened stems from entering (or to
  answer their kw sites from the recorded concrete instances), not to
  admit more evidence.

**Candidate levers, to be measured in this order:**

1. The drain filter admits a recorded kw-sorter/kw-body instance whose
   BODY method is model-rooted even though the sorter's owner is Core —
   ownership of kw plumbing should follow the method it sorts for. A
   filter rule, no new vocabulary.
2. The repair pass learns kw signatures: expand a
   `Tuple{typeof(Core.kwcall), NamedTuple{names, T}, typeof(f), ...}`
   over the union members of `T`'s slots, the way `switchtupleunion`
   expands positional unions. Bounded by the same limits.
3. A `seal_keywords(f, NamedTuple{names, Tuple{...}})` claim, when 1 and
   2 both leave a residue only the program can name.

**Gates.** The ladder example's three verdicts flip to the declared
target as each lever lands (re-declare deliberately, never silently);
the 25 existing examples stay at their declarations; regress FEATURE,
TIME and SPACE unchanged; then inet-julia phase 3 at 0 errors is the
real acceptance.

**Curation.** Commits on `sealed-aot` stay one-thing-per-commit in the
series' style; when the class is closed and the flagship re-verified,
the excursion is curated into the branch the way the 26-commit series
was built (the user's direction, 2026-09-02).
