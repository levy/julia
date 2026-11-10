# The library of the gate of the code that an expression runs
# (tool/gate_runs.sh). helpers.jl holds the functions that the gate edits.
# users.jl holds the expressions that run them: the text of users.jl stays as
# it is, and a whole build of the edit gives each of its expressions another
# result. statements.jl holds statements that fill a list and a table; the gate
# changes one and removes one.
module RunLib
include("helpers.jl")
include("users.jl")
include("statements.jl")
end
