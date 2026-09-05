# Region GC — a replacement buffer belongs to the region of the buffer it replaces

This plan removes the largest class of accidental escapes: a container that
grows inside a window puts its new backing memory in the window's region,
although the memory has the lifetime of the container. A reviewer of the
first version named the case:

> this will blow up for innocuous things like `push!(long_term_vector,
> some_bits_type)` if the `long_term_vector` gets resized (newly allocated
> Memory lives inside region)

Today the escape barrier catches that store and quarantines the region. The
program keeps its memory safety and loses the region. This plan makes the
case work instead.

The issues plan is `region-gc-issues.md` in this folder. That plan closes
holes in the barrier. This plan changes where an allocation lands, so fewer
stores break the rule at all. The two are independent and can land in either
order.

Status (2026-09-05): Steps 0 to 4 are done on the flat tree, branch
`gc-regions-fixes`, except the decision on a program-level borrow. The
review of the fixes (`region-gc-issues.md`, F6) found four more replacement
sites and added them. Steps 5 and 6 wait for the fold into the series,
together with the issues plan.

## The rule this plan adds

**A buffer allocated to replace or to extend the buffer of an existing
object belongs to the region of the old buffer, not to the open window.**

The rule is sound because the new buffer takes the lifetime of the old one.
The container is unchanged, so its region is unchanged, and the reference
from the container to its new buffer keeps rule 3 with no barrier event.

The rule covers the buffer only. The **elements** stay the program's own
data and keep the rule: `push!(long_term_vector, region_object)` still
quarantines, and it must. The reviewer's example is a bits element, so no
element escapes and the case becomes free of any barrier event at all.

## The mechanism

An allocation must land in a named region while a window on another region
is open. The runtime has half of it already: `jl_gc_region_suspend` and
`jl_gc_region_resume` in `src/gc-common.c:286` install region 0 and put the
window back. Base uses them for the slow path of `OncePerProcess` through
`with_region_window_suspended` in `base/lock.jl:704`.

Region 0 is not enough. The old buffer can be in region 2 while the window
is on a leaf. Allocating in region 0 would be safe and would leak the buffer
into the stock heap, which defeats the model. The mechanism must borrow the
region of the old buffer.

**D1. Add one pair of entry points, `jl_gc_region_borrow(n)` and
`jl_gc_region_unborrow(saved)`.** They swap `active_pools` and
`current_region`, and they touch nothing else: not the window count, not the
task's `region` field, not the stickiness. This is `jl_gc_region_suspend`
generalized from 0 to n, and `jl_gc_region_suspend` becomes
`jl_gc_region_borrow(0)`.

This is a new entry point, and it is the only one this plan adds. It cannot
be avoided: `jl_gc_region_set` is the wrong tool, because it opens a window,
counts it, and pins the task.

**Rules for a borrow, to be written next to the entry.**

- Keep a borrow short. It brackets one allocation.
- Never yield inside a borrow. A task switch inside one saves the borrowed
  region as the task's window.
- Always restore with `finally`. An exception past the restore leaves the
  wrong region current, and that direction is not safe, unlike the region-0
  case of `gf.c`.
- A stock collection inside a borrow is safe. Its bracket reads
  `heap->current_region` into `saved_region` and puts it back.

## The cases

I searched for the shape "C or Base code allocates a buffer for an object
that exists already". The list below is what I found; each entry says who
allocates and whether the old buffer is in hand at the allocation site.

### C1 — Every array growth, through one function in Base

**Julia 1.13 grows a `Vector` in Julia, not in C.** `push!`, `pushfirst!`,
`append!`, `insert!` and `resize!` reach `_growbeg!`, `_growend!` or
`_growat!` in `base/array.jl:1138`, `:1193`, `:1211`, and all three
allocate through one function:

```julia
array_new_memory(mem::Memory, newlen::Int) = typeof(mem)(undef, newlen)
```

`base/array.jl:1101`. It takes the old memory as its first argument, so the
region to borrow is `jl_gc_region_of(mem)`. **One function, and every array
growth path in the language inherits the fix.**

That includes the `data` vector of a `Channel`, which the history of the
branch records as a hazard: a `put!` inside a window grows the channel's
stock vector with region memory. This plan removes that hazard.

`jl_array_grow_end` in `src/array.c:191` is still exported and still
allocates through `jl_alloc_genericmemory` at `:222`, with `a` in hand. Fix
it too, for a caller that uses the C entry.

### C2 — The `IdDict` rehash, in C

`jl_idtable_rehash` (`src/iddict.c:13`) allocates the new table with
`jl_alloc_memory_any(newsz)` at `:22` and has the old table `a` as its
argument. `jl_eqtable_put` reaches it at `:101`. Borrow the region of `a`.

### C3 — The `Dict` rehash, in Base

`Base.rehash!` allocates fresh `Memory` for the slots, the keys and the
values of a `Dict` that exists. The old buffers are in hand as `h.slots`,
`h.keys`, `h.vals`. This is the case the escape test of the branch uses
(`dict_rehash_quarantines_region6` in `test/gc/regions_escape.jl:98`), so a
fix turns that test around: the test must then assert that the region is
**not** quarantined and that the dictionary reads correctly.

`Set` and `WeakKeyDict` wrap a `Dict` and follow it.

### C4 — The `IOBuffer` growth, in Base

`base/iobuffer.jl` grows the `data` of an `IOBuffer` that exists. Same
shape, same fix.

### C5 — The module binding table, in C

`jl_get_module_binding` grows the `bindings` vector of a module that exists
(`src/module.c:1556`). The module is region 0 in every supported use,
because a top-level window is not supported, so this case is already right.
Fix it for consistency only, and say so.

### C6 — The runtime's own caches, in C

The specialization cache of a method (`src/gf.c:256`), the linear type cache
(`src/jltypes.c:1243`) and the method tables all grow a buffer for an object
that exists. They are already right, because the forced region-0 zones put
both the parent and the new buffer in region 0. Leave them, and record the
reason.

### Out of reach

A container written in a package grows its own buffer with an ordinary
allocation, and nothing in the runtime can see that the buffer replaces
another. Those cases stay with the barrier, the quarantine and the
discipline. Name them in the documentation as the residue, and give the
program the borrow to fix its own containers.

## Coverage

| Case | Who allocates | Covered by this plan |
| --- | --- | --- |
| `push!`, `append!`, `resize!` on a `Vector` | `array_new_memory`, Base | yes |
| `Channel` data growth | the same | yes |
| `BitVector` chunk growth | the same | yes |
| `StringVector` growth | the same | yes |
| `jl_array_grow_end` from C | `src/array.c` | yes |
| `IdDict` growth | `src/iddict.c` | yes |
| `Dict`, `Set` growth | `Base.rehash!` | yes |
| `IOBuffer` growth | `base/iobuffer.jl` | yes |
| a package's own container | the package | no, by construction |

## What this plan does not fix

- An **element** that escapes. `push!(v, region_object)` on a region-0
  vector quarantines, today and after this plan. That store breaks rule 3
  and the barrier is right to catch it.
- Any other escape class. The task closure, the opaque closure, `copy` and
  `copyto!` belong to the issues plan.
- The permanent quarantine and its leak. That is I10 of the issues plan.

## Steps

### Step 0 — Decide

- [x] Confirm D1, the borrow pair. It is the one new entry point. Without it
      the rule cannot be expressed. Done: `jl_gc_region_borrow` and
      `jl_gc_region_unborrow` in `src/gc-common.c`.
- [ ] Decide whether `regions.jl` exposes the borrow to a program, so a
      package can fix its own container. A `@in_region_of(old) …` macro is
      the shape. Open: nothing exposes the borrow to a program yet, and the
      test API in `test/gc/regions_api.jl` does not either.

### Step 1 — Reproduce

- [x] Write the test that fails: open a window, `push!` a bits element to a
      region-0 vector until it resizes, close the window, and assert that
      the region is not quarantined and that the vector reads correctly.
      Done: `a_vector_grows_inside_a_window` and
      `a_vector_grows_at_both_ends` in `test/gc/regions_containers.jl`.
- [x] Write the same test for `Dict`, for `IdDict`, for `IOBuffer` and for a
      `Channel`. Done for `Dict`, `IdDict` and `IOBuffer`. No `Channel`
      case: its buffer is a `Vector`, which the C1 cases cover.
- [x] Write the test that must keep failing: `push!` a region object to a
      region-0 vector, and assert that the region **is** quarantined. This
      test guards the split between the buffer and the elements. Done:
      `an_element_still_quarantines`.

### Step 2 — The mechanism

- [x] Add `jl_gc_region_borrow` and `jl_gc_region_unborrow` in
      `src/gc-regions.c`, and make `jl_gc_region_suspend` call the borrow
      with 0. Done, in `src/gc-common.c`, next to the window entries.
- [x] Add the rules for a borrow to the developer documentation, next to the
      window. Done: "Three rules for a borrow" in the section "A
      replacement buffer" of `doc/src/devdocs/gc-regions.md`.
- [x] Add the pair to the API table of the developer documentation.

### Step 3 — The cases

- [x] C1: `array_new_memory` borrows the region of `mem`. Done as
      `array_new_memory_for` in `base/array.jl`, which borrows the region of
      the array, not of `mem`: an empty array shares one permanent empty
      `Memory` of region 0, so the old buffer names the wrong region for an
      array made inside a window. The measurement of `push!` in a tight loop
      waits for the idle machine (Step 5, M1 and M2).
- [x] C1: `jl_array_grow_end` borrows the region of the array. Done in F6
      of the issues plan.
- [x] C2: `jl_idtable_rehash` borrows the region of `a`. Done; a comment in
      `src/iddict.c` says why the old table is a safe key there: an `IdDict`
      never holds the shared empty memory.
- [x] C3: `Base.rehash!` borrows the region of the dictionary, for the same
      reason as C1.
- [x] C4: the `IOBuffer` growth borrows. Done, and F6 added the
      `ensureroom_reallocate` and `truncate` sites after `take!`.
- [x] C5: the module binding table borrows region 0 (`src/module.c`, the
      path that makes a new binding); F5 of the issues plan put the
      `Binding` and its partition in region 0 as well.
- [x] Turn `dict_rehash_quarantines_region6` around, and rename it. Done:
      `a_dict_rehashes_inside_a_window`.

### Step 4 — The malloc'd data must follow

**Warning: this is the one way the plan can introduce a use-after-free.** A
large buffer is malloc'd, and `jl_gc_region_track_malloced`
(`src/gc-regions.c:208`) records it in the **current** region. The reset of
that region frees the data. If the header lands in the borrowed region while
the data is tracked in the window's region, the reset of the window's region
frees the data of a buffer that lives on.

- [x] Check that the borrow brackets the whole allocation, so the tracking
      lands in the borrowed region as well. `jl_gc_region_track_malloced`
      records in the current region, which the borrow installs, and
      `array_new_memory_for` wraps the whole `array_new_memory` call.
- [x] Write a test with a buffer above the malloc threshold: grow it inside
      a window, reset the window's region, and read the buffer. Done:
      `a_vector_grows_inside_a_window` grows to 80 KB and sums the vector
      after the reset.
- [x] Run `jl_gc_region_verify` on both regions after the reset. Done for
      the window's region; region 0 is not a valid argument of the verify.

### Step 5 — Fold into the series and gate

- [ ] Map each change to its owning stage with `xstage.py`. The borrow
      belongs to stage 1, "region state in the thread heap, and the window".
      The Base changes belong to the stage that owns `base/`.
- [ ] `retake.sh` from the lowest stage that changed. Check 1 passes.
- [ ] Check 2 and Check 3 with `check23.sh`.
- [ ] The `gc` group on the tip binary, and `core threads misc` if the code
      of the default build changed.
- [ ] M1 and M2 again. `array_new_memory` is on the growth path of every
      array in the language, so a regression there is a regression for every
      Julia program, region or not.

### Step 6 — Close

- [x] Add a row to `HISTORY.md` for the rule and for each case. Done: R7 and
      S7, and F6 for the four later sites.
- [x] Update the developer documentation: the rule, the borrow, the residue
      that stays with the program. Done: the section "A replacement buffer".
- [ ] Update the pull request text in `region-gc-tidy.md`. The reviewer's
      case is the first thing to say.
- [ ] Move this plan to `plan/done/`.

## Acceptance

- Every test of Step 1 that failed passes, and the guard test still
  quarantines.
- The malloc'd-data test of Step 4 passes, and `jl_gc_region_verify` reports
  no error.
- M1 and M2 stay inside their spread, the growth loop of Step 3 included.
- The gate of Step 5 is green.
- The documentation states the rule, the borrow and the residue.

## Risks

- **A borrow that leaks.** An exception between the borrow and the restore
  leaves the wrong region current, and every later allocation on that thread
  lands there. Every borrow must use `finally`, and the tests must include
  an exception thrown from inside a growth.
- **A yield inside a borrow.** An allocation does not yield, but a finalizer
  can run at an allocation. A finalizer runs with the window parked and the
  depth raised, so it cannot open a window; check that it also cannot yield
  out of the borrow.
- **The cost lands on every Julia program.** `array_new_memory` grows every
  array. The borrow must compile to two stores and a branch, and M1 must
  prove it.
- **The rule can hide a real escape.** A program that deliberately puts a
  buffer in a window, and means it, no longer gets the quarantine. That is
  the intent, and the elements still carry the rule.
