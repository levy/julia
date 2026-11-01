# The tracked file of the example: this edit makes a call site dynamic. The
# container holds `Any`, and `score` has more methods than inference splits
# a call on, so the call of `score` on the element has no static target,
# and the trimmer refuses the image.
const SAMPLES = Any[1, 2.0, "3", true]
score(n::Int) = n * n
score(x::Float64) = round(Int, x)
score(s::String) = length(s)
score(b::Bool) = b ? 1 : 0
label(total::Int) = total > 500 ? "large" : string("small ", score(SAMPLES[2]))
