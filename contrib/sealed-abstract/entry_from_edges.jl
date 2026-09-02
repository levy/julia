# Build from the compiler's own call graph, plus the dispatches it could not
# resolve.
#
# THE RECORDED SET IS TWO PARTS, and neither needs run-time instrumentation:
#
#   S  the static closure — walk `CodeInstance.edges` transitively from the
#      entry. Inference resolved these, so the graph is exact and free.
#   D  the dynamic targets — every instance the run compiled that is NOT in S.
#      Above `max_union_splitting` inference records no edge, so an instance
#      with code and no edge is one dispatch reached at run time.
#
# Everything happens in ONE process, so gensym'd names never have to cross a
# boundary — a cross-process trace lost 4977 routing signatures to that.
# The dynamic set must be what THIS RUN created. The method table already holds
# ~73 000 instances from starting Julia and loading the buildscript; treating
# all of them as "dynamic targets the graph missed" registered 53 061
# entrypoints and took inference from 0.4 s to 19.7 s.
import Serialization
const TRACE_IN = Base.get(Base.ENV, "SEALED_TRACE_IN", "")
const SEALED_FRONTIER = Base.get(Base.ENV, "SEALED_LOOP", "seeded") == "frontier"
const KEEP_STATIC = Base.get(Base.ENV, "SEALED_TRACE_KEEP_STATIC", "")

# Skipped entirely when a trace is loaded. This is the expensive half — it
# runs the program.
function _snapshot()
    s = Base.IdSet{Any}()
    Base.visit(Core.methodtable) do method
        method isa Core.Method || return
        for mi in Base.specializations(method)
            mi isa Core.MethodInstance && Base.push!(s, mi)
        end
    end
    s
end
# LOAD THE PROGRAM'S PACKAGES BEFORE THE SNAPSHOT. `include(PROGRAM)` covers
# the program's `using` lines, and loading a precompiled package materialises
# its whole instance set - 25 844 for `OmnetLegacyRouting` - inside the window the
# recorder calls "what this run created". Phase 0 of routing is a program that
# only loads its packages, and it registered 8645 roots and failed with 26
# errors on them.
#
# Naming them here moves the load OUTSIDE the window, so "created in the
# window" means what it says. The program's own `using` then finds them
# loaded and adds nothing.
#
# TWO PROPERTIES OF THE INSTANCE WERE TRIED FIRST, AND BOTH FAILED. `no edges`
# is what this file's header claims marks a dynamic target; it took
# `trace_abstract` from D=10 to D=0 and a pass to a fail, so genuine targets
# do carry edges. `min_world >= the snapshot world` reads as "inferred in this
# session", but a CodeInstance's min_world says when the code becomes VALID:
# a Base method specialised on a program type keeps Base's old world, and
# `trace_typeparam` lost all five of its targets.
for _pkg in Base.split(Base.get(Base.ENV, "SEALED_TRACE_PACKAGES", ""), ",")
    Base.isempty(_pkg) && continue
    Core.eval(Main, Base.Meta.parse("import " * _pkg))
end

# THE SEAL FILE APPLIES HERE, not where the buildscript would otherwise apply
# it. A seal changes what INFERENCE does, and this file runs the program a few
# lines below: by the time the buildscript reaches its own hook the bodies a
# seal meant to widen are already inferred and cached, and the seal then
# changes nothing at all. Measured on routing phase 3:
# `seal_collapse(_apply_word, 2, 3)` set `nospecialize=6` on the one method and
# the repair pass still reported the site at its full 2809 combinations.
#
# The packages are loaded on the line above, so the functions a seal names
# exist. The call is a no-op when SEALED_SEAL_FILE is unset, and it runs once.
Base.invokelatest(Base.getglobal(Main, :sealed_apply_seal_file))
Core.@latestworld

# THE RECORDER RECORDS SPECIALIZATION, NOT EXECUTION, and coverage is the
# missing signal. The snapshot difference is everything INFERENCE touched,
# including branches it analysed and the run never took: a stacktrace hook on
# the generic document printer never fires during a routing network build, and
# 96 `show` specializations appear anyway, because one error message that
# interpolates a distribution is enough to create them.
#
# Run the program under `--code-coverage=user` and every method it EXECUTED
# carries a positive count on its own lines. Four facts decide the rule, and
# each one was measured here:
#
#   - A method that never ran shows `-`, not `0`. It is never compiled, so it
#     is never instrumented, so `-` and `0` mean the same thing and the only
#     positive signal is a count above zero.
#   - A PRECOMPILED package method that runs IS counted. `Unitful.ustrip` at
#     utils.jl:58 comes out of a package image and still shows `1`, because
#     coverage forces instrumented code generation. Without this the filter
#     would drop every method the packages already compiled.
#   - The file is `<source>.<pid>.cov`. Name it by the pid of the run that
#     wrote it. Taking the last `.cov` match in the directory reads some
#     earlier run's data.
#   - THE BUILD CAN NOT MEASURE ITSELF. The juliac child reports
#     `JLOptions().code_coverage` as set, because the flag is forwarded, and it
#     writes no coverage data at all: it generates an object file rather than
#     running ordinary code. A recorder that read its own coverage found no
#     file anywhere, kept all 10 entries of `trace_abstract`, and read as a
#     pass. So the coverage comes from `record_coverage.jl`, a separate
#     ordinary run of the same program, and its pid names the files.
#
# The rule is per METHOD, not per specialization: it can not tell
# `show(::Normal)` from `show(::Weibull)`.
const COVPID = Base.get(Base.ENV, "SEALED_TRACE_COVPID", "")
const COVERAGE_ON = !Base.isempty(COVPID)
const COVCACHE = Base.Dict{Base.String,Base.Any}()
const COVDIR = Base.Dict{Base.String,Bool}()
const COVLINES = Base.IdDict{Any,Any}()
const EXEC_SIGS = Base.IdSet{Any}()
# The same test over EVERY instance the window created, before the closure
# and root filters, so an edge TARGET can be asked whether its method ran.
const EXEC_ALL = Base.IdSet{Any}()

function _cov_counts(path::Base.String)
    Base.get!(COVCACHE, path) do
        local f = path * "." * COVPID * ".cov"
        Base.isfile(f) || return nothing
        local out = Int[]
        for l in Base.eachline(f)
            # The count field is nine ASCII bytes wide, so a byte index is safe.
            local t = Base.strip(Base.ncodeunits(l) >= 9 ? l[1:9] : l)
            Base.push!(out, (t == "-" || Base.isempty(t)) ? -1 :
                            Base.something(Base.tryparse(Int, t), -1))
        end
        out
    end
end

# ABSENCE IS EVIDENCE ONLY WHERE THE TREE WAS INSTRUMENTED. A file with no
# coverage beside siblings that have it ran no line. A file whose whole
# directory is uninstrumented says nothing, and its methods are kept.
_cov_dir(d::Base.String) = Base.get!(COVDIR, d) do
    Base.isdir(d) && Base.any(f -> Base.endswith(f, "." * COVPID * ".cov"), Base.readdir(d))
end

# THE METHOD'S OWN LINES, NOT A WINDOW. A fixed window of 40 lines reads the
# next method's counts and keeps a method that never ran. The lowered IR names
# every line the method occupies, which is exactly what coverage instruments.
# The definition line is the fallback, and it carries a count of its own for an
# ordinary `function` or a one-line definition.
function _method_lines(m)
    Base.get!(COVLINES, m) do
        local out = Int[Int(m.line)]
        try
            local ci = Base.uncompressed_ir(m)
            for i in 1:Base.length(ci.code)
                for n in Base.IRShow.buildLineInfoNode(ci.debuginfo, m, i)
                    n.file === m.file && Base.push!(out, Int(n.line))
                end
            end
        catch
        end
        out
    end
end

# A VACUOUS FILTER MUST SAY SO. If no file carries information the filter keeps
# everything and reads as a pass, which is how a broken recorder hides. Count
# the methods no coverage file could answer for, and report the number.
const COV_NOINFO = Base.Ref(0)
const COV_SEEN = Base.Ref(0)

# `count` decides whether the call joins the report above. The edge-target
# test asks about every instance the window created - most of them in Base,
# which carries no coverage - and it must not turn the report into "19 429 of
# 25 848 methods had NO coverage information" about a 1302-method trace.
function _cov_executed(m; count::Bool = true)
    m isa Method || return true
    count && (COV_SEEN[] += 1)
    local path = Base.String(m.file)
    local counts = _cov_counts(path)
    if counts === nothing
        # No file for this source. If the directory was instrumented at all,
        # nothing in this file ran; if it was not, we know nothing.
        _cov_dir(Base.dirname(path)) && return false
        count && (COV_NOINFO[] += 1)
        return true
    end
    for l in _method_lines(m)
        1 <= l <= Base.length(counts) && counts[l] > 0 && return true
    end
    return false
end

TRACE_IN == "" && _snapshot()     # warm, so the baseline holds this code too
const BEFORE = TRACE_IN == "" ? _snapshot() : Base.IdSet{Any}()

# The program to build. Set SEALED_TRACE_PROGRAM to point at another one.
const PROGRAM = Base.get(Base.ENV, "SEALED_TRACE_PROGRAM",
                         Base.joinpath(@__DIR__, "work-regress", "f_plain.jl"))
# THE PROGRAM MAY MARK ITS OWN BUILD-TIME WORK. Without this the recorder
# registers everything the include created, and phase 1 of routing carried
# 8669 roots for a binary that reads one number out of a baked index.
Main.SealHints.RECORDING[] = true
# THE RECORDER NEEDS THE SEALED WORLD ON, and the buildscript now leaves it off
# while the program loads - that saves 3.6s of a routing build, because a
# plain build's load only defines methods. This file is different: it RUNS the
# program inside the include, and the run is the recording. With the sealed
# world off, inference resolves less and everything it could not resolve lands
# in D: `trace_abstract` went from 10 recorded targets to 30, `expand_product`
# from 0 to 5. The verdicts held, but a trace three times larger than it needs
# to be is the defect this whole branch exists to remove.
Main.Compiler.SEALED_WORLD[] = true
# RECORD EDGES, NOT ONLY TARGETS (§26). A bare target can not say WHICH site
# observed it, so the recorder has to guess whether the build will derive it -
# and it guesses by walking `main`'s closure, which above the split limit is a
# graph the build does not have.
Main.Compiler.SEALED_RECORD_EDGES[] = true
include(PROGRAM)
Main.SealHints.RECORDING[] = false
Core.println("SEAL-BUILDTIME marked ", Base.length(Main.SealHints.BUILDTIME), " instances")
# THE RECORDER MUST SPLIT. `SEALED_SUBTYPES` is what makes the sealed compiler
# treat an abstract type as the union of its concretes, and the buildscript
# sets it AFTER including this file — so the run below would otherwise infer
# with no splitting at all, resolve almost nothing, and dump everything into D.
# Routing recorded that way produced 28 857 dynamic targets where features.jl
# produces 53.
if TRACE_IN == "" && Base.get(Base.ENV, "SEALED_RECORD_SPLIT", "") != ""
    local lists = Base.IdDict{Any,Any}()
    local seen = Base.IdSet{Module}()
    # `parentmodule(Base) === Main`, so an unguarded walk from Main descends
    # into Base and every submodule — thousands of names, and subtype lists for
    # types the program never touches. The buildscript guards this with the same
    # root check; dropping it made the recorder pass visibly slow.
    local function rootmod(m::Module)
        local r = m
        while Base.parentmodule(r) !== r; r = Base.parentmodule(r); end
        r
    end
    local function scan(mod::Module)
        (mod in seen) && return
        local r = rootmod(mod)
        (r === Core || r === Base) && return
        Base.push!(seen, mod)
        for nm in Base.names(mod; all = true)
            Base.isdefined(mod, nm) || continue
            local v = try Base.getglobal(mod, nm) catch; continue end
            if v isa Module
                v !== mod && Base.parentmodule(v) === mod && scan(v)
            elseif v isa Type
                local t = v
                if t isa DataType && !Base.isabstracttype(t) && Base.isconcretetype(t)
                    local sup = Base.supertype(t)
                    while sup !== Any
                        Base.isabstracttype(sup) && Base.push!(
                            Base.get!(Base.Vector{Any}, lists, sup), t)
                        sup = Base.supertype(sup)
                    end
                end
            end
        end
    end
    scan(Main)
    local subs = Base.IdDict{Any,Any}()
    for (k, v) in lists
        subs[k] = Base.Union{v...}
    end
    Base.getglobal(Main, :Compiler).SEALED_SUBTYPES[] = subs
    Core.println("EDGE-TRACE recorder: split enabled over ", Base.length(subs), " abstract types")
end
# RUN IT THE WAY THE BINARY WILL BE RUN. `main` takes arguments, and what it
# does with them decides which code the run reaches: the flagship records result
# files only when it is given a result directory, so a run with no arguments
# records a trace with no recorder in it. SEALED_TRACE_ARGS is the same variable
# `record_coverage.jl` reads, so the two runs agree.
const RUN_ARGS = Base.String[a for a in Base.split(
                     Base.get(Base.ENV, "SEALED_TRACE_ARGS", ""), ' ')
                 if !Base.isempty(a)]
# WHY A METHOD REACHED ONLY BY DISPATCH CAN BE MISSING FROM THE TRACE.
#
# `_walk` follows `main`'s edges to decide what the trim DERIVES, and anything
# it reaches is left out of D. That closure is measured HERE, and the build
# computes its own under different settings: the buildscript builds
# `SEALED_SUBTYPES` AFTER including this file, so the abstract-to-union map is
# off while the recorder infers and ON while the build does.
#
# MEASURED on the flagship. `deliver_message!` is called nowhere statically -
# `schedule_event!` takes it as a VALUE and the only call is `evt.action(...)`.
# While recording, that site's argument positions are narrow, the split
# resolves, and edges to the method exist, so all four of its instances are
# rejected as `in-mains-static-closure`. While building, positions 3 and 4 are
# `Union{Nothing, EventArgument-concretes}` - 25 members each, because
# `GateOwner <: EventArgument` drags every module type in - the product is
# 4 x 25 x 25 = 2500 against a split limit of 64, the split is declined, and no
# edge is ever created. The method is compiled ZERO times.
#
# TAKING THE CLOSURE BEFORE THE RUN DOES NOT FIX IT: 25263 instances against
# 25264, the same four rejections, 21 errors either way. Registering the whole
# closure is worse still - 549 entries become 2317 and the flagship goes from
# 20 errors to 30 (§6b). The fix is to make the two closures agree, or to
# narrow the event argument union so the build's split succeeds.
#
# `SEALED_TRACE_WHY=<name>` prints which filter rejected each instance of a
# method. Three theories about this one were wrong before it existed.
TRACE_IN == "" && Base.invokelatest(getglobal(Main, :main), RUN_ARGS)

# FREEZE the set here, the instant the run ends. Everything below — the edge
# walk, the registration loop, its closure captures — creates instances of its
# own, and a set computed by walking the LIVE table afterwards contains them.
# That put `Compiler.widenconst` and `Core.Box` captures of this file's own
# loop variables into the binary, as nine unresolved dispatches.
const AFTER = TRACE_IN == "" ? _snapshot() : Base.IdSet{Any}()

# ROOT FILTER. A dynamic target is the PROGRAM's own dispatch, so it belongs
# to the program's own packages. Anything else in D got compiled merely because
# the program LOADED — StyledStrings, DataStructures iterators, display
# machinery — and a simulation binary never calls it.
#
# This is the rule the analysing compiler already applies through
# SEALED_TARGET_ROOTS. Two other tests were tried and are wrong:
#   - "the method appears in main's static closure": a method reached only
#     through a dynamic call is not in that closure, and neither is anything
#     below it. It dropped every entry features.jl needs.
#   - no filter at all: routing registers 27 618 targets and reports 46
#     verifier errors, against 23 with a filter.
const TRACE_ROOTS = let e = Base.get(Base.ENV, "SEALED_TRACE_ROOTS", "")
    Base.isempty(e) ? Base.String[] : Base.String[Base.String(Base.strip(x)) for x in Base.split(e, ",")]
end

function _root_ok(d)
    d isa Method || return false
    local r = d.module
    while Base.parentmodule(r) !== r; r = Base.parentmodule(r); end
    (r === Core || r === Base) && return false
    Base.nameof(r) === :Compiler && return false
    Base.isempty(TRACE_ROOTS) && return true
    return Base.String(Base.nameof(r)) in TRACE_ROOTS
end

const SEEN = Base.IdSet{Any}()
const STATIC = Any[]
function _walk(c)
    (c in SEEN) && return
    Base.push!(SEEN, c); Base.push!(STATIC, c)
    for e in c.edges
        e isa Core.CodeInstance && _walk(e)
    end
end
if TRACE_IN == ""
    let mi = Base.method_instance(getglobal(Main, :main), (Vector{String},))
        Base.isdefined(mi, :cache) && mi.cache isa Core.CodeInstance && _walk(mi.cache)
    end
end

const IN_S = Base.IdSet{Any}()
for c in STATIC
    Base.push!(IN_S, Base.get_ci_mi(c))
end

# REGISTER ONLY THE DYNAMIC TARGETS. The static closure S is what the trim
# DERIVES from `main` on its own, so registering it adds nothing — and it does
# harm: an instance with a vararg signature (`string(Any...)`,
# `println(IO, Any...)`) forced to compile standalone as an entrypoint cannot
# resolve, where the same code reached through the closure specializes
# concretely. That mistake took a clean 2-error build to a wall of
# SEALED-PUSH errors.
#
# D is the information the trim CANNOT derive: above `max_union_splitting`
# inference records no edge, so these targets exist only because dispatch
# reached them at run time.
# TWO WAYS TO BUILD, and the split matters because tracing is the expensive
# half: it runs the program.
#
#   SEALED_TRACE_IN=<path>   load a recorded D and compile. The program is
#                            included so its types exist, but it is NOT run and
#                            no graph is walked.
#   SEALED_TRACE_OUT=<path>  trace and compile, and write D out for reuse.
#
# Only D crosses the boundary — 53 entries on features.jl, not the 28 636 a
# whole-set trace needed. That matters: gensym'd names (`##format_value#2`,
# closures) are numbered per session and can not be resolved in another one, so
# a trace can only name methods with stable names. D is dispatch TARGETS, which
# are named methods almost by definition.
let nd = 0, skipped = 0
    local wanted = Any[]
    if TRACE_IN != ""
        for t in Serialization.deserialize(TRACE_IN)
            Base.push!(wanted, t)
        end
        # THE EDGES ANSWER A SITE THE TARGET LIST CAN NOT. A target the
        # recorder saw at a dispatch site belongs in the table whether or not
        # `main`'s closure appeared to reach it: the closure was measured under
        # settings the build does not have.
        # THE TABLE IS CONSULTED AT A DECLINED SITE, NOT REGISTERED WHOLESALE.
        # 20 758 sites carry 63 726 targets, and pushing all of them into the
        # trace is the "keep everything" mistake again - 549 entries became 2317
        # once and took the flagship from 20 errors to 30. The site identity is
        # recorded precisely so that only a site which FAILS asks for its own
        # targets: `sealed_push_declined!` looks itself up by
        # `(caller signature, statement index)`.
        let ef = TRACE_IN * ".edges"
            if Base.isfile(ef)
                local sites = Serialization.deserialize(ef)
                local n = 0
                for (k, ts) in sites
                    Main.Compiler.SEALED_EDGE_BY_SITE[k] = ts
                    n += Base.length(ts)
                end
                Core.println("EDGE-TRACE edges loaded from ", ef, ": ",
                             Base.length(sites), " sites, ", n, " targets")
            end
        end
    else
        # WHY WAS A METHOD NOT RECORDED? `SEALED_TRACE_WHY=name` prints the
        # filter that rejected each instance of a method with that name. Every
        # theory about a missing entry has been wrong so far - the closure, the
        # split limit, the ordering - because the filters were never asked.
        local _why = Base.get(Base.ENV, "SEALED_TRACE_WHY", "")
        local _say = function (mi, reason)
            Base.isempty(_why) && return
            local d = mi.def
            d isa Method || return
            Base.String(d.name) == _why || return
            Core.println("EDGE-TRACE-WHY ", reason, "  ", mi.specTypes)
        end
        for mi in AFTER
            mi isa Core.MethodInstance || continue
            if COVERAGE_ON && !(mi in BEFORE) && mi.def isa Method &&
               _cov_executed(mi.def; count = false)
                Base.push!(EXEC_ALL, mi.specTypes)
            end
            if mi in BEFORE
                _say(mi, "existed-before-the-run")
                continue
            end
            if mi in IN_S
                _say(mi, "in-mains-static-closure")
                # THE CLOSURE IS THE RECORDER'S, NOT THE BUILD'S (§26). `_walk`
                # measures what `main`'s edges reach HERE, and the build reaches
                # less: above the split limit `CodeInstance.edges` gives nothing
                # at all, and edges are precisely what is missing there.
                #
                # SEALED_TRACE_KEEP_STATIC=1 records these anyway. On the
                # frontier loop an entry is EVIDENCE consulted at a declined
                # site, not a root, so an entry no site demands is never
                # compiled - which is what makes keeping them affordable.
                #
                # AFFORDABLE IS NOT FREE: keeping ALL of them also keeps the
                # `@nospecialize` reflection entries - `declared_default`,
                # `parameter_field_names` - whose widened compileable form can
                # never compile (its body reflects over an unknown `Type`).
                # Measured: keep-all took the flagship from a working binary
                # to 8 errors. A comma list of FILE BASENAMES keeps only the
                # subtree that needs it - the recorder's own file, whose
                # executed instances the build can not derive.
                if KEEP_STATIC == ""
                    continue
                elseif KEEP_STATIC != "1"
                    local _kf = mi.def isa Method ?
                        Base.basename(Base.String(mi.def.file)) : ""
                    (_kf in Base.split(KEEP_STATIC, ",")) || continue
                end
            end
            _root_ok(mi.def) || (_say(mi, "not-a-program-root"); continue)      # not the program's own dispatch
            Base.nameof(Base.parentmodule(mi.def)) === :Compiler && continue
            Base.nameof(Base.parentmodule(mi.def)) === :SealHints && continue
            # WHAT THE PROGRAM MARKED AS BUILD TIME. `seal_buildtime` is the
            # only thing that can tell a constant being computed from a
            # function being warmed: both run inside `include(PROGRAM)`, and
            # both have ordinary types.
            (mi in Main.SealHints.BUILDTIME) && (_say(mi, "marked-build-time"); continue)
            (Base.isdefined(mi, :cache) && mi.cache isa Core.CodeInstance) || (_say(mi, "no-code-instance"); continue)
            Base.isdispatchtuple(mi.specTypes) || (_say(mi, "not-a-dispatch-tuple"); continue)
            Base.push!(wanted, mi.specTypes)
            # TEST THE METHOD HERE, where `mi.def` is still in hand. Resolving a
            # signature back to its methods afterwards through
            # `_methods_by_ftype` answers a different question and loses the
            # ones it can not resolve.
            COVERAGE_ON && _cov_executed(mi.def) && Base.push!(EXEC_SIGS, mi.specTypes)
        end
        # BUILD-TIME MACHINERY IS NOT A DISPATCH TARGET. Including the
        # program runs its macros, and everything they touch gets compiled —
        # inside the very window the recorder watches. Measured on
        # `macro_buildtime`: the recorder registers
        # `Tuple{typeof(_shape_of), Expr}`, a helper that runs only at
        # expansion time and can never be called at run time.
        #
        # TEST THE PARAMETER, NOT THE PRINTED NAME. A substring match on
        # "Module" hits `OmnetSimulator.NetworkModule.Network` — nearly every
        # type the model has. That version dropped 1951 of 2018 entries and took
        # routing from 30 verifier errors to 554, because it removed the model
        # rather than the macro machinery.
        local function _buildtime_shape(t)
            try
                for p in t.parameters
                    (p === Expr || p === Module || p === Method ||
                     p === Core.MethodInstance || p === LineNumberNode) && return true
                end
            catch
            end
            return false
        end
        let dropped = 0, keep = Any[]
            for mi in wanted        # these are SIGNATURE TYPES, not instances
                if _buildtime_shape(mi)
                    dropped += 1
                else
                    Base.push!(keep, mi)
                end
            end
            dropped == 0 || Core.println("EDGE-TRACE dropped ", dropped,
                                         " build-time shapes; kept ", Base.length(keep))
            wanted = keep
        end

        # THE EXECUTED-ONLY SPLIT, applied last so the two files differ by this
        # rule alone. `<out>.all` is the unfiltered set: it is the evidence for
        # what the filter removed, and it is what a build compares against.
        local wanted_all = wanted
        if COVERAGE_ON
            local keep = Any[]
            local drop = Any[]
            for t in wanted
                (t in EXEC_SIGS) ? Base.push!(keep, t) : Base.push!(drop, t)
            end
            Core.println("EDGE-TRACE coverage: ", Base.length(keep), " executed, ",
                         Base.length(drop), " not executed, of ", Base.length(wanted),
                         "; ", COV_NOINFO[], " of ", COV_SEEN[],
                         " methods had NO coverage information")
            COV_SEEN[] == COV_NOINFO[] && Core.println(
                "EDGE-TRACE coverage: VACUOUS - no source file carried a count. ",
                "The run wrote no coverage, so this filter decided nothing.")
            for (i, t) in Base.enumerate(drop)
                i > 40 && (Core.println("  ... and ", Base.length(drop) - 40, " more"); break)
                Core.println("  NOT-EXECUTED ", t)
            end
            wanted = keep
        end

        let out = Base.get(Base.ENV, "SEALED_TRACE_OUT", "")
            if out != ""
                # CAN THE ENTRY CROSS? Ask, do not guess from its printed form.
                #
                # The test used to be `occursin("#", string(t))`, and it is far
                # too coarse. A gensym from a PACKAGE is stable across sessions
                # - it is generated at precompile time and baked into the `.ji`
                # - while only a session's own top-level gensyms can not be
                # resolved again. Rejecting every signature that MENTIONS one
                # throws away entries that carry a gensym deep inside a type
                # parameter and are otherwise perfectly nameable.
                #
                # MEASURED: `deliver_message!` is dropped by that test, because
                # its `ctx` argument is
                # `EventContext{MSequentialEngine{Union{..., var"#10#11"{App}}}}`
                # - the engine's action union names an anonymous function. The
                # method itself is ordinary, and the build then has NO instance
                # of it: sixteen unresolved calls in `execute_events!`.
                #
                # A round trip answers exactly the question that matters.
                local function _named(v)
                    local named = Any[]
                    local gensyms = 0
                    for t in v
                        local ok = try
                            local io = Base.IOBuffer()
                            Serialization.serialize(io, t)
                            Base.seekstart(io)
                            Serialization.deserialize(io) === t
                        catch
                            false
                        end
                        ok ? Base.push!(named, t) : (gensyms += 1)
                    end
                    (named, gensyms)
                end
                if COVERAGE_ON
                    local (all_named, _) = _named(wanted_all)
                    Serialization.serialize(out * ".all", all_named)
                    Core.println("EDGE-TRACE unfiltered set written to ", out, ".all: ",
                                 Base.length(all_named), " entries")
                end
                # THE EDGES, keyed by `(caller method signature, statement
                # index)`. The site is a SOURCE location and is the same on both
                # sides; the argument types are not.
                local edges = Base.Dict{Any,Any}()
                local edge_targets = 0
                local edge_dropped = 0
                for (k, v) in Main.Compiler.SEALED_EDGE_LOG
                    local (kept, _) = _named(v)
                    # AN EDGE TARGET IS EVIDENCE ONLY IF IT RAN. The log holds
                    # every target inference matched, on every path it
                    # analysed; the executed-only rule that filters the trace
                    # filters the edges too, or a declined site pulls display
                    # machinery an error path was analysed for.
                    if COVERAGE_ON
                        local ran = Any[t for t in kept if t in EXEC_ALL]
                        edge_dropped += Base.length(kept) - Base.length(ran)
                        kept = ran
                    end
                    Base.isempty(kept) && continue
                    local ok = try
                        local b = Base.IOBuffer()
                        Serialization.serialize(b, k)
                        Base.seekstart(b)
                        Serialization.deserialize(b) == k
                    catch
                        false
                    end
                    ok || continue
                    edges[k] = kept
                    edge_targets += Base.length(kept)
                end
                Serialization.serialize(out * ".edges", edges)
                # THE SAME TABLE IN ONE PROCESS. A build that continues from
                # here has no file to load, and the lookup then reported
                # `0 sites in the table` on the two-process path. Fill it from
                # the filtered set, so both paths consult the same edges.
                for (k, ts) in edges
                    Main.Compiler.SEALED_EDGE_BY_SITE[k] = ts
                end
                Core.println("EDGE-TRACE edges written to ", out, ".edges: ",
                             Base.length(edges), " sites, ", edge_targets, " targets",
                             COVERAGE_ON ? string(", ", edge_dropped, " not-executed targets dropped") : "")

                local (named, gensyms) = _named(wanted)
                Serialization.serialize(out, named)
                Core.println("EDGE-TRACE written to ", out, ": ", Base.length(named),
                             " entries, ", gensyms, " gensym-named dropped")
            end
        end
    end
    # RECORD-ONLY. Stop after the trace is written, so a later process can
    # build from the file without running the program (SEALED_TRACE_IN).
    #
    # THIS IS A CONVENIENCE, NOT A NECESSITY. One process can record and build
    # with the same settings, and does: `build_phase.sh 3` reaches 0 errors in
    # one juliac process when it has a coverage pid. What a single process can
    # NOT do is measure its own coverage - a juliac child reports the flag as
    # set and writes no data - so the executed-only filter always needs one
    # ordinary julia run first. Without that filter the repair rounds diverge
    # (22, 42, 62, 697 errors on phase 3), on display machinery an error path
    # was analysed for and the run never executed.
    if Base.get(Base.ENV, "SEALED_RECORD_ONLY", "") != ""
        Core.println("EDGE-TRACE record-only: stopping before the build")
        Base.exit(0)
    end
    for t in wanted
        # ROOTS OR EVIDENCE, and the loop decides. Seeded, every entry is an
        # entrypoint. On the frontier loop it goes into the trace table and a
        # declined dispatch site consults it, so an entry no site demands is
        # never compiled.
        #
        # `Main.Compiler`, NOT `Base.Compiler`. Julia's builtin compiler also
        # has `add_entrypoint`, so this line worked against the wrong module
        # and never said so.
        try
            if SEALED_FRONTIER
                Main.Compiler.sealed_add_trace_sig!(t)
            else
                Main.Compiler.add_entrypoint(t)
            end
            nd += 1
        catch err
            skipped += 1
            skipped == 1 && Core.println("EDGE-TRACE first skip: ", err)
        end
    end
    Core.println("EDGE-TRACE: ", Base.length(IN_S), " static in the graph (NOT registered), ",
                 nd, " dynamic registered, ", skipped, " skipped")
end
