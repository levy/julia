# Default arguments make several methods. The edit replaces two defaults by one
# default of a tuple type, so the methods of the old arities must go.
# Revise has the test set "Method deletion".
module MethodDeletionDefaultArgs
dfltargs(x::Int8, y::Int=0, z::Float32=1.0f0) = x + y + z
shown() = (dfltargs(Int8(2)), hasmethod(dfltargs, Tuple{Int8,Int}),
           hasmethod(dfltargs, Tuple{Int8,Tuple{Int,Float32}}))
end
