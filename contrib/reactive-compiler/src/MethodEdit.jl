"""
    MethodEdit

Redefine a method from its own source, so that any method can be "edited".

The measurements need to edit a method that this code did not write, and whose
body is a hundred lines long. Rewriting such a body by hand is not practical and
would change the program. Instead read the source back from the file that the
`Method` names, parse the one expression there, and evaluate it again in the
module that owns it.

A redefinition with the same text is still an edit as far as Julia is concerned:
it bumps the world counter and invalidates whatever depended on the method. That
is exactly what the invalidation cone is measured from, and it has the advantage
that the program still means the same thing afterwards, so the run can continue.
"""
module MethodEdit

export method_source, redefine!

"""
    line_offset(text, line) -> Int

The index in `text` at which the given 1-based line starts.
"""
function line_offset(text::String, line::Int)
    offset = 1
    current = 1
    while current < line
        next = findnext('\n', text, offset)
        next === nothing && error("file has fewer than $line lines")
        offset = nextind(text, next)
        current += 1
    end
    return offset
end

"""
    method_source(m::Method; replace = nothing) -> (Expr, String)

Parse the definition of `m` out of its file. Answer the expression and the path.

The `line` of a method points at its signature. A definition may carry a
docstring or a macro above it; this reads from the signature line, so what comes
back is the bare definition.

`replace` is a `"before" => "after"` pair applied to the text of the definition
before it is parsed. This is a real edit. The text must contain `before` exactly
once.
"""
function method_source(m::Method; replace = nothing)
    path = string(m.file)
    isfile(path) || error("the file of $(m.name) is not readable: $path")
    text = read(path, String)
    offset = line_offset(text, Int(m.line))
    expr, stop = Meta.parse(text, offset)
    expr === nothing && error("nothing parsed at $path:$(m.line)")
    if replace !== nothing
        chunk = String(SubString(text, offset, prevind(text, stop)))
        n = count(replace.first, chunk)
        n == 1 || error("the definition of $(m.name) contains $(repr(replace.first)) $n times, not once")
        expr = Meta.parse(Base.replace(chunk, replace))
    end
    return expr, path
end

"""
    redefine!(m::Method; replace = nothing) -> Float64

Evaluate the definition of `m` again in its own module. Answer the seconds it took.

Julia re-infers what it invalidates during the redefinition, so the time this
answers is the cost of the edit, including the cone. With `replace` the new
definition differs from the old one; see `method_source`.
"""
function redefine!(m::Method; replace = nothing)
    expr, _ = method_source(m; replace)
    mod = m.module
    return @elapsed Core.eval(mod, expr)
end

"""
    can_redefine(m::Method) -> Bool

Whether the source of `m` parses into something that looks like its definition.

A method that a macro or an `@eval` generated does not read back this way. Check
before you measure, so that a failure is reported and not counted as an edit that
invalidated nothing.
"""
function can_redefine(m::Method)
    try
        expr, _ = method_source(m)
        return expr isa Expr && (expr.head === :function || expr.head === :(=) ||
                                 expr.head === :macrocall || expr.head === :block)
    catch
        return false
    end
end

end # module MethodEdit
