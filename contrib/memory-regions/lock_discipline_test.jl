# Region-tree, the lock-discipline hazard (the Dict-resize hazard in its
# multi-thread coat). A growable structure that lives in the trunk must be
# grown with the TRUNK current: grown with a leaf current, its new backing
# memory is a leaf object stored into the trunk structure -- a trunk (older)
# holding a leaf (younger) child, an escape the barrier must quarantine.
@noinline region_set(n)        = ccall(:jl_gc_region_set, Cint, (Cint,), n)
@noinline region_parent!(c, p) = ccall(:jl_gc_region_declare_parent, Cint, (Cint, Cint), c, p)
@noinline quarantined(n)       = Int(ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)) != 0
const TRUNK = 1; const LEAF = 2
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

region_parent!(LEAF, TRUNK)

# The disciplined case: grow the trunk vector with the TRUNK current. The new
# backing memory is a trunk object, stored into a trunk vector: legal.
@noinline function disciplined()
    region_set(TRUNK)
    v = Vector{Any}()
    for i in 1:10_000; push!(v, i); end   # resizes happen in the trunk
    region_set(0)
    check("growing the trunk in the trunk does not escape", !quarantined(LEAF) && !quarantined(TRUNK))
    return v
end

# The hazard: grow the same trunk vector with a LEAF current. A resize now
# allocates the backing memory in the leaf and stores it into the trunk
# vector -- an escape that quarantines the leaf.
@noinline function hazard(v)
    region_set(LEAF)
    for i in 1:100_000; push!(v, i); end   # the trunk vector's resize lands in the leaf
    region_set(0)
    check("growing a trunk vector under a leaf window quarantines the leaf", quarantined(LEAF))
end

let v = disciplined()
    hazard(v)
end

if failures[] == 0
    println("LOCK DISCIPLINE: ALL PASS")
else
    println("LOCK DISCIPLINE: ", failures[], " FAILURES")
end
