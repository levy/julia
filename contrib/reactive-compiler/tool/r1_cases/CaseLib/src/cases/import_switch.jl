# An explicit import of one name from a submodule. The edit imports the name
# from the other submodule, which exports a name that clashes with the first.
# Revise has the test set "Import switch (issue #1106)".
module ImportSwitch
    module A
        export tag
        tag() = :A
    end
    module B
        export tag
        tag() = :B
    end
using .A: tag
call_tag() = tag()
shown() = (call_tag(), tag === A.tag, tag === B.tag)
end
