# Record what a real routing run actually compiles, as TEXT, so it can be
# compared against what the trimming compiler derives.
#
#     JULIA_LOAD_PATH=... julia routing_sigs.jl <entry.jl> <out.txt> [seconds]
#
# This is set 1 of the three-set comparison, for a program too large to hand
# trace: instead of the program reporting itself, the COMPILER is asked what it
# specialized while the program ran. Including the entry runs its warm phase,
# and `main` then runs the simulation, so the recorded set covers both — the
# same two phases a build sees.
#
# Only the model's own packages are recorded. Core and Base are excluded for
# the same reason the buildscript excludes them: their subtypes are open, and
# the trim reaches their code statically from the entrypoints anyway.

const ENTRY   = ARGS[1]
const OUT     = ARGS[2]
const SECONDS = length(ARGS) >= 3 ? ARGS[3] : "1.0"

rootmod(m::Module) = (r = m; while parentmodule(r) !== r; r = parentmodule(r); end; r)
model_owned(m::Module) = (r = rootmod(m); r !== Core && r !== Base)

t0 = time_ns()
Base.include(Main, abspath(ENTRY))
println(stderr, "include (warm phase): ", round((time_ns() - t0) / 1e9, digits = 2), "s")

t1 = time_ns()
Base.invokelatest(getglobal(Main, :main), String[SECONDS])
println(stderr, "main (", SECONDS, "s of simulation): ",
        round((time_ns() - t1) / 1e9, digits = 2), "s")

# Walk the method table once and record every specialization the run produced.
const sigs = String[]
const nmeth = Ref(0)
Base.visit(Core.methodtable) do method
    method isa Core.Method || return
    model_owned(method.module) || return
    nmeth[] += 1
    for mi in Base.specializations(method)
        mi isa Core.MethodInstance || continue
        push!(sigs, string(mi.specTypes))
    end
end
sort!(sigs)
unique!(sigs)
open(OUT, "w") do io
    for s in sigs; println(io, s); end
end
println(stderr, "recorded ", length(sigs), " distinct signatures across ",
        nmeth[], " model-owned methods -> ", OUT)
