# Structs made by a keyword macro. The edit changes only the default values of
# the fields, so the types keep their shape.
# Revise has the test set "struct revision (issue #1022)".
module StructRevisionDefaultOnly
Base.@kwdef struct Blah
    x = 5
end
useblah(b::Blah) = b.x + 1
if true
    abstract type AbstractWrapped end
    Base.@kwdef struct Wrapped <: AbstractWrapped
        w::Int = 2
    end
end
shown() = (Blah().x, useblah(Blah()), Wrapped().w, supertype(Wrapped) === AbstractWrapped)
end
