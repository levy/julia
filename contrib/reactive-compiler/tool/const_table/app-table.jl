# The lines that the binary prints: those of gate I1, and the count of the
# marks of the table.
function shape_lines()
    return ["leaf = $(DepLib.leaf_value())",
            "inner = $(DepLib.Inner.inner_value())",
            "extra = $(length(methods(DepLib.extra)))",
            "table = $(DepLib.table_marks())"]
end

Base.@ccallable function julia_main()::Cint
    for line in shape_lines()
        println("shape: ", line)
    end
    println("shape: state = 0")
    return 0
end
