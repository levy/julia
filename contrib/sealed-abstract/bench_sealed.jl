# The sealed compiler's cost, measured IN A SESSION, in seconds.
#
#     julia +1.13 --project=env2 bench_sealed.jl K,S,W [K,S,W ...]
#
# Several cases run in ONE session: activating the sealed compiler costs 17
# seconds, and that is paid once for the whole sweep, not once per point. Each
# case gets its own module, so the generated names can not collide.
#
# WHY THIS EXISTS. Every earlier measurement went through juliac, which costs
# an 18 second floor of package load, codegen, image write and link before the
# compiler does anything the measurement is about. A routing build costs 22
# minutes. Neither is a loop.
#
# WHAT IT MEASURES. Exactly the phase that dominated a routing build:
#
#     precompile(main, (Vector{String},))       # base/client.jl:581
#
# Julia's `_start` runs that whenever it generates output, so a trim build
# compiles the entry through the ordinary JIT before the trim path sees it. On
# routing that cost 960 s against 198 s for the trim's own inference. Here the
# same call is made directly, with no image and no linker.
#
# THE KNOBS. The routing build records 883 062 671 dispatch targets for 39 538
# distinct ones — a multiplicity of ~22 300. A juliac run of this program's
# shape reached ~22. Multiplicity is the axis that separates them:
#
#     K   concrete subtypes, hence methods matched at a declined split
#     S   distinct call sites, hence declined split sites
#     W   warm instances per method, hence targets recorded per match
#
# Records grow as about S x K x W, so the three multiply. `main` is NEVER run
# here — only `warm()` is, exactly as in a real build, where the warm run
# populates the instance table and `main` is compiled cold.

# The sealed compiler replaces Julia's, exactly as the buildscript loads it.
using Compiler
using Profile
Compiler.activate!(; reflection = true, codegen = true)

const CASES = isempty(ARGS) ? [(40, 300, 1)] :
    [let p = split(a, ","); (parse(Int, p[1]), parse(Int, p[2]), parse(Int, p[3])) end for a in ARGS]

function program_source(k::Int, s::Int, w::Int)
    types = join(("struct T$i <: Node; v::Int; end" for i in 1:k), "\n")
    # One `step` method per concrete type, each with `w` distinct concrete
    # specializations, so a matched method contributes `w` recorded targets.
    steps = join(("Base.@noinline step(x::T$i, ::Val{J}) where {J} = x.v + $i + J" for i in 1:k), "\n")
    sites = join(("Base.@noinline site$j(x::Node, v) = step(x, v) + $j" for j in 1:s), "\n")
    calls = join(("    total += site$j(nodes[($j - 1) % $k + 1], Val($((j - 1) % w + 1)))" for j in 1:s), "\n")
    ctors = join(("    nodes[$i] = T$i($i)" for i in 1:k), "\n")
    # The warm run touches every (type, Val) pair through a CONCRETE path, so
    # the specializations exist before `main` is compiled. It must not call
    # `main`: a real build warms the model, never the entry.
    warms = join(("    warm_total += step(nodes[$i], Val($v))" for i in 1:k for v in 1:w), "\n")
    """
    abstract type Node end
    $types

    $steps

    $sites

    function build_nodes()
        nodes = Vector{Node}(undef, $k)
    $ctors
        nodes
    end

    function warm()
        nodes = build_nodes()
        warm_total = 0
    $warms
        warm_total
    end

    function main(argv::Vector{String})::Cint
        nodes = build_nodes()
        total = 0
    $calls
        Cint(total % 128)
    end
    """
end


function run_case(idx::Int, k::Int, s::Int, w::Int)
    name = Symbol("Bench", idx)
    Core.eval(Main, Meta.parse("module $name\n" * program_source(k, s, w) *
                               "\nconst __SEALED_PRESET = Base.IdSet{Any}()\nend"))
    M = getfield(Main, name)
    # The module is created at run time, so its methods are newer than this
    # world; `invokelatest` is required to reach them.
    t_warm = @elapsed Base.invokelatest(getfield(M, :warm))

    # The sealed setup, as juliac-buildscript.jl does it.
    Compiler.SEALED_WORLD[] = true
    Compiler.SEALED_SUBTYPES[] = Base.IdDict{Any,Any}(
        M.Node => Union{(getfield(M, Symbol("T$i")) for i in 1:k)...})
    table = Base.IdDict{Any,Any}(); n = 0
    sealedroot(m::Module) = (r = m; while parentmodule(r) !== r; r = parentmodule(r); end;
                             r !== Core && r !== Base && r !== Compiler)
    Base.visit(Core.methodtable) do method
        method isa Core.Method || return
        sealedroot(method.module) || return
        for mi in Base.specializations(method)
            mi isa Core.MethodInstance || continue
            if !Base.isdispatchtuple(mi.specTypes)
                (mi.specTypes == method.sig) || continue
            end
            push!(get!(Vector{Any}, table, method), mi); n += 1
        end
    end
    Compiler.SEALED_WARM_INSTANCES[] = table

    before_n = Compiler.SEALED_TARGET_DUPES[]
    before_d = length(Compiler.SEALED_EXTRA_TARGETS)
    mainfn = getfield(M, :main)      # same world-age rule as `warm` above
    # BENCH_PROFILE=1 samples the phase with Julia's own profiler, which names
    # Julia frames — `perf` sees only hex addresses for JIT-compiled inference.
    local t
    # BENCH_INFER_ONLY=1 runs INFERENCE on the entry without codegen. The JIT
    # pass exists (for the sealed toolchain) to populate dispatch-target
    # records; its machine code is discarded, because the trim path emits the
    # binary from its own inference. If the records survive inference alone,
    # the LLVM cost of this phase is avoidable.
    if get(ENV, "BENCH_INFER_ONLY", "") != ""
        mi = Base.method_instance(mainfn, (Vector{String},))
        world = Base.get_world_counter()
        t = @elapsed ccall(:jl_type_infer, Any, (Any, UInt, Cint), mi, world, 0)
    elseif get(ENV, "BENCH_PROFILE", "") != ""
        Profile.clear()
        t = @elapsed Profile.@profile precompile(mainfn, (Vector{String},))
        println("--- profile, case K=$k S=$s W=$w ---")
        Profile.print(; format = :flat, sortedby = :count, mincount = 20, maxdepth = 1)
    else
        t = @elapsed precompile(mainfn, (Vector{String},))
    end
    records = Compiler.SEALED_TARGET_DUPES[] - before_n + (length(Compiler.SEALED_EXTRA_TARGETS) - before_d)
    distinct = length(Compiler.SEALED_EXTRA_TARGETS) - before_d
    mult = distinct == 0 ? 0.0 : records / distinct
    row(a...) = println(join((lpad(x, 10) for x in a)))
    row(k, s, w, round(t, digits = 2), round(t_warm, digits = 3), distinct, records, round(mult))
    return t
end

println(join((lpad(x, 10) for x in ("K", "S", "W", "precomp_s", "warm_s", "distinct", "records", "mult"))))
for (i, (k, s, w)) in enumerate(CASES)
    run_case(i, k, s, w)
end
