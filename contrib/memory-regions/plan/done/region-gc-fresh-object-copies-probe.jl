include(joinpath(ENV["JLROOT"], "test/gc/regions_api.jl"))
mutable struct Holder; f::Any; end
struct Twin; a::Base.RefValue{Int}; b::Base.RefValue{Int}; end
mutable struct TwinHolder; t::Twin; end
@noinline make_child() = Ref{Int}(123456789)
@noinline construct_holder(c) = Holder(c)
@noinline construct_twin_holder(c) = TwinHolder(Twin(c, c))
@noinline box_twin(c) = Any[Twin(c, c)]
@noinline function run(n, f)
    region_set(n); c = make_child(); region_set(0)
    return f(c)
end
p = run(5, construct_holder);      println("boxed child at construction:  quarantined(5) = ", quarantined(5))
q = run(6, construct_twin_holder); println("inline child at construction: quarantined(6) = ", quarantined(6))
r = run(7, box_twin);              println("inline child in a fresh box:  quarantined(7) = ", quarantined(7))
println(p.f[], " ", q.t.a[], " ", r[1].a[])
