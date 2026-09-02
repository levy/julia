# WHICH METHODS DID THE RUN EXECUTE?
#
# Run the program here, under an ORDINARY julia with `--code-coverage=user`.
# Every method that runs marks its own lines, and `entry_from_edges.jl` reads
# those marks to drop the trace entries that inference merely SPECIALIZED.
#
# THIS CAN NOT BE DONE INSIDE THE BUILD. The juliac child reports
# `JLOptions().code_coverage` as set, because the flag is forwarded, and writes
# no coverage data at all: it generates an object file rather than running
# ordinary code. Measured on `trace_abstract`: the parent wrote
# `juliac.jl.<pid>.cov`, the child wrote nothing, and the filter kept all 10
# entries and read as a pass.
#
#   julia +1.13 --startup-file=no --code-coverage=user record_coverage.jl
#
#     SEALED_TRACE_PROGRAM   the program to run, the same one the recorder uses
#     SEALED_TRACE_PACKAGES  loaded first, exactly as the recorder loads them
#
# It prints its pid. Give that to the recorder as SEALED_TRACE_COVPID.
#
# NO SEALED COMPILER HERE, and none is wanted. The program computes the same
# thing under any compiler, so the set of methods it executes is the same. The
# hints are the identity outside the recorder, which is what `seal_hints.jl`
# exists to guarantee.
include(joinpath(@__DIR__, "seal_hints.jl"))
using .SealHints

for _pkg in split(get(ENV, "SEALED_TRACE_PACKAGES", ""), ",")
    isempty(_pkg) && continue
    Core.eval(Main, Meta.parse("import " * _pkg))
end

# THE RUN MUST BE THE RUN THE BINARY WILL PERFORM. `main` takes arguments, and
# what it does with them decides which code executes: the flagship records
# result files only when it is GIVEN a result directory. Run it with no
# arguments and the executed-only filter drops every line of the recorder,
# because nothing executed it.
const SEAL_ARGS = String[a for a in split(get(ENV, "SEALED_TRACE_ARGS", ""), ' ')
                        if !isempty(a)]

const PROGRAM = get(ENV, "SEALED_TRACE_PROGRAM", "")
isempty(PROGRAM) && error("set SEALED_TRACE_PROGRAM to the program to run")
include(PROGRAM)

# RUN IT ONCE. `@main` also makes Julia call `main` on the way out, so without
# this the program runs TWICE - once here and once at exit. Clearing the marker
# the entry point tests leaves this call as the only run.
if isdefined(Main, Symbol("#__main_is_entrypoint__#"))
    Core.eval(Main, :(var"#__main_is_entrypoint__#" = false))
end
Base.invokelatest(getglobal(Main, :main), SEAL_ARGS)

# WRITE THE COUNTERS OUT. Without this call the data stays in memory and the
# process exits with nothing on disk.
ccall(:jl_write_coverage_data, Cvoid, (Ptr{UInt8},), C_NULL)
println("COVERAGE-PID ", getpid())
