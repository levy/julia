# The program's hints to the compiler.
#
# A program is behaviour, and it is the program writer's right to help the
# compiler do its job. A hint is a plain function call, so the SAME text works
# in the program's own source and in a seal file the compiler evaluates after
# the program loads. Nothing here changes what the program computes: run any of
# these under a stock `julia` and every hint is the identity.
#
# This file is loaded THREE ways, and all three must agree:
#
#   1. `juliac-buildscript.jl` includes it before the program, so a direct
#      compile sees the hints as no-ops
#   2. `entry_from_edges.jl` includes it and sets `RECORDING[]`, so the
#      recorder learns what the hints marked
#   3. `julia -L seal_hints.jl program.jl` runs the program with no compiler
#      at all, which is how the ladder gets an example's expected output
module SealHints

export seal_buildtime, @seal_buildtime, seal_collapse, @seal_collapse,
       seal_residual, seal_instances, seal_compile, seal_argument

# The instances that were FIRST created inside a `seal_buildtime` block.
const BUILDTIME = Base.IdSet{Any}()
# The recorder turns this on. Off, `seal_buildtime` is `f()` and nothing else.
const RECORDING = Base.RefValue(false)

function snapshot()
    s = Base.IdSet{Any}()
    Base.visit(Core.methodtable) do method
        method isa Core.Method || return
        for mi in Base.specializations(method)
            mi isa Core.MethodInstance && Base.push!(s, mi)
        end
    end
    return s
end

"""
    seal_buildtime(f)

Run `f`, and tell the compiler that everything it compiled to do so is BUILD
TIME work, which the binary can never call.

The recorder's window is `include(PROGRAM)`, which runs the program's whole
top level. It can not tell a constant being computed from a function being
warmed, because both create instances inside that one window, and both have
ordinary types. Routing's `const NED_INDEX = read_routing_type_index()` put
8276 roots into a phase-1 binary that does nothing but read the finished
index, and with them the reactive cell machinery of the `@document` macro.

Write it around the work, not around the constant:

    const NED_INDEX = @seal_buildtime read_routing_type_index()

THE ARGUMENT IS AN EXPRESSION, NOT A BLOCK, AND IT HAS TO BE. A `do` block was
tried first and marked nothing. Julia infers a whole top-level statement -
the closure's body with it - BEFORE the call runs, so every instance the block
would create already exists when the block is entered. Measured on
`buildtime_sealed`: before=73481, after=73481, marked=0. `Core.eval` is what
moves the compilation inside the window.

WHAT IT PROMISES. Nothing the binary reaches at run time may be FIRST compiled
inside the block. Warming a run-time function inside one hides it from the
compiler, and the build then fails on the call that needed it. The promise is
about the work, not the value: the value the block returns is baked as data
and stays.
"""
function seal_buildtime(ex::Expr, mod::Module = Main)
    RECORDING[] || return Core.eval(mod, ex)
    local before = snapshot()
    local result = Core.eval(mod, ex)
    for mi in snapshot()
        mi in before || Base.push!(BUILDTIME, mi)
    end
    return result
end

"""
    @seal_buildtime <expression>

The thin macro over `seal_buildtime`. It quotes the expression and passes the
calling module, so the two spellings do the same thing:

    const NED_INDEX = @seal_buildtime read_routing_type_index()
    const NED_INDEX = seal_buildtime(:(read_routing_type_index()))
"""
macro seal_buildtime(ex)
    return :(seal_buildtime($(QuoteNode(ex)), $(__module__)))
end


"""
    seal_collapse(f)
    seal_collapse(f, 2, 3)

Compile `f` ONCE for the named argument positions instead of once per
combination of argument types.

In a sealed world an abstract argument is the union of its concrete subtypes,
and the splitter enumerates the cases so each resolves concretely. With one
such argument that is what makes a dispatch static. With several it is a CROSS
PRODUCT: six subtypes at three positions is 216 specializations of one method,
and routing's network union has sixteen members. Measured on routing phase 3:
the build passed fifteen minutes without reaching the compile loop and was
killed; at Julia's own split limit of 4 it finished in 125 seconds.

    seal_collapse(combine)            # every argument
    seal_collapse(combine, 2, 3)      # the second and third only

WHAT IT ACTUALLY DOES, AND WHY IT MUST. It sets `Method.nospecialize`. That is
not an implementation detail, it is the whole construct: compiling a method at
a wide signature and registering that instance was tried and produced a binary
that DIES AT RUN TIME, because Julia dispatches on the concrete argument types
and never finds the widened body. The method has to decline to specialize, and
this bitmask is how a method says so.

WHAT IT WIDENS TO. The method's own declared parameter type — `Signal` for
`combine(a::Signal, ...)`, not `Any`. That is what `nospecialize` means, and it
is usually what is wanted: the narrowest type that covers the domain is
already written in the signature.

WHAT IT DOES NOT DO. It does not narrow the body. A widened body's own calls
lose the type information the caller had, and if they dispatch on it they
become dynamic in turn — one example went from two errors to fourteen that
way. A call inside the body with ONE union-typed argument still splits
cheaply; a call that needs the exact type does not, and the body must narrow
it explicitly.
"""
function seal_collapse(@nospecialize(f), positions::Int...)
    local n = 0
    for m in Base.methods(f)
        local bits = m.nospecialize
        if Base.isempty(positions)
            # `nargs` counts the function itself, so the arguments are 1:nargs-1
            bits |= (1 << (m.nargs - 1)) - 1
        else
            for p in positions
                bits |= 1 << (p - 1)
            end
        end
        m.nospecialize = bits
        n += 1
    end
    return n
end

"""
    @seal_collapse function f(...) ... end
    @seal_collapse 2 3 function f(...) ... end

The thin macro over `seal_collapse`, for a definition site. It expands to the
definition followed by the call, so the two spellings do the same thing and the
call form remains the one a seal file uses.
"""
macro seal_collapse(args...)
    local defn = args[end]
    local positions = args[1:end-1]
    local name = defn isa Expr && defn.head === :function ?
                 (defn.args[1] isa Expr ? defn.args[1].args[1] : defn.args[1]) :
                 defn isa Expr && defn.head === :(=) ? defn.args[1].args[1] : defn
    return esc(quote
        $defn
        $(SealHints).seal_collapse($name, $(positions...))
    end)
end

"""
    seal_residual(within, f; from = :none)      # `within` is a function or a Method
    seal_residual(within, f; from = [TypeA, TypeB])
    seal_residual(within, f; from = :trace)

Promise that calls to `f` MADE FROM WITHIN `within` only ever pass the covered
types, so the compiler need not close the rest of `f`'s domain there.

THE PROMISE IS ABOUT A SITE, AND THE SCOPE IS WHAT MAKES IT SOUND. A global
promise about `Base.show` broke the build session's own error printing before
the program was compiled at all - a function that universal is called by
everything, and a claim about all of its call sites is false.

A call is reachable in the GRAPH long before it is reachable in a RUN.
Diagnostic formatting, error paths a configuration can not take and debug
rendering are all cold, and closing them costs their full transitive closure -
which, for anything that prints an arbitrary object, is the whole type universe
reachable from it. Measured on routing: the document printer faces 6306
distinct types at its own depth limit, against a whole image of 1694 instances.

    required   every type the site could dispatch to
    covered    what the promise names
    residual   the rest, which the compiler is told does not occur

THE SOURCE IS ALWAYS EXPLICIT AND `:none` IS THE DEFAULT. `from = :trace` makes
the compiled set depend on which run produced the recording, and a build that
depends on a trace without saying so is one nobody can reproduce from the
source alone.

IT IS A PROMISE AND IT IS FALSIFIABLE. A checked build keeps the residual live
and the suite says whether anything outside the covered set ever arrives.
"""
function seal_residual(@nospecialize(within), @nospecialize(f); from = :none, at = :all)
    Base.isdefined(Main, :Compiler) || return nothing
    local C = Base.getglobal(Main, :Compiler)
    local covered
    if from === :none
        covered = Base.Union{}
    elseif from === :trace
        # The argument types the recorded trace observed for `f`.
        local ts = Any[]
        for sig in C.SEALED_TRACE_SIGS
            local ps = (sig::DataType).parameters
            Base.length(ps) >= 2 || continue
            ps[1] === Base.typeof(f) || continue
            for i in 2:Base.length(ps); Base.push!(ts, ps[i]); end
        end
        covered = Base.isempty(ts) ? Base.Union{} : Base.Union{ts...}
    else
        covered = Base.Union{from...}
    end
    # `within` may be a FUNCTION, which promises for all of its methods, or one
    # METHOD, which promises for that method alone. The second matters: the
    # site to close is often one overload of something universal, and
    # promising about every `Base.show` broke the build session's own error
    # printing.
    # WHICH ARGUMENT THE PROMISE IS ABOUT. `at = :all` narrows every argument
    # to the covered set, which is right when one union flows into every
    # position and WRONG the moment the positions differ.
    #
    # Measured: `_read_primary` calls `evaluate(volatile, rng)`, and all four
    # `evaluate` methods want `MersenneTwister` in position 2. A whole-call
    # promise of `[MersenneTwister]` replaces the VOLATILE with it too, because
    # a `Volatile` is not within the covered set - a wrong build, not a smaller
    # one. `at = 2` says the promise is about the second argument alone.
    local positions = at === :all ? :all :
                      at isa Base.Integer ? (Int(at),) :
                      Tuple(Int(p) for p in at)
    local ms = within isa Base.Method ? (within,) : Base.methods(within)
    local n = 0
    for m in ms
        C.SEALED_RESIDUAL[(m, Base.typeof(f))] = (covered, positions)
        n += 1
    end
    return n
end

"""
    seal_instances(wrapper, types)

State which instantiations of a PARAMETRIC type the image contains.

`switchtupleunion` splits a `Union` and can not split a `UnionAll`, so a call
site whose argument is `Volatile{T} where T` yields no instance at all: the
repair pass adds nothing, the round still counts the call as unresolved, and
the error names only the caller. Routing phase 3's last six errors were three
sites of exactly this shape.

The program is what knows the instantiations, so it states them:

    seal_instances(Volatile, [Volatile{WholeDraw{Normal}}, ...])

WHAT IT PROMISES. No other instantiation of `wrapper` reaches a call the binary
makes. An instantiation left out is a dispatch the binary can not perform.
"""
function seal_instances(@nospecialize(wrapper), types)
    Base.isdefined(Main, :Compiler) || return nothing
    local C = Base.getglobal(Main, :Compiler)
    C.SEALED_INSTANCES[wrapper] = Base.Union{types...}
    return Base.length(types)
end

"""
    seal_compile(signature)

State that a signature is a RUN-TIME DISPATCH TARGET and must be in the binary.

The engine dispatches an event to its action through a field, so the target is
chosen at run time and no caller names it statically. Its method is declared
untyped, so the signature dispatch looks for is the all-`Any` one — and nothing
puts that in the compiled set: the trace records dispatch TUPLES only, and the
drain's filter answers nothing when no target roots are configured.

Measured: routing's `execute_events!` reported sixteen unresolved calls, four
arities across four instances, and every one of them wanted
`deliver_message!(Any, Any, Any)`.

WHAT IT PROMISES. Nothing, and that is the point: it does not narrow or widen
anything, it asks for one more instance. It is wrong only by being unnecessary.
"""
function seal_compile(@nospecialize(signature))
    Base.isdefined(Main, :Compiler) || return nothing
    local C = Base.getglobal(Main, :Compiler)
    # `add_entrypoint` RETURNS FALSE when the signature has no compilable
    # specialization, and says nothing. Reporting the call rather than the
    # answer is how a seal reads as applied while doing nothing at all -
    # measured here, on `deliver_message!(Any, Any, Any)`.
    local ok = try
        C.add_entrypoint(signature)
    catch err
        Core.println("SEAL compile THREW ", signature, ": ", err)
        false
    end
    ok && return 1
    # AN ALL-`Any` SIGNATURE IS NOT A COMPILE HINT. `add_entrypoint` asks
    # `jl_get_compile_hint_specialization`, which answers `nothing` for
    # `deliver_message!(Any, Any, Any)` - measured - even though that IS the
    # method's own signature. Specialize the method directly and put the
    # instance on the entrypoint list, which is the same list `add_entrypoint`
    # would have appended to.
    local m = nothing
    for mm in Base._methods_by_ftype(signature, -1, Base.get_world_counter())
        mm.spec_types === signature || continue
        m = mm
        break
    end
    if m === nothing
        Core.println("SEAL compile REFUSED (no method has this exact signature) ", signature)
        return 0
    end
    local mi = try
        C.specialize_method(m.method, signature, m.sparams)
    catch err
        Core.println("SEAL compile THREW specializing ", signature, ": ", err)
        nothing
    end
    mi === nothing && return 0
    Base.push!(C._entrypoint_mis, mi)
    return 1
end

"""
    seal_argument(f, position, types)
    seal_argument(f, position, types; within = caller, at = pc)

State what a parameter of `f` IS, wherever `f` is called.

`seal_residual` is keyed by the CALLER and narrows a callee's arguments at that
one caller. This is the other half, and it is what a program knows about its own
functions: `deliver_message!(ctx, message, gate)` takes a gate in position 3,
whatever calls it.

WHY A DERIVED TYPE IS NOT THE TRUE ONE. The method is declared untyped, so the
compiler derives its parameters from the event's argument fields —
`Union{Nothing, EventArgument}` — and `GateOwner <: EventArgument` drags every
module type into a position that holds a gate. The engine's action site is then
4 actions x 25 x 25 = 2500 against a split limit of 64: the split is declined,
and nothing reaches the method at all.

    seal_argument(deliver_message!, 3, Gate)

`position` counts the arguments, so 1 is the first after the function.

WHAT IT PROMISES. No call passes anything else there. It is a claim about the
program's own behaviour that the types do not carry, and nothing checks it: a
value outside the promise is a dispatch the binary can not perform.

SCOPED FORMS. `within` names a caller method and `at` its statement index, so
the same parameter can be promised narrowly at one site and left alone
elsewhere.
"""
function seal_argument(@nospecialize(f), position::Base.Integer, @nospecialize(types);
                       within = nothing, at = nothing)
    Base.isdefined(Main, :Compiler) || return nothing
    local C = Base.getglobal(Main, :Compiler)
    local ft = f isa Base.Type ? f : Base.typeof(f)
    # `:trace` READS THE SET RATHER THAN STATING IT. A covering set written by
    # hand is a claim, and a wrong one is not caught: promising `evaluate` the
    # 42 volatiles `NedValue` names generated code for a type that never
    # arrives, and the build died in its own warm run at `draw_byte_count`.
    # Those are the volatiles a PARSED EXPRESSION carries; `evaluate` is called
    # on volatiles built elsewhere too.
    #
    # The recorded edges hold what actually reached the position, at every site
    # that called it. That is the set, and nobody has to guess it.
    #
    # THE EDGES LOAD DURING THE PROGRAM'S INCLUDE, so this answers nothing on
    # the seal file's first pass and everything on its second.
    local t
    if types === :trace
        t = Base.Union{}
        local n = 0
        for (_k, ts) in C.SEALED_EDGE_BY_SITE, tt in ts
            tt isa Base.DataType || continue
            local ps = tt.parameters
            Base.length(ps) >= position + 1 || continue
            ps[1] === ft || continue
            t = Base.Union{t, ps[position + 1]}
            n += 1
        end
        if n == 0
            Core.println("SEAL argument :trace observed nothing for ", ft,
                         " at position ", position)
            return nothing
        end
        Core.println("SEAL argument :trace ", ft, " position ", position,
                     ": ", n, " observations")
    else
        t = types isa Base.Type ? types : Base.Union{types...}
    end
    if within === nothing
        C.SEALED_ARGUMENT[(ft, Base.Int(position))] = t
    else
        local ms = within isa Base.Method ? (within,) : Base.methods(within)
        for m in ms
            C.SEALED_ARGUMENT[(ft, Base.Int(position), m.sig,
                               at === nothing ? 0 : Base.Int(at))] = t
        end
    end
    return t
end

end

using .SealHints
