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

# A statement defines a method for each row of a table that a function makes.
for (name, value) in loop_table()
    @eval $name() = $value
end

# A statement exports each name that a function gives.
for name in exported_names()
    @eval export $name
end

# The initializer makes two functions of its own, which call a function of
# helpers.jl by its name. Each evaluation gives a result of the same code, so
# the constant stays as it is, and its functions call the new method.
const HANDLERS = [x -> handle(x), x -> handle(x) + 1]

# The initializer gives another value at each evaluation, and it counts its
# evaluations. The constant stays as it is, and so does the count.
const COUNTER = Ref(0)
const STAMP = next_number(COUNTER)

# A statement fills a table of values of the type that the edit changes. The
# table is made again, and the statement runs again.
const THEMES = Dict{Symbol, Theme}()
THEMES[:default] = make_theme()

# The expansion defines two methods with the lines of the function that builds
# it. The edit changes one of them, and the other one must stay.
macro accessors(name)
    return accessor_code(name)
end
@accessors pair

# The initializer puts a value into the storage of the task that evaluates it.
const MARKED = mark!(1)

# The expansion defines a method with a line of the function that builds it.
# The edit changes that function and not the expansion, so the rebuild does not
# evaluate this expression again, and its method must stay.
macro steady(name)
    return steady_code(name)
end
@steady steady_value
