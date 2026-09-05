# The test application of the gates: every call shape across the reuse
# boundary and a redefined `@ccallable` method in `shapes.jl`, one change of
# every category of the catalog in `changes.jl`. The gates copy the `-after`
# files of the tool directory over the tracked files between the founding
# build and the rebuild. `untracked.jl` is included and never tracked: it
# holds the dependent of a refusal case.
module HazardApp

using Libdl
Base.Experimental.@optlevel 1

include("shapes.jl")
include("changes.jl")
include("renamed.jl")
include("untracked.jl")

function julia_main()::Cint
    print(report())
    print(changes_report())
    return 0
end

end # module HazardApp
