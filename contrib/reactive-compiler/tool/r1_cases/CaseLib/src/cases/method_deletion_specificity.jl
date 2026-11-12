# Two methods, one on Int and one on Integer. The edit deletes the more specific
# one; the call must reach the method that is left.
# Revise has the test set "Method deletion specificity".
module MethodDeletionSpecificity
methspecificity(x::Int) = 1
methspecificity(x::Integer) = 2
shown() = (methspecificity(1), length(methods(methspecificity)))
end
