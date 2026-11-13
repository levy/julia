# The compiler server of a reactive store (Stage D of the plan): a process in
# the output mode of the rebuild child that stays, applies the edits of the
# tracked sources, and saves an image without an exit. A client (the
# `materialize_app` of PackageCompiler, or any build tool) starts it with
# `julia --reactive-server=<socket>` on the image of a snapshot and talks to
# it over the Unix socket: one request per connection, one line each way.
# The requests:
#
#   apply <spec.toml>   the arguments of `rc_apply_tracked` and the trace
#   save <archive>      a forked child writes the image and exits
#   trim <archive> [dir]  the same with the trim of the compiler: the trimmed
#                       product; the patches of a trimmed build are included
#                       from dir (test/trimming of the Julia tree); the
#                       verifier's messages go to <archive>.log
#   status              the world, the saves, the resident size
#   quit                the server exits, and writes no image
#
# The reply is `ok ...`, `refused <refusal file>` or `error <message>`. The
# save: `jl_reactive_fork` (the child opens its own /proc/self/mem, or its
# code would land in the parent), the child runs the tail of the object
# script, points the output at the archive and writes it with the exit path
# of the compiler, then `_exit`s; the parent keeps its heap, its ledger and
# its compiled code. The reuse test of the next save sees the founding image
# as image code: the delta of a save holds every change since the server
# started, and the link takes the founding's texts and this delta.

const RC_AF_UNIX = Cint(1)
const RC_SOCK_STREAM = Cint(1)

# sockaddr_un: a family of two bytes, then the path in 108 bytes.
function rc_sockaddr(path::String)
    length(path) < 108 || error("rc: the socket path is too long: ", path)
    addr = zeros(UInt8, 110)
    addr[1] = UInt8(RC_AF_UNIX)
    copyto!(addr, 3, codeunits(path), 1, length(path))
    return addr
end

function rc_listen(path::String)
    rm(path; force = true)
    fd = ccall(:socket, Cint, (Cint, Cint, Cint), RC_AF_UNIX, RC_SOCK_STREAM, 0)
    fd < 0 && error("rc: socket: ", Libc.strerror())
    addr = rc_sockaddr(path)
    ccall(:bind, Cint, (Cint, Ptr{UInt8}, UInt32), fd, addr, length(addr)) == 0 ||
        error("rc: bind ", path, ": ", Libc.strerror())
    ccall(:listen, Cint, (Cint, Cint), fd, 4) == 0 || error("rc: listen: ", Libc.strerror())
    return fd
end

function rc_read_line(fd::Cint)
    line = UInt8[]
    byte = Ref{UInt8}(0)
    while length(line) < 1 << 16
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, byte, 1)
        n == 1 || break
        byte[] == UInt8('\n') && break
        push!(line, byte[])
    end
    return String(line)
end

function rc_write_all(fd::Cint, text::String)
    data = codeunits(text)
    offset = 0
    while offset < length(data)
        n = ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, pointer(data, offset + 1), length(data) - offset)
        n > 0 || error("rc: write: ", Libc.strerror())
        offset += n
    end
    return nothing
end

rc_root_paths(roots) = Vector{Symbol}[isempty(root) ? Symbol[] : Symbol.(split(root, '.')) for root in roots]

# The reads listing of a snapshot: `<hash> <path>` lines.
function rc_read_reads(listing::String)
    reads = Tuple{String, String}[]
    isfile(listing) || return reads
    for line in eachline(listing)
        parts = split(line, " "; limit = 2)
        length(parts) == 2 && push!(reads, (String(parts[2]), String(parts[1])))
    end
    return reads
end

function rc_resident_kb()
    for line in eachline("/proc/self/status")
        startswith(line, "VmRSS:") && return parse(Int, split(line)[2])
    end
    return 0
end

# Whether no world of the image runs the code instance: its range of worlds is
# closed, and the world of the compiler is outside it. The image writer drops
# such a code instance from the chain of its method instance
# (`codeinst_may_be_runnable` in staticdata.c).
function rc_is_dead_code(ci::Core.CodeInstance)
    ci.max_world == typemax(UInt) && return false
    typeinf = unsafe_load(cglobal(:jl_typeinf_world, UInt))
    return !(ci.min_world <= typeinf <= ci.max_world)
end

# Add to `named` each code instance that the code `x` names.
function rc_named_code!(named::Base.IdSet{Core.CodeInstance}, @nospecialize(x))
    if x isa Core.CodeInstance
        push!(named, x)
    elseif x isa Expr
        for argument in x.args
            rc_named_code!(named, argument)
        end
    elseif x isa Vector{Any}
        for i in eachindex(x)
            isassigned(x, i) && rc_named_code!(named, x[i])
        end
    elseif x isa Union{QuoteNode, Core.ReturnNode, Core.PiNode, Core.PhiNode, Core.PhiCNode, Core.UpsilonNode,
                       Core.GotoIfNot, Core.EnterNode}
        for i in 1:nfields(x)
            isdefined(x, i) && rc_named_code!(named, getfield(x, i))
        end
    end
    return named
end

# The code instances that the inferred code of the live code instances of the
# method names: the callees of its `:invoke` statements.
function rc_named_code(method::Method)
    named = Base.IdSet{Core.CodeInstance}()
    instances = Any[mi for mi in Base.specializations(method)]
    isdefined(method, :unspecialized) && push!(instances, method.unspecialized)
    for mi in instances
        mi isa Core.MethodInstance || continue
        ci = isdefined(mi, :cache) ? mi.cache : nothing
        while ci !== nothing
            if !rc_is_dead_code(ci) && isdefined(ci, :inferred)
                inferred = ci.inferred
                code = inferred isa String ? Base._uncompressed_ir(ci, inferred) : inferred
                code isa Core.CodeInfo && rc_named_code!(named, code.code)
            end
            ci = isdefined(ci, :next) ? ci.next : nothing
        end
    end
    return named
end

# Empty each root of a method that holds a dead code instance which no code of
# the method names, and answer their count. Julia appends to the roots of a
# method and takes nothing out. The inferred code of a method names the code
# instances of its callees through the roots, and after a callee is compiled
# again the root of before stays. The image writer follows the roots, so a
# dead code instance there stays in the image with the dead code that it
# calls, and each rebuild left more of it (finding 24). The index of a root
# is its name in the code, so a root is emptied and stays in its place.
function rc_drop_dead_roots!()
    dropped = 0
    Base.visit(Core.methodtable) do method
        isdefined(method, :roots) || return
        roots = method.roots
        dead = Int[]
        for i in eachindex(roots)
            isassigned(roots, i) || continue
            root = roots[i]
            root isa Core.CodeInstance && rc_is_dead_code(root) && push!(dead, i)
        end
        isempty(dead) && return
        named = rc_named_code(method)
        for i in dead
            roots[i] in named && continue
            roots[i] = nothing
            dropped += 1
        end
    end
    return dropped
end

# The tail of the object script: the image carries no path of this build.
function rc_before_write()
    # The ledger and the parses of the tracked files serve the next apply of
    # the server; in the image they are the parsed sources of every file.
    RC_LEDGER_CACHE[] = nothing
    empty!(RC_PARSED)
    # The image is the save of the apply that the process holds.
    RC_APPLY_OPEN[] = false
    dropped = rc_drop_dead_roots!()
    dropped == 0 || println("rc: ", dropped, " roots of methods held dead code and are empty now")
    empty!(Base.Filesystem.TEMP_CLEANUP)
    empty!(Core.ARGS)
    empty!(Base.ARGS)
    empty!(LOAD_PATH)
    empty!(DEPOT_PATH)
    empty!(Base.TOML_CACHE.d)
    Base.TOML.reinit!(Base.TOML_CACHE.p, "")
    @eval Sys begin
        BINDIR = ""
        STDLIB = ""
    end
    return nothing
end

# The child of a trimmed save writes its output to a file: the verifier
# names the call sites it refuses there, and the builder reads them.
function rc_redirect_output(path::String)
    fd = ccall(:open, Cint, (Cstring, Cint, Cint), path, 0o1101, 0o644)   # O_WRONLY | O_CREAT | O_TRUNC
    fd < 0 && return
    ccall(:dup2, Cint, (Cint, Cint), fd, 1)
    ccall(:dup2, Cint, (Cint, Cint), fd, 2)
    ccall(:close, Cint, (Cint,), fd)
    return
end

# A write to a file descriptor without the event loop: the forked child's.
rc_write_raw(fd::Integer, text::String) =
    ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, text, sizeof(text))

# Whether this module is the harness that the image of the process holds: the
# standard library that `Base.require` gives. A client loads the sources of
# another version of the harness into a module of its own, for a store whose
# image holds an older one; that module is not the harness of the image.
rc_is_image_harness() =
    get(Base.loaded_modules, Base.PkgId(Base.UUID("1dda119b-71a3-45fb-bd14-d17b1eb16859"), "ReactiveCompiler"),
        nothing) === @__MODULE__

# Whether `mod` is this module or a module inside it.
function rc_is_harness_module(mod::Module)
    while true
        mod === (@__MODULE__) && return true
        parent = parentmodule(mod)
        parent === mod && return false
        mod = parent
    end
end

# Delete each method of this module, and of the modules inside it, when it is
# not the harness of the image, and answer how many: the image that the process
# writes next then holds no code of a harness that a client loaded from its
# sources. A deletion closes a method from the next world on, so the code that
# runs now, in an earlier world, calls the harness as before. The list of the
# modules that have documentation holds these modules no more, because the list
# is a root of the image.
function rc_remove_harness!()
    rc_is_image_harness() && return 0
    found = Method[]
    rc_each_live_method() do method
        rc_is_harness_module(method.module) && push!(found, method)
    end
    foreach(Base.delete_method, found)
    filter!(!rc_is_harness_module, Base.Docs.modules)
    return length(found)
end

function rc_save(archive::String; trim::Bool = false, overrides::String = "")
    flush(stdout)
    flush(stderr)
    t0 = time()
    pid = ccall((:jl_reactive_fork, "libjulia-codegen"), Cint, ())
    pid < 0 && error("rc: fork: ", Libc.strerror())
    if pid == 0
        # The child never returns into the loop: an exception of the writer
        # would answer the request from the child and leave it on the socket.
        try
            trim && rc_redirect_output(archive * ".log")
            rc_before_write()
            if trim
                # The patches of a trimmed build, then the entry points of the
                # trim: every `@ccallable` method, the way `juliac` adds them;
                # the `__init__`s join at the write.
                for name in ("juliac-trim-base.jl", "juliac-trim-stdlib.jl")
                    isempty(overrides) || Base.include(Main, joinpath(overrides, name))
                end
                trim_entrypoints!()
                # The memo of the trimmed pass lives beside the store: the
                # served code instances of the last accepted pass and their
                # callees, which this pass takes without a compile.
                ccall(:jl_reactive_set_trim_memo, Cvoid, (Cstring,), joinpath(dirname(dirname(archive)), "trim-memo.txt"))
                ccall(:jl_reactive_set_trim, Cvoid, (Cint,), 1)
            end
            rc_remove_harness!()
            ccall(:jl_reactive_set_output, Cvoid, (Cstring,), archive)
            ccall(:jl_write_compiler_output, Cvoid, ())
        catch e
            # The child has no event loop of its own after the fork: the
            # report goes to the file descriptor directly. And the writer
            # forbids inference once it started (`jl_type_infer` aborts), so
            # the report compiles nothing: the message of an error, else the
            # name of the exception's type, through the runtime.
            rc_write_raw(2, "rc: the save child failed: ")
            if e isa ErrorException
                rc_write_raw(2, e.msg)
            else
                name = ccall(:jl_typeof_str, Ptr{UInt8}, (Any,), e)
                ccall(:write, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), 2, name, ccall(:strlen, Csize_t, (Ptr{UInt8},), name))
            end
            rc_write_raw(2, "\n")
            ccall(:_exit, Cvoid, (Cint,), 1)
        end
        ccall(:_exit, Cvoid, (Cint,), 0)
    end
    status = Ref{Cint}(0)
    ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, status, 0) == pid ||
        error("rc: waitpid: ", Libc.strerror())
    status[] == 0 || error("rc: the ", trim ? "trim" : "save", " child exited with status ", status[])
    isfile(archive) || error("rc: the save child wrote no ", archive)
    println("rc: saved ", archive, " in ", round(time() - t0; digits = 1), " s")
    return nothing
end

function rc_apply_spec(spec::String)
    s = Base.parsed_toml(spec)
    state = rc_apply_tracked(String.(s["old_files"]), rc_root_paths(s["old_roots"]), String.(s["old_copies"]),
                             String.(s["files"]), rc_root_paths(s["roots"]),
                             rc_read_reads(s["old_reads"]), s["reads_out"], s["refusal_out"]; keep_ledger = true)
    rc_precompile_trace(s["trace"])
    rc_report_new(state)
    return nothing
end

function rc_dispatch(request::String, saves::Ref{Int})
    parts = split(request, ' '; limit = 2)
    command = parts[1]
    argument = length(parts) == 2 ? String(parts[2]) : ""
    if command == "apply"
        # An apply that no save followed is still in the heap: the client
        # counts from the last save, so this request would apply it again.
        RC_APPLY_OPEN[] && error("rc: the server holds an apply that no save wrote")
        rc_apply_spec(argument)
        return "ok"
    elseif command == "save"
        rc_save(argument)
        RC_APPLY_OPEN[] = false
        saves[] += 1
        return "ok"
    elseif command == "trim"
        parts = split(argument, ' '; limit = 2)
        rc_save(String(parts[1]); trim = true, overrides = length(parts) == 2 ? String(parts[2]) : "")
        RC_APPLY_OPEN[] = false
        return "ok"
    elseif command == "status"
        return string("ok world=", Base.get_world_counter(), " saves=", saves[], " rss_kb=", rc_resident_kb())
    elseif command == "quit"
        return "ok"
    end
    return "error unknown request $request"
end

function rc_serve(socket::String)
    fd = rc_listen(socket)
    saves = Ref(0)
    println("rc: server ", ccall(:getpid, Cint, ()), " listens on ", socket)
    flush(stdout)
    while true
        client = ccall(:accept, Cint, (Cint, Ptr{Cvoid}, Ptr{Cvoid}), fd, C_NULL, C_NULL)
        client < 0 && error("rc: accept: ", Libc.strerror())
        request = rc_read_line(client)
        t0 = time()
        println("rc: request ", request)
        reply = try
            rc_dispatch(request, saves)
        catch e
            if e isa RcRefusal
                string("refused ", e.path)
            else
                showerror(stdout, e, catch_backtrace())
                println(stdout)
                string("error ", sprint(showerror, e))
            end
        end
        println("rc: reply ", reply, " in ", round(time() - t0; digits = 1), " s")
        flush(stdout)
        rc_write_all(client, reply * "\n")
        ccall(:close, Cint, (Cint,), client)
        startswith(request, "quit") && break
        # D4: a request that fails while the heap holds an apply that no save
        # wrote leaves a heap that is not the image of the last save. The
        # server exits, and the next build starts one from that image.
        if startswith(reply, "error") && RC_APPLY_OPEN[]
            println("rc: the server exits: its heap holds an apply that no save wrote")
            break
        end
    end
    ccall(:close, Cint, (Cint,), fd)
    rm(socket; force = true)
    ccall(:jl_reactive_set_output, Cvoid, (Ptr{UInt8},), C_NULL)
    println("rc: server exits")
    flush(stdout)
    exit(0)
end

# The entry of `julia --reactive-server=<socket>`. The process was started
# on the image of a snapshot in the output mode of the rebuild
# (`--output-o`), which runs no `__init__`; the image write emptied the
# paths of the process, so they are set again from the options: the
# project of `--project` and the standard library of this Julia. Then the
# loop runs until `quit`, and never returns.
function serve(socket::String)
    Base.reinit_stdio()
    bindir = ccall(:jl_get_julia_bindir, Any, ())::String
    Core.eval(Base.Sys, :(BINDIR = $bindir))
    stdlib = normpath(joinpath(bindir, "..", "share", "julia", "stdlib",
                               string('v', VERSION.major, '.', VERSION.minor)))
    Core.eval(Base.Sys, :(STDLIB = $stdlib))
    project = Base.JLOptions().project
    project = project == C_NULL ? "" : unsafe_string(project)
    copy!(LOAD_PATH, isempty(project) ? ["@stdlib"] : [project, "@stdlib"])
    Base.init_depot_path()
    rc_serve(socket)
end
