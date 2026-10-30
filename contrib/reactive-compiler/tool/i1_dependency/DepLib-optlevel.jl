# The dependency of the I1 gate: a path package that the application loads.
# One file through a path constant, one in a submodule.
module DepLib
Base.Experimental.@optlevel 1

const _PARTS = joinpath(@__DIR__, "parts")
include(joinpath(_PARTS, "leaf.jl"))

module Inner
include("inner.jl")
end

end
