# The report of the reach over real commits (Step 7 of
# plan/pending/a-rebuild-equals-a-whole-build.md): how many expressions a
# rebuild evaluates again, because the code that they run changed, for each
# commit of a range. The tool reads the tracked list of a store, walks the
# commits in a checkout of its own, and runs no build and no image: it loads
# the sources of the harness beside it.
#
#   julia reach_report.jl --store STORE.toml --repo MAIN --checkout DIR --commits A..B [--verbose]
#
#   --store     the store.toml whose tracked files and roots the report takes
#   --repo      the checkout that the tracked paths of the store name
#   --checkout  a checkout of the same repository that the tool moves from
#               commit to commit (`git worktree add --detach DIR A`); the
#               tracked files of other repositories are read where they are
#   --commits   the range, as `git rev-list` takes it
#   --verbose   the hit expressions of each commit, and the name that hit each
#
# One line for each commit: the changed expressions, the names that they
# change, the names that use one of them, and the expressions that the reach
# hits, by kind. A file that the store tracks and a commit does not have is
# left out of that commit.
import TOML

const HARNESS = let wrapper = Module(:ReactiveHarness)
    Base.include(wrapper, joinpath(@__DIR__, "..", "..", "..", "stdlib", "ReactiveCompiler", "src", "ReactiveCompiler.jl"))
    Base.invokelatest(getfield, wrapper, :ReactiveCompiler)
end

function option(name; default = nothing)
    index = findfirst(==(name), ARGS)
    index === nothing && return default === nothing ? error("missing ", name) : default
    return ARGS[index + 1]
end

git(dir, arguments...) = readchomp(`git -C $dir $arguments`)

# The ledger of the tracked files that exist: the items, and the root of each file.
function ledger(files, roots)
    kept = [index for index in eachindex(files) if isfile(files[index])]
    paths = String[files[index] for index in kept]
    items = HARNESS.rc_ledger(paths, paths)
    return items, Vector{Symbol}[roots[index] for index in kept], paths
end

# The items by the path of their file and their key.
function index_items(items)
    found = Dict{String, Dict{UInt64, Any}}()
    for item in items
        get!(found, item.path, Dict{UInt64, Any}())[item.entry.key] = item
    end
    return found
end

# For some hit expressions of each kind, the chain of names from the name that
# the expression runs to a changed name: each name of the chain names the next.
function print_paths(reach, changed, items, changed_items)
    parent = Dict{Symbol, Symbol}()
    pending = collect(changed)
    seen = Set{Symbol}(changed)
    while !isempty(pending)
        name = popfirst!(pending)
        for user in get(reach.users, name, ())
            user in seen && continue
            push!(seen, user)
            parent[user] = name
            push!(pending, user)
        end
    end
    shown = Dict{Symbol, Int}()
    for item in items
        item in changed_items && continue
        name = HARNESS.rc_reach_hit(item, seen)
        name === nothing && continue
        get!(shown, item.kind, 0) >= 12 && continue
        shown[item.kind] += 1
        chain = Symbol[name]
        while haskey(parent, chain[end])
            push!(chain, parent[chain[end]])
        end
        println("    ", item.kind, " ", HARNESS.rc_where(item), " ", HARNESS.rc_what(item), ": ", join(chain, " > "))
    end
end

function report()
    config = TOML.parsefile(option("--store"))["config"]
    repo = rstrip(abspath(option("--repo")), '/')
    checkout = rstrip(abspath(option("--checkout")), '/')
    verbose = "--verbose" in ARGS
    files = String[startswith(entry["file"], repo * "/") ? checkout * entry["file"][length(repo) + 1:end] : entry["file"]
                   for entry in config["tracked"]]
    roots = Vector{Symbol}[isempty(entry["root"]) ? Symbol[] : Symbol.(split(entry["root"], '.'))
                           for entry in config["tracked"]]
    commits = split(git(checkout, "rev-list", "--reverse", option("--commits")))
    first_parent = git(checkout, "rev-parse", string(commits[1], "^"))
    run(`git -C $checkout checkout -q --detach $first_parent`)
    old_items, old_roots, _ = ledger(files, roots)
    old_reach = HARNESS.rc_reach(old_items, old_roots)
    kinds = (:const, :global, :other, :method, :type, :macro)
    println("items of the first ledger: ", length(old_items), " in ", length(unique(item.path for item in old_items)), " files; ",
            join((string(count(item -> item.kind === kind, old_items), " ", kind) for kind in kinds), ", "))
    println("with a name that they run: ",
            join((string(count(item -> item.kind === kind && !isempty(HARNESS.rc_names(item).runs), old_items), " ", kind)
                  for kind in kinds), ", "))
    totals = Dict{Symbol, Int}(kind => 0 for kind in kinds)
    for commit in commits
        run(`git -C $checkout checkout -q --detach $commit`)
        new_items, new_roots, _ = ledger(files, roots)
        reach = HARNESS.rc_reach(new_items, new_roots)
        old_index = index_items(old_items)
        new_index = index_items(new_items)
        changed = Set{Symbol}()
        changed_items = Base.IdSet{Any}()
        changed_count = 0
        for item in new_items
            haskey(get(old_index, item.path, Dict{UInt64, Any}()), item.entry.key) && continue
            push!(changed_items, item)
            changed_count += 1
            union!(changed, HARNESS.rc_filed_names(reach, new_roots, item))
        end
        for item in old_items
            haskey(get(new_index, item.path, Dict{UInt64, Any}()), item.entry.key) && continue
            changed_count += 1
            union!(changed, HARNESS.rc_filed_names(old_reach, old_roots, item))
        end
        affected = Set{Symbol}()
        HARNESS.rc_affected!(affected, reach, changed)
        hits = Dict{Symbol, Int}(kind => 0 for kind in kinds)
        lines = String[]
        for item in new_items
            item in changed_items && continue
            name = HARNESS.rc_reach_hit(item, affected)
            name === nothing && continue
            hits[item.kind] = get(hits, item.kind, 0) + 1
            verbose && push!(lines, string("    ", item.kind, " ", HARNESS.rc_where(item), " ", HARNESS.rc_what(item), " runs ", name))
        end
        for kind in kinds
            totals[kind] += hits[kind]
        end
        println(commit[1:9], ": ", changed_count, " changed, ", length(changed), " names, ", length(affected), " affected; hits: ",
                join((string(hits[kind], " ", kind) for kind in kinds if hits[kind] > 0), ", "))
        verbose && foreach(println, lines)
        "--paths" in ARGS && print_paths(reach, changed, new_items, changed_items)
        verbose && println("    changed names: ", join(sort!(collect(changed)), " "))
        old_items, old_roots, old_reach = new_items, new_roots, reach
    end
    println("sum over ", length(commits), " commits: ", join((string(totals[kind], " ", kind) for kind in kinds), ", "))
end

report()
