# This file is a part of Julia. License is MIT: https://julialang.org/license

# Two threads use the same region number, each on its own heap: the
# per-thread leaf pattern. A checked reset on one heap marks from the roots
# of every thread, so it marks the other thread's region objects as well.
# It must clear those marks before it returns: a mark that stays makes the
# other thread's next checked reset refuse falsely, and makes its next
# census stop at the marked object, so the census never marks the children
# of that object and frees them under a live parent.
include(joinpath(@__DIR__, "regions_api.jl"))

const N = 1
const A_READY = Threads.Atomic{Int}(0)
const B_DONE = Threads.Atomic{Int}(0)

@noinline function spin_until(flag)
    while flag[] == 0
        GC.safepoint()
        ccall(:jl_cpu_pause, Cvoid, ())
    end
end

# A holds region objects rooted on its frame while B runs a checked reset
# of B's own instance of the region. Then A closes its window and works on.
@noinline function heaps_hold(mode)
    region_set(N)
    objs = [Ref(Ref(i)) for i in 1:3000]
    check("A's objects are in region $N", region_of(objs[1]) == N)
    Threads.atomic_add!(A_READY, 1)
    spin_until(B_DONE)
    s = 0
    for r in objs; s += r[][]; end
    check("A's objects survive B's reset (sum $s)", s == 4_501_500)
    if mode == :census
        # Give each outer a new inner. A census that does not walk the
        # outer, because B's scan left it marked, never marks the new inner.
        for r in objs; r[] = Ref(r[][] + 1); end
        region_set(0)
        freed = region_collect(N)
        check("A's census runs after B's reset (code $freed)", freed >= 3000)
        # Reuse the freed cells: a freed inner takes a -1, and its parent
        # reads it.
        region_set(N)
        junk = [Ref(-1) for _ in 1:6000]
        region_set(0)
        s2 = 0
        for r in objs; s2 += r[][]; end
        check("the new inners survive A's census (sum $s2)", s2 == s + length(objs))
        check("the junk is intact", all(j -> j[] == -1, junk))
    else
        region_set(0)
    end
    return s
end

@noinline function heaps_fill()
    region_set(N)
    x = [Ref(i) for i in 1:100]
    s = sum(r[] for r in x)
    region_set(0)
    return s
end

function heaps_worker(w, mode)
    if w == 1
        heaps_hold(mode)
        # The frame of heaps_hold is gone: nothing roots A's objects.
        check("A's check finds no root after B's reset ($mode)", region_check(N) == 0)
        r = reset_via_call(N)
        check("A's checked reset succeeds after B's ($mode, code $(code(r)))", !refused(r))
    else
        spin_until(A_READY)
        heaps_fill()
        r = reset_via_call(N)
        check("B's checked reset succeeds ($mode, code $(code(r)))", !refused(r))
        Threads.atomic_add!(B_DONE, 1)
    end
end

function heaps_round(mode)
    A_READY[] = 0
    B_DONE[] = 0
    Threads.@threads :static for w in 1:2
        heaps_worker(w, mode)
    end
    check("no quarantine after the $mode round", quarantined(N) == 0)
end

if Threads.nthreads() < 2
    println("regions_heaps: skipped, needs two threads")
else
    heaps_round(:reset)
    heaps_round(:census)
    finish("regions_heaps")
end
