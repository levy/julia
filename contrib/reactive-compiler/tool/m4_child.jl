# M4, the materialize child.
#
# The driver (src/Materialize.jl) starts this script in a fresh Julia process
# that boots from the image of the previous snapshot, with `--output-o`. The
# script loads the application, applies the source changes, runs the workload,
# and exits; Julia then emits the object archive of the delta. Without a
# previous snapshot the same script is the full build.
#
# The environment, set by the driver:
#   RC_PROJECT        the project path, relative to the working directory
#   RC_PACKAGES       the packages to load, separated by commas
#   RC_SRC            the directory of SourceDiff.jl
#   RC_TRACKED        the tracked source files, separated by colons
#   RC_TRACKED_MODULES  one dotted module path per tracked file, separated by
#                     colons: the module whose `include` loads the file. An
#                     empty entry means Main.
#   RC_PARENT_SOURCE  the stored sources of the previous snapshot; unset on a
#                     full build, and then no source change is applied
#   RC_WORKLOAD       the Julia code of the workload, one snippet
#
# The script prints one `m4:` line per applied expression and per cone member,
# so that the gate can compare the delta of the build with the cone.

# With `--output-o`, Julia leaves Sys.BINDIR, Sys.STDLIB, LOAD_PATH and
# DEPOT_PATH unset, and `--project` is not applied. Fill them the way
# PackageCompiler fills them in its child.
@eval Sys BINDIR = ccall(:jl_get_julia_bindir, Any, ())::String
@eval Sys STDLIB = abspath(Sys.BINDIR, "..", "share", "julia", "stdlib", "v$(VERSION.major).$(VERSION.minor)")
copy!(LOAD_PATH, [abspath(ENV["RC_PROJECT"]), "@stdlib"])
Base.init_depot_path()

for package in split(ENV["RC_PACKAGES"], ',')
    Core.eval(Main, :(using $(Symbol(package))))
end

# The harness itself is part of the image. Every definition is guarded, so
# that a build that boots from a previous image keeps the compiled functions
# and the delta holds the cone of the source change alone. A change of the
# harness therefore needs a new chain from a full build.
isdefined(Main, :ReactiveSourceDiff) || include(joinpath(ENV["RC_SRC"], "SourceDiff.jl"))

if !@isdefined(m4_each_instance)

# Call f on every method instance of the method table.
function m4_each_instance(f)
    Base.visit(Core.methodtable) do method
        for mi in Base.specializations(method)
            mi isa Core.MethodInstance && f(mi)
        end
        true
    end
end

# The module that a path of names leads to, from Main.
function m4_resolve_module(module_path)
    mod = Main
    for name in module_path
        mod = getfield(mod, name)::Module
    end
    return mod
end

# The module path of one tracked file, from its RC_TRACKED_MODULES entry.
function m4_root_path(index)
    entries = split(ENV["RC_TRACKED_MODULES"], ':')
    entry = strip(entries[index])
    isempty(entry) && return Symbol[]
    return Symbol.(split(entry, '.'))
end

# Warm every code path of the diff and of its report on a synthetic edit, so
# that the first real edit does not put the machinery itself into the delta.
# Nothing is evaluated: the world does not move, and the delta of a no-edit
# build stays empty. The argument types copy the real calls exactly: the texts
# are String, the path is the SubString that `split` answers, and the report
# lines carry the same argument types as the real report lines.
function m4_warm()
    old = "f() = 1\nmodule M\ng() = 1\nh() = 1\nend\n"
    new = "f() = 2\nmodule M\ng() = 2\nend\n"
    path = first(split("warm.jl", ':'))
    diff = ReactiveSourceDiff.changed_expressions(old, new, path)
    length(diff.changed) == 2 && length(diff.removed) == 1 ||
        error("m4_warm: the synthetic diff answered ", length(diff.changed), " changed and ",
              length(diff.removed), " removed")
    name = something(ReactiveSourceDiff.defined_name(diff.changed[1][2]), :none)
    Core.println("m4: warm ", path, " ", name, " ", Tuple{typeof(m4_warm)})
    Core.println("m4: warm eval in ", Main, ": ", name)
    Core.println("m4: warm removed in ", join(Symbol[:M], '.'), ": ", :function, "; not applied")
    println("m4: warm file ", path, " changed, ", length(diff.changed), " expressions, ",
            length(diff.removed), " removals")
end

# Compare every tracked file with the stored copy of the previous snapshot,
# and evaluate the changed expressions in their modules. Print the cone that
# the evaluation closed: the specializations of the replaced methods, and
# every code instance whose world ended. Answer the set of method instances
# that exist before the workload, and whether the world moved.
#
# The comparison, the scan and the report run in every build, also when
# nothing changed, and in a full build each file is compared with itself. The
# harness so warms its own code in the first build of a chain, and the delta
# of an edit build holds the cone of the edit and not the first compilation
# of the harness.
function m4_apply_tracked()
    m4_warm()
    full = !haskey(ENV, "RC_PARENT_SOURCE")
    tracked = split(ENV["RC_TRACKED"], ':')
    pairs = Tuple{Vector{Symbol}, Any}[]
    for (index, path) in enumerate(tracked)
        new_text = read(path, String)
        old_text = full ? new_text :
            read(joinpath(ENV["RC_PARENT_SOURCE"], string(index, "-", basename(path))), String)
        root = m4_root_path(index)
        diff = ReactiveSourceDiff.changed_expressions(old_text, new_text, path)
        for (module_path, e) in diff.removed
            Core.println("m4: removed in ", join(vcat(root, module_path), '.'), ": ", e.head,
                         "; not applied")
        end
        for (module_path, e) in diff.changed
            push!(pairs, (vcat(root, module_path), e))
        end
        isempty(diff.changed) && isempty(diff.removed) ||
            println("m4: file ", path, " changed, ", length(diff.changed), " expressions, ",
                    length(diff.removed), " removals")
    end
    # The specializations of the methods that the evaluation will replace.
    replaced = Core.MethodInstance[]
    for (module_path, e) in pairs
        mod = m4_resolve_module(module_path)
        name = ReactiveSourceDiff.defined_name(e)
        if name === nothing
            ReactiveSourceDiff.is_module(e) &&
                Core.println("m4: warning, a whole module is evaluated: ", join(module_path, '.'))
            continue
        end
        isdefined(mod, name) || continue
        value = getfield(mod, name)
        value isa Function || continue
        for method in methods(value)
            method.module === mod || continue
            for mi in Base.specializations(method)
                mi isa Core.MethodInstance && push!(replaced, mi)
            end
        end
    end
    world_before = Base.get_world_counter()
    t_eval = @elapsed for (module_path, e) in pairs
        mod = m4_resolve_module(module_path)
        Core.eval(mod, e)
        Core.println("m4: eval in ", mod, ": ",
                     something(ReactiveSourceDiff.defined_name(e), e.head))
    end
    world_after = Base.get_world_counter()
    # The cone: the replaced specializations, and every code instance that the
    # evaluation closed. Collect the set of method instances that exist now,
    # so that the workload's new instances can be reported.
    closed = Core.MethodInstance[]
    before = Base.IdSet{Core.MethodInstance}()
    t_scan = @elapsed m4_each_instance() do mi
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
    for mi in replaced
        push!(before, mi)
        Core.println("m4: cone replaced ", mi.specTypes)
    end
    for mi in closed
        Core.println("m4: cone closed ", mi.specTypes)
    end
    println("m4: applied ", length(pairs), " expressions in ", round(1e3 * t_eval, digits = 1),
            " ms, world ", world_before, " -> ", world_after, "; cone ", length(replaced),
            " replaced, ", length(closed), " closed; scan ", round(t_scan, digits = 2), " s")
    return (before = before, moved = world_after > world_before)
end

# Count every method instance that the workload made. Print each one only
# after an edit; a full build makes thousands, and only the cone of an edit
# is compared with the delta.
function m4_new_instances(before, verbose::Bool)
    new = Core.MethodInstance[]
    t_scan = @elapsed m4_each_instance(mi -> mi in before || push!(new, mi))
    if verbose
        for mi in new
            Core.println("m4: cone new ", mi.specTypes)
        end
    end
    println("m4: new ", length(new), " method instances after the workload, scan ",
            round(t_scan, digits = 2), " s")
end

end # @isdefined guard

applied = m4_apply_tracked()
include_string(Main, ENV["RC_WORKLOAD"], "workload")
m4_new_instances(applied.before, applied.moved)
