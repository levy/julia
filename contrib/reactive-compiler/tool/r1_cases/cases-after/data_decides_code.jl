# Code whose existence depends on data: a statement defines one of two methods
# by the value of a global, and the edit changes the value. Revise lists it as a
# limit ("Code whose existence depends on data").
module DataDecidesCode
flag = false
if flag
    answer() = 1
else
    answer() = 2
end
shown() = answer()
end
