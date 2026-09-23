# The cost of a deferred collection: the allocation rate of a loop that runs with
# the collector disabled after the heap crossed its target.
#
#   julia deferral.jl [blocks] [allocations per block]
#
# The loop keeps 1024 objects alive in a ring and allocates the rest as garbage.
# With GC.enable(false), every allocation past the heap target enters
# jl_gc_collect and is deferred there. On a runtime whose deferral leaves the
# heap target where it was, every following allocation walks in again; on one
# whose deferral re-arms the target, the walk happens once per allowance. The
# row is the median nanoseconds per allocation over the second half of the
# blocks, the part past the target.
include(joinpath(@__DIR__, "report.jl"))

mutable struct Cell; v::Int; end

@noinline function block!(ring, n, base)
    @inbounds for i in 1:n
        ring[(i & 1023) + 1] = Cell(base + i)
    end
    return nothing
end

function main()
    blocks = parse(Int, get(ARGS, 1, "60"))
    n = parse(Int, get(ARGS, 2, "1000000"))
    ring = Vector{Any}(undef, 1024)
    block!(ring, n, 0)                       # compile
    GC.gc()
    d0 = Base.gc_num().deferred_alloc
    GC.enable(false)
    ns = zeros(Float64, blocks)
    for b in 1:blocks
        t = time_ns()
        block!(ring, n, b * n)
        ns[b] = (time_ns() - t) / n
    end
    deferred_mb = (Base.gc_num().deferred_alloc - d0) / 1e6
    GC.enable(true)
    half = sort(ns[(blocks ÷ 2 + 1):end])
    med = half[(length(half) + 1) ÷ 2]
    println("blocks            ", blocks, " of ", n, " allocations")
    println("first half        ", round(sort(ns[1:blocks ÷ 2])[(blocks ÷ 4) + 1]; digits = 2), " ns per allocation, median")
    println("second half       ", round(med; digits = 2), " ns per allocation, median")
    println("live heap         ", round(Base.gc_live_bytes() / 1e6; digits = 1), " MB")
    println("deferred          ", round(deferred_mb; digits = 1), " MB of allocation deferred")
    tsv_row(("blocks", "allocations", "ns_per_alloc_first_half", "ns_per_alloc_second_half", "deferred_mb"),
            (blocks, n, sort(ns[1:blocks ÷ 2])[(blocks ÷ 4) + 1], med, deferred_mb))
end

main()
