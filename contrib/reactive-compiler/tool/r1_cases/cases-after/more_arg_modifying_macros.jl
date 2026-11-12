# A macro that adds an argument to the signature of the function it is given.
# The edit changes the body of the function, which reads the added argument.
# Revise has the test set "More arg-modifying macros".
module MoreArgModifyingMacros
macro with_scale(def)
    push!(def.args[1].args, :(scale::Int))
    esc(def)
end
@with_scale area(w, h) = w * h + scale
shown() = (area(2, 3, 4), hasmethod(area, Tuple{Int,Int,Int}), hasmethod(area, Tuple{Int,Int}))
end
