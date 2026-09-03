# Chain residuals — close out the maturation branch

The maturation plan is done and its evidence stands, but the record
carries residual items that live only in prose (MATURATION.md "Where it
stands", the stage-1 facts, one open measurement question). This plan
turns each into a closed item with a test or an explicit decision, so
the chain baseline is clean before the tree work starts in its own
worktree (`plan/pending/region-tree.md`).

## Small — measurements and flags

- [ ] **Explain the many_refs allocation gain.** The allocation phase
      of the 35 M-object shape measured faster on the region binaries
      (155 against 333 ms in one warmed probe), and MATURATION.md
      honestly calls the gain unexplained. Re-measure warmed, repeated,
      interleaved, on the quiet isolated core; profile the phase on
      both binaries; either name the mechanism in MATURATION.md or
      correct the claim if the gap was machine load.
- [ ] **The allocation-indirection compile-out.** Mirror
      `JL_NO_REGION_STORE_BARRIER`: with `JL_NO_REGION_ALLOC` defined,
      the pool address computes exactly as vanilla (`ptls + offset`)
      and `jl_gc_region_set` refuses with -1, because regions cannot
      allocate in that build. `jl_gc_region_reserve` stays functional:
      the prefault is useful without regions. Acceptance: the flag
      build matches the vanilla allocation path on the alloc probe and
      refuses `region_set`; the normal build is unchanged.
- [ ] **The multithreaded sweep.** The cost table is the serial set;
      run the GCBenchmarks multithreaded set A/B (`-t4`) and add the
      table to MATURATION.md.

## Medium — the armed fast path

- [ ] **Inline IR tag-compares for the armed barrier.** The armed
      legal-store path costs ~9 ns because every store pays the cold
      call `jl_gc_region_wb`. Emit the two page-tag loads and the
      compare inline in the write-barrier lowering, and keep the call
      only for the violation path. Target: the armed light-loop median
      within ~2 ns of disarmed. Acceptance: the light-loop measurement,
      plus escape_test unchanged (every quarantine still fires).

## Medium — the two stage-1 gaps, decided

- [ ] **The fresh-store elision gap.** The compiler elides the write
      barrier for stores into freshly allocated objects; a window
      opened between the allocation and the store lets a region store
      skip the armed barrier. Close it or bound it: either
      `region_set` acts as an allocation boundary for elision, or the
      lowering keeps the region branch on elided stores when the flag
      is armed. Acceptance: a test that demonstrates the miss today
      and quarantines after the change, plus the light-loop median
      unmoved while disarmed.
- [ ] **The blocking-`take!` escape.** A blocking `take!` inside a
      window escapes through wait-queue growth. Decide and record:
      either this stays a documented discipline rule (do not block
      inside a window) with the demonstrating test kept as expected
      output, or the runtime parks the window across the wait. The
      item closes with the decision written into DESIGN.md, not
      necessarily with code.

## Large — defined refusals for the declined subsystems

Full support for these is future work, not this plan. This plan only
replaces silence with a defined, tested refusal — the same move the
finalizer story made (the STW census refuses with -6).

- [ ] **Weak references**: creating a `WeakRef` to a region object
      refuses or quarantines, with a test.
- [ ] **The id dict**: an `IdDict` key in a region either works via
      the existing hash path or refuses; decide, test.
- [ ] **Serialization**: serializing a region object refuses with a
      clear error, with a test.
- [ ] **Precompile images**: a region open during precompile output
      refuses, with a test.

## When this stands

Every line above ends in a commit with its test or its recorded
decision; MATURATION.md's "Where it stands" then lists nothing that
this plan still leaves open, and the tree worktree starts from a chain
baseline with no loose ends.
