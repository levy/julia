# A global that holds a type and is named in a field type. The edit makes it a
# constant with another type; callers that read it and the field type follow.
# Revise has the test set "Global binding invalidation".
module GlobalBindingInvalidation
global StringType = String
struct Info
    a::StringType
    b::String
end
observe(x::Info) = StringType
outer(x) = observe(Info("a", string(x)))
shown() = (outer("x"), fieldtype(Info, :a), isconst(@__MODULE__, :StringType))
end
