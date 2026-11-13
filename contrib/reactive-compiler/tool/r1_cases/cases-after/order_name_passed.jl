# A constant that the edit moves above the use of a macro that asks whether it
# exists (H4). A whole build expands the use after the constant.
module OrderNamePassed
macro shelf(name)
    found = isdefined(__module__, :SHELF_SIZE)
    return esc(:(shelf_found() = $found))
end
const SHELF_SIZE = 3
@shelf crate
shown() = shelf_found()
end
