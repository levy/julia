# A type whose values the program keeps in the storage of its task, as a stack
# of what it computes now, after the edit of the gate: the mark has two times
# the number.
struct Marker
    id::Int
end
marker_stack() = get!(() -> Marker[], task_local_storage(), :run_markers)::Vector{Marker}
mark!(id) = (push!(marker_stack(), Marker(2 * id)); marker_stack()[end].id)
