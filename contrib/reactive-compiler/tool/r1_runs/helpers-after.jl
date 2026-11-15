# The functions that the expressions of users.jl run, after the edit of the
# gate: each function gives another result, and the type has one more field.

# The initializer of a constant calls this function.
make_table() = Dict(:answer => 2)

# The initializer of a constant calls this function on a value whose type the
# compiler does not know.
scale(x) = 3 * x

# A macro makes its expansion with this function.
expand_answer(value) = :($value + 2)

# A constant holds a value of this type, which a function makes.
struct Theme
    width::Int
    height::Int
end
make_theme() = Theme(2, 5)

# A generated function takes its body from this function.
generated_body(::Type{T}) where {T} = T <: Integer ? :(x + 2) : :(x)

# A loop defines one method for each row of this table.
loop_table() = [(:loop_first, 2), (:loop_second, 3)]

# A loop exports each of these names.
exported_names() = [:TABLE, :SCALED]

# The initializer of a constant calls this function, which reads a file. No
# edit changes it.
read_motto() = strip(read(joinpath(@__DIR__, "motto.txt"), String))

# The program reaches these three functions with no static call of a source
# that the edit leaves as it is: a finalizer, a callback of C, and a call
# through a value of an unknown type.
release(parcel) = (RELEASED[] += 2 * parcel.weight; nothing)
scale_in_c(x::Cint)::Cint = Cint(3) * x
shout(x::Int) = x + 20

# A small function, and its one caller. The caller now calls the small
# function through a value of an unknown type, so the call needs compiled code
# of the small function.
tiny(x::Int) = x + 1
whisper(x::Int) = Base.inferencebarrier(tiny)(x)

# Two functions of a constant call this function.
handle(x) = 2 * x

# The initializer of a constant calls this function, which gives the next
# number at each call. No edit changes it.
next_number(counter) = (counter[] += 1)

# A statement calls this function, which writes into a list that the statement
# does not name. No edit changes it.
const NOTES = Symbol[]
remember(note) = push!(NOTES, note)

# A macro makes its expansion with this function: two methods, which carry the
# lines of this quote. The edit changes the first method only.
function accessor_code(name)
    return quote
        $(esc(Symbol(name, :_first)))() = 2
        $(esc(Symbol(name, :_second)))() = 10
    end
end

# A macro makes its expansion with this function: one method, which carries a
# line of this quote. The edit changes the function and not the expansion.
function steady_code(name)
    name isa Symbol || error("a name is needed")
    return quote
        $(esc(name))() = 7
    end
end
