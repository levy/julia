#!/bin/bash
# The gate of the server of a store (plan/pending/a-build-talks-to-its-own-server.md):
# a rebuild talks to the server that it starts, a founding stops the server
# of the store that it replaces, and the server log keeps its output. The
# application is DepApp of gate I1 (tool/i1_dependency). A decoy
# (tool/server_decoy.py) plays an older server: it answers `status` and
# `quit`, and an error to any other request.
#   copy      - the packages into $OUT/src
#   found     - materialize_app founds $OUT/app/depapp (a child build)
#   decoy     - a decoy on the socket path of the store, and no session file;
#               then a rebuild through the server. The rebuild passes, the
#               decoy gets `quit` and no `apply`, and the log starts with the
#               `listens` line of the server of the session
#   signal    - a rebuild through the server, then SIGTERM to the server: the
#               log still holds its `listens` line and the trace of the signal
#   founding  - a founding in the background; while it runs, a decoy starts
#               and a session file names it, as a rebuild from a terminal
#               does. The founding passes, and the decoy gets `quit`
#   stop      - the server of the store and every decoy stop
# Pass step names to run some steps, or nothing to run all of them in order.
# Run the gate under bounded-run: the steps take no cap of their own.
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-server}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
JULIA=${JULIA:-$JH/usr/bin/julia}
PC=${PC:-$(cd "$JH/.." && pwd)/PackageCompiler.jl}
TOOL=$JH/contrib/reactive-compiler/tool
SRC=$OUT/src
THREADS=${THREADS:-4}
LANE=${LANE:-16-23}
APP=$OUT/app/depapp
STORE=$APP/reactive-store
DEPOT="$OUT/depot:$HOME/.julia:"
mkdir -p "$OUT/depot"

# One run on the build lane. $1 = log name, $2.. = the command.
lane() {
    local name=$1; shift
    nice -n 10 taskset -c "$LANE" /usr/bin/time -v \
        env JULIA_IMAGE_THREADS=$THREADS JULIA_DEPOT_PATH="$DEPOT" "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed \(wall|Maximum resident|materialize_app|=== " "$OUT/$name.log"
    return $rc
}

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

# $1 = log name, $2 = the bundle, $3.. = assignments of the environment.
mat() {
    local name=$1 app=$2; shift 2
    write_mat && lane "$name" env "$@" "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" "$app"
}

# The socket path of the store, as PackageCompiler computes it.
socket_of_store() {
    JULIA_DEPOT_PATH="$DEPOT" "$JULIA" --startup-file=no --project="$OUT/compile-env" -e \
        'using PackageCompiler; print(PackageCompiler._reactive_server_socket(PackageCompiler._reactive_store_dir(ARGS[1])))' "$APP"
}

session_pid() { sed -n 's/^pid = \([0-9]*\)$/\1/p' "$STORE/server.toml" 2>/dev/null; }

# $1 = the socket, $2 = the log of the requests. The pid goes to decoys.pids.
start_decoy() {
    rm -f "$2"
    python3 "$TOOL/server_decoy.py" "$1" "$2" &
    echo $! >> "$OUT/decoys.pids"
    for _ in $(seq 1 50); do [ -S "$1" ] && return 0; sleep 0.2; done
    echo "=== the decoy does not listen on $1"; return 1
}

# $1 = a label, $2 = the expected pid of the first line of the server log.
check_listens() {
    if head -1 "$STORE/server.log" | grep -q "^rc: server $2 listens"; then
        echo "=== $1: the server log starts with the listens line of $2"
    else
        echo "=== $1: the server log does not start with the listens line of $2:"
        head -2 "$STORE/server.log" | cut -c1-120
        return 1
    fi
}

copy() { rm -rf "$SRC" && cp -a "$TOOL/i1_dependency" "$SRC" && echo "=== copied the packages to $SRC"; }

decoy() {
    local socket failed=0
    socket=$(socket_of_store) || return 1
    rm -f "$STORE/server.toml"
    start_decoy "$socket" "$OUT/decoy.log" || return 1
    mat mat-decoy "$APP" JULIA_REACTIVE_SERVER=1 || { echo "=== decoy: the rebuild failed"; failed=1; }
    echo "=== decoy: the requests of the decoy: $(tr '\n' ' ' < "$OUT/decoy.log")"
    grep -qx quit "$OUT/decoy.log" || { echo "=== decoy: the decoy got no quit"; failed=1; }
    grep -q "^apply" "$OUT/decoy.log" && { echo "=== decoy: the decoy got the apply"; failed=1; }
    check_listens decoy "$(session_pid)" || failed=1
    return $failed
}

signal() {
    local pid failed=0
    mat mat-signal "$APP" JULIA_REACTIVE_SERVER=1 || return 1
    pid=$(session_pid)
    [ -n "$pid" ] || { echo "=== signal: no session"; return 1; }
    kill -TERM "$pid"
    for _ in $(seq 1 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -0 "$pid" 2>/dev/null && { echo "=== signal: the server $pid did not stop"; return 1; }
    rm -f "$STORE/server.toml"
    check_listens signal "$pid" || failed=1
    if grep -q "signal 15" "$STORE/server.log"; then
        echo "=== signal: the server log holds the trace of the signal"
    else
        echo "=== signal: the server log holds no trace of the signal"; failed=1
    fi
    return $failed
}

founding() {
    local socket job rc failed=0
    socket=$(socket_of_store) || return 1
    stop_all
    mat mat-founding "$APP" JULIA_REACTIVE_FOUNDING=1 &
    job=$!
    for _ in $(seq 1 600); do [ -d "$APP.founding" ] && break; sleep 0.2; done
    [ -d "$APP.founding" ] || { echo "=== founding: no staging directory"; wait $job; return 1; }
    start_decoy "$socket" "$OUT/decoy-founding.log" || { wait $job; return 1; }
    printf 'socket = "%s"\npid = %s\nbase = 1\nlast = 1\n' "$socket" "$(tail -1 "$OUT/decoys.pids")" > "$STORE/server.toml"
    echo "=== founding: a decoy and its session file in the old store"
    wait $job; rc=$?
    [ $rc -eq 0 ] || { echo "=== founding: the founding failed"; failed=1; }
    echo "=== founding: the requests of the decoy: $(tr '\n' ' ' < "$OUT/decoy-founding.log" 2>/dev/null)"
    grep -qx quit "$OUT/decoy-founding.log" 2>/dev/null || { echo "=== founding: the decoy got no quit"; failed=1; }
    return $failed
}

stop_all() {
    if [ -f "$STORE/server.toml" ]; then
        python3 "$TOOL/server_request.py" "$APP" quit 2>/dev/null
        rm -f "$STORE/server.toml"
    fi
    if [ -f "$OUT/decoys.pids" ]; then
        while read -r pid; do kill "$pid" 2>/dev/null; done < "$OUT/decoys.pids"
        rm -f "$OUT/decoys.pids"
    fi
    echo "=== stopped the server and the decoys"
}

steps=${*:-copy found decoy signal founding stop}
for step in $steps; do
    case $step in
        copy) copy ;;
        found) rm -rf "$OUT/app" && mat mat-found "$APP" ;;
        decoy) decoy ;;
        signal) signal ;;
        founding) founding ;;
        stop) stop_all ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || {
        echo "=== step $step failed"
        # The other steps need the packages and the store.
        case $step in copy|found) stop_all; exit 1 ;; esac
        FAILED="${FAILED:-} $step"
    }
done
[ -z "${FAILED:-}" ] || { echo "=== failed:$FAILED"; stop_all; exit 1; }
echo "=== done $(date +%T)"
