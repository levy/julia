# Phase 1 on a real application: the OMNeT++ routing model in omnet-julia.
#
# Run it from the omnet-julia checkout:
#
#   julia --project=package/OmnetLegacyRoutingExample \
#         <this file>
#
# The synthetic application only checks the harvester. This one answers the
# question the plan asks: after an edit, how much of the compilation work does a
# rebuild have to repeat?

const HARVEST = get(ENV, "RC_HARVEST",
    "/home/projectured/workspace/julia-reactive/contrib/reactive-compiler/src/GraphHarvest.jl")
include(HARVEST)
using .GraphHarvest

println("### load the application")
t_load = @elapsed using OmnetLegacyRoutingExample
using OmnetSimulator
println("    load = ", round(t_load, digits = 2), " s")

const SCENARIO = Symbol(get(ENV, "RC_SCENARIO", "routing_small"))
println("### run scenario ", SCENARIO)
t_run = @elapsed OmnetLegacyRoutingExample.run_scenario(SCENARIO)
println("    run = ", round(t_run, digits = 2), " s")

# The modules whose methods seed the graph. The closure over the forward edges
# then reaches the simulator, the unit arithmetic and the code of Base that the
# run caused to be compiled.
const ROOTS = Module[OmnetLegacyRoutingExample, OmnetSimulator]

println("### harvest the graph")
graph = @time GraphHarvest.harvest(ROOTS)
println("    nodes         = ", length(graph.nodes))
println("    edges         = ", sum(length, graph.forward; init = 0))
println("    from image     = ", GraphHarvest.image_nodes(graph), " nodes")
println("    codegen total  = ", round(GraphHarvest.total_cost(graph), digits = 3), " s")
println("    codegen local  = ", round(GraphHarvest.total_local_cost(graph), digits = 3),
        " s   (the work a rebuild repeats)")
println("    bindings read  = ", length(graph.binding_users))

const R = OmnetLegacyRoutingExample.Routing

reports = GraphHarvest.ConeReport[]

function class!(name, ms)
    seeds = GraphHarvest.seeds_for(graph, ms)
    if isempty(seeds)
        println("    !! no nodes for ", name, "; never specialized")
        return
    end
    push!(reports, GraphHarvest.report(graph, name, seeds))
end

# Class A — a leaf. `naive_fib` is the synthetic CPU load of the model. Nothing
# calls it but the forwarding handler.
class!("A leaf naive_fib", methods(R.naive_fib))

# Class B — the middle. Every packet that is not delivered locally goes through
# the forwarding handler.
class!("B middle routing_handle!", methods(R.routing_handle!))

# Class D — the type. Seed with every handler that names Packet, because a change
# to a field of Packet makes a new type and every such signature is new.
class!("D type Packet", vcat(collect(methods(R.app_generate!)),
                             collect(methods(R.app_receive!)),
                             collect(methods(R.routing_handle!)),
                             collect(methods(R.queue_enqueue!)),
                             collect(methods(R.queue_start_tx!)),
                             collect(methods(R.queue_receive!))))

# Class C — the widest thing in the graph. Do not guess which method is generic
# enough to matter: ask the graph. Rank by the number of direct callers, which is
# a cheap proxy for a wide cone, then measure the cone of the top few.
println("### the ten nodes with the most direct callers")
order = sortperm(map(length, graph.reverse); rev = true)
for k in 1:min(10, length(order))
    i = order[k]
    def = graph.nodes[i].def
    name = def isa Method ? string(def.module, ".", def.name) : string(def)
    println("    ", lpad(length(graph.reverse[i]), 6), " callers  ", first(name, 70))
end
for k in 1:min(3, length(order))
    i = order[k]
    def = graph.nodes[i].def
    name = def isa Method ? string(def.module, ".", def.name) : "toplevel"
    push!(reports, GraphHarvest.report(graph, "C wide " * first(name, 22), [i]))
end

println()
GraphHarvest.print_reports(stdout, sort(reports; by = GraphHarvest.cost_fraction))

# Class E — the constants. The model holds its knobs in `Ref` values, so the
# binding is constant and its contents are not. Report what the graph recorded.
println()
println("### bindings the graph recorded, by how many nodes read them")
bs = sort(collect(graph.binding_users); by = p -> -length(p.second))
for (b, users) in first(bs, 10)
    name = try
        string(b.globalref)
    catch
        first(string(b), 60)
    end
    println("    ", lpad(length(users), 6), " nodes  ", first(name, 70))
end
