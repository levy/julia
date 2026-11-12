# A nested bare module, which has no names of Base. The edit makes it an ordinary
# module and changes its function.
# Revise has the test set "baremodule".
module BaremoduleToModule
    baremodule Inner
        f() = 1
    end
shown() = (Inner.f(), isdefined(Inner, :map))
end
