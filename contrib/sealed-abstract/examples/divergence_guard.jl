# divergence_guard — the binary is run OUTSIDE what the trace recorded.
# EXPECT proven=fail sealed=fail trace=fail
#
# MEASURED, AND THE ANSWER IS BETTER THAN THE CONTRACT PROMISED. A trace
# recorded on the default input covers T1..T3 and omits T4..T6. The build then
# FAILS - it will not produce a binary that could diverge - naming the
# unresolved dispatch:
#
#     unresolved call ... Main.kind_of(Main.typeof(...))
#
# So under a closed policy a run-time divergence is not merely loud, it is
# UNREACHABLE: the verifier sees the uncovered path in the code and refuses,
# whether or not any input reaches it. Section 1's "abort naming the signature"
# is the fallback for a policy that admits unresolved dispatch, not the normal
# case.
#
# THE COST IS THE OTHER SIDE OF THAT BARGAIN. A binary can only be built for a
# trace covering every REACHABLE path, not merely every path taken. Recording
# one input is not enough when the code holds branches for others - which is
# what trace merging (section 37) is for.
#
# THE NEGATIVE TEST FOR THE CONTRACT. Section 1 says a dispatch reaching no
# compiled target must abort naming the signature, never guess — and with no
# compiler in the image there is nothing to fall back on. Nothing had ever
# checked that.
#
# The dispatch is on `Type{T}`, which is the one shape sealing can not resolve
# (see trace_typeparam), so what gets compiled is decided by the trace alone.
# The argument selects WHICH types are touched, so a trace recorded on one
# input genuinely omits the others.
abstract type Node end
struct T1 <: Node; v::Int; end
struct T2 <: Node; v::Int; end
struct T3 <: Node; v::Int; end
struct T4 <: Node; v::Int; end
struct T5 <: Node; v::Int; end
struct T6 <: Node; v::Int; end
kind_of(::Type{T1})::Int = 10
kind_of(::Type{T2})::Int = 20
kind_of(::Type{T3})::Int = 30
kind_of(::Type{T4})::Int = 40
kind_of(::Type{T5})::Int = 50
kind_of(::Type{T6})::Int = 60

Base.@noinline function nodes_for(which::Int)::Vector{Node}
    out = Vector{Node}(undef, 3)
    if which == 2
        out[1] = T4(4); out[2] = T5(5); out[3] = T6(6)
    else
        out[1] = T1(1); out[2] = T2(2); out[3] = T3(3)
    end
    return out
end

function (@main)(argv::Vector{String})::Cint
    which = isempty(argv) ? 1 : 2
    ns = nodes_for(which)
    total = 0
    for i in 1:3
        total += kind_of(typeof(ns[i]))::Int
    end
    Base.print(Core.stdout, "divergence_guard: ", total, "\n")
    return Cint(0)
end
