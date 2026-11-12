# An expression that reads a definition that comes after it in the load order
# (finding 53), after the step `order` of the gate: the struct has one more
# field, so the method that the use of the macro defines names a new type, and
# a rebuild must evaluate the use again.
struct Crate
    size::Int
    lid::Bool
end
Crate(size) = Crate(size, false)

# The layout of a name. The macro `@shelf` asks for it when it expands.
layout_of(::Val) = :plain
macro shelf(name)
    layout = layout_of(Val(name))
    return esc(:($(Symbol(name, :_layout))(crate::Crate) = $(QuoteNode(layout))))
end
@shelf crate

# The answer for the name `crate` comes after the use of the macro, so a whole
# build expands the use with the answer of the method above.
layout_of(::Val{:crate}) = :wrapped
