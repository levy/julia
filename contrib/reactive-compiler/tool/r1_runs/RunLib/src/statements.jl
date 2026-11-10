# The statements whose effect an edit must take back. The gate replaces this
# file with statements-after.jl, and then with statements-refused.jl.

# A list that statements fill. The edit changes the second statement.
const REGISTRY = Symbol[]
push!(REGISTRY, :first)
push!(REGISTRY, :second)

# A table that one statement fills. The edit removes the statement.
const SEEN = Dict{Symbol, Int}()
SEEN[:a] = 1

# A statement that names no global: it writes into a list that only its
# function names. The rebuild can not take back what it did.
remember(:loaded)
