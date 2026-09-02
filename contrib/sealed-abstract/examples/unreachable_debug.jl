# unreachable_debug — a cold path whose closure is the whole type universe.
# EXPECT proven=fail sealed=fail trace=fail
#        (NOT IMPLEMENTED: `seal_residual` does not exist. Plan 47.3.)
#
# MEASURED: 272 errors, and the NOISE IS THE CLOSURE. Showing arbitrary values
# pulls Base's whole display stack with it - LazyString, AnnotatedString,
# `fieldname` reflection. That is what closing one uncloseable printer costs,
# and it is why the answer is a terminal rather than a bigger budget.
#
# DISTILLED FROM ROUTING PHASE 3. Its last error is the generic document
# printer, whose body is
#
#     for f in fieldnames(typeof(x))
#         show(inner, getproperty(x, f))
#     end
#
# `getproperty(x, f)` over `fieldnames` is `Any`, so `show(::IO, ::Any)` is
# every type reachable through a document's fields. Measured on routing: 158
# concrete Documents, and 6306 distinct types the printer faces at its own
# depth limit of 3 - against a phase-3 image of 1694 instances in total.
#
# The domain is FINITE, so a closed dispatch table could be built (plan 47.1).
# It would cost four times the whole program, for a debug aid that the run
# path never executes. That is what `seal_unreachable` is for.
abstract type Item end

struct Alpha <: Item
    n::Int
    tag::Symbol
end

struct Beta <: Item
    n::Int
    inner::Alpha
end

# THE UNCLOSEABLE BODY. It shows whatever the fields happen to hold, so its
# target set is the closure of every field type - the same shape as the
# document printer.
function _debug(io::IO, v::Item)
    for f in fieldnames(typeof(v))
        Base.show(io, Base.getproperty(v, f))
    end
    return nothing
end

# A COLD PATH. Reachable in the graph, never taken by the run. It does NOT
# throw: `error` with an interpolated string drags LazyString and
# AnnotatedString machinery and buries the one failure this example is about -
# the first version produced 272 errors, most of them nothing to do with it.
Base.@noinline function _reject(v::Item)::Int
    local buf = Base.IOBuffer()
    _debug(buf, v)
    return Base.length(Base.take!(buf))
end

function (@main)(argv::Vector{String})::Cint
    n = Base.isempty(argv) ? 1 : Base.length(argv[1])
    v = n > 100 ? Beta(n, Alpha(n, :b)) : Alpha(n, :a)
    # The guard is never true for any argument this binary is given, but the
    # compiler must still close `_reject` unless the program says otherwise.
    n < 0 && Base.print(Core.stdout, _reject(v))
    Base.print(Core.stdout, "unreachable_debug: ", n, "\n")
    return Cint(0)
end
