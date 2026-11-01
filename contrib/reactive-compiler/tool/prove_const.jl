# Does a change to a constant invalidate the code that used it?
#
# This is the hazard in the design: `f(x) = x * SCALE` may hold the value of
# SCALE in its compiled code, so the source hash of `f` is unchanged while its
# native code is wrong. The forward edges of a CodeInstance do not record SCALE
# at all, which was measured on the synthetic application. The question here is
# whether Julia invalidates through some other route, and whether the backedges
# see it.
#
# Run: julia --startup-file=no tool/prove_const.jl

const HERE = @__DIR__
const ROOT = dirname(HERE)
include(joinpath(ROOT, "src", "GraphHarvest.jl"))
using .GraphHarvest

const ALIVE = typemax(UInt)

module Subject
    const SCALE = 10
    # Uses the constant. Inference is free to put 10 into the code.
    f(x) = x * SCALE
    # Uses f.
    h(x) = f(x) + 1
    # Uses neither.
    g(x) = x + 1
end

println("### compile")
for fn in (Subject.f, Subject.h, Subject.g)
    fn(2)
end
println("    f(2) = ", Subject.f(2), "   h(2) = ", Subject.h(2))

function entry(fn, argtypes)
    sig = Tuple{typeof(fn),argtypes...}
    for m in methods(fn), mi in GraphHarvest.specializations_of(m)
        mi.specTypes === sig && return mi
    end
    return nothing
end

mis = Dict("f" => entry(Subject.f, (Int,)),
           "h" => entry(Subject.h, (Int,)),
           "g" => entry(Subject.g, (Int,)))
cis = Dict(k => GraphHarvest.code_instances(v) for (k, v) in mis)
worlds = Dict(k => map(ci -> ci.max_world, v) for (k, v) in cis)
for k in ("f", "h", "g")
    println("    ", k, ": CIs=", length(cis[k]),
            "  max_world=", join([w == ALIVE ? "alive" : string(w) for w in worlds[k]], ","))
end

# Does the graph see the constant at all?
g_graph = GraphHarvest.harvest([Subject])
println("### does the dependency data mention SCALE?")
found_binding = false
for b in keys(g_graph.binding_users)
    name = try string(b.globalref) catch; string(b) end
    if occursin("SCALE", name)
        global found_binding = true
        println("    forward edges record it: ", name)
    end
end
found_binding || println("    forward edges do NOT record it")

# And the backedges of Julia?
be = GraphHarvest.backedge_cone([mis["f"]])
println("    backedge cone of f = ", sort([string(m.def isa Method ? m.def.name : m.def) for m in be]))

println("### change the constant from 10 to 20")
log = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
changed = try
    Core.eval(Subject, :(const SCALE = 20))
    true
catch e
    println("    the redefinition threw: ", first(string(e), 120))
    false
end
ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
println("    log entries = ", length(log))

println("### after")
for k in ("f", "h", "g")
    now = map(ci -> ci.max_world, cis[k])
    still = GraphHarvest.code_instances(mis[k])
    gone = count(ci -> !any(x -> x === ci, still), cis[k])
    println("    ", k, ": max_world=",
            join([w == ALIVE ? "alive" : string(w) for w in now], ","),
            "   entries dropped from the cache = ", gone)
end
println("    f(2) = ", Subject.f(2), "   (20 x 2 = 40 if the change took effect)")
println("    h(2) = ", Subject.h(2), "   (41 if it did)")

println()
println("### verdict")
ok_f = Subject.f(2) == 40
ok_h = Subject.h(2) == 41
println("    f sees the new constant: ", ok_f ? "yes" : "NO  <- stale code")
println("    h sees the new constant: ", ok_h ? "yes" : "NO  <- stale code")
println("    the forward edges recorded the constant: ", found_binding)
