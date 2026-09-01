# Stage 4, the paced hardware-in-the-loop run. Needs the patched build:
#
#   ../../julia --heap-size-hint=128M stage4_paced.jl baseline 1000000
#   ../../julia stage4_paced.jl regions 1000000
#
# One event fires per 100 us slot, on the wall clock: the loop spins to the
# slot deadline, processes the event, and (regions) resets the Event region.
# The lateness column is what the hardware feels: how late an event COMPLETES
# relative to its slot start. A collector pause makes the events behind it
# late; a miss is an event that completes after its whole slot has passed.
#
# `baseline` is the stage-0 alloc model with the collector ON — pass a heap
# hint so the collector actually fires inside the run, the way a pinned
# hardware box bounds memory. `regions` is the stage-3 model under the v1
# contract: the collector is off, reset is the only collector.

include("kernel.jl")
using .MiniKernel
include("regions.jl")
using .Regions
include("model_alloc.jl")
include("stage3_model.jl")

const PERIOD_NS = 100_000

function percentile(sorted::Vector{Int64}, p::Float64)
    isempty(sorted) && return 0
    sorted[clamp(ceil(Int, p * length(sorted)), 1, length(sorted))]
end

function run_paced!(network, use_regions::Bool, latencies_ns::Vector{Int64},
                    late_ns::Vector{Int64}, gc_ns::Vector{Int64})
    limit = length(latencies_ns)
    count = 0
    t0 = time_ns() + 1_000_000              # the first slot starts 1 ms out
    while !isempty(network.queue)
        count == limit && return count
        best = 1
        @inbounds for i in 2:length(network.queue)
            event, top = network.queue[i], network.queue[best]
            (event.time < top.time ||
             (event.time == top.time && event.sequence < top.sequence)) && (best = i)
        end
        event = network.queue[best]
        deleteat!(network.queue, best)
        network.time = event.time
        count += 1
        deadline = t0 + UInt64(count - 1) * UInt64(PERIOD_NS)
        while time_ns() < deadline; end     # spin to the slot start
        gc0 = Base.gc_num().total_time
        t1 = time_ns()
        event.action(network, event.environment)
        use_regions && region_reset(1)
        t2 = time_ns()
        gc1 = Base.gc_num().total_time
        @inbounds latencies_ns[count] = Int64(t2 - t1)
        @inbounds late_ns[count] = Int64(t2) - Int64(deadline)
        @inbounds gc_ns[count] = Int64(gc1 - gc0)
    end
    return count
end

function report(label, latencies, late_ns, gc_ns, count)
    lat = sort!(latencies[1:count])
    late = sort!(late_ns[1:count])
    misses = count - searchsortedlast(late, Int64(PERIOD_NS))
    gc_events = count - Base.count(iszero, view(gc_ns, 1:count))
    gc_total = sum(view(gc_ns, 1:count))
    println("=== ", label, " (paced, one event per 100 us slot) ===")
    println("events            ", count)
    println("latency p50       ", percentile(lat, 0.50), " ns")
    println("latency p99.9     ", percentile(lat, 0.999), " ns")
    println("latency max       ", lat[end], " ns")
    println("lateness p99.9    ", percentile(late, 0.999), " ns")
    println("lateness max      ", late[end], " ns")
    println("slot misses       ", misses, " events (",
            round(misses / count * 100; sigdigits = 3), " %)")
    println("gc events         ", gc_events)
    println("gc total          ", round(gc_total / 1e6; digits = 1), " ms")
end

function main()
    variant = ARGS[1]
    events = parse(Int, ARGS[2])
    relays = 4
    latencies = Vector{Int64}(undef, events)
    late_ns = Vector{Int64}(undef, events)
    gc_ns = Vector{Int64}(undef, events)
    deliveries = events ÷ (relays + 3) + 1

    warm_n = min(10_000, events)
    warm_lat = Vector{Int64}(undef, warm_n)
    warm_gc = Vector{Int64}(undef, warm_n)

    if variant == "baseline"
        network, sink = ModelAlloc.build(relays)
        run_measured!(network, warm_lat, warm_gc)      # compile, unpaced
        GC.gc()
        count = run_paced!(network, false, latencies, late_ns, gc_ns)
    elseif variant == "regions"
        network, sink = Stage3Model.build(relays, deliveries; use_regions = true)
        warm_late = Vector{Int64}(undef, warm_n)
        run_paced!(network, true, warm_lat, warm_late, warm_gc)
        region_reset(1)
        # The v1 contract: no collection once region pages exist. The report
        # path compiles here, before the measured phase.
        report("warm", warm_lat, warm_late, warm_gc, warm_n)
        GC.enable(false)
        count = run_paced!(network, true, latencies, late_ns, gc_ns)
        println("overflow pages    ", region_overflow(1))
    else
        error("variant must be baseline or regions")
    end
    report(variant, latencies, late_ns, gc_ns, count)
    println("live heap         ", round(Base.gc_live_bytes() / 1e6; digits = 1), " MB")
end

main()
