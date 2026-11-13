# The replay of an apply: the items whose text an edit leaves as it is, and
# whose evaluation gives another result after the edit.
#
# An evaluation has a result when Julia runs code for it: the expansion of a
# macro call, the value of an initializer, the body that a generator answers,
# and the methods and the names of an `eval` statement. The ledger compares the text of
# an item, so it does not see an item whose text stays and whose result
# changes, because a function that the macro, the initializer, the generator
# or the statement runs has other code.
#
# The replay does such an evaluation again and compares the two results:
#   - a *candidate* is an item with a result that tracked code can change
#     (`rc_candidates`);
#   - the *print* of a result is a number that two results of the same
#     structure share (`rc_print`); it reads the fields of a value and calls
#     no method of the program;
#   - the *trial* takes the print of each candidate, applies the changes of
#     the edit, and takes the print of each candidate again at its place in
#     the load order (`rc_trial!`). A candidate whose print differs is
#     evaluated at once, as a change, so the candidates after it see its new
#     result. A whole build gives an item the code that it loads before the
#     item, and the trial gives it the same.
# The trial runs in a fork of the process (`rc_in_fork`). It writes the items
# that differ, and the process applies the edit with those items among its
# changes (`rc_replay!`). Nothing that the trial evaluates stays in the
# process: no second effect of an initializer, no type of a closure, no
# compiled code.
#
# An item that the edit moves has one more result that its text does not show:
# a macro can put the place of its call into its expansion, as a log macro does
# with the line. The trial compares the expansion of each moved item that holds
# a macro call at its place of before and at its place of now
# (`rc_moved_difference`), and an item that differs is a change of the edit.
#
# The replay runs in a world that holds the whole program, and a whole build
# evaluates an item in a world that holds the items before it. Both prints of
# a candidate see the same world, so the difference shows only when an edit
# changes a method that is more specific than the one that the item called
# when it was loaded.
#
# The apply has the same limit: it evaluates an item again in a process that
# holds the whole program, and a live process can not give the item the state
# of its place in the load order. So the items that the apply evaluates again
# with the text of before have a check (`rc_again_check!`): each one is
# evaluated in a second fork, in the state of before the changes, and the
# methods that it defines there must be the methods that the program holds for
# it. An item that fails reads something that the apply can not give it again:
# a definition that comes after it, a counter, the time. The apply refuses,
# and a whole build evaluates the item at its place.
#
# An item whose text the edit changes has no result of before for its text of
# now. Its text of before has one, so the check takes that text too: when the
# text of before does not define again what the program holds for it, the item
# reads what the apply can not give it, and its edit is refused.
#
# The text of now of such an item, and the text of a new item, have a check of
# their own at the end of the trial (`rc_order_check!`). The fork takes the
# result of the item in the whole program, then takes out of the program each
# method that an item after it in the load order defined, and each name that a
# later `const`, `global` or type gives its module, and takes the result again.
# A whole build gives the item the second program, so an item whose two
# results differ is a refusal. The check takes no value out that a later
# statement wrote: a read of such a value is not found.

# ── the print of a result ───────────────────────────────────────────────────

# The number of each object that a print names by its identity: a type name, a
# module, a method. Two types of the same name are two objects after a
# redefinition, and their names have the same hash, so the number comes from
# this table and not from `objectid`.
const RC_IDENTITIES = IdDict{Any, Int}()
rc_identity(@nospecialize(x)) = get!(() -> length(RC_IDENTITIES) + 1, RC_IDENTITIES, x)::Int

# The print of each type that has no free variable and that no evaluation of
# the replay made, and the print of each name.
const RC_TYPE_PRINTS = IdDict{Any, UInt}()
const RC_NAME_PRINTS = Dict{Symbol, UInt}()

const RC_SEED_NAME = 0x6e616d65 % UInt
const RC_SEED_STRING = 0x73747269 % UInt
const RC_SEED_LINE = 0x6c696e65 % UInt
const RC_SEED_REFERENCE = 0x72656665 % UInt
const RC_SEED_IDENTITY = 0x6964656e % UInt
const RC_SEED_SEEN = 0x7365656e % UInt
const RC_SEED_UNDEFINED = 0x756e6465 % UInt
const RC_SEED_TYPE = 0x74797065 % UInt
const RC_SEED_DEFINED = 0x64656669 % UInt
const RC_SEED_UNION = 0x756e696f % UInt
const RC_SEED_BOTTOM = 0x626f7474 % UInt
const RC_SEED_ERROR = 0x6572726f % UInt
const RC_SEED_LIMIT = 0x6c696d69 % UInt

# The most objects that one print reads. A larger result has the print of the
# limit, so it compares equal, and the trial names it in its report.
const RC_PRINT_LIMIT = 4_000_000

struct RcPrintLimit <: Exception end

# One walk of a result.
#   seen       - the mutable objects of the walk, numbered in the order of the
#                first visit: a cycle ends, and a shared part prints as shared
#   defined    - the methods that the evaluation of the result defined, by the
#                name of the type that they belong to
#   variables  - the type variables of the `where` clauses that the walk is
#                inside, the innermost last
#   count      - the objects that the walk read
mutable struct RcPrinter
    seen::IdDict{Any, Int}
    defined::IdDict{Any, Vector{Method}}
    variables::Vector{TypeVar}
    count::Int
end
RcPrinter() = RcPrinter(IdDict{Any, Int}(), IdDict{Any, Vector{Method}}(), TypeVar[], 0)

# A printer for a result whose evaluation defined `methods`: the functions of
# a top-level `->`, of a `do` block and of a comprehension.
function RcPrinter(methods::Vector{Method})
    printer = RcPrinter()
    for method in methods
        self = Base.unwrap_unionall(Base.unwrap_unionall(method.sig).parameters[1])
        self isa DataType && push!(get!(printer.defined, self.name, Method[]), method)
    end
    return printer
end

# The print of a name. A name that Julia generates holds a counter, which
# differs between two evaluations: `##x#281`, `#12#x`, `#5#6`. Its print leaves
# the digits out.
function rc_name_print(name::Symbol)
    return get!(RC_NAME_PRINTS, name) do
        text = String(name)
        hash('#' in text ? filter(!isdigit, text) : text, RC_SEED_NAME)
    end
end

const RcPlainNumber = Union{Bool, Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128,
                            Float16, Float32, Float64, Char}

function rc_plain_print(values::Union{Array{T}, Memory{T}}, print::UInt) where {T}
    for index in eachindex(values)
        print = hash(@inbounds(values[index]), print)
    end
    return print
end

# The print of `x`: equal for two values of the same structure. The walk reads
# fields, elements and the pairs of a `Dict`, and calls no method of the
# program, so it runs in any world. What counts as the same:
#   - a type, a module and a method are the same object; a type that the
#     evaluation itself made counts by the code of its methods;
#   - a line number is no difference, because the lines of an item move with
#     an edit above it;
#   - a pointer, a task, a weak reference, a file stream and a lock count by
#     their type only: a lock of Base has a field that it never sets.
function rc_print(printer::RcPrinter, @nospecialize(x))::UInt
    (printer.count += 1) > RC_PRINT_LIMIT && throw(RcPrintLimit())
    x isa Symbol && return rc_name_print(x)
    x isa String && return hash(x, RC_SEED_STRING)
    x isa LineNumberNode && return RC_SEED_LINE
    x isa Type && return rc_type_print(printer, x)
    if x isa TypeVar
        # A variable of a `where` clause around it counts by the depth of the
        # clause, so two types that differ in the names of their variables
        # only have one print.
        index = findlast(variable -> variable === x, printer.variables)
        index === nothing || return hash(length(printer.variables) - index, RC_SEED_SEEN)
        return hash(rc_print(printer, x.ub), hash(rc_print(printer, x.lb), rc_name_print(x.name)))
    end
    x isa GlobalRef && return hash(rc_name_print(x.name), hash(rc_identity(x.mod), RC_SEED_REFERENCE))
    if x isa Module || x isa Method || x isa Core.MethodInstance || x isa Core.CodeInstance ||
       x isa Core.TypeName || x isa Core.Binding
        return hash(rc_identity(x), RC_SEED_IDENTITY)
    end
    type_print = rc_type_print(printer, typeof(x))
    (x isa BigInt || x isa BigFloat) && return hash(x, type_print)
    (x isa Ptr || x isa Task || x isa WeakRef || x isa IOStream || x isa Base.AbstractLock) && return type_print
    if ismutable(x)
        number = get(printer.seen, x, 0)
        number > 0 && return hash(number, RC_SEED_SEEN)
        printer.seen[x] = length(printer.seen) + 1
    end
    if x isa Dict || x isa IdDict
        # The order of the pairs follows the hash of the keys, which can be
        # an address: the sum does not depend on the order.
        sum = UInt(0)
        for (key, value) in x
            sum += hash(rc_print(printer, value), rc_print(printer, key))
        end
        return hash(sum, hash(length(x), type_print))
    elseif x isa Array || x isa Memory
        print = hash(size(x), type_print)
        if x isa Array{<:RcPlainNumber} || x isa Memory{<:RcPlainNumber}
            printer.count += length(x)
            return rc_plain_print(x, print)
        end
        for index in eachindex(x)
            print = hash(isassigned(x, index) ? rc_print(printer, x[index]) : RC_SEED_UNDEFINED, print)
        end
        return print
    elseif x isa Core.SimpleVector
        print = hash(length(x), type_print)
        for index in 1:length(x)
            print = hash(isassigned(x, index) ? rc_print(printer, x[index]) : RC_SEED_UNDEFINED, print)
        end
        return print
    end
    count = nfields(x)
    # A value with no field is a number of a primitive type, or the one value
    # of its type, whose `objectid` is the hash of the name of the type.
    count == 0 && return isbits(x) && sizeof(x) > 0 ? hash(objectid(x), type_print) : type_print
    type = typeof(x)
    print = type_print
    for index in 1:count
        if !isdefined(x, index)
            print = hash(RC_SEED_UNDEFINED, print)
        elseif Base.isfieldatomic(type, index)
            print = hash(rc_print(printer, getfield(x, index, :sequentially_consistent)), print)
        else
            print = hash(rc_print(printer, getfield(x, index)), print)
        end
    end
    return print
end

# The print of a type: the identity of its name and the prints of its
# parameters. The table `RC_TYPE_PRINTS` keeps the print of a type with no free
# variable, for a walk whose evaluation defined no method: the print of such a
# type depends on nothing else.
function rc_type_print(printer::RcPrinter, @nospecialize(type))::UInt
    if type isa DataType
        cache = isempty(printer.defined)
        if cache
            cached = get(RC_TYPE_PRINTS, type, nothing)
            cached === nothing || return cached::UInt
        end
        methods = get(printer.defined, type.name, nothing)
        print = methods === nothing ? hash(rc_identity(type.name), RC_SEED_TYPE) :
                rc_defined_print(printer, type.name, methods)
        for parameter in type.parameters
            print = hash(rc_print(printer, parameter), print)
        end
        cache && !Base.has_free_typevars(type) && (RC_TYPE_PRINTS[type] = print)
        return print
    elseif type isa UnionAll
        variable = type.var
        bounds = hash(rc_print(printer, variable.ub), rc_print(printer, variable.lb))
        push!(printer.variables, variable)
        body = rc_print(printer, type.body)
        pop!(printer.variables)
        return hash(body, bounds)
    elseif type isa Union
        sum = UInt(0)
        for part in Base.uniontypes(type)
            sum += rc_print(printer, part)
        end
        return hash(sum, RC_SEED_UNION)
    end
    return RC_SEED_BOTTOM
end

# The print of a type on which the evaluation of the result defined methods:
# its name, and the signature and the code of each of those methods. Each
# evaluation of a top-level `->` makes a new type, and two such types of the
# same code are the same result.
function rc_defined_print(printer::RcPrinter, name::Core.TypeName, methods::Vector{Method})
    number = get(printer.seen, name, 0)
    number > 0 && return hash(number, RC_SEED_SEEN)
    printer.seen[name] = length(printer.seen) + 1
    print = hash(rc_name_print(name.name), RC_SEED_DEFINED)
    for method in methods
        code = Base.uncompressed_ir(method).code
        print = hash(rc_print(printer, code), hash(rc_print(printer, method.sig), print))
    end
    return print
end

# ── the candidates ──────────────────────────────────────────────────────────

# One item with a result that the replay compares.
#   index        - of the item in the ledger
#   expands      - the item calls a tracked macro
#   initializer  - the expression that gives the binding of the item its
#                  value, when it runs code and names a tracked name; else
#                  `nothing`
#   generated    - the item is a `@generated` method
#   statement    - the item is a statement that defines through `eval`
struct RcCandidate
    index::Int
    item::RcItem
    expands::Bool
    initializer::Any
    generated::Bool
    statement::Bool
end

const RC_NAMED_KINDS = (:method, :other, :type, :const, :global, :module)
const RC_CANDIDATE_KINDS = (:method, :macro, :other, :type, :const, :global)

# The candidates of the ledger `items`, in the load order. The macros and the
# names are tracked by their name alone, with no module: a candidate with no
# need costs its print, and never a wrong result.
function rc_candidates(items::Vector{RcItem}, order::RcLoadOrder)
    macros = Set{Symbol}()
    names = Set{Symbol}()
    for item in items
        item.name === nothing && continue
        if item.kind === :macro
            push!(macros, item.name)
        elseif item.kind in RC_NAMED_KINDS
            push!(names, item.name)
        end
    end
    candidates = RcCandidate[]
    for (index, item) in enumerate(items)
        item.kind in RC_CANDIDATE_KINDS || continue
        e = item.entry.expr
        heads = ReactiveSourceDiff.macro_heads(e)
        expands = !isdisjoint(heads, macros)
        initializer = item.kind in RC_BINDING_KINDS ? ReactiveSourceDiff.initializer(e) : nothing
        if initializer !== nothing
            ReactiveSourceDiff.runs_code(initializer) &&
                !isdisjoint(ReactiveSourceDiff.all_names(initializer), names) || (initializer = nothing)
        end
        generated = item.kind === :method && Symbol("@generated") in heads
        statement = item.kind === :other && (Symbol("@eval") in heads || :eval in ReactiveSourceDiff.all_names(e))
        expands || initializer !== nothing || generated || statement || continue
        push!(candidates, RcCandidate(index, item, expands, initializer, generated, statement))
    end
    sort!(candidates; by = candidate -> rc_order(order, candidate.item))
    return candidates
end

# The expression with each line counted from `start`, the first line of its
# item. A macro can put the line of its call into its expansion, and the line
# of an item moves with an edit above it.
rc_relative_lines(@nospecialize(x), start::Int) = x
rc_relative_lines(node::LineNumberNode, start::Int) = LineNumberNode(node.line - start + 1, node.file)
function rc_relative_lines(e::Expr, start::Int)
    relative = Expr(e.head)
    for argument in e.args
        push!(relative.args, rc_relative_lines(argument, start))
    end
    return relative
end

# The methods that an evaluation of the trial defined: the filter of
# `jl_method_def` records each one.
const RC_DEFINED = Method[]
rc_record_method(method::Method) = (push!(RC_DEFINED, method); false)

# The filter of an `eval` statement of the trial: each method is recorded, and
# a method of the same code is kept, as in the apply, so a statement that
# defines what the table holds changes nothing.
rc_record_and_keep_method(method::Method) = (push!(RC_DEFINED, method); rc_method_filter(method))

# Print the result of `evaluate`, a function of a printer. An evaluation that
# throws has the print of the type of its exception: an item that threw before
# the edit and throws after it has the same result. `problems` gets a line for
# a result that passes the limit of a print.
function rc_guarded_print(evaluate, printer::RcPrinter, problems::Vector{String}, what::String)
    try
        return evaluate(printer)::UInt
    catch e
        e isa RcPrintLimit || return hash(rc_identity(typeof(e)), RC_SEED_ERROR)
        push!(problems, string(what, " is too large to compare"))
        return RC_SEED_LIMIT
    end
end

# The prints of the candidate in the module `mod`: of the expansion of its
# expression, and of the value of its initializer or of the definitions of its
# statement. The evaluation runs under a filter that records its methods;
# `filter` is the filter of the trial, which is installed again after it. The
# print of the definitions of a statement leaves out the names of `left_out`.
function rc_candidate_prints(candidate::RcCandidate, mod::Module, filter, problems::Vector{String};
                             left_out::Set{Symbol} = Set{Symbol}())
    item = candidate.item
    what = string(rc_where(item), " ", rc_what(item))
    expansion = UInt(0)
    if candidate.expands
        expansion = rc_guarded_print(RcPrinter(), problems, what) do printer
            relative = rc_relative_lines(item.entry.expr, item.entry.lines.start)
            rc_print(printer, rc_with_fresh_log_ids(() -> Base.invokelatest(macroexpand, mod, relative)))
        end
    end
    result = UInt(0)
    if candidate.initializer !== nothing
        value = rc_recorded_evaluation(mod, item, candidate.initializer, rc_record_method, filter)
        result = value isa Some ? rc_guarded_print(printer -> rc_print(printer, something(value)),
                                                   RcPrinter(copy(RC_DEFINED)), problems, what) :
                 hash(rc_identity(typeof(value)), RC_SEED_ERROR)
    elseif candidate.statement
        value = rc_recorded_evaluation(mod, item, item.entry.expr, rc_record_and_keep_method, filter)
        rc_take_kept!()
        result = value isa Some ? rc_guarded_print(printer -> rc_definitions_print(printer, mod, copy(RC_DEFINED), left_out),
                                                   RcPrinter(copy(RC_DEFINED)), problems, what) :
                 hash(rc_identity(typeof(value)), RC_SEED_ERROR)
    end
    return (expansion, result)
end

# Evaluate `e`, the expression of the item or its initializer, in `mod` under
# the filter `record`, which fills `RC_DEFINED`, and install `filter` again.
# The evaluation has the place of the item, as that of the apply has: a method
# that it defines, or that the filter keeps for it, has the item as its definer.
# Answer the value in a `Some`, or the exception of an evaluation that throws.
function rc_recorded_evaluation(mod::Module, item::RcItem, e, record, filter)
    empty!(RC_DEFINED)
    rc_install_filter(record)
    try
        return Some{Any}(rc_with_fresh_log_ids(() -> rc_evaluate_at(mod, item, e)))
    catch exception
        return exception
    finally
        rc_install_filter(filter)
    end
end

# The print of what a statement defined in `mod`: its methods, the names that
# the module exports, and the names that it binds, except the names of
# `left_out`. A name that Julia generates is left out: each evaluation of a
# top-level `->` binds a new one.
function rc_definitions_print(printer::RcPrinter, mod::Module, methods::Vector{Method},
                              left_out::Set{Symbol} = Set{Symbol}())
    print = RC_SEED_DEFINED
    for method in methods
        print = hash(rc_print(printer, method.sig), print)
    end
    for name in Base.invokelatest(names, mod)
        name in left_out || (print = hash(rc_name_print(name), print))
    end
    for name in Base.invokelatest(names, mod; all = true)
        '#' in String(name) || name in left_out || (print = hash(rc_name_print(name), print))
    end
    return print
end

# ── the moved expressions ───────────────────────────────────────────────────

# Whether the moved expression expands to other code at its place of now than
# at its place of before the edit. A line number node prints the same at each
# line, so the two prints differ when a macro put the line or the file of its
# call into the expansion as a value: a log macro, `@__LINE__`.
function rc_moved_difference(moved::RcMoved, evaluation::RcEvaluation, problems::Vector{String})
    item = moved.item
    mod = rc_module_or_nothing(rc_module_path(evaluation.roots, item))
    mod === nothing && return false
    what = string(rc_where(item), " ", rc_what(item))
    before = rc_expansion_print(mod, moved.old, problems, what)
    return rc_expansion_print(mod, item.entry.expr, problems, what) != before
end

# The print of the expansion of `e` in `mod`, with no docstring.
function rc_expansion_print(mod::Module, e, problems::Vector{String}, what::String)
    return rc_guarded_print(RcPrinter(), problems, what) do printer
        stripped = ReactiveSourceDiff.without_docstrings(e)
        rc_print(printer, rc_with_fresh_log_ids(() -> Base.invokelatest(macroexpand, mod, stripped)))
    end
end

# ── the trial ───────────────────────────────────────────────────────────────

# How the result of a candidate differs, or `nothing`. `before` holds the
# prints of the candidate of before the changes.
#   'e'  the expansion gives other code
#   'v'  the initializer gives another value
#   's'  the statement defines a method of other code, or binds or exports
#        another name; the trial keeps what the statement did
#   'g'  a generator runs in the world of its method, so a method that a
#        change made is new to it
# The trial names one more, for a moved expression (`rc_moved_difference`):
#   'l'  the expansion holds the place of the expression
function rc_candidate_difference(candidate::RcCandidate, before::Dict{Int, Tuple{UInt, UInt}},
                                 evaluation::RcEvaluation, problems::Vector{String})
    item = candidate.item
    mod = Base.invokelatest(rc_module_or_nothing, rc_module_path(evaluation.roots, item))
    mod === nothing && return nothing
    old = get(before, candidate.index, nothing)
    if old !== nothing
        now = rc_candidate_prints(candidate, mod, rc_method_filter, problems)
        if now != old
            # A result that differs between two evaluations of the same world is
            # no result of the edit: a counter, a clock, a random number.
            if rc_candidate_prints(candidate, mod, rc_method_filter, problems) != now
                push!(problems, string(rc_where(item), " ", rc_what(item),
                                       " gives another result at each evaluation; it stays as it is"))
                return nothing
            end
            return now[1] != old[1] ? 'e' : candidate.statement ? 's' : 'v'
        end
    end
    return candidate.generated ? 'g' : nothing
end

# The prints of the values of the tracked globals, by the index of the item
# that defines each one.
function rc_global_prints(evaluation::RcEvaluation)
    prints = Dict{Int, UInt}()
    problems = String[]
    for (index, item) in enumerate(evaluation.items)
        item.kind in RC_BINDING_KINDS && item.name !== nothing || continue
        mod = Base.invokelatest(rc_module_or_nothing, rc_module_path(evaluation.roots, item))
        mod === nothing && continue
        Base.invokelatest(isdefined, mod, item.name) || continue
        value = Base.invokelatest(getglobal, mod, item.name)
        prints[index] = rc_guarded_print(printer -> rc_print(printer, value), RcPrinter(), problems, "")
    end
    return prints
end

# The check of the statement group of an apply (D3), before the changes: the
# definitions of the group are evaluated again with the statements of before
# the edit, as the apply does it with the statements of the edit, and each
# tracked global must have the value that it had. Then the definitions and the
# statements that name the globals make their state, and the apply can make it
# again. Answer `nothing`, or the refusal: a global that gets another value has
# a writer that the rebuild does not find.
function rc_check_statement_group(evaluation::RcEvaluation)
    group = evaluation.group::RcStatementGroup
    before = rc_global_prints(evaluation)
    items = RcItem[item for item in evaluation.items if !any(statement -> statement === item, group.new)]
    append!(items, group.old)
    queue = RcQueue(evaluation.queue.order)
    check = RcEvaluation(items, evaluation.roots, evaluation.tracked, queue, RcChange[], String[], nothing, RcMoved[],
                         RcNameRemoval[])
    for definition in group.definitions
        rc_enqueue!(queue, RcChange("S1", definition, ""))
    end
    rc_install_filter(rc_method_filter)
    try
        while queue.cursor < length(queue.changes)
            rc_evaluate_next!(check) || return first(check.refusals)
        end
    catch e
        statement = first(group.old)
        return string("S1 ", rc_where(statement), " ", rc_what(statement),
                      ": the statements of before the edit can not run again: ", first(split(sprint(showerror, e), '\n')))
    finally
        rc_install_filter(nothing)
        rc_take_kept!()
    end
    after = rc_global_prints(evaluation)
    for index in sort!(collect(keys(before)))
        get(after, index, before[index]) == before[index] && continue
        item = evaluation.items[index]
        return string("S1 ", rc_where(item), " ", rc_what(item),
                      ": its value does not come back when the definitions and the statements of the changed group are evaluated again")
    end
    return nothing
end

# The trial of an apply: write to `report` a line `differs <index> <how>` for
# each moved item whose expansion holds its place, and for each candidate whose
# result the changes of `evaluation` change. The trial evaluates the changes of
# the queue as the apply does, and each item that differs, so it runs in a fork
# and never in the process that writes an image.
#
# A candidate has a print of before the changes when a change comes before it
# in the load order, or the apply removes a method: no other candidate can
# differ. A line `problem <text>` names a candidate that the trial can not
# compare, and a line `stopped <text>` the error or the refusal that ends the
# trial early; the apply of the process meets the same one. A line
# `refuse <text>` is the refusal of the check of the statement group, which
# the apply of the process takes as its own. A line `again <index> <id>` names
# a change that evaluates an item with the text of before; the process checks
# each one in a second fork (`rc_again_check!`), with the text of before of
# each item that the edit changes. A line `early <index> <id>` names an item
# with a text of the edit whose result differs in a program with nothing after
# it (`rc_order_check!`). The trial starts with an empty
# storage of the task, and its part after the changes with another empty one.
function rc_trial!(report::IO, evaluation::RcEvaluation, candidates::Vector{RcCandidate})
    return rc_with_empty_task_storage() do
        rc_with_fresh_log_ids(() -> rc_trial_parts!(report, evaluation, candidates))
    end
end

function rc_trial_parts!(report::IO, evaluation::RcEvaluation, candidates::Vector{RcCandidate})
    queue = evaluation.queue
    order = queue.order
    problems = String[]
    if evaluation.group !== nothing
        refusal = rc_check_statement_group(evaluation)
        if refusal !== nothing
            println(report, "refuse ", refusal)
            return nothing
        end
    end
    # A moved expression whose expansion holds its place is a change of the
    # edit, in the queue before the first change is looked for.
    differs = 0
    for moved in evaluation.moved
        objectid(moved.item) in queue.queued && continue
        rc_moved_difference(moved, evaluation, problems) || continue
        differs += 1
        println(report, "differs ", findfirst(item -> item === moved.item, evaluation.items), " l")
        rc_enqueue!(queue, rc_replay_change(moved.item, 'l'))
    end
    before = Dict{Int, Tuple{UInt, UInt}}()
    active = Set{Int}()
    first_change = isempty(queue.changes) ? nothing : minimum(change -> rc_order(order, change.item), queue.changes)
    for candidate in candidates
        isempty(evaluation.removals) && isempty(evaluation.names) &&
            (first_change === nothing || rc_order(order, candidate.item) < first_change) && continue
        objectid(candidate.item) in queue.queued || push!(active, candidate.index)
    end
    t_before = @elapsed begin
        # A statement can do more in the whole program than it did when its
        # package was loaded: a loop that exports the names of a module finds
        # the names of the files after it. Each statement runs once before the
        # prints, so the prints of before hold what the statements do here.
        for candidate in candidates
            candidate.statement && candidate.index in active || continue
            mod = rc_module_or_nothing(rc_module_path(evaluation.roots, candidate.item))
            mod === nothing && continue
            rc_recorded_evaluation(mod, candidate.item, candidate.item.entry.expr, rc_record_and_keep_method, nothing)
            rc_take_kept!()
        end
        for candidate in candidates
            candidate.index in active || continue
            candidate.expands || candidate.initializer !== nothing || candidate.statement || continue
            mod = rc_module_or_nothing(rc_module_path(evaluation.roots, candidate.item))
            mod === nothing && continue
            before[candidate.index] = rc_candidate_prints(candidate, mod, nothing, problems)
        end
    end
    next = 1
    indices = IdDict{RcItem, Int}(item => index for (index, item) in enumerate(evaluation.items))
    # The part before this line evaluated the code of before the changes, and
    # the part after it evaluates the code of after them: the storage of the
    # task and the registry of the log ids are empty again, as they are for the
    # apply (`rc_with_empty_task_storage`, `rc_with_fresh_log_ids`).
    current_task().storage = nothing
    empty!(Base.CoreLogging._log_record_ids)
    stopped = false
    t_trial = @elapsed try
        rc_delete_removals!(evaluation)
        rc_install_filter(rc_method_filter)
        while true
            change = queue.cursor < length(queue.changes) ? queue.changes[queue.cursor + 1] : nothing
            candidate = next <= length(candidates) ? candidates[next] : nothing
            change === nothing && candidate === nothing && break
            if candidate !== nothing &&
               (change === nothing || rc_order(order, candidate.item) < rc_order(order, change.item))
                next += 1
                candidate.index in active || continue
                objectid(candidate.item) in queue.queued && continue
                how = rc_candidate_difference(candidate, before, evaluation, problems)
                how === nothing && continue
                differs += 1
                println(report, "differs ", candidate.index, " ", how)
                how == 's' || rc_enqueue!(queue, rc_replay_change(candidate.item, how))
            else
                rc_is_evaluated_again(evaluation, change) && haskey(indices, change.item) &&
                    println(report, "again ", indices[change.item], " ", change.id)
                if !rc_evaluate_next!(evaluation)
                    println(report, "stopped ", first(evaluation.refusals))
                    stopped = true
                    break
                end
            end
        end
    catch e
        println(report, "stopped ", first(split(sprint(showerror, e), '\n')))
        stopped = true
    finally
        rc_install_filter(nothing)
    end
    stopped || rc_order_check!(report, evaluation, candidates, problems)
    for problem in unique!(problems)
        println(report, "problem ", problem)
    end
    println(report, "done ", length(candidates), " ", length(active), " ", differs, " ",
            round(t_before; digits = 2), " ", round(t_trial; digits = 2), " ", length(evaluation.moved))
    return nothing
end

# ── the text of the edit at its place in the load order ─────────────────────

# The candidates that a change of the queue evaluates with a text of the edit
# or at a new place of the load order, with the id of the change: an item that
# the edit changes, a new one, or one that moved (H4). A
# generated method has no result at its evaluation, because its generator runs
# at a call.
function rc_edited_candidates(evaluation::RcEvaluation, candidates::Vector{RcCandidate})
    ids = IdDict{RcItem, String}()
    for change in evaluation.queue.changes
        change.item === nothing && continue
        rc_is_evaluated_again(evaluation, change) || (ids[change.item] = change.id)
    end
    return Tuple{RcCandidate, String}[(candidate, ids[candidate.item]) for candidate in candidates
                                      if haskey(ids, candidate.item) &&
                                         (candidate.expands || candidate.initializer !== nothing || candidate.statement)]
end

# The kinds of the items whose name the check of the load order takes out.
const RC_HIDDEN_KINDS = (:const, :global, :type)

# The first place in the load order of each name that an item of a kind of
# `RC_HIDDEN_KINDS` gives its module, by the path of the module and the name.
rc_first_places(evaluation::RcEvaluation) = rc_first_places(evaluation.items, evaluation.roots, evaluation.queue.order)
function rc_first_places(items::Vector{RcItem}, roots::Vector{Vector{Symbol}}, order::RcLoadOrder)
    first = Dict{Tuple{Vector{Symbol}, Symbol}, Tuple{Vararg{Int}}}()
    for item in items
        item.kind in RC_HIDDEN_KINDS && item.name !== nothing || continue
        key = (rc_module_path(roots, item), item.name::Symbol)
        place = rc_order(order, item)
        haskey(first, key) && first[key] <= place || (first[key] = place)
    end
    return first
end

# Take out of the program each method that an item after `place` in the load
# order defined, and each name that such an item gives its module when no item
# at or before `place` gives it (`first_places`). A name leaves as the name of
# an expression that left does: the module is then as one that never bound
# the name. The methods leave together, and the names of one module leave
# together (`jl_reactive_bindings_hide`), with one pass over the methods of the
# module that invalidates the code that names them (`rc_invalidate_named!`).
# `hidden` and `hidden_names` hold what is out; a method that the table holds
# no more stays as it is.
function rc_hide_after!(evaluation::RcEvaluation, place, hidden::Base.IdSet{Method},
                        first_places::Dict{Tuple{Vector{Symbol}, Symbol}, Tuple{Vararg{Int}}},
                        hidden_names::Set{Tuple{Vector{Symbol}, Symbol}})
    order = evaluation.queue.order
    leaving = Dict{Vector{Symbol}, Vector{Any}}()
    disabled = Any[]
    for item in evaluation.items
        rc_order(order, item) > place || continue
        for method in item.methods
            method in hidden && continue
            push!(hidden, method)
            push!(disabled, method)
        end
        item.kind in RC_HIDDEN_KINDS && item.name !== nothing || continue
        key = (rc_module_path(evaluation.roots, item), item.name::Symbol)
        key in hidden_names && continue
        first_places[key] > place || continue
        push!(hidden_names, key)
        push!(get!(() -> Any[], leaving, key[1]), key[2])
    end
    # The methods leave together (`jl_reactive_methods_disable`). A runtime
    # with no such function, or a batch that disabled fewer methods than it
    # got, makes the deletion of each method, which leaves a disabled one as
    # it is.
    batch = try
        Int(ccall(:jl_reactive_methods_disable, Csize_t, (Any,), disabled))
    catch
        -1
    end
    if batch != length(disabled)
        for method in disabled
            try
                Base.delete_method(method)
            catch
            end
        end
    end
    for (path, names) in leaving
        mod = Base.invokelatest(rc_module_or_nothing, path)
        mod === nothing && continue
        own = Any[name for name in names if Base.invokelatest(Base.binding_kind, mod, name) in RC_OWN_KINDS]
        isempty(own) && continue
        try
            scanned = ccall(:jl_reactive_bindings_hide, Any, (Any, Any), mod, own)::Vector{Any}
            rc_invalidate_named!(mod, scanned, Base.get_world_counter() - 1)
        catch
            # A runtime with no batch of names takes them out one by one.
            for name in own
                ccall(:jl_reactive_binding_leave, Cint, (Any, Any), mod, name)
            end
        end
    end
    return nothing
end

# Whether the code `x` names one of the bindings `names` of the module `mod`.
rc_names_any(@nospecialize(x), mod::Module, names::Set{Symbol}) =
    x isa GlobalRef ? x.mod === mod && x.name in names :
    x isa Expr ? any(argument -> rc_names_any(argument, mod, names), x.args) :
    x isa Union{Core.ReturnNode, Core.GotoIfNot, Core.PiNode} ?
        any(i -> isdefined(x, i) && rc_names_any(getfield(x, i), mod, names), 1:nfields(x)) : false

# Invalidate the code of the methods of `mod` that names one of the bindings
# `bindings` of it, as the invalidation of each binding does it
# (`invalidate_method_for_globalref!` of the compiler), in one pass over the
# methods of the module whose code names a binding of it: each code instance
# of a method whose source names one of them, and each code instance with an
# edge to one of them.
function rc_invalidate_named!(mod::Module, bindings::Vector{Any}, world::UInt)
    isempty(bindings) && return 0
    names = Set{Symbol}(binding.globalref.name for binding in bindings)
    set = Base.IdSet{Any}(bindings)
    invalidated = 0
    for i in 1:ccall(:jl_module_scanned_methods_length, Csize_t, (Any,), mod)
        method = ccall(:jl_module_scanned_methods_getindex, Any, (Any, Csize_t), mod, i)::Method
        all = false
        if isdefined(method, :source) && method.source isa Union{Core.CodeInfo, String}
            all = any(statement -> rc_names_any(statement, mod, names), Base._uncompressed_ir(method).code)
        end
        for mi in Base.specializations(method)
            mi isa Core.MethodInstance && isdefined(mi, :cache) || continue
            ci = mi.cache
            while true
                if ci.max_world > world &&
                   (all || isdefined(ci, :edges) && any(i -> isassigned(ci.edges, i) && ci.edges[i] in set, eachindex(ci.edges)))
                    ccall(:jl_invalidate_code_instance, Cvoid, (Any, UInt), ci, world)
                    invalidated += 1
                end
                isdefined(ci, :next) || break
                ci = ci.next
            end
        end
    end
    return invalidated
end

# The check of each candidate that the apply evaluates with a text of the
# edit, at the end of the trial: write to `report` a line `early <index> <id>`
# for each one whose result in a program that holds no method and no name of
# the items after it is not its result in the whole program, and a line
# `ordered <count> <differ> <methods> <seconds> <names>` at the end, or a line
# `unordered <text>` for a check that fails. The candidates go from the last
# one to the first one, so each method leaves the program one time. A result
# that differs between two evaluations of the same program is no result of the
# load order. The check ends the trial: the fork holds a part of the program
# after it.
function rc_order_check!(report::IO, evaluation::RcEvaluation, candidates::Vector{RcCandidate},
                         problems::Vector{String})
    edited = rc_edited_candidates(evaluation, candidates)
    isempty(edited) && return nothing
    order = evaluation.queue.order
    try
        module_of(candidate) = Base.invokelatest(rc_module_or_nothing, rc_module_path(evaluation.roots, candidate.item))
        # The names that the items after a candidate give its module: the check
        # takes them out, and a whole build has none of them at the place of the
        # candidate, so the print of a statement leaves them out in both
        # programs.
        first_places = rc_first_places(evaluation)
        later_names(candidate) = (path = rc_module_path(evaluation.roots, candidate.item);
                                  place = rc_order(order, candidate.item);
                                  Set{Symbol}(key[2] for (key, first) in first_places if key[1] == path && first > place))
        whole = Dict{Int, Tuple{UInt, UInt}}()
        left_out = Dict{Int, Set{Symbol}}()
        for (candidate, _) in edited
            mod = module_of(candidate)
            mod === nothing && continue
            left_out[candidate.index] = candidate.statement ? later_names(candidate) : Set{Symbol}()
            whole[candidate.index] = rc_candidate_prints(candidate, mod, nothing, problems;
                                                         left_out = left_out[candidate.index])
        end
        hidden = Base.IdSet{Method}()
        hidden_names = Set{Tuple{Vector{Symbol}, Symbol}}()
        differ = 0
        seconds = @elapsed for (candidate, id) in Iterators.reverse(edited)
            haskey(whole, candidate.index) || continue
            mod = module_of(candidate)
            rc_hide_after!(evaluation, rc_order(order, candidate.item), hidden, first_places, hidden_names)
            alone = rc_candidate_prints(candidate, mod, nothing, problems; left_out = left_out[candidate.index])
            alone == whole[candidate.index] && continue
            rc_candidate_prints(candidate, mod, nothing, problems; left_out = left_out[candidate.index]) == alone || continue
            differ += 1
            println(report, "early ", candidate.index, " ", id)
        end
        println(report, "ordered ", length(edited), " ", differ, " ", length(hidden), " ", round(seconds; digits = 2), " ",
                length(hidden_names))
    catch e
        println(report, "unordered ", first(split(sprint(showerror, e), '\n')))
    end
    return nothing
end

# Whether the change evaluates an item with the text of before at its place of
# before: a dependent, a candidate whose result differs, a moved expression.
# Its old item is the item itself. A `using`, an `export`, an `include` and the
# header of a module define no method. An item that comes at another place of
# the load order (H4, `order_moved`) is not at its place of before, whatever
# change evaluates it, so the check of the load order takes it, as it takes a
# text of the edit (`rc_edited_candidates`).
const RC_AGAIN_KINDS = (:method, :macro, :other, :type, :const, :global)
rc_is_evaluated_again(evaluation::RcEvaluation, change::RcChange) =
    change.item !== nothing && !(change.item in evaluation.order_moved) && change.item.kind in RC_AGAIN_KINDS &&
    length(change.old_items) == 1 && change.old_items[1] === change.item

# The print of the methods of one evaluation: the same for two evaluations
# that define methods of the same signatures and the same code. A type on
# which these methods are defined counts by their code (`RcPrinter`), so a
# function with no name has the same print at each evaluation. The methods are
# put in the order of the text of their signatures, with the counters of the
# generated names left out, so the order of their definition is no difference,
# and each method has a walk of its own.
function rc_methods_print(methods::Vector{Method}, problems::Vector{String}, what::String)
    sorted = sort(methods; by = method -> replace(Base.invokelatest(string, method.sig), r"#+s?\d+" => "#"))
    sum = UInt(0)
    for method in sorted
        sum += rc_guarded_print(RcPrinter(sorted), problems, what) do printer
            code = isdefined(method, :source) ? Base.uncompressed_ir(method).code : nothing
            hash(rc_print(printer, code), rc_print(printer, method.sig))
        end
    end
    return hash(length(sorted), sum)
end

# One expression of before the edit that the check evaluates again
# (`rc_again_check!`).
#   item    - holds the expression, its place, and the methods that the
#             program holds for it
#   home    - an item of the edited sources in the same module; a refusal
#             names the expression by it
#   id      - of the change
#   edited  - the edit changes the text of the item, so the apply evaluates
#             the text of now and never this one
struct RcAgain
    item::RcItem
    home::RcItem
    id::String
    edited::Bool
end

# The text of before of each item that a change of the queue replaces with
# another text, when the program holds methods for it: the methods are what
# the check compares.
function rc_edited_checks(evaluation::RcEvaluation)
    checks = RcAgain[]
    seen = Base.IdSet{RcItem}()
    for change in evaluation.queue.changes
        home = change.item
        home === nothing && continue
        for old in change.old_items
            old === home && continue
            old.kind in RC_AGAIN_KINDS && !isempty(old.methods) || continue
            old in seen && continue
            push!(seen, old)
            push!(checks, RcAgain(old, home, change.id, true))
        end
    end
    return checks
end

# The check of the expressions of before the edit, in the state of before the
# changes: write to `report` a line `unlike <position> methods` for each one
# that does not define the methods that the program holds for it, a line
# `unlike <position> throws <exception>` for each one that throws, and a line
# `checked <count> <unlike> <seconds>` at the end. `checks` is in the load
# order, and a position counts in it. A moved item is evaluated with its
# expression of before, which holds its lines of before. An item after one
# that differs can differ because of it: the evaluation of the first one stays
# in this fork.
function rc_again_check!(report::IO, evaluation::RcEvaluation, checks::Vector{RcAgain})
    problems = String[]
    moved = IdDict{RcItem, Any}(move.item => move.old for move in evaluation.moved)
    unlike = 0
    seconds = @elapsed for (position, check) in enumerate(checks)
        item = check.item
        mod = Base.invokelatest(rc_module_or_nothing, rc_module_path(evaluation.roots, check.home))
        mod === nothing && continue
        what = string(rc_where(item), " ", rc_what(item))
        held = rc_methods_print(item.methods, problems, what)
        value = rc_recorded_evaluation(mod, item, get(moved, item, item.entry.expr), rc_record_and_keep_method, nothing)
        rc_take_kept!()
        if !(value isa Some)
            unlike += 1
            println(report, "unlike ", position, " throws ", nameof(typeof(value)))
        elseif rc_methods_print(copy(RC_DEFINED), problems, what) != held
            unlike += 1
            println(report, "unlike ", position, " methods")
        end
    end
    for problem in unique!(problems)
        println(report, "problem ", problem)
    end
    println(report, "checked ", length(checks), " ", unlike, " ", round(seconds; digits = 2))
    return nothing
end

# Why the check refuses the expression: `how` is what the check wrote for it.
function rc_again_refusal(check::RcAgain, how::AbstractString)
    throws = startswith(how, "throws ")
    if check.edited
        throws && return string("its expression of before the edit ", how, " when the program of before the edit ",
                                "evaluates it again, so no check tells what the edited expression reads")
        return string("its expression of before the edit, evaluated again in the program of before the edit, ",
                      "defines other methods than the program holds for it, so its evaluation reads what comes after it")
    end
    throws && return string("its evaluation ", how, " in the program of before the edit")
    return "its evaluation in the program of before the edit defines other methods than the program holds for it"
end

# Run the check of the expressions of before the edit in a fork, and add a
# refusal for the first one that the check names. `again` holds the index and
# the id of the change of each item that the apply evaluates again, as the
# trial wrote them; the text of before of each item that the edit changes
# joins them (`rc_edited_checks`). What the evaluations of the check print
# goes to the file `log`. A check that ends with no answer is a refusal: the
# apply would evaluate those items with no check.
function rc_check_again!(evaluation::RcEvaluation, again::Vector{Tuple{Int, String}}, log::String)
    order = evaluation.queue.order
    checks = RcAgain[RcAgain(evaluation.items[index], evaluation.items[index], id, false)
                     for (index, id) in Dict{Int, String}(again)]
    append!(checks, rc_edited_checks(evaluation))
    isempty(checks) && return nothing
    sort!(checks; by = check -> rc_order(order, check.home))
    report = rc_in_fork(log) do io
        rc_with_empty_task_storage(() -> rc_again_check!(io, evaluation, checks))
    end
    if report === nothing
        home = first(checks).home
        push!(evaluation.refusals, string(first(checks).id, " ", rc_where(home), " ", rc_what(home),
                                          ": the check of the expressions of before the edit ended with no answer, see ",
                                          log))
        return nothing
    end
    unlike = 0
    for line in split(report, '\n'; keepempty = false)
        parts = split(line, ' '; limit = 3)
        if parts[1] == "unlike"
            # The first item in the load order is the one to name: the check
            # keeps what it evaluated, so an item after it can differ because
            # of it.
            unlike += 1
            check = checks[parse(Int, parts[2])]
            home = check.home
            if unlike == 1
                push!(evaluation.refusals, string(check.id, " ", rc_where(home), " ", rc_what(home), ": ",
                                                  rc_again_refusal(check, parts[3]),
                                                  "; only a whole build evaluates it at its place in the load order"))
            else
                println("rc: replay: after it, ", rc_where(home), " ", rc_what(home), " differs too")
            end
        elseif parts[1] == "problem"
            println("rc: replay: ", SubString(line, 9))
        elseif parts[1] == "checked"
            numbers = split(line, ' ')
            println("rc: replay: ", numbers[2], " expressions of before the edit were evaluated again in the program of ",
                    "before the edit, ", count(check -> check.edited, checks), " of them replaced by the edit; ",
                    numbers[3], " differ; ", numbers[4], " s")
        end
    end
    return nothing
end

# The change that evaluates again a candidate whose result differs.
function rc_replay_change(item::RcItem, how::Char)
    how == 'e' && return RcChange("D1", item, "expands to other code")
    how == 'v' && return RcChange(item.kind === :const ? "C1" : "C2", item, "the initializer gives another value")
    how == 'g' && return RcChange("A6", item, "the generator can run other code")
    how == 'l' && return RcChange("D1", item, "expands to other code at its new place")
    return RcChange("D2", item, "defines other methods or names")
end

# Run `produce(io)` in a fork of the process, and answer the text that it wrote
# to `io`, or `nothing` when the fork ends with no answer. What the fork prints
# goes to the file `output`: Julia keeps its own copies of the standard
# streams, so the streams of Julia are redirected, and the descriptors with
# them. The fork leaves through `_exit`, so it never comes back into the
# caller.
function rc_in_fork(produce, output::String)
    pipe = zeros(Cint, 2)
    ccall(:pipe, Cint, (Ptr{Cint},), pipe) == 0 || error("rc: pipe: ", Libc.strerror())
    flush(stdout)
    flush(stderr)
    pid = ccall((:jl_reactive_fork, "libjulia-codegen"), Cint, ())
    if pid == 0
        status = 1
        try
            ccall(:close, Cint, (Cint,), pipe[1])
            log = open(output, "w")
            redirect_stdout(log)
            redirect_stderr(log)
            try
                io = IOBuffer()
                produce(io)
                rc_write_all(pipe[2], String(take!(io)))
                status = 0
            catch e
                showerror(log, e, catch_backtrace())
            finally
                flush(log)
            end
        catch
        end
        ccall(:_exit, Cvoid, (Cint,), status)
    end
    ccall(:close, Cint, (Cint,), pipe[2])
    if pid < 0
        ccall(:close, Cint, (Cint,), pipe[1])
        return nothing
    end
    data = UInt8[]
    chunk = Vector{UInt8}(undef, 1 << 16)
    while true
        count = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), pipe[1], chunk, length(chunk))
        count < 0 && Libc.errno() == Libc.EINTR && continue
        count > 0 || break
        append!(data, view(chunk, 1:count))
    end
    ccall(:close, Cint, (Cint,), pipe[1])
    status = Ref{Cint}(0)
    ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, status, 0)
    return status[] == 0 ? String(data) : nothing
end

# Run the trial of the apply in a fork, and add to the queue of `evaluation`
# the change of each candidate that the trial names, and to its refusals the
# refusal of the check of the statement group. What the evaluations of the
# trial print goes to the file `log`: the apply prints the same for each
# change, and a candidate printed it in the whole build. The trial evaluates
# each change of the queue, so it runs for each apply that has one: an edit
# that can not be evaluated stops in the fork, and the process stays as it
# was (decision D4). Answer the error or the refusal that stopped the trial
# early, also for a trial that ends with no answer, or `nothing`.
function rc_replay!(evaluation::RcEvaluation, log::String)
    t0 = time()
    stopped = nothing
    candidates = rc_candidates(evaluation.items, evaluation.queue.order)
    report = rc_in_fork(io -> rc_trial!(io, evaluation, candidates), log)
    report === nothing && return string("the trial ended with no answer, see ", log)
    again = Tuple{Int, String}[]
    for line in split(report, '\n'; keepempty = false)
        parts = split(line, ' '; limit = 3)
        if parts[1] == "differs"
            item = evaluation.items[parse(Int, parts[2])]
            how = parts[3][1]
            rc_enqueue!(evaluation.queue, rc_replay_change(item, how))
        elseif parts[1] == "again"
            push!(again, (parse(Int, parts[2]), String(parts[3])))
        elseif parts[1] == "early"
            item = evaluation.items[parse(Int, parts[2])]
            push!(evaluation.refusals, string(parts[3], " ", rc_where(item), " ", rc_what(item),
                                              ": its evaluation gives another result in a program that holds no method ",
                                              "and no name of what comes after it; only a whole build evaluates it at its ",
                                              "place in the load order"))
        elseif parts[1] == "ordered"
            numbers = split(line, ' ')
            println("rc: replay: ", numbers[2], " expressions of the edit were evaluated again with no method and no ",
                    "name of what comes after them (", numbers[4], " methods, ", numbers[6], " names), ", numbers[3],
                    " differ; ", numbers[5], " s")
        elseif parts[1] == "unordered"
            push!(evaluation.refusals, string("the check of the load order of the expressions of the edit failed: ",
                                              SubString(line, 11), "; see ", log))
        elseif parts[1] == "refuse"
            push!(evaluation.refusals, String(SubString(line, 8)))
        elseif parts[1] == "problem"
            println("rc: replay: ", SubString(line, 9))
        elseif parts[1] == "stopped"
            stopped = String(SubString(line, 9))
            println("rc: replay: stopped: ", stopped)
        elseif parts[1] == "done"
            numbers = split(line, ' ')
            println("rc: replay: ", numbers[2], " candidates, ", numbers[3], " compared, ", numbers[7],
                    " moved, ", numbers[4], " differ; prints ", numbers[5], " s, trial ", numbers[6], " s, in all ",
                    round(time() - t0; digits = 2), " s")
        end
    end
    stopped === nothing && isempty(evaluation.refusals) && rc_check_again!(evaluation, again, string(log, ".again"))
    return stopped
end
