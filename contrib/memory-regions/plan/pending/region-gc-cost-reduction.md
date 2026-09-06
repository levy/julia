# Region GC — cut the cost of the runtime a program does not use

The measurement of 2026-09-06 gives the cost of the region runtime to a
program that never opens a window. One number is large enough to decide a
review: **a full collection on 32 threads costs 7 % more** [3 %, 8 %], where
the same collection on one thread costs 2 % more. The others are small and
known: +0.085 ns on a pointer store, +0.283 ns on a pool allocation, +3.4 %
on the text of the system image, +1.7 % on a serial mark.

This plan tries to cut them. It changes nothing that a test protects. Every
candidate is measured before it is accepted, and a candidate that does not
pay is reverted, not kept.

## What may not change

These are the properties that tests, not opinions, hold up. A change that
weakens one is out of this plan, whatever it buys:

- the escape barrier at every managed pointer store, and at every copy of an
  inline value with pointers into a fresh object;
- the root check of the checked reset, and its stop-the-world;
- the permanent, process-wide quarantine after an escape;
- the borrow of the container's region for a replacement buffer;
- the bounded finalizer phases of the reset, and every refusal code;
- the refusal of a window on a quarantined region, and the tree's live-child
  rules.

A trade-off inside those bounds is allowed. A trade-off that moves one of
them is not.

## How a Julia developer will read this

The reviewer of an upstream pull request asks five questions. The plan
answers each one with a measurement, not with prose:

1. *What does my program pay when it never uses the feature?* M1, M2, M13.
2. *Does the allocation fast path get slower?* M2, `alloc_stock`, with an
   interval.
3. *Does the collector get slower on my 32-core machine?* M13, the row this
   plan exists for.
4. *Does the system image grow?* `size` on `sys.so` and on
   `libjulia-internal`.
5. *Is the stock path still the stock path?* The disassembly of the loops a
   change touches, and the stock-path table of `HISTORY.md`.

## The gate every candidate passes

A candidate is accepted only when all of this holds:

- **Correctness.** The eleven region scripts pass at every harness
  configuration (threads 1, 2, 4, each with 0 and 1 interactive thread), the
  `gc` group has 0 fail and 0 error, and `core threads misc` is unchanged.
- **The win is real.** M13 and M2 run before and after, paired rounds, and
  the interval of the improvement excludes zero. A median that moves inside
  its interval is not a win.
- **Nothing else moved.** M1, M5, M9 and M14 stay inside their intervals.
  M9 matters most: it is the bound on a region that churns inside one
  window.
- **The stock path is what it was.** Where a step claims "no change for a
  program without regions", the claim is checked with `size` and with the
  disassembly of the changed loop, not asserted.
- **It is revertible.** Each candidate is one commit on top of the flat
  tree. A candidate that does not pay is reverted the same day, and the
  measurement goes into `HISTORY.md` as a finding.

## Step 0 — Attribute the 7 %

Nothing is changed before this step answers. Three things can carry the cost
of the unused runtime through a parallel collection:

- **the census filter**, `jl_gc_region_census_target`, which every marking
  thread reads;
- **the page metadata**, 8 bytes larger per 16 KB page, which every marking
  and sweeping thread touches;
- **the thread heap**, 608 bytes larger, which the three brackets of a
  collection walk once per heap.

The filter is already the least likely: the mark loops load it once per
object or per array and pass it in a register, and the branch is
`__unlikely`, so a slot costs a register compare. The measurement decides,
not the reading.

- [ ] Build A: `JL_NO_REGION_ALLOC`. It folds the census filter to the
      constant 0 and takes the region pools out. Run M13 against vanilla.
- [ ] Build B: the page metadata back to 40 bytes, with nothing else
      changed (`region_next` removed, the chain kept in a scratch array that
      only this build uses). It is a probe, not the fix. Run M13.
- [ ] Build C, only if A and B leave the cost standing: the thread heap
      region table reduced to one pointer. Run M13.
- [ ] Write the attribution into `HISTORY.md`, whatever it says. A cost with
      no cause found is a finding too.

## Step 1 — The page metadata, if Step 0 points at it

`region_n` is free: one byte that lands in padding vanilla already wastes.
The growth from 40 to 48 bytes is `region_next`, the intrusive chain of a
region's pages.

- [ ] Move the chain into `jl_gc_region_state_t`: an array of page pointers
      per region, with the same three roles the chain has today (the live
      pages, the tail, the fresh pages).
- [ ] Keep every property the chain gives: the claim appends in amortized
      constant time, the reset parks the whole set in constant time, the
      census walks the set with no lock while the world is stopped, and a
      page keeps its owner heap.
- [ ] `jl_gc_pagemeta_t` is byte-for-byte the vanilla struct again. Check
      with a `sizeof` probe and with `readelf`, and say so in `COST.md`.
- [ ] The gate. M13 is the row that must move; `regions_lifetime.jl`,
      `regions_census.jl` and `regions_many.jl` are the scripts that must
      not.

## Step 2 — Skip the guard where the child cannot be a region object

Every managed store of the system image carries the region guard, and that
is the 576 KB. A store whose child is a compile-time constant of the image -
a `Symbol`, a `DataType`, a `Module`, `nothing`, the value of a `const` -
can never be a region object: the image is region 0 for the life of the
process, so the check can only pass.

- [ ] Find the predicate the compiler already has for such a child (a
      literal pointer to an image object). Do not invent a new one.
- [ ] `emit_region_write_barrier` drops those children, and drops the call
      when every child is one.
- [ ] Measure the text of `sys.so` and of `libjulia-internal`, and M2's
      `store_disarmed`.
- [ ] The gate. `regions_stores.jl` and `regions_escape.jl` must pass
      unchanged: a store the compiler drops must be a store the runtime
      would have passed.

## Step 3 — One test fewer on the allocation path

`maybe_collect` reads `current_region` and branches, then compares the heap
size against the target. The census of the open region could ride on the
comparison that is already there: the slow path is where the choice between
a census and a collection already lives.

This step is the one with a semantic risk, so it comes last and it carries
the heaviest proof.

- [ ] Show first that the census still fires: a region's pages count in
      `heap_size`, so a window that grows crosses `heap_target` on its own.
      M9 is the measurement of that bound, and it must hold with the same
      shape.
- [ ] Show that no stock collection is lost: `core threads misc`, the `gc`
      group, and the collection counts of M5, M8 and M10 stay as they are.
- [ ] Measure M2's `alloc_stock`. If the interval of the improvement
      includes zero, revert the step: a semantic risk with no measured win
      is not a trade-off, it is a loss.

## Step 4 — The reserve, chosen by Step 0

Only if the attribution names them:

- [ ] **The mark loop, specialized.** Two instantiations of the hot loop,
      one without the filter, chosen once per collection by a flag that says
      whether any region was ever used. It costs text in
      `libjulia-internal`, which no Julia program pays for at run time, and
      it takes the filter out of the loop that a program without regions
      runs. Measure the text and M13.
- [ ] **The thread heap, smaller.** The region table is 64 pointers. A
      program that uses one region needs one entry; the table could be a
      pointer to a small map. Measure the heap struct with the `sizeof`
      probe and M13.

## Step 5 — Close

- [ ] Every accepted change is one commit on the flat tree, with its
      measurement in the message.
- [ ] `COST.md` takes the new numbers and says what each step bought. A step
      that bought nothing is named there too.
- [ ] `HISTORY.md` gains a row per accepted change in the stock-path table,
      and the attribution of Step 0.
- [ ] The fold: move the flat tag, take the stages again from the lowest one
      that changed, Check 1, Check 2 and Check 3, the `gc` group, `core
      threads misc`, and the documentation build.
- [ ] The pull request text takes the new cost paragraph.

## What this plan will not try

- **Copy the pool array at a window switch** to remove the `active_pools`
  indirection. It trades 0.283 ns per allocation for about 1.2 KB of copying
  per window pair, so it loses above roughly a hundred allocations per
  window, and it brings back the parked state that the design removed. The
  cost is robustness, and this plan does not spend that.
- **Move the barrier flag into the thread state.** One cache line at best,
  and the arming race needs a delicate argument that the process-wide flag
  already carries. The gain does not pay for the subtlety.
- **Weaken any check.** The barrier, the root scan, the quarantine and the
  refusals stay as they are. Their measured cost is small, and each one
  exists because a test found the fault it prevents.

## The budget

A candidate costs about three hours of machine time: two builds of about
20 minutes, M13 at 10 paired rounds (about an hour), M2 at 25 rounds (about
40 minutes), and the test scripts and groups (about 20 minutes). Step 0
alone is two or three builds and three M13 runs.

The machine states are the ones the measurement uses: the whole machine with
the isolated partition off for M13 and the test groups, and the partition on
for M2 and the latency rows (`tools/hil_isolation.sh`).

## Acceptance

- The attribution of the 7 % is written down, with the measurement that
  supports it.
- Every accepted change has a measured win whose interval excludes zero, and
  a gate that is green.
- Every rejected change is recorded with the number that rejected it.
- No property of the list "What may not change" is different at the end than
  at the start.
