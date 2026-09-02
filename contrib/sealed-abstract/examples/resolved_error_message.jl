# resolved_error_message — the POSITIVE twin of residual_error_message.
# EXPECT proven=pass sealed=pass trace=pass
#
# Same diagnostic path, same never-taken error branch, same routing class
# (`show`, `print_to_string`, `escape_raw_string`, `Core.invoke_in_world` —
# 19 of routing's 33 errors). The only difference is that the message is built
# from parts the compiler can SEE, instead of handing a container to `string`.
#
# Measured on the negative twin: 170 errors -> 0.
#
# WHAT MAKES IT COMPILE IS THE PROGRAM, NOT A TRACE OR A SEAL. That is worth
# being exact about: no trace can help here, because the path never runs, and no
# seal exists yet that bounds a display closure. This class is closed by writing
# the code so the compiler can see through it — section 0's cheap half.
Base.@noinline function check_names(names::Vector{Symbol}, what::String)::Int
    n = length(names)
    if n > 1000
        msg = "the " * what * " names disagree:"
        for nm in names
            msg = msg * " " * String(nm)
        end
        error(msg)
    end
    return n
end

Base.@noinline function build_names(seed::Int)::Vector{Symbol}
    out = Vector{Symbol}(undef, 3)
    out[1] = :alpha; out[2] = :beta; out[3] = :gamma
    return out
end

function (@main)(argv::Vector{String})::Cint
    total = check_names(build_names(length(argv)), "alternative")
    Base.print(Core.stdout, "resolved_error_message: ", total, "\n")
    return Cint(0)
end
