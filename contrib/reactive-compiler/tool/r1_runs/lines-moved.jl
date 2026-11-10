# A function that holds its own line as a number, as a log macro does, after
# the second edit of the gate: the step `move` puts one more line of this
# comment above the function, and changes nothing else in the program.
# The text of the function is the same, and the function moved from line 5 to
# line 6.
noted_line() = @__LINE__
