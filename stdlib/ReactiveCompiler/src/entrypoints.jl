# The entry points of a trimmed image (Stage E of the plan): every
# `@ccallable` method, and the hooks that the runtime calls into the image
# on its own, the ones the build script of `juliac` registers
# (test/trimming/juliac-buildscript.jl of this tree). The `__init__`s join
# at the write. A trim child calls this before its write.
import Base.Experimental: entrypoint

function trim_entrypoints!()
    entrypoint(Base.task_done_hook, (Task,))
    entrypoint(Base.wait, ())
    entrypoint(Base.wait_forever, ())
    entrypoint(Base.trypoptask, (Base.StickyWorkqueue,))
    entrypoint(Base.checktaskempty, ())
    Base.Compiler.add_ccallable_entrypoints!()
    return nothing
end
