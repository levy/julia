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

# RC_EDIT=1 edits the model before the scenario: `pk.hop_count += 1` becomes
# `+= 2` in `routing_handle!`, the edit of M0. The definition is read back from
# the file of the method, the text is replaced, and the result is evaluated
# again in the module of the method, as `src/MethodEdit.jl` does. The cone of
# the edit is printed for the comparison with the delta of the build: the
# specializations of the replaced method, every code instance that the edit
# closed, and, after the scenario, every method instance that did not exist
# before the scenario. `Core.println` prints a signature the way the delta
# report does. Without RC_EDIT the same code runs up to the evaluation and
# finds an empty cone, so that the code of these functions is in the image
# before the edit and the delta of the edited build holds the cone alone. A
# build that boots from the image of a previous build has the functions
# already; a definition would replace them and put them into the delta of
# every build.
if !@isdefined(edit_and_cone)
# Call f on every method instance of the method table.
function each_instance(f)
    Base.visit(Core.methodtable) do method
        for mi in Base.specializations(method)
            mi isa Core.MethodInstance && f(mi)
        end
        true
    end
end
# Apply the edit and print the cone that the edit closed. The result is the set
# of method instances that exist before the scenario.
function edit_and_cone(edit::Bool)
    target = first(methods(OmnetLegacyRoutingExample.Routing.routing_handle!))
    file = string(target.file)
    # A method that an earlier build evaluated from text has the file "none":
    # its image carries the edit already, and a run from that image reads
    # nothing.
    definition = nothing
    if isfile(file)
        text = read(file, String)
        offset = 1
        for _ in 2:Int(target.line)
            offset = nextind(text, findnext('\n', text, offset))
        end
        _, stop = Meta.parse(text, offset)
        chunk = String(SubString(text, offset, prevind(text, stop)))
        count("pk.hop_count += 1", chunk) == 1 || error("the edit does not apply to $file:$(target.line)")
        definition = Meta.parse(replace(chunk, "pk.hop_count += 1" => "pk.hop_count += 2"))
    elseif edit
        error("the edit is applied already: routing_handle! comes from $file")
    end
    world_before = Base.get_world_counter()
    t_edit = edit ? @elapsed(Core.eval(target.module, definition)) : 0.0
    world_after = Base.get_world_counter()
    closed = Core.MethodInstance[]
    before = Base.IdSet{Core.MethodInstance}()
    t_scan = @elapsed each_instance() do mi
        push!(before, mi)
        ci = isdefined(mi, :cache) ? mi.cache : nothing
        while ci isa Core.CodeInstance
            if world_before <= ci.max_world < world_after
                push!(closed, mi)
                break
            end
            ci = isdefined(ci, :next) ? ci.next : nothing
        end
    end
    # The replaced method keeps its specializations; the table does not list
    # it any more.
    replaced = Core.MethodInstance[]
    if world_after > world_before
        for mi in Base.specializations(target)
            mi isa Core.MethodInstance && push!(replaced, mi)
            push!(before, mi)
        end
    end
    for mi in replaced
        Core.println("m0_build: cone replaced ", mi.specTypes)
    end
    for mi in closed
        Core.println("m0_build: cone closed ", mi.specTypes)
    end
    println("m0_build: edit ", edit ? "routing_handle!" : "none", " in ", round(1e3 * t_edit, digits = 1),
            " ms, world ", world_before, " -> ", world_after, "; cone ", length(replaced), " replaced, ",
            length(closed), " closed; ", length(before), " method instances, scan ", round(t_scan, digits = 2), " s")
    return before
end
# Print every method instance that the scenario made: the new specializations
# of the edited method and of its closures, and the residue of the run.
function new_instances(before)
    new = Core.MethodInstance[]
    t_scan = @elapsed each_instance(mi -> mi in before || push!(new, mi))
    for mi in new
        Core.println("m0_build: cone new ", mi.specTypes)
    end
    println("m0_build: new ", length(new), " method instances after the scenario, scan ", round(t_scan, digits = 2), " s")
end
end
before_scenario = edit_and_cone(haskey(ENV, "RC_EDIT"))
# The sequential simulator only. The default mode also runs the parallel
# simulator, which takes many minutes without package images.
OmnetLegacyRoutingExample.run_scenario(Symbol(get(ENV, "RC_SCENARIO", "routing_small")); mode = :seq)
new_instances(before_scenario)
