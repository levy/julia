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
