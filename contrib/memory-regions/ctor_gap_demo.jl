@noinline region_set(n) = Int(ccall(:jl_gc_region_set, Cint, (Cint,), n))
@noinline region_reset(n) = UInt64(ccall(:jl_gc_region_reset, UInt64, (Cint,), n))
@noinline quarantined(n) = Int(ccall(:jl_gc_region_quarantined, Cint, (Cint,), n)) != 0
mutable struct P; f::Any; end
@noinline make_child() = Ref{Int}(123456789)
@noinline ctor_only(c) = P(c)
@noinline function build()
    region_set(1); c = make_child(); region_set(0)
    return ctor_only(c)          # region-0 P holding region-1 child, ctor store
end
function run()
    p = build()
    println("before reset: p.f[] = ", (p.f)[], "  quarantined(1)=", quarantined(1))
    region_reset(1)              # frees region 1 — c is gone, p.f dangles
    # allocate churn into region 1's freed pages to overwrite c
    region_set(1); junk = [Ref{Int}(-1) for _ in 1:100000]; region_set(0)
    Base.donotdelete(junk)
    println("after reset:  p.f[] = ", (p.f)[], "   (was 123456789)")
end
run()
