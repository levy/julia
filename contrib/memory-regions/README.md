# Memory regions: the Julia face

The runtime of this branch adds regions to the stock collector — sets of
objects with one common lifetime, kept safe by one rule: a reference may
only point to an object of equal or longer lifetime. [DESIGN.md](DESIGN.md)
is the design; the commits before this one are the runtime, one idea each.
This directory is the Julia side: `regions.jl` wraps the runtime entry
points so a program can open a region, come back, reset it, and ask for a
census of it.

## Build

```
make -j$(nproc)        # at the repository root: builds ../../julia
```

Every script in this directory says at its top how it is run; all of them
take the branch's own build, `../../julia`.

## The rules, in five lines

1. Every object belongs to exactly one region, chosen at allocation,
   forever (no promotion).
2. Every allocation goes to the dynamically current region — including
   compiler-implicit ones (tuples, boxes, closures, exceptions).
3. A reference `a → b` is legal only when `b`'s region is an ancestor of
   `a`'s, or the same. A store that violates this is a defect, not a
   hint: a write barrier can trap on it exactly.
4. `reset!(r)` is legal when no execution root and no live younger object
   points into `r`. Rule 3 guarantees no OLDER object can.
5. A collection of `r` needs only the execution roots plus quiesced
   younger regions: older regions are implicitly live and never traced.

## The API

`regions.jl` is a small module; `include` it and `using .Regions`.

| call | runtime entry | what it does |
| --- | --- | --- |
| `region_set(n)` | `jl_gc_region_set` | make region `n` current; returns the previous region. Region 0 is the ordinary heap |
| `region_current()` | `jl_gc_region_current` | the current region |
| `region_reset(n)` | `jl_gc_region_reset` | free every object of region `n` (not current) in O(pages); returns the page count, or `typemax(UInt64)` when the debug check refuses |
| `region_of(x)` | `jl_gc_region_of` | the region of an object, from its page tag, in constant time |
| `region_collect(n)` | `jl_gc_region_collect` | the census: stop the world, mark region `n` from the execution roots, sweep only its pages; returns the freed cell count |
| `region_collect_coop(n)` | `jl_gc_region_collect_coop` | the same census with no stop-the-world, for a single-mutator engine at an event boundary it owns; `-4` when another thread runs managed code |
| `region_check(n)` | `jl_gc_region_check` | the rule-5 scan: live references into `n` from the execution roots, without a reset |
| `region_debug(on)` | `jl_gc_region_set_debug` | arm the rule-5 scan on every reset |
| `region_overflow(n)` | `jl_gc_region_overflow` | the pages region `n` had beyond one per pool |
| `region_reserve(bytes)` | `jl_gc_region_reserve` | claim and prefault `bytes` of heap before the loop: populates every block the runtime already holds (`MADV_POPULATE_WRITE`), maps whole blocks populated (`MAP_POPULATE`) into the clean pool, and populates every later block too; a loop whose heap fits takes no page fault. Returns the bytes mapped |
| `@with_region n body` | (macro) | run `body` with region `n` current and come back to the previous region, however the body leaves; the readable form of a window - the hottest loop can keep the bare `region_set` pair |

The reset, the check and the census are `@noinline` Julia calls on purpose:
a bare `ccall` is not a safepoint, so the caller would keep live references
in registers where the precise root scan can not see them. A Julia call is
a safepoint boundary — the caller spills every live value into its frame,
which is exactly what the rule-5 scan reads.

One rule the runtime does not check, and breaks the heap when it is broken:
**an array with malloc'd data — a `Vector` of more than about 2 KB — must
not die inside a region.** Its header is a small region object while its
data is kept by the runtime's own malloc list; a reset or a census frees the
header, the list still owns the data, and the next full collection corrupts
the heap. Keep such arrays in region 0, or make sure they outlive the region
(a table that lives for the whole run is fine — the census example keeps
one).

The shape of an event loop, from the design:

```julia
region_set(EVENT)
process_event!(...)
region_set(0)
region_reset(EVENT)          # after the extent: no stack can still point in
```

## Tests

Two batteries, both printing `ALL PASS`; `./run.sh` runs them:

- `v2_regression.jl` — the reproducer of the two collector-interplay defects
  the prototype found and fixed: reset every iteration, three million
  cycles, an explicit collection after quiesce, plus the swap-only and the
  live-object variants.
- `stage3_safety.jl` — the rule-5 check: with the debug scan armed, a reset
  while a live reference still points into the region is refused and the
  offender is named by type; the reset succeeds once the reference dies; an
  explicit check reports zero afterwards. The file documents the pinning
  idioms a test of region machinery needs against the optimizer
  (`Base.donotdelete`, `GC.@preserve`, an opaque callee).

## Files

| file | role |
| --- | --- |
| the commits before this one, `src/gc-*.c` and `src/gf.c` | the runtime |
| `DESIGN.md` | the goal and the semantic design |
| `regions.jl` | the Julia face: the calls above |
| `v2_regression.jl`, `stage3_safety.jl` | the correctness batteries |
| `run.sh` | runs the batteries |
