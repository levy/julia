# An alias that a type definition names: the edit changes the alias, and the
# field of the struct must have the new type. Revise lists it as a limit
# ("Toplevel binding changes do not propagate").
module AliasInAType
Items{T} = Vector{T}
struct Shelf{T}
    items::Items{T}
end
shown() = fieldtype(Shelf{Int}, :items)
end
