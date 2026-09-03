# Stage-1a acceptance: a region window follows its task. Two tasks
# interleave on one thread - each allocates into its own claimed region
# across yields - and an open window pins its task (sticky), restored at
# close. Then the same under @spawn on every thread.
# One REGION-ESCAPE warning is expected: the blocking take! inside the
# window grows the channel's wait queue - an allocation stored into
# region-0 state, caught by the barrier. That is the composability
# hazard of windows, demonstrated by the test's own plumbing; the
# quarantine it causes is harmless here (nothing resets EVENT).
region_set(n)  = ccall(:jl_gc_region_set, Cint, (Cint,), n)
region_reset(n) = ccall(:jl_gc_region_reset, UInt64, (Cint,), n)
region_of(x)   = Int(ccall(:jl_gc_region_of, Cint, (Any,), x))
const EVENT = 2
failures = Ref(0)
check(name, cond) = (cond || (failures[] += 1; println("FAIL: ", name)))

function interleave()
    # The handshake and the results carry no pointers: a Channel{Nothing}
    # stores a singleton and the Int vector stores isbits - no write
    # barrier fires, so the test's own plumbing cannot escape.
    ch1, ch2 = Channel{Nothing}(1), Channel{Nothing}(1)
    got = zeros(Int, 3)
    tA = Threads.@spawn begin
        was_sticky = current_task().sticky
        region_set(EVENT)
        check("open makes sticky", current_task().sticky)
        a = Ref(1); got[1] = region_of(a)
        put!(ch1, nothing); take!(ch2)              # park the window, run B
        b = Ref(2); got[2] = region_of(b)
        region_set(0)
        check("close restores sticky", current_task().sticky == was_sticky)
        a[] + b[]
    end
    tB = Threads.@spawn begin
        take!(ch1)                             # A's window is parked now
        c = Ref(3); got[3] = region_of(c)
        put!(ch2, nothing)
        c[]
    end
    fetch(tA); fetch(tB)
    check("A allocates in its window before the yield", got[1] == EVENT)
    check("A allocates in its window after the yield", got[2] == EVENT)
    check("B allocates outside A's window", got[3] == 0)
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
