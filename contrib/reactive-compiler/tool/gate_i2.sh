#!/bin/bash
# Gate I2 of Stage I (plan/pending/robust-incremental-compiler.md): the IDE
# store of omnet-julia rebuilds a few seconds after a change in the platform
# package of projectured-julia. It runs in a folder that holds worktrees of
# omnet-julia, projectured-julia and PackageCompiler.jl side by side, so that
# omnet-julia's relative paths reach them, and it edits the projectured
# worktree only. The store must exist: `bin/build_omnet_ide --reactive` in the
# omnet worktree founds it.
#   edit       - get_scroll_layout_cell of the layout slice counts by 4, not 3
#   rebuild    - the bare bin/build_omnet_ide, timed
#   check-4    - the image answers (1, 2) for index 5
#   revert     - git restores the file
#   rebuild    - again
#   check-3    - the image answers (2, 2)
#   watch      - the same edit and revert through `bin/build_omnet_ide --watch`:
#                the time from the save to the rebuilt image
#   stop       - the server of the store stops: the next rebuild starts one,
#                the way a rebuild on demand does
# Pass step names to run some steps, or nothing to run all of them in order.
# Run the gate under bounded-run: the steps take no cap of their own.
set -u
FOLDER=${FOLDER:-/home/projectured/workspace/reactive-dependencies}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
OUT=${OUT:-$FOLDER/log/gate-i2}
LANE=${LANE:-16-23}
OMNET=$FOLDER/omnet-julia
PROJECTURED=$FOLDER/projectured-julia
FILE=source/platform/layout/LayoutDocument.jl
IMAGE=$OMNET/build/omnet_ide/lib/julia/sys.so
export PATH=$JH/usr/bin:$PATH
export JULIA_DEPOT_PATH="$FOLDER/depot:$HOME/.julia:" JULIA_IMAGE_THREADS=${THREADS:-8}
export JULIA_REACTIVE_TIMINGS=1 DISPLAY=${DISPLAY:-:0}
mkdir -p "$OUT"

# The seconds since $1, a `date +%s.%N`.
elapsed() { awk -v a="$1" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }'; }

edit() {
    sed -i 's/^get_scroll_layout_cell(index::Integer) = (mod1(index, 3), div(index - 1, 3) + 1)$/get_scroll_layout_cell(index::Integer) = (mod1(index, 4), div(index - 1, 4) + 1)/' "$PROJECTURED/$FILE"
    grep -q "mod1(index, 4)" "$PROJECTURED/$FILE" && echo "=== edit: get_scroll_layout_cell counts by 4 at $(date +%T.%N | cut -c1-12)"
}
revert() { git -C "$PROJECTURED" checkout -- "$FILE" && echo "=== revert: $FILE restored at $(date +%T.%N | cut -c1-12)"; }
stop() { (cd "$OMNET" && bin/build_omnet_ide --stop-server) > "$OUT/stop.log" 2>&1; echo "=== stop: $(tail -1 "$OUT/stop.log")"; }

rebuild() {
    local name=$1 start
    start=$(date +%s.%N)
    (cd "$OMNET" && nice -n 10 taskset -c "$LANE" bin/build_omnet_ide) > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc: $(elapsed $start) s from the command to the image"
    grep -E "rc: applied|rc: refuse|rc: new|reactive: delta|cone|materialize_app" "$OUT/$name.log" | head -6
    return $rc
}

# $1 = the expected answer for index 5.
check() {
    local got
    got=$(julia --startup-file=no -J "$IMAGE" -e '
        P = Base.loaded_modules[Base.PkgId(Base.UUID("b21cb890-5227-4e91-ae0e-8ab4d844f9f7"), "ProjecturedPlatform")]
        print(P.LayoutModule.get_scroll_layout_cell(5))' 2>&1 | tail -1)
    if [ "$got" == "$1" ]; then echo "=== check: the image answers $got"; else echo "=== check: the image answers $got, not $1"; return 1; fi
}

# $1 = a pattern, $2 = how many lines of it the log must hold.
await() {
    timeout 600 bash -c "until n=\$(grep -c '$1' '$OUT/watch.log' 2>/dev/null); [ \"\${n:-0}\" -ge $2 ]; do sleep 0.2; done"
}

watch() {
    (cd "$OMNET" && exec nice -n 10 taskset -c "$LANE" bin/build_omnet_ide --watch) > "$OUT/watch.log" 2>&1 &
    local pid=$!
    await "watch: .* tracked files" 1 || { echo "=== watch: did not start"; kill -INT $pid; return 1; }
    grep -E "watch: .* tracked files" "$OUT/watch.log" | sed 's/^/=== /'
    sleep 2
    local saved
    edit; saved=$(date +%s.%N)
    await "watch: rebuilt in\|rebuild failed" 1 || { echo "=== watch: no rebuild"; kill -INT $pid; return 1; }
    echo "=== watch: $(elapsed $saved) s from the save to the rebuilt image"
    grep -E "watch: (rebuilt|the rebuild failed)" "$OUT/watch.log" | sed 's/^/=== /'
    check "(1, 2)" || { kill -INT $pid; return 1; }
    revert; saved=$(date +%s.%N)
    await "watch: rebuilt in\|rebuild failed" 2 || { echo "=== watch: no second rebuild"; kill -INT $pid; return 1; }
    echo "=== watch: $(elapsed $saved) s from the save to the rebuilt image"
    grep -E "watch: (rebuilt|the rebuild failed)" "$OUT/watch.log" | tail -1 | sed 's/^/=== /'
    check "(2, 2)"
    local rc=$?
    kill -INT $pid; wait $pid 2>/dev/null
    return $rc
}

steps=${*:-edit rebuild check-4 revert rebuild-back check-3 watch}
for step in $steps; do
    case $step in
        edit) edit ;;
        rebuild) rebuild rebuild ;;
        check-4) check "(1, 2)" ;;
        revert) revert ;;
        rebuild-back) rebuild rebuild-back ;;
        check-3) check "(2, 2)" ;;
        watch) watch ;;
        stop) stop ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; revert >/dev/null 2>&1; exit 1; }
done
echo "=== done $(date +%T)"
