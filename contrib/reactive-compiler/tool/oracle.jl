# The oracle of Stage 0 (plan/pending/robust-incremental-compiler.md): the
# digest of an image, printed from inside a process that boots from it.
#
#   julia -J <bundle>/lib/julia/sys.so oracle.jl --tracked Mod[,Mod...] [--trace trace.jl]
#
# One line per fact, sorted, so that `diff` compares two images:
#   method <signature> <hash of the lowered code>   a method of a tracked
#                                                   module, valid in the
#                                                   current world; without
#                                                   gensym counters and
#                                                   quoted line numbers
#   root <signature> compiled|inferred|absent|unresolved|gensym
#                                                   a statement of the trace;
#                                                   `gensym` names a gensym
#                                                   of a tracked module
#   global <Module>.<name> = <value>                a non-function binding of
#                                                   a tracked module
#   info ...                                        counts; not compared
#
# The digest is semantic: two images with the same method tables, the same
# compiled roots and the same globals give the same `method`, `root` and
# `global` lines, whatever their machine code looks like.

function oracle_args(args)
    tracked = String[]
    trace = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--tracked"
            append!(tracked, split(args[i + 1], ','))
            i += 2
        elseif args[i] == "--trace"
            trace = args[i + 1]
            i += 2
        else
            error("oracle: unknown argument ", args[i])
        end
    end
    isempty(tracked) && error("oracle: --tracked names no module")
    return tracked, trace
end

# The module of a dotted path, through Main or the loaded modules.
function oracle_module(path::AbstractString)
    names = Symbol.(split(path, '.'))
    mod = nothing
    if isdefined(Main, names[1])
        mod = getfield(Main, names[1])
    else
        for (pkgid, loaded) in Base.loaded_modules
            Symbol(pkgid.name) === names[1] && (mod = loaded; break)
        end
    end
    mod isa Module || error("oracle: no module ", path)
    for name in names[2:end]
        mod = getfield(mod, name)::Module
    end
    return mod
end

# Is `mod` one of the tracked modules or inside one?
function oracle_inside(mod::Module, roots)
    while true
        mod in roots && return true
        parent = parentmodule(mod)
        parent === mod && return false
        mod = parent
    end
end

# Every method table entry that is valid in `world`; `Base.visit` drops the
# entry, and with it the worlds of the method.
function oracle_entries(f, world::UInt)
    visit_entry(e) = while e !== nothing
        e.min_world <= world <= e.max_world && f(e)
        e = e.next
    end
    function visit_level(mc)
        function each(mem::Memory{Any})
            for i in 2:2:length(mem)
                isassigned(mem, i) || continue
                ei = mem[i]
                if ei isa Memory{Any}
                    for j in 2:2:length(ei)
                        isassigned(ei, j) && visit_any(ei[j])
                    end
                else
                    visit_any(ei)
                end
            end
        end
        mc.targ === nothing || each(mc.targ::Memory{Any})
        mc.arg1 === nothing || each(mc.arg1::Memory{Any})
        mc.tname === nothing || each(mc.tname::Memory{Any})
        mc.name1 === nothing || each(mc.name1::Memory{Any})
        mc.list === nothing || visit_entry(mc.list)
        mc.any === nothing || visit_any(mc.any)
    end
    visit_any(x) = x isa Core.TypeMapEntry ? visit_entry(x) : visit_level(x)
    Core.methodtable.defs === nothing || visit_any(Core.methodtable.defs)
    return nothing
end

# The dead part of the heap: the method table entries and the code instances
# that no world of the image runs. A finite `max_world` closes them, and the
# world of the compiler (`jl_typeinf_world`), which the image still runs, is
# outside their range. A reactive image drops them (staticdata.c); a stock
# image keeps them. Returns (closed entries, invalid code instances).
function oracle_dead()
    typeinf = unsafe_load(cglobal(:jl_typeinf_world, UInt))
    dead(min_world, max_world) = max_world != typemax(UInt) && !(min_world <= typeinf <= max_world)
    nentries = 0
    methods = IdSet{Method}()
    visit_all(e) = while e !== nothing
        dead(e.min_world, e.max_world) && (nentries += 1)
        e.func isa Method && push!(methods, e.func)
        e = e.next
    end
    function visit_level(mc)
        function each(mem::Memory{Any})
            for i in 2:2:length(mem)
                isassigned(mem, i) || continue
                ei = mem[i]
                if ei isa Memory{Any}
                    for j in 2:2:length(ei)
                        isassigned(ei, j) && visit_any(ei[j])
                    end
                else
                    visit_any(ei)
                end
            end
        end
        mc.targ === nothing || each(mc.targ::Memory{Any})
        mc.arg1 === nothing || each(mc.arg1::Memory{Any})
        mc.tname === nothing || each(mc.tname::Memory{Any})
        mc.name1 === nothing || each(mc.name1::Memory{Any})
        mc.list === nothing || visit_all(mc.list)
        mc.any === nothing || visit_any(mc.any)
    end
    visit_any(x) = x isa Core.TypeMapEntry ? visit_all(x) : visit_level(x)
    Core.methodtable.defs === nothing || visit_any(Core.methodtable.defs)
    ninstances = 0
    for m in methods, mi in Base.specializations(m)
        mi isa Core.MethodInstance || continue
        ci = isdefined(mi, :cache) ? mi.cache : nothing
        while ci isa Core.CodeInstance
            dead(ci.min_world, ci.max_world) && (ninstances += 1)
            ci = isdefined(ci, :next) ? ci.next : nothing
        end
    end
    return nentries, ninstances
end

# The hash of the lowered code of a method: the statements and the slot
# names, without the line information. A `LineNumberNode` inside a quoted
# literal (the body of a macro, the answer of a generator) names the line of
# the definition; it is stripped, because a rebuild that applies nothing
# leaves the quoted lines where the last evaluation put them. A generated
# method has no lowered code of its own; the code of its generator stands
# for it.
function oracle_lowered(m::Method)
    isdefined(m, :generator) && (m = only(methods(m.generator.gen)))
    ci = Base.uncompressed_ast(m)
    code = Any[oracle_strip_lines(stmt) for stmt in ci.code]
    return string(hash(oracle_canonical(repr(code)), hash(repr(ci.slotnames))); base = 16)
end

oracle_strip_lines(x) = x
oracle_strip_lines(::LineNumberNode) = LineNumberNode(0)
oracle_strip_lines(q::QuoteNode) = QuoteNode(oracle_strip_lines(q.value))
oracle_strip_lines(e::Expr) = Expr(e.head, Any[oracle_strip_lines(a) for a in e.args]...)

# The name of an anonymous function, a closure or a generator carries the
# gensym counters of its process (`var"##3#4"`, `var"#f##0#f##1"`); a chain
# and a founding count differently. The digest drops the counters.
oracle_canonical(text::AbstractString) = replace(text, r"#+\d+" => "#")

# The state of a signature: `compiled` when a code instance valid in `world`
# has native code, `inferred` when one exists without native code, `absent`
# when no method instance has the signature.
function oracle_root_state(sig, world::UInt)
    matches = Base._methods_by_ftype(sig, -1, world)
    matches === nothing && return "absent"
    for match in matches
        for mi in Base.specializations(match.method)
            mi isa Core.MethodInstance && mi.specTypes === sig || continue
            ci = isdefined(mi, :cache) ? mi.cache : nothing
            state = "absent"
            while ci isa Core.CodeInstance
                if ci.min_world <= world <= ci.max_world
                    ci.invoke != C_NULL && return "compiled"
                    state = "inferred"
                end
                ci = isdefined(ci, :next) ? ci.next : nothing
            end
            return state
        end
    end
    return "absent"
end

function oracle_main(args)
    tracked, trace = oracle_args(args)
    roots = Module[oracle_module(path) for path in tracked]
    world = Base.get_world_counter()
    lines = String[]
    # A redefinition does not close the world of the replaced entry: both
    # entries stay valid, and dispatch takes the newest one (`gf.c`,
    # `get_intersect_visitor`). The digest keeps the newest entry of each
    # signature; the shadowed ones are dead code, counted in an `info` line.
    newest = Dict{String, Tuple{UInt, Method}}()
    nshadowed = 0
    oracle_entries(world) do e
        m = e.func
        m isa Method || return
        oracle_inside(m.module, roots) || return
        key = string(m.sig)
        if haskey(newest, key)
            nshadowed += 1
            newest[key][1] < e.min_world || return
        end
        newest[key] = (e.min_world, m)
    end
    ninstances = 0
    for (_, (_, m)) in newest
        for mi in Base.specializations(m)
            mi isa Core.MethodInstance || continue
            ci = isdefined(mi, :cache) ? mi.cache : nothing
            while ci isa Core.CodeInstance
                ci.min_world <= world <= ci.max_world && (ninstances += 1; break)
                ci = isdefined(ci, :next) ? ci.next : nothing
            end
        end
        push!(lines, string("method ", oracle_canonical(string(m.sig)), " ", oracle_lowered(m)))
    end
    for mod in roots, name in names(mod; all = true, imported = false)
        startswith(string(name), '#') && continue
        isdefined(mod, name) || continue
        value = getglobal(mod, name)
        value isa Union{Function, Type, Module} && continue
        push!(lines, string("global ", mod, ".", name, " = ", repr(value)))
    end
    # A root that names a gensym of a tracked module (the generator of a
    # generated method, a closure) names the counters of the trace process:
    # no image has to know that name. Its state is `gensym`, not compared.
    gensym_of = [Regex(string("\\b", mod, "\\.(?:[A-Za-z_]\\w*\\.)*var\"[^\"]*#\\d")) for mod in roots]
    if trace !== nothing
        for line in eachline(trace)
            startswith(line, "precompile(") || continue
            text = line[12:end-1]
            ex = Meta.parse(line)
            sig = try
                Core.eval(Main, ex.args[2])
            catch
                nothing
            end
            state = any(re -> occursin(re, text), gensym_of) ? "gensym" :
                    sig === nothing ? "unresolved" : oracle_root_state(sig, world)
            push!(lines, string("root ", oracle_canonical(text), " ", state))
        end
    end
    sort!(lines)
    for line in lines
        println(line)
    end
    println("info world ", world)
    println("info methods ", length(newest), " of the tracked modules, ", ninstances,
            " code instances valid in the world")
    println("info shadowed ", nshadowed, " replaced methods still in the table")
    nentries, ndead = oracle_dead()
    println("info dead ", nentries, " closed entries, ", ndead, " invalid code instances in the heap")
    return nothing
end

oracle_main(ARGS)
