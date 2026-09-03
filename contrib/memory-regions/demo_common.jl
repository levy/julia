# Shared harness for the regions-vs-stock demonstrators. One `measure` that
# records the reliable per-run deltas the plan's honesty bar asks for, and an
# interleaved A/B/A/B driver so a noisy neighbour shows as A-against-A, not a
# false win.
#
# The headline metrics are per-run and trustworthy: stock collection count and
# total GC time (both deltas of Base.gc_num over the run). Region runs drive
# these to zero on the transients; that IS the claim. Peak RSS resets its
# high-water mark per run via /proc/self/clear_refs where the kernel allows.
module DemoCommon

using Printf
export measure, ab, Metrics, report_table

@noinline region_quarantined(n) = Int(ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)) != 0

struct Metrics
    wall_ms::Float64
    collections::Int
    gc_ms::Float64
    peak_rss_mb::Float64
end

function reset_peak_rss()
    try
        open("/proc/self/clear_refs", "w") do io
            write(io, "5")     # 5 = reset the VmHWM peak
        end
    catch
    end
end

function vmhwm_mb()
    hwm = 0
    for line in eachline("/proc/self/status")
        if startswith(line, "VmHWM:")
            hwm = parse(Int, split(line)[2])   # KB
            break
        end
    end
    hwm / 1024
end

# Run `f()` once and record the per-run deltas. `f` returns its own result,
# which the caller checks for A == B equality.
function measure(f)
    GC.gc(true)                       # clean slate, not counted
    reset_peak_rss()
    g0 = Base.gc_num()
    t0 = time_ns()
    result = f()
    t1 = time_ns()
    g1 = Base.gc_num()
    m = Metrics(
        (t1 - t0) / 1e6,
        g1.pause - g0.pause,
        (g1.total_time - g0.total_time) / 1e6,
        vmhwm_mb(),
    )
    (m, result)
end

# Interleaved A/B, min of `reps` by wall time. Returns (best_a, best_b, equal).
function ab(fa, fb; reps=5)
    pick(ms) = ms[argmin(m.wall_ms for m in ms)]
    as = Metrics[]; bs = Metrics[]; ra = nothing; rb = nothing
    for _ in 1:reps
        ma, ra = measure(fa); push!(as, ma)
        mb, rb = measure(fb); push!(bs, mb)
    end
    (pick(as), pick(bs), ra == rb)
end

row(name, a, b) = @printf("%-14s region %-10s stock %s\n", name, string(a), string(b))

function report_table(label, region::Metrics, stock::Metrics)
    println("== ", label)
    row("wall ms",     round(region.wall_ms; digits=1),  round(stock.wall_ms; digits=1))
    row("collections", region.collections,               stock.collections)
    row("gc ms",       round(region.gc_ms; digits=1),    round(stock.gc_ms; digits=1))
    row("peak RSS MB", round(region.peak_rss_mb; digits=1), round(stock.peak_rss_mb; digits=1))
    speedup = stock.wall_ms / region.wall_ms
    @printf("  wall speedup region/stock: %.2fx   gc eliminated: %.1f ms\n", speedup, stock.gc_ms - region.gc_ms)
end

end # module DemoCommon
