# This file is a part of Julia. License is MIT: https://julialang.org/license

# The runtime entries of the GC regions (src/gc-regions.h), as the five
# regions_*.jl scripts call them, and the harness the scripts share. The
# scripts run under test/gc.jl's run_gctest, one process each, and exit 1
# at the first failed check.

region_set(n)              = Int(ccall(:jl_gc_region_set, Cint, (Cint,), n))
region_current()           = Int(ccall(:jl_gc_region_current, Cint, ()))
region_reset(n)            = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
region_reset_global(n)     = ccall(:jl_gc_region_reset_global, UInt64, (Cint,), n)
declare_parent(c, p)       = Int(ccall(:jl_gc_region_declare_parent, Cint, (Cint, Cint), c, p))
parent_of(c)               = Int(ccall(:jl_gc_region_parent_of, Cint, (Cint,), c))
region_collect(n)          = Int(ccall(:jl_gc_region_collect, Int64, (Cint,), n))
region_collect_coop(n)     = Int(ccall(:jl_gc_region_collect_coop, Int64, (Cint,), n))
census_threshold!(pages)   = ccall(:jl_gc_region_census_threshold, Cvoid, (Cint,), pages)
region_of(x)               = Int(ccall(:jl_gc_region_of, Cint, (Any,), x))
region_pages(n)            = Int(ccall(:jl_gc_region_pages, Cint, (Cint,), n))
quarantined(n)             = Int(ccall(:jl_gc_region_quarantined, Cint, (Cint,), n))
region_stat(i)             = ccall(:jl_gc_region_stat, UInt64, (Cint,), i)
region_debug!(on)          = ccall(:jl_gc_region_set_debug, Cvoid, (Cint,), on)
region_check(n)            = Int(ccall(:jl_gc_region_check, Int64, (Cint,), n))
region_verify(n)           = Int(ccall(:jl_gc_region_verify, Cint, (Cint,), n))
heap_reserve(bytes)        = ccall(:jl_gc_heap_reserve, UInt64, (UInt64,), bytes)

# The refusal codes of gc-regions.h.
const EINVAL = -1; const EBUSY = -2; const ERACE = -3; const EUNSAFE = -4
const EQUARANTINED = -5; const EFINALIZERS = -6; const ECHILD = -7; const EROOT = -8

# A count that an entry returns as UInt64 is a refusal when it is a code
# cast to the unsigned type: (uint64_t)-2 stands for -2.
code(r::UInt64) = r > typemax(UInt64) - 16 ? -Int(typemax(UInt64) - r) - 1 : Int(r)
refused(r::UInt64) = code(r) < 0

# The harness: the first failed check ends the process with exit code 1.
const CHECKS = Ref(0)
function check(name, cond)
    if !cond
        println(stderr, "FAIL: ", name)
        flush(stderr)
        exit(1)
    end
    CHECKS[] += 1
    return nothing
end
finish(script) = println(script, ": ", CHECKS[], " checks passed")

# The compiler removes an allocation that does not escape, and inlines the
# finalizer of such an object at its last use: no object is allocated and no
# finalizer is registered. An object a test needs in a region must escape.
# `escape` hands it to the runtime, which the compiler cannot see through.
@noinline escape(x) = region_of(x)

# Allocate and drop pool objects in region 0, so freed cells get reused.
@noinline function churn(n = 2_000_000)
    v = Vector{Any}(undef, 1024)
    for i in 1:n
        v[(i & 1023) + 1] = Ref(i)
    end
    return length(v)
end
