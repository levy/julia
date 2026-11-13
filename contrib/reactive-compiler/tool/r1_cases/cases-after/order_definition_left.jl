# A type that the edit moves below a method that names it in its signature
# (H4). A whole build stops at the method, because the type is not defined
# there; the process of a rebuild holds the type, so the rebuild must refuse.
module OrderDefinitionLeft
holder(c::Crate) = c.size
struct Crate
    size::Int
end
shown() = holder(Crate(4))
end
