#!/bin/bash
# Every measurement of MEASUREMENTS.md, in order, each with its cores, its
# memory cap, its timeout, and its data file under data/. The logs go to
# log/ (not committed). plot.py then draws every plot from data/.
#
#   ./run_all.sh                   every row, M1 to M12
#   ONLY="M2 M5" ./run_all.sh      the rows named
#
# Environment:
#   JULIA        the julia of this checkout (default ../../../usr/bin/julia)
#   VANILLA      a vanilla julia built at the base commit; M1 and M2 need it
#   GCBENCHMARKS a checkout of https://github.com/JuliaCI/GCBenchmarks; M1 needs it
#   CORE         the isolated core for the one-thread rows (default 29)
#   MTCORES      the cores of the multi-thread rows (default 24-31)
#   RTPRIO       the SCHED_FIFO priority for the latency rows when the machine
#                grants one (default 50); 0 turns it off
#
# A row runs under `systemd-run --user --scope -p MemoryMax=…` when systemd
# is present, under `timeout` always, and pinned with `taskset`. The
# latency rows (M3, M4, M6) take the real-time class when `chrt` grants it;
# the others never do: a FIFO thread that spins on one core starves the
# child process or the other threads of the same run.
set -uo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../../.. && pwd)
JULIA=${JULIA:-$ROOT/usr/bin/julia}
VANILLA=${VANILLA:-}
GCBENCHMARKS=${GCBENCHMARKS:-}
CORE=${CORE:-29}; MTCORES=${MTCORES:-24-31}; RTPRIO=${RTPRIO:-50}
ONLY=${ONLY:-M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 M12}
DATA=data; LOG=log
mkdir -p "$DATA" "$LOG"
SHA=$(git -C "$ROOT" rev-parse --short=10 HEAD)

# --- the context every plot cites -------------------------------------------
{
    printf '# key\tvalue\n'
    printf 'date\t%s\n' "$(date -u +%Y-%m-%d)"
    printf 'sha\t%s\n' "$SHA"
    printf 'julia\t%s\n' "$("$JULIA" --startup-file=no -e 'print(VERSION)')"
    [ -n "$VANILLA" ] && printf 'vanilla\t%s\n' "$("$VANILLA" --startup-file=no -e 'print(Base.GIT_VERSION_INFO.commit[1:10])')"
    printf 'host\t%s\n' "$(hostname)"
    printf 'cpu\t%s\n' "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//')"
    printf 'kernel\t%s\n' "$(uname -r)"
    printf 'core\t%s\n' "$CORE"
    printf 'mtcores\t%s\n' "$MTCORES"
    if [ "$RTPRIO" -gt 0 ] && chrt -f "$RTPRIO" true 2>/dev/null; then printf 'realtime\tSCHED_FIFO %s\n' "$RTPRIO"
    else printf 'realtime\tnone\n'; fi
} > "$DATA/context.tsv"

# --- the runner ---------------------------------------------------------------
STATUS=$LOG/status.tsv
printf '# row\tname\texit\tseconds\n' > "$STATUS"
want() { case " $ONLY " in *" $1 "*) return 0;; *) return 1;; esac; }
RT=""; if [ "$RTPRIO" -gt 0 ] && chrt -f "$RTPRIO" true 2>/dev/null; then RT="chrt -f $RTPRIO"; fi
SCOPE=""; command -v systemd-run >/dev/null && SCOPE="systemd-run --user --scope --quiet"

# run <row> <name> <MemoryMax> <timeout seconds> <cores> <rt: 0|1> <command...>
# stdout and stderr go to log/<name>.log; the exit code and the seconds to
# log/status.tsv. The command's own REGIONS_TSV is set by the caller.
run() {
    local row=$1 name=$2 mem=$3 tmo=$4 cores=$5 rt=$6; shift 6
    local pre="" t0 t1 rc
    [ "$rt" = 1 ] && pre="$RT"
    echo "[$row] $name: $*"
    t0=$(date +%s)
    if [ -n "$SCOPE" ]; then
        $SCOPE -p MemoryMax="$mem" timeout "$tmo" $pre taskset -c "$cores" "$@" > "$LOG/$name.log" 2>&1
    else
        timeout "$tmo" $pre taskset -c "$cores" "$@" > "$LOG/$name.log" 2>&1
    fi
    rc=$?; t1=$(date +%s)
    printf '%s\t%s\t%s\t%s\n' "$row" "$name" "$rc" "$((t1 - t0))" >> "$STATUS"
    [ $rc -ne 0 ] && echo "[$row] $name: exit $rc (see $LOG/$name.log)"
    return $rc
}
skip() { echo "[$1] skipped: $2"; printf '%s\tskipped\t-\t%s\n' "$1" "$2" >> "$STATUS"; }
fresh() { rm -f "$DATA/$1"; }
J="$JULIA --startup-file=no"

# --- M1: zero cost when unused ----------------------------------------------
if want M1; then
    if [ -z "$VANILLA" ] || [ -z "$GCBENCHMARKS" ]; then skip M1 "VANILLA and GCBENCHMARKS must be set"
    else
        fresh gcbench.tsv
        REGIONS_TSV=$DATA/gcbench.tsv CORE=$CORE MTCORES=$MTCORES \
            run M1 gcbench 16G 3600 0-31 0 bash ../bench/gcbench.sh "$VANILLA" "$JULIA" "$GCBENCHMARKS" 5
    fi
fi

# --- M2: unit costs -----------------------------------------------------------
# unit_costs.jl prints TSV rows itself; the two binaries are joined into one
# file with a first column that names the binary. No real-time class: the
# script waits for a child process.
if want M2; then
    fresh unit_costs.tsv
    printf '# binary\tcost\tvalue\tunit\n' > "$DATA/unit_costs.tsv"
    if [ -n "$VANILLA" ]; then
        run M2 unit_costs_vanilla 8G 900 "$CORE" 0 "$VANILLA" --startup-file=no ../bench/unit_costs.jl stock 5 \
            && grep -P '^\w+\t' "$LOG/unit_costs_vanilla.log" | sed 's/^/vanilla\t/' >> "$DATA/unit_costs.tsv"
    else echo "[M2] no VANILLA: the vanilla rows are missing"; fi
    run M2 unit_costs_regions 8G 900 "$CORE" 0 $J ../bench/unit_costs.jl 5 \
        && grep -P '^\w+\t' "$LOG/unit_costs_regions.log" | sed 's/^/regions\t/' >> "$DATA/unit_costs.tsv"
fi

# --- M3: the tail, one Bool apart -------------------------------------------
if want M3; then
    fresh tail.tsv
    for v in alloc pooled; do
        REGIONS_TSV=$DATA/tail.tsv run M3 yardstick_$v 8G 900 "$CORE" 1 $J ../bench/yardstick.jl $v 20000000
    done
    for v in baseline regions; do
        REGIONS_TSV=$DATA/tail.tsv run M3 tail_$v 8G 900 "$CORE" 1 $J ../bench/tail.jl $v 20000000
    done
fi

# --- M4: the real-world loop -----------------------------------------------
# realworld.sh pins, takes the real-time class, keeps the run with the fewest
# involuntary switches, and writes data/realworld.tsv and data/ccdf_*.tsv.
if want M4; then
    fresh realworld.tsv
    JULIA=$JULIA CORE=$CORE RTPRIO=$RTPRIO run M4 realworld 8G 5400 0-31 0 bash ./realworld.sh
fi

# --- M5: the census -----------------------------------------------------------
if want M5; then
    fresh census_pause.tsv; fresh census_throughput.tsv
    for K in 300 1000 3000 10000 30000 100000; do
        for v in scoped coop full; do
            REGIONS_TSV=$DATA/census_pause.tsv run M5 census_${v}_K$K 8G 900 "$CORE" 0 $J ../bench/census.jl $v 2000000 100000 $K
        done
    done
    for W in 3 200; do
        REGIONS_TSV=$DATA/census_throughput.tsv run M5 census_autopool_W$W 8G 900 "$CORE" 0 $J ../bench/census.jl autopool 5000000 100000 10000 $W
        for B in 1 100 1000; do
            REGIONS_TSV=$DATA/census_throughput.tsv run M5 census_batch_W${W}_B$B 8G 900 "$CORE" 0 $J ../bench/census.jl batch 5000000 100000 10000 $W $B
        done
        REGIONS_TSV=$DATA/census_throughput.tsv run M5 census_pooled_W$W 8G 900 "$CORE" 0 $J ../bench/census.jl pooled 5000000 100000 10000 $W
    done
fi

# --- M6: paced, and the endurance run ----------------------------------------
if want M6; then
    fresh paced.tsv; fresh endurance.tsv
    REGIONS_TSV=$DATA/paced.tsv run M6 paced_baseline 8G 900 "$CORE" 1 $J --heap-size-hint=128M ../bench/paced.jl baseline 1000000
    REGIONS_TSV=$DATA/paced.tsv run M6 paced_regions 8G 900 "$CORE" 1 $J ../bench/paced.jl regions 1000000
    REGIONS_TSV=$DATA/endurance.tsv run M6 endurance 8G 2700 "$CORE" 1 $J ../bench/endurance.jl 18000000
fi

# --- M7: region-native against C++ -------------------------------------------
if want M7; then
    fresh native.tsv
    g++ -O2 -std=c++17 -o "$LOG/native" ../bench/native.cpp || echo "[M7] g++ failed"
    for W in 3 200; do
        REGIONS_TSV=$DATA/native.tsv run M7 native_region_W$W 8G 900 "$CORE" 0 $J ../bench/native.jl region 5000000 100000 $W
        REGIONS_TSV=$DATA/native.tsv run M7 native_stock_W$W 8G 900 "$CORE" 0 $J ../bench/native.jl stock 5000000 100000 $W
        [ -x "$LOG/native" ] && REGIONS_TSV=$DATA/native.tsv run M7 native_cpp_W$W 8G 900 "$CORE" 0 "$LOG/native" 5000000 $W
    done
fi

# --- M8: wholesale death, the showcases ---------------------------------------
# Three rounds, the binaries' modes alternating; plot.py keeps the minimum.
if want M8; then
    fresh showcase.tsv
    for r in 1 2 3; do
        for m in stock region; do
            REGIONS_TSV=$DATA/showcase.tsv run M8 showcase_binarytree_${m}_$r 8G 900 "$CORE" 0 $J ../demo/showcase_binarytree.jl $m 18
            REGIONS_TSV=$DATA/showcase.tsv run M8 showcase_linkedlist_${m}_$r 16G 900 "$CORE" 0 $J ../demo/showcase_linkedlist.jl $m 64
        done
        REGIONS_TSV=$DATA/showcase.tsv run M8 showcase_tree_$r 8G 900 "$MTCORES" 0 $J -t 4 ../demo/showcase_tree.jl
    done
fi

# --- M9: the growth bound -------------------------------------------------------
if want M9; then
    fresh census_bound.tsv
    REGIONS_TSV=$DATA/census_bound.tsv run M9 census_bound 8G 600 "$CORE" 0 $J ../bench/census_bound.jl
fi

# --- M10: the demonstrators ---------------------------------------------------
if want M10; then
    fresh demo_a.tsv; fresh demo_b.tsv; fresh demo_c.tsv; fresh demo_d.tsv
    REGIONS_TSV=$DATA/demo_a.tsv run M10 demo_a 8G 1800 "$CORE" 0 $J ../demo/bt_solver.jl
    REGIONS_TSV=$DATA/demo_b.tsv run M10 demo_b 8G 1800 "$MTCORES" 0 $J -t 4 ../demo/pathtrace.jl
    REGIONS_TSV=$DATA/demo_c.tsv run M10 demo_c 8G 1800 "$MTCORES" 0 $J -t 4 ../demo/optimistic_bst.jl
    REGIONS_TSV=$DATA/demo_d.tsv run M10 demo_d 8G 1800 "$MTCORES" 0 $J -t 4 ../demo/dmr.jl
fi

# --- M11: the discipline checker --------------------------------------------
# The hooked compiler is built once into log/regionck; a julia whose
# Compiler the patch does not fit skips the row and says so.
if want M11; then
    fresh checker.tsv
    if python3 ../tools/hook_patch.py "$LOG/regionck" "$JULIA" > "$LOG/hook_patch.log" 2>&1; then
        printf '# model\tevents\tviolations\tsites\n' > "$DATA/checker.tsv"
        for m in alloc clean; do
            JULIA_LOAD_PATH="$LOG/regionck/env:@stdlib" run M11 checker_$m 8G 900 "$CORE" 0 $J ../tools/checker_run.jl $m 100000 \
                && awk -v m=$m '/^violations: /{printf "%s\t100000\t%s\t%s\n", m, $2, $5}' "$LOG/checker_$m.log" >> "$DATA/checker.tsv"
        done
    else skip M11 "hook_patch.py does not apply to this julia (log/hook_patch.log)"; fi
fi

# --- M12: thread scaling of the sibling leaves ------------------------------
# The only row that leaves the isolated core: it waits for a quiet machine
# (load average below 4) for up to 30 minutes.
if want M12; then
    fresh scaling.tsv
    waited=0
    while [ "$(awk '{print int($1)}' /proc/loadavg)" -ge 4 ] && [ $waited -lt 1800 ]; do sleep 60; waited=$((waited + 60)); done
    if [ "$(awk '{print int($1)}' /proc/loadavg)" -ge 4 ]; then skip M12 "load average stayed above 4"
    else
        for t in 1 2 4 8; do
            REGIONS_TSV=$DATA/scaling.tsv run M12 scaling_pathtrace_t$t 8G 1800 "$MTCORES" 0 $J -t $t ../demo/pathtrace.jl
            REGIONS_TSV=$DATA/scaling.tsv run M12 scaling_dmr_t$t 8G 1800 "$MTCORES" 0 $J -t $t ../demo/dmr.jl
        done
    fi
fi

echo "run_all: done; status in $STATUS"
awk -F'\t' 'NR > 1 && $3 != "0" && $3 != "-"' "$STATUS" | sed 's/^/failed: /'
