# trace_abstract — an abstract argument whose subtypes exceed the split limit.
# EXPECT proven=fail sealed=pass trace=pass
#
# Above `max_union_splitting` inference leaves the call dynamic and records NO
# edge, so the static graph misses every target. Only observation supplies them.
# This is the mechanism the whole trace-seeded design exists for.
abstract type Node end
struct T1 <: Node; v::Int; end
Base.@noinline step(x::T1)::Int = x.v + 1
struct T2 <: Node; v::Int; end
Base.@noinline step(x::T2)::Int = x.v + 2
struct T3 <: Node; v::Int; end
Base.@noinline step(x::T3)::Int = x.v + 3
struct T4 <: Node; v::Int; end
Base.@noinline step(x::T4)::Int = x.v + 4
struct T5 <: Node; v::Int; end
Base.@noinline step(x::T5)::Int = x.v + 5
struct T6 <: Node; v::Int; end
Base.@noinline step(x::T6)::Int = x.v + 6
struct T7 <: Node; v::Int; end
Base.@noinline step(x::T7)::Int = x.v + 7
struct T8 <: Node; v::Int; end
Base.@noinline step(x::T8)::Int = x.v + 8
struct T9 <: Node; v::Int; end
Base.@noinline step(x::T9)::Int = x.v + 9
struct T10 <: Node; v::Int; end
Base.@noinline step(x::T10)::Int = x.v + 10
Base.@noinline site(x::Node)::Int = step(x)

function (@main)(argv::Vector{String})::Cint
    nodes = Vector{Node}(undef, 10)
    nodes[1] = T1(1)
    nodes[2] = T2(2)
    nodes[3] = T3(3)
    nodes[4] = T4(4)
    nodes[5] = T5(5)
    nodes[6] = T6(6)
    nodes[7] = T7(7)
    nodes[8] = T8(8)
    nodes[9] = T9(9)
    nodes[10] = T10(10)
    total = 0
    for i in 1:10
        total += site(nodes[i])
    end
    Base.print(Core.stdout, "trace_abstract: ", total, "\n")
    return Cint(0)
end
