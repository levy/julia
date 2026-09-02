# residual_splat — a varargs call through `_apply_iterate`.
# EXPECT proven=fail sealed=fail trace=fail   (generic=pass, NOT IMPLEMENTED)
#
# MEASURED: fails at all three levels, which is correct and is the point. No
# evidence can name a splat's callee. It stays failing until the generic
# fallback exists, and it is the example that will prove that feature works.
#
# THERE IS NO TARGET TO NAME. `a + b + c + d` parses as ONE n-ary `+`, which
# lowers to a splat through `Core._apply_iterate`. No trace entry can supply a
# splat, because there is no single callee. Only a residual generic signature
# can close it — or the build must say so clearly.
#
# This is 16 of routing's 28 unresolved statements.
# The arity must be UNKNOWN at compile time. A tuple of known length is
# resolved and the splat disappears - measured: the first version of this
# example produced zero `_apply_iterate` mentions and passed at `proven`,
# testing nothing.
Base.@noinline pieces(n::Int)::Vector{Int} = Int[n + i for i in 0:(n % 3 + 2)]

function (@main)(argv::Vector{String})::Cint
    p = pieces(length(argv) + 1)
    # a splat of a RUN-TIME length collection: no single callee exists
    total = +(p...)
    Base.print(Core.stdout, "residual_splat: ", total, "\n")
    return Cint(0)
end
