# A function that holds its own line as a number, as a log macro does, after
# the edit of the gate: two more lines of this comment are above the function.
# The text of the function is the same, and the function moved from line 3 to
# line 5.
noted_line() = @__LINE__

# A function that logs. The log macro writes its line and the id of its
# statement into the code. The id must be that of a whole build, and not count
# the evaluations of a server.
function logged_line()
    @debug "a line is read"
    return noted_line()
end
