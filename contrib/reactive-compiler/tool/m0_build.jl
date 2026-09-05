# M0, the build child.
#
# Load the routing model and run one scenario. The process is started with
# `--output-o`, so at exit Julia emits the object archive of the whole image:
# Base, the standard library, the simulator and the model. This is what the
# `create_sysimg_object_file` phase of PackageCompiler does.
#
# Run it from the omnet-julia checkout, in the build lane. The base sysimage
# must be named: with `--output-o` and no `--sysimage`, Julia starts from
# `boot.jl` and needs the source tree.
#   JULIA_IMAGE_THREADS=8 julia --project=package/OmnetLegacyRoutingExample \
#       --startup-file=no --pkgimages=no --sysimage=<lib/julia/sys.so> \
#       -C native --output-o out.a <this file>

# With `--output-o`, Julia leaves Sys.BINDIR, Sys.STDLIB, LOAD_PATH and
# DEPOT_PATH unset, and `--project` is not applied. PackageCompiler fills them
# in its child the same way: the project, the standard library, the default
# depot.
@eval Sys BINDIR = ccall(:jl_get_julia_bindir, Any, ())::String
@eval Sys STDLIB = abspath(Sys.BINDIR, "..", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)")
copy!(LOAD_PATH, [abspath(get(ENV, "RC_PROJECT", "package/OmnetLegacyRoutingExample")), "@stdlib"])
Base.init_depot_path()

using OmnetLegacyRoutingExample
using OmnetSimulator
println("m0_build: loaded from ", pathof(OmnetLegacyRoutingExample))
# RC_LOAD_ONLY=1 is the smoke test: exit before the scenario and the emission.
haskey(ENV, "RC_LOAD_ONLY") && exit(0)
# The sequential simulator only. The default mode also runs the parallel
# simulator, which takes many minutes without package images.
OmnetLegacyRoutingExample.run_scenario(Symbol(get(ENV, "RC_SCENARIO", "routing_small")); mode = :seq)
