# A tree of regions

The chain generalizes to a declared tree of lifetimes. The motivating
shape is the degenerate tree: a fixed trunk whose last level branches
into sibling leaves — a shared `Simulation` trunk with one private event
leaf per task, where sibling leaves are mutually isolated and each leaf
resets on its own. The generic tree costs one word-sized mask test in
two cold paths, so the degenerate form is not a separate mechanism: it
is one particular parent vector. The zero-cost-when-unused claim of
MATURATION.md must survive every stage unchanged.

Internal only, as in the maturation plan's stage 0: no posts, no
issues, no discussions; any upstreaming is the user's manual act.

## Design decisions (from the 2026-09-03 analysis)

- **Parentage is declared data, not order.** Today `m < n` implies that
  `m` is an ancestor of `n`. In a tree that stays true only per branch,
  so the shape must be declared once: `region_tree!(parents)` — index =
  child, value = parent — or incremental `region_parent!(child,
  parent)`. Enforce `parent < child`: the ids then stay a topological
  order of the tree, and the existing assertion shapes survive. The
  current chain is the declaration `[0, 1, 2]`; the degenerate tree is
  `[0, ..., B, B, B]`.
- **The barrier tests an ancestor mask.** `ancestor_mask[r]` = the bit
  set of r's ancestors, r itself, and region 0, one word per region. A
  store of child `cr` into parent `pr` is legal when
  `(ancestor_mask[pr] >> cr) & 1`. The test replaces `cr <= pr` in the
  cold call `jl_gc_region_wb` only: one load from a 512-byte table plus
  a bit test. The disarmed hot path — one predicted branch per pointer
  store — does not change.
- **One word bounds the region count.** 64 regions on this
  architecture, because an ancestor set must fit one machine word for
  the one-instruction test. The page tag (`uint8_t`) and the window
  state need no layout change. The quarantine mask widens to
  `uint64_t`.
- **The census filter keeps its shape.** One region: equality on the
  page tag, as today. A subtree collect: `(subtree_mask >> region_n) &
  1`, the same load-and-test, paid only inside a census. The rule
  "everything outside the censused set is implicitly live" is already
  the filter's else-branch and survives verbatim; tasks stay the extra
  roots.
- **The quarantine stays per region.** A leaked object in region `cr`
  can reference only `cr`'s ancestors, which outlive it, so
  quarantining `cr` alone still contains the damage in a tree.
- **An id names one lifetime, never a per-thread role.** The
  declaration is global; the page instances stay per thread heap. Two
  threads must not reuse one leaf id for their two private regions:
  the pair's page tags compare equal, so the barrier would pass a
  cross-thread store between them undetected. With distinct leaf ids
  the ancestor-mask test quarantines leaf-to-leaf stores across
  threads in both directions — the multi-thread program (a shared
  trunk plus one private leaf per thread) becomes checkable, not just
  disciplined.
- **A shared trunk resets as one act.** A trunk that several threads
  allocate into is physically one instance per thread heap, and
  trunk-internal cross-thread references are legal (equal tags), so a
  per-instance reset would dangle them. `region_reset` of a region
  with instances on several heaps therefore walks every heap's
  instance under stop-the-world. The leaf reset keeps today's
  per-instance fast path — one heap, one bit test, no coordination.
- **The reset precondition is per branch, and one bit for a leaf.**
  Reset of `r` needs every descendant of `r` dead. Per thread heap,
  keep a live-child counter per region and one word
  `region_childless_mask`: bit `r` set = `r` has no initialized child.
  A child's first initialization clears the parent's bit and increments
  the counter; a child's reset decrements it and sets the bit back at
  zero. The reset precondition for a leaf is then ONE bit test — the
  hot case, because per-event leaf resets are the point of the shape.
  `region_subtree_reset(r)` resets a whole branch in postorder as the
  convenience for the non-leaf case. The masks are per thread heap,
  which suffices because a cross-thread reference into a region is
  already an escape.
- **The TLS array goes lazy.** `regions[JL_GC_MAX_REGIONS]` is inline
  today (~1.3 KB per slot); at 64 slots that is ~85 KB per thread.
  Replace the inline array with per-slot pointers, allocated at first
  initialization.
- **The API keeps its signatures.** `region_set`, `@with_region`,
  `region_collect`, `region_collect_coop`, `region_of`,
  `region_current`, `region_reset` all keep taking bare integers. New:
  `region_tree!` / `region_parent!`, `region_subtree_reset`. Names stay
  in the examples and in the checker's `region_names!` registry, never
  in the runtime. Nesting-derived (implicit) parentage was considered
  and rejected: it makes the tree depend on execution order, and the
  same region under two parents has no consistent answer.

## Stage 1 — the declaration and the masks

- [ ] `region_tree!` / `region_parent!` with `parent < child`
      validation, ancestor-mask construction, per-heap live-child
      counters and `region_childless_mask`, and the lazy TLS slots.
      Acceptance: a declaration test that builds a chain, the
      degenerate tree, and a two-branch tree; rejects a cycle, a
      forward parent, and a redeclaration under a different parent;
      masks and childless bits checked after every init and reset
      transition.

## Stage 2 — the barrier and the quarantine on the tree

- [ ] `jl_gc_region_wb` tests the ancestor mask; the quarantine mask
      widens. Acceptance: a sibling-isolation test — two tasks
      interleaved on ONE thread, each in its own leaf over a shared
      trunk (the coverage the chain could not express); a store from
      one leaf into the other quarantines in BOTH directions; leaf →
      trunk stores pass; trunk → leaf stores quarantine. The same
      matrix across TWO threads with distinct leaf ids — the
      cross-thread leaf-to-leaf store must quarantine, which the
      same-id chain could not even detect. The armed light-loop median
      must not move against the chain build.

## Stage 3 — census and reset on the tree

- [ ] Leaf reset behind the one-bit precondition; `region_reset` of a
      region with live descendants refuses with a distinct code;
      `region_subtree_reset` in postorder; subtree collect behind
      `subtree_mask`; the cross-heap trunk reset under stop-the-world.
      Acceptance: per-task leaf churn — N tasks, each opening,
      filling, and resetting its own leaf repeatedly while the trunk
      lives and siblings stay untouched; RSS bounded; a census of one
      leaf leaves sibling data intact; the stock collector runs
      mid-churn with no contract, as in the maturation plan's stage 2.
- [ ] The three-thread program, end to end: three threads share one
      trunk region under application locks, each thread allocates and
      quick-resets its own leaf, and the trunk resets once at the end
      across every heap. The test also proves the lock discipline: a
      lock-held push into a shared trunk structure must run with the
      trunk current — done with the leaf current, the resized backing
      memory lands in the leaf and the barrier must quarantine it (the
      stage-1 Dict-resize hazard, now in its multi-thread coat).

## Stage 4 — evidence

- [ ] The zero-cost re-check: the GCBenchmarks serial set A/B against
      vanilla must stay at the maturation baseline (the four realistic
      benches within noise, both big_arrays stressors at vanilla or
      below) — the tree must not reopen the inline-budget seam in the
      mark drain (keep the filter outlined; re-read the memcpy-caller
      profile if any number moves).
- [ ] The showcase for the shape: the simulator trunk with per-task
      event leaves, against the chain build's single event region —
      the win to show is per-leaf reset frequency and isolation, not
      raw throughput.

## When the stages stand

As in the maturation plan: the work ends at the evidence, every stage
carries its measurements, and the packaging question stays the user's.
