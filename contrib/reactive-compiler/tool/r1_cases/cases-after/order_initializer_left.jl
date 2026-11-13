# A method that the edit moves below a constant whose initializer calls it
# (H4). A whole build gives the constant the value of the method of before,
# which a live process can not give it: the rebuild must refuse.
module OrderInitializerLeft
pick(x) = 1
const PICKED = pick(1)
pick(x::Int) = 2
shown() = PICKED
end
