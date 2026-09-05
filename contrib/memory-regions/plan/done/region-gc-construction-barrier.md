# Region GC — a construction-only barrier

The compiler emits the escape barrier at the fields of a fresh object in
`new`. It does so with the one barrier intrinsic it has,
`julia.write_barrier`, whose lowering emits the region guard and then the
generational check. Vanilla emits no barrier there for a boxed child,
because a fresh parent is young. So a `new` with boxed pointer children
pays the generational check that it does not need: `construct_two` costs
7.1 ns on vanilla and 8.2 ns on the branch with no window open, and the
flag test of the region guard is about 0.26 ns of that 1.0 ns. This plan
gives the compiler a second intrinsic that lowers to the region guard
alone, and uses it at construction.

The premise of the paragraph above was wrong, and the measurement after
the build showed it: the `construct_two` loop allocates three objects per
iteration, and the 1.0 ns is their allocation cost, not the barrier. The
intrinsic is built and stays, for the shape of the code it gives: a
constructor holds no generational barrier, as in vanilla. The Steps below
hold the numbers.

Branch `gc-regions-fixes`, worktree `julia-gc-fixes`, on top of the lazy
region state (`025b0e8557`) and the cost document (`06a511ed9d`). The fold
into the staged series carries it with the other commits of the branch.

## The design

- A second intrinsic, `julia.region_write_barrier(parent, children...)`,
  with the type and the attributes of `julia.write_barrier`
  (`src/codegen.cpp`). Codegen emits it through
  `emit_region_write_barrier(ctx, parent, ptrs)` in `src/cgutils.cpp`,
  which emits nothing when `JL_NO_REGION_STORE_BARRIER` is defined.
- `emit_new_struct` keeps the vanilla `need_wb` logic for `emit_setfield`.
  It collects the boxed pointer children as it stores them, and after the
  field loop it emits one region-only barrier call that names them all,
  with the fresh object as the parent. One call is one guard per object.
  (A first cut emitted one call per child; LLVM's PRE already merged the
  two flag loads of `Two(c, d)` on the disarmed path, but the IR carried a
  second guard block in the armed path. The one-call form is the shape the
  lowering was written for.)
- The late GC lowering collects calls to the new intrinsic with the write
  barriers and lowers them in `CleanupWriteBarriers`: the same early exit
  for a permanently rooted child, the region guard block, and no
  generational part. Under `JL_NO_REGION_STORE_BARRIER` the call is erased.
- Every pass that knows `write_barrier_func` treats the new intrinsic the
  same way: not a safepoint (`llvm-late-gc-lowering.cpp`), a use that does
  not escape and is removed with an elided allocation
  (`llvm-alloc-helpers.cpp`, `llvm-alloc-opt.cpp`), and a call that LICM
  hoists when its operands are loop invariant (`llvm-julia-licm.cpp`).
  `JuliaPassContext` gets the field `region_write_barrier_func`.

## What it does not do

The probe `region-gc-fresh-object-copies-probe.jl` on the binary before this plan shows two holes
in the barrier at a fresh object, both independent of this plan:

- a child that a struct stores inline is not seen at construction:
  `TwinHolder(Twin(c, c))` with `c` of region 6 quarantines nothing;
- a child that a fresh box copies from an unboxed value is not seen:
  `Any[Twin(c, c)]` with `c` of region 7 quarantines nothing.

Vanilla emits no barrier on either path, because the parent is young; the
branch adds none. The C side has the same shape in `jl_new_bits`, which
copies an inline aggregate with pointers into a fresh box. The region-only
barrier of this plan is the tool that closes the compiler-side holes at
the cost of one guard per tracked pointer, but the closing is a change of
the rule's coverage and needs its own audit of every fresh-object copy.
It goes into a plan of its own, `region-gc-fresh-object-copies.md`.

## Steps

- [x] The intrinsic in `codegen.cpp`, the emit function in `cgutils.cpp`,
      the field in `llvm-pass-helpers.{h,cpp}`.
- [x] `emit_new_struct`: vanilla `need_wb`, one region-only barrier call
      after the field loop with every boxed child.
- [x] `CleanupWriteBarriers`: the region-only lowering; the collect site
      and the not-a-safepoint list.
- [x] `llvm-alloc-opt.cpp` (three sites), `llvm-alloc-helpers.cpp`,
      `llvm-julia-licm.cpp` (two sites).
- [x] A test in `test/gc/regions_escape.jl`: the IR of a constructor with
      a boxed child holds a `region_wb` block and no `may_trigger_wb`
      block; a constructor with two boxed children holds one load of the
      flag and two cold calls; the IR of a `setfield!` holds both blocks.
      The existing `ctor_gap_quarantines_region5` keeps the semantic check.
- [x] Build (`nice -n 10 taskset -c 16-23 make -j8`, log, timeout). Trap
      found: `src/Makefile` lists header dependencies by hand, so a change
      to `llvm-pass-helpers.h` leaves `llvm-final-gc-lowering.o` and
      `llvm-late-gc-lowering-stock.o` stale (they reach the header through
      `llvm-gc-interface-passes.h`); the stale objects made the first
      compiled function spin in the module's symbol table. Name the two
      objects as make goals after such a change. A second trap: the
      system image does not depend on `libjulia-codegen`, so a codegen-only
      change leaves `sys.so` with the old code; remove the image files
      before the rebuild. Both are recorded in `HISTORY.md`.
- [x] Tests: `regions_escape.jl` (41 checks); the region sweep (60 of 60
      runs exit 0); the `gc` group (189 pass); `core` (7354041 pass,
      7 broken) and `Compiler/codegen` (288 pass, 1 broken) on cores 24-27
      under the memory cap. All on 2026-09-05.
- [x] Measure `construct_two` on core 29 with `bench/unit_costs.jl`. The
      result changed the plan's premise. Three pairs on the day (vanilla
      against regions with no window, ns per object): `construct_two`
      7.50 → 8.52, 7.73 → 8.35, 7.17 → 7.76; the test suites ran on other
      cores during the first two. The delta did not leave the spread of
      the row. A new row, `construct_shared`, makes the same `Two` from
      two shared children, one allocation per object: 3.82 → 4.05 and
      3.49 → 3.83, the same delta as `alloc_stock` (2.18 → 2.39,
      2.07 → 2.38) and a flag check. So the +1 ns of `construct_two` was
      the three allocations of the loop, and the barrier at construction
      was never more than the guard. The intrinsic still stands: the
      constructor holds no generational barrier, as in vanilla, and the
      documents attribute the cost correctly. The numbers are preliminary
      until the idle-machine rerun; `results/tables.py` lists the new row.
- [x] Documents: the devdoc's barrier paragraph and Files table,
      `MEASUREMENTS.md` prose of M2 (with the day's numbers, marked as
      such), `COST.md` (the dynamic-cost bullet, two construction rows,
      the construction bullet, the judgment, the one sentence, the
      switches table), `README.md` (the headline), `HISTORY.md` (the
      narrative, S4, the M2 entry, the Deferred item replaced by the
      fresh-object-copy holes, two build pitfalls), `bench/README.md`,
      and this plan.
- [x] Commit `19eee113c7` on `gc-regions-fixes` with explicit paths;
      pushed; the fold list in `region-gc-issues.md` names it; this plan
      moved to `done/`.
