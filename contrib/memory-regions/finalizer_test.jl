# Stage-1d acceptance: finalizers on region objects. The reset runs them
# all on whole objects; the cooperative census runs the dead ones and
# keeps the live; a finalizer that resurrects its object is an escape,
# quarantined like any other.
region_set(n)   = ccall(:jl_gc_region_set, Cint, (Cint,), n)
region_reset(n) = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
region_coop(n)  = ccall(:jl_gc_region_collect_coop, Int64, (Cint,), n)
quarantined(n)  = ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)
const SIM = 1
const EVENT = 2
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

mutable struct Payload
    x::Int
end
const seen = Int[]           # region 0, written by finalizers in region 0

@noinline function reset_part()
    region_set(EVENT)
    for i in 1:4
        p = Payload(i)
        finalizer(q -> push!(seen, q.x), p)
    end
    region_set(0)
end
function run_reset_part()
    reset_part()
    region_reset(EVENT)
    check("the reset ran every finalizer on a whole object", sort(seen) == [1, 2, 3, 4])
end
run_reset_part()

@noinline function census_inner()
    region_set(SIM)
    live = Payload(100)
    finalizer(q -> push!(seen, q.x), live)
    for i in 10:12
        p = Payload(i)
        finalizer(q -> push!(seen, q.x), p)
    end
    region_set(0)
    freed = region_coop(SIM)
    return freed, live.x
end
function run_census_part()
    GC.enable(false)
    empty!(seen)
    freed, livex = census_inner()
    check("the census ran (got $freed)", freed >= 3)
    check("the census ran the dead finalizers only", sort(seen) == [10, 11, 12])
    check("the live object stayed whole", livex == 100)
    region_reset(SIM)
    check("the reset then ran the survivor's finalizer", sort(seen) == [10, 11, 12, 100])
    GC.enable(true)
end
run_census_part()
GC.gc()
println(failures[] == 0 ? "FINALIZER: ALL PASS" : "FINALIZER: $(failures[]) FAILURES")
