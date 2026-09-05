# Region GC — the fresh-object copies the barrier does not see

The devdoc says: "The barrier catches every heap reference that breaks the
rule." A probe on the binary of 2026-09-05 (`region-gc-fresh-object-copies-probe.jl`, next to this plan, before the
construction-only barrier) shows two heap references that it does not
catch. Both are copies of tracked pointers into a fresh object, on paths
where vanilla emits no write barrier because the parent is young, and
where the branch added none.

| Probe | Parent | Child | Quarantined |
| --- | --- | --- | --- |
| `Holder(c)`, a boxed field | region 0, fresh | region 5 | yes |
| `TwinHolder(Twin(c, c))`, an inline immutable field with two pointers | region 0, fresh | region 6 | **no** |
| `Any[Twin(c, c)]`, an unboxed `Twin` boxed into a fresh box | region 0, fresh box | region 7 | **no** |

The reset of region 6 or 7 would then free `c` under a live reference from
a region-0 object, and the checked reset does not refuse: its root check
walks the execution roots, not the heap.

## The paths

- `emit_new_struct` (`src/cgutils.cpp`), the boxed allocation: a field that
  is not a pointer field but carries inline roots (`!jl_field_isptr` and
  the field type has `npointers > 0`) is stored with `need_wb = false`. The
  boxed pointer child of the same loop now gets `julia.region_write_barrier`
  (plan `region-gc-construction-barrier.md`); the inline roots get nothing.
- `boxed()` and `box_union()` (`src/cgutils.cpp`): an unboxed value with
  tracked pointers, in an SSA aggregate or in a stack slot with
  `inline_roots`, is copied into a fresh box by `init_bits_cgval` /
  `emit_unbox_store`, with no barrier.
- The C runtime: `jl_new_bits` (`src/datatype.c`) copies an inline
  aggregate with pointers into a fresh box, for `getfield` of an inline
  immutable field and for `unsafe_load`. `set_nth_field` and
  `jl_new_structv` are covered by `jl_gc_wb` / `jl_gc_multi_wb`, whose
  stock definitions carry the region check. Every other memcpy of tracked
  pointers into a fresh object needs the same audit: `jl_new_struct_uninit`
  followed by a copy, `jl_copy_...`, the array and memory copies that
  `HISTORY.md` lists as covered, and the image loader, which is region 0
  by construction.

## The design

- Compiler: `emit_region_write_barrier` takes an `ArrayRef<Value*>` of
  children. `emit_new_struct` emits it for the tracked values of an
  inline-root field (`ExtractTrackedValues` on the stored aggregate, or the
  slice of `inline_roots`), and `boxed()` emits it for the tracked values
  of the value it boxes. One guard per site, a cold call per child when
  armed.
- Runtime: `jl_new_bits` and any other copy found by the audit call
  `jl_gc_region_wb` per pointer under the armed flag, or a
  `jl_gc_region_multi_wb(parent, type)` that walks the pointer layout of
  the copied type once.
- Tests: the two probe cases in `test/gc/regions_escape.jl`, one region
  each, plus a `getfield` of an inline immutable field of a region object
  from region 0.
- Cost: one flag test per box of a value with pointer fields, on a program
  that never opens a window. Measure with a `box_twin` row in
  `bench/unit_costs.jl` before and after.

## Steps

- [ ] The audit of every copy of tracked pointers into a fresh object, in
      the compiler and in the runtime, with a table of sites.
- [ ] The compiler sites.
- [ ] The runtime sites.
- [ ] The tests.
- [ ] The measurement row.
- [ ] The devdoc: the barrier section names the fresh-object copies; the
      claim "every heap reference" holds again.
