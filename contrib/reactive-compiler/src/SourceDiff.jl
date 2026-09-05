"""
    ReactiveSourceDiff

The syntactic half of the ledger of a rebuild: the top-level expressions of
one source file, each with the module that owns it, its lines, its kind, the
name it defines, the macros it names, the global names of its signature or
initializer, and the files its evaluation reads. The rebuild child compares
the ledger of the stored copy of a file with the ledger of the file on disk,
and evaluates only the expressions that changed, plus the ones that depend
on them, in the module that owns them.

The key of an expression is the hash of the expression with every line
number stripped: an edit near the top of a file moves the line of every
later expression, and a key that read the line numbers would report the
whole file as changed. The evaluation uses the parsed expression with its
line numbers, and the parse names the real file, so a redefined method keeps
a readable `file` and `line`.

A `module` block is not one unit: its header is one entry (the module with an
empty body) and each expression of its body is an entry of the deeper module
path, so an edit of one function inside a module changes one expression and
not the module. A quoted expression is one unit.

Nothing here evaluates: the kinds and the names are read from the syntax.
What an expression defines is found by the child, from the method table,
by the file and the lines of the entry.
"""
module ReactiveSourceDiff

export Entry, file_entries, changed_expressions, is_module, entry_kind, defined_name, macro_heads, type_level_names, all_names,
       read_paths, type_shape

"Strip every `LineNumberNode` from `x`, recursively, for the key only."
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
One top-level expression of a file: the module path from the root module of
the file, the expression with its line numbers, the key, and the lines of the
file that it spans (the lines of its methods fall inside).
"""
struct Entry
    module_path::Vector{Symbol}
    expr::Any
    key::UInt64
    lines::UnitRange{Int}
end

entry_key(e, module_path) = hash(strip_lines(e), hash(module_path))

is_module(e) = e isa Expr && e.head === :module
module_name(e::Expr) = e.args[2]::Symbol
module_body(e::Expr) = (e.args[3]::Expr).args

"""
    file_entries(text, path) -> Vector{Entry}

The entries of the file `path` with the content `text`, in file order. A
parse error is an error: the founding would fail on the file as well.
"""
function file_entries(text::AbstractString, path::AbstractString)
    top = Meta.parseall(String(text); filename = String(path))
    last_line = count(==('\n'), text) + 1
    entries = Entry[]
    collect_entries!(entries, top.args, Symbol[], last_line, path)
    return entries
end

# The arguments of a top level or of a module body alternate a
# `LineNumberNode` and an expression: the node before an expression gives its
# first line, the node after it ends it.
function collect_entries!(entries, args::Vector{Any}, module_path, last_line, path)
    line = 1
    for (index, e) in enumerate(args)
        if e isa LineNumberNode
            line = e.line
            continue
        end
        e isa Expr && e.head in (:error, :incomplete) &&
            error("ReactiveSourceDiff: $path:$line does not parse: ", e.args...)
        stop = last_line
        for later in args[index + 1:end]
            if later isa LineNumberNode
                stop = later.line - 1
                break
            end
        end
        if is_module(e)
            header = Expr(:module, e.args[1], e.args[2], Expr(:block))
            push!(entries, Entry(module_path, header, entry_key(header, module_path), line:line))
            collect_entries!(entries, module_body(e), vcat(module_path, module_name(e)), stop, path)
        elseif e isa Expr && e.head === :toplevel
            collect_entries!(entries, e.args, module_path, stop, path)
        else
            push!(entries, Entry(module_path, e, entry_key(e, module_path), line:stop))
        end
    end
    return nothing
end

# The name of a macro call: `@m`, `Mod.@m` and a `GlobalRef` all answer `:@m`.
function macro_name(head)
    head isa Symbol && return head
    head isa GlobalRef && return head.name
    head isa Expr && head.head === :. && head.args[2] isa QuoteNode &&
        return (head.args[2]::QuoteNode).value
    return nothing
end

"""
    definition(e)

The expression that a macro call wraps: the documented definition of a
docstring, the struct of `@kwdef`, the method of `@inline`. An expression
that no macro wraps answers itself.
"""
function definition(e)
    while e isa Expr && e.head === :macrocall
        inner = nothing
        for a in e.args[2:end]
            a isa LineNumberNode && continue
            if a isa Expr
                inner = a
                entry_kind(a) === :other || break
            end
        end
        inner === nothing && return e
        e = inner
    end
    return e
end

"""
    entry_kind(e) -> Symbol

What a top-level expression is: `:method`, `:macro`, `:type`, `:const`,
`:global`, `:using`, `:export`, `:include`, `:dependency`, `:module`, or
`:other` for any other form, which is evaluated as one unit.
"""
function entry_kind(e)
    e isa Expr || return :other
    h = e.head
    h === :module && return :module
    h in (:struct, :abstract, :primitive) && return :type
    h === :const && return :const
    h === :global && return :global
    h in (:using, :import) && return :using
    h in (:export, :public) && return :export
    h === :macro && return :macro
    h === :function && return :method
    if h === :(=)
        lhs = e.args[1]
        (lhs isa Symbol || lhs isa Expr && lhs.head === :tuple) && return :global
        return defined_name(e) === nothing ? :other : :method
    end
    if h === :call && !isempty(e.args)
        e.args[1] === :include && return :include
        e.args[1] === :include_dependency && return :dependency
        return :other
    end
    if h === :macrocall
        inner = definition(e)
        return inner === e ? :other : entry_kind(inner)
    end
    return :other
end

# The name of a signature: `f`, `f(x)`, `f(x) where T`, `f(x)::T`, `A.f(x)`.
function signature_name(signature)
    while signature isa Expr
        if signature.head in (:call, :where, :(::), :curly)
            signature = signature.args[1]
        elseif signature.head === :. && signature.args[2] isa QuoteNode
            # A method added to a function of another module: `A.f(x) = ...`.
            return (signature.args[2]::QuoteNode).value::Symbol
        elseif signature.head === :tuple
            # An anonymous function `(x, y) -> ...` in an assignment is no method.
            return nothing
        else
            return nothing
        end
    end
    return signature isa Symbol ? signature : nothing
end

type_name(sig) = sig isa Symbol ? sig :
                 sig isa Expr && sig.head in (:curly, :<:) ? type_name(sig.args[1]) : nothing

"""
    defined_name(e) -> Union{Symbol, Nothing}

The name that a definition defines, or `nothing`: the function of a method
(`f(x) = ...`, `function f(x) ... end`, `function f end`, `A.f(x) = ...` all
answer `:f`), the macro of a macro definition (`:@m`), the type of a type
definition, the binding of a `const` or a `global`, the name of a module. A
definition wrapped in a docstring or another macro is unwrapped.
"""
function defined_name(e)
    e isa Expr || return nothing
    h = e.head
    if h === :macrocall
        inner = definition(e)
        return inner === e ? nothing : defined_name(inner)
    end
    h === :module && return e.args[2]::Symbol
    h === :struct && return type_name(e.args[2])
    h in (:abstract, :primitive) && return type_name(e.args[1])
    h === :const && return defined_name(e.args[1])
    if h === :global
        a = e.args[1]
        return a isa Symbol ? a : defined_name(a)
    end
    if h === :macro
        name = signature_name(e.args[1])
        return name === nothing ? nothing : Symbol("@", name)
    end
    if h === :function || h === :(=)
        lhs = e.args[1]
        lhs isa Symbol && return lhs
        return signature_name(lhs)
    end
    return nothing
end

"""
    macro_heads(e) -> Set{Symbol}

The names of every macro that the expression calls, anywhere in it, quoted
bodies included: what a macro definition expands to is the quote of its
body, so the calls in the quote are the macros that its expansions expand.
"""
function macro_heads(e)
    set = Set{Symbol}()
    macro_heads!(set, e)
    return set
end
function macro_heads!(set, e)
    e isa Expr || return
    if e.head === :macrocall
        name = macro_name(e.args[1])
        name isa Symbol && push!(set, name)
    end
    for a in e.args
        macro_heads!(set, a)
    end
    return nothing
end

"""
    all_names(e) -> Set{Symbol}

Every name that the expression could resolve as a global: each symbol in it,
and the last name of every `A.b` chain. Locals and arguments are in the set
too; the set is an over-approximation for a filter, never a proof.
"""
function all_names(e)
    set = Set{Symbol}()
    names!(set, e)
    return set
end
function names!(set, e)
    if e isa Symbol
        push!(set, e)
    elseif e isa Expr
        if e.head === :. && length(e.args) == 2 && e.args[2] isa QuoteNode
            push!(set, (e.args[2]::QuoteNode).value)
            names!(set, e.args[1])
        elseif e.head === :quote
            # A quoted symbol names nothing; a quoted expression is the body
            # of a macro or of an `@eval`, and its names resolve later.
            for a in e.args
                a isa Symbol || names!(set, a)
            end
        else
            for a in e.args
                names!(set, a)
            end
        end
    end
    return nothing
end

# The names of the types of a signature: every argument type, the bounds of
# the `where` parameters, the return type. The argument names, the parameter
# names and the function name are left out.
function signature_names!(set, signature)
    signature isa Expr || return nothing
    if signature.head === :call
        head = signature.args[1]
        head isa Symbol || names!(set, head)
        for a in signature.args[2:end]
            argument_names!(set, a)
        end
    elseif signature.head === :where
        signature_names!(set, signature.args[1])
        for p in signature.args[2:end]
            p isa Expr && p.head in (:<:, :>:) && names!(set, p.args[2])
            if p isa Expr && p.head === :comparison
                names!(set, p.args[1])
                names!(set, p.args[end])
            end
        end
    elseif signature.head === :(::)
        signature_names!(set, signature.args[1])
        names!(set, signature.args[end])
    elseif signature.head === :tuple
        for a in signature.args
            argument_names!(set, a)
        end
    end
    return nothing
end
function argument_names!(set, a)
    a isa Expr || return nothing
    if a.head === :(::)
        names!(set, a.args[end])
    elseif a.head === :kw
        argument_names!(set, a.args[1])
    elseif a.head === :parameters
        for p in a.args
            argument_names!(set, p)
        end
    elseif a.head === :...
        argument_names!(set, a.args[1])
    end
    return nothing
end

"""
    type_level_names(e) -> Set{Symbol}

The global names that the evaluation of the expression binds into what it
defines: the types of a method signature, the supertype, the parameters and
the field types of a type, the initializer of a `const` or a `global`. A
name in a method body is not in the set: a body resolves its names when it
compiles, and Julia invalidates it when a binding changes. An expression of
another kind answers every name it holds.
"""
function type_level_names(e)
    set = Set{Symbol}()
    d = definition(e)
    kind = entry_kind(d)
    if kind === :method
        signature_names!(set, d.args[1])
    elseif kind === :type
        if d.head === :struct
            type_signature_names!(set, d.args[2])
            for field in (d.args[3]::Expr).args
                field isa Expr && field.head === :(::) && names!(set, field.args[end])
                # An inner constructor is a method: its body is its own.
            end
        else
            type_signature_names!(set, d.args[1])
        end
    elseif kind === :const || kind === :global
        inner = d.head === :const || d.head === :global ? d.args[1] : d
        inner isa Expr && inner.head === :(=) && names!(set, inner.args[2])
    elseif kind === :macro || kind === :module || kind === :export || kind === :include
        # nothing to bind
    else
        names!(set, d)
    end
    return set
end
function type_signature_names!(set, sig)
    sig isa Expr || return nothing
    if sig.head === :<:
        type_signature_names!(set, sig.args[1])
        names!(set, sig.args[2])
    elseif sig.head === :curly
        for p in sig.args[2:end]
            p isa Expr && p.head === :<: && names!(set, p.args[2])
        end
    end
    return nothing
end

"""
    type_shape(e)

The part of a type definition that decides the identity of the type: the
definition with every inner constructor removed, and line numbers stripped.
Two definitions with one shape define one type; Julia keeps the type and
redefines the constructors.
"""
function type_shape(e)
    d = definition(e)
    d isa Expr && d.head === :struct || return strip_lines(d)
    body = Expr(:block)
    for field in (d.args[3]::Expr).args
        field isa LineNumberNode && continue
        field isa Expr && field.head in (:function, :(=)) && defined_name(field) !== nothing && continue
        push!(body.args, strip_lines(field))
    end
    return Expr(:struct, d.args[1], strip_lines(d.args[2]), body)
end

"""
    read_paths(e, dir) -> Vector{String}

The files that the evaluation of the expression can read: every string
literal in it that names a file relative to `dir`, the directory of the
source file, as `joinpath(@__DIR__, "data.txt")` and `include_dependency`
name them. An `include` names a tracked file, not a read.
"""
function read_paths(e, dir::AbstractString)
    paths = String[]
    entry_kind(e) === :include && return paths
    literals = String[]
    string_literals!(literals, e)
    for s in literals
        occursin('\n', s) && continue
        path = isabspath(s) ? s : joinpath(dir, s)
        isfile(path) && push!(paths, normpath(path))
    end
    return unique!(paths)
end
function string_literals!(literals, e)
    if e isa String
        push!(literals, e)
    elseif e isa Expr
        for a in e.args
            string_literals!(literals, a)
        end
    end
    return nothing
end

# ── the diff of two texts ───────────────────────────────────────────────────

is_module(e) = e isa Expr && e.head === :module

"""
    changed_expressions(old_text, new_text, path) -> (changed, removed)

The entries of `new_text` whose key `old_text` has not, and the entries of
`old_text` whose key `new_text` has not and whose name no changed entry of
the same module defines, each as `(module_path, expr)` in file order. The
M4 gate's child reads the diff in this form.
"""
function changed_expressions(old_text::AbstractString, new_text::AbstractString, path::AbstractString)
    old_entries = file_entries(old_text, path)
    new_entries = file_entries(new_text, path)
    old_keys = Set{UInt64}(e.key for e in old_entries)
    new_keys = Set{UInt64}(e.key for e in new_entries)
    changed = Entry[e for e in new_entries if !(e.key in old_keys)]
    defined = Set{Tuple{Vector{Symbol}, Symbol}}((e.module_path, defined_name(e.expr)) for e in changed
                                                 if defined_name(e.expr) !== nothing)
    removed = Entry[e for e in old_entries if !(e.key in new_keys) &&
                    !((e.module_path, something(defined_name(e.expr), Symbol(""))) in defined)]
    return (changed = Tuple{Vector{Symbol}, Any}[(e.module_path, e.expr) for e in changed],
            removed = Tuple{Vector{Symbol}, Any}[(e.module_path, e.expr) for e in removed])
end

end # module ReactiveSourceDiff
