# Memory regions: no page fault and no preemption inside the event loop

Branch `memory-regions` of levy/julia (worktree `julia-region`). The user's
direction (2026-09-01): "we should avoid the OS biting us, both in terms of
preemption and in terms of juggling with memory, this is for a HIL
simulation after all", then "do the prefault", and: the documents must
state that the measurement is of Julia and its collector under the best
case a HIL simulator can arrange, not of the OS, with the environment and
the exact steps, because "a measurement which cannot be reproduced is
worthless".

## The two ways the OS enters the loop

1. **Memory.** The runtime maps page blocks lazily and the first touch of
   every page takes a page fault; once per about 4 MB of new pages the
   kernel also refills the core's per-CPU free list under the zone lock
   with interrupts off (300-530 us, `rmqueue_bulk`, named by ftrace). The
   no-census region column paid that as its 334/350 us maximum. The
   driver's own latency vector was also first-touched inside the loop, in
   every column.
2. **Preemption.** No rtprio on this machine (`ulimit -r 0`), no isolated
   cores; the loop pins to one core and attributes preemption per
   10 000-event block by `getrusage(RUSAGE_THREAD)`.

## Steps

- [x] `jl_gc_region_reserve(bytes)` in `src/gc-pages.c`: maps whole
      blocks with `MAP_POPULATE` into the clean pool and sets a flag so
      every later block is populated at the claim too. `jl_gc_alloc_page`
      serves the clean pool first, so a loop whose heap fits the reserve
      maps and faults nothing. The region tag is set at the pool claim
      (`gc-stock.c:781`), so an untagged page can wait in the pool.
- [x] `region_reserve(bytes)` in `regions.jl`.
- [x] Driver `stage5_scoped.jl`: `ARGS[7]` = reserve in MB; `fill!(lat, 0)`
      before the loop; "page faults during the run" from `ru_minflt`.
- [x] Build, batteries (`stage3_safety.jl`, `v2_regression.jl`): ALL PASS.
- [x] First probe (no census, W=200, B=100, reserve 512 MB): page faults
      39 139 → 0, max 330 → 23 us (14 us over preemption-free blocks),
      p99.99 2.04 → 1.42 us, zero events over 100 us. Peak RSS counts the
      reserve (846 MB); the document must say so.
- [x] The matrix with a 512 MB reserve in every column, stock included
      (fair): recording-class faults 5 / 1 / 0, light 43 / 19 / 21 - not
      zero. `perf record -e page-faults -d` under `setarch -R` (same
      layout as a run that prints `/proc/self/maps`) placed all 41 light
      faults in the 64 MB block the runtime mapped at startup, in the
      first 8 ms of the loop, from JIT code: 4 KB pages inside GC pages
      the pools had claimed before the reserve existed, reached late.
      Pop order is not the cause (LIFO serves the reserve first).
- [x] Fix: the claim path records every block; the reserve populates the
      recorded blocks with `MADV_POPULATE_WRITE` (Linux 5.14+) before it
      maps its own. Rebuilt, batteries ALL PASS, light probe: 0 faults.
- [x] The matrix on that runtime, RESERVE=512 for every column: faults
      0 / 1 / 0 in both classes; no-census max 21 us (both classes), census
      max 75-76 us (the census), stock 3.8-4.0 ms; recording-class
      throughput 6.9 / 12.9 / 13.0 M, light 17.0 / 18.0 / 17.3 M.
- [x] `contrib/memory-regions/realworld.sh` committed; `run.sh` calls it.
- [x] Documents: the "What is measured is Julia and its collector, not the
      OS" paragraph, the "page faults inside the loop" row, "peak RSS, the
      512 MB reserve included", the reading, "What the census buys, and
      what no census costs" (the reserve bounds a no-census run; an
      endless run needs the census), and "Environment, and how to
      reproduce the six runs" - in README.md and MEASUREMENTS.md.
- [x] Commit and push (the commit after 71aa96bb46).

## Open: preemption needs root

`rtprio` and isolated cores are root settings (`/etc/security/limits.conf`,
`isolcpus=`/`nohz_full=`, or a cpuset). The runtime side can offer a helper
that pins, raises the scheduling class, and locks memory, and reports what
the machine refused; until the limits are raised, the per-block
attribution stays the tool.
