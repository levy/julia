# The expressions that run a function of helpers.jl when Julia evaluates them.
# No edit of the gate changes this file.

# The initializer calls a function.
const TABLE = make_table()

# The initializer calls a function through a value of an unknown type.
const BOX = Ref{Any}(3)
const SCALED = scale(BOX[])

# The expansion of a macro runs a function: in a method and in an initializer.
macro answer(value)
    return esc(expand_answer(value))
end
answer_value() = @answer 10
const ANSWER = @answer 100

# The initializer makes a value of a type that the edit changes.
const DEFAULT_THEME = make_theme()
theme_width() = DEFAULT_THEME.width

# The generator runs a function.
@generated staged(x) = generated_body(x)
