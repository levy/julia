# dynamic_file — a file read at RUN TIME drives dispatch. The routing shape.
# EXPECT proven=fail sealed=pass trace=pass
#
# This is the ladder's closest approach to the real models: routing parses
# `omnetpp.ini` at run time, so a changed configuration changes dispatch with no
# rebuild. The binary is therefore valid only for inputs that drive the recorded
# dispatch, and a divergent file must FAIL loudly.
#
# It is the example that tests whether the contract is ENFORCED, not stated.
abstract type Handler end
# TEN handlers, not three. With three, inference splits the return union of
# `handler_for` and the dispatch resolves statically - the example built with an
# EMPTY recorded set, testing nothing. The knob must straddle
# `max_union_splitting`.
struct CountHandler <: Handler end
struct SumHandler <: Handler end
struct MaxHandler <: Handler end
struct MinHandler <: Handler end
struct FirstHandler <: Handler end
struct LastHandler <: Handler end
struct RangeHandler <: Handler end
struct EvensHandler <: Handler end
struct OddsHandler <: Handler end
struct SquaresHandler <: Handler end
# Written first with `sum` and `maximum`, this example failed at every level on
# `Base.reduce_empty(op::Function, T::Type)` - the empty-collection error path
# of `reduce`, dispatched on an untyped `op`. It was testing `reduce`'s
# diagnostics, not file-driven dispatch. Explicit loops keep the mechanism in
# view.
Base.@noinline handle(::CountHandler, xs::Vector{Int})::Int = length(xs)
Base.@noinline function handle(::SumHandler, xs::Vector{Int})::Int
    t = 0
    for x in xs; t += x; end
    t
end
Base.@noinline function handle(::MaxHandler, xs::Vector{Int})::Int
    m = typemin(Int)
    for x in xs; x > m && (m = x); end
    m
end
Base.@noinline handle(::MinHandler, xs::Vector{Int})::Int =
    (m = typemax(Int); for x in xs; x < m && (m = x); end; m)
Base.@noinline handle(::FirstHandler, xs::Vector{Int})::Int = xs[1]
Base.@noinline handle(::LastHandler, xs::Vector{Int})::Int = xs[length(xs)]
Base.@noinline handle(::RangeHandler, xs::Vector{Int})::Int =
    (lo = typemax(Int); hi = typemin(Int); for x in xs; x < lo && (lo = x); x > hi && (hi = x); end; hi - lo)
Base.@noinline handle(::EvensHandler, xs::Vector{Int})::Int =
    (t = 0; for x in xs; iseven(x) && (t += x); end; t)
Base.@noinline handle(::OddsHandler, xs::Vector{Int})::Int =
    (t = 0; for x in xs; isodd(x) && (t += x); end; t)
Base.@noinline handle(::SquaresHandler, xs::Vector{Int})::Int =
    (t = 0; for x in xs; t += x * x; end; t)

# The table is built behind a `@noinline` boundary and indexed with a value
# derived from the file, so inference can not forward a concrete type into the
# dispatch. Three earlier shapes all resolved statically and recorded an EMPTY
# set: a declared `::Handler` return (inference splits the branch union), a
# direct call, and an assignment read back in the same block.
Base.@noinline function handler_table()::Vector{Handler}
    t = Vector{Handler}(undef, 10)
    t[1] = CountHandler();  t[2] = SumHandler();     t[3] = MaxHandler()
    t[4] = MinHandler();    t[5] = FirstHandler();   t[6] = LastHandler()
    t[7] = RangeHandler();  t[8] = EvensHandler();   t[9] = OddsHandler()
    t[10] = SquaresHandler()
    return t
end

Base.@noinline function index_for(name::AbstractString)::Int
    name == "sum" && return 2
    name == "max" && return 3
    name == "min" && return 4
    name == "first" && return 5
    name == "last" && return 6
    name == "range" && return 7
    name == "evens" && return 8
    name == "odds" && return 9
    name == "squares" && return 10
    return 1
end

function (@main)(argv::Vector{String})::Cint
    # the configuration is READ, not compiled in
    text = isempty(argv) ? "count" : (isfile(argv[1]) ? strip(read(argv[1], String)) : argv[1])
    table = handler_table()
    total = handle(table[index_for(text)], Int[3, 1, 4, 1, 5])
    Base.print(Core.stdout, "dynamic_file: ", total, "\n")
    return Cint(0)
end
