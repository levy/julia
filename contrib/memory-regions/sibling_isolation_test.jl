# Region-tree stage 1+2: a declared tree isolates sibling leaves. The chain
# could not express this - two leaves over one trunk, where a store from one
# leaf into the other is an escape in BOTH directions, while a leaf may still
# reference the trunk. Tree: region 1 is the trunk, regions 2 and 3 are leaves
# whose parent is the trunk.
@noinline region_set(n)      = ccall(:jl_gc_region_set, Cint, (Cint,), n)
@noinline region_parent!(c, p) = ccall(:jl_gc_region_declare_parent, Cint, (Cint, Cint), c, p)
@noinline quarantined(n)     = Int(ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)) != 0
const TRUNK = 1
const LEAF_A = 2
const LEAF_B = 3
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

# Declare the tree: leaves 2 and 3 are children of trunk 1.
check("declare leaf A under trunk", region_parent!(LEAF_A, TRUNK) == 0)
check("declare leaf B under trunk", region_parent!(LEAF_B, TRUNK) == 0)
check("a forward parent is rejected", region_parent!(1, 2) == -1)  # parent >= child
check("parent-of leaf A is the trunk",
      Int(ccall(:jl_gc_region_parent_of, Cint, (Cint,), LEAF_A)) == TRUNK)

mutable struct Box; f::Any; end
@noinline make(n) = (region_set(n); b = Box(nothing); region_set(0); b)
@noinline store!(p, c) = (p.f = c; nothing)   # setfield fires the barrier

# 1. A leaf may reference the trunk (an ancestor): legal, no quarantine.
let trunk_obj = make(TRUNK), leaf = make(LEAF_A)
    store!(leaf, trunk_obj)
    check("leaf -> trunk is legal", !quarantined(LEAF_A) && !quarantined(TRUNK))
end

# 2. One leaf may NOT reference its sibling: escape, quarantines the child.
let a = make(LEAF_A), b = make(LEAF_B)
    check("leaf B not yet quarantined", !quarantined(LEAF_B))
    store!(a, b)                                # store a leaf-B child into leaf-A
    check("leaf A <- leaf B sibling store quarantines B", quarantined(LEAF_B))
end

# 3. The trunk may NOT reference a leaf (a descendant): escape.
let trunk_obj = make(TRUNK), leaf = make(LEAF_A)
    store!(trunk_obj, leaf)
    check("trunk <- leaf descendant store quarantines the leaf", quarantined(LEAF_A))
end

if failures[] == 0
    println("SIBLING ISOLATION: ALL PASS")
else
    println("SIBLING ISOLATION: ", failures[], " FAILURES")
end
