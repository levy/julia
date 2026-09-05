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

## The audit (done)

Every copy of tracked pointers into a fresh object, in the C runtime and
in the compiler. Class A copies an inline value whose bytes are not a heap
object into a fresh box. Class B copies from a heap container, where the
pair check of the bulk barrier already stands. Class C builds a runtime
object whose children are types, methods or code.

| Class | Site | Result |
| --- | --- | --- |
| A | `datatype.c`: `jl_new_bits`, `jl_atomic_new_bits`, `jl_atomic_swap_bits`, `jl_get_nth_field`, `swap_bits`, `modify_bits`, `replace_bits` | fixed: `jl_gc_multi_wb_fresh(r, r, type)` after the copy |
| A | `genericmemory.c`: `jl_memoryrefget` | fixed |
| A | `runtime_intrinsics.c`: `jl_atomic_pointerreplace` | fixed (the old value is field 0 of the result) |
| B | `_new_array`, `jl_exprn`, `jl_f__expr`, `jl_decode_value_array1d` | no fix: the source is a heap container or the image, the pair check or region 0 covers it |
| C | `jl_new_codeinst`, `make_method_match`, `jl_typemap_alloc`, `jl_new_method_table`, `jl_new_typename_in`, `jl_new_method_uninit`, `jl_new_module__` | documented, no fix: their children are made by the compiler and the loader at region 0 in every supported program |
| C | `builtins.c`: `jl_new_typevar` (`lb`, `ub`) | fixed with `jl_gc_wb_fresh`: a bound built inside a window |
| C | `jltypes.c`: `jl_substitute_datatype` (Vararg `T`, `N`), `jl_wrap_vararg` | fixed with `jl_gc_wb_fresh` |
| C | `method.c`: `jl_copy_code_info` | fixed with `jl_gc_multi_wb_fresh` |
| compiler | `emit_new_struct`: the tracked values of an inline-root field join `region_children` | fixed |
| compiler | `boxed()`: the tracked values of the value it boxes | fixed |
| compiler | `emit_pointerref`, `emit_atomic_pointerref`: a struct loaded through a raw pointer into a fresh box | fixed with `emit_region_write_barrier_fields` |

## Decisions

- A pair check of two containers is unsound when the source is a stack
  buffer or a raw pointer: it has no page tag. The fresh-copy barrier
  walks the pointer fields directly. In C this is the macro
  `jl_gc_region_wb_inline_check(parent, src_p, et)` and the fourth
  annotation `jl_gc_multi_wb_fresh(parent, data, dt)` of `gc-interface.h`
  (the mmtk stub is empty). In the compiler it is
  `tracked_values_of(ctx, cgval, type)` and
  `emit_region_write_barrier_fields(ctx, parent, type)`.
- The `julia.region_write_barrier` intrinsic declares its parent
  `readonly nocapture`. The barrier only reads the page tag of the parent.
  Without `nocapture` the intrinsic captures a fresh object, and this
  costs an optimization that vanilla has (see regression (b)).

## Regressions found by the sweep and the `gc` group

(a) `regions_tree.jl`: "the trunk not quarantined". The new barrier
quarantines the region-1 trunk of the tree test. The test hands the trunk
to `Threads.@threads` workers, and the closure of each worker, a region-0
object, captures the trunk. That is a real escape by the rule; the old
barrier did not see it because the closure is a fresh object. Whether a
task closure that captures a region object is an escape is a model
question for the user. Open.

(b) `regions_window.jl`: alloc-opt no longer elides a small fresh Array.
Root cause, found with `/usr/bin/opt-20 -passes=gvn` on the module before
GVN: the fresh-copy barrier for the `MemoryRef` field of the Array passes
the Array to a call before the element stores through `julia.gc_loaded`.
BasicAA proves that those stores leave the Array's size field alone only
while the Array is not captured, so GVN could not forward the size store
to the later `length` load, the `n < 16` test did not fold, the
`mapreduce_impl` call survived, and the Array escaped into it. The matrix
of declarations shows the trigger exactly: `nocapture` on the parent
parameter restores the forwarding; the memory attribute, `readonly`, and
the vararg shape change nothing. Fix: `Attribute::NoCapture` on the parent
parameter of the intrinsic in `src/codegen.cpp`.

## Steps

- [x] The audit of every copy of tracked pointers into a fresh object, in
      the compiler and in the runtime, with a table of sites.
- [x] The compiler sites.
- [x] The runtime sites.
- [x] The tests: `Twin`, `TwinHolder`, `Mutable` cases for regions 8-11 in
      `test/gc/regions_escape.jl`, `fresh_copy_barrier_is_region_only`, the
      mask loop over the quarantined regions.
- [x] The measurement row `box_twin` in `bench/unit_costs.jl` and
      `results/tables.py`. The numbers wait for an idle machine.
- [x] The devdoc: the barrier section names the fresh-object copies; the
      claim "every heap reference" holds again.
- [x] Regression (b): `nocapture` on the parent of the intrinsic. The
      optimized IR of the probe is `ret 1.0` on both builds again, and
      `regions_escape.jl` pins it (`fresh_barrier_leaves_alloc_opt_intact`).
- [x] Rebuild, then re-run `regions_window.jl` (100 checks),
      `regions_escape.jl` (66 checks), the sweep (54 of 60; the six
      `regions_tree` runs fail on regression (a)), the `gc` group (177
      pass, 12 errors: the twelve harness configurations of
      `regions_tree.jl`), `core` and `Compiler/codegen` (both SUCCESS).
- [ ] Regression (a): the user's decision on a task closure that captures
      a region object. `regions_tree.jl` fails until then.
- [x] Commit `e3eb502bb4` on `gc-regions-fixes`, pushed.

## Measurement (preliminary, shared machine, core 29 without FIFO)

Another build ran on the machine. The stock rows, min of 5, vanilla then
this commit: `store_disarmed` 0.87 → 1.10 ns, `construct_two` 19.0 →
20.8 ns, `construct_shared` 8.80 → 9.84 ns, `box_twin` 9.40 → 10.62 ns,
`alloc_stock` 5.54 → 6.57 ns, `stock_mark` 154 → 156 ms. Every row moved
by about one nanosecond, the untouched `alloc_stock` included, so the
barrier of the fresh box is inside the spread. The accurate numbers wait
for an idle machine.

Do not run the bench under `chrt -f 50` on one core: the bench forks a
child process for the disarmed row, and two FIFO processes of one priority
on one core stall each other. The child ran for six minutes with zero
context switches and no output; plain `taskset -c 29` finishes in about
three minutes.
