# Two files whose `include` lines the edit swaps (H4). The constant of the
# first file calls a function that the second file gives a method; a whole
# build after the edit loads the method first.
module OrderIncludeSwapped
pick(x) = 1
include("order_include_swapped/method.jl")
include("order_include_swapped/user.jl")
shown() = PICKED
end
