# A macro that defines a struct with keyword defaults. The edit changes the
# macro so that the struct has a second field; the default constructor follows.
# Revise has the test set "Default constructors for macro-generated types".
module DefaultConstructorsMacroTypes
macro make_point(name, default)
    esc(quote
        Base.@kwdef struct $name
            x::Int = $default
        end
    end)
end
@make_point Pt 1
shown() = (Pt().x, fieldnames(Pt), hasmethod(Pt, Tuple{}))
end
