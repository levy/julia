# A module with one function. The edit adds a nested module with a function.
# Revise has the test set "New submodules".
module NewSubmodules
f() = 1
    module Sub
        g() = 2
    end
shown() = (f(), isdefined(@__MODULE__, :Sub) ? Sub.g() : 0)
end
