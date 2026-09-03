# Region-tree stage 3: the reset precondition. A region with a live child
# must not reset -- a leaf holds a legal reference into its trunk, which the
# trunk's reset would dangle -- so the leaf resets first. The check is one
# bit per heap. Tree: trunk 1, leaves 2 and 3 under it.
@noinline region_set(n)        = ccall(:jl_gc_region_set, Cint, (Cint,), n)
@noinline region_reset(n)      = UInt64(ccall(:jl_gc_region_reset, UInt64, (Cint,), n))
@noinline region_parent!(c, p) = ccall(:jl_gc_region_declare_parent, Cint, (Cint, Cint), c, p)
const HASCHILD = typemax(UInt64) - 6   # (uint64)-7
const TRUNK = 1; const LEAF_A = 2; const LEAF_B = 3
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))
ok(r) = r < typemax(UInt64) - 8        # a real page count, not an error code

region_parent!(LEAF_A, TRUNK); region_parent!(LEAF_B, TRUNK)

mutable struct Box; f::Any; end
@noinline fill_region(n, k) = (region_set(n); local last=Box(nothing); for _ in 1:k; last=Box(last); end; region_set(0); last)

# Fill the trunk, then a leaf that references the trunk.
let
    trunk_obj = fill_region(TRUNK, 1000)
    leaf_obj = fill_region(LEAF_A, 1000)
    leaf_obj.f = trunk_obj              # legal leaf -> trunk edge
    # The trunk has a live child: its reset must refuse.
    check("reset trunk with a live leaf refuses", region_reset(TRUNK) == HASCHILD)
    # The leaf resets fine.
    check("reset leaf succeeds", ok(region_reset(LEAF_A)))
    # Now the trunk has no live child: its reset succeeds.
    check("reset trunk after the leaf succeeds", ok(region_reset(TRUNK)))
end

# Per-leaf churn: the leaf is set/filled/reset many times while the trunk
# stays live and intact. This is the shape the tree is for.
let
    trunk_obj = fill_region(TRUNK, 5000)
    trunk_obj.f = 424242
    for i in 1:200
        leaf = fill_region(LEAF_A, 2000)
        leaf.f = trunk_obj              # leaf references the live trunk each round
        check("leaf churn round $i resets", ok(region_reset(LEAF_A)))
    end
    check("trunk survives 200 leaf resets", trunk_obj.f == 424242)
    check("trunk resets last", ok(region_reset(TRUNK)))
end

if failures[] == 0
    println("RESET ORDER: ALL PASS")
else
    println("RESET ORDER: ", failures[], " FAILURES")
end
