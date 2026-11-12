# A struct with a field of a type that contains the struct itself, and an inner
# constructor. The edit adds a field and changes the constructor.
# Revise has the test set "Recursive types (issues #417 and #883)".
module RecursiveTypes
struct Foo
    x::Vector{Foo}
    n::Int
    Foo() = new(Foo[], 0)
end
shown() = (fieldnames(Foo), Foo().x isa Vector{Foo})
end
