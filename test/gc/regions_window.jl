# This file is a part of Julia. License is MIT: https://julialang.org/license

include(joinpath(@__DIR__, "regions_api.jl"))

const SIM = 1
const EVENT = 2
const RESERVE = 3

# Every entry refuses a region number outside 1:7 without touching any
# region's state.
function bad_region_numbers()
    for n in (-1, 8, 99)
        check("set($n) refuses", region_set(n) == EINVAL)
        check("set($n) leaves region 0 current", region_current() == 0)
        check("reset($n) refuses", code(region_reset(n)) == EINVAL)
        check("reset_global($n) refuses", code(region_reset_global(n)) == EINVAL)
        check("collect($n) refuses", region_collect(n) == EINVAL)
        check("coop($n) refuses", region_collect_coop(n) == EINVAL)
        check("quarantined($n) is 0", quarantined(n) == 0)
        check("pages($n) is 0", region_pages(n) == 0)
    end
end

# The region that is current cannot be reset or censused, by any of the
# three census-like entries, and a global reset refuses while any window
# is open anywhere.
function current_region_refusals()
    region_set(SIM)
    check("reset of the current region refuses", code(region_reset(SIM)) == EBUSY)
    check("collect of the current region refuses", region_collect(SIM) == EBUSY)
    check("coop of the current region refuses", region_collect_coop(SIM) == EBUSY)
    check("reset_global with a window open refuses", code(region_reset_global(EVENT)) == EBUSY)
    region_set(0)
    check("region 1 is not quarantined by the refusal checks", quarantined(SIM) == 0)
end

function no_window_defaults()
    check("set(0) with no window returns 0", region_set(0) == 0)
    check("reset of an untouched region returns 0", code(region_reset(RESERVE)) == 0)
end

# jl_gc_region_set returns the region that was current, so a chain of
# opens and a close read back as the sequence of switches it made.
@noinline alloc_in_current() = Ref(1)

function set_returns_previous_and_reports_current()
    check("opening region 1 returns the previous region 0", region_set(SIM) == 0)
    check("region 1 is now current", region_current() == SIM)
    a = escape(alloc_in_current())
    check("an object allocated inside the window is in region 1", a == SIM)
    check("opening region 2 inside region 1 returns region 1", region_set(EVENT) == SIM)
    check("region 2 is now current", region_current() == EVENT)
    b = escape(alloc_in_current())
    check("an object allocated inside the nested window is in region 2", b == EVENT)
    check("closing the window returns region 2", region_set(0) == EVENT)
    check("no region is current after the close", region_current() == 0)
    c = escape(alloc_in_current())
    check("an object allocated after the close is in region 0", c == 0)
    check("region 1 is not quarantined", quarantined(SIM) == 0)
    check("region 2 is not quarantined", quarantined(EVENT) == 0)
end

# A region that holds objects reports a positive page count, and its reset
# both reclaims the pages and reports zero held afterward. In the default
# chain region 2 is the child of region 1: a live child refuses the
# parent's reset, so the child resets first.
function reset_holds_pages_then_chain()
    check("region 2 holds pages", region_pages(EVENT) > 0)
    check("the parent refuses its reset while the child is live", code(region_reset(SIM)) == ECHILD)
    check("region 1 still holds its pages after the refusal", region_pages(SIM) > 0)
    r2 = region_reset(EVENT)
    check("reset of a region that holds objects returns a positive page count", code(r2) > 0)
    check("region 2 holds no pages after its reset", region_pages(EVENT) == 0)
    check("region 1 holds pages", region_pages(SIM) > 0)
    r1 = region_reset(SIM)
    check("reset of region 1 returns a positive page count", code(r1) > 0)
    check("region 1 holds no pages after its reset", region_pages(SIM) == 0)
end

# A window belongs to the task that opened it: it survives a yield that
# parks the task, and it makes the task sticky to its thread for as long
# as it stays open. The handshake below stores no pointer (a Base.Event
# carries none), so it cannot itself trip the escape barrier.
function interleave()
    e1, e2 = Base.Event(), Base.Event()
    got = zeros(Int, 3)
    tA = Threads.@spawn begin
        was_sticky = current_task().sticky
        region_set(EVENT)
        check("opening a window makes the task sticky", current_task().sticky)
        a = Ref(1); got[1] = region_of(a)
        notify(e1); wait(e2)              # park the window; let B run
        b = Ref(2); got[2] = region_of(b)
        region_set(0)
        check("closing the window restores the previous stickiness", current_task().sticky == was_sticky)
        a[] + b[]
    end
    tB = Threads.@spawn begin
        wait(e1)                          # A's window is parked now
        c = Ref(3); got[3] = region_of(c)
        notify(e2)
        c[]
    end
    fetch(tA); fetch(tB)
    check("A allocates in its window before the yield", got[1] == EVENT)
    check("A allocates in its window after the yield", got[2] == EVENT)
    check("B allocates outside A's window", got[3] == 0)
end

# A window survives being spawned across every available thread, and each
# task's allocations keep landing in its own region across repeated yields.
function spawn_stress()
    n = Threads.nthreads() * 8
    ok = Threads.Atomic{Int}(0)
    Threads.@sync for k in 1:n
        Threads.@spawn begin
            region_set(EVENT)
            r = Ref(k)
            for _ in 1:4
                yield()
                region_of(r) == EVENT || error("window lost across yield")
                escape(Ref(0))         # allocate inside the window
            end
            region_set(0)
            Threads.atomic_add!(ok, 1)
        end
    end
    check("every spawned window survived its yields", ok[] == n)
end

function task_window_cases()
    interleave()
    spawn_stress()
    check("the event region is not quarantined", quarantined(EVENT) == 0)
    r = code(region_reset(EVENT))
    check("the event region resets (got $r)", r >= 0)
end

@noinline work(i) = (tmp = [Float64(i), 2.0, 3.0]; w = collect(1.0:4.0); sum(tmp) + sum(w))

# A reset every iteration, on a region that quiesces to zero pages between
# uses, must never mishandle the empty case, and no reset may refuse.
@noinline function reset_every_iteration(n)
    acc = 0.0
    refusals = 0
    for i in 1:n
        region_set(SIM)
        acc += work(i)
        region_set(0)
        refusals += refused(region_reset(SIM))
    end
    return acc, refusals
end

function reset_loop_case()
    reset_every_iteration(1000)          # warm up before the timed run
    GC.gc()
    r, refusals = reset_every_iteration(1_000_000)
    GC.gc()
    check("no reset of the loop refused (got $refusals)", refusals == 0)
    check("the reset loop accumulates the exact sum", r == 5.000155e11)
    check("region verify finds no inconsistency after the loop", region_verify(SIM) == 0)
end

# A window with nothing allocated inside it needs no reset: opening and
# closing it repeatedly must stay cheap and leave no pages behind.
@noinline function swap_only(n)
    acc = 0.0
    for i in 1:n
        region_set(SIM)
        acc += work(i)
        region_set(0)
    end
    return acc
end

function swap_only_case()
    swap_only(1000)                      # warm up before the timed run
    GC.gc()
    r = swap_only(1_000_000)
    GC.gc()
    check("the swap-only loop accumulates the exact sum", r == 5.000155e11)
    check("region verify finds no inconsistency after the loop", region_verify(SIM) == 0)
    check("a window with no allocation holds no pages", region_pages(SIM) == 0)
end

# A window opened at top level would leave the compiler's own allocations
# for the next top-level statement inside it; wrapping the allocation in
# its own function keeps the window's contents to just the array this
# case means to put there.
@noinline function make_live_array()
    region_set(SIM)
    a = [1.0, 2.0, 3.0]
    region_set(0)
    return a
end

function live_object_survives_gc()
    a = make_live_array()
    GC.gc(); GC.gc()
    check("a live region object survives two collections", sum(a) == 6.0)
    check("the object is still reported in its region", region_of(a) == SIM)
    check("region verify finds no inconsistency", region_verify(SIM) == 0)
    r = code(region_reset(SIM))
    check("the region resets (got $r)", r >= 0)
end

# The reserve claims page blocks up front so a later allocation inside a
# region never first-touch-faults; a second call must be a no-op, not an
# error, and a window can still allocate normally afterward.
@noinline function fill_with_refs(n)
    region_set(RESERVE)
    v = Vector{Any}(undef, n)
    for i in 1:n
        v[i] = Ref(i)
    end
    region_set(0)
    return v
end

function heap_reserve_then_window()
    r1 = heap_reserve(64 << 20)
    check("the reserve returns a byte count, not a refusal", !refused(r1))
    r2 = heap_reserve(64 << 20)
    check("a second reserve call also returns without error", !refused(r2))
    v = fill_with_refs(10_000)
    check("every ref landed in the window's region", all(x -> region_of(x) == RESERVE, v))
    check("the window resets without a refusal", !refused(region_reset(RESERVE)))
end

bad_region_numbers()
current_region_refusals()
no_window_defaults()
set_returns_previous_and_reports_current()
reset_holds_pages_then_chain()
task_window_cases()
reset_loop_case()
swap_only_case()
live_object_survives_gc()
heap_reserve_then_window()

finish("regions_window")
