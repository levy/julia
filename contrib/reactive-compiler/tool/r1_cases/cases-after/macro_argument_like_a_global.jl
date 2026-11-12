# The argument of a macro call that looks like a global with the name of a
# struct: the macro defines a method for the struct and binds no global. The
# edit gives the struct a field, so the rebuild evaluates the macro call again,
# and the struct must stay. A platform package has such a line
# (`@insertion TextBlock = ...`).
module MacroArgumentLikeAGlobal
struct Block
    size::Int
    depth::Int
end
Block(size) = Block(size, 0)
macro register(assignment)
    name, value = assignment.args
    return esc(:(default_of(::Type{$name}) = $value))
end
@register Block = Block(1)
shown() = (default_of(Block).size, fieldcount(Block))
end
