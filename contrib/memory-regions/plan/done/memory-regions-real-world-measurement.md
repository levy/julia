# The real-world configuration of the regions, measured for latency

**Goal.** The README's headline tail table is the reset-per-event model, and
nobody resets per event. A real loop opens one window per slice of B events,
resets once per slice, and calls the cooperative census at a boundary it
owns. That configuration has throughput numbers and census pauses in the
record, but no per-event latency distribution against the stock collector.
Measure it - p50, p99, p99.9, max, and events/s - with one handler under
both collectors, and put the table at the top of the README with its
provenance; say in the tail table that a per-event reset is the one-Bool
comparison, not the configuration anyone runs.

## Steps

- [x] `stage5_scoped.jl`: a `real` variant - one Event window per B events,
      the kept record allocated in the Simulation region (turnover), the
      cooperative census every `every` events at a slice boundary - and
      per-event wall time for `real`, `auto`, `batch`, `autopool`: p50, p99,
      p99.9, p99.99, max, the count over 100 us
- [x] runs: 5 M events, K = 10 000 live records, census every 100 000;
      W = 3 (~100 B/event) with B = 1000, and W = 200 (~1.7 KB/event) with
      B = 100 - the cache optima of the throughput matrix - `batch` against
      `autopool`; logs kept as `logs/realworld_*.log`
- [x] README: the table and the sentence at the top; the tail table's caveat
- [x] MEASUREMENTS.md: the section with the readings; `run.sh` runs the pairs
- [x] one commit on `memory-regions`, pushed

## Decisions

- `batch` updates records in place and never needs a census; the pair a
  simulator cares about is `real` (turnover + census) against `auto` (the
  same handler under the stock collector's heuristics). Both record every
  event's wall time, the slice reset and the census included in the event
  at whose boundary they run.
- `every = 0` means no census, so the census's share of the distribution
  shows by its absence between two `real` runs.
- OS preemption: the machine allows `taskset` but no realtime priority
  (`ulimit -r` is 0, `chrt` refused). The script counts involuntary context
  switches from `/proc/self/status` across the measured loop; the matrix
  runs pinned to one core and keeps a run only with zero switches (up to
  six tries), so a kept run's maximum is the mechanism's own.
- "Keep only a zero-switch run" failed on this machine: an idle core still
  took three to five preemptions per 0.4 s run, twenty tries. The method is
  now exact attribution: every variant samples the thread's involuntary
  switch counter (`getrusage(RUSAGE_THREAD)`, ~0.3 us) every 10 000 events,
  marks the blocks that took one, and prints the maximum over the other
  blocks beside the raw maximum; five runs per configuration, the one with
  the fewest switches kept. What no unprivileged method removes is interrupt
  time - it steals the core without a context switch - and the record says
  so: one 163 us census sat in a clean block.
- "No census" is a regions-only configuration (the user's point): the slice
  reset already reclaims every transient, so only the replaced records pile
  up on region pages - memory traded for the census pause; the stock
  collector has no such option, its nursery collection reclaims everything
  and can not be switched off. The table gets a memory-at-end row and the
  sentence.
- Done 2026-09-01. The ~327 us maxima of the no-census runs were located:
  9-21 events per run above 200 us, at arbitrary indices, at no slice or
  census boundary, none a context switch, only where the heap grows -
  read as the page-block claims of a growing heap; the census runs recycle
  their pages and show none. THP is `madvise` with no huge pages in use,
  so a huge-page fault it is not. `gc_live_bytes` is meaningless under the
  regions (the stock accounting never subtracts what a reset frees); the
  memory row is peak RSS.
- Addendum 2026-09-01: the "page-block claims" reading was replaced by
  measurement. The no-census stalls are ~330 us of continuous kernel CPU in
  the fault path of a growing heap (timestamped perf: 12-17 consecutive
  kernel samples), once per ~6.6 MB of growth; no involuntary switch, no
  syscall over 100 us, no extra faults, no cgroup pressure; gone once a
  census recycles the working set. The kernel path stays unnamed without
  root. Second finding: a deferred jl_gc_collect re-arms allocd at ~0, so
  every allocation enters it while the collector is disabled (~20 ns each).
- Named 2026-09-01 with the function-graph tracer (tracefs opened by the
  user): the ~327 us no-census stall is `rmqueue_bulk` refilling the per-CPU
  free list with 1008 pages (batch 63 scaled x16 by the kernel's adaptive
  refill), 2016 zone-counter updates under the zone lock with IRQs off,
  300-530 us, inside an ordinary `wp_page_copy` fault of a fresh page; once
  per ~4 MB of new pages. IRQs off is why perf saw gaps and why no process
  counter moved. Dead ends on the way, each measured: context switches,
  syscalls, extra faults, cgroup pressure, THP, NUMA, KSM, page migration,
  the mmap lock. Knob: vm.percpu_pagelist_high_fraction (root); runtime
  cure: prefault page blocks.
