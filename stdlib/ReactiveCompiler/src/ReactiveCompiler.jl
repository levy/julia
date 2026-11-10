# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
    ReactiveCompiler

The harness of the reactive compiler (`contrib/reactive-compiler` of this
tree): the ledger and the classifier of the tracked sources of a store, the
apply of an edit, the precompile of the store's trace, the save of an image
by a forked child, and the compiler server that `julia --reactive-server=<socket>`
runs. It is in the system image, so every image a store builds holds it, and
a server or a rebuild child starts on that image without an include. The
protocol of the server is the interface: `apply <spec.toml>`, `save <archive>`,
`trim <archive> [dir]`, `status` and `quit`, one line each way over a Unix
socket, the reply `ok ...`, `refused <file>` or `error <message>`.
PackageCompiler (branch `reactive`) is one client. It also builds the patch of
a package file (`write_package_patch`), which `Base.compilecache` asks for
when the sources of a package changed, and records the top-level reads of a
package at its whole compile (`record_top_level_reads`).
"""
module ReactiveCompiler

"""
    rc_harness_print(dir) -> String

The print of the sources of a harness in the folder `dir`: one hash of its `.jl`
files, each with its name. A client compares the print of the harness in the
image of a store ([`HARNESS_PRINT`](@ref)) with the print of the sources that it
has, and loads the sources when the two differ.
"""
function rc_harness_print(dir::AbstractString)
    print = zero(UInt)
    for name in sort!(filter(endswith(".jl"), readdir(dir)))
        print = hash(read(joinpath(dir, name), String), hash(name, print))
    end
    return string(print; base = 16)
end

"""
    HARNESS_PRINT

The print of the sources that this module was made from ([`rc_harness_print`](@ref)).
"""
const HARNESS_PRINT = rc_harness_print(@__DIR__)

include("SourceDiff.jl")
include("child.jl")
include("replay.jl")
include("patch.jl")
include("entrypoints.jl")
include("server.jl")

# The code of the harness is compiled into the system image: a server or a
# child pays no compile for it, and the delta of a save holds none of it.
precompile(serve, (String,))
precompile(rc_serve, (String,))
precompile(rc_apply_spec, (String,))
precompile(rc_replay!, (RcEvaluation, String))
precompile(rc_trial!, (IOBuffer, RcEvaluation, Vector{RcCandidate}))
precompile(rc_print, (RcPrinter, Any))
precompile(rc_moved_difference, (RcMoved, RcEvaluation, Vector{String}))
precompile(rc_save, (String,))
precompile(rc_precompile_trace, (String,))
precompile(rc_keep_statements, (String, String))
precompile(trim_entrypoints!, ())
precompile(write_package_patch, (Base.PkgId, String, Int, Vector{Core.CodeInstance}))
precompile(record_top_level_reads, (Module,))

end
