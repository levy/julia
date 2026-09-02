# prove_chain — a static call chain, no dispatch at all.
# EXPECT proven=pass sealed=pass trace=pass
#
# The floor of the ladder. Inference resolves every call, so `CodeInstance.edges`
# holds the complete graph and the recorded set D must be EMPTY. If D is not
# empty here, the recorder is inventing work.
Base.@noinline h(x::Int)::Int = x - 3
Base.@noinline g(x::Int)::Int = h(x) * 2
Base.@noinline f(x::Int)::Int = g(x) + 1

function (@main)(argv::Vector{String})::Cint
    total = 0
    for i in 1:4
        total += f(i)
    end
    Base.print(Core.stdout, "prove_chain: ", total, "\n")
    return Cint(0)
end
