# The deferred collection must re-arm the counter with a real interval

**Goal.** Measured on the memory-regions branch: with the stock collector
disabled - every region run - a deferred `jl_gc_collect` re-arms the thread's
allocation counter at ~0 (`gc_num.interval` is ~0 on Julia 1.13), so the very
next allocation enters `jl_gc_collect` again: ~20 ns per allocation, 10 % of a
region run's samples, and most of the 20 ns by which the region median trails
the stock one at light garbage. The region guard's deferral inherits it. Fix
the re-arm, in both deferral branches, and measure.

## Steps

- [x] read what re-arms the counter after a real collection; pick the value
- [x] one helper for both deferral branches; rebuild
- [x] measure: `ijl_gc_collect` 10.2 % -> 0.01 % of samples; light-garbage
      `real` 13.5 -> 17.1 M events/s, p50 50 -> 40 ns, p99 61 -> 41 ns; both
      batteries ALL PASS
- [x] README and MEASUREMENTS say what changed; one commit on the branch

## Decisions

- The first reading was wrong: `gc_num.interval` is 45.9 MB, set at init
  and never changed, and the probe's "+5616" was `jl_gc_num`'s REPORTED
  allocd (counter + interval). The real trigger on Julia 1.13 is
  `maybe_collect`: `heap_size >= heap_target`. A deferral re-arms only the
  thread counter, so a heap above its target re-enters on every allocation.
- Fix: `gc_defer_collection()` for both branches (the stock disable branch
  and the region guard) re-arms `heap_target = heap_size + grant`, grant =
  max(heap_size/20, default_collect_interval/8) - the same minimum a real
  collection grants. Consequence, stated in the docs: the collection a
  window owes runs when that allowance is spent, not on the first
  allocation after the window.
- The first edit silently did nothing: its anchor missed a `static_assert`
  line in the stock branch, and the unchanged measurement (10.17 %) said so
  before anything was believed.
- The real-world matrix, remeasured on the fixed runtime: recording-class
  garbage 12.5 M events/s (was 10.6) against the stock 7.2 M, median 40 ns
  (was 60) against 50, max 75 us (the census) against 4.0 ms, 0 against 302
  events over 100 us; light garbage 17.2 M (was 13.5) against 16.6, median
  40 (was 50) against 30, p99.99 181 against 741 ns, max 73 us against
  4.0 ms. The regions now win every row at recording-class garbage but the
  slice-reset band, and every row but the median at light garbage.
