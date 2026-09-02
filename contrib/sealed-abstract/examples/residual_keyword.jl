# residual_keyword — a keyword-argument body, hence a gensym'd `##f#N`.
# EXPECT proven=pass sealed=pass trace=pass
#
# The body function is numbered PER SESSION, so its name means nothing in
# another process. A trace must never try to name it; it has to be reached by
# CLOSURE from the wrapper. Measured: 4977 routing signatures were dropped
# crossing a process boundary for exactly this reason.
Base.@noinline function padded(v::Int; width::Int = 4, pad::Char = '0')::String
    s = string(v)
    while length(s) < width
        s = pad * s
    end
    return s
end

function (@main)(argv::Vector{String})::Cint
    n = length(padded(7; width = 6)) + length(padded(42; width = 3, pad = ' '))
    Base.print(Core.stdout, "residual_keyword: ", n, "\n")
    return Cint(0)
end
