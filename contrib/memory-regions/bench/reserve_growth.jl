# The heap reserve, measured directly: the minor page faults of this process
# while the pool heap grows by about 110 MB of small objects that stay
# alive, with and without `jl_gc_heap_reserve` before the growth. The vector
# that holds the objects is allocated and written before the count, so the
# faults are those of the pool pages. Master has no reserve and runs with
# RESERVE_MB=0 only.
#
#   julia reserve_growth.jl          RESERVE_MB=0 or 512 in the environment
include("report.jl")

minflt() = parse(Int, split(read("/proc/self/stat", String))[10])
heap_reserve(bytes) = UInt64(ccall(:jl_gc_heap_reserve, UInt64, (UInt64,), bytes))

const N = 4_000_000
keep = Vector{Any}(nothing, N)
reserve_mb = parse(Int, get(ENV, "RESERVE_MB", "0"))
mapped = reserve_mb > 0 ? heap_reserve(reserve_mb * 1_000_000) : UInt64(0)
GC.gc(); GC.gc()
f0 = minflt()
for i in 1:N
    keep[i] = Ref(i)
end
faults = minflt() - f0
live_mb = round(Base.gc_live_bytes() / 1e6; digits = 1)
println("reserve ", reserve_mb, " MB asked, ", mapped ÷ 1_000_000, " MB mapped; ", faults,
        " page faults while the heap grew to ", live_mb, " MB live")
tsv_row(["reserve_mb", "mapped_mb", "faults", "live_mb"], [reserve_mb, mapped ÷ 1_000_000, faults, live_mb])
