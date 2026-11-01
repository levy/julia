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
PackageCompiler (branch `reactive`) is one client.
"""
module ReactiveCompiler

include("SourceDiff.jl")
include("child.jl")
include("entrypoints.jl")
include("server.jl")

# The code of the harness is compiled into the system image: a server or a
# child pays no compile for it, and the delta of a save holds none of it.
precompile(serve, (String,))
precompile(rc_serve, (String,))
precompile(rc_apply_spec, (String,))
precompile(rc_save, (String,))
precompile(rc_precompile_trace, (String,))
precompile(rc_keep_statements, (String, String))
precompile(trim_entrypoints!, ())

end
