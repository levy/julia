# The parts that an edit removes or moves (decision D2). The gate replaces this
# file with moved-after.jl.

# A function that the edit moves from the module Left to the module Right, with
# its export. Both uses the two modules and calls the function by its name.
module Left
export travel
travel() = 1
end

module Right
export stay
stay() = 2
end

module Both
using ..Left, ..Right
journey() = travel() + stay()
end

# A module that uses another one. The edit removes the `using` line.
module Onlooker
using ..Right
end

# A struct and a constant that the edit removes.
struct Gone
    value::Int
end
const GONE = Gone(1)

# A module that the edit gives another name.
module Before
inside() = 4
end

# A function that the edit moves from the module Early to the module Late,
# which imported it by its name and gave it a method. A second function goes
# the other way: Late defined it, and Late imports it by its name after the
# edit. The method that Late gives each function has the same text before and
# after the edit.
module Early
export carry
carry() = 5
end

module Late
using ..Early
import ..Early: carry
export fetch
carry(x) = x + carry()
fetch() = 6
fetch(x) = x + fetch()
end
