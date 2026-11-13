# An expression that the edit makes a reader of a name that comes after it in
# the load order (finding 53). A whole build expands the text of now before the
# constant exists. A rebuild expands it in a program that holds the constant,
# so it must refuse the edit.
module NewReaderOfALaterName
macro shelf(name)
    found = name === :crate && isdefined(__module__, :CRATE_SIZE)
    return esc(:(shelf_found() = $found))
end
@shelf crate
const CRATE_SIZE = 3
shown() = shelf_found()
end
