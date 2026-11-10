# A type whose values the program keeps in the storage of its task, as a stack
# of what it computes now. The gate replaces this file with markers-after.jl,
# and then with markers-retyped.jl.
struct Marker
    id::Int
end
marker_stack() = get!(() -> Marker[], task_local_storage(), :run_markers)::Vector{Marker}
mark!(id) = (push!(marker_stack(), Marker(id)); marker_stack()[end].id)
