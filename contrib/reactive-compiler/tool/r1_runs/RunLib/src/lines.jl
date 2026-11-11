# A function that holds its own line as a number, as a log macro does. The
# gate replaces this file with lines-after.jl, where the function moved.
noted_line() = @__LINE__

# A function that logs. The log macro writes its line and the id of its
# statement into the code. The id must be that of a whole build, and not count
# the evaluations of a server.
function logged_line()
    @debug "a line is read"
    return noted_line()
end
