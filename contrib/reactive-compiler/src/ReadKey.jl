"""
    ReadKey

The recorded-read key of every node of a harvested graph, computed in process.

This is the M0 model of the store's key: a node is valid when its own content and
everything it read are the same as before. Nothing about worlds, backedges or
identity enters the key.

- The local hash of a node is its method (module path, name, signature), the
  lowered code of the method, the specialization types, and the partition of
  every global binding the node reads.
- A strongly connected component of the forward graph is one cell. Its key is
  the hash of the local hashes of its members and of the keys of the components
  it calls. Every member of a component carries the key of the component.

Names and keys are canonical: a `#` followed by digits is a counter that Julia
assigns at definition time (`#_emit##8`, `#12#13`), and it is dropped, so the
same closure defined twice gets the same name.

Use it after a run, on the graph of `GraphHarvest.harvest`:

```julia
g = GraphHarvest.harvest(roots)
keys = ReadKey.component_keys(g)          # one UInt64 per node
pairs = ReadKey.name_key_pairs(g, keys)   # Dict{(name, key), count}
```
"""
module ReadKey

using ..GraphHarvest

export component_keys, name_key_pairs, node_name

# ---------------------------------------------------------------------------
# Canonical names
# ---------------------------------------------------------------------------

"""
    canonical(s) -> String

Drop every definition-time counter: a `#` followed by digits becomes `#`.
Type names such as `Int64` keep their digits.
"""
canonical(s::AbstractString) = replace(String(s), r"#\d+" => "#")

"""
    node_name(mi) -> String

A name for a node that survives a redefinition: the module path, the method name
and the specialization types, all canonical.
"""
function node_name(mi::Core.MethodInstance)
    def = mi.def
    head = def isa Method ? string(def.module, ".", def.name) : string(def)
    return canonical(string(head, " ", mi.specTypes))
end

# ---------------------------------------------------------------------------
# The local hash
# ---------------------------------------------------------------------------

"""
    lowered_hash(m::Method) -> UInt64

Hash the statements of the lowered code of `m`. Line information is not part of
the statements, so an edit above the method in the same file does not change
the hash.
"""
function lowered_hash(m::Method)
    h = hash(canonical(string(m.module, ".", m.name)))
    h = hash(canonical(string(m.sig)), h)
    h = hash(m.nargs, h)
    h = hash(m.isva, h)
    if isdefined(m, :generator)
        # The body of a generated method is produced per specialization; the
        # generator itself is what the method holds.
        h = hash(:generated, h)
    end
    src = try
        Base.uncompressed_ir(m)
    catch
        nothing
    end
    src === nothing && return hash(:nosource, h)
    for stmt in src.code
        h = hash(canonical(sprint(show, stmt)), h)
    end
    return h
end

"""
    globalrefs(m::Method) -> Vector{GlobalRef}

Every `GlobalRef` in the lowered code of `m`, in order of appearance.
"""
function globalrefs(m::Method)
    out = GlobalRef[]
    src = try
        Base.uncompressed_ir(m)
    catch
        return out
    end
    function walk(x)
        if x isa GlobalRef
            push!(out, x)
        elseif x isa Expr
            for a in x.args
                walk(a)
            end
        elseif x isa Core.ReturnNode
            isdefined(x, :val) && walk(x.val)
        elseif x isa Core.GotoIfNot
            walk(x.cond)
        end
    end
    for stmt in src.code
        walk(stmt)
    end
    return out
end

"""
    partition_hash(b::Core.Binding) -> UInt64

Hash what a reader of the binding sees now: its kind and its restriction. For a
constant the restriction is the value; for a typed global it is the type.
"""
function partition_hash(b::Core.Binding)
    h = hash(canonical(string(b.globalref)))
    bpart = Base.lookup_binding_partition(Base.tls_world_age(), b)
    kind = Base.binding_kind(bpart)
    h = hash(kind, h)
    if Base.is_defined_const_binding(kind) || kind == Base.PARTITION_KIND_GLOBAL
        r = Base.partition_restriction(bpart)
        h = hash(value_hash(r), h)
    end
    return h
end

"""
    value_hash(v) -> UInt64

The hash of a constant. Types, modules, functions and the plain immutable values
hash by their printed name; everything else hashes by its structure, which
inside one process is what `Base.hash` gives.
"""
function value_hash(v)
    if v isa Union{Type,Module,Function,Number,AbstractString,Symbol,Char,Nothing,Missing}
        return hash(canonical(string(v)))
    elseif v isa Tuple
        h = hash(:tuple)
        for x in v
            h = hash(value_hash(x), h)
        end
        return h
    else
        return hash(string(typeof(v)), hash(v))
    end
end

"""
    local_hash(g, i) -> UInt64

The content of node `i` and of the global bindings it reads. The bindings come
from two places: the `Core.Binding` entries of the forward edges, which
inference recorded, and a scan of the lowered code for `GlobalRef` values,
which reaches the bindings inference did not fold.
"""
function local_hash(g::Graph, i::Int, binding_reads::Vector{Vector{Core.Binding}})
    mi = g.nodes[i]
    def = mi.def
    h = def isa Method ? lowered_hash(def) : hash(canonical(string(def)))
    h = hash(canonical(string(mi.specTypes)), h)
    bs = Core.Binding[]
    append!(bs, binding_reads[i])
    if def isa Method
        for gr in globalrefs(def)
            b = try
                convert(Core.Binding, gr)
            catch
                continue
            end
            push!(bs, b)
        end
    end
    seen = Set{UInt64}()
    for b in bs
        push!(seen, partition_hash(b))
    end
    for ph in sort!(collect(seen))
        h = hash(ph, h)
    end
    return h
end

"""
    binding_reads(g) -> Vector{Vector{Core.Binding}}

Turn `g.binding_users` around: the bindings each node reads through its edges.
"""
function binding_reads(g::Graph)
    out = [Core.Binding[] for _ in 1:length(g.nodes)]
    for (target, users) in g.binding_users
        target isa Core.Binding || continue
        for i in users
            push!(out[i], target)
        end
    end
    return out
end

# ---------------------------------------------------------------------------
# Components
# ---------------------------------------------------------------------------

"""
    components(g) -> (comp::Vector{Int}, order::Vector{Vector{Int}})

Tarjan's algorithm over the forward edges, without recursion. `comp[i]` is the
component of node `i`; `order` lists the components with every component after
the components it calls, which is the order the keys are computed in.
"""
function components(g::Graph)
    n = length(g.nodes)
    index = zeros(Int, n)
    low = zeros(Int, n)
    onstack = falses(n)
    stack = Int[]
    comp = zeros(Int, n)
    order = Vector{Vector{Int}}()
    counter = 0
    # The explicit call stack: (node, position in its edge list).
    work = Tuple{Int,Int}[]
    for root in 1:n
        index[root] == 0 || continue
        push!(work, (root, 1))
        counter += 1
        index[root] = low[root] = counter
        push!(stack, root); onstack[root] = true
        while !isempty(work)
            v, pos = work[end]
            edges = g.forward[v]
            if pos <= length(edges)
                work[end] = (v, pos + 1)
                w = edges[pos]
                if index[w] == 0
                    counter += 1
                    index[w] = low[w] = counter
                    push!(stack, w); onstack[w] = true
                    push!(work, (w, 1))
                elseif onstack[w]
                    low[v] = min(low[v], index[w])
                end
            else
                pop!(work)
                if !isempty(work)
                    u = work[end][1]
                    low[u] = min(low[u], low[v])
                end
                if low[v] == index[v]
                    members = Int[]
                    while true
                        w = pop!(stack); onstack[w] = false
                        push!(members, w)
                        w == v && break
                    end
                    push!(order, members)
                    c = length(order)
                    for w in members
                        comp[w] = c
                    end
                end
            end
        end
    end
    return comp, order
end

"""
    component_keys(g) -> Vector{UInt64}

The key of every node: the key of its component.
"""
function component_keys(g::Graph)
    reads = binding_reads(g)
    locals = [local_hash(g, i, reads) for i in 1:length(g.nodes)]
    comp, order = components(g)
    ckey = zeros(UInt64, length(order))
    for (c, members) in enumerate(order)
        h = hash(:component)
        for lh in sort!([locals[i] for i in members])
            h = hash(lh, h)
        end
        succ = Set{UInt64}()
        for i in members, j in g.forward[i]
            comp[j] == c && continue
            push!(succ, ckey[comp[j]])
        end
        for sk in sort!(collect(succ))
            h = hash(sk, h)
        end
        ckey[c] = h
    end
    return [ckey[comp[i]] for i in 1:length(g.nodes)]
end

"""
    name_key_pairs(g, keys) -> Dict{Tuple{String,UInt64},Int}

The multiset of (node name, key) over the graph.
"""
function name_key_pairs(g::Graph, keys::Vector{UInt64})
    out = Dict{Tuple{String,UInt64},Int}()
    for (i, mi) in enumerate(g.nodes)
        p = (node_name(mi), keys[i])
        out[p] = get(out, p, 0) + 1
    end
    return out
end

end # module ReadKey
