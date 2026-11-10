# The lines that the binary prints: those of gate I1, and the count of the
# marks of the table. With DEPAPP_DECODE in the environment the binary also
# decodes the source of each method of its image, which reads the root table
# of each method.
function shape_lines()
    return ["leaf = $(DepLib.leaf_value())",
            "inner = $(DepLib.Inner.inner_value())",
            "extra = $(length(methods(DepLib.extra)))",
            "table = $(DepLib.table_marks())"]
end

function decode_sources()
    decoded = 0
    Base.visit(Core.methodtable) do method
        if isdefined(method, :source)
            Base.uncompressed_ir(method)
            decoded += 1
        end
        true
    end
    return decoded
end

Base.@ccallable function julia_main()::Cint
    for line in shape_lines()
        println("shape: ", line)
    end
    println("shape: state = 0")
    haskey(ENV, "DEPAPP_DECODE") && println("decoded: ", decode_sources(), " sources")
    return 0
end
