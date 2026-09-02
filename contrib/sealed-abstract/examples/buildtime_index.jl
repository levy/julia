# buildtime_index — build-time work on ORDINARY types, which no filter can see.
# EXPECT proven=pass sealed=pass trace=fail
# EXPECT-FRONTIER proven=pass sealed=pass trace=pass
#
# THE TWO LOOPS DISAGREE HERE, AND THAT IS THE MEASUREMENT. On the seeded loop
# every trace entry is an entrypoint, so this program's 29 entries of
# build-time work are compiled whether or not anything needs them, and the
# build fails. On the frontier loop the trace is evidence a declined site
# consults, no site asks for them, and the build passes at 283 instances
# against 299. This example is how the frontier loop's central claim is
# checked: an over-broad trace costs nothing.
#
# DISTILLED FROM ROUTING. The routing entry declares
#
#     const NED_INDEX = OmnetLegacyRouting.read_routing_type_index()
#
# which parses every `.ned` file AT BUILD TIME. The binary reads the index; it
# never builds one. Measured on the 2026-08-30 build: 2285 of 3026 roots came
# from `NedDocumentModule`, and cutting them from the trace removed 2813 of
# 5316 instances — 53% of the image — and took the error count DOWN from 31 to
# 29. Nothing needed them.
#
# WHY `macro_buildtime` DOES NOT COVER THIS. That example's helper takes an
# `Expr`, and the recorder already drops a signature with an `Expr`, `Module`,
# `Method`, `MethodInstance` or `LineNumberNode` parameter. This helper takes a
# `Vector{String}` and returns an `Int`. Those are the types a run-time
# function has. No shape test can separate it from real work, and on routing
# that filter dropped 55 entries while missing 1405.
#
# THE QUESTION. The recorder's window is `include(PROGRAM)`, which runs the
# whole top level of the program — the build-time phase together with the
# run-time one. Does it register a helper that only ever ran to compute a
# constant?
#
# THE SIGNAL. `_index_fields` calls `fieldnames` on a type it reads out of a
# `Dict`, so the argument is a run-time `DataType`. A trimmed binary can not
# hold that call, and routing's own build reports it as verifier error #21,
# `fieldnames(t::DataType)`. So the example is loud: if the recorder registers
# the helper, the build fails; if it does not, the build passes. At `proven`
# and `sealed` there is no recorder, and `main` can not reach the helper, so
# both levels pass today.
struct Point
    x::Float64
    y::Float64
end

struct Segment
    from::Point
    to::Point
    name::String
end

const _TYPES = Dict{String,Type}("point" => Point, "segment" => Segment)

# Runs ONCE, while this file is included, to compute `FIELD_COUNT`. `main`
# reads the constant and can never call this.
function _index_fields(names::Vector{String})::Int
    total = 0
    for s in names
        t = _TYPES[s]
        total += Base.length(Base.fieldnames(t))
    end
    return total
end

const FIELD_COUNT = _index_fields(["point", "segment"])

function (@main)(argv::Vector{String})::Cint
    Base.print(Core.stdout, "buildtime_index: ", FIELD_COUNT, "\n")
    return Cint(0)
end
