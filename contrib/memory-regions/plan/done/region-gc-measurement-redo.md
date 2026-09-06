# Region GC — measure it again, with intervals and the whole machine

Every number of `MEASUREMENTS.md` is a point estimate today. A cost row is
the minimum of the runs of one process, and the file keeps that one number,
so no row carries a standard deviation, a confidence interval, or even a
count of rounds. Two rows carry a range and nothing else. The collector is
measured on one thread, although a hardware-in-the-loop simulation runs on
the whole machine, and the pause of the checked reset is measured with no
other thread running at all.

This plan replaces every measurement. The old data files go; the old
headline numbers stay in `HISTORY.md`, as the record of what the first
measurement said.

## What is wrong today

1. **No dispersion.** `bench/unit_costs.jl` reports the minimum over eight
   compiled copies of a loop and the minimum of five repetitions. The data
   file holds that single number per row per binary. The minimum is a
   deliberate and defensible estimator - it is robust against interference,
   which is the dominant noise of a microbenchmark - but it hides the
   variance and it is biased low. Nothing in the file says how far two runs
   of the same binary differ.
2. **The deltas are smaller than the drift.** The store delta, +0.085 and
   +0.087 ns in two clean runs, is stable. The others are not: the
   construction of three allocations moved +1.06, +1.02, +0.66, +0.62 and
   +0.59 ns across five runs, and the construction from shared children
   +0.23, +0.34 and +0.43 ns. The document states one of those as the
   answer.
3. **The mark row moves between processes.** In the last run the same
   binary marked in 67.9 ms in the process without a window and in 66.3 ms
   in the process that opens one. A claimed +3.4 % therefore carries at
   least ±2 % of its own noise, which is why the documents now say "1 to
   3 %". A row that needs a range that wide needs more rounds, not a
   rounder word.
4. **Unpaired processes.** M2 runs vanilla, then the region binary. A drift
   of the clock, the temperature or the page cache between the two sits
   inside the difference. M1 already alternates the binaries inside a
   round; M2 did not.
5. **The collector is measured on one thread.** The region runtime adds one
   relaxed load per object in the mark loops, one byte test per page in the
   sweep, and three brackets that walk 64 region entries per heap. The
   first is a global that every marking thread reads; the third grows with
   the number of heaps. A serial mark shows neither.
6. **The reset pause is measured alone.** The checked reset stops the
   world. `reset_slice_checked` is 2756 ns with no other thread running.
   The number a simulation cares about is what that reset costs when
   thirty-one other threads run Julia code, and what it costs *them*.

## The design

**Pairing.** A round runs each binary once, and the order turns over
between rounds, so a drift moves both sides of a round together. The
statistic of a comparison is the median of the per-round differences or
ratios.

**The estimator.** The cell of a binary is the median of its rounds. The
cell of a comparison is that median with a percentile bootstrap interval at
95 %, and, for a difference, the p value of a two-sided sign test. With ten
rounds the interval is crude and the sign test is the honest statement:
does the difference keep its direction? Both go in the table, with the
count of rounds beside them.

**The samples stay.** `unit_costs.jl` prints the per-copy minima in a fourth
column, so a reader can see how far the code placement spreads a row, and
the driver writes one data row per round instead of one per binary.

**The latency rows keep their statistic.** A tail is a maximum and a set of
quantiles. No mean, no interval: the document reports the quantiles, the
maximum, and the count of samples.

**The machine state goes into the data.** `context.tsv` gains the count of
cores, the isolated and tickless sets, the governor, the boost flag and the
rounds. A 3 % difference is the size of a frequency drift, and today
nothing in the record lets a reader rule that out.

## The two new rows

### M13 — the collector on the whole machine

`bench/parallel_gc.jl`, both binaries, no window opened. Every thread builds
a part of the live set, so every heap holds a part of it and the marking
threads have work to steal. Twelve full collections per run; a row per
collection. The thread counts are 1, 4, 8, 16 and 32, each with half as many
GC threads, which is the default of julia. The table reports the median
collection of each binary, the paired ratio with its interval, the mark
time, and the longest time a thread took to reach the safepoint.

The question: does an unused region runtime cost a parallel collection more
than it costs a serial one? The suspect is the census filter, a global that
every marking thread reads. A read-shared line is cheap; a line that a
collection also writes is not.

### M14 — what a reset costs the other threads

`bench/reset_pause.jl`, the region binary. `T - 1` workers do arithmetic,
reach a safepoint every round and allocate a little; the main task fills
region 1, closes the window and times one reset. The table reports what the
caller pays, the caller's worst reset, and the longest stall a worker
suffered inside a reset interval, for the checked and the unchecked entry,
against the thread count. The unchecked entry is the control: it frees with
no pause and no scan, so its stall column should stay at zero.

The count of stock collections goes into every row. The workers allocate, so
a stock collection can also stall a worker; a row whose stalls sit far above
its resets with many collections measures the collector, not the reset.

## The machine

Two configurations, and they are not the same machine:

- **Whole machine.** Every core available, for M1, M2, M13, M14 and the
  throughput rows. The isolated partition must be **off**: the parallel
  rows need every core in the scheduler.
- **Isolated core.** For the latency rows M3, M4 and M6, which take
  `SCHED_FIFO` on a core the scheduler does not use.

The machine boots with `nohz_full=13,29`, `rcu_nocbs=13,29` and an
`irqaffinity` that excludes those two, and **without** `isolcpus`, by
design: `tools/hil_isolation.sh` makes the isolated partition at run time
through cgroup v2, so the two configurations are one command apart and no
reboot stands between them.

    sudo tools/hil_isolation.sh on      # CPUs 13 and 29 leave the scheduler
    tools/hil_isolation.sh status       # what holds right now
    tools/hil_isolation.sh run CMD      # CMD inside the partition, pinned
                                        # to CORE, SCHED_FIFO when granted
    sudo tools/hil_isolation.sh off     # they take load again

So the order of the run is: the whole-machine rows with the partition
**off**, so that every core takes load; then the partition **on** for the
latency rows M3, M4 and M6; then off again. The three boot parameters cost
nothing while the CPUs do normal work and complete the isolation while the
partition is on.

Never give the real-time class to anything that forks. The unit-cost bench
runs a child process for its disarmed row, and two `SCHED_FIFO` processes of
one priority on one core stall each other.

## The budget

| Row | What runs | Rounds | Estimate |
| --- | --- | --- | --- |
| M1 | nine benchmarks, two binaries | 10 | 25 min |
| M2 | three processes | 10 | 15 min |
| M13 | five widths, two binaries | 10 | 60 min |
| M14 | five widths, two entries | 10 | 20 min |
| M3, M6 | the tail and the paced loop | as today | 30 min |
| M4 | the real-world loop | as today | 45 min |
| M5 | the census sweep | as today | 40 min |
| M7 to M12 | native, showcases, bound, demonstrators, checker, scaling | as today | 2 to 3 h |

A full run is a night. `ROUNDS=20` on the four cost rows costs about one
hour more and doubles the resolution of their intervals.

## Steps

- [x] `results/stats.py`: median, median absolute deviation, percentile
      bootstrap interval, paired difference and ratio, the sign test, and
      the cells of a table. Seeded, so a table does not move between two
      runs of the script. No dependency outside the standard library.
- [x] `bench/unit_costs.jl` prints the per-copy samples in a fourth column,
      and the disarmed child passes its samples up.
- [x] `bench/parallel_gc.jl`, new: M13.
- [x] `bench/reset_pause.jl`, new: M14.
- [x] `results/run_all.sh`: `ROUNDS`, the paired rounds of M2 with an
      alternating order, `GCTHREADS`, the two new rows, and the machine
      state in `context.tsv`.
- [x] `results/tables.py`: the median with its interval, the paired delta
      with its sign test, and the two new tables.
- [x] `results/plot.py`: the paired plots aggregate by the median and draw
      the range of the rounds; two new plots.
- [x] `MEASUREMENTS.md`: the sections of M13 and M14, and the paragraph
      that states how a cost row is measured.
- [x] A dry run of the whole rendering pipeline on synthetic data, with no
      benchmark: the tables and the four plots come out.
- [x] The smoke run found three faults of the new row, all fixed before
      the measurement: `Threads.ngcthreads()` gives the GC thread count, a
      mixed `[Int, Float64]` array promotes and wrote `1.0` in an integer
      column, and `max_time_to_safepoint` is a running maximum, so the
      per-collection wait is the difference of `total_time_to_safepoint`.
- [x] M1, M5, M7 to M14 ran with the partition off; M2, M3, M4 and M6 ran
      inside it. `MEASUREMENTS.md` says which rows ran in which state, and
      that `context.tsv` cannot show it. One fault of the driver came out of
      the partition: `systemd-run --user --scope` moves a row into a cgroup
      of the user's slice, outside the partition, and `taskset` then refuses
      the isolated core. `USE_SCOPE=0` turns the scope off.
- [x] The old data and plots were dropped before the run.
- [x] The full run: M1, M2, M13 and M14 first, then the throughput rows,
      then the latency rows inside the partition. The unit costs took 25
      rounds after ten left the mark row unsettled.
- [x] Every table and plot is regenerated, and every table was read
      against its claim. Three findings: the collection cost is not flat in
      the thread count (2 % at one thread, 7 % at 32), the construction row
      is exactly three allocation deltas, and the stall column of M14 at 32
      threads measures oversubscription in both entries.
- [x] The prose of `MEASUREMENTS.md`, `COST.md`, `README.md`, the devdoc
      and the pull request text carries the new numbers and the new
      headline.
- [x] `HISTORY.md` keeps the old readings beside the new ones, with the
      four harness faults the run found.
- [x] The flat tag is `0a4b78eb15`; stages 15 to 20 were taken again
      (the devdoc is stage 15 and the README stage 16, so stage 17 was not
      low enough), and Check 1 passes.

## Acceptance

- Every cost table carries an interval and a count of rounds.
- No claim in any document states a delta that its interval does not
  support; a delta inside the noise is called noise.
- M13 answers whether the unused runtime costs a parallel collection more
  than a serial one, at 1, 4, 8, 16 and 32 threads.
- M14 states what a checked reset costs the caller and what it costs a
  worker thread, against the thread count, with the unchecked entry as the
  control.
- `context.tsv` records the machine state that a reader needs to judge the
  numbers: cores, isolation, governor, boost, rounds.
- Every data file under `results/data/` comes from this run. No file of the
  old measurement survives.

## Risks

- **The bootstrap on ten rounds is crude.** It is honest, not precise. The
  sign test carries the direction, and the count of rounds sits in the
  table. Raise `ROUNDS` for a row whose interval decides a claim.
- **The parallel rows need memory.** A live set built by 32 threads is
  large; the driver caps M13 at 24 GB and the tree depth is a parameter.
  Lower the depth before the width if the cap is hit.
- **A worker that does not allocate delays a stop-the-world.** The workers
  of M14 call `GC.safepoint()` every round for that reason. A future
  variant without the safepoint would measure the worst case of a
  non-cooperative thread; that is a different row, and it is not in this
  plan.
- **`context.tsv` does not see the partition.** Its `isolated` field reads
  `/sys/devices/system/cpu/isolated`, which stays empty while a cgroup
  partition holds the CPUs. Read `tools/hil_isolation.sh status` beside it,
  and say in the document which rows ran isolated.
