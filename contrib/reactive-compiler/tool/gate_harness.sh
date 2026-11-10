#!/bin/bash
# The gate of the harness that a rebuild runs (Step 4 of
# plan/pending/a-rebuild-equals-a-whole-build.md): a store whose image holds
# another harness than the client has is rebuilt with the sources of the
# client's harness, loaded into a module of their own, and the image of the
# rebuild holds no code of that module. The gate makes the two differ in each
# state of the tree: `JULIA_REACTIVE_HARNESS` names a copy of the sources of the
# harness with one more line. Gate I1 (tool/gate_i1.sh) then runs twice with it:
# through the server, and with a child for each rebuild.
#   harness       - the copy of the sources, with another print
#   server        - gate I1 with a server and overlays, in $OUT/server
#   server-check  - the server ran the program that loads the sources, the
#                   overlay holds no function of the harness, and
#                   tool/overlay_check.py finds no wrong entry
#   child         - gate I1 with overlays and no server, in $OUT/child
#   child-check   - the child loaded the sources, and the same two checks
#   standard      - gate I1 through a server and through a child with the
#                   sources of this tree, in $OUT/standard-server and
#                   $OUT/standard-child: when the image holds these sources, no
#                   rebuild loads them, and the step prints the size of each
#                   overlay beside the size with the loaded sources
#   stop          - the servers of the gate stop
# Pass step names to run some steps, or nothing to run all of them in order.
# Run the gate under bounded-run: the steps take no cap of their own.
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-harness}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
TOOL=$JH/contrib/reactive-compiler/tool
HARNESS=$OUT/harness
mkdir -p "$OUT"

harness() {
    rm -rf "$HARNESS" && mkdir -p "$HARNESS" &&
    cp "$JH"/stdlib/ReactiveCompiler/src/*.jl "$HARNESS/" &&
    echo "# The gate of the harness adds this line, so the print of these sources is another." >> "$HARNESS/server.jl" &&
    echo "=== harness: $(ls "$HARNESS" | wc -l) files in $HARNESS"
}

# $1 = the folder of the run, $2 = 1 for a server, $3 = the sources of the
# harness, or nothing for the sources of this tree
run_i1() {
    OUT="$OUT/$1" JH="$JH" JULIA_REACTIVE_HARNESS="${3:-$JH/stdlib/ReactiveCompiler/src}" \
        JULIA_REACTIVE_IMAGE_WRITE=overlay JULIA_REACTIVE_SERVER=$2 bash "$TOOL/gate_i1.sh" > "$OUT/$1.log" 2>&1
    local rc=$?
    grep -E "^=== |Elapsed \(wall" "$OUT/$1.log" | sed "s/^=== /=== $1: /"
    return $rc
}

# The last overlay of the chain of the run $1, and its size.
overlay_size() {
    local lib=$OUT/$1/chain/depapp/lib/julia
    stat -c %s "$lib/$(grep -v '^#' "$lib/sys.so.chain" | grep . | tail -1)"
}

# Gate I1 with the sources of this tree. A tree whose image holds other sources
# loads them here too; the step says which of the two it saw.
standard() {
    run_i1 standard-server 1 && run_i1 standard-child 0 || return 1
    local loaded=0
    [ -f "$OUT/standard-server/chain/depapp/reactive-store/serve.jl" ] && loaded=1
    grep -q "^rc_harness" "$(ls "$OUT"/standard-child/chain/depapp/reactive-store/s*/child.jl | tail -1)" && loaded=1
    if [ $loaded == 1 ]; then
        echo "=== standard: the image of this tree holds other sources than the tree, so the rebuilds loaded the sources"
    else
        echo "=== standard: the image holds the sources of this tree, and no rebuild loaded them"
    fi
    echo "=== standard: the overlay of the server has $(overlay_size standard-server) bytes, with loaded sources $(overlay_size server 2>/dev/null)"
    echo "=== standard: the overlay of the child has $(overlay_size standard-child) bytes, with loaded sources $(overlay_size child 2>/dev/null)"
    for run in standard-server standard-child server child; do
        [ -f "$OUT/$run/mat-s2.log" ] || continue
        echo "=== standard: $run rebuilds in$(grep -h "Elapsed (wall" "$OUT/$run/mat-s2.log" "$OUT/$run/mat-s3.log" | sed 's/.*: / /' | tr -d '\n') (s2, s3)"
    done
}

# The overlay of a chain, checked: no function of the harness, no wrong entry.
# $1 = "server" or "child"
check_overlay() {
    local lib=$OUT/$1/chain/depapp/lib/julia overlay functions
    overlay=$(grep -v '^#' "$lib/sys.so.chain" | grep . | tail -1)
    functions=$(nm "$lib/$overlay" | grep -c -E " [tT] (julia|jfptr|jlcapi)_rc_")
    echo "=== $1-check: $overlay has $(stat -c %s "$lib/$overlay") bytes and holds $functions functions of the harness"
    echo "=== $1-check: $overlay names the module of the loaded sources $(grep -a -o ReactiveHarness "$lib/$overlay" | wc -l) times"
    [ "$functions" == 0 ] || { nm "$lib/$overlay" | grep -E " [tT] (julia|jfptr|jlcapi)_rc_" | head -5; return 1; }
    python3 -I "$TOOL/overlay_check.py" "$lib/sys.so" "$lib/$overlay" > "$OUT/$1-overlay.log" 2>&1 ||
        { echo "=== $1-check: the overlay has wrong entries"; sed 's/^/    /' "$OUT/$1-overlay.log"; return 1; }
    echo "=== $1-check: $(tail -1 "$OUT/$1-overlay.log")"
}

server_check() {
    local store=$OUT/server/chain/depapp/reactive-store
    grep -q "ReactiveHarness" "$store/serve.jl" 2>/dev/null ||
        { echo "=== server-check: the store has no program of a server that loads the sources"; return 1; }
    grep -q "the server loads the harness of this Julia" "$OUT"/server/mat-s2.log ||
        { echo "=== server-check: the rebuild did not say that its server loads the sources"; return 1; }
    echo "=== server-check: the server ran $store/serve.jl"
    check_overlay server
}

child_check() {
    local script
    script=$(ls "$OUT"/child/chain/depapp/reactive-store/s*/child.jl | tail -1)
    grep -q "^rc_harness = let wrapper = Module(:ReactiveHarness)" "$script" ||
        { echo "=== child-check: $script does not load the sources"; return 1; }
    grep -q "^rc_harness.rc_remove_harness!()" "$script" ||
        { echo "=== child-check: $script does not remove the harness before the image"; return 1; }
    echo "=== child-check: the child ran $script"
    check_overlay child
}

stop() {
    local run
    for run in server standard-server; do
        [ -d "$OUT/$run/chain/depapp" ] || continue
        JULIA_DEPOT_PATH="$OUT/$run/depot:$HOME/.julia:" "${JULIA:-$JH/usr/bin/julia}" --startup-file=no \
            --project="$OUT/$run/compile-env" -e 'using PackageCompiler; PackageCompiler.stop_server(ARGS[1])' \
            "$OUT/$run/chain/depapp" >> "$OUT/stop.log" 2>&1
    done
    echo "=== stop: the servers of the gate are stopped"
}

steps=${*:-harness server server-check child child-check standard stop}
for step in $steps; do
    case $step in
        harness) harness ;;
        server) run_i1 server 1 "$HARNESS" ;;
        server-check) server_check ;;
        child) run_i1 child 0 "$HARNESS" ;;
        child-check) child_check ;;
        standard) standard ;;
        stop) stop ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; stop > /dev/null 2>&1; exit 1; }
done
echo "=== done $(date +%T)"
