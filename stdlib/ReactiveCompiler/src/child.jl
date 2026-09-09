# The apply of an edit: the definitions that the rebuild child of a store
# and the compiler server run.
#
# This file is part of the system image, so a rebuild that boots from the
# previous image finds the harness compiled, and the delta of an edit holds
# the cone of the edit and nothing of this machinery. A store runs the
# harness of the image it was founded on: a change of this file reaches a
# store through a founding on the new image.
#
# Everything that varies between rebuilds — the tracked files, their module
# paths, the stored sources of the previous snapshot — comes in as arguments
# from the client (the spec of a request, or the script of a child), never
# from inside these bodies.
#
# The apply of an edit, in order:
#   1. the ledgers: the entries of the stored copy of every tracked file of
#      the previous snapshot, and of every tracked file on disk (see
#      `ReactiveSourceDiff`); the methods of an old entry are the methods of
#      the method table with the entry's file and a line inside the entry;
#   2. the match of the two file lists: by path, then by content (a renamed
#      file), then a lone leftover pair (a renamed and edited file);
#   3. the diff of each matched pair by key, and the classification of every
#      changed or removed entry with an id of the change catalog of
#      `plan/pending/robust-incremental-compiler.md`; a refusal stops here;
#   4. the apply, in file order: the removals delete their methods first,
#      then every change is evaluated in its module, and the dependents that
#      the evaluation reveals (the expressions that name a changed type, a
#      changed binding or a changed macro, or whose names resolve differently
#      after a changed `using`) join the queue;
#   5. the new ledger: the methods of every new entry, from the method table
#      after the apply; every old method of a change is deleted — one whose
#      signature no new method of the entry has made the change a removal
#      too, one with a replacement is a dead entry.
# Then the top level precompiles the trace, and the image is written.

const RC_METHOD_KINDS = (:method, :macro, :other)
const RC_BINDING_KINDS = (:const, :global)
const RC_OPTION_MACROS = (Symbol("@compiler_options"), Symbol("@optlevel"), Symbol("@max_methods"))

# One entry of a ledger: the entry of the file at `file` in its list, its
# kind and defined name (both syntactic), and its methods once they are
# looked up.
# The ledger of the last apply of this process: the next apply of the same
# files takes it as its old ledger (a server applies many edits).
const RC_LEDGER_CACHE = Ref{Any}(nothing)

mutable struct RcItem
    file::Int
    path::String
    entry::ReactiveSourceDiff.Entry
    kind::Symbol
    name::Union{Symbol, Nothing}
    methods::Vector{Method}
end

# One change to apply: the new item and its id, the old items it replaces
# (the same name in the same module, of a compatible kind; for a dependent,
# the item itself) and their methods before the apply, where it is, and a
# note for the report. A removal has no new item. After the apply, `kept`
# counts the old methods that the method filter kept in place of an
# identical redefinition, and `deleted` the old methods without a
# replacement.
mutable struct RcChange
    id::String
    item::Union{RcItem, Nothing}
    old_items::Vector{RcItem}
    old_methods::Vector{Method}
    where::String
    note::String
    kept::Int
    deleted::Int
end
RcChange(id, item::RcItem, old::Vector{RcItem}, note) =
    RcChange(id, item, old, Method[m for o in old for m in o.methods],
             string(rc_where(item), " ", rc_what(item)), note, 0, 0)
RcChange(id, item::RcItem, note) =
    RcChange(id, item, RcItem[item], copy(item.methods), string(rc_where(item), " ", rc_what(item)), note, 0, 0)

rc_kind_class(kind) = kind in RC_METHOD_KINDS ? :method : kind in RC_BINDING_KINDS ? :binding : kind

# Call f on every method instance of the method table.
function rc_each_instance(f)
    Base.visit(Core.methodtable) do method
        for mi in Base.specializations(method)
            mi isa Core.MethodInstance && f(mi)
        end
        true
    end
end

# The module that a path of names leads to. An empty path is Main. The first
# name resolves through Main when Main binds it, else through the loaded
# modules — the child of a rebuild imports nothing into Main.
function rc_resolve_module(module_path)
    mod = rc_module_or_nothing(module_path)
    mod === nothing && error("rc_resolve_module: no module at ", join(module_path, '.'))
    return mod
end
function rc_module_or_nothing(module_path)
    isempty(module_path) && return Main
    first_name = module_path[1]
    mod = nothing
    if isdefined(Main, first_name)
        mod = getfield(Main, first_name)
    else
        for (pkgid, loaded) in Base.loaded_modules
            if Symbol(pkgid.name) === first_name
                mod = loaded
                break
            end
        end
    end
    for name in module_path[2:end]
        mod isa Module && isdefined(mod, name) || return nothing
        mod = getfield(mod, name)
    end
    return mod isa Module ? mod : nothing
end

rc_module_path(roots, item::RcItem) = vcat(roots[item.file], item.entry.module_path)
rc_where(item::RcItem) = string(basename(item.path), ":", item.entry.lines.start)
rc_what(item::RcItem) = item.name === nothing ? string(item.kind) : string(item.name)

# ── the method filter ───────────────────────────────────────────────────────

# The methods that the filter kept in place of an identical redefinition
# since the last `rc_take_kept!`.
const RC_KEPT = Method[]

# The filter that `jl_method_def` asks before it inserts `m`: answer true to
# keep the method of the table with the same signature in the same module
# whose lowered code is the same. The definition would move the world and
# invalidate every caller of the method for nothing: an `@eval` loop with
# one changed method, or a dependent whose expansion did not change. The
# line table is not compared: the kept method keeps its own.
function rc_method_filter(m::Method)
    isdefined(m, :generator) && return false
    isdefined(m, :source) || return false
    match = Base._which(m.sig; world = Base.get_world_counter(), raise = false)
    match === nothing && return false
    old = match.method
    old === m && return false
    old.module === m.module && old.sig == m.sig || return false
    isdefined(old, :generator) && return false
    isdefined(old, :source) || return false
    old.nargs == m.nargs && old.isva == m.isva && old.nospecialize == m.nospecialize &&
        old.nkw == m.nkw && old.called == m.called && old.constprop == m.constprop &&
        old.purity == m.purity && old.nospecializeinfer == m.nospecializeinfer &&
        old.slot_syms == m.slot_syms || return false
    a = Base.uncompressed_ir(old)
    b = Base.uncompressed_ir(m)
    isequal(a.code, b.code) && a.slotflags == b.slotflags && a.ssaflags == b.ssaflags &&
        isequal(a.ssavaluetypes, b.ssavaluetypes) && a.propagate_inbounds == b.propagate_inbounds &&
        a.has_fcall == b.has_fcall && a.inlining == b.inlining || return false
    push!(RC_KEPT, old)
    return true
end

rc_install_filter(f) = ccall(:jl_reactive_set_method_filter, Cvoid, (Any,), f)

# The methods kept since the last call.
function rc_take_kept!()
    kept = copy(RC_KEPT)
    empty!(RC_KEPT)
    return kept
end

# Delete a method; with a generated method, the method of its generator
# too. The generator is an anonymous function at `none:0`, so no item of the
# ledger owns it, and nothing calls it once the method is gone: left alone,
# it stays in the table as dead code that a founding does not have.
function rc_delete_method(method::Method)
    Base.delete_method(method)
    isdefined(method, :generator) && method.generator isa Core.GeneratedFunctionStub || return
    for gen_method in methods(method.generator.gen)
        Base.delete_method(gen_method)
    end
end

# ── the ledger ──────────────────────────────────────────────────────────────

# The items of every file of `files`, read from `texts` (the stored copies
# for the old ledger, the files themselves for the new one). The parse names
# the real file.
function rc_ledger(files::Vector{String}, texts::Vector{String})
    items = RcItem[]
    for (index, path) in enumerate(files)
        text = read(texts[index], String)
        for entry in ReactiveSourceDiff.file_entries(text, path)
            push!(items, RcItem(index, path, entry, ReactiveSourceDiff.entry_kind(entry.expr),
                                ReactiveSourceDiff.defined_name(entry.expr), Method[]))
        end
    end
    return items
end

# Call f on every live method of the method table: `Base.visit` walks the
# entries that `delete_method` disabled too, and a disabled entry has a
# finite `max_world`.
function rc_each_live_method(f)
    rc_visit_entries(Core.methodtable.defs) do entry
        entry.max_world == typemax(UInt) && f(entry.func)
    end
end
rc_visit_entries(f, ::Nothing) = nothing
function rc_visit_entries(f, entry::Core.TypeMapEntry)
    while entry !== nothing
        f(entry)
        entry = entry.next
    end
end
function rc_visit_entries(f, level::Core.TypeMapLevel)
    for field in (:targ, :arg1, :tname, :name1)
        memory = getfield(level, field)
        memory === nothing && continue
        for i in 2:2:length(memory)
            isassigned(memory, i) || continue
            child = memory[i]
            if child isa Memory{Any}
                for j in 2:2:length(child)
                    isassigned(child, j) && rc_visit_entries(f, child[j])
                end
            else
                rc_visit_entries(f, child)
            end
        end
    end
    rc_visit_entries(f, level.list)
    rc_visit_entries(f, level.any)
end

# The live methods of the method table whose file is one of `paths`.
function rc_methods_by_file(paths)
    byfile = Dict{String, Vector{Method}}(path => Method[] for path in paths)
    rc_each_live_method() do method
        found = get(byfile, String(method.file), nothing)
        found === nothing || push!(found, method)
    end
    return byfile
end

# Give every item the methods with its file and a line inside its lines,
# except the methods of `skip`: after the apply, the old methods of a changed
# expression can still sit at lines inside the new one.
function rc_assign_methods!(items::Vector{RcItem}, byfile, skip = Base.IdSet{Method}())
    for item in items
        empty!(item.methods)
        for method in get(byfile, item.path, Method[])
            method in skip && continue
            method.line in item.entry.lines && push!(item.methods, method)
        end
    end
    return nothing
end

# Match the old file list with the new one: `pairs` by path, `renamed` by
# content or as the lone leftover pair, then the removed and the added. A
# file that several modules include is in both lists once per module, in
# include order: its n-th old entry pairs with its n-th new one.
function rc_match_files(old_files::Vector{String}, old_copies::Vector{String},
                        new_files::Vector{String})
    pairs = Tuple{Int, Int}[]
    renamed = Tuple{Int, Int}[]
    old_left = collect(1:length(old_files))
    new_left = Int[]
    for (j, path) in enumerate(new_files)
        k = findfirst(i -> old_files[i] == path, old_left)
        if k === nothing
            push!(new_left, j)
        else
            push!(pairs, (old_left[k], j))
            deleteat!(old_left, k)
        end
    end
    for i in copy(old_left)
        content = read(old_copies[i], String)
        for j in new_left
            read(new_files[j], String) == content || continue
            push!(renamed, (i, j))
            filter!(!=(i), old_left)
            filter!(!=(j), new_left)
            break
        end
    end
    if length(old_left) == 1 && length(new_left) == 1
        push!(renamed, (old_left[1], new_left[1]))
        empty!(old_left)
        empty!(new_left)
    end
    return (pairs = pairs, renamed = renamed, removed = old_left, added = new_left)
end

# ── the classification ──────────────────────────────────────────────────────

# Whether a signature mentions the type named by `typename`, anywhere in it.
function rc_mentions(@nospecialize(t), typename::Core.TypeName)
    t = Base.unwrap_unionall(t)
    if t isa DataType
        t.name === typename && return true
        for p in t.parameters
            p isa Type && rc_mentions(p, typename) && return true
        end
    elseif t isa Union
        return rc_mentions(t.a, typename) || rc_mentions(t.b, typename)
    elseif t isa TypeVar
        return rc_mentions(t.ub, typename)
    end
    return false
end

# The methods of the method table whose signature mentions the type, split by
# whether their file is tracked.
function rc_methods_on_type(@nospecialize(type), tracked::Set{String})
    typename = Base.unwrap_unionall(type).name
    inside = Method[]
    outside = Method[]
    rc_each_live_method() do method
        if rc_mentions(method.sig, typename)
            push!(String(method.file) in tracked ? inside : outside, method)
        end
    end
    return (inside = inside, outside = outside)
end

# Whether a `using` or `import` reaches outside the loaded modules: its first
# name is neither relative, nor a loaded module, nor bound in the module.
function rc_new_dependency(mod::Module, e::Expr)
    for spec in e.args
        spec isa Expr || continue
        path = spec.head === :(:) ? spec.args[1] : spec
        path isa Expr && path.head === :. || continue
        first_name = path.args[1]
        first_name isa Symbol && first_name !== :. || continue
        isdefined(mod, first_name) && continue
        any(Symbol(pkgid.name) === first_name for (pkgid, _) in Base.loaded_modules) && continue
        return first_name
    end
    return nothing
end

# The module that the path of a `using` or `import` names, seen from `mod`:
# `.A.B` is relative to `mod`, `..A` to its parent, `X.Y` starts at a name
# that `mod` binds or at a loaded module. Nothing when the path leads nowhere.
function rc_import_target(mod::Module, path::Expr)
    parts = path.args
    dots = something(findfirst(part -> part !== :., parts), length(parts) + 1) - 1
    target = mod
    rest = parts[(dots + 1):end]
    if dots == 0
        first_name = rest[1]
        first_name isa Symbol || return nothing
        target = isdefined(mod, first_name) && getfield(mod, first_name) isa Module ?
                 getfield(mod, first_name) : rc_module_or_nothing(Symbol[first_name])
        rest = rest[2:end]
    else
        for _ in 2:dots
            target = parentmodule(target)
        end
    end
    for name in rest
        target isa Module && isdefined(target, name) || return nothing
        target = getfield(target, name)
    end
    return target isa Module ? target : nothing
end

# The partition kinds of a name that the module binds by itself: a definition,
# a declaration, or an explicit import. An implicit binding is not among them.
const RC_EXPLICIT_KINDS = (Base.PARTITION_KIND_CONST, Base.PARTITION_KIND_CONST_IMPORT,
                           Base.PARTITION_KIND_GLOBAL, Base.PARTITION_KIND_EXPLICIT,
                           Base.PARTITION_KIND_IMPORTED, Base.PARTITION_KIND_DECLARED,
                           Base.PARTITION_KIND_UNDEF_CONST, Base.PARTITION_KIND_BACKDATED_CONST)

# The explicit names of a `using X: a, b as c` that `mod` binds already from
# another place. Julia ignores such an import, or refuses it.
function rc_import_conflicts(mod::Module, e::Expr)
    conflicts = Symbol[]
    for spec in e.args
        spec isa Expr && spec.head === :(:) || continue
        target = rc_import_target(mod, spec.args[1])
        for entry in spec.args[2:end]
            bound = source = nothing
            if entry isa Expr && entry.head === :.
                bound = source = entry.args[end]
            elseif entry isa Expr && entry.head === :as && entry.args[1] isa Expr
                source = entry.args[1].args[end]
                bound = entry.args[2]
            end
            bound isa Symbol && source isa Symbol || continue
            Base.binding_kind(mod, bound) in RC_EXPLICIT_KINDS || continue
            target !== nothing && isdefined(target, source) &&
                Base.binding_module(mod, bound) === Base.binding_module(target, source) && continue
            push!(conflicts, bound)
        end
    end
    return conflicts
end

# The module that binds each name for `mod`, or nothing.
function rc_resolution(mod::Module, names)
    resolution = Dict{Symbol, Any}()
    for name in names
        resolution[name] = isdefined(mod, name) ? Base.binding_module(mod, name) : nothing
    end
    return resolution
end

rc_content_hash(path) = string(hash(read(path, String)); base = 16)

# The order of an item in the apply: its file, then its first line.
rc_order(item::RcItem) = (item.file, item.entry.lines.start)

function rc_refuse!(refusals, id, item, reason)
    push!(refusals, string(id, " ", rc_where(item), " ", rc_what(item), ": ", reason))
    return nothing
end

# The id and the checks of one changed expression, with the old items of the
# same name. Answer nothing for a refused change.
function rc_classify(item::RcItem, old::Vector{RcItem}, new_roots, tracked, refusals)
    e = item.entry.expr
    heads = ReactiveSourceDiff.macro_heads(e)
    root_file = isempty(new_roots[item.file])
    if root_file && isempty(item.entry.module_path) && item.kind !== :module
        rc_refuse!(refusals, "C5", item, "the top level of a root file outside its module")
        return nothing
    end
    for option in RC_OPTION_MACROS
        option in heads || continue
        rc_refuse!(refusals, "F1", item, string(option, " is a module option"))
        return nothing
    end
    kind = item.kind
    if kind === :other
        if :__precompile__ in ReactiveSourceDiff.all_names(e)
            rc_refuse!(refusals, "F1", item, "__precompile__ is a module option")
            return nothing
        end
        if root_file
            rc_refuse!(refusals, "C5", item, "an expression of another form in a root file")
            return nothing
        end
        return RcChange(Symbol("@eval") in heads ? "D2" : "X", item, old, "")
    end
    if kind === :method
        d = ReactiveSourceDiff.definition(e)
        callable = d isa Expr && d.head in (:function, :(=)) &&
                   d.args[1] isa Expr && d.args[1].head === :call &&
                   d.args[1].args[1] isa Expr && d.args[1].args[1].head === :(::)
        id = Symbol("@generated") in heads || callable ? "A6" : isempty(old) ? "A1" : "A2"
        return RcChange(id, item, old, "")
    end
    kind === :macro && return RcChange("D1", item, old, "")
    mod = rc_module_or_nothing(rc_module_path(new_roots, item))
    if kind === :type
        isempty(old) && return RcChange("B1", item, old, "")
        shape = ReactiveSourceDiff.type_shape(e)
        any(ReactiveSourceDiff.type_shape(o.entry.expr) == shape for o in old) &&
            return RcChange("A2", item, old, "constructors only")
        if mod !== nothing && item.name !== nothing && isdefined(mod, item.name)
            found = rc_methods_on_type(getfield(mod, item.name), tracked)
            for method in found.outside
                rc_refuse!(refusals, "B2", item,
                           string("the untracked ", basename(String(method.file)), ":", method.line,
                                  " ", method.name, " names the type"))
            end
        end
        d = ReactiveSourceDiff.definition(e)
        return RcChange(d isa Expr && d.head === :abstract ? "B3" : "B2", item, old, "")
    end
    kind === :const && return RcChange("C1", item, old, "")
    kind === :global && return RcChange("C2", item, old, "")
    if kind === :using
        dependency = mod === nothing ? nothing : rc_new_dependency(mod, e)
        if dependency !== nothing
            rc_refuse!(refusals, "F3", item, string(dependency, " is not in the image"))
            return nothing
        end
        conflicts = mod === nothing ? Symbol[] : rc_import_conflicts(mod, e)
        if !isempty(conflicts)
            rc_refuse!(refusals, "C3", item, string("the module binds ", join(conflicts, ", "),
                                                    " already; Julia ignores a conflicting import"))
            return nothing
        end
        return RcChange("C3", item, old, "")
    end
    kind === :export && return RcChange("C3", item, old, "")
    if kind === :include
        argument = length(e.args) == 2 ? e.args[2] : nothing
        included = argument isa AbstractString ? normpath(joinpath(dirname(item.path), argument)) : nothing
        if included === nothing || !(included in tracked)
            rc_refuse!(refusals, "C4", item, "includes a file that is not tracked")
            return nothing
        end
        return RcChange("C4", item, old, string("includes ", basename(included)))
    end
    kind === :dependency && return RcChange("E1", item, old, "")
    if kind === :module
        isempty(old) && return RcChange("C5", item, old, "new module")
        rc_refuse!(refusals, "C5", item, "the header of a module changed")
        return nothing
    end
    return RcChange("X", item, old, "")
end

# ── the apply ───────────────────────────────────────────────────────────────

# The queue of changes, kept in file order. A change that joins the queue
# behind the cursor is evaluated in its turn; one that belongs before the
# cursor goes to the end.
mutable struct RcQueue
    changes::Vector{RcChange}
    cursor::Int
    queued::Set{UInt}
end
RcQueue() = RcQueue(RcChange[], 0, Set{UInt}())

function rc_enqueue!(queue::RcQueue, change::RcChange)
    key = objectid(change.item)
    key in queue.queued && return false
    push!(queue.queued, key)
    order = rc_order(change.item)
    position = length(queue.changes) + 1
    for index in (queue.cursor + 1):length(queue.changes)
        if rc_order(queue.changes[index].item) > order
            position = index
            break
        end
    end
    insert!(queue.changes, position, change)
    return true
end

# The apply refuses the changes: the reasons are in the file, and the heap
# is untouched. The rebuild child exits with 3; the server answers `refused`
# and serves the next request.
struct RcRefusal <: Exception
    path::String
end

function rc_stop(refusals, refusal_out)
    for reason in refusals
        println("rc: refuse ", reason)
    end
    write(refusal_out, join(refusals, '\n') * "\n")
    println("rc: refused ", length(refusals), " changes; the founding build applies them")
    flush(stdout)
    throw(RcRefusal(refusal_out))
end

# Compare every tracked file with the stored copy of the previous snapshot,
# classify the changes, refuse what the catalog refuses, and evaluate the
# changes and their dependents in their modules. `old_reads` holds the
# hash of every file that a top-level expression of the previous snapshot
# could read; the new listing is written to `reads_out`. A refusal is written
# to `refusal_out` and the child exits before any evaluation. Answer the set
# of method instances that exist before the trace, and whether the world
# moved.
function rc_apply_tracked(old_files::Vector{String}, old_roots::Vector{Vector{Symbol}},
                          old_copies::Vector{String},
                          new_files::Vector{String}, new_roots::Vector{Vector{Symbol}},
                          old_reads::Vector{Tuple{String, String}},
                          reads_out::String, refusal_out::String)
    rc_warm()
    t0 = time()
    # The old ledger: the one the previous apply of this process left, when
    # the tracked files are the same (a server), else parsed from the stored
    # copies with a walk of the method table.
    cached = RC_LEDGER_CACHE[]
    if cached !== nothing && cached[1] == old_files
        old_items = cached[2]::Vector{RcItem}
    else
        old_items = rc_ledger(old_files, old_copies)
        rc_assign_methods!(old_items, rc_methods_by_file(Set(old_files)))
    end
    RC_LEDGER_CACHE[] = nothing
    new_items = rc_ledger(new_files, new_files)
    match = rc_match_files(old_files, old_copies, new_files)
    t_ledger = time() - t0
    tracked = Set(new_files)
    refusals = String[]
    queue = RcQueue()
    removals = RcChange[]
    line_updates = 0
    # H3: a renamed file keeps its methods, under the new name.
    for (i, j) in match.renamed
        renamed = 0
        for item in old_items
            item.file == i || continue
            item.path = new_files[j]
            for method in item.methods
                setfield!(method, :file, Symbol(new_files[j]))
                renamed += 1
            end
        end
        println("rc: change H3 ", basename(old_files[i]), " -> ", basename(new_files[j]), ", ",
                renamed, " methods renamed")
    end
    # C4: a removed file loses its methods; an added file is evaluated whole.
    for i in match.removed
        methods = Method[m for item in old_items if item.file == i for m in item.methods]
        push!(removals, RcChange("C4", nothing, RcItem[], methods, basename(old_files[i]), "removed file", 0, 0))
    end
    for j in match.added
        for item in new_items
            item.file == j || continue
            rc_enqueue!(queue, RcChange("C4", item, RcItem[], string("new file ", basename(new_files[j]))))
        end
    end
    # The diff of every matched pair.
    for (i, j) in vcat(match.pairs, match.renamed)
        olds = RcItem[item for item in old_items if item.file == i]
        news = RcItem[item for item in new_items if item.file == j]
        old_by_key = Dict{UInt64, RcItem}(item.entry.key => item for item in olds)
        new_keys = Set{UInt64}(item.entry.key for item in news)
        changed = RcItem[]
        for item in news
            old = get(old_by_key, item.entry.key, nothing)
            if old === nothing
                push!(changed, item)
                continue
            end
            # H1: an unchanged expression keeps its methods, at their new lines.
            shift = item.entry.lines.start - old.entry.lines.start
            for method in old.methods
                shift == 0 && break
                setfield!(method, :line, Int32(method.line + shift))
                line_updates += 1
            end
            item.methods = old.methods
        end
        removed = RcItem[item for item in olds if !(item.entry.key in new_keys)]
        # A removed expression that a changed one of the same name and kind
        # replaces is that change's old counterpart; an unnamed expression
        # (an `@eval` loop) pairs with the unnamed changed ones of its module.
        # The rest are removals.
        counterpart(a, b) = a.name === b.name && (a.name !== nothing || a.kind === :other) &&
                            a.entry.module_path == b.entry.module_path &&
                            rc_kind_class(a.kind) === rc_kind_class(b.kind)
        for item in removed
            any(c -> counterpart(c, item), changed) && continue
            if rc_kind_class(item.kind) === :method
                push!(removals, RcChange("A3", nothing, RcItem[item], item.methods,
                                         string(rc_where(item), " ", rc_what(item)), "removed", 0, 0))
            elseif item.kind !== :include
                println("rc: removed ", rc_where(item), " ", rc_what(item), " (", item.kind,
                        "): not applied, the binding stays")
            end
        end
        for item in changed
            old = RcItem[o for o in removed if counterpart(o, item)]
            change = rc_classify(item, old, new_roots, tracked, refusals)
            change === nothing || rc_enqueue!(queue, change)
        end
    end
    # E1: a changed read file re-evaluates the expressions that name it.
    old_hashes = Dict{String, String}(path => h for (path, h) in old_reads)
    new_reads = Tuple{String, String}[]
    for item in new_items
        for path in ReactiveSourceDiff.read_paths(item.entry.expr, dirname(item.path))
            h = rc_content_hash(path)
            push!(new_reads, (path, h))
            get(old_hashes, path, "") == h && continue
            rc_enqueue!(queue, RcChange("E1", item, string("reads ", basename(path))))
        end
    end
    unique!(new_reads)
    # D1: a changed macro re-evaluates every expression that names it, and
    # the macros among those, transitively.
    macro_users = Dict{Symbol, Vector{RcItem}}()
    for item in new_items, name in ReactiveSourceDiff.macro_heads(item.entry.expr)
        push!(get!(macro_users, name, RcItem[]), item)
    end
    pending_macros = Symbol[c.item.name for c in queue.changes if c.item.kind === :macro && c.item.name !== nothing]
    seen_macros = Set(pending_macros)
    while !isempty(pending_macros)
        name = pop!(pending_macros)
        for user in get(macro_users, name, RcItem[])
            rc_enqueue!(queue, RcChange("D1", user, string("expands ", name))) || continue
            if user.kind === :macro && user.name !== nothing && !(user.name in seen_macros)
                push!(seen_macros, user.name)
                push!(pending_macros, user.name)
            end
        end
    end
    isempty(refusals) || rc_stop(refusals, refusal_out)
    # The apply. The removals first, then the queue in file order, with the
    # dependents that each evaluation reveals.
    deleted = 0
    for change in removals
        for method in change.old_methods
            rc_delete_method(method)
            change.deleted += 1
        end
        deleted += change.deleted
        println("rc: change ", change.id, " ", change.where, " (", change.note, "), ",
                change.deleted, " methods deleted")
    end
    # C3: how the names of every expression of a module with a changed
    # `using` resolve before the apply.
    resolutions = Dict{UInt, Dict{Symbol, Any}}()
    for change in queue.changes
        change.item.kind === :using || continue
        module_path = rc_module_path(new_roots, change.item)
        mod = rc_resolve_module(module_path)
        for item in new_items
            rc_module_path(new_roots, item) == module_path || continue
            haskey(resolutions, objectid(item)) && continue
            resolutions[objectid(item)] = rc_resolution(mod, ReactiveSourceDiff.all_names(item.entry.expr))
        end
    end
    replaced = Core.MethodInstance[]
    kept = 0
    world_before = Base.get_world_counter()
    empty!(RC_KEPT)
    rc_install_filter(rc_method_filter)
    t_eval = @elapsed try while queue.cursor < length(queue.changes)
        queue.cursor += 1
        change = queue.changes[queue.cursor]
        item = change.item
        item.kind === :include && continue
        mod = rc_resolve_module(rc_module_path(new_roots, item))
        # The bindings are read at the latest world: this loop moves it.
        old_type = item.kind === :type && item.name !== nothing && Base.invokelatest(isdefined, mod, item.name) ?
                   Base.invokelatest(getfield, mod, item.name) : nothing
        Core.eval(mod, item.entry.expr)
        # A kept method is a method of the new item, at the line the item
        # moved it to; it is neither replaced nor deleted. Every change that
        # names it as an old method loses it: two changes of the same name
        # (a redefinition and a new method) share their old items.
        for method in rc_take_kept!()
            method in change.old_methods || continue
            for other in queue.changes
                filter!(m -> m !== method, other.old_methods)
            end
            for removal in removals
                filter!(m -> m !== method, removal.old_methods)
            end
            change.kept += 1
            kept += 1
            for old in change.old_items
                method.line in old.entry.lines || continue
                shift = item.entry.lines.start - old.entry.lines.start
                shift == 0 || setfield!(method, :line, Int32(method.line + shift))
                break
            end
        end
        for method in change.old_methods, mi in Base.specializations(method)
            mi isa Core.MethodInstance && push!(replaced, mi)
        end
        # The dependents of what the evaluation changed.
        if item.kind === :type && old_type !== nothing && Base.invokelatest(getfield, mod, item.name) !== old_type
            found = rc_methods_on_type(old_type, tracked)
            for method in found.outside
                rc_refuse!(refusals, change.id, item,
                           string("the untracked ", basename(String(method.file)), ":", method.line,
                                  " ", method.name, " names the type (found in the apply)"))
            end
            isempty(refusals) || rc_stop(refusals, refusal_out)
            for dependent in new_items
                dependent === item && continue
                by_name = item.name in ReactiveSourceDiff.type_level_names(dependent.entry.expr)
                by_sig = any(m in found.inside for m in dependent.methods)
                by_name || by_sig || continue
                rc_enqueue!(queue, RcChange(change.id, dependent, string("names ", item.name)))
            end
        elseif item.kind in RC_BINDING_KINDS && item.name !== nothing
            for dependent in new_items
                dependent === item && continue
                item.name in ReactiveSourceDiff.type_level_names(dependent.entry.expr) || continue
                rc_enqueue!(queue, RcChange(change.id, dependent, string("names ", item.name)))
            end
        elseif item.kind === :using
            module_path = rc_module_path(new_roots, item)
            for dependent in new_items
                dependent === item && continue
                rc_module_path(new_roots, dependent) == module_path || continue
                before = get(resolutions, objectid(dependent), nothing)
                before === nothing && continue
                after = Base.invokelatest(rc_resolution, mod, keys(before))
                after == before && continue
                resolutions[objectid(dependent)] = after
                moved = sort!(Symbol[name for (name, m) in after if before[name] !== m])
                rc_enqueue!(queue, RcChange("C3", dependent, string("resolves ", join(moved, ", "), " differently")))
            end
        end
    end finally
        rc_install_filter(nothing)
    end
    world_after = Base.get_world_counter()
    # The new ledger, and the deletion of every old method of a change: the
    # ones without a replacement of the same signature made the change a
    # removal too, the replaced ones are dead entries that would keep a
    # stale line in the next ledger.
    skip = Base.IdSet{Method}()
    for change in vcat(removals, queue.changes), method in change.old_methods
        push!(skip, method)
    end
    rc_assign_methods!(new_items, rc_methods_by_file(tracked), skip)
    RC_LEDGER_CACHE[] = (copy(new_files), new_items)
    # A replacement can sit in another item of the module than the change
    # that holds the old method (two changes of the same name share their
    # old items), so the signatures of every new item count. An old method
    # that two changes share is deleted once.
    new_sigs = Any[m.sig for item in new_items for m in item.methods]
    gone = Base.IdSet{Method}()
    for change in queue.changes
        item = change.item
        replaced_sigs = 0
        for method in change.old_methods
            if any(sig -> sig == method.sig, new_sigs)
                replaced_sigs += 1
            else
                change.deleted += 1
            end
            method in gone && continue
            push!(gone, method)
            rc_delete_method(method)
        end
        deleted += change.deleted
        if change.id in ("A1", "A2")
            change.id = change.deleted > 0 ? "A4" : replaced_sigs > 0 ? "A2" : "A1"
        end
        println("rc: change ", change.id, " ", change.where,
                isempty(change.note) ? "" : string(" (", change.note, ")"),
                ", ", length(item.methods), " methods",
                change.kept > 0 ? string(", ", change.kept, " kept") : "",
                change.deleted > 0 ? string(", ", change.deleted, " deleted") : "")
    end
    open(reads_out, "w") do io
        for (path, h) in new_reads
            println(io, h, " ", path)
        end
    end
    closed = Core.MethodInstance[]
    before = Base.IdSet{Core.MethodInstance}()
    t_scan = @elapsed rc_each_instance() do mi
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
        Core.println("rc: cone replaced ", mi.specTypes)
    end
    for mi in closed
        Core.println("rc: cone closed ", mi.specTypes)
    end
    println("rc: applied ", length(queue.changes), " expressions and ", length(removals), " removals in ",
            round(1e3 * t_eval, digits = 1), " ms, ", kept, " methods kept, ", deleted, " methods deleted, ", line_updates,
            " lines updated, world ", world_before, " -> ", world_after, "; ledger ",
            round(t_ledger, digits = 2), " s; cone ", length(replaced), " replaced, ", length(closed),
            " closed; scan ", round(t_scan, digits = 2), " s")
    return (before = before, moved = world_after > world_before)
end

# ── the trace ───────────────────────────────────────────────────────────────

# Precompile one statement of a trace in `staging`: the signature is evaluated
# there, and a module that the statement names and the staging module does
# not bind is taken from the loaded modules by its name. Answer whether the
# statement precompiled: a signature without a method answers false.
# The signature of a statement that resolved once, by its text: a server
# precompiles the same trace on every apply, and the parse and the
# evaluation of the signature cost more than the precompile.
const RC_TRACE_CACHE = Dict{String, Type}()

# The C printer of `--trace-compile` (`jl_static_show`) prints a struct in
# a type parameter with its field names, `Rational{Int64}(num=1, den=2)`,
# which no constructor accepts; the printer of a refresh, Julia's `show`,
# prints it positional. The rewrite makes the first form the second: a call
# whose arguments are all keywords becomes the call of their values, in the
# order printed, which is the order of the fields.
function rc_positional(ex)
    ex isa Expr || return ex
    if ex.head === :call && length(ex.args) > 1 && all(a -> Meta.isexpr(a, :kw, 2), ex.args[2:end])
        return Expr(:call, rc_positional(ex.args[1]), (rc_positional(a.args[2]) for a in ex.args[2:end])...)
    end
    return Expr(ex.head, (rc_positional(a) for a in ex.args)...)
end

# The statements that did not resolve, for the session: a module that the
# image does not load, a form that no constructor accepts. An edit of a
# tracked file changes none of that; a founding starts a new session.
const RC_TRACE_FAILED = Set{String}()

function rc_precompile_statement(staging::Module, line::String)
    cached = get(RC_TRACE_CACHE, line, nothing)
    cached === nothing || return precompile(cached)
    line in RC_TRACE_FAILED && return false
    resolved = rc_resolve_statement(staging, line)
    resolved || push!(RC_TRACE_FAILED, line)
    return resolved
end

function rc_resolve_statement(staging::Module, line::String)
    ex = try
        rc_positional(Meta.parse(line))
    catch
        return false
    end
    Meta.isexpr(ex, :call) && length(ex.args) == 2 || return false
    while true
        value = try
            Core.eval(staging, ex.args[2])
        catch e
            e isa UndefVarError || return false
            name = e.var
            found = Module[loaded for (pkgid, loaded) in Base.loaded_modules
                           if Symbol(pkgid.name) === name]
            length(found) == 1 || return false
            Core.eval(staging, :(const $name = $(found[1])))
            continue
        end
        value isa Type || return false
        RC_TRACE_CACHE[line] = value
        return precompile(value)
    end
end

# Precompile every statement of the trace file: a statement that the image
# compiles is a lookup, a statement that the edit invalidated infers its cone
# again, and the codegen at the write of the image compiles what inference
# made. Nothing of the program runs. Answer the statements that precompiled
# and the ones that did not; the ones that did not are listed in the
# `.unresolved` file beside the trace, and the first few are printed.
function rc_precompile_trace(path::String; prefix::String = "rc: trace")
    staging = Module()
    resolved = String[]
    unresolved = String[]
    t = @elapsed for line in eachline(path)
        startswith(line, "precompile(") || continue
        push!(rc_precompile_statement(staging, line) ? resolved : unresolved, line)
    end
    listing = path * ".unresolved"
    if isempty(unresolved)
        rm(listing; force = true)
    else
        write(listing, join(unresolved, '\n') * "\n")
        for line in unresolved[1:min(end, 10)]
            Core.println(prefix, " unresolved ", line)
        end
        length(unresolved) > 10 && Core.println(prefix, " unresolved ", length(unresolved) - 10,
                                                " more, listed in ", listing)
    end
    println(prefix, " ", length(resolved), " statements precompiled, ", length(unresolved),
            " unresolved, ", round(t; digits = 2), " s")
    return (resolved = resolved, unresolved = unresolved)
end

# The refresh: write the statements of the trace that still precompile from
# this image to `kept_file`, one per line.
function rc_keep_statements(path::String, kept_file::String)
    kept = rc_precompile_trace(path).resolved
    write(kept_file, join(kept, '\n') * (isempty(kept) ? "" : "\n"))
    return length(kept)
end

# Count every method instance that the trace made. Print each one only
# after an edit; only the cone of an edit is compared with the delta.
function rc_report_new(state)
    new = Core.MethodInstance[]
    t_scan = @elapsed rc_each_instance(mi -> mi in state.before || push!(new, mi))
    if state.moved
        for mi in new
            Core.println("rc: cone new ", mi.specTypes)
        end
    end
    println("rc: new ", length(new), " method instances after the trace, scan ",
            round(t_scan, digits = 2), " s")
end

# ── the warm-up ─────────────────────────────────────────────────────────────

# Warm the code paths of the ledger, the diff, the trace and the method
# filter on synthetic input, so that the first real edit does not put the
# machinery itself into the cone that the report counts. The argument types
# copy the real calls exactly. The warm-up leaves nothing in the image: the
# only methods it defines are deleted at the end.
function rc_warm()
    staging = Module()
    rc_precompile_statement(staging, "precompile(Tuple{typeof(Base.identity), Int64})") ||
        error("rc_warm: the statement of identity did not precompile")
    rc_precompile_statement(staging, "precompile(Tuple{typeof(Base.identity), Nothing, Nothing})") &&
        error("rc_warm: a statement without a method precompiled")
    rc_precompile_statement(staging, "precompile(Tuple{typeof(NoSuchModule.f)})") &&
        error("rc_warm: a statement of no module precompiled")
    rc_precompile_statement(staging, "precompile(") && error("rc_warm: an unparsable statement precompiled")
    # Neither temporary path is registered for the exit cleanup: a
    # registered path stays in the image (Base.Filesystem.TEMP_CLEANUP).
    warm_trace = tempname(; cleanup = false) * "-warm-trace.jl"
    write(warm_trace, "precompile(Tuple{typeof(Base.identity), Int64})\n" *
                      "precompile(Tuple{typeof(Base.identity), Nothing, Nothing})\n")
    warmed = rc_precompile_trace(warm_trace; prefix = "rc: warm trace")
    length(warmed.resolved) == 1 && length(warmed.unresolved) == 1 ||
        error("rc_warm: the warm trace answered ", length(warmed.resolved), " resolved and ",
              length(warmed.unresolved), " unresolved")
    isfile(warm_trace * ".unresolved") || error("rc_warm: the warm trace wrote no listing")
    rm(warm_trace * ".unresolved")
    rm(warm_trace)
    # The ledger of a synthetic pair of files, without evaluation. The module
    # has a docstring: the ledger descends into a documented module too.
    dir = mktempdir(; cleanup = false)
    old_path = joinpath(dir, "warm.jl")
    new_path = joinpath(dir, "warm2.jl")
    write(old_path, "f() = 1\n\"doc\"\nmodule M\nstruct P; x::Int; end\ng(p::P) = p.x\nconst C = P(1)\n" *
                    "macro m(e) :(\$e + 1) end\nh() = @m 1\nusing Base: sin\nend\n")
    write(new_path, "\nf() = 2\n\"doc\"\nmodule M\nstruct P; x::Int; y::Int; end\ng(p::P) = p.x\nconst C = P(1, 2)\n" *
                    "macro m(e) :(\$e + 2) end\nh() = @m 1\nusing Base: cos\ninclude(\"none.jl\")\nend\n")
    old_items = rc_ledger([old_path], [old_path])
    new_items = rc_ledger([new_path], [new_path])
    length(old_items) == 8 && length(new_items) == 9 ||
        error("rc_warm: the ledgers hold ", length(old_items), " and ", length(new_items), " items")
    match = rc_match_files([old_path], [old_path], [new_path])
    length(match.renamed) == 1 || error("rc_warm: the lone leftover pair is not a rename")
    match = rc_match_files([old_path, old_path], [old_path, old_path], [old_path, old_path])
    match.pairs == [(1, 1), (2, 2)] || error("rc_warm: a file of two modules pairs as ", match.pairs)
    kinds = [item.kind for item in new_items]
    kinds == [:method, :module, :type, :method, :const, :macro, :method, :using, :include] ||
        error("rc_warm: the kinds are ", kinds)
    old_by_key = Dict{UInt64, RcItem}(item.entry.key => item for item in old_items)
    changed = RcItem[item for item in new_items if !haskey(old_by_key, item.entry.key)]
    length(changed) == 6 || error("rc_warm: ", length(changed), " changed items")
    :P in ReactiveSourceDiff.type_level_names(new_items[4].entry.expr) ||
        error("rc_warm: the signature of g does not name P")
    Symbol("@m") in ReactiveSourceDiff.macro_heads(new_items[7].entry.expr) ||
        error("rc_warm: h does not name @m")
    ReactiveSourceDiff.type_shape(old_items[3].entry.expr) == ReactiveSourceDiff.type_shape(new_items[3].entry.expr) &&
        error("rc_warm: the shapes of P are equal")
    isempty(ReactiveSourceDiff.read_paths(new_items[9].entry.expr, dir)) ||
        error("rc_warm: an include is a read")
    refusals = String[]
    tracked = Set([new_path])
    roots = [Symbol[:Base]]
    queue = RcQueue()
    for item in changed
        old = RcItem[o for o in old_items if o.name === item.name && o.name !== nothing]
        change = rc_classify(item, old, roots, tracked, refusals)
        change === nothing || rc_enqueue!(queue, change)
    end
    length(refusals) == 1 && startswith(refusals[1], "C4") ||
        error("rc_warm: the refusals are ", refusals)
    ids = [change.id for change in queue.changes]
    ids == ["A2", "B2", "C1", "D1", "C3"] || error("rc_warm: the ids are ", ids)
    rc_resolution(Base, [:sin, :nosuchname])[:sin] === Base || error("rc_warm: sin does not resolve in Base")
    rc_new_dependency(Base, :(using NoSuchPackage)) === :NoSuchPackage ||
        error("rc_warm: a new dependency is not seen")
    rc_new_dependency(Base, :(using .Math: sin)) === nothing || error("rc_warm: a relative path is a dependency")
    rc_import_target(Base, Expr(:., :Core, :Intrinsics)) === Core.Intrinsics ||
        error("rc_warm: Core.Intrinsics is not an import target")
    rc_import_target(Base.Math, Expr(:., :., :., :Math)) === Base.Math ||
        error("rc_warm: ..Math is not an import target from Base.Math")
    rc_import_conflicts(Base, :(using Core: Int)) == Symbol[] || error("rc_warm: Int conflicts in Base")
    rc_import_conflicts(Base, :(using Core.Intrinsics: sin)) == [:sin] || error("rc_warm: sin does not conflict in Base")
    rc_mentions(Tuple{typeof(sin), Vector{Int}}, Base.unwrap_unionall(Vector).name) ||
        error("rc_warm: the signature does not mention Vector")
    rc_content_hash(new_path)
    rm(dir; recursive = true)
    # Warm both branches of the module resolver: a name that Main binds, and
    # one that only the loaded modules hold.
    rc_resolve_module(Symbol[:Base]) === Base || error("rc_warm: Base did not resolve")
    rc_resolve_module(Symbol[]) === Main || error("rc_warm: the empty path is not Main")
    for (pkgid, loaded) in Base.loaded_modules
        loaded_name = Symbol(pkgid.name)
        isdefined(Main, loaded_name) && continue
        rc_resolve_module(Symbol[loaded_name]) === loaded ||
            error("rc_warm: the loaded module ", loaded_name, " did not resolve")
        break
    end
    # The method filter: an identical redefinition keeps the method and the
    # world, a changed one does not.
    warm = Module(:RcWarm)
    warm_loop(three) = Meta.parse("for (name, k) in ((:two, 2), (:three, $three)); @eval \$name(x) = \$k * x; end")
    Core.eval(warm, warm_loop(3))
    warm_two = only(methods(Base.invokelatest(getfield, warm, :two)))
    warm_three = only(methods(Base.invokelatest(getfield, warm, :three)))
    world = Base.get_world_counter()
    rc_install_filter(rc_method_filter)
    try
        Core.eval(warm, warm_loop(30))
    finally
        rc_install_filter(nothing)
    end
    warm_kept = rc_take_kept!()
    warm_kept == [warm_two] || error("rc_warm: the filter kept ", length(warm_kept), " methods")
    only(methods(Base.invokelatest(getfield, warm, :two))) === warm_two ||
        error("rc_warm: the filter did not keep two")
    warm_three_new = only(methods(Base.invokelatest(getfield, warm, :three)))
    warm_three_new !== warm_three || error("rc_warm: the filter kept three")
    Base.invokelatest(Base.invokelatest(getfield, warm, :three), 1) == 30 || error("rc_warm: the filter kept three")
    Base.get_world_counter() == world + 1 || error("rc_warm: the world moved by ", Base.get_world_counter() - world)
    # The warm module must not reach the image. Its methods are deleted, the
    # replaced `three` too: a deletion closes the entry, and the serializer of
    # a reactive image drops a closed entry with its method, its
    # specializations and their code (staticdata.c). Nothing else roots the
    # module: the `using` backedges of Base and Core and the scanned-method
    # list of the module are weak lists in a reactive image (staticdata.c), so
    # neither `using Base` nor the compiled `three` keeps it. A kept module
    # would grow the image by its heap and by the two text functions of
    # `three(Int64)` on every rebuild.
    for method in (warm_two, warm_three, warm_three_new)
        rc_delete_method(method)
    end
    println("rc: warm ", length(changed), " changed items, ", length(refusals), " refusals, ",
            length(warm_kept), " methods kept")
end
