# Signatures of several forms: a method with a type parameter bound and a default
# argument, and a function with a keyword. The edit changes the bodies, the bound
# and the keyword default. Revise has the test set "Signature extraction".
module SignatureForms
f(x::T, y=2) where T<:Real = x * y
g(; k=3) = k
shown() = (f(3), f(3, 5), g(), g(k=4), hasmethod(f, Tuple{Float64}))
end
