# A file that the edit takes out of its module: the `include` line leaves, and
# the file leaves the folder. A whole build has nothing of the file.
module RemovedInclude
include("removed_include/kept.jl")
include("removed_include/gone.jl")
shown() = (kept(), isdefined(@__MODULE__, :gone), isdefined(@__MODULE__, :GONE_VALUE))
end
