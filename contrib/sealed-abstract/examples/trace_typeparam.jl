# trace_typeparam — dispatch on `Type{T}`, chosen at run time.
# EXPECT proven=fail sealed=fail trace=pass
#
# The STRONGEST test on the ladder: the only example where a trace is strictly
# necessary, because sealing can not resolve a `Type{T}` dispatch.
#
# GUARDS A REAL DEFECT. The dispatch type is `Type{T1}`, but `typeof(T1)` is
# `DataType`. A recorder that writes `typeof(arg)` loses the dispatch entirely
# and the build has no entry for `kind_of(::Type{T1})` — measured, twice, as a
# build that fails on exactly this call.
abstract type Node end
struct T1 <: Node; v::Int; end
struct T2 <: Node; v::Int; end
struct T3 <: Node; v::Int; end
struct T4 <: Node; v::Int; end
struct T5 <: Node; v::Int; end
kind_of(::Type{T1})::Int = 10
kind_of(::Type{T2})::Int = 20
kind_of(::Type{T3})::Int = 30
kind_of(::Type{T4})::Int = 40
kind_of(::Type{T5})::Int = 50

function (@main)(argv::Vector{String})::Cint
    nodes = Vector{Node}(undef, 5)
    nodes[1] = T1(1); nodes[2] = T2(2); nodes[3] = T3(3)
    nodes[4] = T4(4); nodes[5] = T5(5)
    total = 0
    for i in 1:5
        # the dispatch is on Type{Ti}; `typeof` here would say DataType
        total += kind_of(typeof(nodes[i]))::Int
    end
    Base.print(Core.stdout, "trace_typeparam: ", total, "\n")
    return Cint(0)
end
