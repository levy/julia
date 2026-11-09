leaf_value() = 6
extra(x::Int) = 1
extra(x::Float64) = 2

# A new type: DepApp, which the tracked list puts first, defines a method on it.
struct Part
    value::Int
end
