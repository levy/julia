# interpret_residual — a specialization the trim never compiled runs in the
# interpreter, instead of killing the binary at startup.
# EXPECT proven=fail sealed=WRONG trace=fail
#
# THE SHAPE IS THE ONE THE ROUTING BINARY DIED OF, TWICE. `apply_mode` has one
# method. The direct call compiles the `(Fast, Int)` specialization, so the
# method stays in the trimmed table. The loop calls the same method through a
# `Vector{Any}`, so `(Fast, Float64)` is a specialization nothing compiled — and
# the verifier's check is per METHOD (any instance counts), so the build passes
# at 0 errors. At run time `jl_apply_generic` finds the method, finds no code,
# asks for inference, and there is no Compiler in the image.
#
# MEASURED (plan/pending/seal-to-interpreter.md, Stage 0). The `proven` and
# `trace` levels REFUSE this program; the `sealed` level verifies it at 0
# errors and the binary dies at startup. So `sealed=WRONG`: this example pins a
# soundness hole in the sealed verifier — it accepts a call when ANY instance
# of the matched method exists, and dispatch then asks for one it does not
# have — not a feature. With
# SEALED_INTERPRET=1 the image keeps `Method.source`, `_main` sets
# `compile_enabled = MIN`, and the runtime goes PAST inference into the
# interpreter — which executes this body and dies one call later, on
# `getproperty(Base, :round)`: the lowered body reaches `Base.round` through a
# dynamic call, and trim dropped that method. The interpreter works; what it
# calls must also be in the table. That is Stage 1.
abstract type Mode end
struct Fast <: Mode end
Base.@noinline apply_mode(::Fast, x::Real)::Int = Base.round(Int, x * 2)

function (@main)(argv::Vector{String})::Cint
    # `inferencebarrier` keeps the argument a run-time Int: without it constant
    # propagation folds the call to 40, no `(Fast, Int)` instance exists, and
    # trim drops the METHOD — a MethodError, not the crash under test.
    total = apply_mode(Fast(), Base.inferencebarrier(20)::Int)   # compiled: (Fast, Int)
    values = Any[1, 2.5, 3]                 # decided at run time, on purpose
    for v in values
        total += apply_mode(Fast(), v)      # (Fast, Float64) has no compiled code
    end
    Base.print(Core.stdout, "interpret_residual: ", total, "\n")
    return Cint(0)
end
