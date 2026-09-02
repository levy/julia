# This file is a part of Julia. License is MIT: https://julialang.org/license

import ..Compiler: verify_typeinf_trim, NativeInterpreter, argtypes_to_type, compileable_specialization_for_call,
    SEALED_REPAIR,
    SEALED_WORLD, SEALED_MAX_METHODS, findall, method_table, MethodMatch, isvarargtype,
    # the why-chain: this file lives in a SUBMODULE, so the parent's names are
    # not in scope without asking. Omitting them made every chain throw an
    # UndefVarError into the one `catch` that turns a report into
    # "SEALED-DESC-DETAIL failed" - 314 of them, saying nothing.
    SEALED_WHY, SEALED_PROVENANCE, SEALED_TARGET_SITE, get_ci_mi,
    # the argument promises: inference and this file compute a site's type
    # SEPARATELY, so a promise honoured in only one of them narrows what is
    # compiled while the other reports the underived types.
    sealed_apply_argument_promises!

using ..Compiler:
     # operators
     !, !=, !==, +, -, :, <, <=, ==, =>, >, >=, ∈, ∉,
     # types
     Array, Builtin, Callable, Cint, CodeInfo, CodeInstance, Csize_t, Exception,
     GenericMemory, GlobalRef, IdDict, IdSet, IntrinsicFunction, Method, MethodInstance,
     NamedTuple, Pair, PhiCNode, PhiNode, PiNode, QuoteNode, SSAValue, SimpleVector, String,
     Tuple, VarState, Vector,
     # functions
     argextype, empty!, error, get, get_ci_mi, get_world_counter, getindex, getproperty,
     hasintersect, haskey, in, isdispatchelem, isempty, isexpr, iterate, length, map!, max,
     pop!, popfirst!, push!, pushfirst!, reinterpret, reverse!, reverse, setindex!,
     setproperty!, similar, singleton_type, sptypes_from_meth_instance, sp_type_rewrap,
     unsafe_pointer_to_objref, widenconst, isconcretetype,
     # misc
     @nospecialize, @assert, C_NULL
using ..IRShow: LineInfoNode, print, show, println, append_scopes!, IOContext, IO, normalize_method_name
using ..Base: Base, sourceinfo_slotnames
using ..Base.StackTraces: StackFrame

## declarations ##

struct CallMissing <: Exception
    codeinst::CodeInstance
    codeinfo::CodeInfo
    sptypes::Vector{VarState}
    stmtidx::Int
    desc::String
end

struct CCallableMissing <: Exception
    rt
    sig
    desc
end

const _SEALED_DEBUG_BUDGET = Base.RefValue{Int}(60)
const ParentMap = IdDict{CodeInstance,Tuple{CodeInstance,Int}}
const ErrorList = Vector{Pair{Bool,Any}} # severity => exception

const runtime_functions = Symbol[
    # a denylist of any runtime functions which someone might ccall which can call jl_apply or access reflection state
    # which might not be captured by the trim output
    :jl_apply,
]

## code for pretty printing ##

# wrap a statement in a typeassert for printing clarity, unless that info seems already obvious
function mapssavaluetypes(codeinfo::CodeInfo, sptypes::Vector{VarState}, stmt)
    @nospecialize stmt
    newstmt = mapssavalues(codeinfo, sptypes, stmt)
    typ = widenconst(argextype(stmt, codeinfo, sptypes))
    if newstmt isa Expr
        if newstmt.head ∈ (:quote, :inert)
            return newstmt
        end
    elseif newstmt isa GlobalRef && isdispatchelem(typ)
        return newstmt
    elseif newstmt isa Union{Int, UInt8, UInt16, UInt32, UInt64, Float16, Float32, Float64, String, QuoteNode}
        return newstmt
    elseif newstmt isa Callable
        return newstmt
    end
    return Expr(:(::), newstmt, typ)
end

# map the ssavalues in a (value-producing) statement to the expression they came from, summarizing some things to avoid excess printing
function mapssavalues(codeinfo::CodeInfo, sptypes::Vector{VarState}, stmt)
    @nospecialize stmt
    if stmt isa SSAValue
        return mapssavalues(codeinfo, sptypes, codeinfo.code[stmt.id])
    elseif stmt isa PiNode
        return mapssavalues(codeinfo, sptypes, stmt.val)
    elseif stmt isa Expr
        stmt.head ∈ (:quote, :inert) && return stmt
        newstmt = Expr(stmt.head)
        if stmt.head === :foreigncall
            return Expr(:call, :ccall, mapssavalues(codeinfo, sptypes, stmt.args[1]))
        elseif stmt.head ∉ (:new, :method, :toplevel, :thunk)
            newstmt.args = map!(similar(stmt.args), stmt.args) do arg
                @nospecialize arg
                return mapssavaluetypes(codeinfo, sptypes, arg)
            end
            if newstmt.head === :invoke
                # why is the fancy printing for this not in show_unquoted?
                popfirst!(newstmt.args)
                newstmt.head = :call
            end
        end
        return newstmt
    elseif stmt isa PhiNode
        return PhiNode()
    elseif stmt isa PhiCNode
        return PhiNode()
    end
    return stmt
end

function verify_print_stmt(io::IOContext{IO}, codeinfo::CodeInfo, sptypes::Vector{VarState}, stmtidx::Int)
    if codeinfo.slotnames !== nothing
        io = IOContext(io, :SOURCE_SLOTNAMES => sourceinfo_slotnames(codeinfo))
    end
    print(io, mapssavaluetypes(codeinfo, sptypes, SSAValue(stmtidx)))
end

function verify_print_error(io::IOContext{IO}, desc::CallMissing, parents::ParentMap)
    (; codeinst, codeinfo, sptypes, stmtidx, desc) = desc
    frames = verify_create_stackframes(codeinst, stmtidx, parents)
    print(io, desc, " from statement ")
    verify_print_stmt(io, codeinfo, sptypes, stmtidx)
    Base.show_backtrace(io, frames)
    print(io, "\n\n")
    nothing
end

function verify_print_error(io::IOContext{IO}, desc::CCallableMissing, ::ParentMap)
    print(io, desc.desc, " for ", desc.sig, " => ", desc.rt, "\n\n")
    nothing
end

function verify_create_stackframes(codeinst::CodeInstance, stmtidx::Int, parents::ParentMap)
    scopes = LineInfoNode[]
    frames = StackFrame[]
    # THIS IS THE SAME parents MAP the WHY-chain above walks, and it can
    # cycle the same way: the document printer shows a field that is a
    # document, so parents[CI] can end up pointing back to CI itself. The
    # WHY-chain walk learned that lesson and guards it with a seen set and a
    # depth cap. This walk did not, and a cyclic entry here is not
    # hypothetical either - measured directly, it ran past 385 million
    # iterations, still growing `frames` without bound, until the process
    # was killed (once by the OOM killer, once by an external timeout) and
    # took the whole report down with it: no further "Verifier error #"
    # lines, no "Trim verify finished" line at all.
    seen = IdSet{CodeInstance}()
    parent = (codeinst, stmtidx)
    depth = 0
    while parent !== nothing && depth < 256
        codeinst, stmtidx = parent
        (codeinst in seen) && break # a cycle: stop here rather than loop forever
        push!(seen, codeinst)
        di = codeinst.debuginfo
        append_scopes!(scopes, stmtidx, di, :var"unknown scope")
        for i in reverse(1:length(scopes))
            lno = scopes[i]
            inlined = i != 1
            def = lno.method
            def isa Union{Method,Core.CodeInstance,MethodInstance} || (def = nothing)
            sf = StackFrame(normalize_method_name(lno.method), lno.file, lno.line, def, false, inlined, 0)
            push!(frames, sf)
        end
        empty!(scopes)
        parent = get(parents, codeinst, nothing)
        depth += 1
    end
    return frames
end

## code for analysis ##

function may_dispatch(@nospecialize ftyp)
    if ftyp <: IntrinsicFunction
        return true
    elseif ftyp <: Builtin
        # other builtins (including the IntrinsicFunctions) are good
        return Core._apply isa ftyp ||
               Core._apply_iterate isa ftyp ||
               Core._call_in_world_total isa ftyp ||
               Core.invoke isa ftyp ||
               Core.invoke_in_world isa ftyp ||
               Core.invokelatest isa ftyp ||
               Core.finalizer isa ftyp ||
               Core.modifyfield! isa ftyp ||
               Core.modifyglobal! isa ftyp ||
               Core.memoryrefmodify! isa ftyp
    else
        return true
    end
end

function verify_codeinstance!(interp::NativeInterpreter, codeinst::CodeInstance, codeinfo::CodeInfo, inspected::IdSet{CodeInstance}, caches::IdDict{MethodInstance,CodeInstance}, parents::ParentMap, errors::ErrorList)
    mi = get_ci_mi(codeinst)
    # The kernel's reference-pattern PRINTERS (`_show_rules` and family):
    # diagnostics on error arms whose Any-valued fields make their print
    # sites unresolvable by construction — `show(io, expr.value)` over a
    # pattern binding enumerates every show method the image knows. Never on
    # a run path (the SelectionModule reasoning, verifier-side); a run that
    # DID reach one dies at that call, and the hash acceptance would say so.
    let def = mi.def
        if def isa Method && Base.nameof(def.module) === :ReferenceModule
            sn = Base.String(def.name)
            (Base.startswith(sn, "_show_") || Base.startswith(sn, "#_show_")) && return nothing
        end
        # ERASED kernel instances: a ProjecturedKernel method compiled at an
        # all-Any (or bare `Type`) specialization — the document walk
        # (`_walk_document!`: TOML/TermInfo/TTY haskey were among its
        # demands, measured), the gesture-binding family, `unwrap_cell`,
        # `search_documents`. Editor-side machinery whose Any iteration and
        # getproperty enumerate the image; the TYPED instances verify on
        # their own, and a run that DID reach an erased one dies at that
        # call — the hash acceptance would say so.
        if def isa Method &&
           Base.nameof(Base.moduleroot(def.module)) === :ProjecturedKernel
            st = mi.specTypes
            if st isa DataType && Base.length(st.parameters) > 1 &&
               Base.all(i -> st.parameters[i] === Any || st.parameters[i] === Type,
                        2:Base.length(st.parameters))
                return nothing
            end
        end
    end
    sptypes = sptypes_from_meth_instance(mi)
    src = codeinfo.code
    for i = 1:length(src)
        stmt = src[i]
        isexpr(stmt, :(=)) && (stmt = stmt.args[2])
        error = ""
        warn = false
        if isexpr(stmt, :invoke) || isexpr(stmt, :invoke_modify)
            error = "unresolved invoke"
            edge = stmt.args[1]
            if edge isa CodeInstance
                haskey(parents, edge) || (parents[edge] = (codeinst, i))
                edge in inspected && continue
                edge_mi = get_ci_mi(edge)
                if edge_mi === edge.def
                    ci = get(caches, edge_mi, nothing)
                    ci isa CodeInstance && continue # assume that only this_world matters for trim
                end
            end
            # TODO: check for calls to Base.atexit?
        elseif isexpr(stmt, :call)
            farg = stmt.args[1]
            ftyp = widenconst(argextype(farg, codeinfo, sptypes))
            if ftyp <: IntrinsicFunction
                #TODO: detect if f !== Core.Intrinsics.atomic_pointermodify (see statement_cost), otherwise error
                continue
            elseif ftyp <: Builtin
                if !may_dispatch(ftyp)
                    continue
                end
                if !isconcretetype(ftyp)
                    error = "unresolved call to (unknown) builtin"
                elseif Core._apply_iterate isa ftyp
                    if length(stmt.args) >= 3
                        # args[1] is _apply_iterate object
                        # args[2] is invoke object
                        farg = stmt.args[3]
                        ftyp = widenconst(argextype(farg, codeinfo, sptypes))
                        if may_dispatch(ftyp)
                            error = "unresolved call to function"
                        else
                            for i in 4:length(stmt.args)
                                atyp = widenconst(argextype(stmt.args[i], codeinfo, sptypes))
                                if !(atyp <: Union{SimpleVector, GenericMemory, Array, Tuple, NamedTuple})
                                    error = "unresolved argument to call"
                                    break
                                end
                            end
                        end
                    end
                elseif Core.finalizer isa ftyp
                    if 3 <= length(stmt.args) <= 5
                        finalizer = argextype(stmt.args[2], codeinfo, sptypes)
                        obj = argextype(stmt.args[3], codeinfo, sptypes)
                        atype = argtypes_to_type(Any[finalizer, obj])

                        mi = compileable_specialization_for_call(interp, atype)
                        if mi !== nothing
                            ci = get(caches, mi, nothing)
                            ci isa CodeInstance && continue
                        end
                    end
                    error = "unresolved finalizer registered"
                elseif Core._apply isa ftyp
                    error = "trim verification not yet implemented for builtin `Core._apply`"
                elseif Core._call_in_world_total isa ftyp
                    error = "trim verification not yet implemented for builtin `Core._call_in_world_total`"
                elseif Core.invoke isa ftyp
                    error = "trim verification not yet implemented for builtin `Core.invoke`"
                elseif Core.invoke_in_world isa ftyp
                    error = "trim verification not yet implemented for builtin `Core.invoke_in_world`"
                elseif Core.invokelatest isa ftyp
                    error = "trim verification not yet implemented for builtin `Core.invokelatest`"
                elseif Core.modifyfield! isa ftyp
                    error = "trim verification not yet implemented for builtin `Core.modifyfield!`"
                elseif Core.modifyglobal! isa ftyp
                    error = "trim verification not yet implemented for builtin `Core.modifyglobal!`"
                elseif Core.memoryrefmodify! isa ftyp
                    error = "trim verification not yet implemented for builtin `Core.memoryrefmodify!`"
                else @assert false "unexpected builtin" end
            else
                # --- sealed world -----------------------------------------------
                # A dynamic call whose match set is finite and whose every
                # matched METHOD has a compiled instance in the binary cannot
                # reach uncompiled code: the world is closed, and the optimizer
                # above the threshold deliberately left it dynamic with its
                # targets compiled. Membership is per method; the concrete
                # specializations exist because the trim drain compiled the
                # warm-run instances the decline site pulled.
                if SEALED_WORLD[]
                    argts = Any[]
                    okargs = true
                    for k = 1:length(stmt.args)
                        t = argextype(stmt.args[k], codeinfo, sptypes)
                        if isvarargtype(t)
                            okargs = false
                            break
                        end
                        push!(argts, widenconst(t))
                    end
                    if okargs
                        # THE PROMISE APPLIES HERE TOO. The verifier builds its
                        # own atype from `argextype`, so a promise honoured only
                        # by inference narrows what is COMPILED while this still
                        # reports the underived types and calls the site
                        # unresolved.
                        let _pm = get_ci_mi(codeinst).def
                            sealed_apply_argument_promises!(argts,
                                _pm isa Method ? _pm.sig : nothing, i)
                        end
                        # A POSITION PROMISED `Union{}` SAYS THE CALL NEVER
                        # HAPPENS - the site only exists for arities no callee
                        # in the image has. There is nothing to look up, and a
                        # bottom tuple must not reach findall.
                        local _vbottom = false
                        for _vk = 2:length(argts)
                            if argts[_vk] === Union{}
                                _vbottom = true
                                break
                            end
                        end
                        _vbottom && continue
                        atype = argtypes_to_type(argts)
                        # FINDALL CAN NOT SEARCH A UNION-TYPED CALLEE: each
                        # function owns its own method table, so a union atype
                        # matches nothing at all - measured as `findall failed
                        # n=0` at the engine's action site, while every member
                        # matches on its own. Split the callee and ask per
                        # member; inference makes the same split in
                        # find_method_matches before it ever calls findall.
                        local matchvec = nothing
                        local _vfw = argts[1]
                        if _vfw isa Union
                            local _vv = Any[]
                            local _vok = true
                            for _vmf in Base.uniontypes(_vfw)
                                local _vsub = Any[_vmf]
                                for _vk = 2:length(argts)
                                    Base.push!(_vsub, argts[_vk])
                                end
                                local _vmt = findall(argtypes_to_type(_vsub), method_table(interp); limit = SEALED_MAX_METHODS[])
                                if _vmt === nothing || _vmt === false
                                    _vok = false
                                    break
                                end
                                for _vj = 1:length(_vmt.matches)
                                    Base.push!(_vv, _vmt.matches[_vj])
                                end
                            end
                            _vok && (matchvec = _vv)
                        else
                            local _vmt = findall(atype, method_table(interp); limit = SEALED_MAX_METHODS[])
                            (_vmt === nothing || _vmt === false) || (matchvec = _vmt.matches)
                        end
                        # A MATCH SET TOO WIDE TO ENUMERATE IS NOT THE SAME AS
                        # NO MATCH, and the difference was reported nowhere. When
                        # `findall` gives up, the site falls straight through to
                        # an error: it is never offered to the repair pass, so it
                        # shows no skipped site, no missing instance, and raising
                        # the repair limit does nothing to it. Say so.
                        if matchvec === nothing
                            if (_SEALED_NOMATCH_BUDGET[] -= 1) > 0
                                Core.println("SEALED-VERIFY-NOMATCH limit=", SEALED_MAX_METHODS[],
                                             " in=", get_ci_mi(codeinst).def, " stmt#", i,
                                             "  ", atype)
                            end
                        end
                        if matchvec !== nothing && length(matchvec) > 0
                            allcompiled = true
                            for j = 1:length(matchvec)
                                match = matchvec[j]::MethodMatch
                                found = false
                                for kv in caches
                                    if kv.first.def === match.method
                                        found = true
                                        break
                                    end
                                end
                                if !found
                                    # NAME THE METHOD THAT HAS NO INSTANCE.
                                    # `allcompiled` is per METHOD, and on the
                                    # final pass - where `SEALED_REPAIR` is not
                                    # collecting - a false here falls straight
                                    # through to the error. Which method is
                                    # missing is the whole answer, and it was
                                    # reported nowhere: the error names the
                                    # CALLER and the statement, never the
                                    # callee that is absent.
                                    if (_SEALED_MISSING_BUDGET[] -= 1) > 0
                                        Core.println("SEALED-VERIFY-MISSING in=",
                                                     get_ci_mi(codeinst).def, " stmt#", i,
                                                     "  needs ", match.method)
                                    end
                                    allcompiled = false
                                    break
                                end
                            end
                            # REPAIR MODE: record the widened signature so
                        # `typeinf_trim` can expand it into the concrete
                        # instances dispatch will look for (`SEALED_REPAIR`).
                        if !allcompiled
                            let repair = SEALED_REPAIR[]
                                if repair !== nothing
                                    Base.push!(repair, atype)
                                    continue
                                end
                            end
                        end
                        allcompiled && continue
                            if (_SEALED_DEBUG_BUDGET[] -= 1) > 0
                                Core.println("SEALED-DEBUG STMT in=", get_ci_mi(codeinst).def,
                                             " n=", length(matchvec), " atype=", atype)
                                shown = 0
                                for j = 1:length(matchvec)
                                    match = matchvec[j]::MethodMatch
                                    found = false
                                    for kv in caches
                                        if kv.first.def === match.method
                                            found = true
                                            break
                                        end
                                    end
                                    if !found
                                        Core.println("SEALED-DEBUG   missing: ",
                                                     match.method.name, " @ ", match.method.module,
                                                     " sig=", match.method.sig)
                                        (shown += 1) >= 2 && break
                                    end
                                end
                            end
                        elseif (_SEALED_DEBUG_BUDGET[] -= 1) > 0
                            print("SEALED-DEBUG findall failed n=")
                            print(matchvec === nothing ? -1 : length(matchvec))
                            print(" for ")
                            println(atype)
                        end
                    elseif (_SEALED_DEBUG_BUDGET[] -= 1) > 0
                        println("SEALED-DEBUG vararg args")
                    end
                end
                # ----------------------------------------------------------------
                error = "unresolved call"
            end
            extyp = argextype(SSAValue(i), codeinfo, sptypes)
            if extyp === Union{}
                warn = true # downgrade must-throw calls to be only a warning
            end
        elseif isexpr(stmt, :cfunction)
            length(stmt.args) != 5 && continue # required by IR legality
            f, at = stmt.args[2], stmt.args[4]

            at isa SimpleVector || continue  # required by IR legality
            ft = argextype(f, codeinfo, sptypes)
            argtypes = Any[ft]
            for i = 1:length(at)
                push!(argtypes, sp_type_rewrap(at[i], get_ci_mi(codeinst), #= isreturn =# false))
            end
            atype = argtypes_to_type(argtypes)

            mi = compileable_specialization_for_call(interp, atype)
            if mi !== nothing
                # n.b.: Codegen may choose unpredictably to emit this `@cfunction` as a dynamic invoke or a full
                # dynamic call, but in either case it guarantees that the required adapter(s) are emitted. All
                # that we are required to verify here is that the callee CodeInstance is covered.
                ci = get(caches, mi, nothing)
                ci isa CodeInstance && continue
            end

            error = "unresolved cfunction"
        elseif isexpr(stmt, :foreigncall)
            foreigncall = stmt.args[1]
            if isexpr(foreigncall, :tuple, 1)
                foreigncall = foreigncall.args[1]
                if foreigncall isa String
                    foreigncall = QuoteNode(Symbol(foreigncall))
                end
                if foreigncall isa QuoteNode
                    if foreigncall.value in runtime_functions
                        error = "disallowed ccall into a runtime function"
                    end
                else
                    error = "disallowed ccall with non-constant name and no library"
                end
            end
        elseif isexpr(stmt, :new_opaque_closure)
            error = "unresolved opaque closure"
            # TODO: check that this opaque closure has a valid signature for possible codegen and code defined for it
            warn = true
        end
        if !isempty(error)
            # NAME THE STATEMENT, not only its index. An index is only useful
            # against the same IR, and the IR changes with every seal: five
            # errors reported at 762, 763, 800, 804, 805 could not be looked up
            # in a local `code_typed`, because a residual promise had shifted
            # the numbering and a promise can not be reproduced outside a build.
            # The statement itself is the same in every process.
            Core.println("SEALED-PUSH ", warn ? "warn " : "error ",
                         get_ci_mi(codeinst).def, " stmt#", i,
                         "  ", codeinfo.code[i])
            push!(errors, warn => CallMissing(codeinst, codeinfo, sptypes, i, error))
        end
    end
end

## entry-point ##

function get_verify_typeinf_trim(codeinfos::Vector{Any})
    Core.println("SEALED-VERIFY-BEGIN codeinfos=", length(codeinfos))
    this_world = get_world_counter()
    interp = NativeInterpreter(this_world)
    inspected = IdSet{CodeInstance}()
    caches = IdDict{MethodInstance,CodeInstance}()
    errors = ErrorList()
    parents = ParentMap()
    for i = 1:length(codeinfos)
        item = codeinfos[i]
        if item isa CodeInstance
            push!(inspected, item)
            if item.owner === nothing && item.min_world <= this_world <= item.max_world
                mi = get_ci_mi(item)
                if mi === item.def
                    caches[mi] = item
                end
            end
        end
    end
    for i = 1:length(codeinfos)
        item = codeinfos[i]
        if item isa CodeInstance
            src = codeinfos[i + 1]::CodeInfo
            verify_codeinstance!(interp, item, src, inspected, caches, parents, errors)
        elseif item isa SimpleVector
            rt = item[1]::Type
            sig = item[2]::Type
            mi = ccall(:jl_get_specialization1, Any,
                        (Any, Csize_t, Cint),
                        sig, this_world, #= mt_cache =# 0)
            asrt = Any
            valid = if mi !== nothing
                mi = mi::MethodInstance
                ci = get(caches, mi, nothing)
                if ci isa CodeInstance
                    # TODO: should we find a way to indicate to the user that this gets called via ccallable?
                    # parent[ci] = something
                    asrt = ci.rettype
                    true
                else
                    false
                end
            else
                false
            end
            if !valid
                warn = false
                push!(errors, warn => CCallableMissing(rt, sig, "unresolved ccallable"))
            elseif !(asrt <: rt)
                warn = hasintersect(asrt, rt)
                push!(errors, warn => CCallableMissing(asrt, sig, "ccallable declared return type does not match inference"))
            end
        end
    end
    return (errors, parents)
end

# It is unclear if this file belongs in Compiler itself, or should instead be a codegen
# driver / verifier implemented by juliac-buildscript.jl for the purpose of extensibility.
# For now, it is part of Base.Compiler, but executed with invokelatest so that packages
# could provide hooks to change, customize, or tweak its behavior and heuristics.
# How many `SEALED-VERIFY-NOMATCH` lines to print. A build reports the same
# site once per instance, so a handful names every distinct one.
const _SEALED_NOMATCH_BUDGET = Ref(40)

# How many `SEALED-VERIFY-MISSING` lines to print.
const _SEALED_MISSING_BUDGET = Ref(100000)

function verify_typeinf_trim(io::IO, codeinfos::Vector{Any}, onlywarn::Bool)
    errors, parents = get_verify_typeinf_trim(codeinfos)

    # count up how many messages we printed, of each severity
    counts = [0, 0] # errors, warnings
    io = IOContext{IO}(io)
    # print all errors afterwards, when the parents map is fully constructed
    for desc in errors
        warn, desc = desc
        severity = warn ? 2 : 1
        no = (counts[severity] += 1)
        print(io, warn ? "Verifier warning #" : "Verifier error #", no, ": ")
        Core.println("SEALED-DESC ", typeof(desc))
        try
            Core.println("SEALED-DESC-DETAIL [", desc.desc, "] in=",
                         desc.codeinst.def, " stmt#", desc.stmtidx)
            # WALK THE CHAIN TO ITS ROOT, not three levels of it. Three was
            # enough to see a caller and never enough to answer "how does this
            # reach `main`" - and on routing all three printed the SAME
            # instance, which reads as a chain and is a chain of length zero.
            #
            # Where the chain ends, the compiler's own provenance says how the
            # instance entered the compile set at all: an entrypoint, an edge
            # followed from another body, a declined dispatch site's target, or
            # a recorded observation. Those are different problems and they
            # were previously indistinguishable.
            # WHY THIS IS COMPILED, ALL THE WAY TO A ROOT.
            #
            # An explanation that stops at "something recorded this" is not an
            # explanation: the recorded target was reached by a caller, and
            # that caller is compiled for a reason of its own. The walk
            # therefore CROSSES the registration boundary - parents until the
            # chain ends, then the provenance, then the run-time caller that
            # put it in the trace, then that caller's own chain - and only
            # stops at a root, a cycle, or the cap.
            #
            # THE CYCLE IS NOT HYPOTHETICAL. The document printer shows a field
            # that is a document, so `show(IO, Document)` is recorded because
            # `show(IO, Document)` called it. Without the seen set this walk
            # does not terminate.
            # A DIAGNOSTIC MUST NOT BE ABLE TO KILL THE REPORT. The first
            # version of this walk threw partway through error #1 and took the
            # whole verification with it: the build printed one error, no
            # "Trim verify finished with N errors" line at all, and every
            # report of "phase 3 has 1 error" was that truncation. It has 197.
            try
            if SEALED_WHY[]
                local seen = IdSet{Any}()
                local cur = desc.codeinst
                local hop = 0
                while cur !== nothing && hop < 12
                    (cur in seen) && (Core.println("SEALED-WHY  (cycle)"); break)
                    push!(seen, cur)
                    local depth = 0
                    while depth < 64
                        local par = get(parents, cur, nothing)
                        par === nothing && break
                        par[1] === cur && break
                        Core.println("SEALED-WHY  ", depth == 0 && hop == 0 ?
                                     "called from " : "            ", par[1].def)
                        cur = par[1]
                        depth += 1
                        (cur in seen) && break
                        push!(seen, cur)
                    end
                    local mi = try get_ci_mi(cur) catch; nothing end
                    local why = mi === nothing ? :unknown :
                                Base.get(SEALED_PROVENANCE, mi, :unknown)
                    Core.println("SEALED-WHY  ^ entered as ", why,
                                 depth == 0 ? " (no static caller)" : "")
                    if why !== :drain && why !== :trace
                        break                      # a root, or an edge: done
                    end
                    local site = mi === nothing ? nothing :
                                 Base.get(SEALED_TARGET_SITE, mi, nothing)
                    site === nothing ||
                        Core.println("SEALED-WHY  demanded by site ",
                                     Base.first(Base.string(site), 96))
                    # CROSS THE BOUNDARY: continue from whoever reached it
                    # during the recording run.
                    local nxt = nothing
                    local named = false
                    if mi !== nothing && Base.isdefined(mi, :backedges)
                        local edges = Base.getfield(mi, :backedges)
                        # PREFER A COMPILED CALLER: only a CodeInstance lets
                        # the walk cross into that caller's own chain.
                        for e in edges
                            local c = try (e isa CodeInstance ? e :
                                           e isa MethodInstance &&
                                           Base.isdefined(e, :cache) ? e.cache :
                                           nothing) catch; nothing end
                            c isa CodeInstance || continue
                            (c in seen) && continue
                            Core.println("SEALED-WHY  recorded because ",
                                         get_ci_mi(c).def, " called it at run time")
                            nxt = c
                            named = true
                            break
                        end
                        # NAME IT EVEN WITHOUT A CODEINSTANCE. None of the
                        # backedges had a compiled instance to cross into,
                        # but a MethodInstance backedge is still a real
                        # caller the recorder saw - "no caller recorded"
                        # would be a lie one hop early if one is printed here
                        # instead. There is nothing to cross into, so the
                        # walk still stops at this hop.
                        if !named
                            for e in edges
                                local d = try (e isa MethodInstance ? e.def :
                                               e isa CodeInstance ? get_ci_mi(e).def :
                                               nothing) catch; nothing end
                                d === nothing && continue
                                Core.println("SEALED-WHY  recorded because ", d,
                                             " called it at run time (not itself compiled)")
                                named = true
                                break
                            end
                        end
                    end
                    named ||
                        Core.println("SEALED-WHY  no caller recorded: the ",
                                     "recording saw it with no backedge")
                    cur = nxt
                    hop += 1
                end
            end
            catch _why_ex
                Core.println("SEALED-WHY  <explanation failed: ",
                             typeof(_why_ex), ">")
            end
        catch ex
            Core.println("SEALED-DESC-DETAIL failed: ", typeof(ex))
        end
        # TODO: should we coalesce any of these stacktraces to minimize spew?
        # sealed world: one unprintable error must not hide the rest — a
        # rendering failure aborts the whole report otherwise
        try
            verify_print_error(io, desc, parents)
        catch ex
            Core.println("  <error rendering failed: ", typeof(ex), ">")
        end
    end

    ## TODO: compute and display the minimum and/or full call graph instead of merely the first parent stacktrace?
    #for i = 1:length(codeinfos)
    #    item = codeinfos[i]
    #    if item isa CodeInstance
    #        println(item, "::", item.rettype)
    #    end
    #end

    let severity = 0
        if counts[1] > 0 || counts[2] > 0
            print("Trim verify finished with ")
            print(counts[1], counts[1] == 1 ? " error" : " errors")
            print(", ")
            print(counts[2], counts[2] == 1 ? " warning" : " warnings")
            print(".\n")
            severity = 2
        end
        if counts[1] > 0
            severity = 1
        end
        # messages classified as errors are fatal, warnings are not
        0 < severity <= 1 && !onlywarn && throw(Core.TrimFailure())
    end
    nothing
end
