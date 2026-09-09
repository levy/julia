"""
    Materialize

The M4 entry point. A store is a directory that persists across processes:
it holds a chain of snapshots, and each snapshot holds the text objects that
its build emitted, the linked image, and a copy of the tracked source files.

    materialize(store)

starts a fresh child process that boots from the image of the latest snapshot,
applies the changes of the tracked source files (tool/m4_child.jl with
src/SourceDiff.jl), runs the workload, and emits the delta at exit. The driver
then links the text objects of every snapshot in the chain, the delta, and the
fresh `sysimg.o` and `metadata.o` into the image of the new snapshot. With an
empty store the same call is the full build.

    run_snapshot(store)

runs the image of the latest snapshot with the same workload, as a check.

The store is described by `store.toml`. The `[config]` table names the patched
Julia, the project, the packages, the tracked files and the workload; one
`[[snapshot]]` table per snapshot records the chain. The caller writes the
config once; this module appends the snapshots.

Run as a script:  julia Materialize.jl <store> materialize | run [id]
"""
module Materialize

import TOML

export materialize, run_snapshot

const store_file = "store.toml"

load_store(store::AbstractString) = TOML.parsefile(joinpath(store, store_file))

function save_store(store::AbstractString, data)
    open(joinpath(store, store_file), "w") do io
        TOML.print(io, data)
    end
end

snapshots(data) = sort(get(data, "snapshot", Dict{String, Any}[]); by = s -> s["id"])

snapshot_dir(store, id) = joinpath(store, "s$id")

"The text objects of one snapshot, in a stable order."
text_objects(dir) = [joinpath(dir, name) for name in sort(readdir(dir))
                     if startswith(name, "text") && endswith(name, ".o")]

"Print the lines of a log that carry the result, and keep the rest in the file."
function report(log_path)
    for line in eachline(log_path)
        if startswith(line, "reactive: ") || startswith(line, "m4: ") ||
           occursin(r"Network hash|Avg hops|Sequential time", line)
            println("    ", line)
        end
    end
end

"The environment of the child, from the config."
function child_env(cmd, config, store; reuse::Bool, parent_source = nothing)
    pairs = Pair{String, String}[
        "JULIA_IMAGE_THREADS" => string(config["threads"]),
        "JULIA_REACTIVE_TIMINGS" => string(config["timings"]),
        "JULIA_DEPOT_PATH" => string(joinpath(store, "depot"), ":", joinpath(homedir(), ".julia"), ":"),
        "RC_PROJECT" => config["project"],
        "RC_PACKAGES" => join(config["packages"], ','),
        "RC_SRC" => abspath(joinpath(@__DIR__)),
        "RC_TRACKED" => join(config["tracked"], ':'),
        "RC_TRACKED_MODULES" => join(config["tracked_modules"], ':'),
        "RC_WORKLOAD" => config["workload"],
    ]
    reuse && push!(pairs, "JULIA_REACTIVE_REUSE" => "1")
    parent_source === nothing || push!(pairs, "RC_PARENT_SOURCE" => abspath(parent_source))
    return addenv(cmd, pairs...)
end

function materialize(store::AbstractString)
    store = abspath(store)
    data = load_store(store)
    config = data["config"]
    chain = snapshots(data)
    parent = isempty(chain) ? nothing : chain[end]
    id = isempty(chain) ? 1 : chain[end]["id"] + 1
    dir = snapshot_dir(store, id)
    mkpath(joinpath(dir, "source"))
    mkpath(joinpath(store, "depot"))
    julia_home = config["julia_home"]
    julia = joinpath(julia_home, "usr", "bin", "julia")
    sysimage = parent === nothing ? joinpath(julia_home, "usr", "lib", "julia", "sys.so") :
                                    joinpath(snapshot_dir(store, parent["id"]), "image.so")
    archive = joinpath(dir, "delta.a")
    child = abspath(joinpath(@__DIR__, "..", "tool", "m4_child.jl"))
    build_log = joinpath(dir, "build.log")
    println("=== materialize s$id from ", parent === nothing ? "the base image" : "s$(parent["id"])")
    cmd = Cmd(`$julia --project=$(config["project"]) --startup-file=no --pkgimages=no
               --sysimage=$sysimage -C native --output-o $archive $child`;
              dir = config["project_dir"])
    cmd = child_env(cmd, config, store; reuse = parent !== nothing,
                    parent_source = parent === nothing ? nothing :
                                    joinpath(snapshot_dir(store, parent["id"]), "source"))
    t_child = @elapsed success_child = success(pipeline(cmd; stdout = build_log, stderr = build_log))
    if !success_child
        foreach(println, last(readlines(build_log), 20))
        error("the build child failed; the log is $build_log")
    end
    report(build_log)
    t_extract = @elapsed Base.run(Cmd(`ar x $archive`; dir))
    ancestors = [snapshot_dir(store, s["id"]) for s in chain]
    objects = reduce(vcat, [text_objects(d) for d in ancestors]; init = String[])
    append!(objects, text_objects(dir))
    push!(objects, joinpath(dir, "sysimg.o"), joinpath(dir, "metadata.o"))
    image = joinpath(dir, "image.so")
    link_log = joinpath(dir, "link.log")
    lib = joinpath(julia_home, "usr", "lib")
    t_link = @elapsed success_link = success(pipeline(
        `g++ -shared -fPIC -L$(joinpath(lib, "julia")) -L$lib -o $image
         -Wl,--whole-archive $objects -Wl,--no-whole-archive -ljulia-internal -ljulia`;
        stdout = link_log, stderr = link_log))
    if !success_link
        foreach(println, last(readlines(link_log), 20))
        error("the link failed; the log is $link_log")
    end
    for (index, path) in enumerate(config["tracked"])
        cp(joinpath(config["project_dir"], path),
           joinpath(dir, "source", string(index, "-", basename(path))); force = true)
    end
    delta = something(findfirst(l -> startswith(l, "reactive: delta"), readlines(build_log)), 0)
    entry = Dict{String, Any}(
        "id" => id,
        "parent" => parent === nothing ? 0 : parent["id"],
        "created" => string(Libc.strftime("%Y-%m-%d %H:%M:%S", time())),
        "delta" => delta == 0 ? "full build" : readlines(build_log)[delta])
    push!(get!(Vector{Any}, data, "snapshot"), entry)
    save_store(store, data)
    println("=== s$id: child ", round(t_child, digits = 1), " s, extract ",
            round(t_extract, digits = 1), " s, link ", round(t_link, digits = 1),
            " s; image ", round(filesize(image) / 1e6, digits = 1), " MB; ", entry["delta"])
    return id
end

function run_snapshot(store::AbstractString, id::Union{Int, Nothing} = nothing)
    store = abspath(store)
    data = load_store(store)
    config = data["config"]
    chain = snapshots(data)
    isempty(chain) && error("the store has no snapshot")
    id === nothing && (id = chain[end]["id"])
    dir = snapshot_dir(store, id)
    julia = joinpath(config["julia_home"], "usr", "bin", "julia")
    child = abspath(joinpath(@__DIR__, "..", "tool", "m4_child.jl"))
    run_log = joinpath(dir, "run-$(Libc.strftime("%H%M%S", time())).log")
    println("=== run s$id")
    cmd = Cmd(`$julia --project=$(config["project"]) --startup-file=no --pkgimages=no
               --sysimage=$(joinpath(dir, "image.so")) $child`;
              dir = config["project_dir"])
    cmd = child_env(cmd, config, store; reuse = false, parent_source = joinpath(dir, "source"))
    t_run = @elapsed success_run = success(pipeline(cmd; stdout = run_log, stderr = run_log))
    if !success_run
        foreach(println, last(readlines(run_log), 20))
        error("the run failed; the log is $run_log")
    end
    report(run_log)
    println("=== run s$id: ", round(t_run, digits = 1), " s")
    return run_log
end

function main(args)
    length(args) >= 2 || (println("usage: julia Materialize.jl <store> materialize | run [id]"); exit(2))
    store, command = args[1], args[2]
    if command == "materialize"
        materialize(store)
    elseif command == "run"
        run_snapshot(store, length(args) >= 3 ? parse(Int, args[3]) : nothing)
    else
        println("unknown command ", command)
        exit(2)
    end
end

end # module Materialize

if abspath(PROGRAM_FILE) == @__FILE__
    Materialize.main(ARGS)
end
