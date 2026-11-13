# A method that the edit moves above the use of a macro that asks for it
# (H4). No text changes. A whole build expands the use after the method, so it
# gets the answer of the method; the rebuild must evaluate the use again.
module OrderMacroUsePassed
layout_of(::Val) = :plain
macro shelf(name)
    layout = layout_of(Val(name))
    return esc(:(shelf_layout() = $(QuoteNode(layout))))
end
layout_of(::Val{:crate}) = :wrapped
@shelf crate
shown() = shelf_layout()
end
