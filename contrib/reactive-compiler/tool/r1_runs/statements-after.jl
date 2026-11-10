# The statements whose effect an edit must take back, after the edit of the
# gate: one statement of the list has another value, and the statement of the
# table is gone.

# A list that statements fill. The edit changes the second statement.
const REGISTRY = Symbol[]
push!(REGISTRY, :first)
push!(REGISTRY, :third)

# A table that one statement fills. The edit removes the statement.
const SEEN = Dict{Symbol, Int}()

# A statement that names no global: it writes into a list that only its
# function names. The rebuild can not take back what it did.
remember(:loaded)
