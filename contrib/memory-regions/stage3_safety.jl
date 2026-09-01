# The stage-3 safety items, tested: the finalizer gate (rule: finalizers
# only on root-region objects) and the rule-5 reset precondition (a reset
# refuses while an execution root still references into the region).
#
#   ../../julia stage3_safety.jl

include("regions.jl")
using .Regions

@noinline opaque(x) = (x === nothing && error("nothing"); nothing)

# The finalizer must carry a side effect: the compiler elides the whole
# registration of an effect-free finalizer (or inlines it at scope end),
# and then no runtime gate can see it.
fin_count = 0
@noinline count_fin(x) = (global fin_count += 1; nothing)

const REFUSED = typemax(UInt64)

mutable struct Thing
    x::Int
end

failures = 0
function check(name, ok)
    global failures
    ok || (failures += 1)
    println(name, ": ", ok ? "pass" : "FAIL")
end

region_debug(1)

# 1. A finalizer on a region object must throw at registration.
@noinline function finalizer_on_region()
    region_set(1)
    t = Thing(1)
    # Pin the materialization inside the window: an allocation moves to its
    # first use, and without a use here LLVM sinks it past region_set(0).
    Base.donotdelete(t)
    region_set(0)
    # The object must escape, and the finalizer must have a side effect:
    # the compiler elides the registration otherwise. And the catch must
    # sit at the INTERPRETED top level: the compiler models Core.finalizer
    # as nothrow and may move it out of a compiled catch region, so the
    # gate's error acts as a trap, like the store barrier.
    opaque(t)
    finalizer(count_fin, t)
    return false
end
caught = try
    finalizer_on_region()
catch e
    occursin("region", sprint(showerror, e))
end
check("finalizer on a region object throws", caught === true)
check("reset after the finalizer test", region_reset(1) != REFUSED)

# 2. A finalizer on a root-region object still works.
let t0 = Thing(2)
    ok = try
        finalizer(count_fin, t0)
        true
    catch
        false
    end
    check("finalizer on a root object works", ok)
end

# 3. The reset refuses while a stack root references into the region,
#    and succeeds after the reference dies.
@noinline function hold_and_try()
    region_set(1)
    obj = Ref(42)
    Base.donotdelete(obj)
    opaque(obj)
    region_set(0)
    # A micro-test must fight the optimizer on two fronts: the object needs
    # a boxing use (the region_of ccall) so it MATERIALIZES on the heap,
    # and GC.@preserve so it sits PINNED in the scannable GC frame across
    # the reset. The scan sees the precise safepoint root set -- real model
    # state, held in data structures across safepoints, needs neither trick
    # (the stage-5 table is found plainly).
    rof = region_of(obj)
    r = GC.@preserve obj region_reset(1)     # must refuse
    v = obj[]
    return rof, r, v
end
rof, r, v = hold_and_try()
check("the object lives in the region", rof == 1)
check("reset refused while referenced", r == REFUSED && v == 42)
check("object intact after the refusal", v == 42)
check("reset succeeds once the reference dies", region_reset(1) != REFUSED)
check("explicit check reports zero afterwards", region_check(1) == 0)

println(failures == 0 ? "STAGE3 SAFETY: ALL PASS" : "STAGE3 SAFETY: $(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
