# A struct that the edit redefines with a new supertype, together with a new
# abstract type, a new parametric struct and a method on it.
# Revise has the test set "Struct redefinition plus new struct".
module StructRedefinitionPlusNewStruct
struct Est
    a::Float64
end
f(e::Est) = e.a
shown() = (f(Est(2.0)), supertype(Est) === Any, isdefined(@__MODULE__, :Grp),
           isdefined(@__MODULE__, :g) ? g(Grp(3.0)) : 0)
end
