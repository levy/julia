# This file is a part of Julia. License is MIT: https://julialang.org/license

include(joinpath(@__DIR__, "regions_api.jl"))
using Serialization

# A quarantine is permanent, and a quarantined region stays live, which
# blocks its parent's reset. The clean cases use regions 1 to 3 first and
# reset them; the quarantine cases then burn one region each, from 7 down
# to 3. The mask check at the end fixes the outcome of every case.

const SIM = 1
const EVENT = 2
const CLEAN = 3

# A window that allocates and drops its own objects, with no store into
# region 0, resets cleanly: nothing about it arms a quarantine.
@noinline function clean_window()
    region_set(CLEAN)
    local last
    for i in 1:1000
        last = Ref(i)
    end
    escape(last)
    region_set(0)
    check("the clean window is not quarantined", quarantined(CLEAN) == 0)
    check("a window with no store into region 0 resets", !refused(region_reset(CLEAN)))
end

mutable struct Holder
    f::Any
end
@noinline make_holder(n) = (region_set(n); h = Holder(nothing); region_set(0); h)
@noinline make_child(n)  = (region_set(n); c = Ref(1); region_set(0); c)
@noinline store!(h::Holder, c) = (h.f = c; nothing)

# A region-0 object is legal under any parent: it outlives every region,
# so the reference never dangles.
function region0_child_into_region1_parent()
    p = make_holder(SIM)
    c = make_child(0)
    store!(p, c)
    check("a region-0 child into a region-1 parent does not quarantine it", quarantined(SIM) == 0)
end

# A same-region store never crosses a reset boundary.
function region1_child_into_region1_parent()
    p = make_holder(SIM)
    c = make_child(SIM)
    store!(p, c)
    check("a region-1 child into a region-1 parent does not quarantine it", quarantined(SIM) == 0)
end

# In the default chain region 1 is the parent of region 2 and resets after
# it, so a region-1 child in a region-2 parent is legal.
function region1_child_into_region2_parent()
    p = make_holder(EVENT)
    c = make_child(SIM)
    store!(p, c)
    check("a region-1 child into a region-2 parent is legal", quarantined(EVENT) == 0)
end

# The child resets before the parent in the default chain.
function reset_clean_regions()
    check("region 2 is not quarantined before its reset", quarantined(EVENT) == 0)
    r2 = code(region_reset(EVENT))
    check("region 2 resets (got $r2)", r2 >= 0)
    check("region 1 is not quarantined before its reset", quarantined(SIM) == 0)
    r1 = code(region_reset(SIM))
    check("region 1 resets (got $r1)", r1 >= 0)
end

# The reverse store is the escape: a region-7 child in a region-6 parent
# would dangle when region 7 resets first. The barrier quarantines the
# child's region, the parent's region stays clean, and the live quarantined
# child blocks the parent's reset from now on.
function chain_escape_quarantines_region7()
    p = make_holder(6)
    c = make_child(7)
    store!(p, c)
    check("a region-7 child into a region-6 parent quarantines region 7", quarantined(7) == 1)
    check("the parent's region is not quarantined", quarantined(6) == 0)
    check("the quarantined reset refuses", code(region_reset(7)) == EQUARANTINED)
    check("the parent refuses its reset while the quarantined child lives", code(region_reset(6)) == ECHILD)
    check("the stored value still reads", p.f[] == 1)
end

# A Dict made in region 0 that grows inside a window stores its new table
# (a region object) into itself: the barrier quarantines the region rather
# than let the Dict dangle after the reset.
@noinline function grow_into!(d, n)
    region_set(n)
    for k in 1:10_000
        d[k] = k
    end
    region_set(0)
end

function dict_rehash_quarantines_region6()
    d = Dict{Int,Int}()
    grow_into!(d, 6)
    check("the Dict's rehash inside the window quarantines its region", quarantined(6) == 1)
    check("the quarantined reset refuses", code(region_reset(6)) == EQUARANTINED)
    check("the Dict still reads correctly", all(d[k] == k for k in 1:10_000))
end

# A constructor call is a store too: the holder is built in region 0 after
# the child's window closed, and its initializing store puts a region-5
# child into a region-0 object. The barrier catches that store as well.
@noinline make_ctor_child() = Ref{Int}(123456789)
@noinline construct_holder(c) = Holder(c)
@noinline function build_ctor_gap()
    region_set(5)
    c = make_ctor_child()
    region_set(0)
    return construct_holder(c)
end

function ctor_gap_quarantines_region5()
    p = build_ctor_gap()
    check("the constructor store quarantines the child's region", quarantined(5) == 1)
    check("the value reads intact", p.f[] == 123456789)
    check("the quarantined reset refuses", code(region_reset(5)) == EQUARANTINED)
end

mutable struct Box
    v::Int
end
@noinline make_in_region(n) = (region_set(n); x = Box(7); region_set(0); x)

# An IdDict stores its key into its own table, a region-0 object.
function iddict_key_quarantines_region4()
    x = make_in_region(4)
    d = IdDict{Any,Int}()
    d[x] = 1
    check("an IdDict key from region 4 quarantines it", quarantined(4) == 1)
    check("the lookup still finds the key", d[x] == 1)
    check("the quarantined reset refuses", code(region_reset(4)) == EQUARANTINED)
end

# The serializer records every object it writes in a region-0 table.
function serialize_quarantines_region3()
    x = make_in_region(3)
    buf = IOBuffer()
    serialize(buf, x)
    check("serializing a region-3 object quarantines it", quarantined(3) == 1)
    check("serialize still produced bytes", position(buf) > 0)
    check("the quarantined reset refuses", code(region_reset(3)) == EQUARANTINED)
end

function quarantine_mask_is_as_expected()
    for n in (1, 2)
        check("region $n is not quarantined", quarantined(n) == 0)
    end
    for n in (3, 4, 5, 6, 7)
        check("region $n is quarantined", quarantined(n) == 1)
    end
end

clean_window()
region0_child_into_region1_parent()
region1_child_into_region1_parent()
region1_child_into_region2_parent()
reset_clean_regions()
chain_escape_quarantines_region7()
dict_rehash_quarantines_region6()
ctor_gap_quarantines_region5()
iddict_key_quarantines_region4()
serialize_quarantines_region3()
quarantine_mask_is_as_expected()

finish("regions_escape")
