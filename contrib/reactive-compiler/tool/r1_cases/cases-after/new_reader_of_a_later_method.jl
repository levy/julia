# An expression that the edit makes a reader of a method that comes after it in
# the load order (finding 53). Its text of before reads no later method. A
# whole build expands the text of now before the later method exists. A rebuild
# expands it in a program that holds the later method, so it must refuse the
# edit.
module NewReaderOfALaterMethod
layout_of(::Val) = :plain
macro shelf(name)
    layout = layout_of(Val(name))
    return esc(:(shelf_layout() = $(QuoteNode(layout))))
end
@shelf crate
layout_of(::Val{:crate}) = :wrapped
shown() = shelf_layout()
end
