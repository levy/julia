# residual_error_message — a diagnostic path that formats a rich value.
# EXPECT proven=fail sealed=fail trace=fail   (the routing class, isolated)
#
# WHY. Routing's remaining verifier errors are almost all this shape:
#
#   resolve_network_recordings! / register_network_statistics!
#       -> sprint(show, ::Expr)
#          -> show_unquoted, show_block, print_to_string, print
#   _check_alternatives_agree(Vector{Vector{Symbol}}, String)
#       -> string(::Vector{Symbol}, ::String, ::Vector{Symbol})
#
# An error message that interpolates a container drags Julia's whole display
# machinery into a simulation binary — `show`, `print_to_string`, and the
# `Core.invoke_in_world` builtin the verifier has no rule for.
#
# The path is NEVER TAKEN at run time. It only has to be reachable, which is
# what makes this class hard: the cost is paid for code that never executes.
#
# This example exists so the class can be worked in seconds. Routing takes
# 312 s to report the same thing.
#
# THE TRIGGER IS A CONTAINER, NOT A SCALAR. Measured: interpolating
# `String(names[1])` builds clean in 6 s; interpolating `string(names)` fails.
# A Symbol costs nothing, a Vector{Symbol} pulls `show`, `print_to_string`,
# `escape_raw_string` and the `Core.invoke_in_world` builtin. Routing's case is
# `string(::Vector{Symbol}, ::String, ::Vector{Symbol})` — the same shape.
#
# THE FIX IS VALIDATED, AND IT IS IN THE PROGRAM. Replace the container
# interpolation with parts the compiler can see:
#
#     msg = "the " * what * " names disagree:"
#     for nm in names
#         msg = msg * " " * String(nm)
#     end
#     error(msg)
#
# Measured: 170 errors -> 0, a clean 7 s build. This example deliberately keeps
# the BROKEN form, because it is the probe for the class; the fix belongs in
# whatever program has the defect. Routing's is `sprint(show, ::Expr)` in
# `resolve_network_recordings!` and `register_network_statistics!`.
#
# IT IS A SUPERSET: 170 errors here against routing's 33, because this path
# pulls more of the display machinery than routing's do. Same CLASSES, larger
# count — so fixing this example is necessary for routing, not sufficient.
Base.@noinline function check_names(names::Vector{Symbol}, what::String)::Int
    n = length(names)
    if n > 1000
        # unreachable in practice, but the compiler must still resolve it
        error("the " * what * " names disagree: " * string(names))
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
    Base.print(Core.stdout, "residual_error_message: ", total, "\n")
    return Cint(0)
end
