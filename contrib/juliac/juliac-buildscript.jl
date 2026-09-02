# This file is a part of Julia. License is MIT: https://julialang.org/license

# Script to run in the process that generates juliac's object file output

# Initialize some things not usually initialized when output is requested
Sys.__init__()
Base.reinit_stdio()
Base.init_depot_path()
Base.init_load_path()
Base.init_active_project()
task = current_task()
task.rngState0 = 0x5156087469e170ab
task.rngState1 = 0x7431eaead385992c
task.rngState2 = 0x503e1d32781c2608
task.rngState3 = 0x3a77f7189200c20b
task.rngState4 = 0x5502376d099035ae
uuid_tuple = (UInt64(0), UInt64(0))
ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), Base.__toplevel__, uuid_tuple)
if Base.get_bool_env("JULIA_USE_FLISP_PARSER", false) === false
    Base.JuliaSyntax.enable_in_core!()
end

include(joinpath(@__DIR__, "abi_export.jl"))

# Load user code

import Base.Experimental.entrypoint

# for use as C main if needed
function _main(argc::Cint, argv::Ptr{Ptr{Cchar}})::Cint
    args = ccall(:jl_set_ARGS, Any, (Cint, Ptr{Ptr{Cchar}}), argc, argv)::Vector{String}
    setglobal!(Base, :PROGRAM_FILE, args[1])
    popfirst!(args)
    append!(Base.ARGS, args)
    return Main.main(args)
end

using Compiler
Compiler.activate!(; reflection = true, codegen = true)
# THE SEALED WORLD IS OFF WHILE THE PROGRAM LOADS. Loading a package infers,
# and inferring under the sealed settings - `max_union_splitting` at 20 000
# rather than Julia's 4 - costs 3.6 of the 12.9 seconds `load-program` takes,
# for work the trim never uses: the compiled set is built later, at exit.
# Measured on routing phase 0: 12.90s baseline, 9.29s with SEALED_WORLD=0,
# 9.67s with the split limit at 4.
const _SEALED_WORLD_WANTED = Base.get(Base.ENV, "SEALED_WORLD", "1") != "0"
Compiler.SEALED_WORLD[] = false
# SEALED_SPLIT_LIMIT=4 holds inference to the STOCK union splitter, which is
# what the `proven` policy level means. Without it, SEALED_SPLIT=0 disables
# only the abstract-to-union map and a 20 000-wide splitter still resolves
# dispatches stock Julia leaves open.
let v = Base.get(Base.ENV, "SEALED_SPLIT_LIMIT", "")
    v == "" || (Compiler.SEALED_SPLIT_LIMIT[] = Base.parse(Base.Int, v))
end
Core.eval(Base.Compiler, quote
    add_entrypoint(types::Type) = $(Compiler).add_entrypoint(types)
end)



let include_result = Base.include(Main, ARGS[1])
    Core.@latestworld
    # The program is loaded; from here on the sealed world applies.
    Compiler.SEALED_WORLD[] = _SEALED_WORLD_WANTED
    # --- sealed world: abstract type => Union of concrete subtypes ------------
    let lists = Base.IdDict{Any,Vector{Any}}()
        rootmod(m::Module) = (while Base.parentmodule(m) !== m; m = Base.parentmodule(m); end; m)
        # A type is SEALED when its root module is neither Core nor Base: the
        # program's own types and its packages' types are closed at this point,
        # while Function, Integer and the other Base abstracta have subtypes no
        # enumeration can see.
        sealedroot(m::Module) = (r = rootmod(m); r !== Base.Core && r !== Base)
        seen = Base.IdSet{Module}()
        function record!(mod::Module)
            (mod in seen) && return
            Base.push!(seen, mod)
            for name in Base.names(mod; all = true)
                Base.isdefined(mod, name) || continue
                Base.isdeprecated(mod, name) && continue
                t = Base.getglobal(mod, name)
                if t isa Module
                    (t !== mod && sealedroot(t)) && record!(t)
                elseif t isa DataType && Base.isconcretetype(t)
                    s = Base.supertype(t)
                    while s !== Any
                        if sealedroot(Base.parentmodule(s))
                            list = Base.get!(Vector{Any}, lists, s)
                            (t in list) || Base.push!(list, t)
                        end
                        s = Base.supertype(s)
                    end
                end
            end
        end
        for mod in Base.loaded_modules_array()
            sealedroot(mod) && record!(mod)
        end
        record!(Main)
        subs = Base.IdDict{Any,Any}()
        for (k, v) in lists
            subs[k] = Union{v...}
        end
        # Leaving this UNSET disables the abstract-as-union split
        # (`abstractinterpretation.jl` gates on it) while the verifier
        # relaxation stays on — the separation a trace-driven build needs.
        if Base.get(Base.ENV, "SEALED_SPLIT", "1") != "0"
            Compiler.SEALED_SUBTYPES[] = subs
        else
            Core.println("SEALED-SPLIT-OFF: abstract-as-union splitting disabled")
        end
    end
    # --------------------------------------------------------------------------
    if ARGS[2] == "--output-exe"
        have_cmain = false
        if isdefined(Main, :main)
            for m in methods(Main.main)
                if isdefined(m, :ccallable)
                    # TODO: possibly check signature and return type
                    have_cmain = true
                    break
                end
            end
        elseif include_result isa Module && isdefined(include_result, :main)
            error("""
                  The `main` function must be defined in `Main`. If you are defining it inside a
                  module, try adding `import .$(nameof(include_result)).main` to $(ARGS[1]).
                  """)
        end
        if !have_cmain
            if Base.should_use_main_entrypoint()
                if hasmethod(Main.main, Tuple{Vector{String}})
                    entrypoint(_main, (Cint, Ptr{Ptr{Cchar}}))
                    Base._ccallable("main", Cint, Tuple{typeof(_main), Cint, Ptr{Ptr{Cchar}}})
                else
                    error("`@main` must accept a `Vector{String}` argument.")
                end
            else
                error("To generate an executable a `@main` function must be defined in the `Main` module.")
            end
        end
    end
end

# Run the verifier in the current world (before build-script modifications),
# so that error messages and types print in their usual way.
Core.Compiler._verify_trim_world_age[] = Base.get_world_counter()
Compiler._verify_trim_world_age[] = Base.get_world_counter()

# Apply hacks

if Base.JLOptions().trim != 0
    include(joinpath(@__DIR__, "juliac-trim-base.jl"))
    include(joinpath(@__DIR__, "juliac-trim-stdlib.jl"))
end

#entrypoint(join, (Base.GenericIOBuffer{Memory{UInt8}}, Array{Base.SubString{String}, 1}, String))
#entrypoint(join, (Base.GenericIOBuffer{Memory{UInt8}}, Array{String, 1}, Char))
entrypoint(Base.task_done_hook, (Task,))
entrypoint(Base.wait, ())
entrypoint(Base.wait_forever, ())
entrypoint(Base.trypoptask, (Base.StickyWorkqueue,))
entrypoint(Base.checktaskempty, ())

if ARGS[3] == "true"
    Base.Compiler.add_ccallable_entrypoints!()
end

# Export info about entrypoints and structs needed to create header files
if length(ARGS) >= 4
    abi_export = ARGS[4]
    open(abi_export, "w") do io
        write_abi_metadata(io)
    end
end

empty!(Core.ARGS)
empty!(Base.ARGS)
empty!(LOAD_PATH)
empty!(DEPOT_PATH)
empty!(Base.TOML_CACHE.d)
Base.TOML.reinit!(Base.TOML_CACHE.p, "")
Base.ACTIVE_PROJECT[] = nothing
@eval Base begin
    PROGRAM_FILE = ""
end
@eval Sys begin
    BINDIR = ""
    STDLIB = ""
end
