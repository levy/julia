# The face of regions.jl for a julia built without the regions (WITH_GC_REGIONS=0):
# every entry is a no-op that answers "no region", so that a benchmark's stock or
# baseline mode runs on a stock build. region_reserve is real where the runtime has
# jl_gc_heap_reserve (the base branch), and raises where it has not (master).
module Regions
export region_set, region_reset, unsafe_region_reset, region_reset_global, region_pages,
       region_quarantined, region_of, region_current, region_collect, region_collect_coop, region_coop,
       region_stat, region_verify, region_check, region_debug, region_declare_parent,
       region_census_threshold, region_reserve, @with_region, @in_region_of
region_set(n) = -1
region_reset(n) = UInt64(0)
unsafe_region_reset(n) = UInt64(0)
region_reset_global(n) = UInt64(0)
region_pages(n) = 0
region_quarantined(n) = false
region_of(x) = 0
region_current() = 0
region_collect(n) = 0
region_coop(n) = 0
region_collect_coop(n) = 0
region_stat(i) = 0
region_verify(n) = 0
region_check(n) = 0
region_debug(on) = nothing
region_declare_parent(child, parent) = nothing
region_census_threshold(pages) = nothing
region_reserve(bytes::Integer) = UInt64(ccall(:jl_gc_heap_reserve, UInt64, (UInt64,), bytes))
macro with_region(n, body); esc(body); end
macro in_region_of(like, body); esc(body); end
end
