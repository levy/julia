# residual_sealed — the same cold path, closed over what covers it.
# EXPECT proven=fail sealed=pass trace=pass
#
# `proven` fails and that is the shape of the construct, not a defect in it.
# That level runs stock inference with the sealed apparatus off, and the
# narrowing lives inside it - the same row `collapse_sealed` and
# `union_cross_collapsed` show. A promise is part of the sealed world.
#
# THE POSITIVE HALF of `unreachable_debug.jl`, which is this program without
# the promise and fails with 272 errors. The two differ by one line.
#
# `_debug` shows whatever a field holds, so its domain is every type reachable
# from an `Item` - and showing an arbitrary value pulls Base's whole display
# stack, LazyString and AnnotatedString with it. That is what 272 errors are.
#
# `seal_residual` narrows the argument at the sites calling `show` FROM WITHIN
# `_debug` to the types the program says arrive there. The scope is not a
# refinement, it is what makes the promise sound: narrowing every call to
# `Base.show` anywhere broke the build session's own error printing before the
# program was compiled at all. The splitter then enumerates four
# instead of a universe, and the residual is not compiled because, as far as
# inference can see, it can not occur. That IS the promise, and a checked build
# is what falsifies it.
#
# THE SOURCE IS EXPLICIT. `from` is a list here rather than `:trace`, because a
# build whose compiled set depends on which run produced a recording is one
# nobody can reproduce from the source alone.
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

# THE PROMISE. The debug printer shows whatever a field holds, and its domain
# is every type reachable from an `Item`. The program says which types actually
# arrive there: two `Int` fields, a `Symbol`, and an `Alpha`. Everything else
# is residual and is never closed.
seal_residual(_debug, Base.show; from = [Int, Symbol, Alpha])

function (@main)(argv::Vector{String})::Cint
    n = Base.isempty(argv) ? 1 : Base.length(argv[1])
    v = n > 100 ? Beta(n, Alpha(n, :b)) : Alpha(n, :a)
    # The guard is never true for any argument this binary is given, but the
    # compiler must still close `_reject` unless the program says otherwise.
    n < 0 && Base.print(Core.stdout, _reject(v))
    Base.print(Core.stdout, "residual_sealed: ", n, "\n")
    return Cint(0)
end
