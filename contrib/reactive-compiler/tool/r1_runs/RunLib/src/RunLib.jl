# The library of the gate of the code that an expression runs
# (tool/gate_runs.sh). helpers.jl holds the functions that the gate edits.
# users.jl holds the expressions that run them: the text of users.jl stays as
# it is, and a whole build of the edit gives each of its expressions another
# result. statements.jl holds statements that fill a list and a table; the gate
# changes one and removes one. lines.jl holds a function that names its own
# line; the gate moves it. markers.jl holds a type whose values the program
# keeps in the storage of its task; the gate changes the type in a second edit.
# moved.jl holds what an edit removes or moves: a function that goes to another
# module, a struct, a constant, and a module that gets another name.
module RunLib
include("helpers.jl")
include("markers.jl")
include("users.jl")
include("statements.jl")
include("lines.jl")
include("moved.jl")
end
