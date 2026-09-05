# dynamic_callee_domain — a union callee is bounded by the method table too.
# EXPECT proven=pass sealed=pass trace=pass
# SPLIT-CASES 12
#
# THE COMPANION TO `method_table_domain`, and the case one would expect the
# matcher to lose. It does not lose it.
#
# The function here is a VALUE in a field, typed as a union of two function
# types, so at first reading the matcher has no method table to enumerate: it
# does not know which function it is calling. The site is
# `(Action)(Arg, Int)`, priced at 2 callees x 12 argument types = 24 against a
# budget of 12, and the splitter declines it.
#
# MEASURED: the program verifies at 0 errors, and it does so even at the
# `proven` level, with the sealed apparatus off entirely. Julia splits the
# two-member union of function types by itself, and each half is then an
# ordinary call to a known function, where `find_method_matches` bounds the
# argument by the two declared methods. The abstract `Arg` never has to be
# enumerated at all.
#
# SO THE METHOD TABLE IS ALREADY IN USE, in both shapes. The bound a sealed
# world could derive from a closed method table is a bound the matcher already
# applies, and it applies it before the splitter is consulted.
#
# THIS IS THE ENGINE'S ACTION SITE, ALMOST. `deliver_message!(ctx, message,
# gate)` is reached through an event's action field, so position 1 is
# `Union{typeof(deliver_message!), typeof(_timer_fired!), ...}` and the
# argument positions derive from the event's argument fields —
# `Union{Nothing, EventArgument}`, where `GateOwner <: EventArgument` drags in
# every module type. Measured at 4 actions x 25 x 25 = 2500 against a budget of
# 64: declined, and nothing reaches the method.
#
# THE DIFFERENCE IS ONE WORD. The actions below declare `a::A1` and `a::A2`.
# `deliver_message!` declared NOTHING, so its method table said `Any` and the
# matcher had no bound to apply — which is why routing's seal file stated the
# domain by hand. Writing `gate::Gate` on that method retired the promise: the
# seal file's own derivation loop read it off `Base.methods`, the binary shrank
# by 68 464 bytes, and the network hash did not move.
#
# The lesson the two examples carry together: DECLARE THE PARAMETER. A seal is
# for what a declaration can not say — a parametric signature with no instance,
# or a scoped narrowing inside a method of Base.

abstract type Arg end

# The two the method tables declare.
struct A1 <: Arg; v::Int end
struct A2 <: Arg; v::Int end

# Ten more subtypes that neither action has a method for.
struct B1 <: Arg; v::Int end
struct B2 <: Arg; v::Int end
struct B3 <: Arg; v::Int end
struct B4 <: Arg; v::Int end
struct B5 <: Arg; v::Int end
struct B6 <: Arg; v::Int end
struct B7 <: Arg; v::Int end
struct B8 <: Arg; v::Int end
struct B9 <: Arg; v::Int end
struct B10 <: Arg; v::Int end

Base.@noinline act_add(a::A1, n::Int)::Int = n + a.v
Base.@noinline act_add(a::A2, n::Int)::Int = n + a.v * 2
Base.@noinline act_mul(a::A1, n::Int)::Int = n * a.v
Base.@noinline act_mul(a::A2, n::Int)::Int = n * (a.v + 1)

const Action = Union{typeof(act_add), typeof(act_mul)}

# The engine's event: an action to run and the argument to run it on. Both
# fields are declared at their widest, which is what a container of events
# forces.
struct Event
    action::Action
    arg::Arg
end

# THE SITE. `e.action` is a union of two function types and `e.arg` is the
# abstract `Arg`, so this one statement is the whole example.
Base.@noinline fire(e::Event, n::Int)::Int = e.action(e.arg, n)

# THE EVENTS MUST NOT BE LITERALS AT THE SITE. Built inline in `main`, the
# optimizer knows each element concretely and resolves every call without the
# splitter, so the example passes at `proven` and tests nothing. Behind a
# `@noinline` boundary the caller sees only `Vector{Event}`, and the two field
# reads are abstract, which is what a real event queue gives.
Base.@noinline make_events()::Vector{Event} =
    Event[Event(act_add, A1(2)), Event(act_mul, A2(3)),
          Event(act_add, A2(4)), Event(act_mul, A1(5))]

function (@main)(argv::Vector{String})::Cint
    events = make_events()
    acc = 1
    for e in events
        acc = fire(e, acc)
    end
    Base.print(Core.stdout, "dynamic_callee_domain: ", acc, "\n")
    return Cint(0)
end
