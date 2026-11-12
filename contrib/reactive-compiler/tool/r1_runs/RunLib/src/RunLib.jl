# The library of the gate of the code that an expression runs
# (tool/gate_runs.sh). helpers.jl holds the functions that the gate edits.
# users.jl holds the expressions that run them: the text of users.jl stays as
# it is, and a whole build of the edit gives each of its expressions another
# result. statements.jl holds statements that fill a list and a table; the gate
# changes one and removes one. lines.jl holds a function that names its own
# line; the gate moves it. markers.jl holds a type whose values the program
# keeps in the storage of its task; the gate changes the type in a second edit.
# It holds a macro that defines two types and an alias too: the second type has
# a field of the type that the gate changes, and users.jl names it.
# moved.jl holds what an edit removes or moves: a function and a struct that go
# to another module, a struct, a constant, a module that gets another name, and two
# functions that change places between the module that defines one and the
# module that imports it by its name. order.jl holds the use of a macro that
# reads a definition that comes after it; the gate changes a struct that the
# use names, and the rebuild must refuse to evaluate the use again.
module RunLib
include("helpers.jl")
include("markers.jl")
include("users.jl")
include("statements.jl")
include("lines.jl")
include("moved.jl")
include("order.jl")
end
