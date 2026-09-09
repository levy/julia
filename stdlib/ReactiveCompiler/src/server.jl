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

# The tail of the object script: the image carries no path of this build.
function rc_before_write()
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
                             rc_read_reads(s["old_reads"]), s["reads_out"], s["refusal_out"])
    rc_precompile_trace(s["trace"])
    rc_report_new(state)
    return nothing
end

function rc_dispatch(request::String, saves::Ref{Int})
    parts = split(request, ' '; limit = 2)
    command = parts[1]
    argument = length(parts) == 2 ? String(parts[2]) : ""
    if command == "apply"
        rc_apply_spec(argument)
        return "ok"
    elseif command == "save"
        rc_save(argument)
        saves[] += 1
        return "ok"
    elseif command == "trim"
        parts = split(argument, ' '; limit = 2)
        rc_save(String(parts[1]); trim = true, overrides = length(parts) == 2 ? String(parts[2]) : "")
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
