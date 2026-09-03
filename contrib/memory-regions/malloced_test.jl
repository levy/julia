# Stage-1c acceptance: a memory whose data is malloc'd (a Vector over
# ~2 KB) may die inside a region. Its data is freed by the reset (the
# old corruption AND the old leak), and a census frees the dead ones
# while the live keep their data. The RSS bound proves the free.
region_set(n)   = ccall(:jl_gc_region_set, Cint, (Cint,), n)
region_reset(n) = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
region_coop(n)  = ccall(:jl_gc_region_collect_coop, Int64, (Cint,), n)
const SIM = 1
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

function churn(iters)
    for i in 1:iters
        region_set(SIM)
        v = Vector{Float64}(undef, 4096)      # 32 KB, malloc'd data
        v[1] = i; v[end] = i
        region_set(0)
        region_reset(SIM)
    end
end
churn(10)                                      # warm
GC.gc()
rss0 = Sys.maxrss()
churn(20_000)                                  # 640 MB of data if leaked
check("the reset frees malloc'd data (RSS bound)", Sys.maxrss() - rss0 < 100e6)
GC.gc()                                        # the old corruption fired here
check("a full collection after the churn is clean", true)

# The census: live memories keep their data, dead ones are freed. The
# shape of this part is dictated by three rules the barrier enforces:
# locals, not globals (a global may not hold a region object); no
# reassignment of a captured variable (the compiler's Box lives in
# region 0 and a window store into it is an escape); and the reset runs
# only after the frame that referenced the survivors is gone (rule 4).
# The opaque consumer, so allocation elision can not delete the dead
# vectors (the record's de-elision lesson, replayed).
@noinline consume(v) = (v[1] = 0.0; nothing)

@noinline function census_inner()
    region_set(SIM)
    keep = [Vector{Float64}(undef, 1024) for _ in 1:8]
    for (i, v) in enumerate(keep); fill!(v, i); end
    for _ in 1:64; consume(Vector{Float64}(undef, 1024)); end   # dead
    region_set(0)
    freed = region_coop(SIM)
    live_ok = all(keep[i][7] == i for i in 1:8)
    return freed, live_ok
end
function census_part()
    GC.enable(false)
    freed, live_ok = census_inner()
    check("the census ran (got $freed)", freed >= 64)
    check("the live memories kept their data", live_ok)
    region_reset(SIM)          # the inner frame is gone: nothing points in
    GC.enable(true)
end
census_part()
GC.gc()
println(failures[] == 0 ? "MALLOCED: ALL PASS" : "MALLOCED: $(failures[]) FAILURES")
