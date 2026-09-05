#!/bin/bash
# The oracle gate of Stage 0 (plan/pending/robust-incremental-compiler.md):
# a chain of rebuilds against the founding of the final sources, on the
# HazardApp package (tool/m6_hazard). Two edits: shapes-after.jl, then
# shapes-after-2.jl, which changes `driver` alone, so that the third build
# calls `chained` of the second build's delta by its symbol.
#   found-chain  - materialize_app founds $OUT/chain/hazard at the sources S0
#   run-s1       - the founded binary
#   edit1        - shapes-after.jl replaces HazardApp/src/shapes.jl
#   mat-s2       - the rebuild of the first edit
#   run-s2       - the rebuilt binary
#   edit2        - shapes-after-2.jl replaces shapes.jl
#   mat-s3       - the rebuild of the second edit
#   run-s3       - the rebuilt binary; the last image of the chain
#   symbols      - the delta of s3 names `chained` of s2 as an undefined symbol
#   trace        - the workload under --trace-compile at the final sources:
#                  the roots of check 2
#   found-final  - materialize_app founds $OUT/final/hazard at the final sources
#   run-final    - the founded binary
#   restore      - git restores shapes.jl
#   compare      - the four checks of the invariant: the method tables, the
#                  roots, the output, the globals
# Pass step names to run some steps, or nothing to run all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/oracle}
JH=${JH:-/home/projectured/workspace/julia-reactive}
JULIA=$JH/usr/bin/julia
PC=${PC:-/home/projectured/workspace/package-compiler-reactive}
TOOL=$JH/contrib/reactive-compiler/tool
HZ=$TOOL/m6_hazard
THREADS=${THREADS:-8}
TIMINGS=${TIMINGS:-2}
LANE=${LANE:-16-23}
LIGHT=${LIGHT:-24-27}
CHAIN=$OUT/chain/hazard
FINAL=$OUT/final/hazard
FILE=HazardApp/src/shapes.jl
mkdir -p "$OUT/depot"

# One bounded run on the build lane. $1 = log name, $2.. = the command.
lane() {
    local name=$1; shift
    systemd-run --user --scope -q -p MemoryMax=24G -p MemorySwapMax=0 \
        nice -n 10 taskset -c "$LANE" \
        timeout 2400s /usr/bin/time -v \
        env JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=$TIMINGS \
            JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" \
        "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed \(wall|Maximum resident|rc: (file|apply|applied|eval|new [0-9]|warning|removed)|reactive: (delta|front|ccallable|[0-9]+ direct)|materialize_app|shape: (chained|state)|=== " "$OUT/$name.log"
    return $rc
}

# A light run outside the build lane: the oracle and the trace.
light() {
    local name=$1; shift
    timeout 600s taskset -c "$LIGHT" \
        env JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    return $rc
}

# mat.jl takes the bundle directory as its argument; the store inside it
# decides between a founding and a rebuild.
write_mat() {
    cat > "$OUT/mat.jl" <<EOF
import Pkg; Pkg.instantiate()
using PackageCompiler
materialize_app("$HZ/HazardApp", ARGS[1];
    tracked = ["$HZ/$FILE" => "HazardApp"],
    workload = "$HZ/workload.jl",
    executables = ["hazard" => "julia_main"],
    force = true,
    incremental = true,
    cpu_target = "native",
    sysimage_build_args = \`-O2 -g1\`,
    precompile_execution_file = "$HZ/workload.jl")
EOF
    mkdir -p "$OUT/compile-env"
    cat > "$OUT/compile-env/Project.toml" <<EOF
[deps]
PackageCompiler = "9b87118b-4619-50d2-8e1e-99f35a4d4d9d"

[sources]
PackageCompiler = {path = "$PC"}
EOF
}

mat() { write_mat && lane "$1" "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" "$2"; }
runbin() { lane "run-$1" "$2/bin/hazard"; }
edit() { cp "$HZ/$1" "$HZ/$FILE" && echo "=== $1 replaced $FILE"; }
restore() { git -C "$JH" checkout -- "contrib/reactive-compiler/tool/m6_hazard/$FILE" && echo "=== restored $FILE"; }

# The delta of s3 must name `chained` of s2 as an undefined symbol with the
# suffix of the second build, and the linked image must define it once.
symbols() {
    local undefined
    undefined=$(nm "$CHAIN"/reactive-store/s3/text*.o 2>/dev/null | grep -E " U .*chained" | sort -u)
    echo "=== s3 undefined: ${undefined:-none}"
    [ -n "$undefined" ] || { echo "=== the delta of s3 does not call chained of s2 by symbol"; return 1; }
    nm "$CHAIN/lib/julia/sys.so" | grep -E " [Tt] .*chained" | sed 's/^/=== image defines: /'
}

# The workload once to precompile the package, then once under
# --trace-compile: the roots without the noise of package precompilation.
trace() {
    light trace-warm "$JULIA" --startup-file=no --project="$HZ/HazardApp" "$HZ/workload.jl" || return 1
    light trace "$JULIA" --startup-file=no --project="$HZ/HazardApp" \
        --trace-compile="$OUT/trace.jl" "$HZ/workload.jl" || return 1
    echo "=== trace: $(grep -c '^precompile' "$OUT/trace.jl") statements, $(grep -c HazardApp "$OUT/trace.jl") of HazardApp"
}

oracle() {
    light "oracle-$1" "$JULIA" --startup-file=no -J "$2/lib/julia/sys.so" "$TOOL/oracle.jl" \
        --tracked HazardApp --trace "$OUT/trace.jl" || return 1
    grep "^info" "$OUT/oracle-$1.log" | sed "s/^/=== $1 /"
}

# $1 = the check number, $2 = its name, $3 = the pattern of the lines,
# $4 $5 = the files, $6 = the pattern of the lines that are expected to
# differ until Stage A: the state that the rebuild workloads leave in the
# heap. A difference of those lines alone is reported and does not fail.
check() {
    local a b lines n
    a=$(grep -E "$3" "$4"); b=$(grep -E "$3" "$5")
    if [ "$a" == "$b" ]; then
        echo "=== check $1 $2: equal ($(echo "$a" | grep -c .) lines)"
        return 0
    fi
    lines=$(diff <(echo "$a") <(echo "$b") | grep -E "^[<>]")
    n=$(echo "$lines" | grep -c .)
    echo "=== check $1 $2: $n lines differ (< chain, > founding)"
    echo "$lines" | head -20
    if [ -n "${6:-}" ] && ! echo "$lines" | grep -vqE "$6"; then
        echo "=== check $1 $2: the difference is the persisted state alone; expected until Stage A"
        return 0
    fi
    return 1
}

compare() {
    oracle chain "$CHAIN" && oracle final "$FINAL" || return 1
    local failed=0
    check 1 "method tables" "^method " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    check 2 "roots" "^root " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    grep -E "^root .*HazardApp" "$OUT/oracle-chain.log" | grep -vq " compiled$" &&
        { echo "=== check 2: a root of HazardApp is not compiled in the chain"; failed=1; }
    check 3 "output" "^shape: " "$OUT/run-s3.log" "$OUT/run-final.log" "shape: state = " || failed=1
    check 4 "globals" "^global " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" "HazardApp.FINALIZED = " || failed=1
    return $failed
}

steps=${*:-found-chain run-s1 edit1 mat-s2 run-s2 edit2 mat-s3 run-s3 symbols trace found-final run-final restore compare}
for step in $steps; do
    case $step in
        found-chain) rm -rf "$OUT/chain" && mat mat-chain "$CHAIN" ;;
        run-s1) runbin s1 "$CHAIN" ;;
        edit1) edit shapes-after.jl ;;
        mat-s2) mat mat-s2 "$CHAIN" ;;
        run-s2) runbin s2 "$CHAIN" ;;
        edit2) edit shapes-after-2.jl ;;
        mat-s3) mat mat-s3 "$CHAIN" ;;
        run-s3) runbin s3 "$CHAIN" ;;
        symbols) symbols ;;
        trace) trace ;;
        found-final) rm -rf "$OUT/final" && mat mat-final "$FINAL" ;;
        run-final) runbin final "$FINAL" ;;
        restore) restore ;;
        compare) compare ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
