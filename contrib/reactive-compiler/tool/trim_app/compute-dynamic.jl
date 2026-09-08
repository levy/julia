# The tracked file of the example: this edit makes a call site dynamic. The
# container holds `Any`, so the call of `score` on its element has no
# static target, and the trimmer refuses the image.
const SAMPLES = Any[1, 2.0]
score(n::Int) = n * n
score(x::Float64) = round(Int, x)
label(total::Int) = total > 500 ? "large" : string("small ", score(SAMPLES[2]))
