# An `@eval` loop that the edit changes, with a constant after it (finding 53).
# The print of what a statement defines holds the names of its module, and the
# check of the load order takes the later names out: the rebuild must apply
# the edit.
module EditedEvalBeforeAConstant
for (name, k) in ((:times2, 2), (:times3, 3))
    @eval $name(x) = $k * x
end
const LIMIT = 4
shown() = (times2(1), times3(1), LIMIT)
end
