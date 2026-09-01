# The v2 regression battery. Every case here crashed (or guards a case that
# crashed) before the two runtime fixes of 2026-08-25: the regions[0]
# birth-initialization and the global window count in the defer guard.
#
#   ../../julia v2_regression.jl

rs(n)  = ccall(:jl_gc_region_set, Cint, (Cint,), n)
rr(n)  = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
rv(n)  = ccall(:jl_gc_region_verify, Cint, (Cint,), n)
rof(x) = ccall(:jl_gc_region_of, Cint, (Any,), x)

@noinline work(i) = (tmp = [Float64(i), 2.0, 3.0]; w = collect(1.0:4.0); sum(tmp) + sum(w))

failures = 0
function check(name, ok)
    global failures
    ok || (failures += 1)
    println(name, ": ", ok ? "pass" : "FAIL")
end

# 1. The original crasher: reset every iteration, explicit GC after quiesce.
f(n) = (acc = 0.0; for i in 1:n; rs(1); acc += work(i); rs(0); rr(1); end; acc)
f(1000); rr(1); GC.gc()
r = f(3_000_000); GC.gc()
check("reset loop + GC after quiesce", r == 4.5000465e12 && rv(1) == 0)

# 2. Swap-only: windows with no region allocation, no reset.
g(n) = (acc = 0.0; for i in 1:n; rs(1); acc += work(i); rs(0); end; acc)
g(1000); GC.gc()
r = g(3_000_000); GC.gc()
check("swap-only windows + GC", r == 4.5000465e12 && rv(1) == 0)

# 3. A live region object across two collections stays intact, and the
#    region bookkeeping verifies. (Live objects across a collection are
#    outside the contract; this asserts no corruption in the simple case.)
rs(1); a = [1.0, 2.0, 3.0]; rs(0)
GC.gc(); GC.gc()
check("live region object across GCs", sum(a) == 6.0 && rof(a) == 1 && rv(1) == 0)

println(failures == 0 ? "V2 REGRESSION: ALL PASS" : "V2 REGRESSION: $(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
