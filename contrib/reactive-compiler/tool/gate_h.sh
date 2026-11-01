#!/bin/bash
# Gate H of Stage H (plan/pending/robust-incremental-compiler.md), the
# second half: one rebuild of the routing sample driven by a client that
# has nothing of PackageCompiler but the link. The store of the omnet
# build is copied, the server is started by hand with
# `julia --reactive-server=<socket>` on the image of the last snapshot,
# `apply` (a spec written here) and `save` go over the socket, the overlay
# is linked by `_reactive_overlay_link`, and the binary shows the edit: the
# hop mean doubles. The first half of Gate H is Gates D, E and G unchanged
# through the runtime server; run them as they are.
# Needs: a store under $OMNET/build/routing with at least one rebuild
# (`bin/build_omnet_legacy_sample routing --reactive`, then one bare build).
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-h}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
OMNET=${OMNET:-$(cd "$JH/.." && pwd)/omnet-julia-m1}
LANE=${LANE:-16-23}
FILE=sample/legacy/routing/Routing.jl
COPY=$OUT/routing
STORE=$COPY/reactive-store
SOCK=/tmp/jlrc-gate-h-$$.sock
export PATH=$JH/usr/bin:$PATH JULIA_IMAGE_THREADS=${THREADS:-8}
mkdir -p "$OUT"
run() { # $1 = a tag: the hop mean of a Backbone run of the copy's binary
    rm -rf "$OUT/run-$1"; mkdir -p "$OUT/run-$1"
    ( cd "$OUT/run-$1" && timeout 300 nice -n 10 taskset -c "$LANE" "$COPY/bin/routing" \
          -f "$OMNET/sample/legacy/routing/ned/omnetpp.ini" -c Backbone > "$OUT/run-$1.log" 2>&1 ) || { echo "=== run $1 failed"; return 1; }
    grep -A 2 'statistic Backbone.node\[0\].app hopCount' "$OUT/run-$1/results/Backbone-#0.sca" | grep 'field mean' | awk '{print $3}'
}
req() { python3 - "$SOCK" "$*" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1]); s.sendall((sys.argv[2] + "\n").encode())
r = b""
while True:
    c = s.recv(4096)
    if not c: break
    r += c
print(r.decode().strip())
PY
}
restore() { git -C "$OMNET" checkout -- "$FILE" && echo "=== restored $FILE"; }
fail() { echo "=== $1"; req quit > /dev/null 2>&1; restore; exit 1; }

[ -d "$OMNET/build/routing/reactive-store" ] || fail "no store under $OMNET/build/routing"
rm -rf "$COPY"; cp -a "$OMNET/build/routing" "$COPY" || fail "the copy failed"
last=$(ls -d "$STORE"/s[0-9]* | sed 's|.*/s||' | sort -n | tail -1); next=$((last + 1))
echo "=== copied the store: last snapshot s$last"
# The edit goes one above the increment of the last snapshot's copy of the
# file (the working file may differ from it): the hop mean scales with it.
n=$(grep -c "packet.hop_count += [0-9]*" "$OMNET/$FILE"); [ "$n" = 1 ] || fail "the edit does not apply: $n occurrences"
copy=$(ls "$STORE/s$last/source/"*-Routing.jl | head -1)
k=$(grep -o "packet.hop_count += [0-9]*" "$copy" | grep -o "[0-9]*$"); [ -n "$k" ] || fail "no increment in $copy"
k1=$((k + 1))
sed -i "s/packet\.hop_count += [0-9]*/packet.hop_count += $k1/" "$OMNET/$FILE" && echo "=== edited $FILE: hop_count += $k1 (the snapshot has $k)"
before=$(run before) || fail "the run before the edit failed"; echo "=== hops(before): $before"
args=$(python3 -c "import re,sys; t=open(sys.argv[1]).read(); print(' '.join(re.findall(r'\"(-[^\"]+)\"', re.search(r'sysimage_build_args = \[([^\]]*)\]', t).group(1))))" "$STORE/store.toml")
rm -f "$SOCK"
( timeout 900 nice -n 10 taskset -c "$LANE" julia --startup-file=no --pkgimages=no \
      --cpu-target=native $args --sysimage="$COPY/lib/julia/sys.so" --project="$OMNET/build/app/routing" \
      --output-o="$STORE/server.a" --threads=1 --reactive-reuse --reactive-image=overlay \
      --reactive-server="$SOCK" > "$OUT/server.log" 2>&1 & )
for i in $(seq 1 240); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || fail "the server did not listen; see $OUT/server.log"
echo "=== status: $(req status)"
mkdir -p "$STORE/s$next"
python3 - "$STORE" "$last" "$next" <<'PY' || fail "the spec was not written"
import re, sys, os
store, last, nxt = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(os.path.join(store, "store.toml")).read()
files = re.findall(r'^\s*file = "([^"]+)"', text, re.M)
roots = re.findall(r'^\s*root = "([^"]*)"', text, re.M)
assert len(files) == len(roots) and files, (len(files), len(roots))
copies = [os.path.join(store, "s" + last, "source", f"{i + 1}-{os.path.basename(f)}") for i, f in enumerate(files)]
for c in copies: assert os.path.isfile(c), c
def arr(xs): return "[" + ", ".join('"' + x + '"' for x in xs) + "]"
open(os.path.join(store, "s" + nxt, "spec.toml"), "w").write(f'''old_files = {arr(files)}
old_roots = {arr(roots)}
old_copies = {arr(copies)}
files = {arr(files)}
roots = {arr(roots)}
old_reads = "{store}/s{last}/reads.txt"
reads_out = "{store}/s{nxt}/reads.txt"
refusal_out = "{store}/s{nxt}/refusal.txt"
trace = "{store}/trace.jl"
''')
print("=== spec written:", len(files), "tracked files")
PY
reply=$(req apply "$STORE/s$next/spec.toml"); echo "=== apply: $reply"; [ "$reply" = ok ] || fail "the apply was not ok"
t0=$(date +%s.%N); reply=$(req save "$STORE/s$next/delta.a"); echo "=== save: $reply in $(echo "$(date +%s.%N) - $t0" | bc) s"; [ "$reply" = ok ] || fail "the save was not ok"
timeout 300 nice -n 10 taskset -c "$LANE" julia --startup-file=no --project="$OMNET/environment/tool" -e "
using PackageCompiler
name = PackageCompiler._reactive_overlay_link(\"$COPY\", \"$STORE/s$next/delta.a\", $next)
PackageCompiler._reactive_chain_update(\"$COPY\", name, \"\")
println(\"=== linked \", name, \"; chain: \", join(readlines(\"$COPY/lib/julia/sys.so.chain\"), \" \"))" 2>&1 | grep "^===\|ERROR"
after=$(run after) || fail "the run after the edit failed"; echo "=== hops(after): $after"
echo "=== quit: $(req quit)"
restore
python3 - "$before" "$after" "$k" "$k1" <<'PY'
import sys
b, a, k, k1 = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
ok = abs(a - b * k1 / k) < 1e-6
print(f"=== hops(after) {a} {'is' if ok else 'IS NOT'} {k1}/{k} x {b}")
sys.exit(0 if ok else 1)
PY
status=$?
echo "=== done $(date +%T)"
exit $status
