"""
    ReactiveSourceDiff

Find the top-level expressions that changed between two versions of one source
file. The materialize step evaluates only those expressions, in the module that
owns them, so that the delta of the build holds the cone of the edit and
nothing else.

The comparison ignores line numbers: an edit near the top of a file moves the
line of every later expression, and a comparison that read the line numbers
would report the whole file as changed. The evaluation uses the parsed
expression with its line numbers, and the parse names the real file, so a
redefined method keeps a readable `file` and `line`.

A `module` block is not one unit. When the old file and the new file both hold
a module with the same name, the comparison descends into the two bodies, so
an edit of one function inside a module changes one expression and not the
module. A quoted expression is one unit: a change of only the line numbers
inside a `quote` block counts as a change.

An expression that the old file holds and the new file does not is a removal.
Julia has no cheap way to undefine a method in a build child, so a removal is
reported and not applied; the caller decides whether that is acceptable.
"""
module ReactiveSourceDiff

export changed_expressions, defined_name

"Strip every `LineNumberNode` from `x`, recursively, for the comparison only."
strip_lines(x) = x
function strip_lines(e::Expr)
    args = Any[]
    for a in e.args
        a isa LineNumberNode && continue
        push!(args, strip_lines(a))
    end
    return Expr(e.head, args...)
end

"""
    defined_name(e) -> Union{Symbol, Nothing}

The name that a definition defines, or `nothing`. A definition wrapped in a
docstring or another macro is unwrapped; a signature is unwrapped down to the
name. `f(x) = ...`, `function f(x) ... end` and `function f end` all answer
`:f`.
"""
function defined_name(e)
    e isa Expr || return nothing
    if e.head === :macrocall
        for a in e.args
            name = defined_name(a)
            name === nothing || return name
        end
        return nothing
    end
    e.head === :function || e.head === :(=) || return nothing
    signature = e.args[1]
    while signature isa Expr
        if signature.head === :call || signature.head === :where || signature.head === :(::) ||
           signature.head === :curly
            signature = signature.args[1]
        elseif signature.head === :. && signature.args[2] isa QuoteNode
            # A method added to a function of another module: `A.f(x) = ...`.
            return (signature.args[2]::QuoteNode).value::Symbol
        else
            return nothing
        end
    end
    return signature isa Symbol ? signature : nothing
end

is_module(e) = e isa Expr && e.head === :module
module_name(e::Expr) = e.args[2]::Symbol
module_body(e::Expr) = (e.args[3]::Expr).args

"Parse `text` into its top-level expressions, with `path` as the file name."
parse_toplevel(text::AbstractString, path::AbstractString) =
    Meta.parseall(String(text); filename = String(path)).args

"""
    changed_expressions(old_text, new_text, path)
        -> (changed = [(module_path, expr)], removed = [(module_path, expr)])

Compare two versions of the file `path`. Answer the expressions of `new_text`
that `old_text` does not hold, each with the path of module names that leads
to it from the root module of the file, in the order of the new file. Answer
also the removals: the expressions of `old_text` that `new_text` does not
hold, and that no changed expression with the same defined name replaces.
"""
function changed_expressions(old_text::AbstractString, new_text::AbstractString, path::AbstractString)
    changed = Tuple{Vector{Symbol}, Any}[]
    removed = Tuple{Vector{Symbol}, Any}[]
    walk!(changed, removed,
          parse_toplevel(old_text, path), parse_toplevel(new_text, path), Symbol[])
    replaced = Set{Any}((module_path, defined_name(e)) for (module_path, e) in changed
                        if defined_name(e) !== nothing)
    filter!(removed) do (module_path, e)
        !((module_path, defined_name(e)) in replaced)
    end
    return (changed = changed, removed = removed)
end

function walk!(changed, removed, old::Vector{Any}, new::Vector{Any}, module_path::Vector{Symbol})
    old_stripped = Set{Any}()
    old_modules = Dict{Symbol, Expr}()
    for e in old
        e isa LineNumberNode && continue
        push!(old_stripped, strip_lines(e))
        is_module(e) && (old_modules[module_name(e)] = e)
    end
    new_stripped = Set{Any}()
    new_modules = Set{Symbol}()
    for e in new
        e isa LineNumberNode && continue
        push!(new_stripped, strip_lines(e))
        is_module(e) && push!(new_modules, module_name(e))
    end
    for e in new
        e isa LineNumberNode && continue
        strip_lines(e) in old_stripped && continue
        if is_module(e) && haskey(old_modules, module_name(e))
            walk!(changed, removed, module_body(old_modules[module_name(e)]), module_body(e),
                  vcat(module_path, module_name(e)))
        else
            push!(changed, (module_path, e))
        end
    end
    for e in old
        e isa LineNumberNode && continue
        stripped = strip_lines(e)
        stripped in new_stripped && continue
        # A changed module is walked above; only a module that disappeared is a removal.
        is_module(e) && module_name(e) in new_modules && continue
        push!(removed, (module_path, e))
    end
    return nothing
end

end # module ReactiveSourceDiff
