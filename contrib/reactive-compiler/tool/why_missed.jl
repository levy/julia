# Why did the graph miss eleven nodes?
#
# On the widest edit of the routing model, Julia invalidated 222 nodes and the
# forward-edge graph reached 212. This finds the mechanism behind the other
# eleven.
#
# The suspicion, from `src/gf.c`: Julia keeps backedges on the *method table*,
# not only on a MethodInstance. A CodeInstance that dispatches abstractly over a
# signature registers there through `jl_method_table_add_backedge`. When a method
# that intersects the signature is inserted, `invalidate_mt_cache` and the method
# table backedge walk invalidate it. That edge is a pair (invoke signature,
# MethodTable) in the forward edges, and `GraphHarvest.forward_targets` does not
# turn it into a graph edge.
#
# Run it from the omnet-julia checkout:
#   julia --project=package/OmnetLegacyRoutingExample <this file>

const RC = get(ENV, "RC_SRC",
    "/home/projectured/workspace/julia-reactive/contrib/reactive-compiler/src")
include(joinpath(RC, "GraphHarvest.jl"))
include(joinpath(RC, "MethodEdit.jl"))
using .GraphHarvest
using .MethodEdit

const ALIVE = typemax(UInt)

println("### load and compile the model")
using OmnetLegacyRoutingExample
using OmnetSimulator
OmnetLegacyRoutingExample.run_scenario(Symbol(get(ENV, "RC_SCENARIO", "routing_small")))

const ROOTS = Module[OmnetLegacyRoutingExample, OmnetSimulator]

println("### harvest")
g = GraphHarvest.harvest(ROOTS)
println("    nodes = ", length(g.nodes))

# Which nodes carry an abstract-dispatch edge, and over which signature?
"""
    method_table_edges(ci) -> Vector{Any}

The invoke signatures on which this entry dispatches abstractly.

The forward edges hold them as a pair: the signature, then the `MethodTable`.
"""
function method_table_edges(ci::Core.CodeInstance)
    out = Any[]
    isdefined(ci, :edges) || return out
    edges = ci.edges
    edges === nothing && return out
    i, n = 1, length(edges)
    while i <= n
        item = edges[i]
        if item isa Int
            i += 2
        elseif item isa Method || item isa Core.Binding ||
               item isa Core.CodeInstance || item isa Core.MethodInstance
            i += 1
        else
            i + 1 > n && break
            callee = edges[i+1]
            callee isa Core.MethodTable && push!(out, item)
            i += 2
        end
    end
    return out
end

function collect_mt_sigs(g)
    sigs = [Any[] for _ in 1:length(g.nodes)]
    carriers = 0
    for (i, mi) in enumerate(g.nodes)
        for ci in GraphHarvest.code_instances(mi)
            append!(sigs[i], method_table_edges(ci))
        end
        isempty(sigs[i]) || (carriers += 1)
    end
    return sigs, carriers
end
mt_sigs, carriers = collect_mt_sigs(g)
println("    nodes with an abstract-dispatch edge = ", carriers,
        " of ", length(g.nodes))

# The same edit as class C of the proof.
appmods = let s = Set{Module}(); for m in ROOTS; union!(s, GraphHarvest.submodules(m)); end; s end
function pick_target(g, appmods)
    order = sortperm(map(length, g.reverse); rev = true)
    for i in order
        def = g.nodes[i].def
        def isa Method || continue
        def.module in appmods || continue
        MethodEdit.can_redefine(def) || continue
        return def
    end
    return nothing
end
target = pick_target(g, appmods)
println("### edit ", target.module, ".", target.name)

seeds = GraphHarvest.seeds_for(g, [target])
predicted = GraphHarvest.cone(g, seeds)

owners = [GraphHarvest.code_instances(mi) for mi in g.nodes]
worlds = [map(ci -> ci.max_world, cis) for cis in owners]

log = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
MethodEdit.redefine!(target)
ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)

actual = Set{Int}()
for i in eachindex(owners)
    still = GraphHarvest.code_instances(g.nodes[i])
    for (ci, before) in zip(owners[i], worlds[i])
        before == ALIVE || continue
        if ci.max_world != ALIVE || !any(x -> x === ci, still)
            push!(actual, i); break
        end
    end
end
missed = setdiff(actual, predicted)
println("    invalidated = ", length(actual), "   predicted = ", length(predicted),
        "   missed = ", length(missed))

# --- attribute a reason to every item in the log ---------------------------
# The log is a flat list. Julia pushes the objects it is invalidating, then a
# string that says why. So a string applies to everything pushed since the last
# string.
reasons = IdDict{Any,Vector{String}}()
pending = Any[]
for item in log
    if item isa String
        for p in pending
            push!(get!(Vector{String}, reasons, p), item)
        end
        empty!(pending)
    else
        push!(pending, item)
    end
end
println("### reasons that appear in the log")
tally = Dict{String,Int}()
for (_, rs) in reasons, r in rs
    tally[r] = get(tally, r, 0) + 1
end
for (r, n) in sort(collect(tally); by = p -> -p.second)
    println("    ", lpad(n, 6), "  ", r)
end

# --- what do the missed nodes look like? -----------------------------------
println("### the nodes the graph missed")
function report_missed(g, missed, mt_sigs, reasons)
    mt_missed = 0
    for i in missed
    mi = g.nodes[i]
    def = mi.def
    name = def isa Method ? string(def.module, ".", def.name) : string(def)
    rs = String[]
    for (obj, r) in reasons
        obj === mi && append!(rs, r)
        if obj isa Core.CodeInstance && GraphHarvest.method_instance_of(obj) === mi
            append!(rs, r)
        end
    end
    has_mt = !isempty(mt_sigs[i])
    has_mt && (mt_missed += 1)
        println("    ", rpad(first(name, 52), 54),
                " abstract-dispatch edge: ", has_mt,
                "   reasons: ", isempty(rs) ? "(none recorded)" : join(unique(rs), ", "))
    end
    return mt_missed
end
mt_missed = report_missed(g, missed, mt_sigs, reasons)
println()
println("### verdict")
println("    missed nodes                       = ", length(missed))
println("    of those, carrying an mt edge      = ", mt_missed)
println("    of those, without one              = ", length(missed) - mt_missed)
