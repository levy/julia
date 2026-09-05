# method_table_domain — a declined split costs nothing when the callee is known.
# EXPECT proven=fail sealed=pass trace=pass
# SPLIT-CASES 12
#
# WRITTEN TO FAIL, AND IT PASSED. The question was whether the sealed compiler
# should derive an argument's domain from the callee's method table: a sealed
# world fixes the method table by the same argument it fixes the subtypes, so a
# value no method declares can not reach a method body. The answer measured
# here is that the compiler already has that bound, from ordinary method
# matching, and a separate derivation adds nothing to this shape.
#
# WHAT THE SITE DOES. `step(Op, Arg, Int)`: the substitution widens `Op` to 2
# members and `Arg` to 12, so the splitter prices the site at 24 against a
# budget of 12 and DECLINES it — `SEALED-SPLIT budget=12 worst-site=24
# sites-over-budget=7`. The build still verifies at 0 errors, and the item dump
# holds exactly the six instances the program can reach:
#
#     Tuple{var"#step", Plus,  A1, Int64}  ...  Tuple{var"#step", Times, A3, Int64}
#
# `find_method_matches` enumerated the six methods of `step` and compiled those.
# The method table bounded the call without the splitter, so the decline was
# free. A derivation placed before the pricing loop would have made the split
# succeed and produced the same six instances by a longer road.
#
# WHERE A HAND-WRITTEN DOMAIN IS STILL NEEDED, and why it is not this. Two
# shapes defeat the matcher, and neither is helped by reading the method table:
#
#   - A single generic method over an abstract type declares that abstract
#     type, so the union IS the type and nothing narrows. `_to_fields(::Type{T},
#     c::Chunk, ...)` in the T1S packet model is that shape.
#   - An UNTYPED method declares `Any`. `deliver_message!(ctx, message, gate)`
#     was that shape, and its domain was stated by hand in routing's seal file.
#     Writing `gate::Gate` retired that promise: the seal file's own derivation
#     loop then read it off the method, the binary shrank by 68 464 bytes, and
#     the network hash did not move. A `MethodError` checks a declaration in an
#     ordinary run; nothing checks a promise.
#
# See `dynamic_callee_domain` for the same measurement with a union callee,
# which is the case one would expect the matcher to lose.

abstract type Op end
struct Plus <: Op end
struct Times <: Op end

abstract type Arg end

# The three the method table declares.
struct A1 <: Arg; v::Int end
struct A2 <: Arg; v::Int end
struct A3 <: Arg; v::Int end

# Nine more subtypes that `step` has NO method for. They are what makes the
# substitution price the site at 24 and the method table price it at 6. A real
# program grows these by loading a library: `Chunk` has 716 concrete subtypes
# and the T1S receive path reads one of them.
struct B1 <: Arg; v::Int end
struct B2 <: Arg; v::Int end
struct B3 <: Arg; v::Int end
struct B4 <: Arg; v::Int end
struct B5 <: Arg; v::Int end
struct B6 <: Arg; v::Int end
struct B7 <: Arg; v::Int end
struct B8 <: Arg; v::Int end
struct B9 <: Arg; v::Int end

Base.@noinline step(::Plus,  a::A1, acc::Int)::Int = acc + a.v
Base.@noinline step(::Plus,  a::A2, acc::Int)::Int = acc + a.v * 2
Base.@noinline step(::Plus,  a::A3, acc::Int)::Int = acc + a.v * 3
Base.@noinline step(::Times, a::A1, acc::Int)::Int = acc * a.v
Base.@noinline step(::Times, a::A2, acc::Int)::Int = acc * (a.v + 1)
Base.@noinline step(::Times, a::A3, acc::Int)::Int = acc * (a.v + 2)

function (@main)(argv::Vector{String})::Cint
    # The containers carry the ABSTRACT element type, so the loop hands `step`
    # an `Op` and an `Arg` and the site is priced on those.
    ops = Op[Plus(), Times()]
    args = Arg[A1(2), A2(3), A3(4)]
    acc = 1
    for op in ops
        for a in args
            acc = step(op, a, acc)
        end
    end
    Base.print(Core.stdout, "method_table_domain: ", acc, "\n")
    return Cint(0)
end
