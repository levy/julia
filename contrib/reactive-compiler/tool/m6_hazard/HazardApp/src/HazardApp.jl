# The M6 test application: every call shape across the reuse boundary, and a
# redefined `@ccallable` method. `shapes.jl` is the tracked file; the gate
# copies `shapes-after.jl` over it between the founding build and the rebuild.
module HazardApp

using Libdl

include("shapes.jl")

function julia_main()::Cint
    print(report())
    return 0
end

end # module HazardApp
