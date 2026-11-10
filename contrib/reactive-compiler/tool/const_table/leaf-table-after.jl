leaf_value() = 3
extra(x::Int) = 1

# The table of the constant data gate. Its bytes are in the constant data of
# the image. `mark_table!` sets 64 of them, 8256 bytes apart: each mark is on
# a page of its own with no mark on the page before it, and the 64 marks are
# at 64 different places of a page.
const TABLE_STEP = 8256
const TABLE = zeros(UInt8, 64 * TABLE_STEP)
function mark_table!()
    for mark in 0:63
        TABLE[1 + mark * TABLE_STEP] = 0x01
    end
    return nothing
end
table_marks() = count(!iszero, TABLE)

# The edit of the gate: a rebuild evaluates this statement, which writes into
# the table of the base image.
mark_table!()
