# Stage-1a acceptance: a region window follows its task. Two tasks
# interleave on one thread - each allocates into its own claimed region
# across yields - and an open window pins its task (sticky), restored at
# close. Then the same under @spawn on every thread.
region_set(n)  = ccall(:jl_gc_region_set, Cint, (Cint,), n)
region_reset(n) = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
region_of(x)   = Int(ccall(:jl_gc_region_of, Cint, (Any,), x))
const EVENT = 2
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

function interleave()
    ch1, ch2 = Channel{Int}(1), Channel{Int}(1)
    got = Dict{String,Int}()
    tA = Threads.@spawn begin
        was_sticky = current_task().sticky
        region_set(EVENT)
        check("open makes sticky", current_task().sticky)
        a = Ref(1); got["A1"] = region_of(a)
        put!(ch1, 1); take!(ch2)              # park the window, run B
        b = Ref(2); got["A2"] = region_of(b)
        region_set(0)
        check("close restores sticky", current_task().sticky == was_sticky)
        a[] + b[]
    end
    tB = Threads.@spawn begin
        take!(ch1)                             # A's window is parked now
        c = Ref(3); got["B"] = region_of(c)
        put!(ch2, 1)
        c[]
    end
    fetch(tA); fetch(tB)
    check("A allocates in its window before the yield", got["A1"] == EVENT)
    check("A allocates in its window after the yield", got["A2"] == EVENT)
    check("B allocates outside A's window", got["B"] == 0)
end

function spawn_stress()
    n = Threads.nthreads() * 8
    ok = Threads.Atomic{Int}(0)
    Threads.@sync for k in 1:n
        Threads.@spawn begin
            region_set(EVENT)
            r = Ref(k)
            for _ in 1:4
                yield()
                region_of(r) == EVENT || error("window lost across yield")
                Ref(0)                 # allocate inside the window
            end
            region_set(0)
            Threads.atomic_add!(ok, 1)
        end
    end
    check("every spawned window survived its yields", ok[] == n)
end

interleave()
spawn_stress()
GC.gc()   # every window is closed; regions hold only dead scratch
println(failures[] == 0 ? "TASK WINDOW: ALL PASS" : "TASK WINDOW: $(failures[]) FAILURES")
