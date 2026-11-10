# The reach of a tracked expression: the code that its evaluation runs.
#
# An expression is evaluated again when something that its last evaluation used
# changed. The ledger knows the text of the expression, the bindings of its
# names and the files that it reads. This file adds the code that the evaluation
# runs: an initializer and a statement call functions, an expansion runs the
# body of a macro, and a `@generated` method runs its generator.
#
# The reach is found by name, from the syntax of the tracked files:
#   - the code of a method, of a macro, of a type and of an initializer is
#     filed under the name that the expression defines (`rc_filed_names`);
#   - a name *uses* each name of the code that is filed under it;
#   - an expression runs the names of `ReactiveSourceDiff.run_names`, and each
#     name that these use, through any count of steps.
# When an apply changes the code under a name, each expression that runs a name
# which uses the changed one is evaluated again (`rc_affected`, `rc_reach_hit`).
#
# The reach is larger than the truth: a name is a symbol with no module, and a
# local variable counts as a name. An expression that is evaluated with no need
# costs its evaluation only: Julia keeps a constant of an equal value and a
# struct of the same shape, and the method filter keeps a method of the same
# code.
#
# Untracked code calls a method through its function with no name in a tracked
# file: `print(x)` of Base runs the `Base.show` of a tracked type. So a method of
# a function of an untracked module, and a method of the values of a type, is
# filed under each tracked type and constant of its signature too: a value of
# that type must exist before the method can run, and the code that makes the
# value names the type.

# The names of one expression for the reach, read from its syntax.
struct RcNames
    runs::Set{Symbol}
    body::Set{Symbol}
    signature::Set{Symbol}
    owner::Union{Symbol, Nothing}
    callable::Bool
end

# The names of each expression that a ledger of this process read, by the key
# of the expression. An apply keeps the keys of its new ledger.
const RC_NAMES = Dict{UInt64, RcNames}()

function rc_names(item::RcItem)
    return get!(RC_NAMES, item.entry.key) do
        e = item.entry.expr
        method = item.kind === :method
        RcNames(ReactiveSourceDiff.run_names(e), ReactiveSourceDiff.body_names(e),
                method ? ReactiveSourceDiff.type_level_names(e) : Set{Symbol}(),
                method ? ReactiveSourceDiff.method_owner(e) : nothing,
                method && ReactiveSourceDiff.is_callable_method(e))
    end
end

# The name graph of a ledger.
#   users     - for a name, the names whose code names it
#   modules   - the names of the tracked modules
#   defined   - the names of the tracked types, constants and globals
#   imported  - the names that a module imports from an untracked module, each
#               with the path of the module that imports it
struct RcReach
    users::Dict{Symbol, Vector{Symbol}}
    modules::Set{Symbol}
    defined::Set{Symbol}
    imported::Set{Tuple{Vector{Symbol}, Symbol}}
end

# The names under which the code of `item` is filed: the name that it defines,
# and for a method that untracked code can call through its function, each
# tracked type and constant of its signature.
function rc_filed_names(reach::RcReach, roots, item::RcItem)
    filed = Symbol[]
    item.name === nothing && return filed
    item.kind in RC_METHOD_KINDS || item.kind === :type || item.kind in RC_BINDING_KINDS || return filed
    push!(filed, item.name)
    item.kind === :method || return filed
    names = rc_names(item)
    outside = names.callable ||
              names.owner !== nothing && !(names.owner in reach.modules) ||
              (rc_module_path(roots, item), item.name) in reach.imported
    outside || return filed
    for name in names.signature
        name in reach.defined && name !== item.name && push!(filed, name)
    end
    return filed
end

# The name graph of `items`, the ledger of every tracked file, whose module
# paths start at `roots`.
function rc_reach(items::Vector{RcItem}, roots)
    modules = Set{Symbol}()
    for root in roots
        union!(modules, root)
    end
    defined = Set{Symbol}()
    imported = Set{Tuple{Vector{Symbol}, Symbol}}()
    for item in items
        item.name === nothing && continue
        if item.kind === :module
            push!(modules, item.name)
        elseif item.kind === :type || item.kind in RC_BINDING_KINDS
            push!(defined, item.name)
        end
    end
    for item in items
        item.kind === :using || continue
        for (name, root) in ReactiveSourceDiff.imported_names(item.entry.expr)
            root === nothing || root in modules || push!(imported, (rc_module_path(roots, item), name))
        end
    end
    reach = RcReach(Dict{Symbol, Vector{Symbol}}(), modules, defined, imported)
    seen = Set{Tuple{Symbol, Symbol}}()
    for item in items
        filed = rc_filed_names(reach, roots, item)
        isempty(filed) && continue
        for name in rc_names(item).body, under in filed
            name === under && continue
            (name, under) in seen && continue
            push!(seen, (name, under))
            push!(get!(reach.users, name, Symbol[]), under)
        end
    end
    return reach
end

# Add to `affected` each name of `changed` and each name that uses one, through
# any count of steps, and answer the names that are new in `affected`.
function rc_affected!(affected::Set{Symbol}, reach::RcReach, changed)
    added = Symbol[]
    pending = Symbol[]
    for name in changed
        name in affected && continue
        push!(affected, name)
        push!(added, name)
        push!(pending, name)
    end
    while !isempty(pending)
        name = pop!(pending)
        for user in get(reach.users, name, ())
            user in affected && continue
            push!(affected, user)
            push!(added, user)
            push!(pending, user)
        end
    end
    return added
end

# A name of the set `names` that the evaluation of `item` runs, or `nothing`.
function rc_reach_hit(item::RcItem, names)
    for name in rc_names(item).runs
        name in names && return name
    end
    return nothing
end
