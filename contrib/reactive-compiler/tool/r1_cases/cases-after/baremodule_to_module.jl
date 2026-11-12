# A nested bare module, which has no names of Base. The edit makes it an ordinary
# module and changes its function.
# Revise has the test set "baremodule".
module BaremoduleToModule
    module Inner
        f() = 2
    end
shown() = (Inner.f(), isdefined(Inner, :map))
end
