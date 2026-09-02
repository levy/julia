# Rebuild the `memory-regions` branch as a followable series

**Goal.** The Julia repository's `memory-regions` branch (levy/julia) holds
the region runtime as one 779-line commit plus two commits of Julia side and
records. Rebuild it as a series that an external reader who knows Julia and a
little of its internals can follow: the design first, then one runtime idea
per commit, each compiling, then the Julia face, the tests, the examples, and
the measurements — separately.

**Safety.** The old tip stays as branch `memory-regions-before-rebase` and tag
`memory-regions-v1-2026-09-01`. The last runtime stage must equal the old
runtime byte for byte (`git diff` empty against `118abf4 -- src/`).

## The series

Runtime, each stage built with `make` and checked:

- [x] 1 `contrib/memory-regions/DESIGN.md` — the goal and the semantic design
- [x] 2 region state and the switch: `gc-tls-stock.h` fields, `active_pools`,
      the allocation decode, `jl_gc_region_set` / `_current` / `_overflow`,
      thread-heap init
- [x] 3 page tagging and the region page chain: `gc-stock.h` fields,
      `gc_add_page` tags and chains, `jl_gc_region_of`
- [x] 4 the guards: the sweeper skips tagged pages; `jl_gc_collect` defers
      while a window is open (the global window counter in `region_set`);
      `gf.c` pins inference and compilation to region 0; region 0 born
      initialized
- [x] 5 the reset: `jl_gc_region_reset`, `fresh_pages`, `gc_add_page` reuse
- [x] 6 the finalizer gate (`gc-common.c`)
- [x] 7 the scoped census: statics, the mark filter in `gc_try_claim_and_push`
      with task recording and the leaf shortcut, `region_scoped_sweep`,
      `jl_gc_region_collect`, `jl_gc_region_stat`
- [x] 8 the cooperative census: `jl_gc_region_collect_coop`
- [x] 9 the rule-5 check: `jl_gc_region_set_debug`, `jl_gc_region_check`, the
      refusal in `jl_gc_region_reset`
- [x] 10 diagnostics: `jl_gc_region_verify`, `jl_gc_map_addr`, the corpse
      report in `gc_setmark_pool`, the free-page guard in `gc-pages.c`

Julia side, each verified against the build:

- [x] 11 `regions.jl`, the README (overview, build, API), `contrib/README.md`
- [x] 12 the batteries: `v2_regression.jl`, `stage3_safety.jl`, `run.sh`
- [x] 13 the kernel, the models, `harness.jl` — the vanilla-Julia yardstick
- [x] 14 the tail bound, the paced run, the endurance run
- [x] 15 the census and throughput example, `run.sh` complete
- [x] 16 the discipline checker and the barrier trap
- [x] 17 the stage-6 experiment
- [x] 18 `MEASUREMENTS.md` and `logs/`; the README's measured tables
- [x] rename the new branch to `memory-regions`, force-push with lease

## Decisions made on the way

- The stages are constructed by a builder script from the base files and the
  final files, and the last stage is asserted equal to the old runtime byte
  for byte. The builder's first version matched a forward declaration
  instead of a definition (`jl_gc_region_check`) and corrupted stages 9-10;
  a block is anchored on the signature plus its opening brace now.
- `fresh_pages` and the `gc_add_page` reuse arrive with the reset (stage 5),
  not with the census: the reset parks the pages beyond one per pool there.
- The window counter, the collect defer, the region-0 pins and the "born
  initialized" flag form one commit (stage 4): each was learned from a
  crash, and they are one idea - no collection sees a region's pages.
- The IDE crashed during the stage-3 build (`make -j24` on all cores plus
  the Julia runs); the builds run on half the cores since.
- The runtime stages are smoke-tested with what each stage newly allows:
  the switch, `region_of`, a collection with the window closed, the reset,
  the finalizer gate, both censuses, the rule-5 check; the batteries and the
  examples run from stage 9 and 10.
- Stage 4's smoke first asserted "no collector time inside the window" and
  failed by timing: the collection a window defers is OWED, and it runs at
  the first allocation after the window closes - or during a runtime pin
  (inference, compilation), where region 0 is current and the sweeper guard
  keeps it off the region's pages. The smoke reads the pause count from
  inside the window now, and the stage-4 message states the pin's effect.
- Measured with `GC.enable_logging`: the collection the smoke kept seeing
  ran at a toplevel `@assert` inside the window - the toplevel evaluator
  compiles an `if` with a `throw` branch, the compile pins region 0, and
  the owed collection runs during the pin. Inside a window, a smoke test
  makes only plain calls to compiled functions and asserts afterwards.
- Stage 5's first smoke crashed with glibc heap corruption on a clean
  rebuild, and the pool-objects-only variant passes 200 allocate-reset
  cycles: the trigger is a 4000-byte array allocated under the region
  window. Its header is a small region-tagged object; its data is malloc'd
  and tracked by the runtime's malloc list, which the reset does not know.
  CONFIRMED on the final runtime: the same probe aborts there (signal 6,
  `corrupted size vs. prev_size`), while the pool-only smoke and
  v2_regression pass. A pre-existing defect of the prototype, not of the
  split. The README's API notes and honest limits now carry it: no array
  with malloc'd data inside a window.
- Stage 6's smoke wrapped the refused finalizer in a toplevel `try`, and
  the refusal never came: the compiler elides an effect-free finalizer
  registration outright, so nothing reached the runtime - the second of
  the two compiler facts the prototype plan recorded (the other: the
  builtin is modelled nothrow, so a compiled catch would not see the error
  either). The smoke now runs the registration at a child process's
  interpreted top level and checks the child's exit and message.
- Stage 7's smoke held the census table in a GLOBAL and segfaulted after
  the census: a global binding is a store into the root region (rule 3),
  and the census marks from the execution roots only (rule 6), so the
  table was never marked and its cells were freed. The smoke keeps the
  table on a function frame, as the census example does. Every smoke
  mistake so far was a rule of the design, met in practice.
- The runtime series landed as ten commits (`a3854b7364..8b287450d9`), each
  built and tested, and `git diff 118abf4 -- src/` on the last is EMPTY:
  the rebuilt runtime equals the old one byte for byte.
- The Julia side landed as eight commits (`bab8c5530c..5a9aac7ad4`; the last amended once, to pair the tail table's stock column with the run its regions column came from: 4.7 ms and 17 collections, not 13.97 ms), each
  verified against the branch's build before it was made: the face, the
  batteries, the yardstick, the tail-bound examples, the census example,
  the checker and the trap (exit 1 is the trap's pass), the stage-6
  experiment, the measurement record. The README grows one section per
  commit; the file table is regenerated at each.
- Done 2026-09-01: 18 commits on `memory-regions` (levy/julia), pushed with
  lease over the old tip `43b03bd0eb`, which stays as
  `memory-regions-before-rebase` and the tag `memory-regions-v1-2026-09-01`.
  Between the two tips only `DESIGN.md`, the README and the `contrib`
  index differ; the runtime and every script and log are identical.
