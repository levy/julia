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
# SEALED_SPLIT_CASES bounds ONE call site's union cross product. Over it, the
# site keeps its abstract types and is answered further down the lattice.
Compiler.SEALED_SPLIT_CASES[] =
    Base.parse(Int, Base.get(Base.ENV, "SEALED_SPLIT_CASES", "4096"))
# SEALED_SPLIT_SHOW=<n> names every site at least that wide, as it is found.
Compiler.SEALED_SPLIT_SHOW[] =
    Base.parse(Int, Base.get(Base.ENV, "SEALED_SPLIT_SHOW", "0"))
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

# Snapshot every sealed-module concrete specialization that exists BEFORE the
# user program runs, so the warm-table delta harvest below can subtract it.
Core.eval(Main, :(const __SEALED_PRESET = Base.IdSet{Any}()))
let preset = Main.__SEALED_PRESET
    sealedroot1(m::Base.Module) = (r = m; while Base.parentmodule(r) !== r; r = Base.parentmodule(r); end;
                                  r !== Core && r !== Base)
    Base.visit(Core.methodtable) do method
        method isa Core.Method || return
        sealedroot1(method.module) || return
        for mi in Base.specializations(method)
            mi isa Core.MethodInstance && Base.push!(preset, mi)
        end
    end
end


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
                    # The run path takes the NATIVE layout; the cell layout is
                    # the editor's reactive shadow, and a field read on it is a
                    # dynamic call no trim can resolve. Sealed substitution must
                    # only offer what the run path can produce.
                    Base.occursin("CellModule.Cell", Base.string(t)) && continue
                    # A document's REACTIVE layout never occurs on the run
                    # path either. Layouts come in sibling families (MNedX /
                    # MCNedX / NedX); when an M-prefixed sibling exists, this
                    # name is the reactive variant — skip it. A kernel
                    # @cell_struct value type has no sibling and stays.
                    Base.isdefined(mod, Base.Symbol(:M, Base.nameof(t))) && continue
                    # A concrete type whose fields are reactive CELLS is UI
                    # machinery (ProjectionReferenceStep and kin): the run
                    # path never holds one, and a branch over it walks the
                    # cell protocol. Safe only NOW: the run-path step types
                    # converted to layout families and left this class.
                    let cellfield = false
                        for ft in Base.fieldtypes(t)
                            ft isa DataType || continue
                            fn = ft.name.name
                            if fn === :ReactiveCell || fn === :MutableCell
                                cellfield = true
                                break
                            end
                        end
                        Base.nameof(t) === :ProjectionReferenceStep &&
                            Core.println("SEALED-EXCL verdict cellfield=", cellfield)
                        cellfield && continue
                    end
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
    # --- sealed world: the warm-instance TABLE ------------------------------
    # Not entrypoints: a lookup table (Method => concrete instances the warm
    # run compiled). Declined dynamic call sites pull from it, so exactly the
    # runtime dispatch targets are compiled.
    let table = Base.IdDict{Any,Any}(), preset = Main.__SEALED_PRESET, n = Base.RefValue(0)
        sealedroot2(m::Base.Module) = (r = m; while Base.parentmodule(r) !== r; r = Base.parentmodule(r); end;
                                      r !== Core && r !== Base && r !== Compiler)
        Base.visit(Core.methodtable) do method
            method isa Core.Method || return
            sealedroot2(method.module) || return
            for mi in Base.specializations(method)
                mi isa Core.MethodInstance || continue
                (mi in preset) && continue
                if !Base.isdispatchtuple(mi.specTypes)
                    # An instance compiled AT the method's own abstract
                    # signature is the stem pattern: one body serves every
                    # layout, and runtime dispatch lands on it. Membership
                    # needs it in the image (node_address(::ANode) was the
                    # measured case), so it is harvested and marked for the
                    # drain filter, which otherwise drops widened instances.
                    (mi.specTypes == method.sig) || continue
                end
                v = Base.get!(Base.Vector{Any}, table, method)
                Base.push!(v, mi)
                n[] += 1
            end
        end
        Compiler.SEALED_WARM_INSTANCES[] = table
        Base.println("SEALED-WARM-TABLE: ", n[], " instances across ", Base.length(table), " methods")
    end
    # --- sealed world: which roots' recorded targets survive the trim entry --
    let rootsenv = Base.get(Base.ENV, "SEALED_TARGET_ROOTS", "")
        if !Base.isempty(rootsenv)
            roots = Base.Set{Symbol}()
            for s in Base.split(rootsenv, ",")
                Base.push!(roots, Base.Symbol(Base.strip(s)))
            end
            Compiler.SEALED_TARGET_ROOTS[] = roots
        end
    end
    let stemenv = Base.get(Base.ENV, "SEALED_STEM_KEEP", "")
        if !Base.isempty(stemenv)
            names = Base.Set{Symbol}()
            for s in Base.split(stemenv, ",")
                Base.push!(names, Base.Symbol(Base.strip(s)))
            end
            Compiler.SEALED_STEM_KEEP[] = names
        end
    end
    let pullenv = Base.get(Base.ENV, "SEALED_NOCALLINFO_PULL", "")
        if !Base.isempty(pullenv)
            names = Base.Set{Symbol}()
            for s in Base.split(pullenv, ",")
                Base.push!(names, Base.Symbol(Base.strip(s)))
            end
            Compiler.SEALED_NOCALLINFO_PULL[] = names
            # Seed the trim drain with every dispatch-tuple instance of the
            # named methods. Their call sites carry NoCallInfo (more matches
            # than max_methods), so no inlining-time pull ever sees them;
            # inlining-side pulls at such sites cascaded (1 -> 27 -> 158
            # errors). The entry warm run compiles one instance per method,
            # so pushing specializations covers the whole match set.
            seeded = Base.RefValue(0)
            Base.visit(Core.methodtable) do method
                method isa Core.Method || return
                (method.name in names) || return
                # a NAMED method is explicit intent, so Base methods are
                # allowed here (the BitVector constructor was the measured
                # case: an invoke target of a drained instance, whose edges
                # nothing walks) — marked so the drain filter accepts them
                for mi in Base.specializations(method)
                    mi isa Core.MethodInstance || continue
                    Base.isdispatchtuple(mi.specTypes) || continue
                    Base.push!(Compiler.SEALED_MEMBERSHIP_KEEP, mi)
                    Base.push!(Compiler.SEALED_EXTRA_TARGETS, mi)
                    seeded[] += 1
                end
            end
            Core.println("SEALED-SEED: ", seeded[], " instances for ", names)
        end
    end
    # ------------------------------------------------------------------------
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
