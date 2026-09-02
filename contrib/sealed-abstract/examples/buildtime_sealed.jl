# buildtime_sealed — the same program as `buildtime_index`, with the hint.
# EXPECT proven=pass sealed=pass trace=pass
#
# THE POSITIVE HALF OF THE PAIR. `buildtime_index.jl` is the same program with
# no hint, and it declares `trace=fail`: the recorder registers
# `_index_fields(Array{String, 1})` as a run-time root and the build fails on
# the `Dict{String,Type}` machinery behind it. Every line here is that file's,
# except that the work is marked:
#
#     const FIELD_COUNT = @seal_buildtime _index_fields(["point", "segment"])
#
# The two examples differ by that one mark and nothing else, so a pass here and a
# fail there measures the hint alone.
#
# The value is still baked. `main` prints 5 either way — three fields on
# `Segment`, two on `Point`. What the hint removes is the WORK, which the
# binary can never call.
struct Point
    x::Float64
    y::Float64
end

struct Segment
    from::Point
    to::Point
    name::String
end

# EVERY build-time statement needs its own mark. Building this Dict is
# build-time work too, and leaving it unmarked left five errors on
# `setproperty!(Dict{String,Type}, ...)` - the rehash path - after the first
# mark had already removed `_index_fields`.
const _TYPES = @seal_buildtime Dict{String,Type}("point" => Point, "segment" => Segment)

# `fieldnames` on a type read out of a Dict is a call a trimmed binary can not
# hold. Routing reports the same one as its own verifier error #21.
function _index_fields(names::Vector{String})::Int
    total = 0
    for s in names
        t = _TYPES[s]
        total += Base.length(Base.fieldnames(t))
    end
    return total
end

const FIELD_COUNT = @seal_buildtime _index_fields(["point", "segment"])

function (@main)(argv::Vector{String})::Cint
    Base.print(Core.stdout, "buildtime_sealed: ", FIELD_COUNT, "\n")
    return Cint(0)
end
