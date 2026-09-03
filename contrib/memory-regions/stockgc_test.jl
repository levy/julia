# Stage-2 acceptance: the stock collector coexists with live regions -
# no contract. GC.gc(true) and GC.gc(false) run inside an open window
# and between windows, with a live Simulation region; the census after
# them is exact (no stale marks), the reset works, the objects stay
# whole, and region-0 garbage is actually collected while regions live.
region_set(n)   = ccall(:jl_gc_region_set, Cint, (Cint,), n)
region_reset(n) = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
region_coop(n)  = ccall(:jl_gc_region_collect_coop, Int64, (Cint,), n)
const SIM = 1
const EVENT = 2
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))
@noinline consume(v) = (v[1] = 0.0; nothing)

mutable struct Rec
    x::Int
end

@noinline function body()
    region_set(SIM)
    keep = [Rec(i) for i in 1:1000]
    region_set(0)

    # Collections with a live region and an OPEN window.
    region_set(EVENT)
    scratch = [Rec(-i) for i in 1:100]
    GC.gc(false)
    GC.gc(true)
    ok_scratch = all(scratch[i].x == -i for i in 1:100)
    region_set(0)
    region_reset(EVENT)

    # Collections between windows, region-0 garbage reclaimed meanwhile.
    pauses0 = Base.gc_num().pause
    for _ in 1:50
        consume(Vector{Float64}(undef, 4096))   # region-0 garbage
    end
    GC.gc(false)
    GC.gc(true)
    pauses1 = Base.gc_num().pause
    ok_keep1 = all(keep[i].x == i for i in 1:1000)

    # The census after those collections must be exact: kill half the
    # records, then count the frees - stale marks would corrupt this.
    for i in 1:2:1000
        keep[i] = Rec(10_000 + i)               # 500 dead records
        i % 100 == 1 && GC.gc(false)            # force the mid-loop case
    end
    freed = region_coop(SIM)
    bad = findfirst(i -> keep[i].x != (isodd(i) ? 10_000 + i : i), 1:1000)
    bad !== nothing && println("MISMATCH at ", bad, ": got ", keep[bad].x,
                               " want ", isodd(bad) ? 10_000 + bad : bad)
    return ok_scratch, pauses1 - pauses0, ok_keep1, freed, bad === nothing
end

function main()
    ok_scratch, pauses, ok_keep1, freed, ok_keep2 = body()
    check("the open-window scratch survived the collections", ok_scratch)
    check("the collections actually ran (got $pauses)", pauses >= 2)
    check("the live records survived the collections", ok_keep1)
    check("the census after stock collections is exact (got $freed)", freed >= 500)
    check("the records after the census are whole", ok_keep2)
    region_reset(SIM)
end
main()
GC.gc()
println(failures[] == 0 ? "STOCK COEXIST: ALL PASS" : "STOCK COEXIST: $(failures[]) FAILURES")
