# The lines that the binary prints: one for each expression of RunLib that
# runs a function of helpers.jl.
function shape_lines()
    return ["table = $(RunLib.TABLE[:answer])",
            "scaled = $(RunLib.SCALED)",
            "answer = $(RunLib.answer_value())",
            "answer constant = $(RunLib.ANSWER)",
            "theme = $(RunLib.theme_width()) of $(fieldcount(typeof(RunLib.DEFAULT_THEME))) fields",
            "staged = $(RunLib.staged(1))",
            "loop = $(RunLib.loop_first())$(isdefined(RunLib, :loop_second) ? " and $(RunLib.loop_second())" : "")",
            "exports = $(join(sort!(filter(!=(:RunLib), names(RunLib))), ' '))",
            "handlers = $(RunLib.HANDLERS[2](1))",
            "stamp = $(RunLib.STAMP) of $(RunLib.COUNTER[])",
            "themes = $(length(RunLib.THEMES)) with $(fieldcount(valtype(RunLib.THEMES))) fields"]
end

Base.@ccallable function julia_main()::Cint
    for line in shape_lines()
        println("shape: ", line)
    end
    println("shape: state = 0")
    return 0
end
