# The application of the gate of the edit cases (tool/gate_cases.sh). It prints
# one line for each case of the path package CaseLib: what the function `shown`
# of the module of the case answers, or the name of the error that it throws.
module CaseApp
using CaseLib

function shown(name::Symbol)
    try
        return string(Base.invokelatest(getfield(getfield(CaseLib, name), :shown)))
    catch e
        return string(nameof(typeof(e)))
    end
end

Base.@ccallable function julia_main()::Cint
    for name in CaseLib.CASES
        println("shape: ", name, " = ", shown(name))
    end
    return 0
end
end
