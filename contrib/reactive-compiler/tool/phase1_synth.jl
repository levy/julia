# Phase 1 on the synthetic application.
#
# The synthetic application puts each edit class at a known place, so this run
# checks the harvester before it is pointed at a real application.
#
# Run: julia contrib/reactive-compiler/tool/phase1_synth.jl

const HERE = @__DIR__
const ROOT = dirname(HERE)

push!(LOAD_PATH, joinpath(ROOT, "bench", "SynthApp"))
include(joinpath(ROOT, "src", "GraphHarvest.jl"))
using .GraphHarvest
using SynthApp

println("### compile the application")
value = SynthApp.run_all()
println("    run_all() = ", value)

println("### harvest the graph")
graph = @time GraphHarvest.harvest([SynthApp])
println("    nodes       = ", length(graph.nodes))
println("    edges       = ", sum(length, graph.forward; init = 0))
println("    codegen total = ", round(GraphHarvest.total_cost(graph), digits = 3),
        " s  (includes what the system image already paid)")
println("    codegen local = ", round(GraphHarvest.total_local_cost(graph), digits = 3),
        " s  (the work a rebuild repeats)")
println("    from image  = ", GraphHarvest.image_nodes(graph), " nodes")
println("    bindings read = ", length(graph.binding_users))

# --- the edit classes ------------------------------------------------------
reports = GraphHarvest.ConeReport[]

function class!(name, ms)
    seeds = GraphHarvest.seeds_for(graph, ms)
    if isempty(seeds)
        println("    !! no nodes for $name; the method was never specialized")
        return
    end
    push!(reports, GraphHarvest.report(graph, name, seeds))
end

class!("A leaf", methods(SynthApp.calculate_drag))
class!("B middle", methods(SynthApp.normalize_state))
class!("C generic", methods(SynthApp.transform))
# Class D changes a field of State. Every method that dispatches on State is a
# user of the type, so seed with all of them.
class!("D type State", vcat([collect(methods(getglobal(SynthApp, n)))
                             for n in (:drag_of, :normalize_state, :transform, :pipeline, :summarize)]...))

# Class E is the constant. Find the binding that the graph recorded.
println("### bindings that the graph recorded")
scale_binding = nothing
for b in keys(graph.binding_users)
    name = try
        b.globalref
    catch
        b
    end
    println("    ", name, "  read by ", length(graph.binding_users[b]), " nodes")
    if occursin("SCALE", string(name))
        global scale_binding = b
    end
end
if scale_binding === nothing
    println("    !! SCALE is not an edge: inference put its value in the IR")
else
    push!(reports, GraphHarvest.report(graph, "E const SCALE",
                                       GraphHarvest.seeds_for_binding(graph, scale_binding)))
end

println()
GraphHarvest.print_reports(stdout, sort(reports; by = GraphHarvest.cost_fraction))

# --- the check that the harvester is right ---------------------------------
# The leaf has exactly one caller in the source, so its cone must be far smaller
# than the cone of the middle function, which a hundred methods call.
println()
leaf = findfirst(r -> r.name == "A leaf", reports)
middle = findfirst(r -> r.name == "B middle", reports)
if leaf !== nothing && middle !== nothing
    ok = reports[leaf].cone_count < reports[middle].cone_count
    println("### check leaf cone < middle cone: ", ok ? "PASS" : "FAIL",
            "  (", reports[leaf].cone_count, " < ", reports[middle].cone_count, ")")
end
