# A macro that rewrites the definition it is given. The edit changes the value
# that the macro writes into the definition.
# Revise has the test set "Revising macros".
module RevisingMacros
macro change(foodef)
    foodef.args[2].args[2] = 1
    esc(foodef)
end
@change foo(x) = 0
shown() = foo("hello")
end
