# A struct made by a keyword macro. The edit adds a field with a default, and
# the method that reads the struct uses the new field.
# Revise has the test set "struct revision (issue #1022)".
module StructRevisionFieldAdded
Base.@kwdef struct Blah
    x = 5
end
useblah(b::Blah) = b.x + 1
shown() = (fieldnames(Blah), Blah().x, useblah(Blah()))
end
