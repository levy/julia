# Stage 4, the enforcement barrier and the trap test.
#
# The stage-2 checker held region identity in a side table. This one asks the
# RUNTIME: `jl_gc_region_of` reads the region tag from the page header of the
# object, in constant time, with no registration at all. The compiler pass
# inserts one check per reference store; a store whose child lives in a
# younger region than its parent TRAPS.
#
# Run with the patched build and the hooked compiler:
#
#   JULIA_LOAD_PATH=<hookenv>:@stdlib ../../julia --compiled-modules=no stage4_trap.jl

module RegionTrap

export region_set, region_of, enable!, disable!

region_set(n::Int) = Int(ccall(:jl_gc_region_set, Cint, (Cint,), n))
region_of(x)       = Int(ccall(:jl_gc_region_of, Cint, (Any,), x))

const ENABLED = Ref(false)
const CHECKS_RUN = Ref(0)

struct RegionViolation <: Exception
    site::String
    parent::Type
    child::Type
    parent_region::Int
    child_region::Int
end

function Base.showerror(io::IO, e::RegionViolation)
    print(io, "region violation at ", e.site, ": region ", e.parent_region,
          " ", e.parent, " <- region ", e.child_region, " ", e.child)
end

@noinline function trap(site::Int, parent, child, pr::Int, cr::Int)
    ENABLED[] = false
    throw(RegionViolation(SITES[site], typeof(parent), typeof(child), pr, cr))
end

@noinline function check!(site::Int, parent, child)
    ENABLED[] || return nothing
    (child === nothing || isbits(child)) && return nothing
    CHECKS_RUN[] += 1
    parent isa MemoryRef && (parent = parent.mem)
    child isa MemoryRef && (child = child.mem)
    pr = region_of(parent)
    cr = region_of(child)
    cr > pr && trap(site, parent, child, pr, cr)
    return nothing
end

# A `:new` checks every reference the fresh object embeds: for an immutable,
# construction IS the store. The fresh object already sits on a tagged page,
# so `region_of` answers for it with no registration.
@noinline function newobj!(site::Int, x, children...)
    ENABLED[] || return nothing
    for child in children
        check!(site, x, child)
    end
    return nothing
end

const SITES = String[]

# Non-const on purpose: an `Any`-typed binding read keeps the inserted call
# opaque to inference (the stage-2 lesson, see region_check.jl).
global check_dyn = check!
global newobj_dyn = newobj!

enable!() = (ENABLED[] = true; nothing)
disable!() = (ENABLED[] = false; nothing)

end # module RegionTrap

# --- the instrumentation pass ------------------------------------------------
# The stage-2 pass minus registration: stores and construction get a check,
# allocations get nothing, because the runtime page tag is the identity.

using Compiler: Compiler

const NEW_REF = GlobalRef(RegionTrap, :newobj_dyn)
const CHK_REF = GlobalRef(RegionTrap, :check_dyn)
const IN_PASS = Ref(false)
const STATS = Ref((methods = 0, checks = 0))

function _excluded(mod::Module)
    root = mod
    while parentmodule(root) !== root
        root = parentmodule(root)
    end
    return root === Compiler || mod === RegionTrap || root === Core
end

function _resolve(f)
    f isa GlobalRef || return f
    isdefined(f.mod, f.name) || return nothing
    return getglobal(f.mod, f.name)
end
_is(f, value) = _resolve(f) === value

function instrument(ir, opt)
    IN_PASS[] && return ir
    def = opt.linfo.def
    mod = def isa Method ? def.module : def
    def isa Method && def.name in (:invokelatest, :invokelatest_trimmed, :_call_latest) && return ir
    _excluded(mod::Module) && return ir
    IN_PASS[] = true
    checks = 0
    label = def isa Method ? string(def.module, ".", def.name, ":", def.line) : string(mod)
    site() = (push!(RegionTrap.SITES, label); length(RegionTrap.SITES))
    try
        for i in 1:length(ir.stmts)
            stmt = ir.stmts[i][:stmt]
            stmt isa Expr || continue
            if stmt.head === :new || stmt.head === :splatnew
                Compiler.insert_node!(ir, Compiler.SSAValue(i),
                    Compiler.NewInstruction(
                        Expr(:call, NEW_REF, site(), Compiler.SSAValue(i), stmt.args[2:end]...),
                        Nothing), #= attach after =# true)
                checks += 1
            elseif stmt.head === :call && length(stmt.args) >= 3
                f = stmt.args[1]
                if _is(f, Core.setfield!) && length(stmt.args) >= 4
                    Compiler.insert_node!(ir, Compiler.SSAValue(i),
                        Compiler.NewInstruction(
                            Expr(:call, CHK_REF, site(), stmt.args[2], stmt.args[4]), Nothing))
                    checks += 1
                elseif _is(f, Core.memoryrefset!)
                    Compiler.insert_node!(ir, Compiler.SSAValue(i),
                        Compiler.NewInstruction(
                            Expr(:call, CHK_REF, site(), stmt.args[2], stmt.args[3]), Nothing))
                    checks += 1
                end
            end
        end
        old = STATS[]
        STATS[] = (methods = old.methods + 1, checks = old.checks + checks)
        return Compiler.compact!(ir)
    finally
        IN_PASS[] = false
    end
end

function install!()
    push!(RegionTrap.SITES, "warmup")
    RegionTrap.check!(1, Ref{Any}(0), Ref{Any}(0))
    RegionTrap.newobj!(1, Ref{Any}(0), Ref{Any}(0))
    Compiler.IR_HOOK[] = instrument
    return nothing
end

# The definitions above must exist BEFORE activation: the activated compiler
# executes in the world captured here (the stage-2 lesson). Everything
# defined after this line compiles through the hooked compiler.
Compiler.activate!(; reflection = true, codegen = true)

# --- the trap test -----------------------------------------------------------

mutable struct Holder
    x::Any
end

@noinline function store!(h::Holder, v)
    h.x = v
    return nothing
end

# Install at TOP LEVEL: `main` and `store!` compile at the first call of
# `main`, and the hook must already stand when that compilation runs.
install!()

function main()
    # The v1 contract: once region pages exist, the collector must not run.
    # The hooked compiler allocates heavily in this process, so turn the
    # collector off BEFORE the first region use and leave it off.
    GC.enable(false)
    h = Holder(nothing)                      # allocated in region 0

    RegionTrap.region_set(1)
    young = fill(1.0, 2)                     # allocated in region 1
    RegionTrap.region_set(0)

    println("region_of(h)     = ", RegionTrap.region_of(h))
    println("region_of(young) = ", RegionTrap.region_of(young))

    # Legal direction: an old child into a young parent.
    RegionTrap.region_set(1)
    box = Holder(nothing)                    # region 1 parent
    RegionTrap.region_set(0)
    RegionTrap.enable!()
    store!(box, h)                           # region 1 <- region 0: legal
    RegionTrap.disable!()
    println("legal store passed, checks run = ", RegionTrap.CHECKS_RUN[])

    # Illegal direction: the young child into the old parent MUST trap.
    # The trap ends the process with the RegionViolation error — that is what
    # a trap does. (A try/catch around the store does not catch here: the
    # inserted check nodes and the catch edge of the instrumented method do
    # not compose; cause unexamined, the checker is a prototype.)
    println("instrumented methods = ", STATS[].methods,
            ", inserted checks = ", STATS[].checks)
    println("the next store must trap: region 0 Holder <- region 1 Vector")
    RegionTrap.enable!()
    store!(h, young)
    RegionTrap.disable!()
    println("FAIL: the illegal store did not trap")
    return false
end

exit(main() ? 0 : 2)
