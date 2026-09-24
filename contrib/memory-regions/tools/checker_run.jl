# Run a model under the discipline checker and rank the violations.
#
#   JULIA_LOAD_PATH=<regionck>/env:@stdlib julia checker_run.jl alloc 100000

using Compiler
# The checker must exist BEFORE activation: the activated compiler executes in
# the world captured here, and instrumented code it runs cannot see bindings
# created later.
include(joinpath(@__DIR__, "region_check.jl"))
using .RegionCheck
# The example's chain. The checker knows no names; the model defines them.
const ENGINE     = Int8(1)
const SIMULATION = Int8(2)
const EVENT      = Int8(3)
RegionCheck.region_names!("Root", "Engine", "Simulation", "Event")
Compiler.activate!(; reflection = true, codegen = true)
include(joinpath(@__DIR__, "..", "bench", "kernel.jl"))
using .MiniKernel
include(joinpath(@__DIR__, "..", "bench", "model_alloc.jl"))
include(joinpath(@__DIR__, "..", "bench", "model_clean.jl"))

install_checker!()

function run_regioned!(network, events::Int)
    count = 0
    while has_event(network) && count < events
        event = pop_event!(network)
        count += 1
        # No closure here: a `do` block boxes the loop variable, and the
        # checker itself flagged that box. Set and restore the region inline.
        old = RegionCheck.CURRENT[]
        RegionCheck.CURRENT[] = EVENT
        event.action(network, event.environment)
        RegionCheck.CURRENT[] = old
    end
    return count
end

function main()
    variant = ARGS[1]
    events = parse(Int, ARGS[2])
    enable!()
    builder = variant == "alloc" ? ModelAlloc.build :
              variant == "clean" ? ModelClean.build :
              error("variant must be alloc or clean")
    network, sink = RegionCheck.with_region(SIMULATION) do
        builder(4)
    end
    count = run_regioned!(network, events)
    disable!()
    println("events processed: ", count)
    println("instrumented: ", Main.STATS[])
    println("registered objects: ", length(RegionCheck.REGION_OF),
        "  register calls: ", RegionCheck.REGISTERS_RUN[],
        "  check calls: ", RegionCheck.CHECKS_RUN[])
    region_report()
    println("methods with insertions:")
    for (label, (r, c)) in sort!(collect(Main.TOUCHED); by = first)
        println("   ", label, "  registers=", r, " checks=", c)
    end
    println("skipped modules: ", join(sort!(collect(Main.SKIPPED)), ", "))
end

main()
