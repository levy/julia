# The test application of the gates: every call shape across the reuse
# boundary and a redefined `@ccallable` method in `shapes.jl`, one change of
# every category of the catalog in `changes.jl`. The gates copy the `-after`
# files of the tool directory over the tracked files between the founding
# build and the rebuild. `untracked.jl` is included and never tracked: it
# holds the dependent of a refusal case.
module HazardApp

using Libdl

include("shapes.jl")
include("changes.jl")
include("renamed2.jl")
include("untracked.jl")
include("extra.jl")

function julia_main()::Cint
    print(report())
    print(changes_report())
    return 0
end

end # module HazardApp
