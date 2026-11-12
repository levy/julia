# A macro whose expansion has a docstring and a constant. The edit changes a
# function next to the macro use; the docstring made by the macro must stay.
# Revise has the test set "Macro docstrings (issue #309)".
module MacroDocstrings
macro myconst(name, val)
    quote
        "mydoc"
        const $(esc(name)) = $val
    end
end
@myconst c 1.2
f() = 2
doctext(name) = begin
    multidoc = get(Base.Docs.meta(@__MODULE__), Base.Docs.Binding(@__MODULE__, name), nothing)
    multidoc === nothing ? "none" : join((d.text[1] for d in values(multidoc.docs)), "|")
end
shown() = (f(), c, doctext(:c))
end
