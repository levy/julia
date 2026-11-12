# A mutable struct whose body holds an inner constructor and a helper function.
# The edit changes a function after the struct; the struct must stay as it is.
# Revise has the test set "struct inner functions".
module StructInnerFunctions
mutable struct A
    x::Int

    A(x) = new(f(x))
    f(x) = x^2
end
g(x) = 2
shown() = (A(2).x, g(3))
end
