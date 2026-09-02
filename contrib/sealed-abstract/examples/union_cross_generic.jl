# union_cross_generic — the same cross product, compiled through the fallback.
# EXPECT proven=pass sealed=pass trace=pass
# SPLIT-CASES 8
#
# THE POSITIVE HALF OF THE PAIR. `union_cross_product.jl` is the same program
# with one difference: its `combine` takes typed arguments, so when the split
# budget forces a fallback the call goes dynamic and NOTHING answers it —
# `Main.combine(...)` is left unresolved and the build fails. Here `combine`
# declines to specialize, so exactly one widened body exists and the dynamic
# call has a target.
#
#     union_cross_product   combine(a::Signal, b::Signal, c::Signal)   fails
#     union_cross_generic   combine(@nospecialize(a), ...)             passes
#
# The two files differ by that signature and nothing else, so a pass here and a
# fail there measures the fallback alone.
#
# WHY THIS IS THE `:generic` ARM BY HAND. The lattice says a call that can not
# be proven, traced, declared, sealed or usefully split should be answered by a
# generic signature that covers the domain. `@nospecialize` is that, written by
# the program instead of chosen by the compiler: one body for every argument
# type, boxed. When the compiler grows the arm, this example is what says it
# works — and `union_cross_product` is what says it was needed.
#
# THE COST IS A BRANCH, AND THAT IS THE POINT. `combine` is compiled ONCE
# instead of 216 times, and the six-way choice becomes an `isa` chain inside
# it rather than a dispatch the compiler has to close.
abstract type Signal end

struct S1 <: Signal; v::Int end
struct S2 <: Signal; v::Int end
struct S3 <: Signal; v::Int end
struct S4 <: Signal; v::Int end
struct S5 <: Signal; v::Int end
struct S6 <: Signal; v::Int end

# THE GENERIC BODY MUST NARROW ITS OWN ARGUMENTS. A first version dispatched
# `_weight` on the six concrete types and failed with fourteen errors: the
# widened `combine(Any, Any, Any)` compiled, but every `_weight(::Any)` inside
# it was a dynamic call with six matches and nothing supplied them. Widening
# one body only moves the dispatch down a level unless the body resolves it.
#
# An `isa` chain is one method, one body, and every branch concrete - so there
# is no dispatch left to answer.
_weight(x)::Int =
    x isa S1 ? 1 :
    x isa S2 ? 2 :
    x isa S3 ? 3 :
    x isa S4 ? 4 :
    x isa S5 ? 5 : 6

# ONE BODY FOR EVERY COMBINATION. `@nospecialize` is what stops Julia making a
# specialization per argument type, so the cross product never exists.
Base.@noinline function combine(@nospecialize(a), @nospecialize(b),
                                @nospecialize(c))::Int
    return _weight(a) + 10 * _weight(b) + 100 * _weight(c)
end

function (@main)(argv::Vector{String})::Cint
    n = Base.isempty(argv) ? 1 : Base.length(argv[1])
    signals = Signal[S1(1), S2(2), S3(3), S4(4), S5(5), S6(6)]
    a = signals[Base.mod1(n, 6)]
    b = signals[Base.mod1(n + 1, 6)]
    c = signals[Base.mod1(n + 2, 6)]
    Base.print(Core.stdout, "union_cross_generic: ", combine(a, b, c), "\n")
    return Cint(0)
end
