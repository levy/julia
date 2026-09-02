# abstract_field — a type test whose refinement does not survive the guard.
# EXPECT proven=fail sealed=pass trace=fail
#
# DISTILLED FROM ROUTING PHASE 2. The INI parse fails with twelve errors, all
# of them one call, `_section_chain(MIniFile, String)`, on one statement:
#
#     Base.getproperty(φ ()::IniDocumentModule.IniDocument, :value)::Any
#     OmnetLegacyModel.split(<that>, ','::Char)::Array{SubString{_A}, 1}
#
# The source is `IniConfiguration.jl:178`:
#
#     for entry in section.entries
#         entry isa MIniConfigOption && entry.key == "extends" || continue
#         for parent in split(entry.value, ',')
#
# The `isa` test narrows `entry` inside the `&&`, but the refinement does NOT
# survive the `|| continue` guard, so `entry` is still the abstract
# `IniDocument` at `entry.value`. The field types across the subtypes are not
# uniform, so the read gives `Any`, and `split` on `Any` can not be resolved.
#
# A UNIFORM PHI DOES NOT REPRODUCE IT. The first version of this example
# returned one of two subtypes from a `@noinline` function and read a field
# both of them declare as `String`. It passed at every level: inference proves
# the FIELD TYPE without knowing which subtype, because there is only one
# answer. Two things are needed - the guard idiom, and a field the subtypes do
# not agree on.
#
# WHY A TRACE CAN NOT ANSWER IT. A trace records dispatch TARGETS, which
# method a call reached. `getproperty` on an abstract value is not a dispatch
# the recorder can name, so recording produces no evidence for it. Knowing the
# concrete members of the abstract type does, which is what the sealed
# abstract-as-union map is. The routing pipeline runs with SEALED_SPLIT=0 and
# has therefore turned off the one thing that resolves this.
abstract type Node end

# `value` is a String here and absent there, so the read is not uniform across
# the abstract type - `getproperty` gives `Any`, exactly as routing's does.
struct Tagged <: Node
    key::String
    value::String
end

struct Plain <: Node
    text::String
end

Base.@noinline function _count(nodes::Vector{Node})::Int
    total = 0
    for entry in nodes
        entry isa Tagged && entry.key == "extends" || continue
        total += Base.length(Base.split(entry.value, ','))
    end
    return total
end

function (@main)(argv::Vector{String})::Cint
    nodes = Node[Tagged("extends", "a,b,c"), Plain("x"), Tagged("other", "d")]
    Base.print(Core.stdout, "abstract_field: ", _count(nodes), "\n")
    return Cint(0)
end
