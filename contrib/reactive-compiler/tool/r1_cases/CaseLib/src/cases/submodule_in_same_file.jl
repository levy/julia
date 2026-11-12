# A nested module that exports a global, and a `using` of it in the parent. The
# edit changes the value of the global.
# Revise has the test set "Submodule in same file (#718)".
module SubmoduleInSameFile
    module Inner
        export VARIABLE_UNASSIGNED
        global VARIABLE_UNASSIGNED = -84.0
    end
using .Inner
shown() = VARIABLE_UNASSIGNED
end
