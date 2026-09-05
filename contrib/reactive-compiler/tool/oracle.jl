# The oracle of Stage 0 (plan/pending/robust-incremental-compiler.md): the
# digest of an image, printed from inside a process that boots from it.
#
#   julia -J <bundle>/lib/julia/sys.so oracle.jl --tracked Mod[,Mod...] [--trace trace.jl]
#
# One line per fact, sorted, so that `diff` compares two images:
#   method <signature> <hash of the lowered code>   a method of a tracked
#                                                   module, valid in the
#                                                   current world
#   root <signature> compiled|inferred|absent|unresolved
#                                                   a statement of the trace
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

# The hash of the lowered code of a method: the statements and the slot
# names, without the line information.
function oracle_lowered(m::Method)
    ci = Base.uncompressed_ast(m)
    return string(hash(repr(ci.code), hash(repr(ci.slotnames))); base = 16)
end

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
        push!(lines, string("method ", m.sig, " ", oracle_lowered(m)))
    end
    for mod in roots, name in names(mod; all = true, imported = false)
        startswith(string(name), '#') && continue
        isdefined(mod, name) || continue
        value = getglobal(mod, name)
        value isa Union{Function, Type, Module} && continue
        push!(lines, string("global ", mod, ".", name, " = ", repr(value)))
    end
    if trace !== nothing
        for line in eachline(trace)
            startswith(line, "precompile(") || continue
            ex = Meta.parse(line)
            sig = try
                Core.eval(Main, ex.args[2])
            catch
                nothing
            end
            state = sig === nothing ? "unresolved" : oracle_root_state(sig, world)
            push!(lines, string("root ", line[12:end-1], " ", state))
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
    return nothing
end

oracle_main(ARGS)
