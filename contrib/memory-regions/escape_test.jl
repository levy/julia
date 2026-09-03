# Stage-1b acceptance: an escape is a leak, never corruption. The
# counterexample everyone types first: a Dict that lives in region 0
# resizes inside an Event window, so its new tables are region objects
# stored into an older parent - the barrier must quarantine the region,
# the reset must refuse, and the Dict must keep working.
region_set(n)   = ccall(:jl_gc_region_set, Cint, (Cint,), n)
region_reset(n) = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
quarantined(n)  = ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)
const EVENT = 2
const SIM = 1
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

# A clean window first: no quarantine, the reset works.
function clean()
    region_set(SIM)
    x = Ref(0)
    for i in 1:1000
        x = Ref(i)
    end
    region_set(0)
    check("clean window is not quarantined", quarantined(SIM) == 0)
    check("clean reset works", region_reset(SIM) < typemax(UInt64) - 8)
    x[]
end
clean()

# The escape: the Dict's rehash stores Event-region tables into the
# region-0 Dict.
d = Dict{Int,Int}()
function escape!(d)
    region_set(EVENT)
    for k in 1:10_000
        d[k] = k
    end
    region_set(0)
end
escape!(d)
check("the escape quarantined the region", quarantined(EVENT) == 1)
check("the quarantined reset refuses", region_reset(EVENT) == typemax(UInt64) - 1)
intact(d) = all(d[k] == k for k in 1:10_000)
check("the Dict survived intact", intact(d))
GC.gc()
check("the Dict survived a full collection", intact(d))
println(failures[] == 0 ? "ESCAPE: ALL PASS" : "ESCAPE: $(failures[]) FAILURES")
