# A submodule extends a function of a sibling submodule. The edit changes the
# body of the extension; the method of the other module must change with it.
# Revise has the test set "Cross-module extension".
module CrossModuleExtension
    module A
        foo(x) = "default"
    end
    module B
        import ..A
        A.foo(x::Int) = 2
    end
shown() = (A.foo(""), A.foo(0))
end
