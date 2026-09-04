# The same proof as `prove_unrelated.jl`, but on a real application.
#
# Run it from the omnet-julia checkout:
#
#   julia --project=package/OmnetLegacyRoutingExample <this file>
#
# The question at this scale is not whether Julia invalidates correctly. The
# small proof settled that. The question is how much of a real application
# survives one edit, and whether the forward-edge graph still predicts the cone
# when the graph has tens of thousands of nodes.
#
# The measurement captures every CodeInstance by identity before the edit, then
# looks at the same objects afterwards. It does not count what is live after the
# edit: Julia re-infers eagerly during a redefinition, so an invalidated
# MethodInstance gains a fresh live entry almost at once and would look untouched.

const RC = get(ENV, "RC_SRC",
    "/home/projectured/workspace/julia-reactive/contrib/reactive-compiler/src")
include(joinpath(RC, "GraphHarvest.jl"))
include(joinpath(RC, "MethodEdit.jl"))
using .GraphHarvest
using .MethodEdit

const ALIVE = typemax(UInt)

println("### load the application")
t_load = @elapsed using OmnetLegacyRoutingExample
using OmnetSimulator
println("    load = ", round(t_load, digits = 2), " s")

const SCENARIO = Symbol(get(ENV, "RC_SCENARIO", "routing_small"))
println("### run scenario ", SCENARIO, " to compile the model")
t_run = @elapsed OmnetLegacyRoutingExample.run_scenario(SCENARIO)
println("    run = ", round(t_run, digits = 2), " s")

const ROOTS = Module[OmnetLegacyRoutingExample, OmnetSimulator]
const R = OmnetLegacyRoutingExample.Routing

"""
Record every CodeInstance of every node, by identity, with its world.
"""
function capture(g::Graph)
    owners = Vector{Vector{Core.CodeInstance}}(undef, length(g.nodes))
    worlds = Vector{Vector{UInt}}(undef, length(g.nodes))
    for (i, mi) in enumerate(g.nodes)
        cis = GraphHarvest.code_instances(mi)
        owners[i] = cis
        worlds[i] = map(ci -> ci.max_world, cis)
    end
    return owners, worlds
end

"""
Which nodes lost an entry that was open before.

There are two ways to lose one, and the small proof showed both. A method that
*depends* on the edited one keeps its `CodeInstance` object and has its
`max_world` closed. The edited method itself loses its specializations outright:
they leave the cache chain, and the object that is left still says its world is
open. Count both, or the edited method looks untouched.
"""
function invalidated(g::Graph, owners, worlds)
    out = Set{Int}()
    for i in eachindex(owners)
        isempty(owners[i]) && continue
        still = GraphHarvest.code_instances(g.nodes[i])
        for (ci, before) in zip(owners[i], worlds[i])
            before == ALIVE || continue
            if ci.max_world != ALIVE || !any(x -> x === ci, still)
                push!(out, i)
                break
            end
        end
    end
    return out
end

function names_in(g::Graph, indices, mods)
    out = Dict{String,Int}()
    for i in indices
        def = g.nodes[i].def
        def isa Method || continue
        def.module in mods || continue
        key = string(def.module, ".", def.name)
        out[key] = get(out, key, 0) + 1
    end
    return out
end

"""
Measure one edit: predict the cone, make the edit, compare with what happened.
"""
function measure_edit(label, method::Method)
    println()
    println("=== ", label, " : ", method.module, ".", method.name,
            " at ", basename(string(method.file)), ":", method.line)

    println("--- harvest")
    g = @time GraphHarvest.harvest(ROOTS)
    total = length(g.nodes)
    println("    nodes = ", total,
            "   edges = ", sum(length, g.forward; init = 0),
            "   codegen local = ", round(GraphHarvest.total_local_cost(g), digits = 2), " s")

    seeds = GraphHarvest.seeds_for(g, [method])
    if isempty(seeds)
        println("    !! this method has no specialization in the graph; skipped")
        return nothing
    end
    predicted = GraphHarvest.cone(g, seeds)
    pred_cost = sum(i -> g.local_cost[i], predicted; init = 0.0)
    println("    seeds = ", length(seeds),
            "   predicted cone = ", length(predicted),
            " nodes (", round(100 * length(predicted) / total, digits = 2), "%)",
            "   cone codegen = ", round(pred_cost, digits = 3), " s (",
            round(100 * pred_cost / max(GraphHarvest.total_local_cost(g), eps()), digits = 2), "%)")

    # The second prediction: walk the backedges that Julia keeps, which is what
    # `invalidate_backedges` in src/gf.c actually walks when a method is replaced.
    seed_mis = [g.nodes[i] for i in seeds]
    be_cone = GraphHarvest.backedge_cone(seed_mis)
    be_predicted = Set{Int}()
    for (i, mi) in enumerate(g.nodes)
        mi in be_cone && push!(be_predicted, i)
    end
    println("    backedge cone = ", length(be_predicted), " nodes of the graph (",
            length(be_cone), " MethodInstance values in all)")

    owners, worlds = capture(g)

    println("--- edit (redefine the method from its own source)")
    MethodEdit.can_redefine(method) ||
        (println("    !! the source does not parse back; skipped"); return nothing)
    log = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
    edit_cost = MethodEdit.redefine!(method)
    ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
    println("    the edit took ", round(1e3 * edit_cost, digits = 1), " ms",
            "   invalidation log entries = ", length(log))

    # An edit that did not replace the method measures nothing. Re-parsing the
    # source can define a *new* method instead of replacing the old one, if the
    # parse started in the wrong place. Check that the old Method object left the
    # table, and say so loudly when it did not.
    fn = try
        getglobal(method.module, method.name)
    catch
        nothing
    end
    replaced = fn === nothing ? missing : !any(m -> m === method, methods(fn))
    println("    the old Method left the table = ", replaced,
            replaced === true ? "" : "   <- THE EDIT DID NOT REPLACE THE METHOD")

    actual = invalidated(g, owners, worlds)
    survived = total - length(actual)
    println("--- result")
    println("    actually invalidated = ", length(actual), " nodes (",
            round(100 * length(actual) / total, digits = 2), "%)")
    println("    SURVIVED             = ", survived, " nodes (",
            round(100 * survived / total, digits = 2), "%)")

    inside = intersect(actual, predicted)
    missed = setdiff(actual, predicted)
    over = setdiff(predicted, actual)
    println("    forward-edge graph : hit ", length(inside),
            ", missed ", length(missed), ", over ", length(over))
    be_missed = setdiff(actual, be_predicted)
    be_over = setdiff(be_predicted, actual)
    println("    Julia's backedges  : hit ", length(intersect(actual, be_predicted)),
            ", missed ", length(be_missed), ", over ", length(be_over),
            isempty(be_missed) ? "   <- SOUND" : "   <- still unsound")
    if !isempty(missed)
        println("    a few that the graph missed:")
        for (k, v) in Iterators.take(sort(collect(names_in(g, missed, APP_MODULES)); by = p -> -p.second), 10)
            println("        ", lpad(v, 5), "  ", k)
        end
    end
    return (; label, total, predicted = length(predicted), actual = length(actual),
            survived, missed = length(missed), over = length(over),
            be_missed = length(be_missed), be_over = length(be_over), edit_cost, replaced)
end

const APP_MODULES = let s = Set{Module}()
    for m in ROOTS
        union!(s, GraphHarvest.submodules(m))
    end
    s
end

"""
    widest_redefinable(g) -> Method

The application method with the most direct callers, whose source parses back.

Do not guess which method is central. Ask the graph. Stay inside the modules of
the application: redefining a method of Base would measure something else and
would put the running session at risk.
"""
function widest_redefinable(g::Graph)
    order = sortperm(map(length, g.reverse); rev = true)
    println("--- the application methods with the most direct callers")
    shown = 0
    best = nothing
    for i in order
        def = g.nodes[i].def
        def isa Method || continue
        def.module in APP_MODULES || continue
        shown < 8 || break
        ok = MethodEdit.can_redefine(def)
        println("    ", lpad(length(g.reverse[i]), 6), " callers  ",
                rpad(string(def.module, ".", def.name), 52), ok ? "" : "  (source does not parse back)")
        ok && best === nothing && (best = def)
        shown += 1
    end
    return best
end

results = Any[]

# Class A — the leaf. `naive_fib` is the synthetic processor load of the model.
leaf = first(methods(R.naive_fib))
push!(results, measure_edit("A leaf", leaf))

# Class B — the middle. Every packet that is not for this node goes through the
# forwarding handler.
middle = first(methods(R.routing_handle!))
push!(results, measure_edit("B middle", middle))

# Class C — the widest edit the application actually has, chosen by the graph.
let g = GraphHarvest.harvest(ROOTS)
    wide = widest_redefinable(g)
    if wide === nothing
        println("    !! no redefinable application method with callers was found")
    else
        push!(results, measure_edit("C widest", wide))
    end
end

println()
println("=== summary ===")
println(rpad("edit", 12), lpad("nodes", 9), lpad("predicted", 11), lpad("invalidated", 13),
        lpad("survived", 10), lpad("survived %", 12), lpad("fwd miss", 8), lpad("be miss", 10), lpad("edit ms", 10),
        lpad("replaced", 10))
for r in results
    r === nothing && continue
    println(rpad(r.label, 12), lpad(r.total, 9), lpad(r.predicted, 11), lpad(r.actual, 13),
            lpad(r.survived, 10), lpad(round(100 * r.survived / r.total, digits = 2), 12),
            lpad(r.missed, 8), lpad(r.be_missed, 10), lpad(round(1e3 * r.edit_cost, digits = 1), 10),
            lpad(string(r.replaced), 10))
end
