#!/bin/bash
# The gate of the constant data of an overlay (Step 1 of
# plan/pending/a-rebuild-equals-a-whole-build.md): an overlay holds each write
# of a rebuild into the constant data of the base image. The constant data
# holds the bytes of the number tables of the image, and it starts at a cache
# line, not at a page limit. The application is DepApp of gate I1
# (tool/i1_dependency) with a table of bytes in DepLib (tool/const_table).
# The edit adds a top-level statement that sets 64 bytes of the table, 8256
# bytes apart: each one is on a page of its own with no write on the page
# before it, and the 64 bytes are at 64 different places of a page.
#   copy    - the packages into $OUT/src, with the table
#   found   - materialize_app founds $OUT/app/depapp
#   run-s1  - the founded binary: table 0
#   edit    - leaf-table-after.jl replaces leaf.jl: the statement that marks
#   mat-s2  - the rebuild of the edit, written as an overlay
#   run-s2  - the rebuilt binary: table 64
#   check   - tool/overlay_check.py on the image and its overlay: no root
#             table and no key set of the two together is wrong
# Pass step names to run some steps, or nothing to run all of them in order.
# Run the gate under bounded-run: the steps take no cap of their own.
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-const}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
JULIA=${JULIA:-$JH/usr/bin/julia}
PC=${PC:-$(cd "$JH/.." && pwd)/PackageCompiler.jl}
TOOL=$JH/contrib/reactive-compiler/tool
SRC=$OUT/src
THREADS=${THREADS:-4}
TIMINGS=${TIMINGS:-1}
LANE=${LANE:-16-23}
APP=$OUT/app/depapp
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
    grep -E "Elapsed \(wall|Maximum resident|rc: (change|applied|refuse)|reactive: (overlay|pages)|materialize_app|shape: |=== " "$OUT/$name.log"
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

# $1 = log name, $2.. = assignments of the environment. A rebuild writes an
# overlay; a founding writes whole, whatever the variable says.
mat() {
    local name=$1; shift
    write_mat && lane "$name" env "$@" "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" "$APP"
}

# $1 = a tag, $2 = the expected shape lines, "name=value ..."
runbin() {
    lane "run-$1" "$APP/bin/depapp" || return 1
    local want got
    want=$(for pair in $2; do echo "shape: ${pair%%=*} = ${pair#*=}"; done; echo "shape: state = 0")
    got=$(grep "^shape: " "$OUT/run-$1.log")
    if [ "$want" == "$got" ]; then
        echo "=== run-$1: as expected"
    else
        echo "=== run-$1: not as expected"; diff <(echo "$want") <(echo "$got") | grep "^[<>]"
        return 1
    fi
}

copy() {
    rm -rf "$SRC" && cp -a "$TOOL/i1_dependency" "$SRC" &&
    cp "$TOOL/const_table/leaf-table.jl" "$SRC/DepLib/src/parts/leaf.jl" &&
    cp "$TOOL/const_table/app-table.jl" "$SRC/DepApp/src/app.jl" &&
    echo "=== copied the packages to $SRC, with the table"
}

edit() {
    cp "$TOOL/const_table/leaf-table-after.jl" "$SRC/DepLib/src/parts/leaf.jl" &&
    echo "=== edited leaf.jl of DepLib: the statement that marks the table"
}

# The overlay that the chain of the bundle names, checked with its image.
check() {
    local chain=$APP/lib/julia/sys.so.chain overlay
    [ -f "$chain" ] || { echo "=== check: no chain file $chain"; return 1; }
    overlay=$(grep -v '^#' "$chain" | grep . | tail -1)
    python3 -I "$TOOL/overlay_check.py" "$APP/lib/julia/sys.so" "$APP/lib/julia/$overlay" > "$OUT/check.log" 2>&1
    local rc=$?
    sed 's/^/=== check: /' "$OUT/check.log"
    return $rc
}

steps=${*:-copy found run-s1 edit mat-s2 run-s2 check}
for step in $steps; do
    case $step in
        copy) copy ;;
        found) rm -rf "$OUT/app" && mat mat-found ;;
        run-s1) runbin s1 "leaf=3 inner=20 extra=1 table=0" ;;
        edit) edit ;;
        mat-s2) mat mat-s2 JULIA_REACTIVE_IMAGE_WRITE=overlay ;;
        run-s2) runbin s2 "leaf=3 inner=20 extra=1 table=64" ;;
        check) check ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
