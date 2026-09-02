# trace_stem — a `@nospecialize` method compiled at its own abstract signature.
# EXPECT proven=pass sealed=pass trace=pass
#
# MEASURED: it passes at every level, and that is correct - there is one method,
# so nothing dispatches. Its assertion is not "proven must fail" but "the TRACE
# must not break it": the recorder writes `address(::S3)`, the concrete type it
# ran on, while the compiler emits `address(::Node)`, the stem. If the two are
# not normalized the trace-driven build chases a signature that does not exist.
# `trace=ok` is the whole test.
#
# GUARDS THE OPPOSITE DEFECT to trace_typeparam. One body serves every layout,
# so the compiler emits `address(::Node)` — the STEM — while a trace records the
# CONCRETE type it ran on, `address(::T3)`. The two must be normalized, or the
# build chases a signature that does not exist. Measured: `node_address(T1)`
# appeared as executed-but-not-compiled for exactly this reason.
abstract type Node end
struct S1 <: Node; v::Int; end
struct S2 <: Node; v::Int; end
struct S3 <: Node; v::Int; end
struct S4 <: Node; v::Int; end
struct S5 <: Node; v::Int; end
struct S6 <: Node; v::Int; end
Base.@noinline address(@nospecialize(x::Node))::Int = getfield(x, 1)::Int

function (@main)(argv::Vector{String})::Cint
    nodes = Vector{Node}(undef, 6)
    nodes[1] = S1(1); nodes[2] = S2(2); nodes[3] = S3(3)
    nodes[4] = S4(4); nodes[5] = S5(5); nodes[6] = S6(6)
    total = 0
    for i in 1:6
        total += address(nodes[i])
    end
    Base.print(Core.stdout, "trace_stem: ", total, "\n")
    return Cint(0)
end
