# kw_union_slots — a keyword call whose slots carry a union, behind @noinline.
# EXPECT proven=fail sealed=pass trace=pass
#
# `sealed` PASSES since the repair pass expands NamedTuple slot unions:
# the two unresolved kwcalls become the 4x4 slot product, 32 concrete
# instances, zero SEALED-REPAIR-NOMI. `trace` passes independently — the
# @noinline'd sorter executes in the recording, its concrete kwcall
# instance is recorded, and membership holds. `proven` still fails: stock
# inference leaves nothing at the site the expansion can read.
#
# The second half of the keyword class (`kw_from_dict` is the first): the
# keyword NAMES are static, but the VALUES come out of a
# `Dict{Symbol, Union{...}}`, so the call's NamedTuple type is
# `@NamedTuple{a::Union{...}, b::Union{...}}`. Inference union-splits the
# whole call only while the product is small AND the body inlines; behind
# `@noinline` (the flagship's builder bodies are too big to inline) the site
# stays a `Core.kwcall` over union slots, and the repair pass reports it as
# `SEALED-REPAIR-NOMI` WITHOUT the expansion: `switchtupleunion` splits
# top-level tuple parameters and cannot split a union NESTED inside the
# NamedTuple's slot tuple (concrete or in the where-form's TypeVar bound),
# so no instance is compiled and the call stays unresolved.
#
# Distilled from the 10BASE-T1S phase-3 build:
# `build_ned_module(Type{ActivePacketSource}, ...)` stmt#133, the custom
# builder passing `values[:production_interval]::NedValue` raw as a keyword.
# This example gates that expansion: NamedTuple slot unions enumerated in
# the repair pass, bounded by SEALED_REPAIR_LIMIT like every other product.

const VAL = Union{Bool, Float64, Int64, String}

struct Gadget
    name::Symbol
    rate::Float64
    burst::Int
end
Base.@noinline Gadget(name::Symbol; rate::Float64 = 1.0, burst::Int = 1) =
    Gadget(name, rate, burst)

# The builder is too big for the inliner in the flagship; @noinline stands in
# for that size. The keyword values are the union, raw from the dict.
Base.@noinline function assemble(name::Symbol, values::AbstractDict{Symbol})
    Gadget(name; rate = values[:rate], burst = values[:burst])
end

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
    values = Dict{Symbol, VAL}()
    for assignment in ("rate=2.5", "burst=3")
        key, text = split(assignment, "=")
        values[Symbol(key)] = parse_value(String(text))
    end
    g = assemble(:g, values)
    Base.print(Core.stdout, "kw_union_slots: ", g.rate + g.burst, "\n")
    return Cint(0)
end
