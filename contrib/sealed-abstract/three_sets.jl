# Three sets of method signatures for the same program, in one normalized form
# so they can be compared directly.
#
#     julia three_sets.jl <traced-program.jl> <out-dir>
#
#   set1  what STOCK Julia's compiler specialized while the program ran
#         (walked out of the method table after the run)
#   set2  what the program ITSELF reports executing (its own trace lines)
#   set3  what the TRIMMING compiler compiled (the build's item dump)
#
# Ideally all three agree. Where they do not:
#   set3 \ set1   the trim compiled something the program never needs
#   set1 \ set2   the compiler specialized something that never ran
#   set2 \ set1   a method ran without a specialization — a dynamic path
#
# set1 and set2 come from ONE stock run, so they describe the same execution.
# The trace is stock-only by design: a tag helper dispatching on an abstract
# type is itself a declined split, and it took the traced trim build to 16
# errors while the untraced one built clean.

const PROGRAM = ARGS[1]
const OUTDIR = length(ARGS) >= 2 ? ARGS[2] : "work-regress"

# The normal form: `name(ArgType, ArgType)`, dropping the function object that
# `specTypes` carries in position 1.
function normal_form(name, specTypes)
    ps = try
        collect(specTypes.parameters)[2:end]
    catch
        return nothing
    end
    string(name, "(", join(ps, ", "), ")")
end

# Everything the method table holds for a module, after the run.
function specialized_in(mod::Module)
    out = String[]
    for nm in names(mod; all = true)
        isdefined(mod, nm) || continue
        f = try getglobal(mod, nm) catch; continue end
        (f isa Function) || continue
        for m in methods(f)
            m.module === mod || continue
            for mi in Base.specializations(m)
                mi isa Core.MethodInstance || continue
                s = normal_form(m.name, mi.specTypes)
                s === nothing || push!(out, s)
            end
        end
    end
    out
end

# Run the program. Including it runs the warm phase, exactly as a build does;
# then `main` runs the entry. Both are part of what the program needs.
Base.include(Main, abspath(PROGRAM))
Base.invokelatest(getglobal(Main, :main), String[])

set1 = sort(unique(specialized_in(Main)))
open(joinpath(OUTDIR, "set1_stock_compiled.txt"), "w") do io
    for s in set1; println(io, s); end
end
println(stderr, "set1 (stock compiler specializations in Main): ", length(set1))
