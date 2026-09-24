# The minimal sequential kernel: modules deliver messages to each other
# through gates, and an event queue orders the deliveries by time. The
# kernel never learns which module kinds exist.

module MiniKernel

export AbstractModule, EventEnvironment, Gate, Network,
       send!, has_event, pop_event!, run_measured!, handle_message!

abstract type AbstractModule end
abstract type EventEnvironment end

mutable struct Gate <: Function
    owner::Any          # the AbstractModule this gate delivers to
end

struct Event
    action::Gate
    environment::Union{Nothing,EventEnvironment}
    time::Int
    sequence::Int
end

function handle_message! end

@inline (gate::Gate)(network, environment) =
    handle_message!(network, gate.owner::AbstractModule, environment, gate)

# The queue is a binary heap in the first `pending` slots of a vector that
# grows only while the network warms up: a run at its steady size
# reallocates nothing, so no fresh page meets an event.
mutable struct Network
    time::Int
    sequence::Int
    queue::Vector{Event}
    pending::Int
end
Network() = Network(0, 0, Vector{Event}(undef, 1024), 0)

@inline before(a::Event, b::Event) =
    a.time < b.time || (a.time == b.time && a.sequence < b.sequence)

function push_event!(network::Network, time::Int, action::Gate, environment)
    network.sequence += 1
    event = Event(action, environment, time, network.sequence)
    queue = network.queue
    n = network.pending + 1
    n > length(queue) && resize!(queue, 2 * length(queue))
    network.pending = n
    @inbounds while n > 1
        parent = n >> 1
        before(event, queue[parent]) || break
        queue[n] = queue[parent]
        n = parent
    end
    @inbounds queue[n] = event
    nothing
end

has_event(network::Network) = network.pending > 0

"""
Remove the next event, the earliest time and then the lowest sequence, and
set the network's clock to its time.
"""
function pop_event!(network::Network)
    queue = network.queue
    n = network.pending
    @inbounds top = queue[1]
    @inbounds last = queue[n]
    n -= 1
    network.pending = n
    i = 1
    @inbounds while true
        child = 2 * i
        child > n && break
        right = child + 1
        right <= n && before(queue[right], queue[child]) && (child = right)
        before(queue[child], last) || break
        queue[i] = queue[child]
        i = child
    end
    @inbounds n >= 1 && (queue[i] = last)
    network.time = top.time
    return top
end

function send!(network::Network, gate::Gate, environment)
    push_event!(network, network.time + 1, gate, environment)
    nothing
end

"""
Run the queue and measure every event. `latencies_ns[i]` takes the wall time
of event `i`; `gc_ns[i]` takes the collector time that fell into event `i`.
Both vectors are preallocated by the caller, so the harness itself allocates
nothing per event. Returns the number of events processed.
"""
function run_measured!(network::Network, latencies_ns::Vector{Int64},
                       gc_ns::Vector{Int64})
    limit = length(latencies_ns)
    count = 0
    while has_event(network)
        count == limit && return count
        event = pop_event!(network)
        count += 1
        gc0 = Base.gc_num().total_time
        t0 = time_ns()
        event.action(network, event.environment)
        t1 = time_ns()
        gc1 = Base.gc_num().total_time
        @inbounds latencies_ns[count] = Int64(t1 - t0)
        @inbounds gc_ns[count] = Int64(gc1 - gc0)
    end
    return count
end

end # module MiniKernel
