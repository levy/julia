# prove_split — a UNION below max_union_splitting, written as a union.
# EXPECT proven=pass sealed=pass trace=pass
#
# The control for the edge-walk boundary. Stock inference splits a 2-member
# union and records an edge for BOTH targets, so the graph is complete and the
# recorded set D is empty.
#
# IT MUST BE A UNION, NOT AN ABSTRACT TYPE. Written first as `Vector{Shape}`
# with `Shape` abstract, this example failed at `proven` — inference cannot know
# an abstract type's subtypes without the sealed split, so it was testing
# `sealed`, not `proven`. That is the failure mode this ladder exists to catch:
# an example that does not test its own mechanism.
struct Dot; v::Int; end
struct Bar; v::Int; end
const Shape = Union{Dot, Bar}
Base.@noinline area(s::Dot)::Int = s.v
Base.@noinline area(s::Bar)::Int = s.v * 2
Base.@noinline measure(s::Shape)::Int = area(s)

function (@main)(argv::Vector{String})::Cint
    shapes = Vector{Shape}(undef, 2)
    shapes[1] = Dot(3)
    shapes[2] = Bar(5)
    total = 0
    for i in 1:2
        total += measure(shapes[i])
    end
    Base.print(Core.stdout, "prove_split: ", total, "\n")
    return Cint(0)
end
