# The lines that the binary prints. The order step of the gate changes this
# function, and `julia_main` stays as it is.
function shape_lines()
    return ["leaf = $(DepLib.leaf_value())",
            "inner = $(DepLib.Inner.inner_value())",
            "extra = $(length(methods(DepLib.extra)))"]
end

Base.@ccallable function julia_main()::Cint
    for line in shape_lines()
        println("shape: ", line)
    end
    println("shape: state = 0")
    return 0
end
