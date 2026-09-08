#!/bin/bash
# Gate D of Stage D (plan/pending/robust-incremental-compiler.md): ten
# routing edits in a row through the compiler server. The seconds of every
# materialize_app (apply, save, link) against the bound; the hop mean of
# every image; the resident size of the server after ten saves; a restart
# from image k gives the image of edit k+1 that the server gives, by the
# oracle; every image passes the oracle.
#   full     - the founding of the routing sample into $OUT/routing (a child
#              build), and the first run
#   edits    - edit k, k = 1..N: `packet.hop_count += <k>` becomes `+= <k+1>`;
#              the rebuild through the server; the run: hop mean (k+1) times
#              the mean of the founding; the image copied to sys-<k>.so; at
#              k = RESTART a copy of the bundle is kept for the restart step
#   restart  - the copy of the bundle after save RESTART, rebuilt by a child
#              from its image with edit RESTART+1; its oracle against the
#              oracle of the server's image RESTART+1: checks 1, 2 and 4
#   oracle   - every image: `info dead 0` and `shadowed 0`
#   memory   - the status of the server after the edits: the resident size
#   stop     - the server quits, the file is restored
# Pass step names to run some steps, or nothing to run all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/gate-d}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
TOOL=$JH/contrib/reactive-compiler/tool
OMNET=${OMNET:-/home/projectured/workspace/omnet-julia-m1}
THREADS=${THREADS:-8}
TIMINGS=${TIMINGS:-1}
LANE=${LANE:-16-23}
LIGHT=${LIGHT:-24-27}
N=${N:-10}
RESTART=${RESTART:-5}
BOUND=${BOUND:-4}
APP=$OUT/routing
FILE=sample/legacy/routing/Routing.jl
TRACKED="OmnetRunner,OmnetLegacyFormat,OmnetLegacyRouting"
BUILD="bin/build_omnet_legacy_sample routing --reactive"
mkdir -p "$OUT/depot"

# One bounded run on the build lane. $1 = log name, $2 = 0|1 the server,
# $3.. = the command.
lane() {
    local name=$1 server=$2; shift 2
    systemd-run --user --scope -q -p MemoryMax=24G -p MemorySwapMax=0 \
        nice -n 10 taskset -c "$LANE" \
        timeout 2400s /usr/bin/time -v \
        env PATH="$JH/usr/bin:$PATH" \
            JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=$TIMINGS \
            JULIA_REACTIVE_SERVER=$server \
            JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" \
        "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed \(wall|Maximum resident|seconds = |rc: (applied|new [0-9]|trace)|reactive: (delta|save|heap|front)|the server|ERROR|Error" "$OUT/$name.log" | head -20
    return $rc
}

light() {
    local name=$1; shift
    timeout 600s taskset -c "$LIGHT" \
        env JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    return $rc
}

build() { local name=$1 server=$2 app=$3; ( cd "$OMNET" && lane "$name" "$server" $BUILD --output="$app" ); }

# The run of a bundle: $1 = a tag, $2 = the bundle; prints the hop mean.
runsim() {
    rm -rf "$OUT/run-$1"; mkdir -p "$OUT/run-$1"
    ( cd "$OUT/run-$1" && lane "runsim-$1" 0 "$2/bin/routing" \
          -f "$OMNET/sample/legacy/routing/ned/omnetpp.ini" -c Backbone ) > /dev/null || return 1
    local sca="$OUT/run-$1/results/Backbone-#0.sca"
    grep -A 2 'statistic Backbone.node\[0\].app hopCount' "$sca" | grep 'field mean' | awk '{print $3}'
}

# $1 = the tag, $2 = the mean, $3 = the expected factor of the founding's mean
check_mean() {
    python3 - "$1" "$2" "$3" "$(cat "$OUT/mean-1.txt")" <<'PY'
import sys
tag, mean, factor, base = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
ok = abs(mean - factor * base) < 1e-6
print(f"=== hops({tag}): {mean} {'is' if ok else 'IS NOT'} {factor} x {base}")
sys.exit(0 if ok else 1)
PY
}

# The edit: the hop increment becomes $1.
edit() {
    local n
    n=$(grep -c "packet.hop_count += [0-9]*" "$OMNET/$FILE")
    [ "$n" = 1 ] || { echo "=== the edit does not apply: $n occurrences"; return 1; }
    sed -i "s/packet\.hop_count += [0-9]*/packet.hop_count += $1/" "$OMNET/$FILE"
    echo "=== edited $FILE: hop_count += $1"
}
restore() { git -C "$OMNET" checkout -- "$FILE" && echo "=== restored $FILE"; }

# The seconds of the materialize_app of a build log against the bound.
seconds() {
    local s
    s=$(grep -o "seconds = [0-9.]*" "$OUT/$1.log" | head -1 | awk '{print $3}')
    echo "$1 $s" >> "$OUT/seconds.txt"
    echo "=== $1: materialize_app $s s (bound $BOUND)"
}

oracle() {
    light "oracle-$1" "$JH/usr/bin/julia" --startup-file=no -J "$2" "$TOOL/oracle.jl" \
        --tracked "$TRACKED" --trace "$APP/reactive-store/trace.jl" || return 1
    grep "^info" "$OUT/oracle-$1.log" | sed "s/^/=== $1 /"
}

check() {
    local a b
    a=$(grep -E "$3" "$4"); b=$(grep -E "$3" "$5")
    if [ "$a" == "$b" ]; then
        echo "=== check $1 $2: equal ($(echo "$a" | grep -c .) lines)"
        return 0
    fi
    echo "=== check $1 $2: DIFFER"
    diff <(echo "$a") <(echo "$b") | head -20
    return 1
}

full() {
    rm -rf "$APP" "$OUT/seconds.txt" "$OUT"/sys-*.so "$OUT/routing-restart"
    restore
    build build-full 0 "$APP" || return 1
    local mean
    mean=$(runsim full "$APP") || return 1
    echo "$mean" > "$OUT/mean-1.txt"
    echo "=== hops(full): $mean"
    cp "$APP/lib/julia/sys.so" "$OUT/sys-0.so"
}

edits() {
    local k mean
    for k in $(seq 1 "$N"); do
        edit $((k + 1)) || return 1
        build "build-$k" 1 "$APP" || return 1
        seconds "build-$k"
        cp "$APP/lib/julia/sys.so" "$OUT/sys-$k.so"
        mean=$(runsim "$k" "$APP") || return 1
        check_mean "$k" "$mean" $((k + 1)) || return 1
        echo "=== status after save $k: $(python3 "$TOOL/server_request.py" "$APP" status)"
        if [ "$k" = "$RESTART" ]; then
            rm -rf "$OUT/routing-restart"
            cp -a "$APP" "$OUT/routing-restart"
            echo "=== the bundle after save $k is copied for the restart step"
        fi
    done
}

# A child rebuild from image RESTART with edit RESTART+1, against the
# server's image RESTART+1.
restart() {
    local k=$((RESTART + 1))
    [ -d "$OUT/routing-restart" ] || { echo "=== no copy of the bundle after save $RESTART"; return 1; }
    edit $((k + 1)) || return 1
    rm -f "$OUT/routing-restart/reactive-store/server.toml"
    build build-restart 0 "$OUT/routing-restart" || return 1
    seconds build-restart
    oracle restart "$OUT/routing-restart/lib/julia/sys.so" || return 1
    oracle server-$k "$OUT/sys-$k.so" || return 1
    local failed=0
    check 1 "method tables" "^method " "$OUT/oracle-restart.log" "$OUT/oracle-server-$k.log" || failed=1
    check 2 "roots" "^root " "$OUT/oracle-restart.log" "$OUT/oracle-server-$k.log" || failed=1
    check 4 "globals" "^global " "$OUT/oracle-restart.log" "$OUT/oracle-server-$k.log" || failed=1
    local mean
    mean=$(runsim restart "$OUT/routing-restart") || return 1
    check_mean restart "$mean" $((k + 1)) || failed=1
    return $failed
}

oracles() {
    local k failed=0
    for k in $(seq 0 "$N"); do
        oracle "image-$k" "$OUT/sys-$k.so" || failed=1
        grep -q "^info dead 0 closed entries, 0 invalid" "$OUT/oracle-image-$k.log" || { echo "=== image $k holds dead code"; failed=1; }
        grep -q "^info shadowed 0 " "$OUT/oracle-image-$k.log" || { echo "=== image $k holds a shadowed method"; failed=1; }
    done
    return $failed
}

memory() {
    echo "=== status: $(python3 "$TOOL/server_request.py" "$APP" status)"
    echo "=== seconds of every rebuild (bound $BOUND):"; sed 's/^/===   /' "$OUT/seconds.txt"
    awk -v b="$BOUND" '$1 ~ /^build-[0-9]+$/ && $2 > b { over++ } END { if (over) { print "=== " over " rebuilds over the bound"; exit 1 } print "=== every rebuild within the bound" }' "$OUT/seconds.txt"
}

stop() {
    echo "=== quit: $(python3 "$TOOL/server_request.py" "$APP" quit)"
    restore
}

steps=${*:-full edits restart oracle memory stop}
for step in $steps; do
    case $step in
        full) full ;;
        edits) edits ;;
        restart) restart ;;
        oracle) oracles ;;
        memory) memory ;;
        stop) stop ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; python3 "$TOOL/server_request.py" "$APP" quit 2>/dev/null; restore; exit 1; }
done
echo "=== done $(date +%T)"
