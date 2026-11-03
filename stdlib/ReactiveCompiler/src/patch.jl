# The patches of a package file: the process of a patch build that
# `Base.compile_package_patch` starts when the sources of a package changed
# and a file of it is fresh in all else, and the record of the top-level reads
# of a package that every whole compile makes.
#
# The patch process of patch k loads that file and its patches 1 to k-1,
# applies the changes of the package's sources since patch k-1 with the apply
# of a store (`rc_apply_tracked`), compiles again the code that the changes
# closed, and defines the module of patch k. The output of the process is the
# image of that module: the new methods of the package with their code, the
# code compiled again, and the lists that the loader applies after it loads
# the patch (`Base.load_package_patches`).
#
# The apply takes a new, changed or removed method (A1, A2, A3), a changed
# constant (C1) and a changed macro (D1), with the expressions of the package
# that name them. It refuses every other change, and a change of a file that
# the package reads but does not include; the caller then compiles the
# package whole. A file of a package above that names a changed constant or
# macro at its top level goes out of date by the stamp of the name
# (`Base.package_names_dir`); Julia's check of the edges at the load of the
# other files drops the code that read a changed method or constant.

const PATCH_CHANGES = Set(["A1", "A2", "A3", "C1", "D1"])

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

# The docstrings of the modules of the package, as `(module, binding, sig)`
# => the docstring.
function patch_docstrings(modules::Vector{Module})
    found = IdDict{Any, Any}()
    for mod in modules
        meta = Base.Docs.meta(mod; autoinit = false)
        meta === nothing && continue
        for (binding, multidoc) in meta, (sig, docstring) in multidoc.docs
            found[(mod, binding, sig)] = docstring
        end
    end
    return found
end

# The value of every global of the modules, by `(module, name)`.
function patch_globals(modules::Vector{Module})
    found = Dict{Tuple{Module, Symbol}, Any}()
    for mod in modules, name in Base.invokelatest(names, mod; all = true, imported = false)
        Base.invokelatest(isdefinedglobal, mod, name) || continue
        found[(mod, name)] = Base.invokelatest(getglobal, mod, name)
    end
    return found
end

# Whether `value` is the type that the binding `mod.name` defines: a `struct`,
# an `abstract type` or a `primitive type`, not an alias.
function defines_type(mod::Module, name::Symbol, @nospecialize(value))
    value isa Type || return false
    type = Base.unwrap_unionall(value)
    return type isa DataType && parentmodule(type) === mod && nameof(type) === name
end

# The name of the stamp of `mod.name` (`Base.package_names_dir`).
stamp_name(mod::Module, name::Symbol) = string(join(fullname(mod), "."), ".", name)

# The module of patch k, which the output of the process writes: the new and
# changed constants of the package's modules, as `(module, name, value)`, the
# methods that the apply deleted, the new docstrings, as `(module, binding,
# sig, docstring)`, the methods that moved to another line, as `(method,
# line)`, the stamp of the patch and the names it changed.
function define_patch_module(pkg::Base.PkgId, k::Int, bindings::Vector{Any}, deleted::Vector{Method},
                             docstrings::Vector{Any}, moved::Vector{Any}, stamp::String, changed::Vector{String})
    patch_id = Base.package_patch_id(pkg, k)
    uuid = convert(NTuple{2, UInt64}, patch_id.uuid::Base.UUID)
    ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), Base.__toplevel__, uuid)
    ex = Meta.parse("module PatchOfPackage end")
    ex.args[findfirst(==(:PatchOfPackage), ex.args)] = Symbol(patch_id.name)
    body = ex.args[end]::Expr
    push!(body.args, Expr(:const, Expr(:(=), :bindings, QuoteNode(bindings))))
    push!(body.args, Expr(:const, Expr(:(=), :deleted_methods, QuoteNode(deleted))))
    push!(body.args, Expr(:const, Expr(:(=), :docstrings, QuoteNode(docstrings))))
    push!(body.args, Expr(:const, Expr(:(=), :moved_methods, QuoteNode(moved))))
    push!(body.args, Expr(:const, Expr(:(=), :stamp, stamp)))
    push!(body.args, Expr(:const, Expr(:(=), :changed_names, QuoteNode(changed))))
    Core.eval(Base.__toplevel__, ex)
    return nothing
end

# Record the files of the package in the header of the patch, as they are now,
# so the loader takes the chain only while the sources stay the same. The
# entry file is first, as in the header of the package file. A file whose
# text differs from the text that the package file holds is a file of `root`,
# so the writer copies its text into the patch, where the next patch reads it;
# every other file is a file of `Main`, as an `include_dependency` is, and the
# writer copies no text for it.
function record_patch_sources(root::Module, includes, changed_files::Set{String})
    for inc in includes
        content = inc.mtime < 0
        mod = inc.filename in changed_files ? root : Main
        Base._include_dependency!(Base._require_dependencies, true, mod, inc.filename, content, !content)
    end
end

# Apply the changes of the sources of `pkg` since patch k-1 to its file
# `cachefile` and patches 1 to k-1, compile again what they closed, and define
# the module of patch k. `newly_inferred` is the list of code that the output
# writes. Answer whether the patch is made; on false the reasons are in the
# log beside the patch.
function write_package_patch(pkg::Base.PkgId, cachefile::String, k::Int, newly_inferred::Vector{Core.CodeInstance})
    # Julia's stream and the runtime both write the log: append mode keeps
    # every line where its write puts it.
    log_path = Base.package_patch_file(pkg, cachefile, k) * ".log"
    rm(log_path; force = true)
    open(log_path, "a") do log
        redirect_stdout(log) do
            try
                return write_package_patch_logged(pkg, cachefile, k, newly_inferred)
            catch err
                err isa RcRefusal || println("rc: patch error ", sprint(showerror, err, catch_backtrace()))
                return false
            finally
                flush(stdout)
            end
        end
    end
end

function write_package_patch_logged(pkg::Base.PkgId, cachefile::String, k::Int, newly_inferred::Vector{Core.CodeInstance})
    t0 = time()
    _, (includes, srcfiles, _), _ = Base.parse_cache_header(cachefile)
    # A file that the package reads but does not include, a stamp among them:
    # the patch applies changes of the sources alone.
    for inc in includes
        any(s -> s.filename == inc.filename, srcfiles) && continue
        if Base.any_includes_stale([inc], cachefile)
            println("rc: refuse the changed file ", inc.filename, ": the package reads it, the patch applies sources")
            return false
        end
    end
    ocachefile = Base.ocachefile_from_cachefile(cachefile)
    root = @lock Base.require_lock begin
        loaded = Base._tryrequire_from_serialized(pkg, cachefile, ocachefile; patch = false)
        loaded isa Module || error("the file ", cachefile, " did not load: ", loaded)
        failed = Base.load_package_patches(pkg, loaded, cachefile; fresh = false)
        failed === nothing || error("the patches of ", cachefile, " did not load: ", failed)
        loaded
    end
    # The rest sees the bindings of the file: they are newer than this call.
    return Base.invokelatest(apply_package_patch, pkg, root::Module, cachefile, k, includes, srcfiles,
                             newly_inferred, t0)
end

function apply_package_patch(pkg::Base.PkgId, root::Module, cachefile::String, k::Int, includes, srcfiles,
                             newly_inferred::Vector{Core.CodeInstance}, t0::Float64)
    t_load = time() - t0
    # The text of each file as patch k-1 applied it: the copy in patch k-1 of
    # a file that differs from the package file, else the text of the package
    # file.
    previous = k > 1 ? Base.package_patch_file(pkg, cachefile, k - 1) : nothing
    previous_texts = Set{String}()
    if previous !== nothing
        _, (_, previous_srcfiles, _), _ = Base.parse_cache_header(previous)
        union!(previous_texts, (inc.filename for inc in previous_srcfiles))
    end
    work = mktempdir()
    files = String[]
    copies = String[]
    roots = Vector{Symbol}[]
    base_texts = Dict{String, String}()
    for inc in srcfiles
        copy = joinpath(work, string(length(files) + 1, "_", basename(inc.filename)))
        base_texts[inc.filename] = Base.read_dependency_src(cachefile, inc.filename)
        write(copy, inc.filename in previous_texts ? Base.read_dependency_src(previous, inc.filename) :
                    base_texts[inc.filename])
        push!(files, inc.filename)
        push!(copies, copy)
        push!(roots, inc.id == Base.PkgId("") ? Symbol[] : Symbol[Symbol(pkg.name); Symbol.(inc.modpath)])
    end
    ccall(:jl_reactive_set_package_patch, Cvoid, (Any,), root)
    modules = patch_modules(root)
    globals_before = patch_globals(modules)
    methods_before = patch_live_methods()
    lines_before = IdDict{Method, Int32}(method => method.line for method in methods_before)
    docstrings_before = patch_docstrings(modules)
    world_before = Base.get_world_counter()
    # The log messages of the apply, such as a replaced docstring, go to the
    # log of the build.
    Base.CoreLogging.with_logger(Base.CoreLogging.SimpleLogger(stdout)) do
        rc_apply_tracked(files, roots, copies, files, roots, Tuple{String, String}[],
                         joinpath(work, "reads"), joinpath(work, "refusals"); allowed = PATCH_CHANGES)
    end
    world_after = Base.get_world_counter()
    t_apply = time() - t0 - t_load
    # The constants that the apply made or changed: the type of a closure of a
    # changed method and its instance, a changed constant and the constants
    # that name it. A global that is not a constant has no value that a patch
    # can set at the load; one with a generated name is a temporary of a macro
    # at the top level, such as the one of a docstring. A changed type is a
    # change of every method on it.
    bindings = Any[]
    changed = String[]
    for ((mod, name), value) in patch_globals(modules)
        old = get(globals_before, (mod, name), nothing)
        known = haskey(globals_before, (mod, name))
        known && old === value && continue
        if !Base.invokelatest(isconst, mod, name)
            startswith(String(name), '#') && continue
            println("rc: refuse the global ", mod, ".", name, ": not a constant")
            return false
        end
        if known && defines_type(mod, name, old)
            println("rc: refuse the changed type ", mod, ".", name)
            return false
        end
        push!(bindings, (mod, name, value))
        known && push!(changed, stamp_name(mod, name))
    end
    # The methods that the apply made, and the ones it deleted without a
    # replacement of the same signature. A changed macro changes its name. A
    # changed `__init__` ran in its old form at the load of the file, before
    # the patch.
    methods_after = patch_live_methods()
    for method in methods_after
        method in methods_before && continue
        if method.name === :__init__
            println("rc: refuse the changed ", method.module, ".__init__: it runs before the patch loads")
            return false
        end
        startswith(String(method.name), '@') && push!(changed, stamp_name(method.module, method.name))
    end
    # The methods that stay and moved: the apply updates their lines in this
    # process alone.
    moved = Any[]
    for method in methods_after
        line = get(lines_before, method, method.line)
        line == method.line || push!(moved, (method, method.line))
    end
    deleted = Method[]
    for method in methods_before
        method in methods_after && continue
        any(m -> m.sig == method.sig, methods_after) || push!(deleted, method)
        startswith(String(method.name), '@') && push!(changed, stamp_name(method.module, method.name))
    end
    unique!(changed)
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
    docstrings = Any[]
    for ((mod, binding, sig), docstring) in patch_docstrings(modules)
        get(docstrings_before, (mod, binding, sig), nothing) === docstring && continue
        push!(docstrings, (mod, binding, sig, docstring))
    end
    # The stamp of this patch, and the names it changed, for the stamps that
    # `Base.compile_package_patch` writes after the patch.
    stamp = string(Base.UUID(rand(UInt128)))
    write(Base.package_patch_file(pkg, cachefile, k) * ".names", join([stamp; changed], '\n'))
    define_patch_module(pkg, k, bindings, deleted, docstrings, moved, stamp, changed)
    changed_files = Set{String}(f for f in files if read(f, String) != base_texts[f])
    record_patch_sources(root, includes, changed_files)
    println("rc: patch ", k, " of ", pkg.name, ": load ", round(t_load; digits = 2), " s, apply ",
            round(t_apply; digits = 2), " s, compile ", round(t_compile; digits = 2), " s; ",
            length(bindings), " new or changed constants, ", length(deleted), " deleted methods, ",
            length(docstrings), " new docstrings, ", length(moved), " moved methods, ",
            length(changed), " changed names, ",
            compiled, " of ", length(closed), " closed instances compiled again")
    return true
end

# The record of a whole compile of the package of `root`: the constants and
# macros of other packages that its top level names. Each one is the stamp
# file of the name beside the file of its package
# (`Base.package_names_dir`), recorded as a file that the new file depends
# on. The names are syntactic, as the dependents of the apply are: the macros
# that an expression calls anywhere, and the names that a signature, a type or
# the initializer of a global names. A name of a method body is not one:
# Julia's check of the edges at the load drops the code that read a changed
# constant. A function, a module and a type that a `struct` defines are not
# one either: a changed method keeps the files above, and a changed type is
# refused by the patch.
function record_top_level_reads(root::Module)
    sources = String[]
    for (mod, path, _, _, mtime) in Base._require_dependencies
        mtime < 0 || continue
        (mod === Base.__toplevel__ || Base.moduleroot(mod) === root) && isfile(path) && push!(sources, path)
    end
    read_names = Set{Symbol}()
    for path in unique!(sources)
        for entry in ReactiveSourceDiff.file_entries(read(path, String), path)
            union!(read_names, ReactiveSourceDiff.macro_heads(entry.expr))
            union!(read_names, ReactiveSourceDiff.type_level_names(entry.expr))
        end
    end
    for (id, dep) in Base.loaded_modules
        dep === root && continue
        (id.uuid === nothing || Base.package_patch_place(id) !== nothing) && continue
        origin = get(Base.pkgorigins, id, nothing)
        origin === nothing && continue
        cachefile = origin.cachepath
        cachefile === nothing && continue
        startswith(something(origin.path, Sys.STDLIB), Sys.STDLIB) && continue
        # The loaded chain of the package, newest patch first.
        chain = Module[]
        for k in 1:Base.MAX_PACKAGE_PATCHES
            patch = get(Base.loaded_modules, Base.package_patch_id(id, k), nothing)
            patch === nothing && break
            pushfirst!(chain, patch)
        end
        dir = Base.package_names_dir(cachefile)
        for mod in patch_modules(dep), name in read_names
            Base.invokelatest(isdefinedglobal, mod, name) || continue
            # A name that two imports give has no owner, so it has no stamp.
            owner = try Base.binding_module(mod, name) catch; nothing end
            owner === mod || continue
            Base.invokelatest(isconst, mod, name) || continue
            value = Base.invokelatest(getglobal, mod, name)
            if !startswith(String(name), '@')
                value isa Union{Function, Module} && continue
                defines_type(mod, name, value) && continue
            end
            path = joinpath(dir, stamp_name(mod, name))
            if !isfile(path)
                mkpath(dir)
                last = findfirst(patch -> stamp_name(mod, name) in getglobal(patch, :changed_names), chain)
                tmp = string(path, ".", getpid())
                write(tmp, last === nothing ? "base" : getglobal(chain[last], :stamp)::String)
                mv(tmp, path; force = true)
            end
            Base._include_dependency!(Base._require_dependencies, true, Main, path, true, false)
        end
    end
    return nothing
end
