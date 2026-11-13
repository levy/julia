# Two files that a loop includes by a path that it computes. The edit changes
# the text of one file and no other text. A build that does not read the path
# of the file must stop: the file is an input that it can not apply.
module ComputedInclude
for name in ("one", "two")
    include(joinpath("computed_include", name * ".jl"))
end
shown() = (one(), two())
end
