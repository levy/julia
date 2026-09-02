# resolved_splat — the POSITIVE twin of residual_splat.
# EXPECT proven=pass sealed=pass trace=pass
#
# The same sum over a run-time length collection, without the splat. A fold has
# one callee per step, so every call names a target; `+(v...)` has none, because
# the callee is a family indexed by argument count.
#
# WHAT MAKES IT COMPILE IS THE PROGRAM. There is no trace or seal that closes
# the negative twin today: `seal_arity` (plan section 45) is the construct that
# would, and it does not exist. So this pair marks the ONE class where the
# compiler still has no answer of its own, and the positive is a rewrite rather
# than evidence.
Base.@noinline pieces(n::Int)::Vector{Int} = Int[n + i for i in 0:(n % 3 + 2)]

function (@main)(argv::Vector{String})::Cint
    p = pieces(length(argv) + 1)
    total = 0
    for x in p
        total += x
    end
    Base.print(Core.stdout, "resolved_splat: ", total, "\n")
    return Cint(0)
end
