# Methods that the edit deletes: a method on Int, and two of the three methods of
# a function with type parameters. The other methods must stay.
# Revise has the test set "Method deletion".
module MethodDeletion
f(x) = 1
f(x::Int) = 2
g(x::Vector{T}, y::T) where T = 1
g(x::Array{T,N}, y::T) where {N,T} = 2
g(::Array, ::Any) = 3
shown() = (f(1.0), f(1), length(methods(f)), length(methods(g)),
           hasmethod(g, Tuple{Vector{Int},Float64}), g(zeros(3, 3), 1.0))
end
