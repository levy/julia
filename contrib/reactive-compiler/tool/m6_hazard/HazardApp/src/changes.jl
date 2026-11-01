# One change of every category of the catalog
# (plan/pending/robust-incremental-compiler.md). The founding build compiles
# every definition here. `changes-after.jl` holds the edited text, with one
# edit per category, and `changes-reformat.jl` the same text with other
# whitespace and comments. `changes_report()` prints one `change:` line per
# case, with the value that the edit changes.

# A3: the removal of the special method; the dispatch falls to the general one
special(x::Int) = 1
special(x) = 0

# A4: a new signature of the same name
resig(x::Int) = x

# A6: a callable struct and a generated function
struct Scaler
    k::Int
end
(s::Scaler)(x) = s.k * x
@generated gen_times(x::Int) = :(2 * x)

# B2: a struct that gains a field, and its three dependents: a method that
# takes it, a constant of it, and a struct that holds it
struct Box
    w::Int
end
area_of(b::Box) = b.w * b.w
const UNIT_BOX = Box(1)
struct Crate
    box::Box
end
crate_size(c::Crate) = area_of(c.box)

# B3: an abstract type that moves to another supertype, with a subtype
abstract type Kind1 end
abstract type Kind2 end
abstract type Middle <: Kind1 end
struct Item <: Middle end
label(::Kind1) = :one
label(::Kind2) = :two

# C1: a constant
const FACTOR = 2
factor() = FACTOR

# C2: a global
global tally = 10
tally_value() = tally

# C3: a `using` that the edit adds resolves the name of a dependent
module Words
export word
word() = :exported
end
guess_word() = isdefined(@__MODULE__, :word) ? word() : :unbound

# D1: a macro, a macro that expands it, and a method that expands that one
macro twice(e)
    return :(2 * $e)
end
macro quad(e)
    return :(@twice(@twice($e)))
end
quad_one() = @quad 1

# D2: an `@eval` loop; the edit changes one of its methods, and the caller
# of the other one keeps its code
for (name, k) in ((:times2, 2), (:times3, 3))
    @eval $name(x) = $k * x
end
use_times2() = times2(5)
use_times3() = times3(5)

# E1: a file read at the top level
const NOTE = read(joinpath(@__DIR__, "data.txt"), String)
note_len() = length(NOTE)

# The type of a refusal case: `untracked.jl` defines a method on it
struct Corner
    k::Int
end

function changes_report()
    io = IOBuffer()
    for (name, value) in [
            ("special", special(1)),
            ("resig", resig(1)),
            ("scaler", Scaler(2)(3)),
            ("gen", gen_times(4)),
            ("box", area_of(Box(3))),
            ("unit", area_of(UNIT_BOX)),
            ("crate", crate_size(Crate(Box(4)))),
            ("label", label(Item())),
            ("factor", factor()),
            ("tally", tally_value()),
            ("word", guess_word()),
            ("quad", quad_one()),
            ("times2", use_times2()),
            ("times3", use_times3()),
            ("note", note_len()),
            ("renamed", renamed_value()),
            ("corner", corner_of(Corner(7))),
        ]
        println(io, "change: ", name, " = ", value)
    end
    return String(take!(io))
end
