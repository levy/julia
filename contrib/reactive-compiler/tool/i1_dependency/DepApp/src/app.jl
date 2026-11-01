Base.@ccallable function julia_main()::Cint
    println("shape: leaf = ", DepLib.leaf_value())
    println("shape: inner = ", DepLib.Inner.inner_value())
    println("shape: extra = ", length(methods(DepLib.extra)))
    println("shape: state = 0")
    return 0
end
