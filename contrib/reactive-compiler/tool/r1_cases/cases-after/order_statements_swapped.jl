# Two statements that the edit swaps (H4, D3). A whole build fills the list in
# the new order.
module OrderStatementsSwapped
const STEPS = Symbol[]
push!(STEPS, :second)
push!(STEPS, :first)
shown() = Tuple(STEPS)
end
