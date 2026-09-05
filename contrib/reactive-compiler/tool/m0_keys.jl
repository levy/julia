# M0, the key half: does the recorded-read key change for exactly what Julia
# invalidates?
#
# The key of a node is content only (see `src/ReadKey.jl`). Julia's answer is
# identity and worlds. The two are compared on the same edit as build B of the
# object diff: `pk.hop_count += 1` becomes `+= 2` in `routing_handle!`.
#
# Nodes are matched across the edit by a canonical name, because a redefinition
# makes new Method and MethodInstance objects. Three sets are reported:
#
#   key-changed & invalidated   the key and Julia agree
#   key-changed, not invalidated   the key is too sensitive: FIND WHY
#   invalidated, key unchanged     Julia rebuilt what did not change: explain
#
# Run it from the omnet-julia checkout:
#   julia --project=package/OmnetLegacyRoutingExample <this file>

const RC = get(ENV, "RC_SRC",
    "/home/projectured/workspace/julia-reactive/contrib/reactive-compiler/src")
include(joinpath(RC, "GraphHarvest.jl"))
include(joinpath(RC, "MethodEdit.jl"))
include(joinpath(RC, "ReadKey.jl"))
using .GraphHarvest
using .MethodEdit
using .ReadKey

const ALIVE = typemax(UInt)
const SCENARIO = Symbol(get(ENV, "RC_SCENARIO", "routing_small"))
const EDIT = "pk.hop_count += 1" => "pk.hop_count += 2"

println("### load and run ", SCENARIO)
t_load = @elapsed using OmnetLegacyRoutingExample
using OmnetSimulator
t_run = @elapsed OmnetLegacyRoutingExample.run_scenario(SCENARIO; mode = :seq)
println("    load = ", round(t_load, digits = 2), " s   run = ", round(t_run, digits = 2), " s")

const ROOTS = Module[OmnetLegacyRoutingExample, OmnetSimulator]
const R = OmnetLegacyRoutingExample.Routing

# The key computation runs Julia code, and that code is part of the graph:
# `lowered_hash` prints every statement with `sprint(show, ::Expr)`, which the
# routing model also calls. Without this warm-up, `Base.#sprint#` has no code
# instance at the first harvest and four callees at the second, and the twelve
# nodes above it change key without an edit. Compile the harness first.
ReadKey.component_keys(GraphHarvest.harvest(ROOTS))

println("### keys before the edit")
g1 = GraphHarvest.harvest(ROOTS)
# How many code instances each node had when it was harvested. The key
# computation runs Julia code, and that can compile a node of the graph.
ci_count_at_harvest = [length(GraphHarvest.code_instances(mi)) for mi in g1.nodes]
t_key = @elapsed k1 = ReadKey.component_keys(g1)
comp1, order1 = ReadKey.components(g1)
p1 = ReadKey.name_key_pairs(g1, k1)
println("    nodes = ", length(g1.nodes), "   components = ", length(order1),
        "   largest component = ", maximum(length, order1),
        "   distinct (name, key) = ", length(p1),
        "   keys took ", round(t_key, digits = 2), " s")
names1 = [ReadKey.node_name(mi) for mi in g1.nodes]
dup = length(names1) - length(Set(names1))
println("    nodes that share a name with another node = ", dup)

# The same key for the same content, computed twice: a key must be a function.
k1b = ReadKey.component_keys(g1)
println("    keys are deterministic in process = ", k1 == k1b)

owners = [GraphHarvest.code_instances(mi) for mi in g1.nodes]
worlds = [map(ci -> ci.max_world, cis) for cis in owners]
# The `edges` object of every code instance, as it was before the edit.
edges_before = [map(ci -> isdefined(ci, :edges) ? ci.edges : nothing, cis) for cis in owners]

println("### edit routing_handle!: ", EDIT)
target = first(methods(R.routing_handle!))
edit_cost = MethodEdit.redefine!(target; replace = EDIT)
replaced = !any(m -> m === target, methods(R.routing_handle!))
println("    the edit took ", round(1e3 * edit_cost, digits = 1), " ms",
        "   the old Method left the table = ", replaced)

# Julia's answer has two parts. `jl_method_table_invalidate` (src/gf.c) walks
# the backedges of every specialization of the replaced method and caps the
# `max_world` of the callers' code instances; that is `capped`. The code
# instances of the replaced method itself keep `max_world == ALIVE`: what dies
# is the typemap entry of the Method, so dispatch can not reach them any more.
# Those nodes are `replaced`, found by their Method.
capped = Set{Int}()
replaced_nodes = Set{Int}()
for i in eachindex(owners)
    still = GraphHarvest.code_instances(g1.nodes[i])
    g1.nodes[i].def === target && push!(replaced_nodes, i)
    for (ci, before) in zip(owners[i], worlds[i])
        before == ALIVE || continue
        if ci.max_world != ALIVE || !any(x -> x === ci, still)
            push!(capped, i); break
        end
    end
end
invalidated = union(capped, replaced_nodes)
println("    invalidated = ", length(invalidated), " nodes: ", length(capped),
        " with a capped max_world, ", length(replaced_nodes), " of the replaced Method")

println("### run ", SCENARIO, " again, so the new methods get compiled")
t_run2 = @elapsed OmnetLegacyRoutingExample.run_scenario(SCENARIO; mode = :seq)
println("    run = ", round(t_run2, digits = 2), " s")

println("### keys after the edit")
g2 = GraphHarvest.harvest(ROOTS)
k2 = ReadKey.component_keys(g2)
p2 = ReadKey.name_key_pairs(g2, k2)
names2 = Set(ReadKey.node_name(mi) for mi in g2.nodes)
println("    nodes = ", length(g2.nodes), "   distinct (name, key) = ", length(p2))

# --- compare -----------------------------------------------------------------
# A node of g1 is "key-changed" when its (name, key) pair has no twin in g2.
# A name that g2 does not have at all was not compiled after the edit; it is
# listed apart, because a changed program can specialize differently.
unchanged = Set{Int}()
changed = Set{Int}()
gone = Set{Int}()
for (i, mi) in enumerate(g1.nodes)
    name = names1[i]
    if haskey(p2, (name, k1[i]))
        push!(unchanged, i)
    elseif name in names2
        push!(changed, i)
    else
        push!(gone, i)
    end
end
agree = intersect(changed, invalidated)
too_sensitive = setdiff(changed, invalidated)
over = intersect(unchanged, invalidated)
gone_inv = intersect(gone, invalidated)
new_pairs = count(p -> !haskey(p1, p), keys(p2))

println()
println("=== result")
println("    nodes before                        ", lpad(length(g1.nodes), 8))
println("    key unchanged                       ", lpad(length(unchanged), 8),
        "   = ", round(100 * length(unchanged) / length(g1.nodes), digits = 2), "%")
println("    key changed (name still present)    ", lpad(length(changed), 8))
println("    name gone after the edit            ", lpad(length(gone), 8),
        "   of which invalidated ", length(gone_inv))
println("    invalidated by Julia                ", lpad(length(invalidated), 8))
println("    key-changed & invalidated           ", lpad(length(agree), 8))
println("    key-changed, NOT invalidated        ", lpad(length(too_sensitive), 8),
        isempty(too_sensitive) ? "   <- the key is not too sensitive" : "   <- FIND WHY")
println("    invalidated, key unchanged          ", lpad(length(over), 8),
        "   (Julia rebuilt what did not change)")
println("    new (name, key) pairs after         ", lpad(new_pairs, 8))

function show_names(title, set, limit = 25)
    isempty(set) && return
    println("--- ", title, " (", length(set), ")")
    tally = Dict{String,Int}()
    for i in set
        def = g1.nodes[i].def
        key = def isa Method ? string(def.module, ".", def.name) : string(def)
        tally[key] = get(tally, key, 0) + 1
    end
    for (k, v) in Iterators.take(sort(collect(tally); by = p -> -p.second), limit)
        println("    ", lpad(v, 5), "  ", k)
    end
end
show_names("key-changed, not invalidated", too_sensitive)
show_names("invalidated, key unchanged", over)
show_names("name gone after the edit", gone, 15)

# Which components did the key-changed nodes belong to? A component that is one
# giant cell makes every edit change everything.
if !isempty(changed)
    comps = Set(comp1[i] for i in changed)
    println("--- the key-changed nodes lie in ", length(comps), " components; sizes: ",
            join(sort([length(order1[c]) for c in comps]; rev = true)[1:min(end, 10)], " "))
end

# --- why -----------------------------------------------------------------------
# Stage 0, step 4: for every node whose key changed although Julia did not
# invalidate it, find the read that explains the difference. A key is the local
# hash of the node (its lowered code, its specialization types and the
# partitions of the bindings it reads) and the keys of the components it
# calls; the pieces are compared one by one against the node's twin in g2. The
# twin is the same MethodInstance when it survived the edit, else the node of
# g2 with the same name.
reads1 = ReadKey.binding_reads(g1)
reads2 = ReadKey.binding_reads(g2)
names2v = [ReadKey.node_name(mi) for mi in g2.nodes]

function binding_table(g, i, reads)
    mi = g.nodes[i]
    bs = Core.Binding[]
    append!(bs, reads[i])
    if mi.def isa Method
        for gr in ReadKey.globalrefs(mi.def)
            b = try convert(Core.Binding, gr) catch; continue end
            push!(bs, b)
        end
    end
    out = Dict{String,Tuple{UInt64,Core.Binding}}()
    for b in bs
        out[string(b.globalref)] = (ReadKey.partition_hash(b), b)
    end
    return out
end

function describe_binding(b::Core.Binding)
    bpart = Base.lookup_binding_partition(Base.tls_world_age(), b)
    kind = Base.binding_kind(bpart)
    r = Base.is_defined_const_binding(kind) || kind == Base.PARTITION_KIND_GLOBAL ?
        Base.partition_restriction(bpart) : nothing
    s = sprint(show, r; context = :limit => true)
    return string(kind, " ", typeof(r), " ", first(s, 80))
end

successor_table(g, i, keys) = Dict(ReadKey.node_name(g.nodes[s]) => keys[s] for s in g.forward[i])

# What the code instances of a node look like: where each came from, its world
# range, and what its `edges` field holds, entry by entry, before and after the
# edit. A node whose callees appear after the edit although it kept the same
# code instance is explained here or nowhere.
function describe_edges(edges)
    edges === nothing && return "nothing"
    kinds = join((string(e isa Core.CodeInstance ? "CI" : e isa Core.MethodInstance ? "MI" :
                         e isa Method ? "Method" : e isa Core.Binding ? "Binding" :
                         e isa Int ? string(e) : e isa Core.MethodTable ? "MT" : string(typeof(e)))
                  for e in edges), " ")
    return string(length(edges), ": [", first(kinds, 160), "]")
end

function describe_code_instances(i, mi)
    for (n, ci) in enumerate(GraphHarvest.code_instances(mi))
        before = i != 0 && n <= length(edges_before[i]) && owners[i][n] === ci ? edges_before[i][n] : :unknown
        now = isdefined(ci, :edges) ? ci.edges : nothing
        println("      ci: image=", GraphHarvest.from_image(ci), " world=", ci.min_world, ":",
                ci.max_world == ALIVE ? "inf" : string(ci.max_world), " owner=", ci.owner,
                " inferred=", typeof(ci.inferred))
        println("          edges before: ", before === :unknown ? "(not the same code instance)" : describe_edges(before))
        println("          edges now:    ", before === now ? "the same object" : describe_edges(now))
    end
end

function explain(i)
    mi = g1.nodes[i]
    name = names1[i]
    j = get(g2.index, mi, 0)
    same_mi = j != 0
    if !same_mi
        js = findall(==(name), names2v)
        isempty(js) && (println("    no twin in g2"); return)
        j = first(js)
    end
    mj = g2.nodes[j]
    println("--- ", name)
    println("    twin: ", same_mi ? "the same MethodInstance" : "the node of g2 with the same name",
            "   code instances at harvest ", ci_count_at_harvest[i], ", after the keys ",
            length(owners[i]), ", now ", length(GraphHarvest.code_instances(mj)),
            "   forward edges ", length(g1.forward[i]), " -> ", length(g2.forward[j]))
    describe_code_instances(i, mi)
    same_mi || describe_code_instances(0, mj)
    if mi.def isa Method && mj.def isa Method
        lh1, lh2 = ReadKey.lowered_hash(mi.def), ReadKey.lowered_hash(mj.def)
        println("    lowered code: ", lh1 == lh2 ? "same" : "DIFFERENT", "   same Method object: ", mi.def === mj.def)
    end
    b1, b2 = binding_table(g1, i, reads1), binding_table(g2, j, reads2)
    for k in sort!(collect(union(keys(b1), keys(b2))))
        h1 = get(b1, k, nothing); h2 = get(b2, k, nothing)
        if h1 === nothing
            println("    binding only after:  ", k, "  ", describe_binding(h2[2]))
        elseif h2 === nothing
            println("    binding only before: ", k, "  ", describe_binding(h1[2]))
        elseif h1[1] != h2[1]
            println("    binding CHANGED:     ", k, "  now ", describe_binding(h2[2]))
        end
    end
    s1, s2 = successor_table(g1, i, k1), successor_table(g2, j, k2)
    for k in sort!(collect(union(keys(s1), keys(s2))))
        v1 = get(s1, k, nothing); v2 = get(s2, k, nothing)
        if v1 === nothing
            println("    callee only after:   ", k)
        elseif v2 === nothing
            println("    callee only before:  ", k)
        elseif v1 != v2
            println("    callee key CHANGED:  ", k)
        end
    end
end

if !isempty(too_sensitive)
    println("=== why the key changed without an invalidation")
    for i in sort!(collect(too_sensitive))[1:min(end, 40)]
        explain(i)
    end
end
