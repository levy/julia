# A module with one function. The edit adds a second function with a docstring,
# so a binding and its documentation are new together.
# Revise has the test set "New documented binding".
module NewDocumentedBinding
doctext(name) = begin
    multidoc = get(Base.Docs.meta(@__MODULE__), Base.Docs.Binding(@__MODULE__, name), nothing)
    multidoc === nothing ? "none" : join((d.text[1] for d in values(multidoc.docs)), "|")
end
g() = 1
"h" h() = 1
shown() = (g(), isdefined(@__MODULE__, :h) ? h() : 0, doctext(:h))
end
