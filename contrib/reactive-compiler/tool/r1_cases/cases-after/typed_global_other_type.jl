# Two typed globals with no keyword. The edit gives the first one another
# type, and removes the second one. Julia gives a typed global no other type
# in a module that holds it, so the declaration of before must leave first.
module TypedGlobalOtherType
counter::Float64 = 1.5
shown() = (counter, Core.get_binding_type(@__MODULE__, :counter), isdefined(@__MODULE__, :limit))
end
