# Chain residuals — close out the maturation branch

The maturation plan is done and its evidence stands, but the record
carries residual items that live only in prose (MATURATION.md "Where it
stands", the stage-1 facts, one open measurement question). This plan
turns each into a closed item with a test or an explicit decision, so
the chain baseline is clean before the tree work starts in its own
worktree (`plan/pending/region-tree.md`).

## Small — measurements and flags

- [x] **Explain the many_refs allocation gain.** Closed 2026-09-03.
      Re-measured warmed, three interleaves: vanilla ~334-383 ms, both
      region binaries ~170-202 ms — real and stable. Ruled out in
      order: per-phase page faults (equal, /proc/self/stat), memory
      syscalls (equal, strace), the emitted loop code (byte-identical
      native), the page-reuse layout (equal transition counts). A
      bisect over the 30 base commits landed on 13989e9665 ("the
      guards"): vanilla's maybe_collect re-enters jl_gc_collect on
      every allocation while the collector is disabled and the heap
      sits above its target (~20 ns each); gc_defer_collection()
      re-arms the target, so the disabled loop allocates at full
      speed. MATURATION.md carries the mechanism.
- [x] **The allocation-indirection compile-out.** Done 2026-09-03. Mirror
      `JL_NO_REGION_STORE_BARRIER`: with `JL_NO_REGION_ALLOC` defined,
      the pool address computes exactly as vanilla (`ptls + offset`)
      and `jl_gc_region_set` refuses with -1, because regions cannot
      allocate in that build. `jl_gc_region_reserve` stays functional:
      the prefault is useful without regions. Acceptance: the flag
      build matches the vanilla allocation path on the alloc probe and
      refuses `region_set`; the normal build is unchanged. Verified:
      the flag build returns -1 from `region_set(1)`, allocates and
      collects normally, and still allocates fast under
      `GC.enable(false)` (~180 ms — more proof the gain is the
      deferral re-arm, not the indirection); the restored build passes
      stockgc_test and escape_test.
- [x] **The multithreaded sweep.** Done 2026-09-03. `-t4`, three
      interleaved runs: mergesort_parallel 0.97,
      mm_divide_and_conquer 1.06, issue-52937 at parity within its
      ±15 % spread (medians 12.0 against 11.8 s over eight runs — the
      first reading of 1.12 was scheduler variance on shared cores).
      objarray and both binary_tree benches abort on BOTH binaries
      under the harness's memory-pressure callback, as do serial
      linked/list (and TimeZones needs its package offline) — an
      environmental exclusion, equal on both sides. MATURATION.md
      carries the table.

## Medium — the armed fast path

- [x] **The armed barrier is fast enough with the child-first reorder;
      inline IR rejected.** Done 2026-09-03. The cold call
      `jl_gc_region_wb` now tests the child's region first and returns
      after one page-map walk for a region-0 child (almost every store
      in ordinary code). Armed store microbench 1.94 -> 1.49 ns; HIL
      kernel p50 61 ns armed = 61 ns disarmed. The target ("within
      ~2 ns of disarmed") is met, so the inline IR tag-compare is NOT
      built: it would replicate the pagetable walk inline (large IR,
      the non-integral-pointer hazard) for no measurable gain over the
      cold call, which the child-0 fast path already makes cheap. The
      old ~9 ns was p50 31 -> 40 on a quiet machine; the reorder closes
      even that.

## Medium — the two stage-1 gaps, decided

- [x] **The construction-store gap — FIXED (approach B).** Found
      2026-09-03 to be worse than "elision": a
      constructor store of an already-boxed child skips the region
      barrier unconditionally, not just across a window. In the heap
      path of `emit_new_struct` (cgutils.cpp), a pointer field is
      stored with `need_wb = !rhs.isboxed`; for an already-boxed child
      — a pre-existing object of a younger region — `need_wb` is
      false, so no write barrier is emitted, so the region barrier
      that late-lowering bolts onto the generational one never fires.
      Demonstrated: a region-0 object constructed with a region-1
      child leaves quarantined(1)=false, region_check(1)=0 (the audit
      trusts the barrier and does not walk region-0 heap objects), and
      after region_reset(1) plus churn the surviving field reads
      garbage — silent corruption, the one thing the barrier promises
      never happens.

      The fix restores the guarantee and is the user's call on
      approach:
      - **(A) region-only construction barrier.** A new
        `julia.region_write_barrier` intrinsic emitted for boxed
        pointer fields at construction, lowered to the flag-guarded
        region call only (no generational part). Zero cost when
        disarmed past one predicted branch per boxed pointer field at
        construction; zero under JL_NO_REGION_STORE_BARRIER. Complete
        soundness. Cost: codegen + late-lowering + intrinsic plumbing.
      - **(B) widen need_wb.** Set need_wb=true for boxed pointer
        fields when the barrier is compiled in. One line, but emits
        the full generational barrier body at every such construction
        even when regions are unused at runtime — a small always-on
        cost, measurable on construction-heavy code.
      - **(C) audit + discipline.** Extend region_check to also walk
        older-region heap objects for references into region n (a
        debug/CI full scan, zero production cost), and document
        construction of a younger child into an older object as a
        discipline violation. Does NOT restore the production "never
        corrupt" guarantee.
      Recommendation: (A). Acceptance: the ctor_corrupt demonstrator
      quarantines after the change; the disarmed construction
      microbench unmoved; escape_test still green.

      LANDED (B) 2026-09-03, commit 0121cb9049: need_wb is set for a
      boxed pointer child at construction when the barrier is compiled
      in. ctor_gap_demo now quarantines and the field survives the
      reset; all seven suites pass. Measured cost, isolated core, worst
      case (two boxed pointer fields, tight loop): vanilla 42.4 ->
      mature 43.8 ns/obj, +1.4 ns (+3.2 %), gone under
      JL_NO_REGION_STORE_BARRIER. OPEN DECISION: this is a real
      default-build cost on construction, so it dents the zero-cost
      headline. (A) — a region-only construction intrinsic — would cut
      it to the bare flag check (~0.7 ns; the arming check is
      irreducible while the barrier is compiled in). DECIDED
      2026-09-03: keep (B). The correctness fix ships; the cost is
      recorded in MATURATION.md, and the zero-cost intrinsic (A) stays
      the noted follow-up if construction-dense code proves to need it.
- [x] **The blocking-`take!` escape.** Decided 2026-09-03: it stays a
      documented discipline rule (do not block inside a window).
      Parking the window across every yield pins tasks and complicates
      the scheduler for a pattern a disciplined event loop does not
      use. Recorded in DESIGN.md's "discipline rules the barrier does
      not remove" section.

## Large — defined refusals for the declined subsystems

Full support for these is future work, not this plan. This plan only
replaces silence with a defined, tested refusal — the same move the
finalizer story made (the STW census refuses with -6).

Measured 2026-09-03 with a demonstrator: an `IdDict` key from a region
and `serialize` of a region object BOTH already quarantine the region —
the store into the dict's `SimpleVector` slots and into the serializer's
backref table are ordinary boxed-child stores, so the barrier fires.
So the id dict and serialization are already defined behavior (leak, not
corruption). This tier now only sharpens that into a clear message and a
test, and covers the two that are not yet defined.

- [x] **Weak references**: DONE 2026-09-03, commit 72a8ba92e2.
      `jl_gc_new_weakref_th` refuses a WeakRef to a region object
      (arming-flag guarded, zero cost when unused); tested in
      subsystem_refusal_test.jl.
- [x] **The id dict**: already quarantines (measured, tested in
      subsystem_refusal_test.jl). The generic REGION-ESCAPE message is
      kept: sharpening it to name the dict's storage is cosmetic and
      not worth a branch in the cold path.
- [x] **Serialization**: DECIDED 2026-09-03 to keep the quarantine
      (already defined behavior, tested), not an explicit stdlib
      refusal. Editing and re-caching stdlib Serialization for a
      marginally clearer error is not worth the surface; the quarantine
      is sound and documented in DESIGN.md as a discipline rule.
- [x] **Precompile images**: DONE 2026-09-03, commit 0121cb9049.
      `jl_create_system_image` refuses with `jl_error` when
      `jl_gc_region_current() != 0`. In-situ test is awkward because
      `Base.compilecache` writes the image in a forked worker where the
      parent's window is not open — the guard sits at the right choke
      point but a process test cannot open a window in the worker; a
      direct-call test is the follow-up.

## When this stands

Every line above ends in a commit with its test or its recorded
decision; MATURATION.md's "Where it stands" then lists nothing that
this plan still leaves open, and the tree worktree starts from a chain
baseline with no loose ends.
