# An expression that reads a method that comes after it in the load order, and
# whose text the edit changes (finding 53). A whole build expands the use of the
# macro before the later method exists. A rebuild expands the text of now in a
# program that holds the later method, so it must refuse the edit.
module EditedReaderOfALaterMethod
layout_of(::Val) = :plain
macro shelf(name, depth)
    layout = layout_of(Val(name))
    return esc(:($(Symbol(name, :_layout))() = ($(QuoteNode(layout)), $depth)))
end
@shelf crate 1
layout_of(::Val{:crate}) = :wrapped
shown() = crate_layout()
end
