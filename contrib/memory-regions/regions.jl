# The Julia face of the runtime regions. Requires the build of this branch,
# `../../julia` after `make` (jl_gc_region_set / _reset / _current / _overflow).

module Regions

export region_set, region_reset, region_reserve, @with_region, region_current, region_overflow, region_of,
       region_collect, region_collect_coop, region_check, region_debug

region_set(n::Int)     = Int(ccall(:jl_gc_region_set, Cint, (Cint,), n))
region_current()       = Int(ccall(:jl_gc_region_current, Cint, ()))
region_overflow(n::Int) = UInt64(ccall(:jl_gc_region_overflow, UInt64, (Cint,), n))
region_of(x)           = Int(ccall(:jl_gc_region_of, Cint, (Any,), x))
region_debug(on::Int)  = ccall(:jl_gc_region_set_debug, Cvoid, (Cint,), on)
# Claim and prefault `bytes` of heap before the loop starts: the runtime
# maps whole blocks, populated by the kernel at the claim, into its clean
# pool, and prefaults every later block too. A loop whose heap fits the
# reserve takes no page fault while it runs. Returns the bytes mapped.
region_reserve(bytes::Integer) = UInt64(ccall(:jl_gc_region_reserve, UInt64, (UInt64,), bytes))

# The readable form of a window: run the body with region `n` current and
# come back to the region that was current before, however the body leaves
# (return, break, or a throw). Measured, the try/finally adds nothing over
# the bare region_set pair (10.35 against 10.39 ns for the enter-and-leave).
#
#     @with_region EVENT begin
#         process_event!(...)
#     end
macro with_region(n, body)
    quote
        local prev = region_set($(esc(n)))
        try
            $(esc(body))
        finally
            region_set(prev)
        end
    end
end

# The reset, the check, and the scoped collect are @noinline JULIA calls on
# purpose: a plain ccall is not a safepoint, so the caller would keep live
# references in registers where the precise stack scan cannot see them. A
# Julia call is a safepoint boundary -- the caller spills every live value
# into its GC frame, which is exactly what the rule-5 scan reads.
@noinline region_reset(n::Int)   = UInt64(ccall(:jl_gc_region_reset, UInt64, (Cint,), n))
@noinline region_check(n::Int)   = Int64(ccall(:jl_gc_region_check, Int64, (Cint,), n))
@noinline region_collect(n::Int) = Int64(ccall(:jl_gc_region_collect, Int64, (Cint,), n))
# The cooperative census: no stop-the-world. The ENGINE calls it at an
# event boundary under the single-mutator contract; -4 means another
# thread runs managed code and the STW entry must be used instead.
@noinline region_collect_coop(n::Int) = Int64(ccall(:jl_gc_region_collect_coop, Int64, (Cint,), n))

end # module Regions
