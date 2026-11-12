# A function with a C entry whose edit changes its signature. A whole build
# makes the C entry by the name of the function, so the rebuild must refuse the
# edit: a C caller would get the entry of before.
module CEntrySignature
Base.@ccallable function case_entry(x::Cdouble)::Cdouble
    return 2 * x
end
shown() = (case_entry(Cdouble(2)), hasmethod(case_entry, Tuple{Cint}))
end
