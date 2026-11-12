# Two functions, one with a docstring and one without. The edit changes the text
# of the first docstring and adds a docstring to the second.
# Revise has the test set "Changing docstring".
module ChangingDocstring
doctext(name) = begin
    multidoc = get(Base.Docs.meta(@__MODULE__), Base.Docs.Binding(@__MODULE__, name), nothing)
    multidoc === nothing ? "none" : join((d.text[1] for d in values(multidoc.docs)), "|")
end
"f" f() = 1
g() = 1
shown() = (f(), g(), doctext(:f), doctext(:g))
end
