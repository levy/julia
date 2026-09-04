# This file is a part of Julia. License is MIT: https://julialang.org/license

include(joinpath(@__DIR__, "regions_api.jl"))

# A container that grows inside a window keeps its buffer where the
# container lives. The new buffer replaces the old one, so it takes the
# region of the old buffer, not the region of the open window. Without the
# rule, every one of these cases quarantines the window's region for an
# operation the program has every right to make.
#
# The rule covers the buffer. The elements stay the program's own data and
# keep the reference rule: the last case stores a region object into a
# region-0 vector, and that still quarantines.

const GROW = 1
const ELEM = 2

const LONG = Int[]
const LONGANY = Any[]

@noinline function push_inside_window(n, count)
    region_set(n)
    for i in 1:count
        push!(LONG, i)
    end
    region_set(0)
end

function a_vector_grows_inside_a_window()
    push_inside_window(GROW, 10_000)
    check("push! of a bits element inside a window does not quarantine", quarantined(GROW) == 0)
    check("the vector is right", length(LONG) == 10_000 && LONG[end] == 10_000)
    check("the region resets", !refused(reset_via_call(GROW)))
    check("the vector is right after the reset", LONG[end] == 10_000 && sum(LONG) == 50_005_000)
end

@noinline function grow_the_front_inside_window(n, count)
    region_set(n)
    for i in 1:count
        pushfirst!(LONG, -i)
    end
    resize!(LONG, length(LONG) + 100)
    region_set(0)
end

function a_vector_grows_at_both_ends()
    grow_the_front_inside_window(GROW, 2_000)
    check("pushfirst! and resize! inside a window do not quarantine", quarantined(GROW) == 0)
    check("the front of the vector is right", LONG[1] == -2_000)
    check("the region resets", !refused(reset_via_call(GROW)))
end

const D = Dict{Int,Int}()

@noinline function grow_dict_inside_window(n, count)
    region_set(n)
    for i in 1:count
        D[i] = i
    end
    region_set(0)
end

function a_dict_rehashes_inside_a_window()
    grow_dict_inside_window(GROW, 10_000)
    check("a Dict rehash inside a window does not quarantine", quarantined(GROW) == 0)
    check("the Dict is right", length(D) == 10_000 && all(D[k] == k for k in 1:10_000))
    check("the region resets", !refused(reset_via_call(GROW)))
    check("the Dict is right after the reset", D[10_000] == 10_000)
end

const ID = IdDict{Any,Any}()
const KEYS = Any[]
const VALS = Any[]

# The keys and the values are made before the window opens. An IdDict holds
# both as `Any`, so a value made inside the window would be boxed there and
# the box would be a region object in a region-0 table: an element escape,
# not a buffer one. This case is about the table the rehash replaces.
@noinline function grow_iddict_inside_window(n, count)
    region_set(n)
    for i in 1:count
        ID[KEYS[i]] = VALS[i]
    end
    region_set(0)
end

function an_iddict_rehashes_inside_a_window()
    for i in 1:4_000
        push!(KEYS, Ref(i))
        push!(VALS, Ref(-i))
    end
    grow_iddict_inside_window(GROW, 4_000)
    check("an IdDict rehash inside a window does not quarantine", quarantined(GROW) == 0)
    check("the IdDict is right", length(ID) == 4_000 && ID[KEYS[4_000]][] == -4_000)
    check("the region resets", !refused(reset_via_call(GROW)))
    check("the IdDict is right after the reset", ID[KEYS[1]][] == -1)
end

const BUF = IOBuffer()

@noinline function grow_iobuffer_inside_window(n, count)
    region_set(n)
    for i in 1:count
        write(BUF, UInt8(i & 0xff))
    end
    region_set(0)
end

function an_iobuffer_grows_inside_a_window()
    grow_iobuffer_inside_window(GROW, 100_000)
    check("an IOBuffer growth inside a window does not quarantine", quarantined(GROW) == 0)
    check("the buffer is right", position(BUF) == 100_000)
    check("the region resets", !refused(reset_via_call(GROW)))
    check("the buffer reads after the reset", length(take!(BUF)) == 100_000)
end

# The buffer follows its container; an element does not. A region object
# stored into a region-0 vector outlives its region, and the barrier is
# right to quarantine it.
@noinline function push_a_region_element(n)
    region_set(n)
    r = Ref(1)
    region_set(0)
    push!(LONGANY, r)
    return nothing
end

function an_element_still_quarantines()
    push_a_region_element(ELEM)
    check("a region element in a region-0 vector still quarantines", quarantined(ELEM) == 1)
    check("the element still reads", LONGANY[1][] == 1)
end

a_vector_grows_inside_a_window()
a_vector_grows_at_both_ends()
a_dict_rehashes_inside_a_window()
an_iddict_rehashes_inside_a_window()
an_iobuffer_grows_inside_a_window()
an_element_still_quarantines()

finish("regions_containers")
