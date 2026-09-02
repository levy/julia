# macro_buildtime — a macro helper that runs at EXPANSION time and must not be
# in the binary.
# EXPECT proven=pass sealed=pass trace=pass
#
# DISTILLED FROM ROUTING. Its build compiles `_parse_path(Expr)`,
# `_emit_builder(Expr)` and `_simulation_module(Expr, Module)` — macro
# machinery — and with them the display code that formats an `Expr` for an
# error message. 1941 of 2018 recorded entries, 96%, mention `Expr` or
# `Module`.
#
# The question this example asks: does the RECORDER register a macro helper
# merely because including the program ran it? Everything a macro touches gets
# compiled during the include, and the recorder watches exactly that window.
#
# If `_shape_of` appears in the compiled set, the recorder is registering
# build-time work as a run-time dispatch target. If it does not, routing's
# `Expr` machinery is reachable for a different reason, and this example says
# so by passing.
_shape_of(ex::Expr)::Symbol = ex.head

macro describe(ex)
    # runs at EXPANSION time; `_shape_of` is called HERE, never at run time
    shape = _shape_of(ex)
    n = shape === :call ? 100 : shape === :vect ? 200 : 300
    return :($n)
end

Base.@noinline function shape_score()::Int
    a = @describe f(1, 2)      # :call  -> 100
    b = @describe [1, 2, 3]    # :vect  -> 200
    c = @describe (1 + 2)      # :call  -> 100
    return a + b + c
end

function (@main)(argv::Vector{String})::Cint
    Base.print(Core.stdout, "macro_buildtime: ", shape_score(), "\n")
    return Cint(0)
end
