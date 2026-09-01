// The exact C++ equivalent of stage6_region_native.jl: same topology
// (self-ticking source -> 4 relays -> sink), same linear-scan event
// selection, same payload fill and checksum arithmetic. Ownership style:
// new/delete per event wrapper and per packet, vector payload.
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <chrono>

static int W = 3;

struct FlightPacket {
    long id;
    long hops;
    std::vector<double> payload;
};

struct Event6 {
    long time;
    long sequence;
    int target;               // 0 = source self-tick; 1..R relays; R+1 sink
    FlightPacket* packet;
};

struct Net6 {
    long time = 0, sequence = 0;
    int relays = 4;
    long sent = 0, received = 0;
    double checksum = 0.0;
    std::vector<Event6*> queue;
};

static void push_event(Net6& n, long t, int target, FlightPacket* p) {
    n.sequence++;
    n.queue.push_back(new Event6{t, n.sequence, target, p});
}

static void handle(Net6& n, Event6* e) {
    if (e->target == 0) {
        n.sent++;
        FlightPacket* pkt = new FlightPacket{n.sent, 0, {}};
        pkt->payload.resize(W);
        for (int j = 1; j <= W; j++)
            pkt->payload[j - 1] = double(n.sent + j);
        push_event(n, n.time + 1, 1, pkt);
        push_event(n, n.time + 1, 0, nullptr);
    }
    else if (e->target <= n.relays) {
        FlightPacket* pkt = e->packet;
        pkt->hops++;
        push_event(n, n.time + 1, e->target + 1, pkt);
    }
    else {
        FlightPacket* pkt = e->packet;
        n.received++;
        n.checksum += pkt->payload.front() + pkt->payload.back() + pkt->hops;
        delete pkt;
    }
}

int main(int argc, char** argv) {
    long events = argc > 1 ? atol(argv[1]) : 5000000;
    W = argc > 2 ? atoi(argv[2]) : 3;
    Net6 net;
    net.queue.reserve(1024);
    push_event(net, 1, 0, nullptr);
    auto t0 = std::chrono::steady_clock::now();
    long count = 0;
    while (count < events) {
        size_t best = 0;
        for (size_t i = 1; i < net.queue.size(); ++i) {
            Event6* e = net.queue[i];
            Event6* top = net.queue[best];
            if (e->time < top->time ||
                (e->time == top->time && e->sequence < top->sequence))
                best = i;
        }
        Event6* evt = net.queue[best];
        net.queue.erase(net.queue.begin() + best);
        net.time = evt->time;
        count++;
        handle(net, evt);
        delete evt;
    }
    auto t1 = std::chrono::steady_clock::now();
    double wall = std::chrono::duration<double>(t1 - t0).count();
    printf("wall time          %.3f s (%.2f M events/s)\n", wall, events / wall / 1e6);
    printf("checksum           %.10g\n", net.checksum);
    printf("sent/received      %ld / %ld\n", net.sent, net.received);
    return 0;
}
