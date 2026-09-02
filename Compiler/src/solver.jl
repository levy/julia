# THE DEMAND-DRIVEN SOLVER — plan Part Two, sections 21 to 38.
#
# The old loop seeds a worklist with roots, follows static edges, and drains a
# side channel of declined dispatch sites. Evidence enters it in three
# different places and in a fixed order: the union split happens inside
# inference, the seals are environment variables the buildscript reads, the
# trace is a list of roots the ENTRY FILE registers before compilation starts,
# and the generic fallback is a repair loop that runs after verification.
#
# That is why a defect in the recorder could put 8645 package instances into a
# routing phase-1 binary: a trace entry is a ROOT, so nothing ever asked
# whether a call site needed it.
#
# This loop asks. It holds one worklist of OBLIGATIONS, each carrying the
# evidence that justified it, and every unresolved call goes through one
# function, `resolve_dispatch`. Adding a new kind of evidence means adding an
# arm there, not another phase.
#
#     while the worklist is not empty:
#         obligation  <- dequeue
#         result      <- analyse and compile
#         for each call the result discovered:
#             resolution <- resolve_dispatch(call, knowledge)
#             enqueue its targets, tagged with the evidence that found them
#
# BOTH LOOPS ARE KEPT. `SEALED_LOOP=frontier` selects this one. They are
# cross-tested against each other on the ladder, and the old one is the
# baseline: a difference in the compiled set is a finding about one of them.

"""
    SEALED_LOOP

Which compile loop runs, `:seeded` or `:frontier`. Both are kept so they can
be cross-tested; `:seeded` is the baseline.
"""
const SEALED_LOOP = Base.RefValue(:seeded)

"""
    SEALED_PROGRESS_NS

How often `compile_frontier!` prints a progress line, in nanoseconds. Five
seconds by default; `SEALED_PROGRESS=0` silences it.
"""
const SEALED_PROGRESS_NS = Base.RefValue(UInt64(5_000_000_000))

"""
    SEALED_EVIDENCE_ORDER

The order `resolve_dispatch` consults its evidence, weakest promise last.

This is the order the algorithm states: an observation the program actually
made is preferred to an enumeration of a sealed type. Section 23 of the plan
writes the lattice the other way round, `PROVEN > SEALED > TRACE`, on the
argument that a seal promises something about the whole domain while a trace
reports one run. The two disagree only where both apply, and the disagreement
is recorded rather than resolved: this is a table so that it can be changed,
and eventually made cost-based.
"""
const SEALED_EVIDENCE_ORDER =
    (:proven, :trace, :declared, :sealed, :expanded, :generic)

"""
    Obligation

Something to compile, and why. The provenance is not decoration: it is what
lets a build say which evidence justified each instance, and it is what a
cost-based ordering will eventually rank.
"""
struct Obligation
    target::Any            # CodeInstance, MethodInstance or SimpleVector
    provenance::Symbol
end

"""
    Knowledge

What the solver has learned. The evidence providers write here, and
`resolve_dispatch` reads. Today the trace and the seals still arrive through
the entry file and the environment; this type is where they move to.
"""
mutable struct Knowledge
    const declined::Vector{Any}      # call sites inference would not resolve
    const seen::IdSet{Any}           # targets already turned into obligations
    const answered::IdDict{Symbol,Int}  # which arm answered, and how often
    frontier::Int                    # obligations enqueued since the last round
end

Knowledge() = Knowledge(Any[], IdSet{Any}(), IdDict{Symbol,Int}(), 0)

"""
    resolve_dispatch(target, knowledge) -> (targets, provenance)

THE CENTRAL OPERATION. One place decides how a call is answered, and every
kind of evidence is an arm here.

Only two arms carry weight today, and that is the honest state of it:

  :proven   inference resolved the call and left an `:invoke` edge. The
            static-edge case, which needs no evidence at all.
  :trace    the call was declined and something recorded a target for it.
            This is the drain: `SEALED_EXTRA_TARGETS`.

WHAT THIS ARM DOES NOT SEE. It answers sites the INLINER reports as declined.
A call that never produces a `CallInfo` the inliner processes is invisible to
it: `trace_typeparam` dispatches `kind_of` on `Type{T1..T5}` values, its five
trace entries are exactly those, and no declined site names that function at
all. It passes on the seeded loop, where every trace entry is a root, and
fails here. Recording sites from inference as well as from the inliner is what
would close it.

The remaining arms - `:declared`, `:sealed`, `:expanded`, `:generic` - are
answered elsewhere in the compiler today: the seals by `SEALED_SUBTYPES` read
in the buildscript, the union split inside inference by `SEALED_SPLIT_LIMIT`,
the generic fallback by a repair pass that runs after verification. They are
named here so the arms exist before the evidence moves into them, and so a
build can already say which one answered.
"""
function resolve_dispatch(@nospecialize(target), knowledge::Knowledge)
    local mi = sealed_keep(target)
    mi === nothing && return (nothing, :filtered)
    return (mi, :sealed)
end

"""
    drain_declined!(workqueue, knowledge)

Turn every declined dispatch site into obligations. This is step 3 of the
algorithm: a call the solver could not prove becomes new compilation
obligations rather than an error.

THE BATCH IS SORTED, and it has to be. The pull pushes in warm-table order,
and the table is an `IdDict`, so its order is address-dependent: identical
builds compiled pulled instances in a different order every run, and the error
count swung between 1 and about 120 on identical inputs. The key is
content-stable, and dispatch-tuple instances sort first, so a concrete
instance is compiled before its widened cousin and infers precisely.
"""
function drain_declined!(workqueue::CompilationQueue, knowledge::Knowledge)
    isempty(SEALED_EXTRA_TARGETS) && isempty(SEALED_DECLINED_SIGS) && return 0
    local batch = Any[]
    while !isempty(SEALED_EXTRA_TARGETS)
        local t = pop!(SEALED_EXTRA_TARGETS)
        (t in SEALED_DRAIN_SEEN) && continue
        push!(SEALED_DRAIN_SEEN, t)
        local (mi, why) = resolve_dispatch(t, knowledge)
        mi === nothing && continue
        knowledge.answered[why] = get(knowledge.answered, why, 0) + 1
        push!(batch, mi)
    end
    sort!(batch, by = _sealed_drain_key)
    for mi in batch
        push!(workqueue, sealed_prov!(mi, :drain))
    end
    return length(batch)
end

"""
    compile_frontier!(codeinfos, workqueue; invokelatest_queue)

The fixed point. It ends when no obligation is left AND no call site is still
declined - not when the worklist empties, because draining a declined site
enqueues more work.

The body of each obligation is the same work the original loop does; what
differs is that the declined sites go through `resolve_dispatch` instead of
being pushed straight onto the queue.
"""
function compile_frontier!(codeinfos::Vector{Any}, workqueue::CompilationQueue;
                invokelatest_queue::Union{CompilationQueue,Nothing} = nothing)
    local interp = workqueue.interp
    local world = get_inference_world(interp)
    local knowledge = Knowledge()
    local rounds = 0
    local drained = 0
    # PROGRESS AND REPEATED WORK. A phase-3 routing build spent more than
    # fifteen minutes in codegen with nothing on the log between
    # `buildscript-end` and the binary, so there was no way to tell slow work
    # from a hang except by reading utime out of /proc.
    #
    # The repeat counters answer the other half: `typeinf_ext` is called once
    # per queue item, and the same MethodInstance reaches the queue by more
    # than one route. SEALED_ITEM_TIMES has always recorded one row per visit -
    # a routing build held 6855 rows for 5316 distinct instances - but nothing
    # ever reported the difference.
    local t_start = Base.time_ns()
    local t_report = t_start
    local infer_calls = 0
    local infer_ns = 0
    local repeat_calls = 0
    local repeat_ns = 0
    local inferred_once = IdSet{Any}()

    while !isempty(workqueue) || !isempty(SEALED_EXTRA_TARGETS)
        drained += drain_declined!(workqueue, knowledge)
        isempty(workqueue) && continue
        rounds += 1
        # A LINE EVERY FEW SECONDS, so a long build can be followed. Time-based
        # and not count-based: obligations are not uniform, and a build that
        # slows down is exactly the one that must keep reporting.
        local now = Base.time_ns()
        if now - t_report > SEALED_PROGRESS_NS[]
            t_report = now
            Core.println("SEALED-FRONTIER ", Base.round((now - t_start) / 1.0e9, digits = 1),
                         "s  obligations=", rounds,
                         " queue=", length(workqueue.tocompile),
                         " emitted=", length(codeinfos),
                         " declined=", 0,
                         " infer=", infer_calls, " repeats=", repeat_calls)
        end
        local item = pop!(workqueue)

        if item isa MethodInstance
            isinspected(workqueue, item) && continue
            if item.def.primary_world <= world
                local t0 = Base.time_ns()
                local ci = typeinf_ext(interp, item, SOURCE_MODE_GET_SOURCE)
                local dt = Base.time_ns() - t0
                push!(SEALED_ITEM_TIMES, (dt, item))
                infer_calls += 1; infer_ns += dt
                if item in inferred_once
                    repeat_calls += 1; repeat_ns += dt
                else
                    push!(inferred_once, item)
                end
                ci isa CodeInstance && push!(workqueue, ci)
            end
            markinspected!(workqueue, item)

        elseif item isa SimpleVector
            invokelatest_queue === nothing && continue
            local (rt::Type, sig::Type) = item
            local mi = ccall(:jl_get_specialization1, Any,
                             (Any, Csize_t, Cint), sig, world, #= mt_cache =# 0)
            if mi !== nothing
                mi = mi::MethodInstance
                local t1 = Base.time_ns()
                local ci = typeinf_ext(interp, mi, SOURCE_MODE_GET_SOURCE)
                local dt1 = Base.time_ns() - t1
                push!(SEALED_ITEM_TIMES, (dt1, mi))
                infer_calls += 1; infer_ns += dt1
                mi in inferred_once ? (repeat_calls += 1; repeat_ns += dt1) :
                                      push!(inferred_once, mi)
                ci isa CodeInstance && push!(invokelatest_queue, ci)
            end
            push!(codeinfos, item)

        elseif item isa CodeInstance
            local callee = item
            isinspected(workqueue, callee) && continue
            local mi = get_ci_mi(callee)
            local src
            if use_const_api(callee)
                src = codeinfo_for_const(interp, mi,
                        WorldRange(callee.min_world, callee.max_world),
                        callee.edges, callee.rettype_const)
            else
                src = get(interp.codegen, callee, nothing)
                if src === nothing
                    local t2 = Base.time_ns()
                    local newcallee = typeinf_ext(interp, mi, SOURCE_MODE_GET_SOURCE)
                    local dt2 = Base.time_ns() - t2
                    push!(SEALED_ITEM_TIMES, (dt2, mi))
                    infer_calls += 1; infer_ns += dt2
                    mi in inferred_once ? (repeat_calls += 1; repeat_ns += dt2) :
                                          push!(inferred_once, mi)
                    if newcallee isa CodeInstance
                        @assert use_const_api(newcallee) || haskey(interp.codegen, newcallee)
                        push!(workqueue, newcallee)
                    end
                    newcallee === callee || markinspected!(workqueue, callee)
                    continue
                end
            end
            markinspected!(workqueue, callee)
            if src isa CodeInfo
                local sptypes = sptypes_from_meth_instance(mi)
                # STEP 3: every call this specialization discovered. An
                # `:invoke` edge is the PROVEN arm - inference resolved it and
                # no evidence is needed.
                SEALED_TRACE_ONLY[] ||
                    collectinvokes!(workqueue, src, sptypes; invokelatest_queue)
                if iszero(ccall(:jl_mi_cache_has_ci, Cint, (Any, Any), mi, callee))
                    local cached = ccall(:jl_get_ci_equiv, Any, (Any, UInt), callee, world)::CodeInstance
                    if cached === callee
                        code_cache(interp)[mi] = callee
                    else
                        callee = cached
                    end
                end
                push!(codeinfos, callee)
                push!(codeinfos, src)
            end
        else
            @assert false "unexpected item in queue"
        end
    end
    Core.println("SEALED-FRONTIER inference ", Base.round(infer_ns / 1.0e9, digits = 2),
                 "s over ", infer_calls, " calls on ", length(inferred_once),
                 " distinct instances; ", repeat_calls, " repeats cost ",
                 Base.round(repeat_ns / 1.0e9, digits = 2), "s")
    Core.print("SEALED-FRONTIER fixed point after ", rounds, " obligations, ",
               drained, " from declined sites")
    for w in SEALED_EVIDENCE_ORDER
        local c = get(knowledge.answered, w, 0)
        c == 0 || Core.print("  ", w, "=", c)
    end
    Core.println()
    return codeinfos
end

"""
    compile!(codeinfos, workqueue; invokelatest_queue)

THE ONE ENTRY, so the two loops can never be mixed within a build.

  :seeded    `compile_seeded!` - roots are seeded before compilation starts,
             static edges are followed, and evidence is applied in separate
             phases afterwards. The baseline.
  :frontier  `compile_frontier!` - obligations are resolved on demand at each
             unresolved call, through one `resolve_dispatch`. The plan names
             the principle in section 31: solve the frontier, never the
             program.

The names come from the project's own vocabulary. The trace SEEDS the old
loop, which is what "trace-seeded" means; the new one solves a FRONTIER.

WHY THIS IS A DISPATCHER AND NOT A FLAG AT THE CALL SITE. There are three
call sites - the main queue, the invokelatest drain, and the repair pass - and
the first version switched only the first. A build asking for the frontier
loop ran the seeded one for the other two, which is exactly the confusion
having names is meant to prevent.
"""
function compile!(codeinfos::Vector{Any}, workqueue::CompilationQueue;
                  invokelatest_queue::Union{CompilationQueue,Nothing} = nothing)
    if SEALED_LOOP[] === :frontier
        return compile_frontier!(codeinfos, workqueue; invokelatest_queue)
    end
    return compile_seeded!(codeinfos, workqueue; invokelatest_queue)
end
