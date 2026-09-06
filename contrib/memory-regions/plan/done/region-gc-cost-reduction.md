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

- [x] Build A: `JL_NO_REGION_ALLOC`. At 30 threads it gives 1.04
      [1.02, 1.06] where the whole build gives 1.07 [1.06, 1.09], and the
      mark falls from 1.08 to 1.03. **The census filter is the largest
      piece, about 3 points.**
- [x] Build B: vanilla with 8 bytes more per page metadata, which is the
      whole growth the region branch causes. 0.996 [0.971, 1.04] at 30
      threads. **The page metadata costs nothing.**
- [x] Build C: vanilla with 608 bytes more per thread heap. 1.02
      [0.999, 1.03] at 30 threads. **A small piece, about 2 points, and the
      interval touches 1.00, so the evidence is weak.**
- [x] The whole build measured again in the same probe conditions, so the
      four rows compare: 1.07 [1.06, 1.09] at 30 threads, which reproduces
      the 32-thread row of M13 in a different machine state.
- [x] The attribution is in `HISTORY.md`. About 3 points for the filter,
      about 2 for the thread heap, and about 2 that no probe attributes:
      the three brackets of a collection, the region test of the page
      sweep, and the shape of the compiled mark loops.

## Step 1 — The page metadata: dropped

Step 0 killed this candidate before a line of it was written. Eight bytes
more per page metadata move no width: 0.996 [0.971, 1.04] at 30 threads.
Moving the page chain out of `jl_gc_pagemeta_t` would buy nothing on this
row, and it would touch the page bookkeeping of every region. The 8 bytes
stay.

## Step 1b — The census filter, out of the loop the stock path runs

This is what Step 0 named. The filter is not expensive to read: the mark
loops load it once per object or per array and pass it in a register, and
its branch is `__unlikely`. What it costs is that the loops carry a runtime
parameter the compiler cannot fold, and `JL_NO_REGION_ALLOC` shows what the
folding is worth - 3 points at 30 threads, and 5 points of the mark.

The change: two instantiations of the mark loops, one with the filter folded
to 0 and one with it, chosen once per collection by a flag that says whether
any region was ever used. A program that never opens a window then runs the
loop vanilla runs.

**Done, and rejected by its own measurement.** The loops were specialized:
one body, two instantiations, the stock entries passing the literal 0, the
census keeping its own. Every region script passed on the build, and the
disassembly showed the fold worked - the hot mark functions no longer load
`jl_gc_region_census_target`. The result at 30 threads was 1.07 [1.05, 1.09]
against 1.06 [1.05, 1.07] for a plain rebuild of the same source: no change,
and 11 KB more text. Reverted.

The reason is a compiler transformation the plan did not account for. A
branch on a value written before a loop and read inside it is
loop-invariant, and the compiler unswitches it: it hoists the test and
duplicates the loop, which is what the hand specialization does. The filter
is read once per object into a register, so the transformation had already
happened.

- [x] The specialization, built, tested, measured, reverted.
- [x] The control the earlier probes lacked: the flat tip built again from
      the same source. Its text is identical to the byte, so it measures the
      run-to-run variation alone: 1.06 [1.05, 1.07] at 30 threads. **The
      noise floor of this row is about one point**, which puts
      `JL_NO_REGION_ALLOC` two points from it at most, with touching
      intervals. The census filter is not established as a cause.

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

## Step 2b — The region state behind one pointer

This is what the attribution names, and it is a move, not a removal. The
thread heap carries 608 bytes of region state: 64 pointers to the per-region
states, the live and has-child masks, and the child counts. They sit inside
`jl_thread_heap_t`, so every field of the stock collector after them moves,
and the structures a collection walks change their cache lines. Vanilla
padded by 608 bytes alone costs 1.02 [0.999, 1.03] at 30 threads, and a
build with every piece of region code compiled out still costs
1.05 [1.02, 1.08]: the code is not the cost, the layout is.

The change: one pointer in `jl_thread_heap_t` to a block that holds the
region table, the masks and the counts, allocated when the heap first uses a
region. `jl_thread_heap_t` then grows by eight bytes, every stock field
keeps its offset, and the region paths pay one indirection - on the paths
that run only when a program uses a region.

**Done, and rejected: it made the row worse.** The table moved behind one
pointer, with an accessor for every read and a lazy allocation at the first
region; the masks and the counts stayed, so the tree bookkeeping did not
move. Every region script passed. The row went to 1.09 [1.06, 1.10] at 30
threads against a control of 1.06 [1.05, 1.07], and the allocation fast path
gained two instructions. Reverted.

Two facts came out of it and they close this line of work:

- The region fields are **appended** to `jl_thread_heap_t`, so every field of
  the stock collector already keeps its vanilla offset. The padding probe
  reproduces that layout exactly and costs 1.02, where the region build costs
  1.06.
- The build with both defines off costs 1.05, so the difference is not the
  store barrier, not the region allocation path and not the census filter.

What is left is the collector's own region code, which no define removes and
the profile counted as about 15 instructions per marked object: the corpse
check of `gc_setmark_pool` (one test per marked object), the census
parameter of the mark tree (one test per slot), the region test of the page
sweep (one per page), and the three brackets of a collection. Each is worth
about a point, which is the resolution of this measurement, and the one that
was removed by hand moved nothing outside the noise.

- [x] Built, tested, measured, reverted, recorded.

## Step 1c — Profile the collection: done

Four A/B builds and a control leave most of the six to seven points
unattributed. A ratio between two binaries cannot say which instructions
cost the time, and every further pair costs an hour of builds for one
number. The next instrument is a profile.

- [x] `perf stat`: +5.7 % instructions, +5.3 % cycles, the same instructions
      per cycle. The collection executes more, it does not stall more.
- [x] `perf record`: every extra cycle is inside the collector, in the mark
      path, and it is about 15 instructions per marked object where the
      source adds two branches.
- [x] The build with both defines off, which removes every piece of region
      code: 1.05 [1.02, 1.08] at 30 threads against a control of 1.06
      [1.05, 1.07]. **The code is not the cost.** Step 2b follows from it.

## Step 4 — The reserve, chosen by Step 0

Only if the attribution names them:

- [ ] **The unattributed two points.** The three brackets of a collection,
      the region test of the page sweep, and the shape of the compiled mark
      loops. A probe that stubs the three brackets costs one build and
      answers the first of them.
- [ ] **The thread heap, smaller.** Step 0 gives it 1.02 [0.999, 1.03] at
      30 threads, so it is worth about 2 points and the evidence is weak.
      The region table is 64 pointers, 512 of the 608 bytes. Before any
      change, measure the padding probe again with 20 rounds: if the
      interval still touches 1.00, the candidate is not worth a change to
      the thread heap of every program.

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

## Where this leaves the cost

Four candidates were measured and none was accepted:

| Candidate | Result |
| --- | --- |
| The page metadata, 8 bytes back | Free by measurement; dropped before it was written |
| The census filter, specialized out of the stock loop | No change, +11 KB of text; reverted |
| The region state behind one pointer | Three points worse; reverted |
| The thread heap's size | Explains 1.02 of 1.06, and the fields already keep their offsets |

The cost of a parallel collection with the region runtime unused is
therefore the sum of several small checks inside the collector, none of them
removable without giving up a diagnostic or a mechanism, and each of them at
or below the resolution of this measurement.

The user chose the first of the two options: **accept and document**.
`COST.md` states the number, its attribution over six probe builds, and the
four candidates that were built and rejected. An upstream reviewer gets the
measurement and the reasoning behind it.

The second option stays open for the day a reviewer pushes on the number: a
microbenchmark that marks one fixed object graph in one process, with the
same binary marking with and without a single check, resolves one percent
instead of two. Only with that instrument is it worth removing the corpse
check or the census parameter, because only then can the win be seen. Each
removal costs a diagnostic or a mechanism, so each needs its own decision.

## Acceptance

- The attribution of the 7 % is written down, with the measurement that
  supports it.
- Every accepted change has a measured win whose interval excludes zero, and
  a gate that is green.
- Every rejected change is recorded with the number that rejected it.
- No property of the list "What may not change" is different at the end than
  at the start.
