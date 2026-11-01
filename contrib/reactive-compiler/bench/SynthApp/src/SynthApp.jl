"""
    SynthApp

A small application whose dependency graph has known shape.

A real application does not let you choose where a function sits. This one does.
Each of the five edit classes of the plan has a marked place here, and the
comment above it says what the harvester must report.

`run_all()` compiles the graph. Call it before you harvest.
"""
module SynthApp

# The types that every generic function specializes on. More types means more
# MethodInstance values, which is what the harvester counts.
const ELEMENT_TYPES = (Float32, Float64, Int32, Int64)

# ---------------------------------------------------------------------------
# Class D — the type definition.
#
# Change a field type here. A change makes a NEW type, so every signature that
# names State is a new signature. Expect a large cone.
# ---------------------------------------------------------------------------
struct State{T}
    x::T
    y::T
end

# ---------------------------------------------------------------------------
# Class E — the constant.
#
# Change 1.0 to 1.1. Whether this invalidates anything depends on whether
# inference put the value in the IR or the code reads the binding at run time.
# ---------------------------------------------------------------------------
const SCALE = 1.0

# ---------------------------------------------------------------------------
# Class A — the leaf.
#
# Change 0.73 to 0.74. One caller. Expect the smallest cone in the program.
# ---------------------------------------------------------------------------
calculate_drag(x) = x * 0.73

drag_of(s::State) = calculate_drag(s.x)

# ---------------------------------------------------------------------------
# Class B — the middle.
#
# About a hundred generated methods call this. Expect a middle cone.
# ---------------------------------------------------------------------------
normalize_state(s::State{T}) where {T} = State{T}(s.x * T(SCALE), s.y * T(SCALE))

# ---------------------------------------------------------------------------
# Class C — the generic method.
#
# Every container operation goes through it. Expect the widest cone.
# ---------------------------------------------------------------------------
transform(v::AbstractArray) = sum(v) + length(v)

transform(s::State) = s.x + s.y

# --- the hundred callers of normalize_state -------------------------------
# Generate them, so that the count is a fact of the source and not a guess.
const CALLER_COUNT = 100

for i in 1:CALLER_COUNT
    fname = Symbol("stage_", i)
    @eval begin
        function $fname(s::State{T}) where {T}
            n = normalize_state(s)
            return n.x + n.y * T($i)
        end
    end
end

# --- a layer that fans in on the generated callers -------------------------
function pipeline(s::State{T}) where {T}
    acc = zero(T)
    acc += stage_1(s)
    acc += stage_2(s)
    acc += stage_3(s)
    return acc
end

function summarize(v::AbstractArray{State{T}}) where {T}
    total = zero(T)
    for s in v
        total += transform(s) + drag_of(s)
    end
    return total + transform(v isa AbstractArray ? [1, 2, 3] : [1])
end

"""
    run_all()

Compile the graph. Every generated caller and every element type is reached.
"""
function run_all()
    total = 0.0
    for T in ELEMENT_TYPES
        s = State{T}(one(T), one(T))
        total += Float64(pipeline(s))
        total += Float64(drag_of(s))
        total += Float64(transform(s))
        v = [State{T}(T(i), T(i)) for i in 1:3]
        total += Float64(summarize(v))
        for i in 1:CALLER_COUNT
            f = getfield(SynthApp, Symbol("stage_", i))
            total += Float64(f(s))
        end
    end
    total += transform([1.0, 2.0, 3.0])
    return total
end

end # module
