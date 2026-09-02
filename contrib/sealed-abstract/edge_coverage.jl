# Does the compiler's own call graph cover this program, or is observation
# needed too?
#
#     julia edge_coverage.jl <program.jl>
#
# `CodeInstance.edges` holds the callees inference RESOLVED. Below
# `max_union_splitting` it splits an abstract argument and records every target,
# so the graph is complete. Above it the call stays dynamic and NO edge exists.
# A program that exercises the trace-seeded compiler honestly must contain both
# regimes, or it will not test the half of the design that observation exists
# for.
const PROGRAM = ARGS[1]
Base.include(Main, abspath(PROGRAM))
Base.invokelatest(getglobal(Main, :main), String[])

const SEEN = Base.IdSet{Any}()
const ORDER = Any[]
function walk(c)
    (c in SEEN) && return
    push!(SEEN, c); push!(ORDER, c)
    for e in c.edges
        e isa Core.CodeInstance && walk(e)
    end
end
let mi = Base.method_instance(getglobal(Main, :main), (Vector{String},))
    mi.cache isa Core.CodeInstance && walk(mi.cache)
end
const INSIDE = Set(string(Base.get_ci_mi(c).specTypes) for c in ORDER)

println("edge closure from main: ", length(ORDER), " instances")
println("max_union_splitting = ", Core.Compiler.InferenceParams().max_union_splitting)
covered = Dict{Symbol,Int}(); missed = Dict{Symbol,Int}()
for nm in names(Main; all = true)
    isdefined(Main, nm) || continue
    f = try getglobal(Main, nm) catch; continue end
    (f isa Function) || continue
    for m in methods(f)
        m.module === Main || continue
        # This checker's own functions live in Main too. `warm` is build-time
        # only, and never part of what the entry needs.
        (m.name in (:walk, :warm)) && continue
        for s in Base.specializations(m)
            s isa Core.MethodInstance || continue
            d = string(s.specTypes) in INSIDE ? covered : missed
            d[m.name] = get(d, m.name, 0) + 1
        end
    end
end
println("\nMETHODS THE EDGE WALK COVERS (static, no observation needed):")
for (k, v) in sort(collect(covered), by = x -> -x[2])
    println("  ", v, "  ", k)
end
println("\nMETHODS THE EDGE WALK MISSES (only observation can supply these):")
if isempty(missed)
    println("  NONE — this program does not exercise the observation half")
else
    for (k, v) in sort(collect(missed), by = x -> -x[2])
        println("  ", v, "  ", k)
    end
end
println("\ncovered=", sum(values(covered)), "  missed=", sum(values(missed)))
