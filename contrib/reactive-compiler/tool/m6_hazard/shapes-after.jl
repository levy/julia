# The call shapes across the reuse boundary, after the edit. The gate copies
# this file over `HazardApp/src/shapes.jl`.
#
# The founding build compiles every definition here. The edit changes
# `driver`, `edited_leaf`, `delta_callee`, `bench_delta` and `hazard_entry`;
# `shapes-after.jl` holds the edited text. After the rebuild, `driver` is
# delta code that calls reused code of every shape, `cone_caller` is reused
# code that the edit of `edited_leaf` invalidates, and `apply_dynamic` is
# reused code that calls delta code through a generic call.

# specsig; a delta caller reaches it through the trampoline
@noinline reused_noinline(x::Int) = x * 3

# small enough to inline: the callee body lands in the delta with its caller
reused_inline(x::Int) = x + 1

# jl_fptr_args: a @nospecialize method has no specsig
@noinline reused_nospec(@nospecialize(x)) = x isa Int ? x + 10 : -1

# jl_fptr_const_return
reused_const() = 42

# the target of a @cfunction pointer that the delta takes
reused_cfunc_target(x::Cint)::Cint = x * 2

# keyword arguments: the caller reaches the kwcall method and its body
reused_kwargs(x::Int; scale::Int = 2) = x * scale

# varargs
reused_varargs(xs::Int...) = sum(xs; init = 0)

# invoke of an abstract signature
abstract type Shape end
struct Circle <: Shape
    r::Float64
end
area(::Shape) = 0.0
area(c::Circle) = 3.0 * c.r * c.r
reused_invoke(c::Circle) = invoke(area, Tuple{Shape}, c)

# an opaque closure: jl_f_opaque_closure_call reaches its reused body. Reused
# code makes the closure in a function: stock Julia faults on a closure that
# a precompiled package holds in a `const`.
make_oc() = Base.Experimental.@opaque (x::Int) -> x + 100

# a method with a static parameter and no specialization: jl_fptr_sparam
@noinline reused_sparam(@nospecialize(x::T)) where {T} = sizeof(T)

# a finalizer that the delta registers and `finalize` runs
mutable struct Tracked
    id::Int
end
const FINALIZED = Ref(0)
reused_finalizer(t::Tracked) = (FINALIZED[] += t.id; nothing)
function make_tracked(id::Int)
    t = Tracked(id)
    finalizer(reused_finalizer, t)
    return t
end

# the reverse direction: reused code calls delta code through a generic call
@noinline apply_dynamic(f, x) = Base.inferencebarrier(f)(x)
delta_callee(x::Int) = x + 2000

# the cone: reused code that the edit of its callee invalidates
edited_leaf() = 2
cone_caller() = edited_leaf() * 2

# the bench: the same loop in reused code and in delta code; the difference
# is the cost of the trampoline per call
@noinline bench_callee(x::Int) = x + 1
function bench_reused(n::Int)
    s = 0
    for i in 1:n
        s += bench_callee(i)
    end
    return s
end
function bench_delta(n::Int)
    s = 0
    for i in 1:n
        s = s + bench_callee(i)
    end
    return s
end
function bench(f, n::Int)
    f(n)
    t0 = time_ns()
    s = f(n)
    t1 = time_ns()
    return (s, (t1 - t0) / n)
end

# the redefined @ccallable: the alias lives in the founding image; the
# rebuilt image must serve the new body through it
Base.@ccallable hazard_entry()::Cint = Cint(2)

function ccall_entry()
    handle = Libdl.dlopen(unsafe_string(Base.JLOptions().image_file))
    ptr = Libdl.dlsym(handle, :hazard_entry; throw_error = false)
    # the workload runs in a process whose image has no `hazard_entry`
    ptr === nothing && return -1
    return Int(ccall(ptr, Cint, ()))
end

function driver()
    # the increment, not the total: the rebuild workload runs in the process
    # whose heap becomes the image, so `FINALIZED` carries what every rebuild
    # so far added. `state` prints that.
    state = FINALIZED[]
    tracked = make_tracked(2)
    finalize(tracked)
    fptr = @cfunction(reused_cfunc_target, Cint, (Cint,))
    return [
        ("noinline", reused_noinline(2)),
        ("inline", reused_inline(2)),
        ("nospec", reused_nospec(2)),
        ("const", reused_const()),
        ("cfunc", Int(ccall(fptr, Cint, (Cint,), Cint(2)))),
        ("kwargs", reused_kwargs(2; scale = 3)),
        ("varargs", reused_varargs(2, 2, 2)),
        ("invoke", reused_invoke(Circle(2.0))),
        ("oc", make_oc()(2)),
        ("sparam", reused_sparam(2)),
        ("finalizer", FINALIZED[] - state),
        ("state", state),
        ("reverse", apply_dynamic(delta_callee, 2)),
        ("cone", cone_caller()),
    ]
end

function run_all(io::IO)
    for (name, value) in driver()
        println(io, "shape: ", name, " = ", value)
    end
    println(io, "shape: ccallable = ", ccall_entry())
    n = 5_000_000
    (sr, tr) = bench(bench_reused, n)
    (sd, td) = bench(bench_delta, n)
    sr == sd || println(io, "bench: the sums differ ", sr, " ", sd)
    println(io, "bench: reused ", round(tr; digits = 2), " ns/call; delta ",
            round(td; digits = 2), " ns/call")
    return nothing
end

# The one specialization that the workload and `julia_main` share: `stdout`
# has no fixed type, so `run_all(stdout)` would compile at run time.
function report()
    io = IOBuffer()
    run_all(io)
    return String(take!(io))
end
