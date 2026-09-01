#!/bin/bash
# The battery and the headline measurements. Override the binary with
#   JULIA=/path/to/julia ./run.sh    (default: this checkout's ../../julia)
set -euo pipefail
cd "$(dirname "$0")"
JULIA="${JULIA:-../../julia}"
run() { "$JULIA" --startup-file=no "$@"; }

echo "== correctness batteries =="
run v2_regression.jl
run stage3_safety.jl

echo "== the tail bound (20 M events, unpaced) =="
run stage3_run.jl baseline 20000000 | tail -11
run stage3_run.jl regions  20000000 | tail -12

echo "== the census: pause vs live-set size (cooperative entry) =="
for K in 10000 1000 300; do
    echo "-- $K live records --"
    run stage5_scoped.jl coop 2000000 100000 $K | grep -E "stop-the-world|^mark |^sweep |pause"
done
echo "-- the full-sweep reference --"
run stage5_scoped.jl full 2000000 100000 10000 | grep -E "pause"

echo "== throughput: slice-batched resets vs the stock collector =="
for w in 3 200; do
    echo "-- $((w * 8)) B of garbage per event --"
    run stage5_scoped.jl autopool 5000000 100000 10000 $w | grep "wall time"
    for b in 1 100 1000; do
        echo -n "B=$b  "; run stage5_scoped.jl batch 5000000 100000 10000 $w $b | grep "wall time"
    done
done

echo "== memory over time (1 minute paced at 100 us/event; 30 min with 18000000) =="
run stage4_endurance.jl 600000 | tail -10
