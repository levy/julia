# A function that holds its own line as a number, as a log macro does. The
# gate replaces this file with lines-after.jl, where the function moved.
noted_line() = @__LINE__
