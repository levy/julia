# Build from a recorded trace. NOTHING ELSE.
#
# This file is the program's top level, so whatever it contains is part of what
# the trim compiles. `entry_from_edges.jl` carries the recorder — snapshots, the
# edge walk, the fixpoint — and merely ADDING that machinery to the entry took a
# clean build to two verifier errors, with the trace byte-identical. The
# recorder must therefore never be in the file that builds.
#
#   SEALED_TRACE_PROGRAM   the program to compile (default: the feature example)
#   SEALED_TRACE_IN        the trace to register
import Serialization

const PROGRAM = Base.get(Base.ENV, "SEALED_TRACE_PROGRAM",
                         Base.joinpath(@__DIR__, "work-regress", "f_plain.jl"))
include(PROGRAM)

# ROOTS OR EVIDENCE, and the loop decides which.
#
#   seeded     every entry becomes an entrypoint, compiled whether or not any
#              call site needs it
#   frontier   every entry goes into `SEALED_TRACE_SIGS`, and a declined
#              dispatch site consults it. An entry no site demands is never
#              compiled, so an over-broad trace costs nothing.
let path = Base.get(Base.ENV, "SEALED_TRACE_IN", ""), n = 0, skipped = 0
    Base.isempty(path) && Base.error("SEALED_TRACE_IN is not set")
    frontier = Base.get(Base.ENV, "SEALED_LOOP", "seeded") == "frontier"
    for t in Serialization.deserialize(path)
        try
            if frontier
                # THE VENDORED COMPILER, NOT `Base.Compiler`. Julia's builtin
                # one also has `add_entrypoint`, so the seeded path worked
                # against the wrong module and never said so; the frontier path
                # threw on every entry and reported "0 signatures as evidence,
                # 10 skipped". The buildscript binds the vendored package as
                # `Compiler`, and it is the one holding the sealed state.
                Main.Compiler.sealed_add_trace_sig!(t)
            else
                Main.Compiler.add_entrypoint(t)
            end
            n += 1
        catch err
            skipped += 1
            skipped == 1 && Core.println("TRACE-BUILD first skip: ", err)
        end
    end
    Core.println("TRACE-BUILD: ", n, frontier ? " signatures as evidence, " :
                 " entrypoints registered, ", skipped, " skipped")
end
