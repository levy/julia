# kw_from_dict — keyword construction from a runtime dict of union-typed values.
# EXPECT proven=fail sealed=fail trace=fail
# TRACE-ROOTS Main
#
# THE C++-INET PARAMETER SHAPE, distilled from the 10BASE-T1S phase-3 build
# (inet-julia, 16 errors, seeded and frontier agreeing). A configuration
# answers a `Dict{Symbol, V}` where `V` is a small union; a registry maps
# type names to Julia types; and a builder makes each module:
#
#   - a CUSTOM method per type passes dict values as KEYWORDS, so the
#     keyword tuple carries union-typed slots;
#   - the FALLBACK splats the dict — `T(name; values...)` — so the call goes
#     through `Core.kwcall` with a NamedTuple no inference can name.
#
# The Type-valued dispatch of the builder is closed the way the flagship
# closes it, with an argument promise over the registry — so what remains is
# exactly the keyword class: the kw sorter over union-valued NamedTuples,
# and the Core-owned kwcall stem of the splat, which no evidence arm
# answers.
#
# TWO MEASURED NUANCES, both part of the finding:
#
#   - WITHOUT `TRACE-ROOTS`, the trace level PASSES: unfiltered trace roots
#     compile the recorded kw bodies and membership holds. The flagship
#     filters its evidence through the configured roots (`sealed_keep` drops
#     Core-owned kw instances), so its trace still fails — the class is a
#     FILTERED-evidence gap, and the declaration here turns the filter on to
#     reproduce it.
#   - The sealed level fails as the class PLUS its blast radius: the
#     fallback's generic stem carries `(f::Any)(x::Any)`, whose match set is
#     every function the image knows, so the count explodes (59 errors per
#     round, 819 in the last). The flagship's roots contain the blast; the
#     verdict, not the count, is this example's assertion.

const VAL = Union{Bool, Float64, Int64, String}

struct Source
    name::Symbol
    interval::Float64
    offset::Float64
    label::String
end
Source(name::Symbol; interval::Float64 = 1.0, offset::Float64 = -1.0,
       label::String = "s") = Source(name, interval, offset, label)

struct Queue
    name::Symbol
    capacity::Int
    drop::Bool
end
Queue(name::Symbol; capacity::Int = 10, drop::Bool = false) =
    Queue(name, capacity, drop)

struct Sink
    name::Symbol
    limit::Int
    tag::String
end
Sink(name::Symbol; limit::Int = 0, tag::String = "t") = Sink(name, limit, tag)

# The registry: what the builder's first position can hold, and nothing else.
const REGISTRY = Dict{String, Any}("source" => Source, "queue" => Queue,
                                   "sink" => Sink)

# The custom methods pass dict values RAW, as the flagship's glue does — the
# keyword slots are then the union, not a concrete type.
build(::Type{Source}, name::Symbol, values::AbstractDict{Symbol}) =
    Source(name; interval = values[:interval], offset = values[:offset])
build(::Type{Queue}, name::Symbol, values::AbstractDict{Symbol}) =
    Queue(name; capacity = Int(values[:capacity]), drop = values[:drop])
# The fallback: one field per key, splatted. `Sink` takes this path.
build(T::Type, name::Symbol, values::AbstractDict{Symbol}) = T(name; values...)

# The builder's first position is the registry's own domain — the same
# derived claim the flagship states. This keeps the Type-dispatch class out,
# so a failure here is the keyword class and nothing else.
seal_argument(build, 1, Union{Type{Source}, Type{Queue}, Type{Sink}})

# A tiny configuration parser, so every value is RUNTIME data with the
# union's type, the way an INI answers.
function parse_value(text::String)::VAL
    text == "true" && return true
    text == "false" && return false
    i = tryparse(Int64, text)
    i === nothing || return i
    f = tryparse(Float64, text)
    f === nothing || return f
    return text
end

function (@main)(argv::Vector{String})::Cint
    lines = ["source a interval=2.5 offset=0.5",
             "queue  b capacity=3 drop=true",
             "sink   c limit=7 tag=x"]
    total = 0.0
    for line in lines
        parts = split(line)
        values = Dict{Symbol, VAL}()
        for assignment in parts[3:end]
            key, text = split(assignment, "=")
            values[Symbol(key)] = parse_value(String(text))
        end
        m = build(REGISTRY[String(parts[1])], Symbol(parts[2]), values)
        total += m isa Source ? m.interval + m.offset :
                 m isa Queue ? Float64(m.capacity) : Float64(m.limit)
    end
    Base.print(Core.stdout, "kw_from_dict: ", total, "\n")
    return Cint(0)
end
