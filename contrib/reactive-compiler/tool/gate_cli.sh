#!/bin/bash
# The gate of the command line (H3 of the plan): `julia -m PackageCompiler`
# on the routing store of the omnet build — status, a rebuild, a watch that
# rebuilds on a save and stops on Ctrl-C with its server, stop — and a
# founding and a rebuild of TrimApp from --package and --workload alone.
# Needs: a founded store under $OMNET/build/routing, and an environment that
# has PackageCompiler ($OMNET/environment/tool).
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-cli}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
OMNET=${OMNET:-$(cd "$JH/.." && pwd)/omnet-julia-m1}
LANE=${LANE:-16-23}
TA=$JH/contrib/reactive-compiler/tool/trim_app
FILE=sample/legacy/routing/Routing.jl
export PATH=$JH/usr/bin:$PATH JULIA_IMAGE_THREADS=${THREADS:-8}
PC="julia --startup-file=no --project=$OMNET/environment/tool -m PackageCompiler"
run() { nice -n 10 taskset -c "$LANE" timeout 900 $PC "$@"; }
# The rebuilds of this gate must stay rebuilds: a chain of several server
# generations can reach the growth of the compaction rule, and then a build
# founds again for minutes (and a Ctrl-C into that founding loses the store).
NOCOMPACT=--compact=1000,1.0
mkdir -p "$OUT"
failed=0
check() { if "$@"; then :; else echo "=== FAILED: $*"; failed=1; fi; }
cd "$OMNET"
echo "=== routing: status $(date +%T)"
check run status build/routing
k=$(grep -o "packet.hop_count += [0-9]*" "$FILE" | grep -o "[0-9]*$")
sed -i "s/packet\.hop_count += [0-9]*/packet.hop_count += $((k + 1))/" "$FILE"
echo "=== routing: build (a rebuild after an edit)"
run build build/routing $NOCOMPACT > "$OUT/build.log" 2>&1; echo "=== build exit $?"; check grep -q "snapshot s[0-9]* materialized" "$OUT/build.log"
grep -h "seconds = " "$OUT/build.log" | sed 's/^/===   /'
echo "=== routing: watch (a save, then Ctrl-C)"
( run watch build/routing $NOCOMPACT > "$OUT/watch.log" 2>&1 & )
for i in $(seq 1 600); do grep -q "watch: .* tracked files\|ERROR" "$OUT/watch.log" 2>/dev/null && break; sleep 1; done
check grep -q "watch: .* tracked files" "$OUT/watch.log"
sed -i "s/packet\.hop_count += [0-9]*/packet.hop_count += $((k + 2))/" "$FILE"
for i in $(seq 1 120); do grep -q "watch: rebuilt\|watch: the rebuild failed" "$OUT/watch.log" 2>/dev/null && break; sleep 1; done
check grep -q "watch: rebuilt in" "$OUT/watch.log"
# the watch is the julia started as `julia` through PATH: its argv begins with the bare name
W=$(pgrep -f "^julia .*-m PackageCompiler watch" | head -1)
[ -n "$W" ] && kill -INT "$W"
for i in $(seq 1 60); do [ -n "$W" ] && kill -0 "$W" 2>/dev/null || break; sleep 1; done
check grep -q "watch: stopped" "$OUT/watch.log"
check grep -q "watch: the compiler server was stopped" "$OUT/watch.log"
grep "watch:" "$OUT/watch.log" | sed 's/^/===   /'
echo "=== routing: stop (no server runs after the watch)"
run stop build/routing | sed 's/^/===   /'
git checkout -- "$FILE"
echo "=== trimapp: a founding from --package and --workload $(date +%T)"
rm -rf "$OUT/trimapp"; cp "$TA/TrimApp/src/compute.jl" "$OUT/compute.jl.orig"
run build "$OUT/trimapp" --package="$TA/TrimApp" --workload="$TA/workload.jl" --optimization=2 > "$OUT/found.log" 2>&1; echo "=== founding exit $?"
check grep -q "the store is founded" "$OUT/found.log"
check test "$("$OUT/trimapp/bin/TrimApp" 2>/dev/null | grep '^total')" = "total: 385"
cp "$TA/compute-after.jl" "$TA/TrimApp/src/compute.jl"
run build "$OUT/trimapp" --delta-opt=1 > "$OUT/rebuild.log" 2>&1; echo "=== rebuild exit $?"
check grep -q "snapshot s2 materialized" "$OUT/rebuild.log"
check test "$("$OUT/trimapp/bin/TrimApp" 2>/dev/null | grep '^total')" = "total: 770"
run stop "$OUT/trimapp" | sed 's/^/===   /'
echo "=== trimapp: a founding again, staged beside the app and swapped in $(date +%T)"
run build "$OUT/trimapp" --found > "$OUT/found2.log" 2>&1; echo "=== founding again exit $?"
check grep -q "the store founds again" "$OUT/found2.log"
check test ! -e "$OUT/trimapp.founding"
check test ! -e "$OUT/trimapp.old"
check test "$("$OUT/trimapp/bin/TrimApp" 2>/dev/null | grep '^total')" = "total: 770"
check test "$(ls -d "$OUT"/trimapp/reactive-store/s[0-9]* | wc -l)" = 1
echo "=== trimapp: a founding again killed in the middle: the old store must stay $(date +%T)"
# A founding of TrimApp takes about a minute; its log arrives late (Julia
# buffers stderr to a file), so the kill goes at a fixed delay into it.
( run build "$OUT/trimapp" --found > "$OUT/found3.log" 2>&1 & )
sleep 25
P=$(pgrep -f "^julia .*-m PackageCompiler build .*trimapp --found" | head -1)
if [ -n "$P" ]; then
    kids=$(pgrep -P "$P"); kill -9 "$P" $kids 2>/dev/null
    for k in $kids; do kill -9 $(pgrep -P "$k") 2>/dev/null; done
    echo "=== killed the founding $P and its children"
else
    echo "=== FAILED: no founding to kill"; failed=1
fi
sleep 2
check test -d "$OUT/trimapp.founding"
check test -f "$OUT/trimapp/reactive-store/store.toml"
cp "$OUT/compute.jl.orig" "$TA/TrimApp/src/compute.jl"
run build "$OUT/trimapp" > "$OUT/rebuild2.log" 2>&1; echo "=== rebuild after the kill exit $?"
check grep -q "snapshot s2 materialized" "$OUT/rebuild2.log"
check test "$("$OUT/trimapp/bin/TrimApp" 2>/dev/null | grep '^total')" = "total: 385"
run build "$OUT/trimapp" --found > "$OUT/found4.log" 2>&1; echo "=== founding again after the kill exit $?"
check test ! -e "$OUT/trimapp.founding"
check test "$("$OUT/trimapp/bin/TrimApp" 2>/dev/null | grep '^total')" = "total: 385"
run status "$OUT/trimapp" | sed 's/^/===   /'
run stop "$OUT/trimapp" | sed 's/^/===   /'
cp "$OUT/compute.jl.orig" "$TA/TrimApp/src/compute.jl"
[ $failed = 0 ] && echo "=== done $(date +%T)" || echo "=== a check failed $(date +%T)"
exit $failed
