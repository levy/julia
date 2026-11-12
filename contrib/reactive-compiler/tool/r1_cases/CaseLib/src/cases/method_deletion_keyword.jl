# A keyword argument that the edit renames. The method keeps one positional
# argument; only the keyword name and its default change.
# Revise has the test set "Method deletion".
module MethodDeletionKeyword
k(::Int; badchoice=1) = badchoice
shown() = (k(1), hasmethod(k, Tuple{Int}, (:badchoice,)), hasmethod(k, Tuple{Int}, (:goodchoice,)))
end
