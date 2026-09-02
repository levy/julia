# union_cross_product — several union-typed arguments at one call.
# EXPECT proven=fail sealed=fail trace=pass
# SPLIT-CASES 8
#          (NOT IMPLEMENTED: the fallback has nowhere to land. `:generic` is
#           still a stub, so a site that falls back leaves a dynamic call
#           nothing answers. `trace=pass` because a recorded target does.)
#
# DISTILLED FROM ROUTING PHASE 3. Building the network takes the compiler past
# fifteen minutes and it was killed without finishing. Capping the splitter to
# Julia's own default ends it:
#
#   SEALED_SPLIT_LIMIT=20000   > 900 s, killed, never reached the compile loop
#   SEALED_SPLIT_LIMIT=4       125 s, 1652 instances, one error
#
# THE SHAPE. In a sealed world an abstract type IS the union of its concrete
# subtypes, and the union splitter enumerates the cases so each resolves
# concretely. With ONE union-typed argument that is what makes the dispatch
# static and costs nothing. With THREE it is a cross product: six subtypes at
# three positions is 216 specializations of one method, and routing's network
# carries a union of sixteen module types.
#
# WHAT THE TEST ASSERTS. The example is built with `SEALED_SPLIT_CASES 8`, far
# below its own 216, so the budget is certain to be exceeded and the compiler
# MUST fall back: the site keeps its abstract argument types, the call stays
# dynamic, and something further down the lattice answers it. Passing means the
# fallback produced a correct binary. Failing means the compiler either
# enumerated anyway or left a call nothing could resolve.
#
# MEASURED TODAY: `budget=8 worst-site=36 taken=6 sites-over-budget=5`. The
# budget works - five sites fell back and nothing wider than six was ever
# enumerated - and the build then FAILS, because falling back is only half of
# the lattice. The other half is `:generic`: the method has to be compiled at
# its own widened signature so the dynamic call has a target. That arm is a
# stub, and this example is what will say when it is not.
#
# It costs 7 seconds. The same question asked of routing phase 3 costs six
# minutes and answers with a timeout.
#
# WHY NOT AN INSTANCE BOUND. The blowup does not fail - it
# succeeds, slowly. An instance bound can not see it either: the splitter
# INLINES each case into the caller, so a build of this example reports 272
# instances and zero for `combine` whether the product is 1 or 216. Only the
# compiler's own counter shows it, and it reads `worst-site=216` here.
#
# The example stays small on purpose - six members at three positions is quick
# enough to run on every ladder pass. Routing's network union has sixteen.
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

function (@main)(argv::Vector{String})::Cint
    # The index comes from `argv`, so no argument's type is known at compile
    # time and the split can not be folded away.
    n = Base.isempty(argv) ? 1 : Base.length(argv[1])
    signals = Signal[S1(1), S2(2), S3(3), S4(4), S5(5), S6(6)]
    a = signals[Base.mod1(n, 6)]
    b = signals[Base.mod1(n + 1, 6)]
    c = signals[Base.mod1(n + 2, 6)]
    Base.print(Core.stdout, "union_cross_product: ", combine(a, b, c), "\n")
    return Cint(0)
end
