# A type whose values the program keeps in the storage of its task, as a stack
# of what it computes now, after the step `retype` of the gate: the type has
# one more field. A stack that an evaluation of before this edit made holds
# values of the type of before.
struct Marker
    id::Int
    tag::Symbol
end
marker_stack() = get!(() -> Marker[], task_local_storage(), :run_markers)::Vector{Marker}
mark!(id) = (push!(marker_stack(), Marker(2 * id, :retyped)); marker_stack()[end].id)
make_marker(id) = Marker(id, :retyped)

# A macro that defines two types and an alias for one struct: the struct, a
# second type that holds a value of it and a marker, and the alias of that
# second type. The source of the call shows the first name only.
macro paired(definition)
    name = definition.args[2]::Symbol
    scaled = Symbol(:Scaled, name)
    marked = Symbol(:Marked, name)
    return esc(quote
        $definition
        struct $scaled{T}
            base::$name
            mark::Marker
            extra::T
        end
        const $marked = $scaled{T} where T<:Integer
    end)
end
@paired struct Badge
    id::Int
end
