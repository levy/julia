# The example of Gate E (plan/pending/robust-incremental-compiler.md): a
# program that the stock trimmer accepts. One tracked file holds the
# computation; the entry point prints its results with the printers that a
# trimmed image keeps.
module TrimApp

include("compute.jl")

Base.@ccallable function julia_main()::Cint
    total = 0
    for n in 1:10
        total += score(n)
    end
    print(Core.stdout, "total: ")
    print(Core.stdout, total)
    print(Core.stdout, "\n")
    print(Core.stdout, "label: ")
    print(Core.stdout, label(total))
    print(Core.stdout, "\n")
    return Cint(0)
end

end
