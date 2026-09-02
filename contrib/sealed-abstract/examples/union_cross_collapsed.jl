# union_cross_collapsed — the cross product closed by `seal_collapse`.
# EXPECT proven=fail sealed=pass trace=pass
# SPLIT-CASES 8
#
# THE THIRD OF THREE, and the one that tests the compiler's construct rather
# than a hand-written workaround. All three are the same program:
#
#   union_cross_product     typed arguments, no help          fail fail pass
#   union_cross_generic     `@nospecialize` written by hand   pass pass pass
#   union_cross_collapsed   `seal_collapse(combine)`          fail pass pass
#
# AND THE DIFFERENCE AT `proven` IS THE POINT. That level runs stock inference
# with the sealed apparatus off, so there is no abstract-to-union map. This
# example still collapses the product — the bits are the program's, not the
# compiler's — but `_weight(a::Signal)` inside the widened body then has no
# union to split and stays dynamic. `union_cross_generic` passes there because
# its `_weight` is an `isa` chain with no dispatch at all.
#
# So `seal_collapse` closes the CROSS PRODUCT and nothing else. Whatever the
# widened body dispatches on still has to be resolvable, by sealing or by the
# body narrowing itself. That is section 46.2, and this row is the measurement
# behind it.
#
# The second says what the answer has to look like; this one says the compiler
# can be told to produce it. They must agree, and if they ever stop agreeing
# the construct has drifted from what it is supposed to mean.
#
# WHY IT IS NOT A COMPILER DECISION. Compiling `combine` at a wide signature
# and registering that instance was tried and produced a binary that dies at
# run time: Julia dispatches on the CONCRETE argument types and never finds the
# widened body, so it falls into a JIT the binary does not contain.
# `seal_collapse` sets `Method.nospecialize`, which is how a method declines to
# specialize at all — and that the program must say, because the compiler can
# not retrofit it onto a signature the program wrote with typed parameters.
#
# THE BODY STILL HAS TO RESOLVE. `combine` now sees `a::Signal` rather than
# `a::S1`, so `_weight(a)` inside it is a call with ONE union-typed argument -
# six cases, well under the budget, and it splits cheaply. That is the whole
# saving: 6 + 6 + 6 instead of 6 x 6 x 6.
abstract type Signal end

struct S1 <: Signal; v::Int end
struct S2 <: Signal; v::Int end
struct S3 <: Signal; v::Int end
struct S4 <: Signal; v::Int end
struct S5 <: Signal; v::Int end
struct S6 <: Signal; v::Int end

_weight(::S1)::Int = 1
_weight(::S2)::Int = 2
_weight(::S3)::Int = 3
_weight(::S4)::Int = 4
_weight(::S5)::Int = 5
_weight(::S6)::Int = 6

# THREE arguments of the same abstract type. One would split into six cases;
# three splits into six cubed.
Base.@noinline function combine(a::Signal, b::Signal, c::Signal)::Int
    return _weight(a) + 10 * _weight(b) + 100 * _weight(c)
end

# THE CONSTRUCT. `combine` is compiled once for every combination of argument
# types instead of once per combination. It sets `Method.nospecialize`, which
# is the only thing that makes a widened body reachable by dispatch.
seal_collapse(combine)

function (@main)(argv::Vector{String})::Cint
    # The index comes from `argv`, so no argument's type is known at compile
    # time and the split can not be folded away.
    n = Base.isempty(argv) ? 1 : Base.length(argv[1])
    signals = Signal[S1(1), S2(2), S3(3), S4(4), S5(5), S6(6)]
    a = signals[Base.mod1(n, 6)]
    b = signals[Base.mod1(n + 1, 6)]
    c = signals[Base.mod1(n + 2, 6)]
    Base.print(Core.stdout, "union_cross_collapsed: ", combine(a, b, c), "\n")
    return Cint(0)
end
