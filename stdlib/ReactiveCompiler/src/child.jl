# The apply of an edit: the definitions that the rebuild child of a store
# and the compiler server run.
#
# This file is part of the system image, so a rebuild that boots from the
# previous image finds the harness compiled, and the delta of an edit holds
# the cone of the edit and nothing of this machinery. A store whose image
# holds the sources that its client has runs the harness of the image. For a
# store whose image holds other sources, the client loads its sources into a
# module of their own, and that module applies the edit; it deletes its
# methods before the image is written (`rc_remove_harness!`), so a change of
# this file reaches a store with its next rebuild.
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
#      the method table that the entry defined: a method keeps the file and
#      the first line of the top-level expression that defined it;
#   2. the match of the two file lists: by path, then by content (a renamed
#      file), then a lone leftover pair (a renamed and edited file);
#   3. the diff of each matched pair by key, and the classification of every
#      changed or removed entry with an id of the change catalog of
#      `plan/pending/robust-incremental-compiler.md`; a refusal stops here;
#   4. the statements (`rc_statement_group!`): a statement that the edit
#      changed or removed did something that the apply must take back, so the
#      definitions of the globals that it names join the changes, and each
#      statement that names them runs again;
#   5. the replay (`replay.jl`): a fork of the process applies the changes,
#      and names each expression whose text stays and whose evaluation gives
#      another result after them, or at the place that the edit moved it to;
#      these join the changes;
#   6. the apply, in the load order (`RcLoadOrder`): the removals delete
#      their methods first, then every change is evaluated in its module,
#      and the dependents that the evaluation reveals (the expressions that
#      name a changed type, a changed binding or a changed macro, or whose
#      names resolve differently after a changed `using`) join the queue;
#   7. the new ledger: the methods of every new entry, from the method table
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
# The ledger of the last apply of this process: the file list, and the items
# with their methods of each file of the list that the apply parsed, by its
# index. The next apply of the same file list takes a file's old items from
# it (a server applies many edits).
const RC_LEDGER_CACHE = Ref{Any}(nothing)

# The entries of the last parse of each tracked file, by path, with the text
# they come from: a file whose text is the same at a later ledger of this
# process takes its entries without a parse. A store tracks the path
# packages of its Manifest, a thousand files, and an edit changes one.
const RC_PARSED = Dict{String, Tuple{String, Vector{ReactiveSourceDiff.Entry}}}()

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

# ── the storage of the task ─────────────────────────────────────────────────

# Call `f` with an empty storage of the task, and give the task its storage
# back after it. A program can keep values in the storage of the task that runs
# it (`task_local_storage`), as a stack of what it computes now. A start of the
# program finds that storage empty. A server evaluates many edits in one task,
# so each part of an apply that evaluates the program at one state of its code
# gets an empty storage: a value of a type of before an edit never meets the
# code of after it there.
function rc_with_empty_task_storage(f)
    task = current_task()
    storage = task.storage
    task.storage = nothing
    try
        return f()
    finally
        task.storage = storage
    end
end

# ── the ids of the log statements ───────────────────────────────────────────

# Call `f` with an empty registry of log ids, and give the registry its content
# back after it. A log macro gives its statement an id from the hash of its
# module, its level and its message, and takes the next number when the
# registry of the process holds that id (`Base.CoreLogging.log_record_id`). A
# whole build expands a statement one time, in the process that compiles its
# package. A server expands it at each evaluation, and the replay at each
# print, so the id would count the expansions. The evaluations of one apply
# share one registry, as the forms of a package do; each print of the replay
# has its own. Two statements of one package with the same module, level and
# message keep one id when only one of them is evaluated again: a whole build
# gives the second one the next number.
function rc_with_fresh_log_ids(f)
    ids = Base.CoreLogging._log_record_ids
    saved = copy(ids)
    empty!(ids)
    try
        return f()
    finally
        empty!(ids)
        union!(ids, saved)
    end
end

# ── the method filter ───────────────────────────────────────────────────────

# The methods that the filter kept in place of an identical redefinition
# since the last `rc_take_kept!`.
const RC_KEPT = Method[]

# The filter that `jl_method_def` asks before it inserts `m`: answer true to
# keep the method of the table with the same signature in the same module
# whose lowered code is the same. The definition would move the world and
# invalidate every caller of the method for nothing: an `@eval` loop with
# one changed method, or a dependent whose expansion did not change. The
# line table is not compared: the kept method keeps its own. The kept method
# stands for the definition of now, so it takes the two places of `m`: the
# file and the line of its text, and those of the top-level expression that
# defines it.
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
    setfield!(old, :file, m.file)
    setfield!(old, :line, m.line)
    setfield!(old, :toplevel_file, m.toplevel_file)
    setfield!(old, :toplevel_line, m.toplevel_line)
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

# Delete a method. The method of the generator of a generated method is a
# method of the item that defines the generated one, so the item deletes it
# with its other methods. A generator method with no top-level place has no
# item, and nothing calls it once the method is gone: it goes here.
function rc_delete_method(method::Method)
    Base.delete_method(method)
    isdefined(method, :generator) && method.generator isa Core.GeneratedFunctionStub || return
    for gen_method in methods(method.generator.gen)
        gen_method.toplevel_file === Symbol("") && Base.delete_method(gen_method)
    end
end

# ── the ledger ──────────────────────────────────────────────────────────────

# The items of every file of `files`, read from `texts` (the stored copies
# for the old ledger, the files themselves for the new one). The parse names
# the real file, and a text that `RC_PARSED` holds is not parsed again.
function rc_ledger(files::Vector{String}, texts::Vector{String})
    items = RcItem[]
    for (index, path) in enumerate(files)
        append!(items, rc_file_items(index, path, texts[index]))
    end
    return items
end

# The items of the file `path` at `index` of its list, read from `text_path`.
function rc_file_items(index::Int, path::String, text_path::String)
    text = read(text_path, String)
    parsed = get(RC_PARSED, path, nothing)
    if parsed === nothing || parsed[1] != text
        parsed = (text, ReactiveSourceDiff.file_entries(text, path))
        RC_PARSED[path] = parsed
    end
    return RcItem[RcItem(index, path, entry, ReactiveSourceDiff.entry_kind(entry.expr),
                         ReactiveSourceDiff.defined_name(entry.expr), Method[]) for entry in parsed[2]]
end

# The old items of the files at `indices` of `old_files`: from the ledger of
# the last apply when it has the file, else parsed from the stored copy, with
# the methods of the method table. Also the ledger of the last apply by index.
function rc_old_items(old_files::Vector{String}, old_copies::Vector{String}, indices)
    cached = RC_LEDGER_CACHE[]
    byindex = cached !== nothing && cached[1] == old_files ? cached[2]::Dict{Int, Vector{RcItem}} :
              Dict{Int, Vector{RcItem}}()
    items = RcItem[]
    parsed = RcItem[]
    for i in indices
        found = get(byindex, i, nothing)
        if found === nothing
            found = rc_file_items(i, old_files[i], old_copies[i])
            append!(parsed, found)
        end
        append!(items, found)
    end
    isempty(parsed) || rc_assign_methods!(parsed, rc_methods_by_definer(Set(item.path for item in parsed)))
    return items, byindex
end

# The new items of the files at `indices` of `new_files`.
rc_new_items(new_files::Vector{String}, indices) =
    RcItem[item for j in indices for item in rc_file_items(j, new_files[j], new_files[j])]

# Whether the edit changes something that the apply evaluates: an expression
# that one ledger has and the other has not, an expression at another place
# that holds a macro call (see `rc_is_moved_macro_user`), or a read file with
# another content. Such an apply takes the items of every file, because a
# dependent of a change and a candidate of the replay can be in any file. An
# edit of the comments and of the blank lines that moves no macro call changes
# nothing: the apply moves the lines of the methods of the changed files, and
# reads no other file. `pair_of_new` maps a new file index to its old one.
function rc_has_change(old_items, new_items, pair_of_new::Dict{Int, Int}, old_reads)
    old_by_key = Dict{Tuple{Int, UInt64}, RcItem}((item.file, item.entry.key) => item for item in old_items)
    new_keys = Set{Tuple{Int, UInt64}}((get(pair_of_new, item.file, 0), item.entry.key) for item in new_items)
    keys(old_by_key) == new_keys || return true
    for item in new_items
        old = old_by_key[(pair_of_new[item.file], item.entry.key)]
        rc_is_moved_macro_user(item, old.entry.lines.start, old.path) && return true
    end
    return any(((path, h),) -> !isfile(path) || rc_content_hash(path) != h, old_reads)
end

# Whether `item`, an expression that the edit leaves as it is, is at another
# place than before the edit, when it started at the line `old_start` of the
# file `old_path`, and holds a macro call outside a docstring. A macro can put
# the place of its call into its expansion, as a log macro does with the line,
# so the replay compares the expansions of the two places
# (`rc_moved_difference`).
rc_is_moved_macro_user(item::RcItem, old_start::Int, old_path::String) =
    (item.entry.lines.start != old_start || item.path != old_path) && item.kind in RC_CANDIDATE_KINDS &&
    !isempty(ReactiveSourceDiff.macro_heads(ReactiveSourceDiff.without_docstrings(item.entry.expr)))

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

# A method has two places. Its *definer* is the top-level expression whose
# evaluation defined it (`toplevel_file`, `toplevel_line`): the item that owns
# the method, which deletes or replaces it. Its *text* is where its code is
# written (`file`, `line`): the line table needs it, and it moves with the
# item that holds it. The two differ for a method that the expansion of a
# macro defines: its text is in the macro, and its definer is the user.

# The live methods of the method table that a top-level expression of one of
# the files `paths` defined, by file.
function rc_methods_by_definer(paths)
    byfile = Dict{String, Vector{Method}}(path => Method[] for path in paths)
    rc_each_live_method() do method
        found = get(byfile, String(method.toplevel_file), nothing)
        found === nothing || push!(found, method)
    end
    return byfile
end

# The live methods of the method table whose text is in one of the files
# `paths`, by file.
function rc_methods_by_text(paths)
    byfile = Dict{String, Vector{Method}}(path => Method[] for path in paths)
    rc_each_live_method() do method
        found = get(byfile, String(method.file), nothing)
        found === nothing || push!(found, method)
    end
    return byfile
end

# Give every item the methods that it defined: those whose top-level place is
# the file and the first line of the item, except the methods of `skip`.
# After the apply, the old methods of a changed expression still have the
# place of the expression, when its first line stayed.
function rc_assign_methods!(items::Vector{RcItem}, bydefiner, skip = Base.IdSet{Method}())
    for item in items
        empty!(item.methods)
        for method in get(bydefiner, item.path, Method[])
            method in skip && continue
            method.toplevel_line == item.entry.lines.start && push!(item.methods, method)
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
# whether a top-level expression of a tracked file defined them. A method that
# the expansion of a macro of another package defines for a tracked expression
# is inside: the apply evaluates that expression again.
function rc_methods_on_type(@nospecialize(type), tracked::Set{String})
    typename = Base.unwrap_unionall(type).name
    inside = Method[]
    outside = Method[]
    rc_each_live_method() do method
        if rc_mentions(method.sig, typename)
            push!(String(method.toplevel_file) in tracked ? inside : outside, method)
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
                rc_resolved(mod, bound) === rc_resolved(target, source) && continue
            push!(conflicts, bound)
        end
    end
    return conflicts
end

# What `name` is for `mod`: nothing when `mod` has no such name, the value of
# a constant, and for a global the module that binds it. Two modules that give
# a function or a type of the same name give two values, so the value says
# which one the name is. A module can take one constant from several modules,
# and then no single module binds the name.
function rc_resolved(mod::Module, name::Symbol)
    isdefined(mod, name) || return nothing
    isconst(mod, name) && return getglobal(mod, name)
    return Base.binding_module(mod, name)
end

# What each name is for `mod` (`rc_resolved`).
function rc_resolution(mod::Module, names)
    resolution = Dict{Symbol, Any}()
    for name in names
        resolution[name] = rc_resolved(mod, name)
    end
    return resolution
end

rc_content_hash(path) = string(hash(read(path, String)); base = 16)

# The load order of the apply: a key for each tracked file, which the key of
# an item of the file extends with the first line of the item. Two keys
# compare from left to right, and a key that begins another comes first.
#
# The first number is the rank of the package of the file in the load order
# of this process, `Base.loaded_modules_order`: Julia loads a package after
# the packages that it loads. A package that is not loaded comes after every
# loaded one; no loaded module can name it (F3).
#
# When the ledger holds every tracked file, the next numbers are the lines of
# the includes from the root file of the package down to the file, so the
# items of an included file come at the line of its include. A file whose
# include the ledger does not hold comes after the other files of its
# package, in the order of the list. When the ledger holds the changed files
# alone, no expression changed (see `rc_has_change`), the queue stays empty,
# and the next number is the index of the file in the list.
struct RcLoadOrder
    keys::Vector{Tuple{Vararg{Int}}}
end

rc_order(order::RcLoadOrder, item::RcItem) = (order.keys[item.file]..., item.entry.lines.start)

# The package of a tracked file: the first name of its module, or for a root
# file, which `tracked_sources` finds at `src/<package>.jl`, its name.
rc_package_name(file::String, root::Vector{Symbol}) =
    isempty(root) ? Symbol(splitext(basename(file))[1]) : root[1]

function rc_load_order(files::Vector{String}, roots::Vector{Vector{Symbol}}, items::Vector{RcItem},
                       every_file::Bool)
    ranks = Dict{Symbol, Int}()
    for (index, mod) in enumerate(Base.loaded_modules_order)
        get!(ranks, nameof(mod), index)
    end
    unloaded = length(Base.loaded_modules_order) + 1
    rank(j) = get(ranks, rc_package_name(files[j], roots[j]), unloaded)
    every_file || return RcLoadOrder(Tuple{Vararg{Int}}[(rank(j), j) for j in eachindex(files)])
    index_of = Dict{String, Int}(file => j for (j, file) in enumerate(files))
    parents = Dict{Int, Tuple{Int, Int}}()
    for item in items
        item.kind === :include || continue
        e = item.entry.expr
        length(e.args) == 2 || continue
        mod = rc_module_or_nothing(rc_module_path(roots, item))
        included = rc_include_path(e.args[2], item.path, mod)
        j = included === nothing ? nothing : get(index_of, included, nothing)
        j === nothing || (parents[j] = (item.file, item.entry.lines.start))
    end
    keys = Tuple{Vararg{Int}}[]
    for j in eachindex(files)
        lines = Int[]
        k = j
        while !isempty(roots[k]) && haskey(parents, k) && length(lines) < length(files)
            k, line = parents[k]
            pushfirst!(lines, line)
        end
        if isempty(roots[k])
            push!(keys, (rank(j), lines...))
        else
            println("rc: order: no include of ", basename(files[j]))
            push!(keys, (rank(j), typemax(Int), j))
        end
    end
    return RcLoadOrder(keys)
end

function rc_refuse!(refusals, id, item, reason)
    push!(refusals, string(id, " ", rc_where(item), " ", rc_what(item), ": ", reason))
    return nothing
end

# The functions of a path that the walk of the tracked files computes.
const RC_PATH_FUNCTIONS = (joinpath = joinpath, normpath = normpath, abspath = abspath,
                           dirname = dirname)

# The file that an `include` in `file` names, by the rules of the walk of the
# tracked files (`tracked_sources` of PackageCompiler): a string, `@__DIR__`,
# `@__FILE__`, and `joinpath`, `normpath`, `abspath` and `dirname` of those, and
# the name of a `const` of `mod` that holds a `String`. The module is loaded, so
# its `const` holds the path that the walk computes from its definition. Nothing
# for every other form.
function rc_include_path(argument, file::String, mod)
    path = rc_static_path(argument, file, mod)
    return path === nothing ? nothing : normpath(joinpath(dirname(file), path))
end

function rc_static_path(x, file::String, mod)
    x isa AbstractString && return String(x)
    if x isa Symbol
        mod isa Module && isdefined(mod, x) && isconst(mod, x) || return nothing
        value = getglobal(mod, x)
        return value isa String ? value : nothing
    end
    x isa Expr || return nothing
    if x.head === :macrocall
        x.args[1] === Symbol("@__DIR__") && return dirname(file)
        x.args[1] === Symbol("@__FILE__") && return file
        return nothing
    end
    x.head === :call && !isempty(x.args) && x.args[1] isa Symbol || return nothing
    f = get(RC_PATH_FUNCTIONS, x.args[1], nothing)
    f === nothing && return nothing
    parts = String[]
    for argument in x.args[2:end]
        part = rc_static_path(argument, file, mod)
        part === nothing && return nothing
        push!(parts, part)
    end
    try
        return f(parts...)::String
    catch
        return nothing
    end
end

# A module header split into its docstring and the module with the empty body:
# `doc` and `source` are `nothing` for a header without a docstring. A header
# under another macro keeps the macro in `bare`.
function rc_split_module_doc(header)
    if header isa Expr && header.head === :macrocall && length(header.args) == 4 &&
       (header.args[1] == GlobalRef(Core, Symbol("@doc")) || header.args[1] === Symbol("@doc")) &&
       ReactiveSourceDiff.is_module(header.args[4])
        return (doc = header.args[3], source = header.args[2], bare = header.args[4])
    end
    return (doc = nothing, source = nothing, bare = header)
end

# Whether two module headers differ only in the docstring.
function rc_is_module_doc_change(old_header, new_header)
    old_split = rc_split_module_doc(old_header)
    new_split = rc_split_module_doc(new_header)
    return ReactiveSourceDiff.is_module(old_split.bare) && ReactiveSourceDiff.is_module(new_split.bare) &&
           ReactiveSourceDiff.strip_lines(old_split.bare) == ReactiveSourceDiff.strip_lines(new_split.bare)
end

# H2 of a module: the docstring of `header` replaces the docstring of the loaded
# module `target`, which stays the same object. The expression is the one of
# `Base.Docs.moduledoc` for a module that exists, so the binding and the metadata
# are the ones that the definition of the module gives; it names the module, and
# a module binds its own name. The old entry goes first, so `doc!` replaces no
# docstring, and a header without a docstring removes it.
function rc_set_module_doc!(target::Module, header)
    split = rc_split_module_doc(header)
    docs = Base.Docs.meta(target; autoinit = false)
    docs === nothing || delete!(docs, Base.Docs.Binding(target, nameof(target)))
    split.doc === nothing && return nothing
    docex = Base.Docs.docm(split.source, parentmodule(target), split.doc, split.bare, false)
    docex isa Expr && docex.head === :escape && (docex = docex.args[1])
    Core.eval(target, docex)
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
        # A whole build makes the C entry of a `@ccallable` function, by the
        # name of the function. With another signature, the program would
        # keep the entry of before.
        if Symbol("@ccallable") in heads && !isempty(old) && d isa Expr && !isempty(d.args)
            signature_of(x) = x isa Expr && !isempty(x.args) ? ReactiveSourceDiff.strip_lines(x.args[1]) : nothing
            now = signature_of(d)
            if all(o -> signature_of(ReactiveSourceDiff.definition(o.entry.expr)) != now, old)
                rc_refuse!(refusals, "A4", item,
                           "the signature of a @ccallable function changed, and a whole build makes its C entry")
                return nothing
            end
        end
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
        return RcChange("C3", item, old, "")
    end
    kind === :export && return RcChange("C3", item, old, "")
    if kind === :include
        included = length(e.args) == 2 ? rc_include_path(e.args[2], item.path, mod) : nothing
        if included === nothing || !(included in tracked)
            rc_refuse!(refusals, "C4", item, "includes a file that is not tracked")
            return nothing
        end
        return RcChange("C4", item, old, string("includes ", basename(included)))
    end
    kind === :dependency && return RcChange("E1", item, old, "")
    if kind === :module
        isempty(old) && return RcChange("C5", item, old, "new module")
        # H2: the change keeps the loaded module, so it takes no old method: the
        # methods at the line of the old header stay.
        all(o -> rc_is_module_doc_change(o.entry.expr, e), old) &&
            return RcChange("H2", item, RcItem[], "the docstring of the module")
        rc_refuse!(refusals, "C5", item, "the header of a module changed")
        return nothing
    end
    return RcChange("X", item, old, "")
end

# ── the apply ───────────────────────────────────────────────────────────────

# Whether the process holds an apply that no save wrote: an apply that began to
# change the process and did not end, or one that ended and whose image is not
# written yet. A server whose request fails in that state exits, because its
# heap is then not the image of its last save (decision D4).
const RC_APPLY_OPEN = Ref(false)

# The queue of changes, kept in the load order. A change that joins the queue
# behind the cursor is evaluated in its turn; one that belongs before the
# cursor goes to the end.
mutable struct RcQueue
    changes::Vector{RcChange}
    cursor::Int
    queued::Set{UInt}
    order::RcLoadOrder
end
RcQueue(order::RcLoadOrder) = RcQueue(RcChange[], 0, Set{UInt}(), order)

function rc_enqueue!(queue::RcQueue, change::RcChange)
    key = objectid(change.item)
    key in queue.queued && return false
    push!(queue.queued, key)
    order = rc_order(queue.order, change.item)
    position = length(queue.changes) + 1
    for index in (queue.cursor + 1):length(queue.changes)
        if rc_order(queue.order, queue.changes[index].item) > order
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

# The statements of an edit whose effect the apply takes back (see
# `rc_statement_group!`).
#   definitions  - the definitions of the tracked globals that the statements
#                  name, which the apply evaluates again
#   old          - the statements of before the edit that the edit changed or
#                  removed, as items of the new file list
#   new          - the statements of the edit that replace them
struct RcStatementGroup
    definitions::Vector{RcItem}
    old::Vector{RcItem}
    new::Vector{RcItem}
end

# ── the names that an edit removes ──────────────────────────────────────────

# The kinds of an item that binds its name in its module.
const RC_NAMING_KINDS = (:method, :macro, :type, :const, :global, :module)

# The partition kinds of a name that a module took from another one by a
# `using` with names or an `import`.
const RC_IMPORT_KINDS = (Base.PARTITION_KIND_EXPLICIT, Base.PARTITION_KIND_IMPORTED,
                         Base.PARTITION_KIND_CONST_IMPORT)

# The partition kinds of a name that a module defines by itself.
const RC_OWN_KINDS = (Base.PARTITION_KIND_CONST, Base.PARTITION_KIND_GLOBAL, Base.PARTITION_KIND_DECLARED,
                      Base.PARTITION_KIND_UNDEF_CONST, Base.PARTITION_KIND_BACKDATED_CONST)

# What a `using` or `import` expression takes into its module: the module
# paths of a `using` line with no names, and the names that a `using` with
# names or an `import` binds. `using A.B` uses the module and binds its name.
function rc_using_parts(e::Expr)
    used = Expr[]
    imported = Symbol[]
    for spec in e.args
        spec isa Expr || continue
        if spec.head === :(:)
            for entry in spec.args[2:end]
                bound = entry isa Expr && entry.head === :. ? entry.args[end] :
                        entry isa Expr && entry.head === :as ? entry.args[2] : nothing
                bound isa Symbol && push!(imported, bound)
            end
        elseif spec.head === :as
            spec.args[2] isa Symbol && push!(imported, spec.args[2])
        elseif spec.head === :.
            e.head === :using && push!(used, spec)
            spec.args[end] isa Symbol && spec.args[end] !== :. && push!(imported, spec.args[end])
        end
    end
    return (used = used, imported = imported)
end

# The id of the removal of an item, by its kind.
rc_removal_id(kind::Symbol) = rc_kind_class(kind) === :method ? "A3" : kind === :type ? "B2" :
                              kind === :const ? "C1" : kind === :global ? "C2" : kind === :module ? "C5" : "C3"

# A name that an edit takes out of a module, when no expression of the edited
# sources gives it again (decision D2). A whole build of the edited sources has
# no such name, so the apply takes it out:
#   :bound     - a type, a constant, a global, a function, a macro or a module
#                that the module defined
#   :imported  - a name that the module took by a `using` with names or an
#                `import`
#   :exported  - a name of an `export` or a `public` line
#   :used      - a module of a `using` line with no names, in `target`
# A name that an import of the edited sources gives again is `:replaced`: the
# import of before goes only when the import of now names another binding
# (`rc_drop_replaced_imports!`).
struct RcNameRemoval
    id::String
    how::Symbol
    path::Vector{Symbol}
    name::Symbol
    target::Union{Expr, Nothing}
    where::String
end

# What the items give their modules, by the module path and the name: the
# names that they bind and export, the items that import each name, and the
# `using` paths. A method or a macro of a name that its module imports is a
# method of the function of another module, so it binds no name.
function rc_given_names(items, path_of)
    bound = Set{Tuple{Vector{Symbol}, Symbol}}()
    callable = Set{Tuple{Vector{Symbol}, Symbol}}()
    exported = Set{Tuple{Vector{Symbol}, Symbol}}()
    importers = Dict{Tuple{Vector{Symbol}, Symbol}, Vector{RcItem}}()
    used = Set{Tuple{Vector{Symbol}, Expr}}()
    for item in items
        path = path_of(item)
        e = item.entry.expr
        if item.kind in RC_NAMING_KINDS
            # A method of a function that the definition names through a
            # module (`Base.iterate(x) = ...`) binds no name here.
            item.name === nothing || (item.kind === :method && ReactiveSourceDiff.is_qualified_method(e)) ||
                push!(item.kind in (:method, :macro) ? callable : bound, (path, item.name))
        elseif item.kind === :export && e isa Expr
            for name in e.args
                name isa Symbol && push!(exported, (path, name))
            end
        elseif item.kind === :using && e isa Expr
            parts = rc_using_parts(e)
            foreach(name -> push!(get!(() -> RcItem[], importers, (path, name)), item), parts.imported)
            foreach(target -> push!(used, (path, target)), parts.used)
        end
    end
    union!(bound, (key for key in callable if !haskey(importers, key)))
    return (bound = bound, exported = exported, importers = importers, used = used)
end

# The names that the removed items gave their modules and that the edited
# sources give in no way or in another way: `removed` holds each removed item
# with its module path, and `given` what the new items give. A name that a
# removed item defined goes when no item defines it now. A name that a removed
# item imported goes when no item imports it now, also when the module defines
# it by itself now; when an item imports it now, it is `:replaced`.
function rc_name_removals(removed::Vector{Tuple{RcItem, Vector{Symbol}}}, given)
    names = RcNameRemoval[]
    for (item, path) in removed
        e = item.entry.expr
        place = string(rc_where(item), " ", rc_what(item))
        if item.kind in RC_NAMING_KINDS
            item.name === nothing || (path, item.name) in given.bound ||
                (item.kind === :method && ReactiveSourceDiff.is_qualified_method(e)) ||
                push!(names, RcNameRemoval(rc_removal_id(item.kind), :bound, path, item.name, nothing, place))
        elseif item.kind === :export && e isa Expr
            for name in e.args
                name isa Symbol && !((path, name) in given.exported) &&
                    push!(names, RcNameRemoval("C3", :exported, path, name, nothing, place))
            end
        elseif item.kind === :using && e isa Expr
            parts = rc_using_parts(e)
            for name in parts.imported
                how = haskey(given.importers, (path, name)) ? :replaced : :imported
                push!(names, RcNameRemoval("C3", how, path, name, nothing, place))
            end
            for target in parts.used
                (path, target) in given.used ||
                    push!(names, RcNameRemoval("C3", :used, path, Symbol(""), target, place))
            end
        end
    end
    return unique!(removal -> (removal.how, removal.path, removal.name, removal.target), names)
end

# Whether the module holds the name in the form of the removal: a name that it
# defines by itself for `:bound`, a name that it took from another module for
# `:imported` and `:replaced`.
rc_holds_name(mod::Module, removal::RcNameRemoval) =
    Base.binding_kind(mod, removal.name) in (removal.how === :bound ? RC_OWN_KINDS : RC_IMPORT_KINDS)

# Take one name out of its module. A name that the module does not hold in
# the form of the removal stays: a function of another module that the item
# extended, a name that the module binds in another way now. A `:replaced`
# name stays here: the evaluation of the import that gives it again decides.
# Answer whether the module changed.
function rc_remove_name!(removal::RcNameRemoval)
    mod = rc_module_or_nothing(removal.path)
    mod === nothing && return false
    name = removal.name
    if removal.how === :exported
        return ccall(:jl_reactive_module_unexport, Cint, (Any, Any), mod, name) != 0
    elseif removal.how === :used
        target = rc_import_target(mod, removal.target::Expr)
        target === nothing && return false
        return ccall(:jl_reactive_module_unuse, Cint, (Any, Any), mod, target) != 0
    end
    removal.how === :replaced && return false
    rc_holds_name(mod, removal) || return false
    # The binding is then that of a name that the module never bound: the
    # export of a module that it uses gives the name again, which the guard of
    # `Base.delete_binding` hides.
    return ccall(:jl_reactive_binding_leave, Cint, (Any, Any), mod, name) != 0
end

# C3: refuse each `using` of the queue with a name that its module binds
# already from another place, because Julia ignores such an import. A name
# that the apply takes out of the module before the evaluation, or whose import
# of before the evaluation replaces, is no conflict.
function rc_refuse_import_conflicts!(refusals, queue::RcQueue, roots, names)
    for change in queue.changes
        item = change.item
        item.kind === :using && item.entry.expr isa Expr || continue
        path = rc_module_path(roots, item)
        mod = rc_module_or_nothing(path)
        mod === nothing && continue
        leaves(name) = any(removal -> removal.path == path && removal.name === name &&
                                      removal.how in (:bound, :imported, :replaced) && rc_holds_name(mod, removal), names)
        conflicts = filter!(!leaves, rc_import_conflicts(mod, item.entry.expr))
        isempty(conflicts) || rc_refuse!(refusals, "C3", item, string("the module binds ", join(conflicts, ", "),
                                                                    " already; Julia ignores a conflicting import"))
    end
    return nothing
end

# An expression that the edit leaves as it is and moves to another place, and
# that holds a macro call: its item of the new ledger, and its expression of
# before the edit, with the lines and the file of before.
struct RcMoved
    item::RcItem
    old::Any
end

# The state of the evaluation of the changes of one apply: the new ledger, the
# queue and the removals, the refusals that the evaluation finds, how the
# names of the modules with a changed `using` resolve, the method instances of
# the old methods of the evaluated changes, the count of the methods that the
# filter kept, the statements whose effect the apply takes back, the moved
# expressions that hold a macro call, the names that the edit removes, and the
# names of the imports that left which an import of the edited sources gives
# again and no evaluation decided yet, and the items by the names that their
# evaluation resolves, made at the first evaluation that binds a constant again.
mutable struct RcEvaluation
    items::Vector{RcItem}
    roots::Vector{Vector{Symbol}}
    tracked::Set{String}
    queue::RcQueue
    removals::Vector{RcChange}
    refusals::Vector{String}
    resolutions::Dict{UInt, Dict{Symbol, Any}}
    replaced::Vector{Core.MethodInstance}
    kept::Int
    group::Union{RcStatementGroup, Nothing}
    moved::Vector{RcMoved}
    names::Vector{RcNameRemoval}
    replaced_imports::Set{Tuple{Vector{Symbol}, Symbol}}
    named::Union{Nothing, Dict{Symbol, Vector{RcItem}}}
end
RcEvaluation(items, roots, tracked, queue, removals, refusals, group, moved, names) =
    RcEvaluation(items, roots, tracked, queue, removals, refusals, Dict{UInt, Dict{Symbol, Any}}(),
                 Core.MethodInstance[], 0, group, moved, names,
                 Set{Tuple{Vector{Symbol}, Symbol}}((removal.path, removal.name) for removal in names
                                                    if removal.how === :replaced),
                 nothing)

# Whether the item is a statement that defines nothing: it holds no macro call
# and no `eval`, so what it does is an effect on a value that exists. A
# `precompile` call has no effect on a value.
function rc_is_plain_statement(item::RcItem)
    e = item.entry.expr
    item.kind === :other && e isa Expr || return false
    e.head === :call && !isempty(e.args) && (e.args[1] === :precompile || e.args[1] == :(Base.precompile)) && return false
    return isempty(ReactiveSourceDiff.macro_heads(e)) && !(:eval in ReactiveSourceDiff.all_names(e))
end

# D3: take back what the statements `old` did, which the edit changed or
# removed; `new` holds the statements of the edit that replace them. The state
# of a global is made by its definition and by each statement that names it, in
# the load order. So the definition of each tracked global that one of the
# statements names joins the queue, and its evaluation runs each statement
# that names it again (the dependents of a binding). A statement of the ledger
# that names one of these globals brings the other globals that it names, until
# no global is new. A statement that names no tracked global is refused: its
# effect is on a value that the rebuild can not make again. Answer the group,
# or `nothing` when no statement changed.
function rc_statement_group!(queue::RcQueue, refusals::Vector{String}, items::Vector{RcItem},
                             old::Vector{RcItem}, new::Vector{RcItem})
    isempty(old) && return nothing
    definitions = Dict{Symbol, Vector{RcItem}}()
    for item in items
        item.kind in RC_BINDING_KINDS && item.name !== nothing && push!(get!(definitions, item.name, RcItem[]), item)
    end
    named(item) = Symbol[name for name in ReactiveSourceDiff.all_names(item.entry.expr) if haskey(definitions, name)]
    names = Set{Symbol}()
    for statement in old
        found = named(statement)
        isempty(found) && rc_refuse!(refusals, "S1", statement,
                                     "the statement changed or left, and it names no tracked global: the rebuild can not take back what it did")
        union!(names, found)
    end
    for statement in new
        union!(names, named(statement))
    end
    isempty(names) && return nothing
    statements = RcItem[item for item in items if rc_is_plain_statement(item)]
    grew = true
    while grew
        grew = false
        for statement in statements
            found = named(statement)
            (isdisjoint(found, names) || issubset(found, names)) && continue
            union!(names, found)
            grew = true
        end
    end
    group = RcItem[]
    for name in sort!(collect(names)), definition in definitions[name]
        push!(group, definition)
        rc_enqueue!(queue, RcChange("S1", definition, "a statement that names it changed"))
    end
    return RcStatementGroup(group, old, new)
end

# Evaluate the expression of the item in `mod`, as the loader of a file does.
rc_evaluate_item(mod::Module, item::RcItem) = rc_evaluate_at(mod, item, item.entry.expr)

# Evaluate `e`, the expression of the item or a part of it, in `mod`, as the
# loader of a file does: with the file and the first line of the item before
# it, so each method that the evaluation defines keeps that place as its
# definer.
rc_evaluate_at(mod::Module, item::RcItem, e) =
    Core.eval(mod, Expr(:toplevel, LineNumberNode(item.entry.lines.start, Symbol(item.path)), e))

# Delete the methods of the removals, and take out the names that the edit
# removes. The modules come last: the names inside a module go while its path
# still leads to it. How the names resolve is recorded first, and each
# expression that resolves a name in another way afterwards joins the queue,
# in every module: a method that an unchanged expression gave an imported
# function is a method of another function when the import is gone, and a
# method of another module that names a moved struct in its signature is a
# method for the struct of the new module.
function rc_delete_removals!(evaluation::RcEvaluation)
    rc_record_resolutions!(evaluation)
    for change in evaluation.removals, method in change.old_methods
        rc_delete_method(method)
        change.deleted += 1
    end
    is_module(removal) = removal.how === :bound &&
                         rc_module_or_nothing(vcat(removal.path, removal.name)) !== nothing
    changed = false
    for removal in sort(evaluation.names; by = removal -> is_module(removal) ? -length(removal.path) : typemin(Int))
        Base.invokelatest(rc_remove_name!, removal) || continue
        changed = true
        println("rc: removed ", removal.where, ": the ",
                removal.how === :used ? "using" : string(removal.how, " name ", removal.name), " leaves ",
                join(removal.path, '.'))
    end
    if changed
        # A statement of the trace that names a name that left resolves no more.
        empty!(RC_TRACE_CACHE)
        empty!(RC_TRACE_FAILED)
        rc_enqueue_resolved_differently!(evaluation, nothing, nothing)
    end
    return nothing
end

# Before the evaluation of a `using` with names or of an `import`: the import
# of an expression that left goes when the import of now names another
# binding, because Julia ignores an import that conflicts with one that
# exists. The first expression of the load order that gives a name decides it,
# as in a whole build, so a later one finds the name decided.
function rc_drop_replaced_imports!(evaluation::RcEvaluation, mod::Module, item::RcItem)
    isempty(evaluation.replaced_imports) && return nothing
    path = rc_module_path(evaluation.roots, item)
    conflicts = rc_import_conflicts(mod, item.entry.expr)
    for name in rc_using_parts(item.entry.expr).imported
        key = (path, name)
        key in evaluation.replaced_imports || continue
        delete!(evaluation.replaced_imports, key)
        name in conflicts && Base.binding_kind(mod, name) in RC_IMPORT_KINDS || continue
        Base.delete_binding(mod, name)
        println("rc: removed ", rc_where(item), ": the imported name ", name, " of before leaves ", join(path, '.'))
    end
    return nothing
end

# C3: record how the names of the expressions resolve before the apply. In a
# module with a changed `using`, or with a `using` that left, each name of each
# expression is recorded. A name that leaves a module is recorded in every
# module, because an expression of another module can take that name through a
# `using`. A new module has no such names: the apply makes it, and no
# expression of it ran before.
function rc_record_resolutions!(evaluation::RcEvaluation)
    leaving = Set{Symbol}(removal.name for removal in evaluation.names
                          if removal.how in (:bound, :imported, :exported))
    whole = Set{Vector{Symbol}}(removal.path for removal in evaluation.names if removal.how === :used)
    for change in evaluation.queue.changes
        change.item.kind === :using && push!(whole, rc_module_path(evaluation.roots, change.item))
    end
    isempty(leaving) && isempty(whole) && return nothing
    modules = Dict{Vector{Symbol}, Union{Module, Nothing}}()
    for item in evaluation.items
        path = rc_module_path(evaluation.roots, item)
        names = ReactiveSourceDiff.all_names(item.entry.expr)
        path in whole || intersect!(names, leaving)
        isempty(names) && continue
        mod = get!(() -> rc_module_or_nothing(path), modules, path)
        mod === nothing && continue
        evaluation.resolutions[objectid(item)] = Base.invokelatest(rc_resolution, mod, names)
    end
    return nothing
end

# C3: each expression whose names resolve in another way than at the last
# record joins the queue: the expressions of the module at `module_path` other
# than `except`, or those of every module when `module_path` is nothing.
function rc_enqueue_resolved_differently!(evaluation::RcEvaluation, module_path, except)
    modules = Dict{Vector{Symbol}, Union{Module, Nothing}}()
    for dependent in evaluation.items
        dependent === except && continue
        before = get(evaluation.resolutions, objectid(dependent), nothing)
        before === nothing && continue
        path = rc_module_path(evaluation.roots, dependent)
        module_path === nothing || path == module_path || continue
        mod = get!(() -> Base.invokelatest(rc_module_or_nothing, path), modules, path)
        mod === nothing && continue
        after = Base.invokelatest(rc_resolution, mod, keys(before))
        moved = sort!(Symbol[name for (name, what) in after if before[name] !== what])
        isempty(moved) && continue
        evaluation.resolutions[objectid(dependent)] = after
        rc_enqueue!(evaluation.queue, RcChange("C3", dependent, string("resolves ", join(moved, ", "), " differently")))
    end
    return nothing
end

# The value that the binding has as a constant in `world`, in a `Some`, or
# nothing when it is no constant there. The partitions of the binding are read
# as they are: a lookup would make a partition for a world that has none. Julia
# dates a new constant back to the worlds before its definition; the name was
# no constant in those worlds.
function rc_constant_in(binding::Core.Binding, world::UInt)
    isdefined(binding, :partitions) || return nothing
    partition = binding.partitions
    while partition.min_world > world
        isdefined(partition, :next) || return nothing
        partition = @atomic partition.next
    end
    partition.max_world >= world || return nothing
    kind = Base.binding_kind(partition)
    Base.is_defined_const_binding(kind) && kind != Base.PARTITION_KIND_BACKDATED_CONST || return nothing
    return Some{Any}(Base.partition_restriction(partition))
end

# The constants of the module that have another value now than in `world`:
# each name with the value of that world in a `Some`, or with nothing when the
# name was no constant there. A type that a definition makes is a constant
# too. Julia keeps the binding of a constant whose new value is identical to
# the old one, so a type that is defined again with the same fields is not in
# the list.
function rc_rebound_constants(mod::Module, world::UInt)
    rebound = Tuple{Symbol, Union{Some{Any}, Nothing}}[]
    Base.get_world_counter() == world && return rebound
    for name in Base.unsorted_names(mod; all = true)
        binding = ccall(:jl_get_module_binding_or_nothing, Any, (Any, Any), mod, name)
        binding isa Core.Binding && isdefined(binding, :partitions) || continue
        latest = binding.partitions
        latest.min_world > world || continue
        Base.binding_kind(latest) == Base.PARTITION_KIND_CONST || continue
        before = rc_constant_in(binding, world)
        before !== nothing && Base.partition_restriction(latest) === something(before) && continue
        push!(rebound, (name, before))
    end
    return rebound
end

# Whether the value of before is a type as its definition made it: `S` of
# `struct S` and of `struct S{T}`, and neither `S{Int}` nor the alias of a
# union.
rc_is_defined_type(::Nothing) = false
function rc_is_defined_type(before::Some)
    value = something(before)
    value isa Type || return false
    body = Base.unwrap_unionall(value)
    return body isa DataType && body.name.wrapper === value
end

# What the session keeps of the statements of the trace holds for one state of
# the bindings of the program: a statement resolves through them. A constant
# that has another value now makes each kept type doubtful, because a
# statement that names the constant has the same text and another type. A new
# name can make a statement resolve that did not. A name that Julia generates
# has a counter, and no statement of before names the new one.
function rc_forget_statements!(rebound)
    for (name, before) in rebound
        if before !== nothing
            empty!(RC_TRACE_CACHE)
            empty!(RC_TRACE_FAILED)
            return nothing
        end
        startswith(String(name), '#') || empty!(RC_TRACE_FAILED)
    end
    return nothing
end

# The items of the ledger by the names that their evaluation resolves into
# what they define: a name of the signature, of the fields or of the
# initializer, and the function or the type that a method definition adds its
# method to. The names are those of the source, with no module.
function rc_items_by_name!(evaluation::RcEvaluation)
    named = evaluation.named
    named === nothing || return named
    named = Dict{Symbol, Vector{RcItem}}()
    for item in evaluation.items
        names = ReactiveSourceDiff.type_level_names(item.entry.expr)
        item.kind === :method && item.name !== nothing && push!(names, item.name)
        for name in names
            push!(get!(() -> RcItem[], named, name), item)
        end
    end
    return evaluation.named = named
end

# Whether the item is a `const` or a `global` in plain text: no macro call
# holds the declaration, other than its docstring. The kind of an item is read
# from its text, and the argument of a macro call can look like a declaration
# and be none (`@insertion TextBlock = ...`).
function rc_is_plain_declaration(item::RcItem)
    item.kind in RC_BINDING_KINDS && item.name !== nothing || return false
    e = ReactiveSourceDiff.without_docstrings(item.entry.expr)
    return e isa Expr && e.head in (:const, :global, :(=))
end

# Before the evaluation of a changed `const` or `global`: the binding of
# before leaves when the text of before declared the name in another kind.
# Julia makes no constant of a global and no global of a constant in a module
# that holds the name, and it gives a typed global no other type. A whole
# build has only the declaration of now, so the name of before goes first, as
# the name of an expression that left does. The rule takes a plain declaration
# of before and one of now, and a binding that is what the text of before
# declared. Answer whether the binding left.
function rc_drop_other_declaration!(mod::Module, change::RcChange)
    item = change.item
    rc_is_plain_declaration(item) || return false
    declared = ReactiveSourceDiff.declared_type(item.entry.expr)
    held = Base.binding_kind(mod, item.name)
    for old in change.old_items
        old === item && continue
        rc_is_plain_declaration(old) && old.name === item.name || continue
        old.kind !== item.kind ||
            (item.kind === :global && ReactiveSourceDiff.declared_type(old.entry.expr) != declared) || continue
        held == (old.kind === :const ? Base.PARTITION_KIND_CONST : Base.PARTITION_KIND_GLOBAL) || continue
        Base.delete_binding(mod, item.name)
        println("rc: removed ", change.where, ": the declaration of ", item.name, " of before leaves ", mod,
                ", because the one of now is of another kind")
        return true
    end
    return false
end

# Evaluate the next change of the queue in its module, and add to the queue
# the dependents of what the evaluation changed. Answer false when the
# evaluation found a refusal. The method filter is installed by the caller.
function rc_evaluate_next!(evaluation::RcEvaluation)
    queue = evaluation.queue
    new_roots = evaluation.roots
    new_items = evaluation.items
    queue.cursor += 1
    change = queue.changes[queue.cursor]
    item = change.item
    item.kind === :include && return true
    if change.id == "H2" && item.kind === :module
        path = vcat(rc_module_path(new_roots, item), item.name)
        Base.invokelatest(rc_set_module_doc!, Base.invokelatest(rc_resolve_module, path), item.entry.expr)
        return true
    end
    # The bindings are read at the latest world: the evaluation of the changes
    # moves it, and a module that an earlier change made is newer than the
    # caller.
    mod = Base.invokelatest(rc_resolve_module, rc_module_path(new_roots, item))
    world = Base.get_world_counter()
    item.kind === :using && Base.invokelatest(rc_drop_replaced_imports!, evaluation, mod, item)
    Base.invokelatest(rc_drop_other_declaration!, mod, change)
    rc_evaluate_item(mod, item)
    # A kept method is a method of the sources of now: this evaluation defined
    # it again with the same code, and the filter gave it the place of that
    # definition. It is neither replaced nor deleted. Each change and each
    # removal that names it as an old method loses it: two changes of the same
    # name share their old items, and the lines of a method that the expansion
    # of a macro defines are those of the function that builds the expansion,
    # so the change of that function names the method too.
    for method in rc_take_kept!()
        named = false
        for other in queue.changes
            method in other.old_methods || continue
            filter!(m -> m !== method, other.old_methods)
            named = true
        end
        for removal in evaluation.removals
            method in removal.old_methods || continue
            filter!(m -> m !== method, removal.old_methods)
            named = true
        end
        named || continue
        change.kept += 1
        evaluation.kept += 1
    end
    for method in change.old_methods, mi in Base.specializations(method)
        mi isa Core.MethodInstance && push!(evaluation.replaced, mi)
    end
    # The dependents of what the evaluation changed. The constants come from the
    # bindings of the module and not from the name of the item: the call of a
    # macro binds names that its source does not show, as the second type of a
    # macro that defines two.
    rebound = Base.invokelatest(rc_rebound_constants, mod, world)
    on_types = Base.IdDict{Method, Symbol}()
    rc_forget_statements!(rebound)
    for (name, before) in rebound
        rc_is_defined_type(before) || continue
        found = rc_methods_on_type(something(before), evaluation.tracked)
        for method in found.outside
            rc_refuse!(evaluation.refusals, change.id, item,
                       string("the untracked ", basename(String(method.file)), ":", method.line,
                              " ", method.name, " names the type ", name, " (found in the apply)"))
        end
        for method in found.inside
            on_types[method] = name
        end
    end
    isempty(evaluation.refusals) || return false
    names = Set{Symbol}(name for (name, _) in rebound)
    # The value of a global that is no constant can change with no new binding.
    item.kind === :global && item.name !== nothing && push!(names, item.name)
    if !isempty(names)
        by_name = rc_items_by_name!(evaluation)
        reasons = Base.IdDict{RcItem, Symbol}()
        for name in sort!(collect(names)), dependent in get(by_name, name, ())
            get!(reasons, dependent, name)
        end
        for dependent in new_items
            dependent === item && continue
            named = get(reasons, dependent, nothing)
            if named === nothing && !isempty(on_types)
                index = findfirst(method -> haskey(on_types, method), dependent.methods)
                index === nothing || (named = on_types[dependent.methods[index]])
            end
            named === nothing && continue
            rc_enqueue!(queue, RcChange(change.id, dependent, string("names ", named)))
        end
    end
    item.kind === :using && rc_enqueue_resolved_differently!(evaluation, rc_module_path(new_roots, item), item)
    return true
end

# Compare every tracked file with the stored copy of the previous snapshot,
# classify the changes, refuse what the catalog refuses, and evaluate the
# changes and their dependents in their modules. `old_reads` holds the
# hash of every file that a top-level expression of the previous snapshot
# could read; the new listing is written to `reads_out`. A refusal is written
# to `refusal_out` and the child exits before any evaluation. With `allowed`,
# the ids of the change catalog that this apply takes, every other change is
# refused too. The evaluations of the replay print to the file
# `<refusal_out>.replay.log`. With `keep_ledger`, the ledger and the parses stay for the next
# apply of the process, as a server needs them; a process that writes its
# image next keeps none of them, because they would be in the image. Answer
# the set of method instances that exist before the trace, and whether the
# world moved.
function rc_apply_tracked(old_files::Vector{String}, old_roots::Vector{Vector{Symbol}},
                          old_copies::Vector{String},
                          new_files::Vector{String}, new_roots::Vector{Vector{Symbol}},
                          old_reads::Vector{Tuple{String, String}},
                          reads_out::String, refusal_out::String;
                          allowed::Union{Nothing, Set{String}} = nothing, keep_ledger::Bool = false)
    rc_warm()
    t0 = time()
    # The ledgers of the files whose text changed: a pair by path whose texts
    # differ, and every renamed, removed and added file. The old items come
    # from the ledger of the previous apply of this process when it has them
    # (a server), else from the stored copies with a walk of the method
    # table. An edit that changes an expression takes the ledgers of every
    # file.
    match = rc_match_files(old_files, old_copies, new_files)
    changed_pairs = Tuple{Int, Int}[(i, j) for (i, j) in match.pairs
                                    if read(old_copies[i], String) != read(new_files[j], String)]
    old_indices = sort!(vcat(first.(changed_pairs), first.(match.renamed), match.removed))
    new_indices = sort!(vcat(last.(changed_pairs), last.(match.renamed), match.added))
    pair_of_new = Dict{Int, Int}(j => i for (i, j) in vcat(match.pairs, match.renamed))
    old_items, old_ledger = rc_old_items(old_files, old_copies, old_indices)
    new_items = rc_new_items(new_files, new_indices)
    all_files = rc_has_change(old_items, new_items, pair_of_new, old_reads)
    if all_files
        old_items, old_ledger = rc_old_items(old_files, old_copies, eachindex(old_files))
        new_items = rc_new_items(new_files, eachindex(new_files))
    end
    RC_LEDGER_CACHE[] = nothing
    t_ledger = time() - t0
    tracked = Set(new_files)
    filter!(entry -> entry.first in tracked, RC_PARSED)
    refusals = String[]
    queue = RcQueue(rc_load_order(new_files, new_roots, new_items, all_files))
    removals = RcChange[]
    old_statements = RcItem[]
    new_statements = RcItem[]
    moved = RcMoved[]
    removed_named = Tuple{RcItem, Vector{Symbol}}[]
    line_updates = 0
    # The new places of the methods of the expressions that an edit moves, and
    # the new paths of the items of a renamed file. The apply writes them when
    # it begins: a refusal or a trial that stops leaves each method and each
    # item of the ledger of before at its place (decision D4).
    place_moves = Tuple{Method, Symbol, Any}[]
    path_moves = Tuple{RcItem, String}[]
    # The methods whose text is in a file that changed, by the old path: they
    # take the new name of a renamed file and the shift of a moved expression.
    # The methods of an item are those that it defined, and their text can be
    # in another file.
    text_methods = rc_methods_by_text(Set{String}(old_files[i] for i in old_indices))
    # H3: a renamed file keeps its methods, under the new name.
    for (i, j) in match.renamed
        renamed = 0
        new_file = Symbol(new_files[j])
        for item in old_items
            item.file == i || continue
            push!(path_moves, (item, new_files[j]))
            for method in item.methods
                push!(place_moves, (method, :toplevel_file, new_file))
            end
        end
        for method in text_methods[old_files[i]]
            method.file === new_file && continue
            push!(place_moves, (method, :file, new_file))
            renamed += 1
        end
        println("rc: change H3 ", basename(old_files[i]), " -> ", basename(new_files[j]), ", ",
                renamed, " methods renamed")
    end
    # C4: a removed file loses its methods; an added file is evaluated whole.
    for i in match.removed
        methods = Method[m for item in old_items if item.file == i for m in item.methods]
        push!(removals, RcChange("C4", nothing, RcItem[], methods, basename(old_files[i]), "removed file", 0, 0))
        for item in old_items
            item.file == i && push!(removed_named, (item, vcat(old_roots[i], item.entry.module_path)))
        end
    end
    for j in match.added
        for item in new_items
            item.file == j || continue
            rc_enqueue!(queue, RcChange("C4", item, RcItem[], string("new file ", basename(new_files[j]))))
        end
    end
    # The diff of every matched pair.
    shifted = Base.IdSet{Method}()
    for (i, j) in vcat(match.pairs, match.renamed)
        olds = RcItem[item for item in old_items if item.file == i]
        news = RcItem[item for item in new_items if item.file == j]
        # The methods whose text is inside each old expression, taken before a
        # line moves: a moved line can be inside the old lines of the next
        # expression.
        text_of = IdDict{RcItem, Vector{Method}}()
        for method in get(text_methods, old_files[i], Method[])
            for old in olds
                method.line in old.entry.lines || continue
                push!(get!(() -> Method[], text_of, old), method)
                break
            end
        end
        old_by_key = Dict{UInt64, RcItem}(item.entry.key => item for item in olds)
        new_keys = Set{UInt64}(item.entry.key for item in news)
        changed = RcItem[]
        for item in news
            old = get(old_by_key, item.entry.key, nothing)
            if old === nothing
                push!(changed, item)
                continue
            end
            # H1: an unchanged expression keeps the methods that it defined, at
            # its new first line, and the methods whose text is inside it move
            # with it. A file that two modules include has its methods in two
            # items: a method moves once.
            shift = item.entry.lines.start - old.entry.lines.start
            if shift != 0
                for method in old.methods
                    push!(place_moves, (method, :toplevel_line, Int32(item.entry.lines.start)))
                end
                for method in get(text_of, old, Method[])
                    method in shifted && continue
                    push!(shifted, method)
                    push!(place_moves, (method, :line, Int32(method.line + shift)))
                    line_updates += 1
                end
            end
            item.methods = old.methods
            rc_is_moved_macro_user(item, old.entry.lines.start, old_files[i]) &&
                push!(moved, RcMoved(item, old.entry.expr))
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
            # D3: a statement that the edit changed or removed, as an item of
            # the new file, and the statements of the edit that replace it.
            if rc_is_plain_statement(item)
                push!(old_statements, RcItem(j, new_files[j], item.entry, item.kind, item.name, Method[]))
                for c in changed
                    counterpart(c, item) && rc_is_plain_statement(c) && !(c in new_statements) && push!(new_statements, c)
                end
            end
            if any(c -> counterpart(c, item), changed)
                # The changed counterpart takes the methods. The name leaves
                # when the counterpart gives none: a method that the edit writes
                # with the module of its function (`Base.iterate(x) = ...`).
                push!(removed_named, (item, vcat(new_roots[j], item.entry.module_path)))
                continue
            end
            item.kind === :include && continue
            # D2: an expression that left. The methods that it defined go, and
            # so do the names that it gave its module, when no expression of
            # the edited sources gives them again (`rc_name_removals`).
            push!(removed_named, (item, vcat(new_roots[j], item.entry.module_path)))
            isempty(item.methods) && rc_kind_class(item.kind) !== :method && continue
            push!(removals, RcChange(rc_removal_id(item.kind), nothing, RcItem[item], item.methods,
                                     string(rc_where(item), " ", rc_what(item)), "removed", 0, 0))
        end
        for item in changed
            old = RcItem[o for o in removed if counterpart(o, item)]
            change = rc_classify(item, old, new_roots, tracked, refusals)
            change === nothing || rc_enqueue!(queue, change)
        end
    end
    # E1: a changed read file re-evaluates the expressions that name it. A
    # ledger of the changed files found every old read file the same, and the
    # reads of the other files carry over.
    old_hashes = Dict{String, String}(path => h for (path, h) in old_reads)
    new_reads = all_files ? Tuple{String, String}[] : copy(old_reads)
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
    group = rc_statement_group!(queue, refusals, new_items, old_statements, new_statements)
    # D2: the names that the removed expressions gave, and that no expression
    # of the edited sources gives. A removal is a change, so the ledger holds
    # every file.
    given = rc_given_names(new_items, item -> rc_module_path(new_roots, item))
    names = isempty(removed_named) ? RcNameRemoval[] : rc_name_removals(removed_named, given)
    # An import of the edited sources that gives a name of an import that left
    # is evaluated again, so the first one of the load order decides the name.
    for removal in names
        removal.how === :replaced || continue
        for importer in given.importers[(removal.path, removal.name)]
            rc_enqueue!(queue, RcChange("C3", importer, string("gives ", removal.name, ", which an import that left gave")))
        end
    end
    rc_refuse_import_conflicts!(refusals, queue, new_roots, names)
    if allowed !== nothing
        isempty(match.renamed) || push!(refusals, "H3 a renamed file: not taken by this apply")
        for change in vcat(removals, queue.changes)
            change.id in allowed || push!(refusals, string(change.id, " ", change.where, ": not taken by this apply"))
        end
        for removal in names
            removal.how === :replaced && continue
            if removal.how in (:bound, :imported)
                mod = rc_module_or_nothing(removal.path)
                mod !== nothing && rc_holds_name(mod, removal) || continue
            end
            push!(refusals, string(removal.id, " ", removal.where, ": a name leaves its module, not taken by this apply"))
        end
    end
    isempty(refusals) || rc_stop(refusals, refusal_out)
    evaluation = RcEvaluation(new_items, new_roots, tracked, queue, removals, refusals, group, moved, names)
    # The replay: the expressions whose text stays and whose result changes.
    replay_log = string(refusal_out, ".replay.log")
    stopped = nothing
    if !isempty(queue.changes) || !isempty(removals) || !isempty(moved) || !isempty(names)
        known = Set{UInt}(objectid(change) for change in queue.changes)
        stopped = rc_replay!(evaluation, replay_log)
        if allowed !== nothing
            for change in queue.changes
                objectid(change) in known || change.id in allowed ||
                    push!(refusals, string(change.id, " ", change.where, ": not taken by this apply"))
            end
        end
        isempty(refusals) || rc_stop(refusals, refusal_out)
        # D4: the trial evaluated the edit in a fork and stopped. The process
        # evaluated nothing of the edit, so it is as before the request.
        stopped === nothing ||
            error("rc: the edit is not applied, because its trial stopped: ", stopped, "; see ", replay_log)
    end
    # The apply. The removals first, then the queue in the load order, with the
    # dependents that each evaluation reveals. From here the process holds a
    # part of the edit until the apply ends.
    RC_APPLY_OPEN[] = true
    for (method, field, place) in place_moves
        setfield!(method, field, place)
    end
    for (item, path) in path_moves
        item.path = path
    end
    rc_delete_removals!(evaluation)
    deleted = 0
    for change in removals
        deleted += change.deleted
        println("rc: change ", change.id, " ", change.where, " (", change.note, "), ",
                change.deleted, " methods deleted")
    end
    world_before = Base.get_world_counter()
    empty!(RC_KEPT)
    rc_install_filter(rc_method_filter)
    t_eval = @elapsed try
        rc_with_empty_task_storage() do
            rc_with_fresh_log_ids() do
                while queue.cursor < length(queue.changes)
                    rc_evaluate_next!(evaluation) || rc_stop(refusals, refusal_out)
                end
            end
        end
    finally
        rc_install_filter(nothing)
    end
    replaced = evaluation.replaced
    kept = evaluation.kept
    world_after = Base.get_world_counter()
    # The new ledger, and the deletion of every old method of a change: the
    # ones without a replacement of the same signature made the change a
    # removal too, the replaced ones are dead entries that would keep a
    # stale line in the next ledger.
    skip = Base.IdSet{Method}()
    for change in vcat(removals, queue.changes), method in change.old_methods
        push!(skip, method)
    end
    byfile = rc_methods_by_definer(tracked)
    rc_assign_methods!(new_items, byfile, skip)
    # The ledger for the next apply: the new items, and the old items of each
    # file whose text stayed, under the file's new index.
    ledger = Dict{Int, Vector{RcItem}}()
    for item in new_items
        push!(get!(ledger, item.file, RcItem[]), item)
    end
    for (i, j) in match.pairs
        haskey(ledger, j) && continue
        kept_items = get(old_ledger, i, nothing)
        kept_items === nothing && continue
        for item in kept_items
            item.file = j
        end
        rc_assign_methods!(kept_items, byfile, skip)
        ledger[j] = kept_items
    end
    if keep_ledger
        RC_LEDGER_CACHE[] = (copy(new_files), ledger)
    else
        empty!(RC_PARSED)
    end
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
            # A method of a function with a generated name (a closure, the body
            # of a keyword method, a generator) has a new name at each
            # evaluation: it is no method that the edit removed.
            if any(sig -> sig == method.sig, new_sigs)
                replaced_sigs += 1
            elseif !('#' in String(method.name))
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
            round(t_ledger, digits = 2), " s of ", all_files ? string("all ", length(new_files)) :
            string(length(new_indices), " changed of ", length(new_files)), " files; cone ", length(replaced), " replaced, ", length(closed),
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
    length(rc_new_items([new_path], [1])) == 9 || error("rc_warm: the new items of one file are not 9")
    rc_has_change(old_items, new_items, Dict(1 => 1), Tuple{String, String}[]) ||
        error("rc_warm: the ledgers of an edit show no change")
    rc_has_change(old_items[1:1], old_items[1:1], Dict(1 => 1), Tuple{String, String}[]) &&
        error("rc_warm: two equal ledgers show a change")
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
    queue = RcQueue(rc_load_order([new_path], roots, new_items, false))
    for item in changed
        old = RcItem[o for o in old_items if o.name === item.name && o.name !== nothing]
        change = rc_classify(item, old, roots, tracked, refusals)
        change === nothing || rc_enqueue!(queue, change)
    end
    length(refusals) == 1 && startswith(refusals[1], "C4") ||
        error("rc_warm: the refusals are ", refusals)
    ids = [change.id for change in queue.changes]
    ids == ["A2", "B2", "C1", "D1", "C3"] || error("rc_warm: the ids are ", ids)
    # The candidates of the replay: the constant that a call of a tracked type
    # gives its value, and the method that expands a tracked macro.
    candidates = rc_candidates(new_items, queue.order)
    [(candidate.item.name, candidate.expands, candidate.initializer !== nothing) for candidate in candidates] ==
        [(:C, false, true), (:h, true, false)] ||
        error("rc_warm: the candidates are ", [candidate.item.name for candidate in candidates])
    # D3: a changed statement brings the definition of the global that it
    # names, and a statement that names no global is refused. A `precompile`
    # call and a definition are no statements.
    statement_path = joinpath(dir, "warm8.jl")
    write(statement_path, "const T = Symbol[]\npush!(T, :a)\nprecompile(sin, (Int,))\nnote(:x)\n")
    statement_items = rc_ledger([statement_path], [statement_path])
    [rc_is_plain_statement(item) for item in statement_items] == [false, true, false, true] ||
        error("rc_warm: the statements are ", [rc_is_plain_statement(item) for item in statement_items])
    statement_queue = RcQueue(rc_load_order([statement_path], roots, statement_items, false))
    statement_refusals = String[]
    group = rc_statement_group!(statement_queue, statement_refusals, statement_items, statement_items[[2, 4]], RcItem[])
    group !== nothing && [item.name for item in group.definitions] == [:T] &&
        [change.id for change in statement_queue.changes] == ["S1"] &&
        length(statement_refusals) == 1 && startswith(statement_refusals[1], "S1 warm8.jl:4") ||
        error("rc_warm: the statement group gives ", statement_refusals)
    # A moved expression: at another line, the function that holds a macro
    # call is a moved macro user, and the function whose only macro call is its
    # docstring is not.
    moved_path = joinpath(dir, "warm9.jl")
    write(moved_path, "\"doc\"\nplain() = 1\n\"doc\"\nnoted() = @__LINE__\n")
    moved_items = rc_ledger([moved_path], [moved_path])
    [rc_is_moved_macro_user(item, item.entry.lines.start + 1, moved_path) for item in moved_items] == [false, true] &&
        !rc_is_moved_macro_user(moved_items[2], moved_items[2].entry.lines.start, moved_path) ||
        error("rc_warm: the moved macro users are wrong")
    # The storage of the task is empty inside the call, and back after it.
    task_local_storage(:rc_warm, 1)
    rc_with_empty_task_storage(() -> haskey(task_local_storage(), :rc_warm)) &&
        error("rc_warm: the storage of the task is not empty inside the call")
    haskey(task_local_storage(), :rc_warm) || error("rc_warm: the storage of the task did not come back")
    delete!(task_local_storage(), :rc_warm)
    # The load order: a loaded package before one that is not loaded, and a
    # `using` after the module that the include above it loads.
    root_path = joinpath(dir, "W.jl")
    part_path = joinpath(dir, "warm4.jl")
    write(root_path, "module W\ninclude(\"warm4.jl\")\nusing .X\nend\n")
    write(part_path, "module X\nend\n")
    order_roots = [Symbol[], Symbol[:W]]
    order_items = rc_ledger([root_path, part_path], [root_path, part_path])
    order = rc_load_order([root_path, part_path], order_roots, order_items, true)
    using_item = only(item for item in order_items if item.kind === :using)
    module_item = only(item for item in order_items if item.kind === :module && item.file == 2)
    rc_order(order, module_item) < rc_order(order, using_item) ||
        error("rc_warm: the load order puts ", rc_order(order, using_item), " before ",
              rc_order(order, module_item))
    rc_load_order([new_path, root_path], [Symbol[:Base], Symbol[]], RcItem[], false).keys[1] <
        order.keys[1] || error("rc_warm: Base does not load before an unloaded package")
    # C4: a new include takes a tracked file when the rules of the walk compute
    # its path, and an include of another form is refused.
    include_path = joinpath(dir, "warm3.jl")
    write(include_path, "include(joinpath(@__DIR__, \"warm2.jl\"))\n" *
                        "include(joinpath(pwd(), \"warm2.jl\"))\n")
    include_ids = String[]
    include_refusals = String[]
    for item in rc_ledger([include_path], [include_path])
        change = rc_classify(item, RcItem[], roots, tracked, include_refusals)
        change === nothing || push!(include_ids, change.id)
    end
    include_ids == ["C4"] && length(include_refusals) == 1 &&
        occursin("warm3.jl:2", include_refusals[1]) ||
        error("rc_warm: the includes give ", include_ids, " and ", include_refusals)
    # The bindings are new, so they are read at the latest world.
    paths = Module()
    Core.eval(paths, :(const SOURCE = $dir))
    Core.eval(paths, :(VARIABLE = $dir))
    Base.invokelatest(rc_include_path, :(joinpath(SOURCE, "warm2.jl")), include_path, paths) == new_path &&
        Base.invokelatest(rc_include_path, :(joinpath(VARIABLE, "warm2.jl")), include_path, paths) === nothing &&
        rc_include_path(:(normpath(@__FILE__, "..", "warm2.jl")), include_path, nothing) == new_path ||
        error("rc_warm: a const path of a module does not give the included file")
    # H2: a header that differs only in its docstring keeps the loaded module and
    # sets its docstring; another change of a header is refused.
    header_of(text, name) = (write(joinpath(dir, name), text);
                             rc_ledger([joinpath(dir, name)], [joinpath(dir, name)])[1])
    old_header = header_of("\"old\"\nmodule D\nend\n", "warm4.jl")
    new_header = header_of("\n\"new\"\nmodule D\nend\n", "warm5.jl")
    plain_header = header_of("module D\nend\n", "warm6.jl")
    bare_header = header_of("\"new\"\nbaremodule D\nend\n", "warm7.jl")
    header_ids = String[]
    header_refusals = String[]
    for header in (new_header, plain_header, bare_header)
        change = rc_classify(header, [old_header], roots, tracked, header_refusals)
        push!(header_ids, change === nothing ? "refused" : change.id)
    end
    header_ids == ["H2", "H2", "refused"] && length(header_refusals) == 1 &&
        startswith(header_refusals[1], "C5") ||
        error("rc_warm: the headers give ", header_ids, " and ", header_refusals)
    documented_parent = Module()
    Core.eval(documented_parent, old_header.entry.expr)
    documented = Base.invokelatest(getglobal, documented_parent, :D)
    module_doc(m) = (docs = Base.Docs.meta(m; autoinit = false);
                     binding = Base.Docs.Binding(m, nameof(m));
                     docs === nothing || !haskey(docs, binding) ? nothing :
                         join(docs[binding].docs[Union{}].text))
    Base.invokelatest(module_doc, documented) == "old" ||
        error("rc_warm: the module of the old header has no docstring")
    Base.invokelatest(rc_set_module_doc!, documented, new_header.entry.expr)
    Base.invokelatest(getglobal, documented_parent, :D) === documented &&
        Base.invokelatest(module_doc, documented) == "new" ||
        error("rc_warm: the docstring of the module is not replaced in place")
    Base.invokelatest(rc_set_module_doc!, documented, plain_header.entry.expr)
    Base.invokelatest(module_doc, documented) === nothing ||
        error("rc_warm: a header without a docstring keeps the docstring of the module")
    rc_resolution(Base, [:sin, :nosuchname])[:sin] === sin || error("rc_warm: sin does not resolve in Base")
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
    # The constants that an evaluation binds again: a new value and a new name
    # are in the list, an identical value is not.
    rebinds = Module(:RcWarmRebinds)
    Core.eval(rebinds, :(const same = 1; const other = [1]))
    rebinds_world = Base.get_world_counter()
    Core.eval(rebinds, :(const same = 1; const other = [2]; const added = Int))
    rebound = sort!(Base.invokelatest(rc_rebound_constants, rebinds, rebinds_world); by = first)
    length(rebound) == 2 && rebound[1] == (:added, nothing) && rebound[2][1] === :other &&
        something(rebound[2][2]) == [1] || error("rc_warm: the constants bound again are ", rebound)
    rc_is_defined_type(Some{Any}(Array)) && !rc_is_defined_type(Some{Any}(Vector)) &&
        !rc_is_defined_type(Some{Any}(Union{Int, Nothing})) && !rc_is_defined_type(nothing) ||
        error("rc_warm: the types that a definition makes are not told from their aliases")
    # A constant with another value drops what the session keeps of the
    # statements of the trace; a new name drops only the statements that failed.
    kept_cache = copy(RC_TRACE_CACHE)
    kept_failed = copy(RC_TRACE_FAILED)
    RC_TRACE_CACHE["rc-warm"] = Int
    push!(RC_TRACE_FAILED, "rc-warm")
    rc_forget_statements!(rebound[1:1])
    haskey(RC_TRACE_CACHE, "rc-warm") && isempty(RC_TRACE_FAILED) ||
        error("rc_warm: a new name does not drop only the statements that failed")
    rc_forget_statements!(rebound)
    isempty(RC_TRACE_CACHE) || error("rc_warm: a constant with another value keeps the types of the statements")
    merge!(RC_TRACE_CACHE, kept_cache)
    union!(RC_TRACE_FAILED, kept_failed)
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
    # world, a changed one does not. The loop is evaluated with a place, as an
    # item is: a method keeps the place of the top-level expression that
    # defined it, also when an `eval` inside that expression defines it, and a
    # kept method takes the place of the new definition.
    warm = Module(:RcWarm)
    warm_file = Symbol("rc-warm.jl")
    warm_loop(three, line) = Expr(:toplevel, LineNumberNode(line, warm_file),
        Meta.parse("for (name, k) in ((:two, 2), (:three, $three)); @eval \$name(x) = \$k * x; end"))
    Core.eval(warm, warm_loop(3, 7))
    warm_two = only(methods(Base.invokelatest(getfield, warm, :two)))
    warm_three = only(methods(Base.invokelatest(getfield, warm, :three)))
    (warm_two.toplevel_file, warm_two.toplevel_line, warm_three.toplevel_line) == (warm_file, 7, 7) ||
        error("rc_warm: a method has the top-level place ", warm_two.toplevel_file, ":", warm_two.toplevel_line)
    world = Base.get_world_counter()
    rc_install_filter(rc_method_filter)
    try
        Core.eval(warm, warm_loop(30, 9))
    finally
        rc_install_filter(nothing)
    end
    warm_kept = rc_take_kept!()
    warm_kept == [warm_two] || error("rc_warm: the filter kept ", length(warm_kept), " methods")
    warm_two.toplevel_line == 9 || error("rc_warm: a kept method keeps the top-level line ", warm_two.toplevel_line)
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
