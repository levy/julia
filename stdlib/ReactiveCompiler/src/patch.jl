# The patch of a package file: the process of a patch build that
# `Base.compile_package_patch` starts when the sources of a package changed
# and a file of it is fresh in all else.
#
# The process loads that file, applies the changes of the package's sources
# since the file with the apply of a store (`rc_apply_tracked`), compiles again
# the code that the changes closed, and defines the module of the patch. The
# output of the process is the image of that module: the new methods of the
# package with their code, the code compiled again, and the lists that the
# loader applies after it loads the patch (`Base.load_package_patch`).
#
# The apply takes a new, changed or removed method (A1, A2, A3). It refuses
# every other change: a top-level read of a package above, of a macro, a
# constant or a type, has no record yet, so a file above could keep a value
# that the change made old. The caller then compiles the package whole.

const PATCH_CHANGES = Set(["A1", "A2", "A3"])

# Whether the patch build owns module `m`: a module of the patched package.
patch_owns(m::Module) = ccall(:jl_reactive_package_patch_owns, Cint, (Any,), m) != 0

# Every module of the package of `root`.
function patch_modules(root::Module)
    found = Module[root]
    i = 1
    while i <= length(found)
        mod = found[i]
        for name in names(mod; all = true, imported = false)
            isdefined(mod, name) || continue
            value = getglobal(mod, name)
            value isa Module && value !== mod && parentmodule(value) === mod && !(value in found) &&
                push!(found, value)
        end
        i += 1
    end
    return found
end

# The live methods of the package of the patch build.
function patch_live_methods()
    found = Base.IdSet{Method}()
    rc_each_live_method() do method
        patch_owns(method.module) && push!(found, method)
    end
    return found
end

# The module of the patch, which the output of the process writes: the new
# bindings of the package's modules, as `(module, name, value)`, and the
# methods that the apply deleted.
function define_patch_module(pkg::Base.PkgId, bindings::Vector{Any}, deleted::Vector{Method})
    patch_id = Base.package_patch_id(pkg)
    uuid = convert(NTuple{2, UInt64}, patch_id.uuid::Base.UUID)
    ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), Base.__toplevel__, uuid)
    ex = Meta.parse("module PatchOfPackage end")
    ex.args[findfirst(==(:PatchOfPackage), ex.args)] = Symbol(patch_id.name)
    body = ex.args[end]::Expr
    push!(body.args, Expr(:const, Expr(:(=), :bindings, QuoteNode(bindings))))
    push!(body.args, Expr(:const, Expr(:(=), :deleted_methods, QuoteNode(deleted))))
    Core.eval(Base.__toplevel__, ex)
    return nothing
end

# Record the files of the package in the header of the patch, as they are now,
# so the loader takes the patch only while the sources stay the same. The
# entry file is first, as in the header of the package file.
function record_patch_sources(root::Module, includes)
    for inc in includes
        mod = inc.id == Base.PkgId("") ? Base.__toplevel__ : root
        for name in inc.modpath
            mod = getglobal(mod, Symbol(name))::Module
        end
        content = inc.mtime < 0
        Base._include_dependency!(Base._require_dependencies, true, mod, inc.filename, content, !content)
    end
end

# Apply the changes of the sources of `pkg` to its file `cachefile`, compile
# again what they closed, and define the module of the patch. `newly_inferred`
# is the list of code that the output writes. Answer whether the patch is
# made; on false the reasons are in the log beside the file.
function write_package_patch(pkg::Base.PkgId, cachefile::String, newly_inferred::Vector{Core.CodeInstance})
    # Julia's stream and the runtime both write the log: append mode keeps
    # every line where its write puts it.
    log_path = Base.package_patch_file(cachefile) * ".log"
    rm(log_path; force = true)
    open(log_path, "a") do log
        redirect_stdout(log) do
            try
                return write_package_patch_logged(pkg, cachefile, newly_inferred)
            catch err
                err isa RcRefusal || println("rc: patch error ", sprint(showerror, err, catch_backtrace()))
                return false
            finally
                flush(stdout)
            end
        end
    end
end

function write_package_patch_logged(pkg::Base.PkgId, cachefile::String, newly_inferred::Vector{Core.CodeInstance})
    t0 = time()
    ocachefile = Base.ocachefile_from_cachefile(cachefile)
    root = @lock Base.require_lock Base._tryrequire_from_serialized(pkg, cachefile, ocachefile; patch = false)
    root isa Module || error("the file ", cachefile, " did not load: ", root)
    # The rest sees the bindings of the file: they are newer than this call.
    return Base.invokelatest(apply_package_patch, pkg, root::Module, cachefile, newly_inferred, t0)
end

function apply_package_patch(pkg::Base.PkgId, root::Module, cachefile::String,
                             newly_inferred::Vector{Core.CodeInstance}, t0::Float64)
    t_load = time() - t0
    _, (includes, srcfiles, _), _ = Base.parse_cache_header(cachefile)
    work = mktempdir()
    files = String[]
    copies = String[]
    roots = Vector{Symbol}[]
    for inc in srcfiles
        copy = joinpath(work, string(length(files) + 1, "_", basename(inc.filename)))
        write(copy, Base.read_dependency_src(cachefile, inc.filename))
        push!(files, inc.filename)
        push!(copies, copy)
        push!(roots, inc.id == Base.PkgId("") ? Symbol[] : Symbol[Symbol(pkg.name); Symbol.(inc.modpath)])
    end
    ccall(:jl_reactive_set_package_patch, Cvoid, (Any,), root)
    modules = patch_modules(root)
    names_before = Dict{Module, Set{Symbol}}(m => Set(names(m; all = true, imported = false)) for m in modules)
    methods_before = patch_live_methods()
    world_before = Base.get_world_counter()
    rc_apply_tracked(files, roots, copies, files, roots, Tuple{String, String}[],
                     joinpath(work, "reads"), joinpath(work, "refusals"); allowed = PATCH_CHANGES)
    world_after = Base.get_world_counter()
    t_apply = time() - t0 - t_load
    # The bindings that the apply made: the type of a closure of a changed
    # method, and its instance. A new global that is not a constant has no
    # value that a patch can carry.
    bindings = Any[]
    for mod in modules, name in Base.invokelatest(names, mod; all = true, imported = false)
        name in names_before[mod] && continue
        Base.invokelatest(isdefined, mod, name) || continue
        if !Base.invokelatest(isconst, mod, name)
            println("rc: refuse the new global ", mod, ".", name, ": not a constant")
            return false
        end
        push!(bindings, (mod, name, Base.invokelatest(getglobal, mod, name)))
    end
    # The methods that the apply deleted without a replacement of the same
    # signature. A changed `__init__` ran in its old form at the load of the
    # file, before the patch.
    methods_after = patch_live_methods()
    for method in methods_after
        method in methods_before && continue
        if method.name === :__init__
            println("rc: refuse the changed ", method.module, ".__init__: it runs before the patch loads")
            return false
        end
    end
    deleted = Method[]
    for method in methods_before
        method in methods_after && continue
        any(m -> m.sig == method.sig, methods_after) || push!(deleted, method)
    end
    # The code that the apply closed, compiled again in the new world. The
    # tag marks it as precompiled, so the output keeps it.
    closed = Core.MethodInstance[]
    rc_each_instance() do mi
        ci = isdefined(mi, :cache) ? mi.cache : nothing
        while ci isa Core.CodeInstance
            if world_before <= ci.max_world < world_after
                push!(closed, mi)
                break
            end
            ci = isdefined(ci, :next) ? ci.next : nothing
        end
    end
    ccall(:jl_set_newly_inferred, Cvoid, (Any,), newly_inferred)
    ccall(:jl_tag_newly_inferred_enable, Cvoid, ())
    compiled = 0
    try
        for mi in closed
            try
                precompile(mi.specTypes) && (compiled += 1)
            catch err
                println("rc: patch: ", mi.specTypes, " did not compile: ", sprint(showerror, err))
            end
        end
    finally
        ccall(:jl_tag_newly_inferred_disable, Cvoid, ())
    end
    t_compile = time() - t0 - t_load - t_apply
    define_patch_module(pkg, bindings, deleted)
    Base.invokelatest(record_patch_sources, root, includes)
    println("rc: patch of ", pkg.name, ": load ", round(t_load; digits = 2), " s, apply ",
            round(t_apply; digits = 2), " s, compile ", round(t_compile; digits = 2), " s; ",
            length(bindings), " new bindings, ", length(deleted), " deleted methods, ",
            compiled, " of ", length(closed), " closed instances compiled again")
    return true
end
