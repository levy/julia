# Stage 5, scoped collection: collect the Simulation region alone, and
# compare the pause against a full sweep. Needs the patched build.
#
#   ../../julia stage5_scoped.jl scoped 2000000 [every] [K]
#   ../../julia stage5_scoped.jl coop   2000000 [every] [K]
#   ../../julia stage5_scoped.jl pooled 2000000 [every] [K]
#   ../../julia stage5_scoped.jl full   2000000 [every] [K]
#   ../../julia stage5_scoped.jl auto   2000000 [every] [K]   (GC on, no explicit collects)
#   ../../julia stage5_scoped.jl batch  2000000 [every] [K] [W] [B]  (one Event window per B events)
#   ../../julia stage5_scoped.jl autopool 2000000 [every] [K] [W]    (the batch handler under stock GC)
#
# `pooled` is the ownership-style variant: records are UPDATED IN PLACE, so
# the Simulation region makes no garbage at all -- the C++ free-on-replace
# equivalent -- and its collect pause is the pure floor (stop-the-world +
# mark of the live set).
#
# The model: a Simulation-region table of K live records with turnover --
# every event replaces one slot, so the replaced record becomes garbage in
# the Simulation region -- plus Event-region scratch, reset every event.
# Every `every` events the driver collects. `scoped` collects ONLY the
# Simulation region (jl_gc_region_collect: mark from the execution roots
# through the region filter, sweep the region's own pages). `full` keeps
# everything in the ordinary heap and runs GC.gc(). Rule 3 is what makes
# the scoped mark small: no global and no older-region root can point into
# the region, so only the task stacks are walked.

region_set(n)     = ccall(:jl_gc_region_set, Cint, (Cint,), n)
region_reset(n)   = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
region_collect(n) = ccall(:jl_gc_region_collect, Int64, (Cint,), n)
region_coop(n)    = ccall(:jl_gc_region_collect_coop, Int64, (Cint,), n)
region_verify(n)  = ccall(:jl_gc_region_verify, Cint, (Cint,), n)
region_stat(i)    = ccall(:jl_gc_region_stat, UInt64, (Cint,), i)

mutable struct Record
    id::Int
    a::Float64
    b::Float64
end

@noinline _touch(v::Vector{Float64}) = (isempty(v) && error("empty"); nothing)

const SIM = 1
const EVENT = 2
# Live records in the Simulation region; the fourth argument overrides.
const K = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 10_000
# Scratch floats allocated per event (the garbage knob); the fifth
# argument overrides. 3 is light; 200 is ~1.6 KB per event.
const W = length(ARGS) >= 5 ? parse(Int, ARGS[5]) : 3
# The batch size for the `batch` variant: one Event window and one reset
# per B events; the sixth argument overrides.
const B = length(ARGS) >= 6 ? parse(Int, ARGS[6]) : 1

# The batch handler: scratch plus an in-place record update, with NO
# region calls inside -- the driver owns the window.
@noinline function handle_batch!(table::Vector{Record}, i::Int)
    scratch = Vector{Float64}(undef, W)
    @inbounds for j in 1:W
        scratch[j] = Float64(i + j)
    end
    _touch(scratch)
    acc = scratch[1] + scratch[end]
    slot = (i - 1) % K + 1
    r = table[slot]
    r.id = i
    r.a = acc
    r.b = 2 * acc
    return nothing
end

function build_table(use_regions::Bool)
    use_regions && region_set(SIM)
    table = Vector{Record}(undef, K)
    for i in 1:K
        table[i] = Record(i, 1.0, 2.0)
    end
    use_regions && region_set(0)
    return table
end

@noinline function handle!(table::Vector{Record}, i::Int, use_regions::Bool)
    # Event-region scratch: dies at the reset below.
    use_regions && region_set(EVENT)
    scratch = Vector{Float64}(undef, W)
    @inbounds for j in 1:W
        scratch[j] = Float64(i + j)
    end
    _touch(scratch)
    acc = scratch[1] + scratch[end]
    use_regions && region_set(0)
    use_regions && region_reset(EVENT)
    # Simulation-region turnover: the replaced record becomes garbage.
    use_regions && region_set(SIM)
    slot = (i - 1) % K + 1
    table[slot] = Record(i, acc, 2 * acc)
    use_regions && region_set(0)
    return nothing
end

# The ownership-style handler: the record is UPDATED, not replaced. No
# Simulation garbage exists, exactly like C++ freeing on replacement.
@noinline function handle_pooled!(table::Vector{Record}, i::Int)
    region_set(EVENT)
    scratch = Vector{Float64}(undef, W)
    @inbounds for j in 1:W
        scratch[j] = Float64(i + j)
    end
    _touch(scratch)
    acc = scratch[1] + scratch[end]
    region_set(0)
    region_reset(EVENT)
    slot = (i - 1) % K + 1
    r = table[slot]
    r.id = i
    r.a = acc
    r.b = 2 * acc
    return nothing
end

checksum(table) = (s = 0; for r in table; s += r.id; end; s)

function main()
    variant = ARGS[1]
    events = parse(Int, ARGS[2])
    use_regions = variant != "full" && variant != "auto" && variant != "autopool"
    coop = variant == "coop"
    every = length(ARGS) >= 3 ? parse(Int, ARGS[3]) : 100_000

    # The in-process full-sweep reference, before any region exists.
    t0 = time_ns(); GC.gc(); t1 = time_ns()
    println("full GC reference (startup): ", round((t1 - t0) / 1e6; digits = 2), " ms")

    # Under regions, the collector must not run while region 1 holds live
    # objects (a real collection would leave stale marks on the skipped
    # region pages). The scoped collector is region 1's only collector.
    use_regions && GC.enable(false)

    table = build_table(use_regions)
    # Warm on a throwaway table so compilation stays out of the wall time.
    let warm = build_table(use_regions)
        for i in 1:10_000
            if variant == "pooled"
                handle_pooled!(warm, i)
            elseif variant == "batch" || variant == "autopool"
                handle_batch!(warm, i)
            else
                handle!(warm, i, use_regions)
            end
        end
        use_regions && region_reset(EVENT)
    end
    pauses_ns = Int64[]
    freed_total = Int64(0)
    stats = zeros(UInt64, 8)
    t_wall0 = time_ns()
    variant == "batch" && region_set(EVENT)
    for i in 1:events
        if variant == "pooled"
            handle_pooled!(table, i)
        elseif variant == "batch" || variant == "autopool"
            handle_batch!(table, i)
        else
            handle!(table, i, use_regions)
        end
        if variant == "batch" && i % B == 0
            region_set(0)
            region_reset(EVENT)
            i < events && region_set(EVENT)
        end
        if i % every == 0 && variant != "auto" && variant != "batch" && variant != "autopool"
            if use_regions
                c0 = time_ns()
                f = coop ? region_coop(SIM) : region_collect(SIM)
                c1 = time_ns()
                f < 0 && error("region_collect failed: ", f)
                freed_total += f
                push!(pauses_ns, Int64(c1 - c0))
                for k in 1:8
                    stats[k] += region_stat(k - 1)
                end
                region_verify(SIM) == 0 && region_verify(EVENT) == 0 ||
                    error("verify failed after collect at event ", i)
            else
                c0 = time_ns(); GC.gc(); c1 = time_ns()
                push!(pauses_ns, Int64(c1 - c0))
            end
        end
    end

    if variant == "batch" && events % B != 0
        region_set(0)
        region_reset(EVENT)
    end
    t_wall1 = time_ns()
    wall_s = (t_wall1 - t_wall0) / 1e9
    pause_total_ms = sum(pauses_ns) / 1e6
    println("wall time          ", round(wall_s; digits = 3), " s (",
            round(events / wall_s / 1e6; digits = 2), " M events/s)")
    println("collection total   ", round(pause_total_ms; digits = 1), " ms (",
            round(pause_total_ms / 10 / wall_s; digits = 2), " % of wall)")
    # Correctness: slot s last written at event i = events - K + s.
    expect = K * (events - K) + K * (K + 1) ÷ 2
    got = checksum(table)
    println("table checksum     ", got == expect ? "correct" : "WRONG ($got vs $expect)")
    if use_regions && !isempty(pauses_ns)
        nc = length(pauses_ns)
        println("=== phase means over ", nc, " collections ===")
        println("stop-the-world     ", round(stats[2] / nc / 1e3; digits = 1), " us")
        println("mark               ", round(stats[3] / nc / 1e3; digits = 1), " us")
        println("sweep              ", round(stats[4] / nc / 1e3; digits = 1), " us")
        println("live cells kept    ", stats[5] ÷ nc)
        println("cells freed        ", stats[6] ÷ nc)
        println("pages walked       ", stats[7] ÷ nc)
        println("pages wholesale    ", stats[8] ÷ nc)
    end
    sort!(pauses_ns)
    println("=== ", variant, ": ", length(pauses_ns), " collections ===")
    if !isempty(pauses_ns)
        println("pause p50          ", round(pauses_ns[(end + 1) ÷ 2] / 1e6; digits = 3), " ms")
        println("pause max          ", round(pauses_ns[end] / 1e6; digits = 3), " ms")
    end
    use_regions && println("cells freed        ", freed_total,
                           " (turnover was ", events - K, " records + scratch)")
    println("live heap counter  ", round(Base.gc_live_bytes() / 1e6; digits = 1), " MB")
end

main()
