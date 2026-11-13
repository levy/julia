# An expression that the edit makes call a function whose body names a
# constant that comes after it in the load order (finding 53). A whole build
# stops there, because the constant is not defined yet; the process of a
# rebuild has compiled code that holds its value, so the check must invalidate
# that code and refuse the edit.
module NewReaderOfALaterConstantInAFunction
size_of(::Val) = 1
size_of(::Val{:crate}) = CRATE_SIZE
macro shelf(name)
    found = size_of(Val(name))
    return esc(:(shelf_size() = $found))
end
@shelf crate
const CRATE_SIZE = 3
shown() = shelf_size()
end
