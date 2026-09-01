# Optimise the region collector: reason, change, measure, repeat

The loop: a measurement names the cost, one change addresses it, the
matrix (or the narrowest run that shows the cost) decides keep or revert.
Baseline = the isolated-core matrix (tip `7e61bae39e`): recording-class
12.9 M events/s, p50 40 ns, p99-p99.99 1.36-1.41 us (the slice reset),
census 74 us max / p50 63 us; light 18.1 M, p50 31 ns (stock: 30 ns).

## The levers, by headline impact

1. **The census mark, 74 us max.** The law from the record: pause = 8 us
   + ~6 ns x live objects; 10 000 live records = memory latency through
   the table and the record headers. Candidates: software prefetch in the
   mark path; anything that avoids touching cold headers twice.
2. **The slice reset, ~1.3 us per 42-page slice (31 ns/page).** It is the
   entire p99-p99.9 band of the recording-class regions columns.
3. **The window cost, p50 40 vs the nursery's 30 ns at light garbage.**
   `region_set` does an atomic fetch_add on `region_windows_open` at
   every 0<->n transition - two lock-prefixed operations per event.

## Iterations

(one entry per iteration: measured -> reasoned -> changed -> remeasured ->
kept or reverted)

### Iteration 1 — the reset walks nothing

- **Measured.** The microbench reset is 1.3-3 ns/page hot; the same reset
  in situ is 1 916 ns mean (W=200, B=100: ~100 pages, metadata cold after
  170 KB of slice writes). Every one of the 50 000 boundary events is over
  800 ns (p50 2 024 ns); mid-slice p99.9 is 240 ns. The band is the reset.
- **Reasoned.** The per-page `gc_reset_page` at reset is redundant:
  `gc_add_page` resets a page when it claims it - the work was done twice,
  and the reset-time copy walks cold metadata at the boundary. The census
  sweep's wholesale path had the same double reset.
- **Changed.** The region keeps `pages_tail`, `n_pages`, `n_fresh`
  (maintained by the two claim sites and the sweep). `jl_gc_region_reset`
  clears the 49 pool cursors and parks the whole chain on the fresh list
  in O(1); the sweep parks wholesale pages without resetting them. The
  invariant, stated at the field: a fresh page's metadata is stale, the
  claim resets it.
- **Remeasured.** Batteries ALL PASS, checksums correct. The reset in
  situ: 1 916 -> 21 ns mean; boundary events p50 2 024 -> 120 ns, over
  800 ns 50 000 -> 0. Recording-class no census: p99 1.97 us -> 110 ns,
  p99.9 140 ns, p99.99 331 ns, throughput 11.5 -> 15.4 M events/s (the
  instrumented driver). Light census: p99 41 ns, p99.9 70 ns, p99.99
  110 ns; the census pause unchanged (62 us), as expected. KEPT.

### Iteration 2 — prefetch the mark's next header

- **Measured.** The census pause is 62 us of which mark 58 us; the phase
  law is ~6 ns per live object. The live records never enter the queue
  (the leaf shortcut marks them inline in gc_mark_objarray's scan), so
  the cost is one cold header line per record, at a random address, paid
  per element while the slots themselves stream.
- **Reasoned.** The scan knows the target of slot i+8 while it works on
  slot i; a prefetch of that header hides the latency behind eight
  elements of work. The pagetable walk of the scoped filter stays cold -
  header first, measure, then decide.
- **Changed.** gc_mark_objarray prefetches jl_astaggedvalue(slot[+8])
  when non-NULL. Unconditional: the stock mark shares the loop, so the
  stock column is measured too.
- **Remeasured.** Mark 58.4 -> 60.9 us, pause p50 62 -> 68 us: the
  prefetch pays instructions and hides nothing. The records sit in
  allocation order, so their headers already stream under the hardware
  prefetcher; the dependent cold chain is the pagetable walk to
  page_metadata plus the pool-meta update, untouched by a header
  prefetch. REVERTED.

### Iteration 3 — cache the last page's metadata in the scoped filter

- **Reasoned.** ~85 records share a page, and neighboring table slots
  hold records allocated together, so the scoped filter resolves the
  same page_metadata over and over through the pagetable. A one-entry
  cache of (page data, metadata) in the filter - reset at census entry,
  single mutator by contract - skips the walk for most of the live set.
- **Changed.** gc_try_claim_and_push's scoped branch consults the cache
  before the pagetable; the census entries reset it.
- **Remeasured.** Mark 58.4 -> 58.0 us, pause p50 62 -> 62 us: no change.
  The pagetable walk is not the bottleneck either. REVERTED (a change
  that buys nothing goes).

### Iteration 4 — non-atomic marking under the census contract

- **Reasoned.** After the headers stream (iteration 2) and the walk is
  cached (iteration 3), what is left per live record is the marking
  itself: gc_try_setmark_tag is an atomic header RMW - needed when many
  threads mark, not under the census's single-mutator contract - and the
  pool-meta update may carry more. ~6 ns per record over 10 000 records
  is the price of lock-prefixed RMWs.
- **Changed.** The atomic is jl_atomic_exchange_relaxed in
  gc_try_setmark_tag, guarded by the code's own comment: two racing
  markers must not both claim an object. One mutator, no race:
  gc_scoped_setmark does a load, a test, and a store, and the scoped
  branch's three sites (task record, leaf, queue) use it.
- **Remeasured.** Mark 58 -> 32-34 us, pause p50 62 -> 37-39 us, pause
  max 73 -> 49-51 us; a census run's largest event 51 us. Batteries ALL
  PASS, checksums correct. KEPT. The exchange was the ~6 ns; the scoped
  mark now costs ~2.4 ns per live object.

### The matrix after iteration 1 (kept logs)

Recording-class: 15.66 M events/s (stock 7.1), p50 40 ns, p99 70 ns,
p99.9 80 ns (census) / 230 ns (no census), p99.99 181 / 391 ns, max
74.8 us (census) / 16.1 us; light: 18.1-18.3 M, p99 41 ns, p99.9 60 /
80 ns, p99.99 121 / 331 ns. The regions now beat the stock collector on
every row at recording-class; at light garbage the stock keeps 1 ns of
median (30 vs 31).

## Where the loop stops, and why

Four iterations: two kept (the O(1) reset, the non-atomic census mark),
two measured as nothing and reverted (the header prefetch, the
pagetable-walk cache). After them the matrix reads: recording-class
15.6 M events/s (stock 7.2), every percentile won, max 53 us = the
census at p50 36 us; light 18.2 M, the stock nursery keeping 1 ns of
median. What remains is near the floor: the mark's 32 us is ~3 ns per
live object (about two cache lines each under the hardware prefetcher),
the sweep 4-7 us, the window pair 5.2 ns, the reset 21 ns. The next
visible lever would change the model, not the runtime (an explicit free
for single-owner slots would remove the census's reason); it is not
taken.
