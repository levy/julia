# Stage-3 acceptance: a parked task's stack is a root for the census.
# Task A allocates region records, closes its window, and parks; the
# census runs from the main task; A's records must survive, because A's
# stack still references them - the live_tasks walk finds them. Run with
# one thread: that is the discriminating case (A parks on the census's
# own thread). With more threads A's records live in A's thread's region
# instance and the main census never sees them - trivially safe.
region_set(n)   = ccall(:jl_gc_region_set, Cint, (Cint,), n)
region_reset(n) = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
region_coop(n)  = ccall(:jl_gc_region_collect_coop, Int64, (Cint,), n)
quarantined(n)  = ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)
const SIM = 1
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

mutable struct Rec
    x::Int
end

function main()
    # Initialize SIM on THIS thread, so the census's return is meaningful
    # whether or not the spawned task lands here.
    region_set(SIM); region_set(0)
    ch1, ch2 = Channel{Nothing}(1), Channel{Nothing}(1)
    tA = Threads.@spawn begin
        region_set(SIM)
        recs = [Rec(i) for i in 1:100]
        region_set(0)
        put!(ch1, nothing); take!(ch2)      # park: window closed, refs live
        all(recs[i].x == i for i in 1:100)
    end
    take!(ch1)
    GC.enable(false)
    # The cooperative contract: -4 means another thread runs managed code
    # at this instant - an engine retries at its next boundary. So does
    # the test.
    freed = Int64(-4)
    for _ in 1:100
        freed = region_coop(SIM)
        freed != -4 && break
        sleep(0.01)
    end
    GC.enable(true)
    check("the census ran (got $freed)", freed >= 0)
    put!(ch2, nothing)
    check("the parked task's records survived the census", fetch(tA))
    check("nothing was quarantined", quarantined(SIM) == 0)
    region_reset(SIM)
end
main()
GC.gc()
println(failures[] == 0 ? "PARKED TASK: ALL PASS" : "PARKED TASK: $(failures[]) FAILURES")
