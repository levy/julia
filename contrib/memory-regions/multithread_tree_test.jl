# Region-tree, the multi-thread shape. Three worker threads share one trunk
# region under a lock; each thread churns its OWN leaf region (a distinct id,
# so a cross-thread leaf-to-leaf store is detectable, which the same-id chain
# could not even see). The trunk resets once at the end, across every heap.
#   run with: julia -t4 multithread_tree_test.jl
@noinline region_set(n)         = ccall(:jl_gc_region_set, Cint, (Cint,), n)
@noinline region_reset(n)       = UInt64(ccall(:jl_gc_region_reset, UInt64, (Cint,), n))
@noinline region_reset_global(n) = UInt64(ccall(:jl_gc_region_reset_global, UInt64, (Cint,), n))
@noinline region_parent!(c, p)  = ccall(:jl_gc_region_declare_parent, Cint, (Cint, Cint), c, p)
@noinline quarantined(n)        = Int(ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)) != 0
ok(r) = r < typemax(UInt64) - 8

const TRUNK = 1
# One leaf per worker; leaf id = 1 + tid so ids are distinct across threads.
leaf_of(tid) = 1 + tid
const NWORKERS = 3
failures = Threads.Atomic{Int}(0)
check(name, cond) = (cond || (Threads.atomic_add!(failures, 1); println("FAIL: ", name)))

# Declare the tree: every worker's leaf is a child of the shared trunk.
for w in 1:NWORKERS
    region_parent!(leaf_of(w), TRUNK)
end

mutable struct Cell; f::Any; end
const LK = ReentrantLock()
const COUNTER = Ref(0)                 # region-0 shared state, guarded by LK

# Build the trunk content once, single-threaded, before the workers run. The
# trunk is held on the STACK (a region-0 global may not hold a younger-region
# object - that is an escape), and shared with the workers by capture.
@noinline function build_trunk()
    region_set(TRUNK)
    t = Cell(777)
    region_set(0)
    t
end
@noinline function worker(w, trunk)
    leaf = leaf_of(w)
    for round in 1:50
        region_set(leaf)
        c = Cell(nothing)
        for _ in 1:500; c = Cell(c); end
        region_set(0)
        c.f = trunk                   # leaf -> trunk edge: legal, each round
        # Shared work under the lock: a region-0 counter, no region object
        # stored anywhere older than itself. This is the disciplined pattern.
        lock(LK) do
            COUNTER[] += 1
        end
        check("worker $w round $round leaf reset", ok(region_reset(leaf)))
    end
end

# The trunk must never touch a module global (region 0): a top-level
# `trunk_obj = ...` would store it into a region-0 Binding and escape. So the
# whole driver runs in a function, where the trunk is a stack local.
function main()
    trunk_obj = build_trunk()
    Threads.@threads for w in 1:NWORKERS
        worker(w, trunk_obj)
    end
    check("trunk survived the workers", (trunk_obj.f == 777))
    check("shared counter reached every round", COUNTER[] == NWORKERS * 50)
    check("no leaf was quarantined", !any(quarantined(leaf_of(w)) for w in 1:NWORKERS))
    check("trunk not quarantined", !quarantined(TRUNK))
    # The trunk resets once, across every heap, after the workers are done. Do
    # not read trunk_obj after this: its pages are freed.
    r = region_reset_global(TRUNK)
    check("global trunk reset succeeds", ok(r))
    return nothing
end
main()

if failures[] == 0
    println("MULTITHREAD TREE: ALL PASS")
else
    println("MULTITHREAD TREE: ", failures[], " FAILURES")
end
