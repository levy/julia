# Prove the property the whole idea rests on.
#
#   Change `f`. Then `h`, which calls `f`, loses its compiled code. And `g`,
#   which has nothing to do with `f`, keeps its own.
#
# If Julia recompiled `g` as well, no cache design would help, because the
# invalidation would not follow the dependency graph. So measure it, do not
# assume it.
#
# The proof reads three things for each function:
#
#   1. the `CodeInstance` object itself, by identity;
#   2. its `max_world`, which Julia closes when it invalidates the entry;
#   3. whether a new `CodeInstance` appears after the edit, which is what a
#      recompilation leaves behind.
#
# It also compares what Julia actually invalidated against what the forward-edge
# graph predicted, which is the cross-check the plan asks for.
#
# Run: julia --startup-file=no tool/prove_unrelated.jl

const HERE = @__DIR__
const ROOT = dirname(HERE)
include(joinpath(ROOT, "src", "GraphHarvest.jl"))
using .GraphHarvest

const ALIVE = typemax(UInt)

module Subject
    # Give each function a body long enough that compiling it takes a time the
    # clock can see. A four-line program recompiles below the resolution of the
    # compile-time counter, and then the timing says nothing either way.
    function chain(seed, n::Int)
        stmts = Any[:(acc = $seed)]
        for i in 1:n
            push!(stmts, :(acc = muladd(acc, $(1.0 + i * 1e-9), $(float(i)))))
        end
        push!(stmts, :(return acc))
        return Expr(:block, stmts...)
    end

    # The leaf that will be edited.
    @eval f(x) = $(chain(:(x * 0.73), 400))
    # Depends on f. Must lose its compiled code.
    @eval h(x) = $(chain(:(f(x) + 1), 400))
    # Unrelated to f. Must keep its compiled code.
    @eval g(x) = $(chain(:(x + 1), 400))
    # Depends on g, not on f. Must also keep its compiled code.
    @eval k(x) = $(chain(:(g(x) * 2), 400))
end

"""
    entry(fn, argtypes) -> (MethodInstance, Vector{CodeInstance})

The specialization of `fn` for `argtypes`, and its cache chain.
"""
function entry(fn, argtypes)
    sig = Tuple{typeof(fn),argtypes...}
    for m in methods(fn), mi in GraphHarvest.specializations_of(m)
        mi.specTypes === sig && return (mi, GraphHarvest.code_instances(mi))
    end
    return (nothing, Core.CodeInstance[])
end

struct Snapshot
    name::String
    mi::Any
    cis::Vector{Core.CodeInstance}
    ids::Vector{UInt}
    maxworlds::Vector{UInt}
end

function snap(name, fn, argtypes)
    mi, cis = entry(fn, argtypes)
    Snapshot(name, mi, cis, map(objectid, cis), map(ci -> ci.max_world, cis))
end

show_snap(s::Snapshot) = println("    ", rpad(s.name, 4), " CIs=", length(s.cis),
    "  max_world=", join([w == ALIVE ? "alive" : string(w) for w in s.maxworlds], ","))

# ---------------------------------------------------------------------------
println("### compile all four functions")
for fn in (Subject.f, Subject.h, Subject.g, Subject.k)
    fn(1.0)
end
const H_BEFORE = Subject.h(1.0)
const G_BEFORE = Subject.g(1.0)

before = [snap("f", Subject.f, (Float64,)),
          snap("h", Subject.h, (Float64,)),
          snap("g", Subject.g, (Float64,)),
          snap("k", Subject.k, (Float64,))]
foreach(show_snap, before)

# --- what the forward-edge graph predicts ---------------------------------
println("### what the dependency graph predicts")
graph = GraphHarvest.harvest([Subject])
seeds = GraphHarvest.seeds_for(graph, collect(methods(Subject.f)))
predicted = GraphHarvest.cone(graph, seeds)
predicted_names = Set{String}()
for i in predicted
    def = graph.nodes[i].def
    def isa Method && def.module === Subject && push!(predicted_names, string(def.name))
end
println("    graph nodes = ", length(graph.nodes),
        "   predicted cone in Subject = ", sort(collect(predicted_names)))

# --- the edit -------------------------------------------------------------
println("### edit f, and log what Julia invalidates")
log = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
# The same edit as class A of the plan: change the constant in the leaf.
# Time the edit itself. Julia re-infers what it invalidates, and it may do that
# here rather than at the next call.
new_body = Subject.chain(:(x * 0.74), 400)
edit_cost = @elapsed Core.eval(Subject, :(f(x) = $new_body))
ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
println("    the edit itself took ", round(1e3 * edit_cost, digits = 3), " ms")

actual_names = Set{String}()
for item in log
    mi = nothing
    if item isa Core.CodeInstance
        mi = GraphHarvest.method_instance_of(item)
    elseif item isa Core.MethodInstance
        mi = item
    elseif item isa Method
        item.module === Subject && push!(actual_names, string(item.name))
    end
    if mi !== nothing
        def = mi.def
        def isa Method && def.module === Subject && push!(actual_names, string(def.name))
    end
end
println("    invalidation log entries = ", length(log))
println("    invalidated in Subject   = ", sort(collect(actual_names)))

after = [snap("f", Subject.f, (Float64,)),
         snap("h", Subject.h, (Float64,)),
         snap("g", Subject.g, (Float64,)),
         snap("k", Subject.k, (Float64,))]
println("### after the edit")
foreach(show_snap, after)

# --- the assertions -------------------------------------------------------
println()
println("### the verdict")
failures = String[]

function check(label, ok)
    println("    ", ok ? "PASS  " : "FAIL  ", label)
    ok || push!(failures, label)
end

byname(v, n) = v[findfirst(s -> s.name == n, v)]

# g and k are unrelated to f. Their entries must be the same objects and must
# still be alive.
for name in ("g", "k")
    b, a = byname(before, name), byname(after, name)
    same = a.ids == b.ids
    alive = all(w -> w == ALIVE, a.maxworlds)
    check("$name keeps the same CodeInstance object", same)
    check("$name is still valid (max_world open)", alive)
end

# h depends on f. Julia must have closed its world.
h_after = byname(after, "h")
h_before = byname(before, "h")
check("h was invalidated (max_world closed on the old entry)",
      any(w -> w != ALIVE, h_before.cis |> cis -> map(ci -> ci.max_world, cis)))

# The graph predicted h and not g.
check("graph predicted h", "h" in predicted_names)
check("graph did NOT predict g", !("g" in predicted_names))
check("graph did NOT predict k", !("k" in predicted_names))

# --- does calling them again recompile? -----------------------------------
println()
println("### call each again and time the first call after the edit")
# Wall time, not the compile-time counter. The counter did not move for a
# recompilation that demonstrably happened, so it is not evidence here. The
# first call of an invalidated function pays for its own recompilation, and
# these bodies are 400 statements long, so the difference is plain.
cost_g = @elapsed Subject.g(1.0)
cost_k = @elapsed Subject.k(1.0)
cost_h = @elapsed Subject.h(1.0)
println("    first call of g = ", round(1e3 * cost_g, digits = 3), " ms  (unrelated)")
println("    first call of k = ", round(1e3 * cost_k, digits = 3), " ms  (unrelated)")
println("    first call of h = ", round(1e3 * cost_h, digits = 3), " ms  (depends on f)")

final = [snap("f", Subject.f, (Float64,)),
         snap("h", Subject.h, (Float64,)),
         snap("g", Subject.g, (Float64,)),
         snap("k", Subject.k, (Float64,))]
println("### after calling them again")
foreach(show_snap, final)

check("g gained no new CodeInstance", length(byname(final, "g").cis) == length(byname(before, "g").cis))
check("k gained no new CodeInstance", length(byname(final, "k").cis) == length(byname(before, "k").cis))
check("h did gain a new CodeInstance", length(byname(final, "h").cis) > length(byname(before, "h").cis))
check("h now answers a different value", Subject.h(1.0) != H_BEFORE)
check("g still answers the same value", Subject.g(1.0) == G_BEFORE)
println()
println("### where the work happened")
println("    the edit           = ", round(1e3 * edit_cost, digits = 3), " ms")
println("    first call of h    = ", round(1e3 * cost_h, digits = 3), " ms")
println("    first call of g    = ", round(1e3 * cost_g, digits = 3), " ms")
println("    Julia re-infers what it invalidates during the edit, not at the")
println("    next call, so the edit carries the cost of the cone.")

println()
if isempty(failures)
    println("### ALL CHECKS PASSED: an edit to f leaves unrelated code compiled.")
else
    println("### ", length(failures), " CHECK(S) FAILED:")
    foreach(f -> println("      ", f), failures)
end
