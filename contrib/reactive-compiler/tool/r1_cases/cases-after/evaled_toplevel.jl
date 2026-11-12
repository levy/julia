# A module that brings a submodule into scope with an evaluated `using`. The edit
# changes a function after that statement; the evaluated statement must still hold.
# Revise has the test set "Evaled toplevel".
module EvaledToplevel
    module Lower
        export f
        f() = 1
    end
@eval using .Lower
g() = 3
shown() = (f(), g())
end
