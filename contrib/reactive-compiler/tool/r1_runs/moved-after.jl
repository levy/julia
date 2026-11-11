# The parts that an edit removes or moves (decision D2), after the edit of the
# gate: the function and the struct Token are in the module Right, the struct
# Gone and the constant are gone, and the last module has another name.

# The function and the struct left this module, with their exports.
module Left
end

module Right
export stay, travel, Token
stay() = 2
travel() = 1
struct Token
    weight::Int
end
end

module Both
using ..Left, ..Right
journey() = travel() + stay()
weigh(token::Token) = token.weight
end

# The module that used another one.
module Onlooker
end

# The module with its new name.
module After
inside() = 4
end

# The module that defined the first function defines the second one, and the
# module that imported the first function defines it and imports the second
# one.
module Early
export bring
bring() = 6
end

module Late
using ..Early
import ..Early: bring
export carry
carry() = 5
carry(x) = x + carry()
bring(x) = x + bring()
end
