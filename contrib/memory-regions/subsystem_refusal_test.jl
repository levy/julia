# The declined subsystems have defined behavior, not corruption. A region
# object reached by a weak reference, an IdDict key, or the serializer must
# either refuse or quarantine the region - never dangle it.
@noinline region_set(n)   = ccall(:jl_gc_region_set, Cint, (Cint,), n)
@noinline quarantined(n)  = Int(ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)) != 0
const R = 1
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

mutable struct Box; v::Int; end
@noinline make_in_region() = (region_set(R); x = Box(7); region_set(0); x)

# 1. WeakRef to a region object is refused outright.
let x = make_in_region()
    threw = false
    try
        WeakRef(x)
    catch e
        threw = true
        check("weakref error mentions region", occursin("region", sprint(showerror, e)))
    end
    check("weakref to a region object is refused", threw)
end

# 2. An IdDict key from a region quarantines the region (defined leak).
let x = make_in_region()
    d = IdDict{Any,Int}()      # region 0
    d[x] = 1                   # stores x into the dict's storage: escape
    check("iddict key from a region quarantines it", quarantined(R))
end

# 3. Serializing a region object quarantines the region (defined leak),
#    and produces bytes rather than corrupting.
using Serialization
let x = make_in_region()
    buf = IOBuffer()
    serialize(buf, x)
    check("serialize of a region object quarantines it", quarantined(R))
    check("serialize still produced bytes", position(buf) > 0)
end

if failures[] == 0
    println("SUBSYSTEM REFUSAL: ALL PASS")
else
    println("SUBSYSTEM REFUSAL: ", failures[], " FAILURES")
end
