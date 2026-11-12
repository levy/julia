# A method definition that makes a local function with the name of a function of
# Base, by mistake. The edit writes `Base.iterate`, so the name in the module is
# the one of Base again, and a caller that was defined earlier uses it.
# Revise has the test set "Orphaned binding realias (issue #239)".
module OrphanedBindingRealias
struct Foo end
caller() = iterate(Foo())
Base.iterate(x::Foo) = (42, nothing)
shown() = (caller(), iterate === Base.iterate)
end
