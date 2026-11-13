# A file whose `include` line the edit moves from one module to another. A
# whole build defines the function of the file in the second module only.
module MovedInclude
module First
include("moved_include/part.jl")
end
module Second
end
shown() = (isdefined(First, :part), isdefined(Second, :part))
end
