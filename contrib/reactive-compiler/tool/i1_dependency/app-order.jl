# The lines that the binary prints. The order step of the gate changes this
# function, and `julia_main` stays as it is.
function shape_lines()
    return ["leaf = $(DepLib.leaf_value())",
            "inner = $(DepLib.Inner.inner_value())",
            "extra = $(length(methods(DepLib.extra)))",
            "part = $(part_value(DepLib.Part(5)))",
            "added = $(DepLib.added_value())"]
end

# A method on a type that the same edit adds to DepLib, which loads first.
part_value(part::DepLib.Part) = part.value

Base.@ccallable function julia_main()::Cint
    for line in shape_lines()
        println("shape: ", line)
    end
    println("shape: state = 0")
    return 0
end
