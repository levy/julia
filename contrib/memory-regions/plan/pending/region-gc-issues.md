# Region GC — the issues a code review found

This plan collects the robustness, correctness and safety issues of the
region collector that a review of the sixth cut found, and it says how to
close them. The series `gc-regions` on levy/julia is at `3577055ee6`; the
flat tree is the tag `gc-regions-flat` at `d543cb834a`. The pull request is
not opened.

The tidy plan is `region-gc-tidy.md` in this folder. That plan built the
series and its gate. This plan changes the runtime.

A third plan, `region-gc-parent-region-buffers.md`, is independent of this
one. It makes a replacement buffer belong to the region of the buffer it
replaces, so a container that grows inside a window no longer escapes at
all. This plan closes holes in the barrier; that plan removes the largest
class of stores that hit the barrier by accident.

## Status of the evidence

Every issue I1 to I13 comes from a read of the source at `d543cb834a`. Step
1 turned each consequence into a test, and Step 2 fixed them on the branch
`gc-regions-fixes` (worktree `workspace/julia-gc-fixes`, eight commits
`41f8b37749..55ef64ed29`). A second review of those eight commits found the
findings F1 to F7 below, each with a scratch test that fails on
`55ef64ed29`; the tests of those findings found F8 and F9. The findings are
the open work of this plan.

## The findings of the second review (2026-09-05)

Ranked as the issues are: a corruption and a leak first, a false refusal
next, a hole in a check last. Each finding gets a regression script under
`test/gc/` before its fix.

### F1 — The checked reset leaves marks on other heaps (corruption)

`region_root_scan` (`gc-regions.c`) marks from the roots of every thread and
clears the marks of the calling heap only. Two threads that use the same
region number on their own heaps — the supported per-thread leaf pattern —
are hit: after thread B's checked reset, thread A's region-n objects stay
marked. A's next checked reset refuses falsely with `EROOT` ("6002 live
references"). A's next census does not walk a stale-marked live object
(`gc_scoped_setmark` returns 0), so it never marks the children that object
holds: it frees live children and keeps dead ones. Witnessed: `live=6002
freed=3005`, and parents read `-1` after the freed cells were reused.

Fix: `region_root_scan` calls `region_clear_marks_on_other_heaps(heap, n)`
before `region_census_end()`, as `region_census_core` does. This fixes
`jl_gc_region_check` too. Test: `regions_heaps.jl`, two threads, one region
number, a reset mode and a census mode; skipped with one thread.

### F7 — A census of a region with a live child frees live objects (corruption)

The census filter drops every out-of-region object at the claim
(`gc_scoped_claim`). A child region holds legal references into its parent.
A census of the parent while the child is live does not walk the child's
objects, so a parent object that only the child references is never marked
and is freed. Witnessed: open 1, allocate `a`; open 2, `b = Ref(a)`; close;
`collect(1)` returns `freed=1002`; the next stock collection segfaults in
`gc_mark_outrefs` on the freed cells.

The reset refuses this case with `ECHILD` (`region_haschild_mask`); the three
census entries (`jl_gc_region_collect`, `jl_gc_region_collect_coop`,
`jl_gc_region_census_open`) do not check it. Fix: the same `ECHILD` refusal
in all three. The allocator's census of the open region skips the census and
goes on, as it does for a quarantine. Test: `regions_census.jl` gains the
case.

### F2 — The pair checks quarantine correct programs (false quarantine, leak)

`jl_gc_wb_genericmemory_copy_boxed`, `jl_gc_wb_genericmemory_copy_ptr`,
`jl_genericmemory_copy_slice` (`jl_gc_wb_fresh(new_mem, mem)`),
`jl_svec_copy` and `jl_gc_multi_wb` test the pair (destination container,
source container) and use the source container's region as a proxy for the
regions of its elements. A young container of old elements copied into an
old container — `append!(old, filter(f, xs))` after the window closed,
`copy(scratch)` into a region-0 field — trips the proxy: the region is
quarantined for a legal program, and a quarantine is permanent.

Fix: keep the pair test as the fast path; when the pair test would
quarantine, test each element (each pointer field for `_copy_ptr` and
`multi_wb`) and quarantine only on a real escape. This needs a predicate
split out of `jl_gc_region_wb` that answers "would this store escape"
without quarantining. Test: the young-container-of-old-elements copy must
not quarantine; today it does.

Found while writing the test: `jl_genericmemory_copy_slice` ran its pair
check only under `layout->first_ptr != -1`. The layout of a boxed memory
lists no pointer (`first_ptr` is -1; the element is the reference), so the
C copy of a `Vector{Any}` — `jl_array_copy`, `jl_genericmemory_copy` — ran
no check at all, and region elements left the region unnoticed. The fix
puts the boxed case before the layout test. The test gains a case that
burns a region through `jl_array_copy`.

The predicate is `jl_gc_region_would_escape`; the element loops are
`jl_gc_region_wb_boxed` and `jl_gc_region_wb_inline` (`gc-regions.c`); the
two macros `jl_gc_region_wb_copy_boxed_check` and
`jl_gc_region_wb_copy_inline_check` (`gc-wb-stock.h`) join them, and the
five sites call the macros.

### F3 — The global reset runs no root scan

`jl_gc_region_reset_global` refuses `EFINALIZERS`, `ECHILD`, `EBUSY` per
heap under its stop-the-world, then frees every heap's region `n` with no
root scan. The per-heap reset checks by default; the global one is unchecked
under the checked name. Fix: one mark from every thread's roots and one walk
of every heap's region-`n` pages inside the existing pause, `EROOT` on a
hit; or name it `jl_gc_region_unsafe_reset_global` and add the checked one.
Test: a trunk object rooted on a parked task's frame; the global reset must
refuse.

### F4 — A finalizer registered during the check runs under the pause

The checked reset runs the region's finalizers (phase 1), then re-reads the
quarantine, then stops the world and scans. A finalizer that registers a
new finalizer on a region object leaves a non-empty list, and
`region_reset_heap` runs `region_reset_finalizers` inside the pause: Julia
code under stop-the-world. Fix: run the finalizer phase in a bounded loop
until the list is empty (refuse `EFINALIZERS` past the bound); inside the
pause assert the list is empty and never run Julia code. Test: a finalizer
that registers a finalizer; the reset must not deadlock and must run both.

### F5 — A binding defined inside a window is a region object

A name first looked up inside a window allocates its `Binding`, and its
first `BindingPartition`, in the window's region; the store into the
module's binding table (`SimpleVector` of region 0) is an escape and
quarantines the region. The lookup is a run-time event, not only a toplevel
one: `getglobal`, `isdefined`, `@eval` and the first resolution of a global
in compiled code all reach `jl_get_module_binding` with `alloc=1`. The
documentation's claim "a binding is a region-0 object" is false for such a
name. Fix: `jl_gc_region_borrow(0)`/`unborrow` around the two allocations
in `src/module.c` (`jl_get_module_binding` and `new_binding_partition`).
Test: `regions_window.jl` looks up a new name inside a window and asserts
no quarantine, that the `Binding` is in region 0, and that the region
resets.

The first report said "`@eval f(x) = ...` inside a window", and a probe
found the other objects (`Method`, signature, `DataType`, `TypeName`,
`Module`) in region 0. That probe stopped at the binding's quarantine, so
it did not show whether a toplevel definition quarantines for another
reason once the binding is right. The probe ran again on the fixed build,
one definition per region: `@eval f(x) = x + 1` stores a `DataType` (the
type of `f`) of the window's region into a `BindingPartition`; `@eval
struct S ... end` stores its `DataType` the same way; `@eval module M ...
end` stores a `Module` of the region into a `GlobalRef`; `@eval const c =
Ref(1)` stores the `RefValue`. Each one quarantines its region. `@eval g =
7` does not, because an `Int` is not boxed. So a run-time lookup of a new
name inside a window is fixed, and a toplevel definition inside a window
quarantines through the defined object itself: it is made in the open
region, and the binding that holds it is region 0. That is the reference
rule at work, not a fault. The devdoc bullet "Open a window inside a
function, not at top level" names the four objects.

### F6 — Replacement buffers the C1 rule does not reach

Sites that replace a container's buffer without a borrow, so the new
buffer lands in the window's region and the store into an older container
quarantines it:

- `base/iobuffer.jl`: `ensureroom_reallocate` (the `reinit` path after
  `take!`) and the `reinit` branch of `truncate`. A cached `IOBuffer` that
  is emptied with `take!` and written to inside a window hits this.
- `base/iddict.jl`: `empty!(::IdDict)` allocates a fresh `ht`.
- `base/idset.jl` `push!` → `jl_idset_put_key` (`src/idset.c`) and
  `jl_idset_put_idx` → `smallintset_rehash` (`src/smallintset.c`).
- `src/array.c` `jl_array_grow_end`: the C growth the runtime's own
  `jl_array_ptr_1d_push` callers use; the store runs `jl_gc_wb`, so the
  barrier sees it, but the buffer is in the wrong region.

Fix: a borrow keyed on the container at each site, as C1 does. Test: each
site once — an old container, the operation inside a window, no quarantine.

### F8 — A borrow did not mark the region live on the heap that borrows

Found while writing the F6 tests. `jl_gc_region_borrow(n)` installed
region `n` on the calling heap through `jl_gc_region_install_task`, the
task-switch path, which assumes the region is already live on that heap: a
task switch reinstalls a window this heap opened. A borrow has no such
guarantee. Thread B grows a vector that thread A made in a child region; B's
heap takes pages of the child, but the child is not in B's
`region_live_mask`, so B's `region_haschild_mask` does not name it and B's
reset of the parent runs while the child's pages live under it. Fix:
`jl_gc_region_install_borrow` (`gc-regions.c`) does the lazy init, marks the
region live, then installs it; `jl_gc_region_borrow` calls it. Test:
`regions_heaps.jl` gains a two-thread round: B's reset of the parent must
refuse `ECHILD` while B's borrowed buffer lives, then succeed once the child
is reset on both heaps.

### F9 — The exception stack of a task is made in the open region

Found while the F5 test ran on the fixed build: the case's first throw
printed "a (null) of region 1 was stored into a Task of region 0" and
quarantined the region. The `(null)` is a GC buffer, which has no type name.
`jl_reserve_excstack` (`src/rtutils.c`) makes the exception stack of a task
at the task's first throw, with `jl_gc_alloc_buf` in whatever region is
open, and stores it into the `Task`. The task keeps the buffer and every
later throw reuses it, so it has the lifetime of the task, not of the
window. A task made outside the window and thrown inside it for the first
time quarantined the window's region. Fix: `jl_reserve_excstack` borrows
`jl_gc_region_of(ct)` around the allocation, as the replacement-buffer rule
does for a container. Test: `regions_window.jl` runs a fresh task that
opens a window and throws for the first time inside it; no quarantine, and
the region resets. The case fails on the build before the fix with
`FAIL: the first throw inside a window does not quarantine the region`.

The same read looked at `save_stack` (`src/task.c`), which copies the stack
of a copy-stack task into a buffer before the switch, with the window of the
task still installed. The buffer is always larger than `GC_MAX_SZCLASS`, so
it is a big object and belongs to region 0 whatever window is open. A probe
with `JULIA_COPY_STACKS=1` and a real task switch inside a window showed no
quarantine on the unfixed build. No change there.

### Lesser notes, no action

- `jl_idtable_rehash` keys its borrow on the old buffer, not the `IdDict`;
  correct because the old buffer is never the shared empty memory, but
  fragile. Leave a comment.
- A checked reset that loses the safepoint 1024 times returns `ERACE`;
  callers must handle it. Document.
- The cooperative census's one-time `EUNSAFE` snapshot is a documented
  precondition, not a check.
- A borrow on a container of another heap's region allocates in this heap's
  instance of that number. Legal under the documented discipline (a leaf is
  one thread's; a trunk resets globally) — once F8 makes the region live on
  the heap that borrows.

## How the issues are ranked

A leak is a robustness failure, and it is ranked with a corruption, not
below it. A bounded program that leaks becomes an unbounded program: it dies
of memory exhaustion, and the only recovery is a restart of the process. A
leak that no code path can undo is worse than one a later collection clears.

The first version of this plan ranked the leaks below the corruptions and
described them as a cost. That was wrong, and the ranking below is the
corrected one.

## The rule that every issue is measured against

Rule 3 of the design says a reference from an older region into a younger
one is an escape. Rule 4 says the write barrier catches such a store and
quarantines the child's region. An issue below is a hole when a store that
breaks rule 3 does not reach the barrier, or when the runtime frees a region
that rule 4 already condemned.

An invariant carries most of the runtime: **the runtime's own objects are
always region 0**, because the branch forces region 0 around inference,
compilation, a dispatch cache miss, and a type instantiation. A region-0
child is legal under any parent. This invariant is why most unbarriered
stores in the runtime are harmless. It is load-bearing and it is not written
down. Write it down (see I9).

## The issues

### I1 — The constructor stores of the C runtime do not run the region check

**Rank: first. Class: correctness and safety.**

The generational shortcut "the parent is fresh, so no barrier is needed" is
inverted for a region. A fresh parent takes the **current** region. The
child can come from an **earlier** window. The hole opens when the window is
closed, the parent is region 0, and the child survived an earlier window.
The compiled path was fixed for exactly this (stock-path change S4 forces
`need_wb = true` in `emit_new_struct`). The C constructors were not.

Three barrier entry points are empty functions, so a store they annotate
runs no region check:

| Entry | Where | Its generational reason |
| --- | --- | --- |
| `jl_gc_wb_fresh` | `src/gc-interface.h:255` | the parent is young |
| `jl_gc_wb_current_task` | `src/gc-interface.h:262` | the parent is in the remembered set |
| `jl_gc_wb_knownold` | `src/gc-interface.h:265` | the child is old |

None of the three reasons says anything about a region.

Two more barriers carry no region check, and they move many references at
once:

- `jl_gc_wb_genericmemory_copy_boxed`, `src/gc-wb-stock.h:66`, called by
  `jl_genericmemory_copyto`, `src/genericmemory.c:234`. `Base.copyto!`
  reaches it through `base/genericmemory.jl:143`.
- `jl_gc_wb_genericmemory_copy_ptr`, `src/gc-wb-stock.h:115`, called at
  `src/genericmemory.c:250`.

`jl_gc_wb_back`, `src/gc-wb-stock.h:39`, takes no child, so it cannot check.
Its sites are `src/task.c:514` and `src/gc-stock.c:1608` and `:1630`.

**The sites that carry a user value.** These are the ones a program can
reach with a region object as the child:

| Site | What it stores |
| --- | --- |
| `src/task.c:1142` | `t->start`, the closure the task runs |
| `src/task.c:1144` | `t->donenotify` |
| `src/task.c:1147` | `t->scope`, through `jl_gc_wb_fresh` |
| `src/opaque_closure.c:128` | `oc->captures`, the captured environment |
| `src/genericmemory.c:285` | the element copy of `jl_genericmemory_copy_slice`, which is `copy` of an array, with no barrier of any kind |
| `src/genericmemory.c:234`, `:250` | the element copy of `copyto!` |
| `src/genericmemory.c:309` | `m->mem` of `jl_new_memoryref` |
| `src/genericmemory.c:113` | the owner field of `jl_string_to_genericmemory` |
| `src/simplevector.c:44`, `:55`, `:67`, `:105` | the raw element writes of `jl_svec1`, `jl_svec2`, `jl_svec3`, `jl_svec_fill` |
| `src/simplevector.c:96` | the element copy of `jl_svec_copy` |
| `src/interpreter.c:547`, `src/rtutils.c:300`, `:340` | `ct->scope`, through `jl_gc_wb_current_task` |
| `src/codegen.cpp:6288`, `:9573` | `ct->scope` from compiled code, with no barrier at all |
| `src/module.c:184`, `:633`, `:1724`, `:1734` | the `restriction` of a binding partition, through `jl_gc_wb_fresh` |
| `src/gf.c:3212` | the `{f, args, world}` copy of `jl_method_error_bare` |

The sharpest of these is `src/task.c:1142`. The documentation tells the
program to make its tasks **outside** the window. The natural code builds
the closure inside the window and spawns the task outside. That puts a
region child into a stock `Task` with no check.

**Detection gap without a dangling pointer.** The splat path builds its
argument vector with no barrier: `src/builtins.c:761` and the element copy
of `_copy_to`, `src/builtins.c:635`. The elements are the caller's own
arguments, so `f(region_objects...)` is unchecked. The vector dies with the
call, so nothing dangles. What is lost is the report. The comment at
`src/builtins.c:773` states the generational reasoning in full, which makes
it the clearest example of the inverted assumption.

**Not a hole, for the record.** `a->ref.mem = mem` in `_new_array`,
`src/array.c:65`, needs no check: the caller allocates the backing memory
moments before, so the array and its memory always share the current region.
The same holds for `src/ircode.c:643` and `src/builtins.c:1739`.

**Not a hole, by the region-0 invariant.** The unbarriered stores of
`jltypes.c`, `gf.c` (except `jl_method_error_bare`), `method.c`,
`datatype.c`, `staticdata.c` and `toplevel.c` store symbols, modules, types,
methods, code data or image data. All of those are region 0.

**Fix shape.** Give the three empty entry points the region check, and leave
their generational body empty. That closes every annotated site in one edit.
Then add the check, or the annotation, at the sites that write raw. The
owning commit is stage 5, "the escape barrier quarantines the region of an
escaped child".

**Warning: this fix has a price.** The check is one load of the armed flag
and a predicted branch at each site. Two of the sites are hot
(`jl_new_memoryref`, the splat copy). M1 and M2 must run again after the
fix. Read "The cost gate" below before the site list grows.

### I10 — A quarantine leaks the region without bound

**Rank: second. Class: robustness.**

A quarantine stops every path that frees the region, and it stops no path
that fills it.

- `jl_gc_region_reset`, `jl_gc_region_reset_global`, `jl_gc_region_collect`
  and `jl_gc_region_collect_coop` refuse with `EQUARANTINED`
  (`src/gc-regions.c:536`, `:575`, `:871`, `:901`).
- The allocator's own census declines a quarantined region
  (`src/gc-regions.c:950`), so the growth bound of stage 10 is off as well.
- The stock sweep never sweeps a region page (`src/gc-stock.c:1078`).
- `jl_gc_region_set` does **not** refuse a quarantined region
  (`src/gc-regions.c:433`), so the program keeps opening windows on it.
- The mark is process-wide and permanent, and no entry point clears it
  (`src/gc-regions.c:45`).

So an event loop whose region is quarantined by one innocuous store runs
correctly and grows at the rate of the loop until the process dies. This is
the common outcome of a rule violation, not a rare one: it follows every
escape, including the `push!` on a long-lived vector that a reviewer named.

**Fix shape, three parts, each usable alone.**

1. Refuse a window on a quarantined region, or refuse the second one. A
   program that ignores the printed line then fails fast at its next window
   instead of at its memory limit. This changes an entry point's contract,
   so it needs a line in the API table.
2. Give the program a way to see the state at the boundary of its unit of
   work. `jl_gc_region_quarantined(n)` exists; `regions.jl` must wrap it,
   and the documentation must tell a server loop to test it.
3. Let a program recover the memory when it can prove the escaped reference
   is gone. A `jl_gc_region_uncondemn(n)` that runs the debug root check,
   walks the heap for a reference into the region, and clears the bit when
   it finds none, would turn a permanent leak into a recoverable one. This
   is a new entry point. Decide it separately from parts 1 and 2.

The owning commit for parts 1 and 2 is stage 5, "the escape barrier
quarantines the region of an escaped child". Part 3 needs its own design.

### I11 — A quarantined region pins stock memory through its finalizer list

**Rank: third. Class: robustness.**

`jl_gc_region_mark_finalizer_lists` marks the finalizer list of every
initialized region as a root of the stock mark
(`src/gc-regions.c:357`). Only a reset or a census drains that list, and a
quarantine refuses both. So every pair the program registered on the region
stays a root for the life of the process, and so does everything the
finalizer function captures. Those closures are region-0 objects, so the
leak reaches the stock heap: a quarantine costs more than the region's own
pages.

**Fix shape.** Decide what a quarantine means for a finalizer. Either run
the finalizers of a quarantined region once, on whole objects, and drop the
list, or state in the documentation that a quarantine pins the list and give
the program a way to see it. The owning commit is stage 4, which owns the
reset that drains the list today.

### I12 — Parked pages and the stock heuristic

**Rank: after the three above. Class: robustness.**

A reset parks the region's pages for the next window on that region
(`src/gc-regions.c:504`). The pages never return to the operating system,
and they never return to the stock pool either. The documentation states
the first half. The second half matters as much: a program that uses a
region for one phase and then never again holds those pages for its whole
run.

The collector's heuristic reads `gc_heap_stats.heap_size`, which counts
every region page, parked or in use (developer documentation, "Counters").
So a large parked region raises the heap size the stock collector aims at,
and the stock collector runs against memory it can never reclaim.

**Fix shape.** Return a region's parked pages to the stock free list at a
reset, or at a second reset that finds them still parked. Measure the cost:
the O(1) reset relies on the park, so a return must not walk the chain in
the hot path. State the interaction with `heap_size` in the Counters
section whatever the outcome.

### I2 — The reset frees a region a finalizer quarantined

**Rank: fourth. Class: correctness and safety.**

`jl_gc_region_reset` tests the quarantine at `src/gc-regions.c:536` and runs
the debug root check at `:545`. It then calls `region_reset_heap`, which
runs the region's own finalizers at `src/gc-regions.c:494` and frees the
pages at `:499`. A finalizer runs arbitrary Julia code with the barrier
armed. A finalizer that stores a region object into a stock object
quarantines the region, and the reset, already past its check, frees the
pages under that reference.

The global reset is immune: it refuses a region with pending finalizers
(`EFINALIZERS`).

No test covers the case. `test/gc/regions_escape.jl` has no finalizer, and
the finalizer of `test/gc/regions_lifetime.jl:147` stores a fresh region-0
object.

**Fix shape.** Read the quarantine again after the finalizer list ran. Keep
the pages and return `EQUARANTINED` when it is set. The owning commit is
stage 4, "reset a region in O(1)".

### I3 — Two cooperative censuses can pass the same gate

**Rank: fifth. Class: correctness.**

`jl_gc_region_collect_coop` reads the window count at
`src/gc-regions.c:904` and increments it at `:909`. The read and the
increment are not one act, so two threads can both pass. Both then write the
one process-wide filter `jl_gc_region_census_target` and share the one
`region_census_tasks` table. A census that marks with another region's
filter sweeps live objects.

The stop-the-world census is safe: `jl_safepoint_start_gc` serializes it,
and the loser gets `ERACE`.

**Fix shape.** Replace the read and the increment by one compare-exchange on
a dedicated flag, or by a compare-exchange from 0 to 1 on the window count.
The owning commit is stage 7, "the census collects one region alone".

### I4 — A task that dies inside a window leaks the window count

**Rank: sixth. Class: robustness.** The consequence is a leak as well as a
refusal: with the census and the global reset disabled, a region that the
program meant to census grows without bound.

Only `jl_gc_region_set(0)` decrements `region_windows_open`
(`src/gc-regions.c:452`), and no task-exit hook closes a window. A task that
dies with a window open leaves the count above zero for the life of the
process. From then on `jl_gc_region_collect`, `jl_gc_region_collect_coop`,
`jl_gc_region_reset_global`, `jl_gc_region_declare_parent` and
`jl_gc_region_check` return `EBUSY`. There is no recovery.

The macro `@with_region` of `contrib/memory-regions/regions.jl` protects
with `try`/`finally`. The raw entry, which the documentation calls the
interface, does not.

**Fix shape.** Close the window of a task that finishes. The task switch
already carries the state (`jl_gc_region_task_switch`,
`src/gc-regions.h:151`), so the exit path can decrement the count for a task
whose `region` field is not 0. The owning commit is stage 6, "a window
belongs to its task".

### I13 — The reset is unchecked, and it is the plain name

**Rank: first among the design changes. Class: safety.**

The barrier sees the heap. It does not see the stack. A reference to a
region object in a stack slot, in a register, or on the stack of a parked
task is invisible, and `jl_gc_region_reset` frees the region under it. The
next collection meets the freed cell and aborts with `CORPSE`. The reset is
the last unchecked operation of the design: it is `free()` with a warning
label, and it carries the plain name.

The runtime holds both halves of the answer already. `jl_gc_region_check(n)`
stops the world, marks from the execution roots with the region filter, and
counts every marked cell of the region. `jl_gc_region_reset(n)` frees. A
checked reset is the two in one call.

Today the check runs only behind `jl_gc_region_set_debug`, a process-wide
flag. That is the wrong shape. A flag is global, so a library cannot choose
per call site, and a reader of the code cannot tell which behaviour a given
reset got.

**Fix shape. Two entries, not a mode.**

1. `jl_gc_region_reset(n)` checks the roots and refuses with `EROOT` when
   one points into the region.
2. `jl_gc_region_unsafe_reset(n)` is today's reset. A program types the
   longer name on purpose, and a review sees it.
3. The check and the free run in **one** stop-the-world pause. Two calls
   would mean two pauses and a gap between them.
4. `jl_gc_region_set_debug` goes away, or it keeps only the extra reporting.
   The behaviour it used to select is now the default.
5. `regions.jl` follows with `region_reset` and `unsafe_region_reset`, and
   `@with_region` uses the safe one.

The plain name must be the safe one. A reader who does not know the model
must land on the safe entry by default.

**What it does not fix.** A reset with no live root today still has no live
root after the change; the check refuses a program that was already wrong.
The parked-task case of the deferred list is caught by the same scan,
because a parked task's stack is an execution root.

**The measurement that this needs.** The cost of the scan is not measured. A
region that is empty at its reset finds nothing in the heap, so the cost is
the root walk over the task stacks, not the live set. M5 puts a whole scoped
census at about 5 µs at a small live set, so the scan alone should be a few
microseconds and near constant in the region's size. Measure it on the M3
and M4 loops, at one thread and at four, and add the row to
`MEASUREMENTS.md`. The number does not decide the design any more. It
decides which entry the demonstrators use, and it must be published, because
a reader will ask what the safe default costs.

The owning commit is stage 4, "reset a region in O(1)", with the check that
stage 13 owns moved forward or shared.

### I5 — Guards that detect but do not prevent

**Class: robustness.**

- `jl_gc_free_page` prints `FREEPAGE-TAGGED … a tagged page must never
  free` and then frees the page (`src/gc-pages.c:235`). The guard names the
  violation and lets the harm happen. Make it keep the page.
- `gc_setmark_pool` calls `abort()` on a pool object with no page metadata
  (`src/gc-stock.c:337`). It runs in every program, region or not, and it
  ends the process without a Julia backtrace. Keep the diagnosis; decide
  whether an abort or the stock fault is the better end. This is recorded as
  stock-path change S3, so a change here needs its own line in `HISTORY.md`.

### I6 — Races on shared state

**Class: robustness.**

- `jl_gc_region_declare_parent` checks the window count and every heap's
  live mask, then writes `region_parent[]` and rebuilds the eight
  `region_uptree[]` entries with relaxed stores (`src/gc-regions.c:126`). A
  window that opens on another thread in that gap reads a half-built tree.
  The declaration is a startup act, so the likelihood is low.
- `region_collect_stats[8]` (`src/gc-regions.c:66`) is a plain global. Two
  censuses on two threads interleave their numbers.
- `jl_gc_region_census_page_threshold` (`src/gc-regions.c:78`) is a plain
  `int` written from one thread and read on the allocation path of every
  thread.
- The armed flag is stored with release and read relaxed. On x86-64 that is
  enough. The cost is measured on x86-64 only; on a weaker memory model
  another thread can miss the arming for a while.

### I7 — Cross-heap effects

**Class: robustness.**

- A census marks region objects on **every** heap, because
  `region_census_mark` walks the execution roots of every thread
  (`src/gc-regions.c:793`), and `region_scoped_sweep` clears the marks of
  the calling heap alone. A stale mark makes a dead cell look live on the
  other heap, so its census keeps the cell. The leak is bounded: the next
  stock collection clears the marks. A program that never runs a stock
  collection, which is the point of the region model, never clears them.
- `jl_gc_region_reset` does not test whether another heap holds the same
  region. "Use the global reset for a region several threads fill" is a
  limit in the documentation, not a refusal in the code.

### I8 — The cost that the Cost section does not name

**Class: documentation.**

Each thread heap carries eight full pool arrays (`regions[8]`, each with
`jl_gc_pool_t pools[51]`), about 10 KB per thread, plus the masks and the
child counts (`src/gc-tls-stock.h:40`). Every page metadata grows by
`region_n` and `region_next`. Both costs are unconditional. Name them in the
Cost section of the developer documentation.

### I9 — Two rules the documentation does not state

**Class: documentation.**

- **The region-0 invariant.** The runtime's own objects are always region 0,
  because the forced region-0 zones put them there, and a region-0 child is
  legal under any parent. This is why the unbarriered stores of the type
  system and the method table are sound. State it next to rule 4. Anyone who
  removes a forced zone opens a class of missed escapes at once.
- **The barrier sees managed stores only.** A store from C code, and
  `unsafe_store!`, are invisible. Add the rule to "Discipline the barrier
  does not remove".

## Decisions

- **D1. Fix the bug, do not add a feature.** Every change of this plan
  closes a hole that exists. The one exception is I13, which renames the
  reset and makes the check the default. It adds no capability; it changes
  which behaviour a program gets when it does not choose.
- **D2. Each fix goes into its owning stage.** The series is a staged
  reveal; a fix that lands as a later commit would leave its own stage
  wrong. Take the stages again with `retake.sh` of
  `workspace/julia-gc-series-tooling`, as D17 of the tidy plan did. The
  owning stage of each fix is named above.
- **D3. The tests go into stage 14.** The test commit is one commit
  ("regions: the tests"), whatever stage the fix belongs to.
- **D4. A test comes before its fix.** Each issue needs a test that fails on
  `d543cb834a` first. An issue whose test cannot be made to fail is reported
  as such and is not "fixed".
- **D5. The cost gate decides the width of I1.** See below.

## The cost gate

I1 widens the barrier to sites that pay nothing today. The claim "the cost
when unused is small" is measured, published in `MEASUREMENTS.md`, and it is
the first thing a reviewer will test. So:

1. Fix the three empty entry points first, and measure.
2. Run M1 (`bench/gcbench.sh`) and M2 (`bench/unit_costs.jl`) against the
   same vanilla binary the tables used.
3. Accept the fix when `store_disarmed`, `construct_two`, `alloc_stock` and
   the GCBenchmark ratios stay inside the spread the tables record.
4. If a row moves outside its spread, cut the site list to the sites that
   can carry a user value, and measure again.
5. Update the tables and the Cost section with the new numbers. A cost that
   grew must appear in the tables, not in prose alone.

## Steps

### Step 1 — Reproduce

- [x] Write a failing test for I1 with a task: build a closure inside a
      window, spawn the task outside, reset, and read the closure. Expect a
      `CORPSE` abort or a wrong value today.
- [x] Write a failing test for I1 with `copy` and with `copyto!` on a
      `Vector{Any}`: copy region objects into a region-0 vector, reset, and
      read. Assert that the region is quarantined; today it is not.
- [x] Write a failing test for I2: register a finalizer on a region object
      whose body stores the object into a global, then reset. Assert that
      the reset returns `EQUARANTINED`; today it frees.
- [x] Write a failing test for I4: run a task that opens a window and throws
      past it, then assert that `jl_gc_region_collect` does not return
      `EBUSY`.
- [x] Write a failing test for I10: quarantine a region, then allocate in it
      in a loop and assert that `jl_gc_region_pages` stops growing. It grows
      without bound today.
- [x] Write a failing test for I11: register a finalizer on a region object,
      quarantine the region, drop every reference, run `GC.gc()` twice, and
      assert that the finalizer closure is collected. It is pinned today.
- [x] Record which tests fail as expected and which do not. An issue whose
      test passes today is downgraded and its entry above is corrected.
- [x] I3, I6 and I7 need a race or several heaps. Write a stress script for
      I3 if one can be made to fail in a bounded time; otherwise fix by
      inspection and say so.

### Step 2 — Fix, one commit per issue, on the flat tree

Work on the flat worktree `workspace/julia-gc-regions`, as the tidy plan
did. Build with `nice -n 10 taskset -c 16-23 make -j8`.

- [x] I1 part 1: the region check in `jl_gc_wb_fresh`,
      `jl_gc_wb_current_task` and `jl_gc_wb_knownold`.
- [x] I1 part 2: the region check in the two `GenericMemory` copy barriers.
- [x] I1 part 3: the sites that write raw, from the table above.
- [ ] Run the cost gate. Record the numbers.
- [x] I2: the second quarantine test after the finalizers.
- [x] I3: one compare-exchange.
- [x] I4: close the window of a task that finishes.
- [x] I13: one entry that checks and frees in one pause, and
      `jl_gc_region_unsafe_reset` for the program that opts out. Measure the
      scan on the M3 and M4 loops and publish the row.
- [x] I10 parts 1 and 2: refuse a window on a quarantined region; wrap the
      state in `regions.jl` and say in the documentation that a loop must
      test it.
- [ ] I11: decide what a quarantine means for a finalizer list, and make the
      code and the documentation agree.
- [ ] I12: measure what the parked pages cost a long run, then decide
      whether a reset returns them.
- [x] I5: keep a tagged page instead of freeing it; decide the abort.
- [x] I6: atomics for the two globals; make the declaration atomic against a
      window.
- [x] I7: clear the marks the census set on other heaps, or refuse a census
      of a region that another heap holds. Choose one and say why.
- [x] I8 and I9: the documentation.

### Step 2b — The findings of the second review, on `gc-regions-fixes`

One commit per finding, the test in the same commit, each test shown to
fail on `55ef64ed29` first. Done: eight fix commits `5c2cbf01d3..14dc151267`
on `gc-regions-fixes` (F1 and F3 share one commit, because the global
reset needs the cleared root scan), then `9d4de2bc69` for the documents
and `f413f39068` for a verify check in the containers script.
The committed tree is the tree that the sweep tested: every one of the
23 changed files compares identical to the tested copy.

- [x] F1: `region_clear_marks_on_other_heaps` in `region_root_scan`;
      `test/gc/regions_heaps.jl`.
- [x] F7: `ECHILD` in the three census entries; a case in
      `regions_census.jl`.
- [x] F2: the per-element fallback of the pair checks; a case in
      `regions_stores.jl`.
- [x] F3: the root scan in the global reset; a case in `regions_tree.jl`.
- [x] F4: the bounded finalizer loop of the checked reset; a case in
      `regions_lifetime.jl`.
- [x] F5: the borrow of region 0 around a `Binding` allocation; a case in
      `regions_window.jl`.
- [x] F6: the borrows at the five sites; cases in `regions_containers.jl`.
- [x] F8: `jl_gc_region_install_borrow`; the borrow round in
      `regions_heaps.jl`.
- [x] F9: the borrow of the task's region in `jl_reserve_excstack`; the
      first-throw case in `regions_window.jl`.
- [x] The documents follow: the devdoc's binding claim, the `ERACE`
      sentence, `HISTORY.md` rows, the devdoc's "A replacement buffer"
      section (the F6 sites), the bulk-copy explanation (F2), the exception
      stack (F9), the toplevel bullet (the F5 probe), the Files table.
- [x] The regions scripts pass at every harness configuration: threads 1, 2,
      4, each with 0 and 1 interactive thread (`regions_heaps` skips at one
      thread).

Two tests changed while the fixes landed, both because a test held the
fault it tested for. `tree_multithread_leaves` reset the trunk globally from
the frame that held the trunk object, and the F3 root scan refused it with
`EROOT`, which is the right answer: the build now runs in
`tree_run_workers`, and the reset follows its return. `tree_park_with_trunk`
read its object as `t.f` only, so the compiler scalar-replaced the object and
nothing was on the frame; the case now passes the object through `escape`,
which forces the allocation. The F5 case reads its new binding with
`Base.invokelatest(getglobal, ...)`, because the definition is in a newer
world than the function.

### Step 3 — Fold into the series

The fold also carries the two commits of `region-gc-64-regions.md`,
`1e71388e75` (the constant, the mask, the tests) and `75fd633ce8` (the
documents), which sit on `gc-regions-fixes` after the fix commits. They
belong to the stage that owns `gc-tls-stock.h` and `regions_api.jl`. The
two commits of `region-gc-lazy-region-state.md` follow them: `c061421172`
(the pointer table, `jl_gc_region_state_t`, the sites, the test) and
`025b0e8557` (the documents). They touch `gc-tls-stock.h`, `gc-regions.c`,
`gc-regions.h`, `gc-stock.c` and `regions_window.jl`, and belong to the
stage that owns the per-heap region table. One more commit follows,
`06a511ed9d`: it adds `contrib/memory-regions/COST.md`, the cost of the
unused runtime with the switches, and points to it from the README's
documents table and the devdoc's Cost section. It is a documents-only
commit and belongs to the stage that adds the measurement documents. Its
timing rows are the last M1 and M2 run on the shared machine; the rerun on
an idle machine refreshes them by hand, because `results/tables.py`
rewrites `MEASUREMENTS.md` alone. The last commit of the branch is
`19eee113c7`, the construction-only barrier of
`region-gc-construction-barrier.md`: the intrinsic
`julia.region_write_barrier` in `codegen.cpp`, `cgutils.cpp`,
`llvm-pass-helpers.{h,cpp}`, `llvm-late-gc-lowering.cpp`,
`llvm-alloc-opt.cpp`, `llvm-alloc-helpers.cpp` and `llvm-julia-licm.cpp`,
with its test in `regions_escape.jl`, the `construct_shared` row of
`bench/unit_costs.jl` and `results/tables.py`, and the corrected cost
prose of COST.md, MEASUREMENTS.md, README.md, HISTORY.md and the devdoc.
The compiler files belong to the stage that adds the escape barrier to the
compiler; the bench and the documents to the stage of the measurement
documents. After it comes `e3eb502bb4`, the fresh-object copies of
`region-gc-fresh-object-copies.md`: the `nocapture` parent of the intrinsic
in `codegen.cpp`, the inline-field and box paths of `cgutils.cpp` and
`intrinsics.cpp`, the fourth annotation `jl_gc_multi_wb_fresh` in
`gc-interface.h`, `gc-wb-stock.h` and `gc-wb-mmtk.h`, and the runtime
sites in `datatype.c`, `genericmemory.c`, `runtime_intrinsics.c`,
`builtins.c`, `jltypes.c` and `method.c`, with the tests in
`regions_escape.jl`, the `box_twin` row of `bench/unit_costs.jl` and
`results/tables.py`, and the prose of the devdoc and HISTORY.md. The
compiler files and the runtime sites belong to the stages that add the
escape barrier to the compiler and to the runtime; the bench and the
documents to the stage of the measurement documents.

- [ ] Map each flat commit to its owning stage with `xstage.py`.
- [ ] Move the annotated markers in `annotated/` of the tooling repository so
      each change appears at its stage.
- [ ] `reveal.py check` passes.
- [ ] `retake.sh <worktree> <commit before the first stage> <first stage>`
      from the lowest stage that changed. Stage 4 is the lowest one this plan
      touches, so commits 1 to 3 keep their SHAs.
- [ ] Check 1: the tree of the branch equals the tree of the flat tag.

### Step 4 — The gate

- [ ] Check 2 and Check 3 with `check23.sh <first stage>`: every commit
      builds, `julia -e 1` runs, and the five region scripts pass at commit
      13.
- [ ] The `gc` group on the tip binary: 0 fail, 0 error.
- [ ] `core threads misc` on the tip binary. I1 changes the code of the
      default build, so the result of the third cut does **not** carry over.
- [ ] `make -C doc html` builds.
- [ ] M1 and M2 again, with the tables and the Cost section updated.

### Step 5 — Close

- [ ] Add a bug row for each fixed issue to `HISTORY.md`, in the shape the
      B-numbers use, and a stock-path row for I5 if the abort changes.
- [ ] Update the pull request text in `region-gc-tidy.md` if a cost number
      moved.
- [ ] Push `gc-regions` with `--force-with-lease`, and the flat tag.
- [ ] Move this plan to `plan/done/`.

## Acceptance

- Every test of Step 1 that failed on `d543cb834a` passes on the tip.
- The gate of Step 4 is green.
- The cost rows of M1 and M2 stay inside their spread, or the tables carry
  the new numbers and the Cost section explains them.
- `HISTORY.md` names every issue this plan closed, and the developer
  documentation carries I8 and I9.

## Risks

- **The barrier grows wider than the measurements allow.** The cost gate is
  the control. The fallback is a smaller site list, and an honest sentence
  that says which stores stay unchecked.
- **A re-cut costs a full check.** Check 2 and Check 3 over commits 4 to 20
  take about 90 minutes of builds. Run them on cores 16 to 23 with `nice`,
  and never on the timing cores.
- **A fix at stage 4 or 5 moves eighteen commit SHAs.** Everything that
  names a SHA — this plan, the tidy plan, `HISTORY.md`, the memory — must be
  updated in the same pass.
- **A test for I1 can abort the test process** when it reproduces a
  `CORPSE`. Run such a test as its own process, the way `test/gc.jl` runs
  the region scripts.

## Out of scope

- Any new region feature. The eight-region cap, the one-heap rule, the
  missing `Base` API and the permanent quarantine stay as they are.
- The standing discipline rules the documentation already states: a closed
  window before a reset, no top-level window, an exception caught inside the
  window, no blocking, tasks made outside, no `WeakRef`, no serialization.
- The deferred item of `HISTORY.md`: a per-region count of open windows, so
  a reset can see a parked task of the same thread. It is a real gap; it
  needs a design, not a fix.
