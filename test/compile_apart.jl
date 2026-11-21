# This file is a part of Julia. License is MIT: https://julialang.org/license

# Compile apart from load: one process compiles a function into an object with
# `jl_emit_object`, and a new process installs the object with
# `jl_install_object` and calls the function with no compile.

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
    object, slots, functions = ccall(:jl_emit_object, Any, (Any,), codeinfos)
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
    n = ccall(:jl_install_object, Cint, (Any, Any, Any), object, slots, functions)
    y = Base.invokelatest(greet, 13)
    compiled = Base.cumulative_compile_time_ns()[1] - before
    print(n, " ", repr(y), " ", compiled)
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
