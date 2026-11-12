# Statements that the edit removes: a constant and the method that reads it, a
# constant that hides a name of Base, and a global that becomes a constant. A
# constant that stays gets a new value.
# Revise has the test set "Retract removed bindings".
module RetractRemovedBindings
    module Sub
        export tag
        tag() = :sub
    end
using .Sub
const SETTING = 17
const CHANGED = 1
global TO_CONST::Int = 42
const view = "shadow"
read_setting() = SETTING
shown() = (tag(), isdefined(@__MODULE__, :SETTING),
           isdefined(@__MODULE__, :read_setting) ? length(methods(read_setting)) : 0,
           CHANGED, TO_CONST, isconst(@__MODULE__, :TO_CONST), view === Base.view)
end
