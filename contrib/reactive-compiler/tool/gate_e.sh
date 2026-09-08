#!/bin/bash
# Gate E of Stage E (plan/pending/robust-incremental-compiler.md): the
# trimmed product through the edits, on tool/trim_app/TrimApp, a program
# that the stock trimmer accepts.
#   full     - the founding with `trim = on` (a child build): both bundles
#              run and print the sums of the original file
#   edits    - N edits through the server, the file alternating with
#              compute-after.jl: both bundles print the sums of the file,
#              the untrimmed image passes the oracle, the sizes are recorded
#   child    - one more edit through a child build: the same checks
#   dynamic  - compute-dynamic.jl makes a call site dynamic: the rebuild is
#              refused with the trimmer's reason, both bundles and the store
#              stay as they were
#   sizes    - the trimmed image against the untrimmed, and the last trimmed
#              against the first, within the residue of the slots
#   stop     - the server quits, the file is restored
# Pass step names to run some steps, or nothing to run all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/gate-e}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
JULIA=$JH/usr/bin/julia
TOOL=$JH/contrib/reactive-compiler/tool
PC=${PC:-/home/projectured/workspace/package-compiler-reactive}
TA=$TOOL/trim_app
PKG=$TA/TrimApp
FILE=$PKG/src/compute.jl
THREADS=${THREADS:-8}
TIMINGS=${TIMINGS:-1}
LANE=${LANE:-16-23}
LIGHT=${LIGHT:-24-27}
N=${N:-6}
APP=$OUT/trimapp
mkdir -p "$OUT/depot"

# One bounded run on the build lane. $1 = log name, $2 = 0|1 the server,
# $3.. = the command.
lane() {
    local name=$1 server=$2; shift 2
    systemd-run --user --scope -q -p MemoryMax=24G -p MemorySwapMax=0 \
        nice -n 10 taskset -c "$LANE" \
        timeout 2400s /usr/bin/time -v \
        env JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=$TIMINGS \
            JULIA_REACTIVE_SERVER=$server JULIA_REACTIVE_TRIM=on \
            JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" \
        "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed \(wall|Maximum resident|seconds = |Info: materialize_app|refused|Verifier|Trim verify|ERROR" "$OUT/$name.log" | head -12
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

write_mat() {
    cat > "$OUT/mat.jl" <<JL
import Pkg; Pkg.instantiate()
using PackageCompiler
materialize_app("$PKG", "$APP";
    tracked = ["$FILE" => "TrimApp"],
    workload = "$TA/workload.jl",
    executables = ["trimapp" => "julia_main"],
    force = true,
    incremental = true,
    cpu_target = "native",
    sysimage_build_args = \`-O2 -g1\`)
JL
    mkdir -p "$OUT/compile-env"
    cat > "$OUT/compile-env/Project.toml" <<TOML
[deps]
PackageCompiler = "9b87118b-4619-50d2-8e1e-99f35a4d4d9d"

[sources]
PackageCompiler = {path = "$PC"}
TOML
}

mat() { write_mat && lane "$1" "$2" "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl"; }

# The two bundles print the sums: $1 = a tag, $2 = original | after.
runboth() {
    local tag=$1 which=$2 total label failed=0
    if [ "$which" = original ]; then total=385; label=small; else total=770; label=large; fi
    for bundle in "$APP" "$APP/trimmed"; do
        local name=$tag-$(basename "$bundle")
        [ "$bundle" = "$APP" ] && name=$tag-untrimmed
        lane "run-$name" 0 "$bundle/bin/trimapp" > /dev/null || { echo "=== run-$name failed"; failed=1; continue; }
        if grep -q "^total: $total$" "$OUT/run-$name.log" && grep -q "^label: $label$" "$OUT/run-$name.log"; then
            echo "=== $name: total $total, label $label, as expected"
        else
            echo "=== $name: WRONG output:"; grep -E "^(total|label)" "$OUT/run-$name.log" | sed 's/^/===   /'
            failed=1
        fi
    done
    return $failed
}

loadable() { size "$1" | awk 'NR == 2 { print $4 }'; }
record() { local u t; u=$(loadable "$APP/lib/julia/sys.so"); t=$(loadable "$APP/trimmed/lib/julia/sys.so"); echo "$1 $u $t" >> "$OUT/sizes.txt"; echo "=== size $1: untrimmed $u, trimmed $t"; }

oracle() {
    light "oracle-$1" "$JULIA" --startup-file=no -J "$APP/lib/julia/sys.so" "$TOOL/oracle.jl" \
        --tracked TrimApp --trace "$APP/reactive-store/trace.jl" || return 1
    grep -q "^info dead 0 closed entries, 0 invalid" "$OUT/oracle-$1.log" || { echo "=== the image of $1 holds dead code"; return 1; }
    grep "^info" "$OUT/oracle-$1.log" | sed "s/^/=== $1 /"
}

edit_after() { cp "$TA/compute-after.jl" "$FILE" && echo "=== edited compute.jl: after"; }
edit_dynamic() { cp "$TA/compute-dynamic.jl" "$FILE" && echo "=== edited compute.jl: dynamic"; }
restore() { git -C "$JH" checkout -- "contrib/reactive-compiler/tool/trim_app/TrimApp/src/compute.jl" && echo "=== restored compute.jl"; }

full() {
    rm -rf "$APP" "$OUT/sizes.txt"
    restore
    mat mat-full 0 || return 1
    runboth full original || return 1
    record full
    oracle full
}

edits() {
    local k which
    for k in $(seq 1 "$N"); do
        if [ $((k % 2)) = 1 ]; then edit_after; which=after; else restore; which=original; fi
        mat "mat-edit-$k" 1 || return 1
        runboth "edit-$k" $which || return 1
        record "edit-$k"
        oracle "edit-$k" || return 1
    done
}

child() {
    local which
    if grep -q "n \* n \* 2" "$FILE"; then restore; which=original; else edit_after; which=after; fi
    mat mat-child 0 || return 1
    runboth child $which || return 1
    record child
    oracle child
}

dynamic() {
    local before after snapshots
    before=$(sha256sum "$APP/lib/julia/sys.so" "$APP/trimmed/lib/julia/sys.so" | awk '{print $1}' | tr '\n' ' ')
    snapshots=$(grep -c "^\[\[snapshot\]\]" "$APP/reactive-store/store.toml")
    edit_dynamic
    if mat mat-dynamic 1; then echo "=== the dynamic edit was NOT refused"; restore; return 1; fi
    grep -q "refused (T1)" "$OUT/mat-dynamic.log" || { echo "=== the failure is not the refusal T1"; restore; return 1; }
    echo "=== refused T1:"; grep -E "Verifier error|Trim verify" "$OUT/mat-dynamic.log" | head -4 | sed 's/^/===   /'
    restore
    after=$(sha256sum "$APP/lib/julia/sys.so" "$APP/trimmed/lib/julia/sys.so" | awk '{print $1}' | tr '\n' ' ')
    [ "$before" = "$after" ] || { echo "=== an image changed under the refusal"; return 1; }
    [ "$snapshots" = "$(grep -c "^\[\[snapshot\]\]" "$APP/reactive-store/store.toml")" ] || { echo "=== the store gained a snapshot under the refusal"; return 1; }
    echo "=== both images and the store unchanged"
}

sizes() {
    [ -f "$OUT/sizes.txt" ] || { echo "=== no sizes recorded"; return 1; }
    echo "=== sizes (tag untrimmed trimmed):"; sed 's/^/===   /' "$OUT/sizes.txt"
    # Two invariants of the trimmed product. Each trimmed image is a small
    # fraction of its untrimmed one. The founding and every server edit share
    # one base, so their trimmed images stay flat within the slot residue of
    # the chain; the `child` row is a no-server delta after the chain, and its
    # image carries the residue of the linked chain, which a founding resets,
    # so it is reported, not bounded here.
    awk '
        { u = $2; t = $3 }
        $1 == "child" { child = t; next }
        { if (min == 0 || t < min) min = t; if (t > max) max = t; founding_u = founding_u ? founding_u : u; if (t > u / 2) big = 1 }
        END {
            printf "=== server chain: min %d, max %d, spread %d; child %d\n", min, max, max - min, child
            if (big) { print "=== a trimmed image is not below half of the untrimmed"; exit 1 }
            if (max - min > 65536) { print "=== the server chain grew beyond the slot residue (64 KB)"; exit 1 }
            if (child > founding_u / 2) { print "=== the child image is not below half of the untrimmed"; exit 1 }
        }' "$OUT/sizes.txt"
}

stop() {
    [ -f "$APP/reactive-store/server.toml" ] && echo "=== quit: $(python3 "$TOOL/server_request.py" "$APP" quit 2>&1)"
    restore
}

steps=${*:-full edits child dynamic sizes stop}
for step in $steps; do
    case $step in
        full) full ;;
        edits) edits ;;
        child) child ;;
        dynamic) dynamic ;;
        sizes) sizes ;;
        stop) stop ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; python3 "$TOOL/server_request.py" "$APP" quit 2>/dev/null; restore; exit 1; }
done
echo "=== done $(date +%T)"
