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
include("renamed.jl")
include("untracked.jl")

# Gate M6 tests an edit that arrives during a whole build (finding 39). With
# HAZARD_EDIT_DURING_BUILD=1, the process that writes the image changes
# `reused_const` in shapes.jl when it loads this module, after it read the
# text of before: the image holds that text, and the first rebuild must apply
# the edit.
function __init__()
    if get(ENV, "HAZARD_EDIT_DURING_BUILD", "") == "1" && ccall(:jl_generating_output, Cint, ()) == 1 &&
            Base.JLOptions().incremental == 0
        path = joinpath(@__DIR__, "shapes.jl")
        write(path, replace(read(path, String), "reused_const() = 42" => "reused_const() = 43"))
    end
    return nothing
end

function julia_main()::Cint
    print(report())
    print(changes_report())
    return 0
end

end # module HazardApp
