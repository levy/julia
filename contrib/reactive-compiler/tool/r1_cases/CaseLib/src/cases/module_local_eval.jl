# Methods that a loop defines with the eval of the module. The edit changes the
# types of the loop: one type goes, another comes.
# Revise has the test set "Module-local eval".
module ModuleLocalEval
for T in (Int, Float64)
    eval(:(localeval(::$T) = $T))
end
shown() = (localeval(1), hasmethod(localeval, Tuple{Float64}), hasmethod(localeval, Tuple{String}))
end
