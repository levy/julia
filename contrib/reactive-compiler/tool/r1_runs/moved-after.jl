# The parts that an edit removes or moves (decision D2), after the edit of the
# gate: the function is in the module Right, the struct and the constant are
# gone, and the last module has another name.

# The function left this module, with its export.
module Left
end

module Right
export stay, travel
stay() = 2
travel() = 1
end

module Both
using ..Left, ..Right
journey() = travel() + stay()
end

# The module that used another one.
module Onlooker
end

# The module with its new name.
module After
inside() = 4
end
