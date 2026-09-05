# GC regions

A region is a numbered set of pool pages with its own allocation cursors. A
thread allocates into region `n` while a window on `n` is open, and frees every
object of the region at once with a reset, without a trace. The stock collector
implements the regions (`src/gc-regions.c`, `src/gc-regions.h`). A program that opens no window runs on the stock collector unchanged.

## The goal

A program that repeats one unit of work many times, and whose garbage dies at
the end of each unit, pays for a tracing collection it does not need. The
example the design is built for is a discrete event simulator with a time
budget of 100 µs per event, or a hardware-in-the-loop loop with the same
budget. The stock collector pauses such a program for milliseconds at moments
the program does not choose.

A region gives that program a second way to free memory. The program opens a
window on a region before the unit of work, and resets the region after it.
The reset frees every object the unit allocated in constant time per page.
Nothing is traced, nothing is moved, and the stock collector does not run.

The mechanism extends the runtime; it does not fork it. Every object outside a
window is a stock object. The stock collector runs with regions present, and
frees the stock objects that region objects reference when nothing else does.

## The model

Every managed object belongs to exactly one region for its whole lifetime.
Region 0 is the stock heap. Regions 1 to `JL_GC_MAX_REGIONS - 1` (63) are the
regions a program can open. There is no promotion and no migration.

The regions form a tree of lifetimes. The parent of a region lives at least as
long as the region. The default tree is the chain `0 <- 1 <- 2 <- ...`: region
1 outlives region 2, and so on. A program can declare another tree
([The tree](@ref gc-regions-tree)).

**The one rule.** A managed reference `a -> b` is legal when the region of `b`
is the region of `a` or one of its ancestors. An object can reference objects
that live at least as long as itself. A reference from an older region into a
younger one is an escape.

Because of the rule, no object outside a region references into it, except a
younger descendant. When the descendants are already reset, a reset of the
region frees every object of it without a trace: no live object can hold a
reference into the region.

## The six rules

1. **Ownership.** Every managed object belongs to exactly one region.
2. **Allocation.** Every pool allocation goes into the region of the open
   window of the thread. This includes the allocations the compiler makes:
   tuples, closures, boxes, arrays, exceptions. A buffer that replaces the
   buffer of an object that exists is the exception: it goes into the region
   of that object, whatever window is open (see "A replacement buffer").
3. **Reference monotonicity.** For every managed reference `a -> b`, the
   region of `b` is the region of `a` or one of its ancestors.
4. **Write enforcement.** Every managed pointer store checks rule 3 while a
   region is in use. A store that breaks the rule quarantines the region of
   the child, process-wide and permanently. A scalar store needs no check.
5. **Reset precondition.** A region is reset only when no execution root
   references into it and no live child region exists. Rule 3 guarantees that
   no older region references into it.
6. **Collection roots.** A collection of one region needs two root sets: the
   execution roots of every task, and the younger regions. No heap reference
   from an older region exists (rule 3).

Rule 4 makes the design different from a generational collector. A
generational write barrier records a store that makes collection harder. This
barrier rejects a store that makes a reset unsafe.

Two facts carry the rest of the runtime, and neither is a check.

**The runtime's own objects are region 0.** Inference, compilation, a
dispatch cache miss and a type instantiation all run with region 0 forced
(`gf.c`, `jltypes.c`), so a method, a type and a code instance are region-0
objects. A binding is made where a name is first looked up, which can be
inside a window, so `jl_get_module_binding` and `new_binding_partition`
(`module.c`) allocate the `Binding` and its partition under a borrow of
region 0. The exception stack of a task is made at the task's first throw,
which can be inside a window, and the task keeps it for every later throw, so
`jl_reserve_excstack` (`rtutils.c`) allocates it under a borrow of the task's
region. The saved stack of a copy-stack task needs no such care: it is larger
than the pool limit, so it is a big object and belongs to region 0 (see
"Finalizers and malloc'd data"). Rule 3 makes a region-0 child legal under any
parent, so the many
stores in the type system and the method table that carry no barrier cannot
break the rule. Anyone who removes one of those forced zones opens a class of
missed escapes at once.

**The barrier sees a managed store and nothing else.** A store from C code,
an `unsafe_store!`, and a pointer a foreign library keeps are all invisible.
A region object handed to C and stored there dangles at the reset with no
report.

## The barrier

The compiler emits the escape barrier at every managed pointer store of a
boxed child, next to the generational write barrier
(`src/llvm-late-gc-lowering.cpp`, `src/cgutils.cpp`). The barrier is one load of
the flag `jl_gc_region_barrier_on` and a well-predicted branch. The first
window of the process arms the flag, and it stays armed. Before the first
window, the barrier is the load and the branch only.

With the flag armed, the store calls `jl_gc_region_wb(parent, child)`. The
call reads the region of the child from its page tag. A child of region 0 is
legal under any parent, and almost every store in ordinary code has one, so
the common case pays one page-map walk. A child of region `cr` under a parent
of region `pr` is legal when `cr` is in the uptree bitset of `pr`: `pr` itself
and its ancestors.

An illegal store quarantines region `cr`: the runtime prints one
`REGION-ESCAPE` line, sets the bit of `cr` in the process-wide quarantined
mask, and keeps the memory of the region. A reset and a census of a
quarantined region refuse with `EQUARANTINED`. The program keeps its memory
safety: the store stays, and the region never frees under the reference.

`jl_gc_wb` in `src/gc-wb-stock.h` runs the same check for the stores of the
C runtime and of the builtins.

A bulk copy moves many references in one act: `copyto!` and `copy` of a
`Memory` with references (`jl_genericmemory_copyto`,
`jl_genericmemory_copy_slice`), `jl_svec_copy`, and the store of an inline
immutable with pointer fields (`jl_gc_multi_wb`). Each one checks the pair
(destination, source) first. Every element of the source keeps the rule
against the source, so a source that is legal under the destination makes
every element legal under it, and the copy pays one check. The converse does
not hold: a young container of old elements — a `filter` made inside a
window and appended to an old vector after the window closed — fails the
pair, and the copy is legal. So a failed pair decides nothing; the check then
walks the copied references, or the pointer fields of each copied element,
and quarantines only a real escape.

## A replacement buffer

A container that grows does not make a new object: it replaces the buffer
behind an object that exists. The new buffer takes the lifetime of that
object, so it takes its region, whatever window happens to be open. Without
the rule, a `push!` to a long-lived vector inside a window would put the new
`Memory` in the window's region, an older array would hold a younger object,
and the barrier would quarantine the region for an operation the program has
every right to make.

The region comes from the **container**, never from the old buffer. An empty
container shares one permanent empty `Memory` that belongs to region 0, so a
container made inside a window starts with a region-0 buffer, and its first
growth must land where the container lives.

`jl_gc_region_borrow(n)` gives region `n` to the next allocations of the
thread and returns the region it replaced; `jl_gc_region_unborrow` gives that
region back. A borrow is not a window: it changes no window state, so the
count of open windows, the task's own region and the task's stickiness stay
as they were. `jl_gc_region_suspend` is the borrow of region 0.

Three rules for a borrow. Keep it short, around one allocation. Do not yield
inside one, because a task switch would save the borrowed region as the
task's window. Always give it back in a `finally`.

A borrow makes the region live on the heap that borrows
(`jl_gc_region_install_borrow`). A thread that grows a container of another
thread's region takes pages of that region on its own heap, and from that
moment its resets of the region's parent see the region as a live child.

The places that follow the rule are `array_new_memory_for` in `base/array.jl`,
which every array growth passes through and with it `push!`, `pushfirst!`,
`append!`, `insert!`, `resize!`, the data of a `Channel` and the chunks of a
`BitVector`; `jl_array_grow_end` in `src/array.c`, the growth the runtime's
own `jl_array_ptr_1d_push` callers use; `rehash!` in `base/dict.jl`;
`jl_idtable_rehash` and `empty!` for an `IdDict`; the key list and the index
table of an `IdSet` in `push!`; and the growth of an `IOBuffer`, with the new
data that a write or a `truncate` makes after a `take!`. A container written
elsewhere follows the rule with the same pair, or its growth stays an escape.

The rule covers the buffer. It does not cover the **elements**: a region
object stored into a long-lived container outlives its region, and the
barrier is right to quarantine it.

## The reset

`jl_gc_region_reset` runs four phases, and each one sees the result of the
one before.

1. The preconditions: a valid region, no window on it, no pending finalizer
   run on this thread, no quarantine, no live child.
2. The finalizers of the region, which run Julia code with the barrier armed.
   A finalizer can register a finalizer on another object of the region, so
   the phase runs rounds until the list is empty, and refuses with
   `EFINALIZERS` after 64 rounds. No Julia code runs after this phase.
3. The quarantine, read again. A finalizer that stores one of its own objects
   into an older region condemns this region, and a reset that freed after
   that would leave the published reference dangling.
4. The root check and the free, in one stop-the-world pause. No finalizer is
   left to run, so the pause holds through the free.

The root check is what stands between a live local and a freed object,
because the barrier sees the heap and not the stack. It marks from the
execution roots of every thread with the region filter and counts the marked
cells of the region; a count above zero refuses the reset with `EROOT`.
`jl_gc_region_set_debug(1)` makes the runtime name the objects it found. The
marks the scan leaves on the other heaps' instances of the region are
cleared before the pause ends: two threads that use one region number each
on their own heap must not see each other's marks at their next reset or
census. `jl_gc_region_reset_global` runs the same root check, over every
heap's instance of the region, inside its own pause.

**The reset must not run in a frame that still names the region's objects.**
A Julia frame roots a local until the frame ends, whether or not the program
reads it again, so a function that builds in a window and resets afterwards
refuses its own reset. Build and use the region's objects in one function,
and reset after that function returned.

Several threads that reset their own leaves collide on the safepoint, so a
reset that loses the race waits for the winner and tries again. `ERACE` comes
back after 1024 lost attempts. It is a refusal like the others: the region is
intact, and the caller resets it again later.

`jl_gc_region_unsafe_reset` frees with no pause and no scan. A reference from
a stack slot, a register or a parked task's stack is then left pointing into
freed memory, and the next collection reports `CORPSE` and aborts. Use it
where the pause is the thing being measured, or in a loop that has shown with
the checked entry that no root survives its window. The benchmarks and the
demonstrators of `contrib/memory-regions` use it for that reason.

## The API

Every entry point takes region numbers. The numbering and its meaning belong
to the program. The entries are `ccall` targets; there is no `Base` API.

| Entry | Returns |
|:--|:--|
| `jl_gc_region_set(n)` | Open a window on region `n` on the calling task; `n = 0` closes it. Returns the region that was current, or a refusal code. |
| `jl_gc_region_current()` | The region of the open window, 0 when none. |
| `jl_gc_region_reset(n)` | Free every object of region `n` on the calling thread's heap, after a check that no execution root references into it. Returns the pages the region held (`uint64_t`), or a refusal code cast to `uint64_t`. |
| `jl_gc_region_unsafe_reset(n)` | The same with no check and no pause. A reference from a stack slot, a register or a parked task's stack is left dangling. |
| `jl_gc_region_borrow(n)` | Give region `n` to the next allocations of this thread; returns the region it replaced. Not a window. |
| `jl_gc_region_unborrow(lent)` | Give back the region a borrow replaced. |
| `jl_gc_region_reset_global(n)` | Free region `n` on every heap at once, with the world stopped, after the same root check over every heap's instance. |
| `jl_gc_region_declare_parent(child, parent)` | Declare an edge of the tree before either region is used. Returns 0, or a refusal code. |
| `jl_gc_region_parent_of(child)` | The declared parent. |
| `jl_gc_region_collect(n)` | The stop-the-world census of region `n`: free its dead objects, keep the live ones. Returns the cells freed (`int64_t`), or a refusal code. |
| `jl_gc_region_collect_coop(n)` | The cooperative census: no stop-the-world; every other thread must be parked GC-safe. |
| `jl_gc_region_census_threshold(pages)` | The page count of the open region that triggers a census from the allocator; 0 never. |
| `jl_gc_region_of(v)` | The region of an object. |
| `jl_gc_region_pages(n)` | The pages region `n` holds on the calling thread's heap. |
| `jl_gc_region_quarantined(n)` | 1 when an escape quarantined region `n`. |
| `jl_gc_region_stat(i)` | A field of the last census: 0 total ns, 1 stop-the-world ns, 2 mark ns, 3 sweep ns, 4 live cells, 5 freed cells, 6 pages walked, 7 pages freed wholesale. |
| `jl_gc_region_set_debug(on)` | With reporting on, the reset's root check names the objects it found. The check itself always runs. |
| `jl_gc_region_check(n)` | Run that check alone; returns the count of references, or a refusal code. |
| `jl_gc_region_verify(n)` | Walk the page chains of region `n` for consistency; returns the error count. |
| `jl_gc_heap_reserve(bytes)` | Prefault `bytes` of pool heap so a later allocation never faults. Returns the bytes mapped. |

The refusal codes are negative integers. An entry that returns a count
returns the code cast to its unsigned type: `(uint64_t)-2` stands for `-2`.

| Code | Name | Meaning |
|:--|:--|:--|
| -1 | `EINVAL` | A bad region number, a bad tree edge, or a build that cannot allocate in a region. |
| -2 | `EBUSY` | The region is current, a window is open, or this heap runs region finalizers now. |
| -3 | `ERACE` | Lost the race for the safepoint; retry. |
| -4 | `EUNSAFE` | Another thread runs managed code (cooperative census only). |
| -5 | `EQUARANTINED` | An escape quarantined the region; its memory is retained. |
| -6 | `EFINALIZERS` | Finalizers are pending; a cooperative census runs them first. |
| -7 | `ECHILD` | The region has a live child region. |
| -8 | `EROOT` | The debug check found an execution root that references the region. |

The shape of the loop the design is built for, in Julia:

```julia
const EVENT = 1
region_set(n)   = ccall(:jl_gc_region_set, Cint, (Cint,), n)
region_reset(n) = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)

while running
    region_set(EVENT)
    try
        process_event!(...)         # allocates into region 1
    finally
        region_set(0)
    end
    region_reset(EVENT)             # frees every object of the event
end
```

The reset stands after the window, so no stack slot or register of the loop
references into the region. A result the program keeps is allocated outside
the window, or copied out before the reset.

## The window

A window belongs to the calling task. The window follows the task across a
task switch: the runtime parks the region of the task that leaves and
installs the region of the task that arrives (`jl_gc_region_task_switch`,
called from `src/task.c`). A task with an open window is sticky: the pages of
a region live in the thread heap, so the task must not migrate. The task gets
its stickiness back when the window closes. A new task starts with no window.

A stock collection parks every open window and runs with region 0 installed
on every thread. It installs the windows again when it returns. A finalizer
list runs with region 0 installed, and while it runs no window opens and no
region entry runs on the thread (`EBUSY`).

The runtime's own work runs in region 0. Type inference and compilation
(`jl_type_infer`, `jl_compile_method_internal` in `src/gf.c`), the cache-miss
path of a dynamic dispatch (`jl_lookup_generic_` in `src/gf.c`), and the
cache-miss path of a type instantiation (`inst_datatype_new` in
`src/jltypes.c`) close the window around their work and open it again after.
The objects the runtime makes on the code's behalf, such as a
`MethodInstance`, an argument tuple type, or a new `DataType`, are stock
objects, and the runtime's tables reference them legally. A cache hit pays
nothing for this. An error thrown from this work (a `MethodError`, a bad type
parameter) leaves region 0 current: the exception is a stock object, and the
handler at the window boundary closes the window in any case.

Base keeps lazily initialized state, a value made once per process or once
per thread (`OncePerProcess`, `OncePerThread` in `base/lock.jl`), in tables
that outlive every window, and makes it on behalf of whatever task first
needs it. The scheduler's own state is made this way: the first idle wait on
a thread makes the thread's scheduler task and its sticky work queue, inside
the window of the task that waits when it holds one. The slow path of each
`Once` runs with the window suspended (`jl_gc_region_suspend`,
`jl_gc_region_resume` in `src/gc-common.c`): region 0 is installed, the
window stays open, so the task stays pinned to its thread while the slow path
parks on a lock, and a `finally` installs the window again on every exit. The
C sites above close the window instead: they never park the task, and an
exception past their bracket leaves the window closed, which is coherent.

## [The tree](@id gc-regions-tree)

The default tree is the chain: the parent of region `n` is `n - 1`. A program
declares another tree with `jl_gc_region_declare_parent(child, parent)`. The
parent's number is smaller than the child's; a region is declared before it is
used; no window is open on any thread; no region is live.

With a tree, two leaves over a shared trunk are isolated from each other:
neither leaf can reference the other, only their common ancestors. A leaf on
its own thread holds objects of its own thread heap; a trunk two threads share
holds objects of both heaps, and trunk objects on different heaps reference
each other legally. A trunk is reset with `jl_gc_region_reset_global`, which
stops the world and resets every heap's instance as one act.

A region is live between a window on it and its reset. A reset of a region
with a live child refuses with `ECHILD`: a descendant can hold a legal
reference into it. A census of it refuses for the same reason: the census
filter drops the child's objects, so a parent object that only the child
references would go unmarked and freed. The program resets the leaves first.

## The census

A census is a tracing collection of one region. It frees the dead objects of
the region and keeps the live ones in place. Its roots are the execution roots
of every task (rule 6). It marks only objects of the region: the census filter
`jl_gc_region_census_target` names the region, and the mark loops drop an
out-of-region object at the claim. It sweeps only the pages of the region.

The stop-the-world census (`jl_gc_region_collect`) stops every thread and
scans every task. It refuses with pending region finalizers
(`EFINALIZERS`): the world stays stopped, so nothing can run them. The
cooperative census (`jl_gc_region_collect_coop`) runs with no stop-the-world
when every other thread is parked GC-safe; it scans the tasks of the calling
thread and runs the finalizers of the dead objects after the sweep. Both
refuse while a window is open on any thread (`EBUSY`).

A census leaves the marks and the remsets of the stock collector as it found
them.

## The growth bound

A window whose garbage dies inside the window, not at its boundary, grows the
region without bound. The allocator's census bounds that growth. With
`jl_gc_region_census_threshold(pages)` set, the page claim of a window checks
the page count of the open region; past the threshold it runs a
stop-the-world census of the open region, with the window open. The check is
inline on the page claim path, one comparison. The live objects of the window
survive in place; the dead ones free. Pending finalizers or a quarantine skip
the census, and the page claim goes on.

The threshold is process-wide. The reset stays the common path: a program
whose garbage dies at the boundary never triggers the census.

## The heap reserve

`jl_gc_heap_reserve(bytes)` claims `bytes` of page blocks now, populated, into
the clean pool, and prefaults every block the runtime maps from then on.
`jl_gc_alloc_page` serves the clean pool before it maps anything, so a loop
whose heap fits the reserve maps nothing and faults nothing while it runs. The
call is for a program that measures its pauses in microseconds; a program that
does not can leave it out.

## Finalizers and malloc'd data

A finalizer registered on a region object goes to the list of the region
(`jl_gc_region_add_finalizer`). The reset runs every finalizer of the region
on whole objects before it frees the pages; the census runs the finalizers of
the dead objects. A cross-thread registration on a region object throws.

A `GenericMemory` whose data is malloc'd and whose header is a region object
is tracked by the region (`jl_gc_region_track_malloced`). The reset frees its
data with the region.

An object larger than the pool limit (`GC_MAX_SZCLASS`) is a big object and
belongs to region 0 whatever window is open. A store of a region object into it
is an escape.

## Counters

An allocation in a region counts as an allocation: `gc_num.allocd` grows by
the object size, so `@time` and `Base.gc_num()` report it. `Base.gc_live_bytes()`
adds `allocd` to a running total that only a stock sweep reduces, by the bytes
it frees. A reset parks the pages of the region for reuse and subtracts nothing,
and a stock sweep skips region pages, so nothing ever subtracts a region object: over
a long run the counter grows by every byte allocated through a region, and its
slope is the allocation throughput of the regions, not the live heap. The
collector's heuristics do not read this counter; they read the heap size in
pages (`gc_heap_stats.heap_size`), which counts the pages of a region, parked or
in use. A program that watches the memory of a region reads
`jl_gc_region_pages(n)`; a program that watches the process reads `Sys.maxrss()`.

## Discipline the barrier does not remove

The barrier catches every heap reference that breaks the rule. It does not
see the execution roots. The checked reset does (see "The reset"), so the
rules below are what the program keeps beyond it, and every one of them is
the program's own to keep.

- **Reset from a frame that names none of the region's objects.** A Julia
  frame roots a local until the frame ends, whether or not the program reads
  it again, so a function that builds in a window and resets afterwards
  refuses its own reset with `EROOT`. Build and use the region's objects in
  one function and reset after it returned. The checked reset makes this a
  refusal; `jl_gc_region_unsafe_reset` makes it a freed object under a live
  reference and a `CORPSE` abort at the next collection.
- **Close every window on the region before its reset.** The reset refuses
  the window of the calling task (`EBUSY`). A parked task of the same thread
  that holds a window on the region is not counted, although the root check
  does reach that task's stack.
- **Open a window inside a function, not at top level.** A window at top
  level covers the evaluation of the next top-level statement. A definition
  there makes the defined object in the open region — the type of a new
  function, the `DataType` of a `struct`, a `Module`, the value of a `const` —
  and stores it into a binding of region 0: an escape, which the barrier
  reports and quarantines. Inside a function the runtime's own work is safe:
  a method that compiles for the first time, a dynamic dispatch on a new
  signature, a type first instantiated at run time, a name first looked up,
  a first throw, and the scheduler state a first wait on a thread makes all
  happen in region 0.
- **Catch an exception inside the window.** An exception allocated inside the
  window is a region object. An exception that leaves the window is a root
  into the region at the reset point. The handler at the window boundary
  handles it, or throws a copy allocated outside the window.
- **Do not block inside a window.** A task that waits inside a window keeps
  the region live and, through the stickiness, keeps its thread. The window
  is for the unit of work, not for the loop around it.
- **Make tasks outside the window.** A task made inside a window is a region
  object, and its schedule stores it into the scheduler's queues, which are
  stock objects: an escape, which the barrier reports and quarantines. The
  task is made outside, and opens its own window inside.
- **Do not weak-reference a region object.** `WeakRef` on a region object
  throws while the barrier is armed: a weak reference is a stock-heap
  reference the reset does not clear.
- **Do not serialize a region object.** The image writer (`src/staticdata.c`)
  refuses while a window is open.
- **Do not hand a region object to C and let it keep the pointer.** The
  barrier sees a managed store and nothing else, so a pointer a foreign
  library holds dangles at the reset with no report.

## Limits

- There is no `Base` API. The entries are `ccall` targets; a program wraps
  them itself.
- 64 regions: region 0 and 63 regions a program can open
  (`JL_GC_MAX_REGIONS`).
- A region's pages belong to one thread heap. A region several threads fill
  is reset with the global reset, with the world stopped.
- A window does not compile: the compiler runs in region 0. A method that
  compiles for the first time inside a window pays its compile in the stock
  heap, and the objects it allocates after are region objects.
- `WeakRef` on a region object and an image write inside a window are refused.
- `finalize(o)` on a region object does nothing: its finalizer is on the
  region's list, which only the reset and the census run.
- The pages of a region never return to the operating system, and they never
  return to the stock pool either: a reset parks them for the next window on
  the region. `gc_heap_stats.heap_size` counts them, parked or in use, so a
  large region raises the heap size the stock collector aims at.
- A quarantine is permanent. No entry point clears it, the reset and both
  censuses refuse from then on, a window on the region is refused, and the
  region's finalizer list stays a root of the stock mark. The memory of a
  quarantined region is retained for the life of the process.
- A window costs the thread heap 64 region entries, about 100 KB, and the
  page metadata two fields, whether or not a program ever opens one.
- The heap reserve prefaults at most `GC_MAX_BLOCKS` blocks (about 64 GB);
  blocks past that are mapped lazily.
- `jl_gc_region_collect` returns `EINVAL` for a valid region that no window
  used on the heap; `jl_gc_region_reset` returns 0 for it.
- A build with a third-party heap (`WITH_THIRD_PARTY_HEAP`) has no regions:
  every window is refused, every hook declines.
- The cost is measured on Linux x86-64 only.

## Cost

A program that opens no window pays the barrier's flag load at every managed
pointer store, one relaxed load per object in the mark loops, and one page tag
per page. The measurements in `contrib/memory-regions/MEASUREMENTS.md`, at the
root of the repository, put a julia that carries the region runtime, with no region in use, against a
vanilla julia built from the same base, on the GCBenchmarks suite and on unit
costs of the allocator, the mark, and the sweep. The same document measures the
cost and the pause tail of a program that uses a region, on synthetic loops and
on four demonstrators.

Two build defines exist for measurement; each takes one half of that cost
out. `JL_NO_REGION_STORE_BARRIER` omits the escape barrier from the compiler
and from the runtime: a pointer store and a construction compile as vanilla
compiles them, so rule 4 is gone and rule 3 rests on the static checker in
`contrib/memory-regions/tools` alone. `JL_NO_REGION_ALLOC` builds the stock
pools only: `jl_gc_region_set` refuses, so no region initializes and no census
runs, and the census filter of the mark loops is the constant 0, which folds
the census branches out. What a build with both defines keeps is nothing per
object: one region tag per page, which the page allocator writes and the
sweep reads, and a store and a compare of the region fields at a task switch.
The region tests fail on both builds by design, every window refused on the
one and no escape ever seen on the other.

## Files

| File | Content |
|:--|:--|
| `src/gc-regions.h` | The exported API, the refusal codes, the hooks the runtime calls, the stubs for a third-party heap. |
| `src/gc-regions.c` | The window, the reset, the tree, the census, the barrier, the debug checks. |
| `src/gc-tls-stock.h` | The per-heap region table: pools, page chains, finalizer list, malloc'd list, live and child masks. |
| `src/gc-stock.c` | The region page tag, the allocation into the active pools, the census filter in the mark loops, the sweep that skips region pages, the `WeakRef` refusal. |
| `src/gc-common.c` | Finalizer lists and malloc'd data of a region; the suspend and resume of a window around the runtime's own allocation. |
| `src/gc-pages.c` | The heap reserve. |
| `src/gc-wb-stock.h`, `src/cgutils.cpp`, `src/llvm-late-gc-lowering.cpp` | The escape barrier in the runtime and in the compiler. |
| `src/task.c` | The window follows the task. |
| `src/gf.c` | Inference, compilation, and the cache-miss path of a dynamic dispatch run in region 0. |
| `src/jltypes.c` | The cache-miss path of a type instantiation runs in region 0. |
| `src/module.c` | A `Binding` and its partition are made in region 0. |
| `src/rtutils.c` | The exception stack of a task is made in the region of the task. |
| `src/array.c`, `src/genericmemory.c`, `src/simplevector.c` | The replacement buffer of `jl_array_grow_end`; the pair check of a bulk copy. |
| `src/staticdata.c` | The image writer refuses inside a window. |
| `base/lock.jl` | The lazily initialized state of `OncePerProcess` and `OncePerThread` is made with the window suspended. |
| `base/array.jl`, `base/dict.jl`, `base/iddict.jl`, `base/idset.jl`, `base/iobuffer.jl` | The replacement buffer of a container that grows. |
| `contrib/memory-regions/` | The Julia wrapper, the benchmarks, the demonstrators, the checker, and the measurements. |
| `test/gc/regions_*.jl` | The tests. |
