# An expression that reads a definition that comes after it in the load order
# (finding 53). The gate replaces this file with order-after.jl.
struct Crate
    size::Int
end

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
