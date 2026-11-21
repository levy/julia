# This file is a part of Julia. License is MIT: https://julialang.org/license

# Compile apart from load: one process compiles functions into objects with
# `jl_emit_object`, and a new process installs the objects with
# `jl_install_objects` and calls the functions with no compile.

using Test

const compile_apart_script = """
using Serialization
const C = Base.Compiler
greet(x::Int) = (3x + 1, :apart, "apart")
mode, dir = ARGS
mi = Base.method_instance(Tuple{typeof(greet), Int})
world = Base.get_world_counter()
if mode == "write"
    codeinfos = C.typeinf_ext_toplevel(Any[mi], UInt[world], C.TRIM_NO, false)[1]
    object, slots, functions = ccall(:jl_emit_object, Any, (Any, Any), codeinfos, nothing)
    write(joinpath(dir, "object.o"), object)
    serialize(joinpath(dir, "table.jls"),
              (Any[slots...], [(C.get_ci_mi(f[1]).specTypes, f[2], f[3], f[4]) for f in functions]))
else
    slots, entries = deserialize(joinpath(dir, "table.jls"))
    functions = Any[]
    for (types, api, invoke, specptr) in entries
        ci = C.typeinf_ext(C.NativeInterpreter(world), Base.method_instance(types), C.SOURCE_MODE_NOT_REQUIRED)
        push!(functions, Core.svec(ci, Int32(api), invoke, specptr))
    end
    object = read(joinpath(dir, "object.o"))
    Base.cumulative_compile_timing(true)
    before = Base.cumulative_compile_time_ns()[1]
    n = ccall(:jl_install_objects, Cint, (Any, Any), Any[Core.svec(object, "jl_object", slots)], functions)
    y = Base.invokelatest(greet, 13)
    compiled = Base.cumulative_compile_time_ns()[1] - before
    print(n, " ", repr(y), " ", compiled)
end
"""

# Two parts: `outer` and `inner` each in an object of its own. The call of
# `outer` to `inner` is a call to another part, which the install links.
const compile_apart_parts_script = """
using Serialization
const C = Base.Compiler
@noinline inner(x::Int) = 3x + 1
outer(x::Int) = 2 * inner(x)
mode, dir = ARGS
mi = Base.method_instance(Tuple{typeof(outer), Int})
world = Base.get_world_counter()
if mode == "write"
    codeinfos = C.typeinf_ext_toplevel(Any[mi], UInt[world], C.TRIM_NO, false)[1]
    pairs = [codeinfos[i:i+1] for i in 1:2:length(codeinfos) if codeinfos[i] isa Core.CodeInstance]
    cis = Any[p[1] for p in pairs]
    names = Any["part_\$k" for k in eachindex(pairs)]
    parts = [ccall(:jl_emit_object, Any, (Any, Any), Any[p...], Core.svec("part_\$k", cis, names))
             for (k, p) in enumerate(pairs)]
    serialize(joinpath(dir, "parts.jls"),
              [(Vector{UInt8}(o[1]), "part_\$k", Any[o[2]...],
                [(C.get_ci_mi(f[1]).specTypes, f[2], f[3], f[4]) for f in o[3]], [c[3] for c in o[4]])
               for (k, o) in enumerate(parts)])
else
    stored = deserialize(joinpath(dir, "parts.jls"))
    objects = Any[]
    functions = Any[]
    for (object, prefix, slots, entries, calls) in stored
        push!(objects, Core.svec(object, prefix, slots))
        for (types, api, invoke, specptr) in entries
            ci = C.typeinf_ext(C.NativeInterpreter(world), Base.method_instance(types), C.SOURCE_MODE_NOT_REQUIRED)
            push!(functions, Core.svec(ci, Int32(api), invoke, specptr))
        end
    end
    calls = sum(s -> length(s[5]), stored)
    Base.cumulative_compile_timing(true)
    before = Base.cumulative_compile_time_ns()[1]
    n = ccall(:jl_install_objects, Cint, (Any, Any), objects, functions)
    y = Base.invokelatest(outer, 13)
    compiled = Base.cumulative_compile_time_ns()[1] - before
    print(length(objects), " ", calls, " ", n, " ", y, " ", compiled)
end
"""

@testset "compile apart from load" begin
    mktempdir() do dir
        file = joinpath(dir, "script.jl")
        write(file, compile_apart_script)
        run(`$(Base.julia_cmd()) --startup-file=no $file write $dir`)
        @test isfile(joinpath(dir, "object.o"))
        # One code instance gets the code of the object, the call gives the
        # right answer, and no compile runs.
        @test readchomp(`$(Base.julia_cmd()) --startup-file=no $file install $dir`) == "1 (40, :apart, \"apart\") 0"
    end
end

@testset "compile apart from load, in parts" begin
    mktempdir() do dir
        file = joinpath(dir, "script.jl")
        write(file, compile_apart_parts_script)
        run(`$(Base.julia_cmd()) --startup-file=no $file write $dir`)
        # Two objects and one call between them; both code instances get code,
        # the call gives the right answer, and no compile runs.
        @test readchomp(`$(Base.julia_cmd()) --startup-file=no $file install $dir`) == "2 1 2 80 0"
    end
end
