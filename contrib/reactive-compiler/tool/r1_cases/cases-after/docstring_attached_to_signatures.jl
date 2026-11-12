# Docstrings that stand on a signature with no body, on a function that has no
# method. The edit changes one text and adds a docstring for a `where` signature.
# Revise has the test set "Docstring attached to signatures".
module DocstringAttachedToSignatures
function f end
"basecase changed" f(x)
"basecase with type" f(x::Int)
"where" f(x::T) where T <: Int8
shown() = (sort!([d.text[1] for d in values(Base.Docs.meta(@__MODULE__)[Base.Docs.Binding(@__MODULE__, :f)].docs)]),
           length(methods(f)))
end
