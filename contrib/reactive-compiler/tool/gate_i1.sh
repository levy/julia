#!/bin/bash
# Gate I1 of Stage I (plan/pending/robust-incremental-compiler.md): a store
# tracks the path packages of its Manifest. The application DepApp
# (tool/i1_dependency) loads the path package DepLib. The edits of the gate
# are a method body through a path constant, a body in a submodule, a new
# method, a module option that a rebuild refuses, and an edit whose parts
# the rebuild must apply in the load order: a type in DepLib with a method
# on it in DepApp, which the tracked list puts first, and in the root file of
# DepLib a `using` of a module that the include above it defines. The chain
# is compared with the founding of the final sources.
#   copy         - the packages into $OUT/src, where the gate edits them
#   found-chain  - materialize_app founds $OUT/chain/depapp with
#                  track_dependencies
#   tracked      - the store tracks the files of DepLib in their modules
#   run-s1       - the founded binary: leaf 3, inner 20, extra 1
#   edit         - leaf-after.jl and inner-after.jl replace their files
#   mat-s2       - the rebuild of the edit
#   run-s2       - the rebuilt binary: leaf 6, inner 40, extra 2
#   refuse       - a module option in DepLib: the rebuild refuses it (F1),
#                  and the binary is as it was
#   edit-order   - DepLib-order.jl, leaf-order.jl and app-order.jl replace
#                  their files, and added-order.jl is the new parts/added.jl
#   mat-s3       - the rebuild of the edit, in the load order
#   run-s3       - the rebuilt binary: also part 5, added 7
#   trace        - the workload under --trace-compile at the final sources
#   found-final  - materialize_app founds $OUT/final/depapp at those sources
#   run-final    - the founded binary: as run-s3
#   compare      - the four checks of the invariant: the method tables, the
#                  roots, the output, the globals
# Pass step names to run some steps, or nothing to run all of them in order.
# Run the gate under bounded-run: the steps take no cap of their own.
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-i1}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
JULIA=${JULIA:-$JH/usr/bin/julia}
PC=${PC:-$(cd "$JH/.." && pwd)/PackageCompiler.jl}
TOOL=$JH/contrib/reactive-compiler/tool
SRC=$OUT/src
THREADS=${THREADS:-4}
TIMINGS=${TIMINGS:-1}
LANE=${LANE:-16-23}
LIGHT=${LIGHT:-24-27}
CHAIN=$OUT/chain/depapp
FINAL=$OUT/final/depapp
mkdir -p "$OUT/depot"

# One run on the build lane. $1 = log name, $2.. = the command.
lane() {
    local name=$1; shift
    nice -n 10 taskset -c "$LANE" /usr/bin/time -v \
        env JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=$TIMINGS \
            JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" \
        "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed \(wall|Maximum resident|rc: (file|apply|applied|eval|new [0-9]|warning|removed|refuse)|reactive: delta|materialize_app|shape: |=== " "$OUT/$name.log"
    return $rc
}

# A light run outside the build lane: the oracle and the trace.
light() {
    local name=$1; shift
    taskset -c "$LIGHT" env JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" "$@" > "$OUT/$name.log" 2>&1
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
materialize_app("$SRC/DepApp", ARGS[1];
    workload = "$SRC/workload.jl",
    executables = ["depapp" => "julia_main"],
    track_dependencies = true,
    force = true,
    incremental = true,
    cpu_target = "native",
    sysimage_build_args = \`-O2 -g1\`)
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

# $1 = a tag, $2 = the bundle, $3 = the expected shape lines, "name=value ..."
runbin() {
    lane "run-$1" "$2/bin/depapp" || return 1
    local want got
    want=$(for pair in $3; do echo "shape: ${pair%%=*} = ${pair#*=}"; done; echo "shape: state = 0")
    got=$(grep "^shape: " "$OUT/run-$1.log")
    if [ "$want" == "$got" ]; then
        echo "=== run-$1: as expected"
    else
        echo "=== run-$1: not as expected"; diff <(echo "$want") <(echo "$got") | grep "^[<>]"
        return 1
    fi
}

copy() { rm -rf "$SRC" && cp -a "$TOOL/i1_dependency" "$SRC" && echo "=== copied the packages to $SRC"; }

tracked() {
    local store=$CHAIN/reactive-store/store.toml ok=0
    for pair in "DepLib/src/DepLib.jl=" "DepLib/src/parts/leaf.jl=DepLib" "DepLib/src/inner.jl=DepLib.Inner"; do
        local file=${pair%%=*} root=${pair#*=}
        if python3 - "$store" "$SRC/$file" "$root" <<'PY'
import sys, tomllib
config = tomllib.load(open(sys.argv[1], "rb"))["config"]
sys.exit(0 if any(e["file"] == sys.argv[2] and e["root"] == sys.argv[3] for e in config["tracked"]) else 1)
PY
        then echo "=== tracked: $file in \"$root\""
        else echo "=== tracked: $file in \"$root\" is missing"; ok=1
        fi
    done
    return $ok
}

edit() {
    cp "$TOOL/i1_dependency/leaf-after.jl" "$SRC/DepLib/src/parts/leaf.jl" &&
    cp "$TOOL/i1_dependency/inner-after.jl" "$SRC/DepLib/src/inner.jl" &&
    echo "=== edited leaf.jl and inner.jl of DepLib"
}

# The rebuild must fail with the refusal F1, and leave the binary as it was.
refuse() {
    cp "$TOOL/i1_dependency/DepLib-optlevel.jl" "$SRC/DepLib/src/DepLib.jl"
    if mat mat-refused "$CHAIN"; then
        echo "=== refuse: the rebuild of a module option passed"; return 1
    fi
    grep -q "F1" "$OUT/mat-refused.log" || { echo "=== refuse: no F1 in the log"; return 1; }
    echo "=== refuse: the rebuild refused the module option (F1)"
    cp "$TOOL/i1_dependency/DepLib/src/DepLib.jl" "$SRC/DepLib/src/DepLib.jl"
    runbin s2-after-refusal "$CHAIN" "leaf=6 inner=40 extra=2"
}

edit_order() {
    cp "$TOOL/i1_dependency/DepLib-order.jl" "$SRC/DepLib/src/DepLib.jl" &&
    cp "$TOOL/i1_dependency/leaf-order.jl" "$SRC/DepLib/src/parts/leaf.jl" &&
    cp "$TOOL/i1_dependency/added-order.jl" "$SRC/DepLib/src/parts/added.jl" &&
    cp "$TOOL/i1_dependency/app-order.jl" "$SRC/DepApp/src/app.jl" &&
    echo "=== edited DepLib.jl, leaf.jl and app.jl, added parts/added.jl"
}

trace() {
    light trace-warm "$JULIA" --startup-file=no --project="$SRC/DepApp" "$SRC/workload.jl" || return 1
    light trace "$JULIA" --startup-file=no --project="$SRC/DepApp" \
        --trace-compile="$OUT/trace.jl" "$SRC/workload.jl" || return 1
    echo "=== trace: $(grep -c '^precompile' "$OUT/trace.jl") statements"
}

oracle() {
    light "oracle-$1" "$JULIA" --startup-file=no -J "$2/lib/julia/sys.so" "$TOOL/oracle.jl" \
        --tracked DepApp,DepLib --trace "$OUT/trace.jl" || return 1
    grep "^info" "$OUT/oracle-$1.log" | sed "s/^/=== $1 /"
}

# $1 = the check number, $2 = its name, $3 = the pattern of the lines,
# $4 $5 = the files.
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
    return 1
}

compare() {
    oracle chain "$CHAIN" && oracle final "$FINAL" || return 1
    local failed=0
    check 1 "method tables" "^method " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    check 2 "roots" "^root " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    check 3 "output" "^shape: " "$OUT/run-s3.log" "$OUT/run-final.log" || failed=1
    check 4 "globals" "^global " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    return $failed
}

steps=${*:-copy found-chain tracked run-s1 edit mat-s2 run-s2 refuse edit-order mat-s3 run-s3 trace found-final run-final compare}
for step in $steps; do
    case $step in
        copy) copy ;;
        found-chain) rm -rf "$OUT/chain" && mat mat-chain "$CHAIN" ;;
        tracked) tracked ;;
        run-s1) runbin s1 "$CHAIN" "leaf=3 inner=20 extra=1" ;;
        edit) edit ;;
        mat-s2) mat mat-s2 "$CHAIN" ;;
        run-s2) runbin s2 "$CHAIN" "leaf=6 inner=40 extra=2" ;;
        refuse) refuse ;;
        edit-order) edit_order ;;
        mat-s3) mat mat-s3 "$CHAIN" ;;
        run-s3) runbin s3 "$CHAIN" "leaf=6 inner=40 extra=2 part=5 added=7" ;;
        trace) trace ;;
        found-final) rm -rf "$OUT/final" && mat mat-final "$FINAL" ;;
        run-final) runbin final "$FINAL" "leaf=6 inner=40 extra=2 part=5 added=7" ;;
        compare) compare ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
