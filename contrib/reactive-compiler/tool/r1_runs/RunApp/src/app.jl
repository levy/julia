# The lines that the binary prints: one for each expression of RunLib that
# runs a function of helpers.jl, for the lists that the statements fill, for
# the function that names its own line, for the methods that the expansion of
# a macro defines, for the value that an initializer puts into the storage
# of its task, and for the types that the call of a macro defines. The call
# with a value of such a type goes through `invokelatest`, so it is a dynamic
# one, and the trace of the workload has a statement that names the type.
shown_call(f) = hasmethod(f, Tuple{}) ? f() : "no method"

# The value of the call, or the name of the error that it throws.
function shown_result(f)
    try
        return string(f())
    catch e
        return string(nameof(typeof(e)))
    end
end

# The names of `names` that the module binds, each with a mark.
bound_names(mod::Module, names::Symbol...) = join((isdefined(mod, name) ? "+$name" : "-$name" for name in names), "")

# The name of the module that defines the function `name` of `mod`, or a mark
# when `mod` has no such name.
owner_name(mod::Module, name::Symbol) = isdefined(mod, name) ? nameof(parentmodule(getfield(mod, name))) : "none"

# The module of RunLib that defines the struct Token, and the weight that the
# method of Both reads from a value of that struct.
token_module() = isdefined(RunLib.Left, :Token) ? RunLib.Left : RunLib.Right
token_weight() = RunLib.Both.weigh(getfield(token_module(), :Token)(8))

# A value of a type that the build never sees: the workload runs with no
# variable RUNAPP_LATE, and the program of the gate runs with it. So a method
# gets its code for that type in the program.
late_value() = Base.inferencebarrier(haskey(ENV, "RUNAPP_LATE") ? Int8(1) : 1)

# The count of the finalizer of RunLib after the program finalizes one value.
released_weight() = (finalize(RunLib.track(3)); RunLib.RELEASED[])

function shape_lines()
    return ["table = $(RunLib.TABLE[:answer])",
            "scaled = $(RunLib.SCALED)",
            "answer = $(RunLib.answer_value())",
            "answer constant = $(RunLib.ANSWER)",
            "theme = $(RunLib.theme_width()) of $(fieldcount(typeof(RunLib.DEFAULT_THEME))) fields",
            "staged = $(RunLib.staged(1))",
            "staged late = $(shown_result(() -> RunLib.staged(late_value()))) of $(typeof(late_value()))",
            "staged by = $(RunLib.staged_by_statement(1)) and $(RunLib.staged_by_macro(1)) and " *
            "$(shown_result(() -> RunLib.staged_by_statement(late_value())))",
            "loop = $(RunLib.loop_first())$(isdefined(RunLib, :loop_second) ? " and $(RunLib.loop_second())" : "")",
            "exports = $(join(sort!(filter(!=(:RunLib), names(RunLib))), ' '))",
            "handlers = $(RunLib.HANDLERS[2](1))",
            "stamp = $(RunLib.STAMP) of $(RunLib.COUNTER[])",
            "themes = $(length(RunLib.THEMES)) with $(fieldcount(valtype(RunLib.THEMES))) fields",
            "registry = $(join(RunLib.REGISTRY, ' '))",
            "seen = $(length(RunLib.SEEN))",
            "notes = $(join(RunLib.NOTES, ' '))",
            "greeting = $(RunLib.GREETING)",
            "reached = $(released_weight()) and $(RunLib.through_c(2)) and " *
            "$(RunLib.through_unknown(RunLib.shout, 1)) and $(RunLib.whisper(1))",
            "motto = $(RunLib.MOTTO)",
            "creed = $(RunLib.CREED)",
            "line = $(RunLib.noted_line())",
            "accessors = $(shown_call(RunLib.pair_first)) and $(shown_call(RunLib.pair_second))",
            "marked = $(RunLib.MARKED) of $(fieldcount(RunLib.Marker)) fields",
            "steady = $(shown_call(RunLib.steady_value))",
            "height = $(RunLib.theme_height(RunLib.DEFAULT_THEME))",
            "logged = $(RunLib.logged_line())",
            "journey = $(shown_result(RunLib.Both.journey))",
            "token = $(shown_result(token_weight)) of $(nameof(token_module()))",
            "left = $(join(filter(!=(:Left), names(RunLib.Left)), ' '))$(bound_names(RunLib.Left, :travel))",
            "removed = $(bound_names(RunLib, :Gone, :GONE, :Before, :After))",
            "onlooker = $(bound_names(RunLib.Onlooker, :stay, :Right))",
            "handover = $(shown_result(() -> RunLib.Late.carry(1))) and $(shown_result(() -> RunLib.Late.bring(1))) of " *
            "$(owner_name(RunLib.Late, :carry)) and $(owner_name(RunLib.Late, :bring))$(bound_names(RunLib.Early, :carry, :bring))",
            "badge = $(shown_result(() -> Base.invokelatest(RunLib.badge_sum, RunLib.MarkedBadge(3))))",
            "layout = $(shown_result(() -> RunLib.crate_layout(RunLib.Crate(1))))"]
end

Base.@ccallable function julia_main()::Cint
    for line in shape_lines()
        println("shape: ", line)
    end
    println("shape: state = 0")
    return 0
end
