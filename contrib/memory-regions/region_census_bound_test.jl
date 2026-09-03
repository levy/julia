# The open-region census bounds a computation whose garbage dies INSIDE the
# window, not at its boundary -- the hazard that would otherwise OOM. In one
# long window, allocate a lot of transient garbage (each round builds and drops
# a big temporary) while keeping a small live accumulator on the stack. With
# the census disarmed the region grows without bound; armed, it stays bounded
# and the live accumulator survives intact.
@noinline region_set(n)             = ccall(:jl_gc_region_set, Cint, (Cint,), n)
@noinline region_reset(n)           = UInt64(ccall(:jl_gc_region_reset, UInt64, (Cint,), n))
@noinline region_pages(n)           = Int(ccall(:jl_gc_region_pages, Cint, (Cint,), n))
@noinline region_census!(pages)     = ccall(:jl_gc_region_census_threshold, Cvoid, (Cint,), pages)
@noinline quarantined(n)            = Int(ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)) != 0
const LEAF = 1
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

# A small pool object, so its allocation lands on a region POOL page (a big
# Vector would go through malloc instead). Each is boxed because it is stored
# into a Vector -- so it is genuinely heap-allocated garbage.
mutable struct Sm; v::Int; end

# A window that churns pool garbage: `rounds` batches, each a fresh Vector of
# `per` Sm objects, summed into a live accumulator. The prior batch is dead the
# moment the next Vector replaces it. Returns (accumulator, peak region pages).
@noinline function churn(rounds, per)
    region_set(LEAF)
    acc = 0
    peak = 0
    for r in 1:rounds
        batch = Vector{Sm}(undef, per)      # the previous batch is now dead
        @inbounds for i in 1:per; batch[i] = Sm((r * i) & 0xffff); end
        s = 0
        @inbounds for i in 1:per; s += batch[i].v; end
        acc += s
        p = region_pages(LEAF)
        p > peak && (peak = p)
    end
    region_set(0)
    region_reset(LEAF)
    (acc, peak)
end

# Same rounds and size both ways, so the accumulator is identical.
const ROUNDS = 40000
const PER = 256          # 256 pool objects per batch; 40000 batches = ~10 M objects

churn(100, PER)          # warm: churn compiles at region 0 on first call

# Disarmed: the region holds every batch until the reset -- it grows.
region_census!(0)
acc_off, peak_off = churn(ROUNDS, PER)

# Armed at a low threshold: the census reclaims the dead batches in place, so
# the region stays near the threshold instead of growing to the whole churn.
region_census!(64)       # 64 pages ~ 1 MB
acc_on, peak_on = churn(ROUNDS, PER)
region_census!(0)

println("churn ", ROUNDS, " x ", PER, " pool objects  (~", ROUNDS*PER*16 ÷ (1024*1024), " MB total)")
println("disarmed: peak region pages ", peak_off, " (~", peak_off*16 ÷ 1024, " MB)")
println("armed:    peak region pages ", peak_on,  " (~", peak_on*16 ÷ 1024, " MB)")
check("same accumulator both ways", acc_off == acc_on)
check("armed census bounds the region", peak_on < peak_off ÷ 4)
check("armed census keeps it near the threshold", peak_on < 4000)   # << the 640 MB churn
check("no quarantine", !quarantined(LEAF))

if failures[] == 0
    println("REGION CENSUS BOUND: ALL PASS")
else
    println("REGION CENSUS BOUND: ", failures[], " FAILURES")
end
