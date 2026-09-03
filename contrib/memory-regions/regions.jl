# The Julia face of the runtime regions. Requires the build of this branch,
# `../../julia` after `make` (jl_gc_region_set / _reset / _current / _overflow).

module Regions

export region_set, region_reset, region_reserve, @with_region, region_current, region_overflow, region_of,
       region_collect, region_collect_coop, region_check, region_debug,
       region_parent!, region_tree!, region_parent_of, region_reset_global

# Declare the region tree. A region's number is a topological order of the
# tree: a parent's number is smaller than its child's. The default, until
# a declaration, is the chain 0 <- 1 <- 2 <- ..., so an object of region r
# may reference its own region and every older one. A declaration lets two
# leaves over a shared trunk be mutually isolated: neither may reference the
# other, only their common ancestors.
region_parent!(child::Int, parent::Int) =
    (ccall(:jl_gc_region_declare_parent, Cint, (Cint, Cint), child, parent) == 0 ||
     error("bad region edge: parent ($parent) must be >= 0 and < child ($child)"))
region_parent_of(child::Int) = Int(ccall(:jl_gc_region_parent_of, Cint, (Cint,), child))
# Declare the whole tree at once: parents[i] is the parent of region i, for
# i = 1.. (region 0 is the root and takes no entry). parents[i] < i.
function region_tree!(parents::AbstractVector{<:Integer})
    for child in 1:length(parents)
        region_parent!(child, Int(parents[child]))
    end
    return nothing
end

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
#     const EVENT = 3          # the caller names its own slots
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
# region_reset returns the pages reclaimed, or an error as (UInt64)-k:
# -1 a root references in (debug mode), -2 quarantined, -7 a live child
# region still exists (reset it first -- the tree precondition).
@noinline region_reset(n::Int)   = UInt64(ccall(:jl_gc_region_reset, UInt64, (Cint,), n))
# The cross-heap reset of a shared region (a trunk): stops the world and
# resets every thread heap's instance as one act, because trunk objects on
# different heaps legally reference each other. Same error codes as the
# single-heap reset, plus -3 for a lost safepoint race.
@noinline region_reset_global(n::Int) = UInt64(ccall(:jl_gc_region_reset_global, UInt64, (Cint,), n))
@noinline region_check(n::Int)   = Int64(ccall(:jl_gc_region_check, Int64, (Cint,), n))
@noinline region_collect(n::Int) = Int64(ccall(:jl_gc_region_collect, Int64, (Cint,), n))
# The cooperative census: no stop-the-world. The driving loop calls it at
# a quiet boundary under the single-mutator contract; -4 means another
# thread runs managed code and the STW entry must be used instead.
@noinline region_collect_coop(n::Int) = Int64(ccall(:jl_gc_region_collect_coop, Int64, (Cint,), n))

end # module Regions
