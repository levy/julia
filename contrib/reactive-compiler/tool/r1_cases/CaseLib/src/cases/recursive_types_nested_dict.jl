# A parametric struct that names itself in its supertype. The edit adds a field,
# so the constructor with no argument becomes a constructor with one.
# Revise has the test set "Recursive types (issues #417 and #883)".
module RecursiveTypesNestedDict
struct NestedDict{K,V} <: AbstractDict{K,Union{V,NestedDict}} end
shown() = (fieldnames(NestedDict), hasmethod(NestedDict{Int,String}, Tuple{}),
           hasmethod(NestedDict{Int,String}, Tuple{Int}),
           NestedDict{Int,String} <: AbstractDict)
end
