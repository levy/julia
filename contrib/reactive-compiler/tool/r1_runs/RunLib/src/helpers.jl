# The functions that the expressions of users.jl run. The gate replaces this
# file with helpers-after.jl.

# The initializer of a constant calls this function.
make_table() = Dict(:answer => 1)

# The initializer of a constant calls this function on a value whose type the
# compiler does not know.
scale(x) = 2 * x

# A macro makes its expansion with this function.
expand_answer(value) = :($value + 1)

# A constant holds a value of this type, which a function makes.
struct Theme
    width::Int
end
make_theme() = Theme(1)

# A generated function takes its body from this function.
generated_body(::Type{T}) where {T} = T <: Integer ? :(x + 1) : :(x)

# A loop defines one method for each row of this table.
loop_table() = [(:loop_first, 1)]

# A loop exports each of these names.
exported_names() = [:TABLE]

# Two functions of a constant call this function.
handle(x) = x

# The initializer of a constant calls this function, which gives the next
# number at each call. No edit changes it.
next_number(counter) = (counter[] += 1)
