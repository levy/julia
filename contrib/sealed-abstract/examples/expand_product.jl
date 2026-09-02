# expand_product — several union-typed arguments, so the site costs the PRODUCT.
# EXPECT proven=fail sealed=pass trace=pass
#
# A call site costs the product of its argument union sizes. Here 5 x 5 = 25
# combinations exist and the program executes 5. Lazy splitting must beat full
# expansion; a compiler that enumerates eagerly compiles 25 where 5 run.
#
# Measured shape in features.jl: `apply` compiled 64 signatures over an
# 8-member union where the program executed 8.
const Value = Union{Int64, Float64, Bool, Char, UInt8}
Base.@noinline scalar(x::Int64)::Int   = x
Base.@noinline scalar(x::Float64)::Int = Int(round(x))
Base.@noinline scalar(x::Bool)::Int    = x ? 1 : 0
Base.@noinline scalar(x::Char)::Int    = Int(x) % 97
Base.@noinline scalar(x::UInt8)::Int   = Int(x)
Base.@noinline combine(a::Value, b::Value)::Int = scalar(a) + scalar(b)
Base.@noinline function pick(i::Int)::Value
    m = i % 5
    m == 0 && return i
    m == 1 && return Float64(i)
    m == 2 && return isodd(i)
    m == 3 && return 'a'
    return UInt8(i % 256)
end

function (@main)(argv::Vector{String})::Cint
    seed = length(argv) + 1
    total = 0
    for i in seed:(seed + 4)
        total += combine(pick(i), pick(i))     # the SAME index: 5 pairs, not 25
    end
    Base.print(Core.stdout, "expand_product: ", total, "\n")
    return Cint(0)
end
