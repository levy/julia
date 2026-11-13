# Two statements that the edit swaps (H4, D3). A whole build fills the list in
# the new order.
module OrderStatementsSwapped
const STEPS = Symbol[]
push!(STEPS, :first)
push!(STEPS, :second)
shown() = Tuple(STEPS)
end
