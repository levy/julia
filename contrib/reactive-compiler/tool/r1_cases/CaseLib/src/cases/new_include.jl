# A file that the edit adds, with its `include` line. A whole build loads the
# new file after the old one.
module NewInclude
include("new_include/old.jl")
shown() = (old(), isdefined(@__MODULE__, :added))
end
