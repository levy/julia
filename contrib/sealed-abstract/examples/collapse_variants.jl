# collapse_variants — one method family, multiplied by a trailing argument.
# EXPECT proven=pass sealed=pass trace=pass
#
# THE NEGATIVE HALF. This program gets no help and compiles 307 instances
# where 280 would do - nine methods become thirty-six because a trailing
# argument it never varies on is specialized four ways. It PASSES: the defect
# is a count, not a wrong answer, which is exactly why it needs a companion.
# `examples/collapse_sealed.jl` is the same program with `seal_collapse`, and
# it carries the bound this one could not meet.
#
# DISTILLED FROM ROUTING. After the build-time entries are cut, routing's
# compile set is 2503 instances and 45.5 s of inference. Of that, the NED
# expression parser holds 76 instances and 41.5 s — 91% of the time — across
# 24 methods. Every method has 4 variants, and the two large ones differ only
# in a trailing argument, after 6255 identical characters of signature.
#
# THE SHAPE. A recursive-descent precedence chain. Each level calls the next
# and carries a context argument it does not read. The context has four types,
# so every level of the chain is compiled four times. Nothing about the four
# copies differs except a type the chain passes through untouched.
#
# WHY THE TRACE CAN NOT CUT THIS. These instances arrive by `static_edge`:
# `main` calls the chain, and `collectinvokes!` follows the IR. They are not
# roots, so no filter on the recorded set reaches them. The compile set is
# correct — it is just four times larger than the program needs.
#
# THE SIGNAL IS A COUNT, NOT A FAILURE. The build succeeds at every level and
# the binary prints the right answer. That is exactly why this example needs
# the instance bound in the EXPECT line: a compiler that compiles four copies
# of everything passes every other test we have.
#
# MEASURED, against a control that calls the same chain with ONE context:
#
#   contexts  chain instances  total  binary
#   1         9                280    1 806 152
#   4         36               307    1 843 824
#
# Nine methods, four contexts, thirty-six instances - the multiplication is
# exact. The bound is 285: below today's 307, and a little above the 280 a
# collapsed build reaches, so one wrapper instance does not read as a failure.
struct Plain end
struct Draw end
struct NoDraw end
struct Trace end

# Every level READS the context. An argument a method never uses is one Julia
# may decline to specialize on, which would collapse the example by accident
# and test nothing. Routing's parser reads its context at every level too.
_bonus(::Plain)::Int = 0
_bonus(::Draw)::Int = 1
_bonus(::NoDraw)::Int = 2
_bonus(::Trace)::Int = 3

Base.@noinline _read_atom(s::String, ctx)::Int = Base.length(s) + _bonus(ctx)
Base.@noinline _read_unary(s::String, ctx)::Int = _read_atom(s, ctx) + 1 + _bonus(ctx)
Base.@noinline _read_power(s::String, ctx)::Int = _read_unary(s, ctx) + 2 + _bonus(ctx)
Base.@noinline _read_product(s::String, ctx)::Int = _read_power(s, ctx) + 3 + _bonus(ctx)
Base.@noinline _read_sum(s::String, ctx)::Int = _read_product(s, ctx) + 4 + _bonus(ctx)
Base.@noinline _read_shift(s::String, ctx)::Int = _read_sum(s, ctx) + 5 + _bonus(ctx)
Base.@noinline _read_compare(s::String, ctx)::Int = _read_shift(s, ctx) + 6 + _bonus(ctx)
Base.@noinline _read_and(s::String, ctx)::Int = _read_compare(s, ctx) + 7 + _bonus(ctx)
Base.@noinline _read_or(s::String, ctx)::Int = _read_and(s, ctx) + 8 + _bonus(ctx)

function (@main)(argv::Vector{String})::Cint
    # THE INPUT MUST COME FROM `argv`. With literal strings the arguments are
    # constant, inference folds the whole chain to its answer, and NOTHING is
    # compiled - the first version of this example emitted zero instances of
    # its own methods and still printed the right number.
    s = Base.isempty(argv) ? "abc" : argv[1]
    # FOUR contexts, one chain. Nine methods become thirty-six instances.
    total = _read_or(s, Plain()) + _read_or(s * "d", Draw()) +
            _read_or(s * "de", NoDraw()) + _read_or(s * "def", Trace())
    Base.print(Core.stdout, "collapse_variants: ", total, "\n")
    return Cint(0)
end
