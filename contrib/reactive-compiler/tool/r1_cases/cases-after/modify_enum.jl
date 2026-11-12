# An enum. The edit adds one more member to it.
# Revise has the test set "Modify @enum".
module ModifyEnum
@enum Fruit apple=1 orange=2 kiwi=3
shown() = (map(Int, Base.instances(Fruit)), isdefined(@__MODULE__, :kiwi))
end
