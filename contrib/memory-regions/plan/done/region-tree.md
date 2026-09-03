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

## Stage 1+2 — the declaration, the masks, and the barrier (MERGED)

Merged because the ancestor masks are inert without the barrier that
reads them; one testable increment.

- [x] LANDED 2026-09-03, commit 2d1a8f9e28. `jl_gc_region_declare_parent`
      (Julia `region_parent!` / `region_tree!`) with `parent < child`
      validation; `region_uptree[r]`, the bitset of r, its ancestors,
      and the root, built in index order; `jl_gc_init` seeds the chain
      default so an undeclared build is the old total order.
      `jl_gc_region_wb` tests `(region_uptree[pr] >> cr) & 1` instead of
      `cr <= pr`. Acceptance met: sibling_isolation_test.jl — a trunk
      with two leaves, leaf → trunk legal, leaf → sibling and trunk →
      leaf quarantine; a forward parent (`parent >= child`) is rejected.
      The four chain regression suites stay green. DEFERRED to stage 5:
      the two-thread distinct-leaf matrix (needs JL_GC_MAX_REGIONS > 4
      for a trunk plus one leaf per thread), and the armed light-loop
      re-measurement.

## Stage 3 — the reset on the tree

- [x] LANDED 2026-09-03, commits 0a7eeb47ec (single-heap) and
      b9c1c11330 (cross-heap). Leaf reset behind the one-bit
      precondition; `region_reset` of a region with a live child
      refuses with `-7`; the cross-heap trunk reset
      (`jl_gc_region_reset_global`) stops the world, checks the child
      precondition on every heap, and resets each heap's instance as
      one act (the per-heap body factored into `region_reset_heap`).
      Per-heap `region_live_mask`, `region_haschild_mask`, and
      `region_child_count[]` maintain the bit: a `region_set` marks a
      region live (its parent gains a child), a `region_reset` marks it
      empty (the parent's haschild bit clears at its last child).
      `JL_GC_MAX_REGIONS` raised 4 -> 8 for a trunk plus one leaf per
      thread. Acceptance met: reset_order_test.jl (leaf-before-trunk,
      200 rounds of leaf churn, trunk intact) and multithread_tree_test.jl
      (three threads, shared trunk under a lock, distinct leaves,
      global reset). `region_subtree_reset` in postorder is deferred:
      the two-level trunk/leaves shape needs only leaf reset plus the
      global trunk reset; a deeper tree wants it. The census on a
      subtree (`subtree_mask`) is deferred with it.
- [x] LANDED 2026-09-03. The three-thread program end to end
      (multithread_tree_test.jl): three threads share one trunk under a
      lock, each quick-resets its own distinct-id leaf 50 rounds, the
      trunk survives, and it resets once globally across every heap.
      The lock discipline is a separate focused test
      (lock_discipline_test.jl): a trunk vector grown with the TRUNK
      current stays clean, and grown under a LEAF window it stores a
      leaf element into the trunk's backing memory — an escape that
      quarantines the leaf (the stage-1 Dict-resize hazard in its
      multi-thread coat).

## Stage 4 — evidence

- [x] The zero-cost re-check DONE 2026-09-03 (TREE.md holds the table).
      GCBenchmarks serial set, tree vs vanilla, min of three
      interleaved on the isolated core: append 1.02, linked tree 0.98,
      strings 1.01, pollard 0.92, single_ref 1.03, many_refs 0.92 —
      the maturation baseline holds. The tree changes only the
      barrier's cold path (a mask load) and the region count (4 -> 8),
      neither on a regions-unused path; the six regression suites stay
      green.
- [x] LANDED 2026-09-03 (showcase_tree.jl, table in TREE.md). A mini
      event loop: a permanent network (region 0), three worker tasks
      each owning a SIBLING leaf and a disjoint node stripe, every event
      allocating a burst of transients and resetting its leaf. Against
      the same workload with no regions, three runs on `-t4`: the tree
      does zero stock collections against six, same result, no
      quarantine, and ~6.5 vs ~8.0 ms. The sibling leaves are mutually
      isolated by declaration — the win the chain's total order cannot
      express.

## When the stages stand

As in the maturation plan: the work ends at the evidence, every stage
carries its measurements, and the packaging question stays the user's.
