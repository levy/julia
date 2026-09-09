# The cone of the hub edit (the log entry "2026-09-09, the cone" of the plan):
# what Julia invalidates when handle_message!(::AApp) of the routing sample is
# redefined with one changed line, by cause and depth, and whether the callers'
# inference would change. Run on the image of a routing store:
#   julia --sysimage=<app>/lib/julia/sys.so --project=<omnet>/build/app/routing tool/cone_probe.jl
const C = Base.Compiler
mod = nothing
for (id, m) in Base.loaded_modules
    id.name == "OmnetLegacyRouting" && (global mod = m)
end
mod === nothing && error("OmnetLegacyRouting is not loaded")
NM = getfield(mod, :NetworkModule)
f = NM.handle_message!
AApp = getfield(mod, :AApp)
file = "/home/projectured/workspace/omnet-julia-m1/sample/legacy/routing/App.jl"
old = only(m for m in methods(f) if endswith(String(m.file), "App.jl") && m.line == 49)
println("old method: ", old.sig, " line ", old.line)
# the old code instances of the method
oldcis = Any[]
for mi in Base.specializations(old)
    mi isa Core.MethodInstance || continue
    ci = isdefined(mi, :cache) ? mi.cache : nothing
    while ci isa Core.CodeInstance
        ci.max_world == typemax(UInt) && push!(oldcis, (mi, ci))
        ci = isdefined(ci, :next) ? ci.next : nothing
    end
end
println("old code instances: ", length(oldcis))
for (mi, ci) in oldcis
    println("  ", mi.specTypes, " -> ", ci.rettype, " inlineable=", ci.inferred !== nothing, " purity=", ci.ipo_purity_bits)
end
# the edit: the same function with one line changed, evaluated in the module
lines = readlines(file)
text = join(lines[49:61], "\n")
text2 = replace(text, "m.total_hop_count += packet.hop_count" => "m.total_hop_count += packet.hop_count + 1")
text2 == text && error("the edit did not apply")
world0 = Base.get_world_counter()
log = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
t = @elapsed Core.eval(mod, Meta.parse(text2))
ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
world1 = Base.get_world_counter()
println("redefined in ", round(t; digits = 3), " s, world ", world0, " -> ", world1, ", log entries ", length(log))
# the log: a method instance followed by a depth (Int32) or a reason (String)
bydepth = Dict{Int, Int}(); byreason = Dict{String, Int}(); invalidated = Dict{Core.MethodInstance, Int}()
i = 1
while i <= length(log)
    x = log[i]
    if x isa Core.MethodInstance && i < length(log)
        y = log[i + 1]
        if y isa Int32
            bydepth[Int(y)] = get(bydepth, Int(y), 0) + 1
            invalidated[x] = min(get(invalidated, x, typemax(Int)), Int(y))
            global i += 2; continue
        elseif y isa String
            byreason[y] = get(byreason, y, 0) + 1
            invalidated[x] = min(get(invalidated, x, typemax(Int)), 0)
            global i += 2; continue
        end
    elseif x isa Method && i < length(log) && log[i + 1] isa String
        byreason["method " * log[i + 1]] = get(byreason, "method " * log[i + 1], 0) + 1
        global i += 2; continue
    end
    global i += 1
end
println("invalidated method instances: ", length(invalidated))
println("by depth: ", sort(collect(bydepth)))
println("by reason: ", sort(collect(byreason)))
# the capped code instances, all of them, by a scan of the method table
capped = 0; cappedmis = Set{Core.MethodInstance}()
Base.visit(Core.methodtable) do m
    for mi in Base.specializations(m)
        mi isa Core.MethodInstance || continue
        ci = isdefined(mi, :cache) ? mi.cache : nothing
        while ci isa Core.CodeInstance
            if world0 - 1 <= ci.max_world < world1
                global capped += 1; push!(cappedmis, mi)
            end
            ci = isdefined(ci, :next) ? ci.next : nothing
        end
    end
    true
end
println("capped code instances by scan: ", capped, " in ", length(cappedmis), " method instances")
# the depth-1 callers: through which edge? (a code instance of the old method, or a signature)
old_mis = Set(mi for (mi, _) in oldcis)
direct = 0; mtedge = 0; other = 0; inlineable_callee = 0
for (mi, d) in invalidated
    d == 1 || continue
    ci = isdefined(mi, :cache) ? mi.cache : nothing
    kind = :other
    while ci isa Core.CodeInstance
        if isdefined(ci, :edges)
            for e in ci.edges
                if e isa Core.CodeInstance && e.def in old_mis
                    kind = :direct
                    e.inferred !== nothing && (global inlineable_callee += 1)
                elseif e isa Core.MethodInstance && e in old_mis
                    kind = :direct
                elseif e isa Type && kind == :other
                    kind = :mt
                end
            end
        end
        ci = isdefined(ci, :next) ? ci.next : nothing
    end
    kind == :direct ? (global direct += 1) : kind == :mt ? (global mtedge += 1) : (global other += 1)
end
println("depth-1 callers: ", direct, " through an invoke edge, ", mtedge, " through a signature (dynamic), ", other, " unknown; inlineable callee edges: ", inlineable_callee)
# the return type of the new method for the old specializations
new = only(m for m in methods(f) if m.sig == old.sig && m !== old)
interp = C.NativeInterpreter(world1)
for (mi, ci) in oldcis
    rt = C.typeinf_type(interp, new, mi.specTypes, mi.sparam_vals)
    println("  new rettype for ", mi.specTypes, ": ", rt, rt === ci.rettype ? " (same)" : " (DIFFERENT from $(ci.rettype))")
end
# the sample of the deepest and the depth-1 names
for d in sort(collect(keys(bydepth)))[1:min(end, 3)]
    names = [string(mi.def.name) for (mi, dd) in invalidated if dd == d]
    println("depth ", d, ": ", length(names), " e.g. ", join(unique(names)[1:min(end, 8)], ", "))
end
