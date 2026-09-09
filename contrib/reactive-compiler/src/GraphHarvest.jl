"""
    GraphHarvest

Read the compilation graph that Julia already holds, and weigh it.

Phase 1 of the plan needs no cache and no store. After a build, every
`CodeInstance` carries its forward `edges` and the cost of its own work in
seconds. This module walks that, builds the reverse graph, and reports the
invalidation cone of an edit.

Nodes are `MethodInstance` values. A `MethodInstance` may own several
`CodeInstance` values; the cost of the node is the sum over them.

Use it like this:

```julia
using SynthApp
SynthApp.run_all()
graph = GraphHarvest.harvest([SynthApp])
GraphHarvest.report(graph, "Class A - leaf", methods(SynthApp.calculate_drag))
```
"""
module GraphHarvest

export Graph, harvest, cone, report

# ---------------------------------------------------------------------------
# Reading one CodeInstance
# ---------------------------------------------------------------------------

"""
    method_instance_of(ci) -> MethodInstance

Answer the `MethodInstance` of a `CodeInstance`. `ci.def` is a `MethodInstance`
or an `ABIOverride` that wraps one.
"""
function method_instance_of(ci::Core.CodeInstance)
    def = ci.def
    def isa Core.MethodInstance && return def
    # Core.ABIOverride wraps the real MethodInstance.
    isdefined(def, :def) && return getfield(def, :def)::Core.MethodInstance
    return nothing
end

"""
    self_cost(ci) -> Float64

The code-generation work this one entry did, in seconds.

**Only `time_compile` is used, and the reason is a measurement.** The obvious
cost is `time_infer_self + time_compile`, but the two fields do not behave the
same way. On `SynthApp`, against 2.6 seconds of compilation that
`Base.cumulative_compile_time_ns` measured:

- the sum of `time_compile` over the graph is 0.77 s, and no single entry holds
  more than 0.1 s. That is the right order for the code-generation share.
- the sum of `time_infer_self` is 28.55 s, which is about sixteen times the
  inference that happened. The same result appears with `--compiled-modules=no`,
  so it is not an artifact of a package image.

`time_infer_self` therefore does not sum over a set of nodes, whatever its name
suggests. Until that is understood, weigh a cone by code generation only, and say
so. `infer_self_cost` reads the other field for whoever wants to study it.

An inference cost that does sum needs the timing tree of `@snoop_inference`,
which Julia builds in `Compiler/src/timing.jl`. That is open work.
"""
function self_cost(ci::Core.CodeInstance)
    compile = Float64(reinterpret(Float16, ci.time_compile))
    return isfinite(compile) ? compile : 0.0
end

"""
    infer_self_cost(ci) -> Float64

The `time_infer_self` field. Do not sum it over a set of nodes; see `self_cost`.
"""
function infer_self_cost(ci::Core.CodeInstance)
    infer = Float64(reinterpret(Float16, ci.time_infer_self))
    return isfinite(infer) ? infer : 0.0
end

"""
    from_image(ci) -> Bool

Whether this entry came out of the system image.

Bit `0b100` of `flags` says so. The distinction matters more than it looks. The
graph reaches code of Base that the application calls, and those entries carry
the time that was paid when the system image was built. A rebuild of the
application never pays it again. Count that cost apart, or every fraction is
measured against a denominator that no rebuild would ever spend.
"""
from_image(ci::Core.CodeInstance) = (ci.flags & 0b100) != 0

"""
    code_instances(mi) -> Vector{CodeInstance}

Walk the cache chain of a `MethodInstance`.
"""
function code_instances(mi::Core.MethodInstance)
    out = Core.CodeInstance[]
    isdefined(mi, :cache) || return out
    ci = mi.cache
    while true
        push!(out, ci)
        isdefined(ci, :next) || break
        nxt = ci.next
        nxt === nothing && break
        ci = nxt
    end
    return out
end

"""
    forward_targets(ci) -> Vector{Any}

Decode the forward edges of a `CodeInstance`.

The encoding is the one that `ForwardToBackedgeIterator` in
`Compiler/src/typeinfer.jl` reads:

- an `Int` is query information. Skip it and its signature, then read the
  entries that follow as ordinary edges.
- a `Method` is an edge that inference failed to resolve. Ignore it.
- a `Core.Binding` is a dependency on a global value.
- a `CodeInstance` or a `MethodInstance` is a call.
- anything else is an `invoke` signature, and the next entry is its callee.
"""
function forward_targets(ci::Core.CodeInstance)
    out = Any[]
    isdefined(ci, :edges) || return out
    edges = ci.edges
    edges === nothing && return out
    i, n = 1, length(edges)
    while i <= n
        item = edges[i]
        if item isa Int
            i += 2                     # skip the count and the signature
        elseif item isa Method
            i += 1                     # an unresolved edge, of no use here
        elseif item isa Core.Binding
            push!(out, item); i += 1
        elseif item isa Core.CodeInstance
            mi = method_instance_of(item)
            mi === nothing || push!(out, mi)
            i += 1
        elseif item isa Core.MethodInstance
            push!(out, item); i += 1
        else
            # `item` is an invoke signature; the callee follows it.
            i + 1 > n && break
            callee = edges[i+1]
            if callee isa Method
                # unresolved
            elseif callee isa Core.CodeInstance
                mi = method_instance_of(callee)
                mi === nothing || push!(out, mi)
            elseif callee isa Core.MethodInstance
                push!(out, callee)
            else
                push!(out, callee)     # a method table: an abstract dispatch
            end
            i += 2
        end
    end
    return out
end

"""
    backedge_callers(mi) -> Vector{MethodInstance}

The callers that Julia itself records on a `MethodInstance`.

This is not the reverse of the forward edges. Julia keeps its own reverse graph
in `mi.backedges`, and `invalidate_backedges` in `src/gf.c` walks exactly that
when a method is redefined. A reverse graph built by turning the forward edges
around is not the same set, because it can only reach callers that the walk
already found by going forward.

The encoding is the one `get_next_edge` in `src/method.c` reads: an entry that is
a `CodeInstance` is the caller, and an entry that is a type is an `invoke`
signature whose caller is the entry after it.
"""
function backedge_callers(mi::Core.MethodInstance)
    out = Core.MethodInstance[]
    isdefined(mi, :backedges) || return out
    list = mi.backedges
    list === nothing && return out
    i, n = 1, length(list)
    while i <= n
        item = list[i]
        local caller
        if item === nothing || item isa Core.CodeInstance
            caller = item
            i += 1
        else
            i + 1 > n && break
            caller = list[i+1]
            i += 2
        end
        if caller isa Core.CodeInstance
            m = method_instance_of(caller)
            m === nothing || push!(out, m)
        end
    end
    return out
end

"""
    backedge_cone(seeds) -> Set{MethodInstance}

Everything that depends on the seeds, following the backedges of Julia.

This is what a redefinition invalidates, walked the way Julia walks it. It needs
no graph: the answer is reachable from the seed `MethodInstance` values alone.
"""
function backedge_cone(seeds)
    seen = Set{Core.MethodInstance}()
    todo = collect(seeds)
    while !isempty(todo)
        mi = pop!(todo)
        mi in seen && continue
        push!(seen, mi)
        append!(todo, backedge_callers(mi))
    end
    return seen
end

# ---------------------------------------------------------------------------
# The graph
# ---------------------------------------------------------------------------

"""
    Graph

The compilation graph of one build.

- `nodes` — the `MethodInstance` of each index.
- `forward[i]` — the indices that node `i` calls.
- `reverse[i]` — the indices that call node `i`.
- `cost[i]` — the seconds of inference and code generation that node `i` did.
- `local_cost[i]` — the part of `cost[i]` that did not come from the system
  image. This is the work a rebuild would repeat, and it is the denominator that
  every fraction should use.
- `binding_users` — for each `Core.Binding`, the nodes that read it.
"""
struct Graph
    nodes::Vector{Core.MethodInstance}
    index::IdDict{Core.MethodInstance,Int}
    forward::Vector{Vector{Int}}
    reverse::Vector{Vector{Int}}
    cost::Vector{Float64}
    local_cost::Vector{Float64}
    image_node::Vector{Bool}
    binding_users::IdDict{Any,Vector{Int}}
end

total_cost(g::Graph) = sum(g.cost; init = 0.0)
total_local_cost(g::Graph) = sum(g.local_cost; init = 0.0)

"""
    image_nodes(g) -> Int

How many nodes hold at least one entry that came out of an image.

Read the flag. Do not infer it from a cost of zero: an entry that was never sent
to the code generator also costs zero.
"""
image_nodes(g::Graph) = count(g.image_node)

"""
    submodules(mod) -> Set{Module}

Every module inside `mod`, and `mod` itself.
"""
function submodules(mod::Module)
    seen = Set{Module}()
    todo = Module[mod]
    while !isempty(todo)
        m = pop!(todo)
        m in seen && continue
        push!(seen, m)
        for name in names(m; all = true, imported = false)
            isdefined(m, name) || continue
            value = try
                getglobal(m, name)
            catch
                continue
            end
            value isa Module && value !== m && push!(todo, value)
        end
    end
    return seen
end

"""
    methods_of(mods) -> Vector{Method}

Every method that one of `mods` defines.

Scan the bindings of the modules and keep the methods whose own `module` is one
of them. A method that a module adds to a function of another module is found
this way as well, because the scan reaches the function through its own module
only if that module is in the set. Pass the modules of the application.
"""
function methods_of(mods)
    modset = Set{Module}()
    for m in mods
        union!(modset, submodules(m))
    end
    found = Method[]
    seen = Set{Method}()
    for m in modset
        for name in names(m; all = true, imported = false)
            isdefined(m, name) || continue
            value = try
                getglobal(m, name)
            catch
                continue
            end
            value isa Module && continue
            ms = try
                methods(value)
            catch
                continue
            end
            for meth in ms
                meth in seen && continue
                if meth.module in modset
                    push!(seen, meth)
                    push!(found, meth)
                end
            end
        end
    end
    return found
end

"""
    specializations_of(m) -> Vector{MethodInstance}

The compiled specializations of a method. The field holds a `MethodInstance`, or
a `SimpleVector` with holes.
"""
function specializations_of(m::Method)
    out = Core.MethodInstance[]
    isdefined(m, :specializations) || return out
    spec = m.specializations
    if spec isa Core.MethodInstance
        push!(out, spec)
    elseif spec isa Core.SimpleVector
        for s in spec
            s isa Core.MethodInstance && push!(out, s)
        end
    end
    return out
end

"""
    harvest(mods) -> Graph

Build the graph of everything the application compiled.

Start at the methods that `mods` define, then follow the forward edges. The
closure reaches the code of Base and of the standard library that the
application caused to be compiled, which is the work a rebuild would repeat.
"""
function harvest(mods)
    nodes = Core.MethodInstance[]
    index = IdDict{Core.MethodInstance,Int}()
    forward = Vector{Vector{Int}}()
    cost = Float64[]
    local_cost = Float64[]
    image_node = Bool[]
    binding_users = IdDict{Any,Vector{Int}}()

    function node!(mi::Core.MethodInstance)
        got = get(index, mi, 0)
        got == 0 || return got
        push!(nodes, mi)
        push!(forward, Int[])
        push!(cost, 0.0)
        push!(local_cost, 0.0)
        push!(image_node, false)
        index[mi] = length(nodes)
        return length(nodes)
    end

    todo = Int[]
    for m in methods_of(mods), mi in specializations_of(m)
        push!(todo, node!(mi))
    end

    expanded = Set{Int}()
    while !isempty(todo)
        i = pop!(todo)
        i in expanded && continue
        push!(expanded, i)
        mi = nodes[i]
        c = 0.0
        lc = 0.0
        for ci in code_instances(mi)
            this = self_cost(ci)
            c += this
            if from_image(ci)
                image_node[i] = true
            else
                lc += this
            end
            for target in forward_targets(ci)
                if target isa Core.MethodInstance
                    j = node!(target)
                    push!(forward[i], j)
                    j in expanded || push!(todo, j)
                else
                    push!(get!(Vector{Int}, binding_users, target), i)
                end
            end
        end
        cost[i] = c
        local_cost[i] = lc
    end

    for f in forward
        unique!(sort!(f))
    end

    rev = [Int[] for _ in 1:length(nodes)]
    for (i, f) in enumerate(forward), j in f
        push!(rev[j], i)
    end
    for r in rev
        unique!(sort!(r))
    end

    return Graph(nodes, index, forward, rev, cost, local_cost, image_node, binding_users)
end

# ---------------------------------------------------------------------------
# The invalidation cone
# ---------------------------------------------------------------------------

"""
    cone(g, seeds) -> Set{Int}

Every node that depends on a seed, and the seeds themselves.

Walk the reverse edges. This is what an edit to the seed methods invalidates,
if invalidation follows the dependency graph exactly.
"""
function cone(g::Graph, seeds)
    out = Set{Int}()
    todo = collect(seeds)
    while !isempty(todo)
        i = pop!(todo)
        i in out && continue
        push!(out, i)
        append!(todo, g.reverse[i])
    end
    return out
end

"""
    seeds_for(g, ms) -> Vector{Int}

The nodes of the given methods. Use it to turn an edit into a seed set.
"""
function seeds_for(g::Graph, ms)
    out = Int[]
    wanted = Set{Method}(ms)
    for (i, mi) in enumerate(g.nodes)
        def = mi.def
        def isa Method && def in wanted && push!(out, i)
    end
    return out
end

"""
    seeds_for_binding(g, b) -> Vector{Int}

The nodes that read a global binding. Use it for the constant edit class.
"""
seeds_for_binding(g::Graph, b) = copy(get(g.binding_users, b, Int[]))

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

struct ConeReport
    name::String
    seed_count::Int
    cone_count::Int
    node_total::Int
    cone_cost::Float64
    total_cost::Float64
end

node_fraction(r::ConeReport) = r.node_total == 0 ? 0.0 : r.cone_count / r.node_total
cost_fraction(r::ConeReport) = r.total_cost == 0 ? 0.0 : r.cone_cost / r.total_cost

"""
    report(g, name, seeds) -> ConeReport

Measure the cone of one edit class.

The cost fraction is the number that matters. A cone of 5% of the nodes that
holds 60% of the cost is a bad result that a node count hides.
"""
function report(g::Graph, name::AbstractString, seeds::Vector{Int})
    c = cone(g, seeds)
    # Weigh the cone by the work a rebuild would repeat. Code that came out of
    # the system image is never rebuilt, so it belongs in neither number.
    cone_cost = sum(i -> g.local_cost[i], c; init = 0.0)
    return ConeReport(name, length(seeds), length(c), length(g.nodes),
                      cone_cost, total_local_cost(g))
end

function Base.show(io::IO, r::ConeReport)
    print(io, rpad(r.name, 26),
          lpad(r.seed_count, 6), " seeds ",
          lpad(r.cone_count, 8), "/", rpad(r.node_total, 8), " nodes ",
          lpad(round(100 * node_fraction(r), digits = 2), 7), "% ",
          lpad(round(r.cone_cost, digits = 3), 9), "/",
          rpad(round(r.total_cost, digits = 3), 9), " s ",
          lpad(round(100 * cost_fraction(r), digits = 2), 7), "% cost")
end

"""
    print_reports(io, reports)

Print a table of cone reports, widest cost fraction last.
"""
function print_reports(io::IO, reports)
    println(io, rpad("edit class", 26), lpad("seeds", 6), " ",
            lpad("cone/total nodes", 19), lpad("node %", 8), " ",
            lpad("cone/total cost", 21), lpad("cost %", 9))
    println(io, "-"^100)
    for r in reports
        println(io, r)
    end
end

end # module
