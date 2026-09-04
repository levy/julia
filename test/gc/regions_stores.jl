# This file is a part of Julia. License is MIT: https://julialang.org/license

include(joinpath(@__DIR__, "regions_api.jl"))

# The stores that the escape barrier did not see. Each one puts a region
# object into a region-0 parent through a path the write barrier of the
# stock collector skips, because the parent is fresh or because the copy
# moves many references at once. Each case burns its own region, from 7
# down, and the mask check at the end fixes the outcome of every case.
#
# The last case is the opposite: an argument vector of a splat call is a
# temporary of the call, and a check there would quarantine a region for
# ordinary correct code. It must stay unchecked.

# The default tree is the chain 0 <- 1 <- 2 <- ..., so a region that stays
# live blocks the reset of every region below it. The case that resets runs
# first, on the lowest region; the cases that burn a region run after, from
# 7 down.
const SPLAT = 1
const TASKR = 7
const COPYTO = 6
const COPYR = 5

# A callable object made inside a window is a region object. The task is
# made outside the window, as the discipline demands, so the task is a
# region-0 object and its `start` field holds the region object.
#
# The callable is a mutable struct, not a closure. A closure with captured
# fields is immutable, so every pass as `Any` boxes it again and the box,
# not the closure, is what a region holds.
mutable struct Callable
    x::Int
end
(c::Callable)() = c.x + 1

@noinline function make_callable(n)
    region_set(n)
    c = Callable(41)
    region_set(0)
    escape(c)
    return c
end

function task_start_quarantines()
    c = make_callable(TASKR)
    check("the callable lives in its region", region_of(c) == TASKR)
    check("nothing escaped it yet", quarantined(TASKR) == 0)
    t = Task(c)
    escape(t)
    check("the task holds the region object", region_of(t) == 0)
    check("a region callable in a region-0 task quarantines its region", quarantined(TASKR) == 1)
    check("the callable still runs", c() == 42)
end

# A vector built inside a window holds region objects, legally: the parent
# and the children share the region. A bulk copy into a region-0 vector
# moves those references out, and the copy barrier must see it.
@noinline function make_source(n, len)
    region_set(n)
    s = Any[Ref(i) for i in 1:len]
    region_set(0)
    escape(s)
    return s
end

function copyto_quarantines()
    src = make_source(COPYTO, 16)
    sink = Vector{Any}(undef, 16)
    copyto!(sink, src)
    escape(sink)
    check("a bulk copy of region elements into a region-0 vector quarantines",
          quarantined(COPYTO) == 1)
    check("the copy is correct", sink[16][] == 16)
end

# `copy` allocates the new memory in the region that is current, which is 0
# here, and moves the element references into it with no barrier call at
# all.
function copy_quarantines()
    src = make_source(COPYR, 16)
    dup = copy(src)
    escape(dup)
    check("a copy of a region vector into region 0 quarantines", quarantined(COPYR) == 1)
    check("the copy is correct", dup[16][] == 16)
end

# The argument vector of a splat call lives for the call and dies with it.
# It never outlives the region, so it is not an escape, and the barrier must
# not fire on it. This case guards that exemption.
@noinline count_args(args...) = length(args)

function splat_does_not_quarantine()
    v = make_source(SPLAT, 3)
    check("a splat call passes region objects", count_args(v...) == 3)
    check("a splat call does not quarantine", quarantined(SPLAT) == 0)
    check("the region of the arguments still resets", !refused(reset_via_call(SPLAT)))
end

splat_does_not_quarantine()
task_start_quarantines()
copyto_quarantines()
copy_quarantines()

check("exactly the three stores quarantined",
      quarantined(TASKR) == 1 && quarantined(COPYTO) == 1 && quarantined(COPYR) == 1 &&
      quarantined(SPLAT) == 0)

finish("regions_stores")
