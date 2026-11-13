# A method that the edit moves above a constant whose initializer calls it
# (H4). A whole build gives the constant the value of the method.
module OrderInitializerPassed
pick(x) = 1
pick(x::Int) = 2
const PICKED = pick(1)
shown() = PICKED
end
