# RECORD what a program's run compiles, in a SEPARATE process.
#
#     julia record_trace.jl <program.jl> <out.jls> [main-args...]
#
# The recorder must not be in the build. Recording inside the build process put
# the snapshot machinery's own instances into the delta and then into the
# binary; a separate process cannot do that, because its instances are created
# after the delta is taken and in a different session entirely.
#
# Signature TYPES are serialized, not printed: parsing `Tuple{...}` back out of
# text needs the right module context and is fragile for Base internals.
using Serialization
# The program defines `@main`, so Julia's `_start` would run it AGAIN at exit
# with this script's own argv. The recording is already done by then; the extra
# run only produces a confusing error.
Core.eval(Base, :(should_use_main_entrypoint() = false))

const PROGRAM = ARGS[1]
const OUT     = ARGS[2]
const MAINARG = length(ARGS) >= 3 ? String[ARGS[3]] : String[]

function snapshot()
    s = Base.IdSet{Any}()
    Base.visit(Core.methodtable) do method
        method isa Core.Method || return
        for mi in Base.specializations(method)
            mi isa Core.MethodInstance && push!(s, mi)
        end
    end
    s
end
snapshot()                       # warm, so the baseline is clean
const BEFORE = snapshot()
println(stderr, "baseline: ", length(BEFORE), " instances")

Base.include(Main, abspath(PROGRAM))
Base.invokelatest(getglobal(Main, :main), MAINARG)

const sigs = Any[]
const skipped = Ref(0)
for mi in snapshot()
    (mi in BEFORE) && continue
    mi isa Core.MethodInstance || continue
    Base.isdispatchtuple(mi.specTypes) || continue
    # A GENSYM'd name does not survive the trip between processes: keyword
    # bodies (`##format_value#2`) and closures are numbered per session, so
    # deserialization looks up a name that means something else, or nothing.
    # They are reached by closure from the wrapper that owns them, so dropping
    # them here loses nothing.
    occursin("#", string(mi.specTypes)) && (skipped[] += 1; continue)
    push!(sigs, mi.specTypes)
end
serialize(OUT, sigs)
println(stderr, "recorded ", length(sigs), " signatures (", skipped[],
        " gensym-named skipped) -> ", OUT)
