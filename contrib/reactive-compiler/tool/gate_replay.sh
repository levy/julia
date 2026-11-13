#!/bin/bash
# The replay gate (Step 2 of plan/pending/a-rebuild-equals-a-whole-build.md):
# a store takes the commits of a real package one by one, and the result is
# compared with a whole build of the last commit. The program is ReplayApp
# (written by this gate), which loads one package of a repository and prints
# counts of its names and methods. The store tracks the sources of the package
# in a clone of the repository; the gate checks out one commit after the other
# there. The program is built in the form of the build scripts: the image
# inside the program, prelinked, the overlay of a rebuild applied in place.
#   clone    - a shared clone of $REPO into $OUT/repo, and the list of the
#              last $COUNT commits that touch $PATHS, with the commit before
#              them as the founding commit
#   app      - ReplayApp and its workload into $OUT/app
#   found    - the founding commit: materialize_app founds $OUT/chain/replay,
#              and the program is linked and prelinked
#   replay   - each later commit: a rebuild through the server, as an overlay;
#              then the prelinked program and the launcher print the same
#              lines, and tool/overlay_check.py finds no wrong entry. A
#              refused rebuild is counted and the store founds again at that
#              commit; the log of its server is kept as $OUT/server-<n>.log,
#              and the images of a rebuild that failed in $OUT/fault-<n>. A
#              rebuild that fails in another way is a fault: the store founds
#              again, the replay goes on, and the gate fails. A store whose
#              image grew past its bound founds again by itself: the gate
#              links the program again and counts the commit. The step says
#              how many rebuilds the chain holds since its last whole build:
#              the comparison tests those alone, so choose LAST so that no
#              refused commit comes at the end
#   final    - materialize_app founds $OUT/final/replay at the last commit
#   control  - a second whole build of the last commit, which compiles the
#              tracked packages again; the lines of the oracle that differ
#              between the two whole builds are the noise of the oracle, and
#              the comparisons leave them out
#   compare  - the chain against the founding of the last commit: the lines
#              of the two programs, the method tables and the globals of the
#              oracle; the roots that the chain lacks are counted, not failed
#   decode   - the prelinked program decodes the source of each method
#   fresh    - the server stops, its log is kept as $OUT/server-replay.log,
#              and a rebuild from a new server applies each change since the
#              last founding at once; then compare again. When the store
#              founds again by itself at that rebuild, the gate links the
#              program again and compares nothing: JULIA_REACTIVE_COMPACT
#              sets the bound of the store
# Pass step names to run some steps, or nothing to run all of them in order.
# Run the gate under bounded-run: the steps take no cap of their own.
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-replay}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
JULIA=${JULIA:-$JH/usr/bin/julia}
PC=${PC:-$(cd "$JH/.." && pwd)/PackageCompiler.jl}
REPO=${REPO:-$(cd "$JH/.." && pwd)/projectured-julia}
PACKAGE=${PACKAGE:-ProjecturedKernel}
PACKAGE_UUID=${PACKAGE_UUID:-a3e3499a-684d-4df9-a0d6-de2d1797b1f3}
PATHS=${PATHS:-source/kernel package/ProjecturedKernel package/ProjecturedPrecompile source/tool/precompile}
TRACKED=${TRACKED:-ReplayApp,ProjecturedKernel,ProjecturedPrecompile}
STATEMENTS=${STATEMENTS:-package/ProjecturedKernel/precompile/projectured.txt}
COUNT=${COUNT:-20}
LAST=${LAST:-HEAD}
LAUNCHER=${LAUNCHER:-$REPO/source/tool/builder/launcher.c}
TOOL=$JH/contrib/reactive-compiler/tool
THREADS=${THREADS:-4}
LANE=${LANE:-16-23}
CLONE=$OUT/repo
APPSRC=$OUT/app/ReplayApp
CHAIN=$OUT/chain/replay
FINAL=$OUT/final/replay
ARCHIVE=$OUT/chain.object/sys-o.a
PROGRAM=$CHAIN/bin/replay_prelinked
DEPOT="$OUT/depot:$HOME/.julia:"
mkdir -p "$OUT/depot"

# One run on the build lane. $1 = log name, $2.. = the command.
lane() {
    local name=$1; shift
    nice -n 10 taskset -c "$LANE" /usr/bin/time -v \
        env JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=1 JULIA_DEPOT_PATH="$DEPOT" \
        "$@" > "$OUT/$name.log" 2>&1
}

# $1 = log name, $2 = the bundle, $3 = the archive to keep or "", $4.. =
# assignments of the environment. The store inside the bundle decides between
# a founding and a rebuild.
mat() {
    local name=$1 bundle=$2 archive=$3; shift 3
    mkdir -p "$OUT/compile-env"
    cat > "$OUT/compile-env/Project.toml" <<EOF
[deps]
PackageCompiler = "9b87118b-4619-50d2-8e1e-99f35a4d4d9d"

[sources]
PackageCompiler = {path = "$PC"}
EOF
    cat > "$OUT/mat.jl" <<'EOF'
import Pkg; Pkg.instantiate()
using PackageCompiler
app, bundle, workload, statements, archive = ARGS
keep = isempty(archive) ? (;) : (; keep_object_archive = archive)
materialize_app(app, bundle;
    workload = workload,
    precompile_statements_file = statements,
    executables = ["replay" => "julia_main"],
    track_dependencies = true,
    force = true,
    incremental = true,
    cpu_target = "native",
    sysimage_build_args = `-O2 -g1 --sysimage-prelink=yes`,
    keep...)
EOF
    lane "$name" env "$@" "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" \
        "$APPSRC" "$bundle" "$OUT/app/workload.jl" "$STATEMENTS_OUT" "$archive"
}

clone() {
    rm -rf "$CLONE" && git clone -q --shared --no-checkout "$REPO" "$CLONE" || return 1
    # shellcheck disable=SC2086
    git -C "$REPO" log --format=%H -n $((COUNT + 1)) "$LAST" -- $PATHS | tac > "$OUT/commits.txt"
    local n; n=$(wc -l < "$OUT/commits.txt")
    [ "$n" -ge 2 ] || { echo "=== clone: $n commits touch $PATHS"; return 1; }
    echo "=== clone: the founding commit $(head -1 "$OUT/commits.txt" | cut -c1-9), then $((n - 1)) commits to $(tail -1 "$OUT/commits.txt" | cut -c1-9)"
}

checkout() { git -C "$CLONE" checkout -q --detach "$1"; }

# The recorded calls of the package at the commit of the clone, as statements
# of a trace. The trace of a store is the one of its founding, and the
# statements file is an input of the store: a rebuild stops when its text is
# not that of the founding. So the chain has one file, and the whole builds of
# the last commit have another.
STATEMENTS_OUT=$OUT/app/statements.jl
statements() {
    sed -n 's/^Tuple{.*/precompile(&)/p' "$CLONE/$STATEMENTS" > "$STATEMENTS_OUT"
}

app() {
    rm -rf "$OUT/app" && mkdir -p "$APPSRC/src" || return 1
    cat > "$APPSRC/Project.toml" <<EOF
name = "ReplayApp"
uuid = "5d1a0c7e-3b0f-4e63-9c55-6a1f0e7d2b11"
version = "0.1.0"

[deps]
$PACKAGE = "$PACKAGE_UUID"

[sources]
$PACKAGE = {path = "$CLONE/package/$PACKAGE"}
EOF
    cat > "$APPSRC/src/ReplayApp.jl" <<EOF
# The program of the replay gate: it loads one package and prints counts that
# a whole build and a chain of rebuilds must agree on. With REPLAY_DECODE in
# the environment it also decodes the source of each method of its image.
module ReplayApp
using $PACKAGE

# Whether \`mod\` is the package or a module inside it.
function is_package_module(mod::Module)
    while true
        mod === $PACKAGE && return true
        parent = parentmodule(mod)
        parent === mod && return false
        mod = parent
    end
end

function count_package_methods()
    total = 0
    Base.visit(Core.methodtable) do method
        is_package_module(method.module) && (total += 1)
        true
    end
    return total
end

function decode_sources()
    decoded = 0
    Base.visit(Core.methodtable) do method
        if isdefined(method, :source)
            Base.uncompressed_ir(method)
            decoded += 1
        end
        true
    end
    return decoded
end

Base.@ccallable function julia_main()::Cint
    println("shape: names = ", length(names($PACKAGE)))
    println("shape: methods = ", count_package_methods())
    haskey(ENV, "REPLAY_DECODE") && println("decoded: ", decode_sources(), " sources")
    return 0
end
end
EOF
    printf 'using ReplayApp\nReplayApp.julia_main()\n' > "$OUT/app/workload.jl"
    echo "=== app: ReplayApp of $PACKAGE in $APPSRC"
}

# The program of the build scripts: the launcher and the archive of the
# founding in one ET_EXEC with the headroom of an overlay, then prelinked.
link() {
    cat > "$OUT/headroom.ld" <<'EOF'
SECTIONS
{
  .reactive_headroom (NOLOAD) : ALIGN(4096) { . = . + 0x14000000; }
}
INSERT AFTER .ldata;
EOF
    cat > "$OUT/link.jl" <<'EOF'
using PackageCompiler
const P = PackageCompiler
program, launcher, archive, script = ARGS
flags = Base.shell_split(join((P.cflags(), P.ldflags(), P.ldlibs()), " "))
P.run_compiler(`-DJULIA_MAIN=\"ReplayApp.julia_main\" $(P.TLS_SYNTAX) $(P.bitflag()) $(P.march()) -no-pie
                -o $program $launcher -Wl,--whole-archive $archive -Wl,--no-whole-archive
                -Wl,-T,$script $(P.rpath_executable()) $flags`)
EOF
    rm -f "$PROGRAM" "$PROGRAM.chain"
    lane link "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/link.jl" \
        "$PROGRAM" "$LAUNCHER" "$ARCHIVE" "$OUT/headroom.ld" || { echo "=== link failed; see $OUT/link.log"; return 1; }
    lane prelink "$PROGRAM" --julia-args --output-prelinked="$PROGRAM.prelinked" &&
        mv "$PROGRAM.prelinked" "$PROGRAM" || { echo "=== prelink failed; see $OUT/prelink.log"; return 1; }
}

# $1 = log name, $2 = "found" or "again". The founding at the commit of the
# clone, with the program.
found_chain() {
    statements
    local env=()
    [ "$2" == again ] && env=(JULIA_REACTIVE_FOUNDING=1)
    mkdir -p "$(dirname "$ARCHIVE")"
    mat "$1" "$CHAIN" "$ARCHIVE" JULIA_REACTIVE_IMAGE_WRITE=overlay JULIA_REACTIVE_SERVER=1 "${env[@]}" ||
        { echo "=== $1: the founding failed; see $OUT/$1.log"; return 1; }
    link || return 1
    echo "=== $1: founded at $(git -C "$CLONE" rev-parse --short HEAD) in $(grep -o 'Elapsed (wall clock) time.*' "$OUT/$1.log" | awk '{print $NF}'), peak $(( $(grep 'Maximum resident' "$OUT/$1.log" | awk '{print $NF}') >> 10 )) MB"
}

# The lines that a program prints. $1 = log name, $2 = the program.
shape() {
    lane "$1" "$2" || return 1
    grep "^shape: " "$OUT/$1.log"
}

# The prelinked program and the launcher after a build, and the overlay.
# $1 = a tag.
verify() {
    local a b
    # The chain of the program is the chain of the bundle, once a rebuild wrote one.
    [ -f "$CHAIN/lib/julia/sys.so.chain" ] && ln -sf ../lib/julia/sys.so.chain "$PROGRAM.chain"
    a=$(shape "run-$1" "$PROGRAM") || { echo "=== $1: the prelinked program failed; see $OUT/run-$1.log"; return 1; }
    b=$(shape "run-$1-launcher" "$CHAIN/bin/replay") || { echo "=== $1: the launcher failed; see $OUT/run-$1-launcher.log"; return 1; }
    [ "$a" == "$b" ] || { echo "=== $1: the prelinked program and the launcher differ"; diff <(echo "$a") <(echo "$b") | grep "^[<>]"; return 1; }
    local chain=$CHAIN/lib/julia/sys.so.chain overlay=""
    [ -f "$chain" ] && overlay=$(grep -v '^#' "$chain" | grep . | tail -1)
    if [ -n "$overlay" ]; then
        python3 -I "$TOOL/overlay_check.py" "$CHAIN/lib/julia/sys.so" "$CHAIN/lib/julia/$overlay" > "$OUT/check-$1.log" 2>&1 ||
            { echo "=== $1: the overlay has wrong entries"; sed 's/^/    /' "$OUT/check-$1.log"; return 1; }
    fi
    echo "=== $1: $(echo $a | sed 's/shape: //g')"
}

found() {
    checkout "$(head -1 "$OUT/commits.txt")" || return 1
    rm -rf "$OUT/chain" "$OUT/chain.object"
    found_chain mat-found found && verify found
}

replay() {
    local n=0 refused=0 faults=0 grown=0 since=0 commit short
    : > "$OUT/refusals.txt"; : > "$OUT/faults.txt"
    for commit in $(tail -n +2 "$OUT/commits.txt"); do
        n=$((n + 1)); short=$(echo "$commit" | cut -c1-9)
        checkout "$commit" || return 1
        if mat "mat-$n" "$CHAIN" "$ARCHIVE" JULIA_REACTIVE_IMAGE_WRITE=overlay JULIA_REACTIVE_SERVER=1; then
            # A store whose image grew past its bound founds again by itself.
            # The base is new then, so the program is linked again from the
            # archive of that founding, as the build scripts do.
            if grep -q "materialize_app: the store founds again" "$OUT/mat-$n.log"; then
                grown=$((grown + 1)); since=0
                link || return 1
                verify "$n-$short" || return 1
                echo "    $n $short the store founded again by itself: $(grep -A 1 "the store founds again" "$OUT/mat-$n.log" | grep -o 'reason = .*' | cut -c1-120)"
                continue
            fi
            local line; line=$(grep -h -o "rc: applied [0-9]* expressions and [0-9]* removals" "$CHAIN/reactive-store/server.log" | tail -1)
            if verify "$n-$short"; then
                since=$((since + 1))
                echo "    $n $short ${line:-rc: applied nothing}, $(grep -o 'Elapsed (wall clock) time.*' "$OUT/mat-$n.log" | awk '{print $NF}')"
                continue
            fi
            faults=$((faults + 1)); echo "$n $short the rebuilt program is wrong" >> "$OUT/faults.txt"
        elif grep -q "the rebuild is refused" "$OUT/mat-$n.log"; then
            refused=$((refused + 1))
            { echo "$n $short"; grep -A 12 "the rebuild is refused" "$OUT/mat-$n.log" | grep -E "^ *[A-Z][0-9] " | sed 's/^/    /'; } >> "$OUT/refusals.txt"
            echo "=== $n $short: the rebuild is refused: $(grep -A 12 "the rebuild is refused" "$OUT/mat-$n.log" | grep -E "^ *[A-Z][0-9] " | head -1 | cut -c1-150)"
        else
            faults=$((faults + 1)); echo "$n $short the rebuild failed; see mat-$n.log" >> "$OUT/faults.txt"
            echo "=== $n $short: the rebuild FAILED: $(grep -m1 -E "ERROR|error " "$OUT/mat-$n.log" | cut -c1-200)"
        fi
        # The server of a store that founds again writes a new log, and the
        # founding writes new images: the log and the images of a rebuild that
        # went wrong stay in $OUT/fault-<n>, for a look at them.
        cp "$CHAIN/reactive-store/server.log" "$OUT/server-$n.log" 2>/dev/null
        if grep -q "^$n " "$OUT/faults.txt"; then
            mkdir -p "$OUT/fault-$n" && cp -a "$CHAIN/lib/julia/." "$OUT/fault-$n/" 2>/dev/null
        fi
        since=0
        found_chain "mat-$n-found" again && verify "$n-$short-found" || return 1
    done
    echo "=== replay: $n commits, $refused refused, $faults faults, $grown founded again by the store"
    # A whole build of the chain takes each change of before into its image, so
    # the comparison at the end tests the rebuilds after the last one alone.
    echo "=== replay: the chain holds $since rebuilds since its last whole build, and the comparison tests those"
    [ "$faults" == 0 ]
}

final() {
    local STATEMENTS_OUT=$OUT/app/statements-final.jl
    statements
    rm -rf "$OUT/final"
    mat mat-final "$FINAL" "" || { echo "=== final: the founding failed; see $OUT/mat-final.log"; return 1; }
    shape run-final "$FINAL/bin/replay" > "$OUT/shape-final.txt" || { echo "=== final: the program failed"; return 1; }
    echo "=== final: founded at $(git -C "$CLONE" rev-parse --short HEAD): $(sed 's/shape: //' "$OUT/shape-final.txt" | tr '\n' ' ')"
}

oracle() {
    taskset -c "$LANE" env JULIA_DEPOT_PATH="$DEPOT" "$JULIA" --startup-file=no -J "$2/lib/julia/sys.so" "$TOOL/oracle.jl" \
        --tracked "$TRACKED" --trace "$FINAL/reactive-store/trace.jl" > "$OUT/oracle-$1.log" 2>&1 ||
        { echo "=== the oracle of $1 failed; see $OUT/oracle-$1.log"; return 1; }
}

# A second whole build of the same sources. A fact of the oracle that differs
# between two whole builds says nothing about a rebuild: its key goes to
# noise.txt, the line without its last word. The compiled files of the tracked
# packages leave the depot first, so that this build compiles them again: a
# module gets a new build id there, as the modules of the chain and of the
# founding of the last commit have different ones, and a fact that depends on
# the build id (the hash of a type) is noise too.
control() {
    rm -rf "$OUT/control"
    local name STATEMENTS_OUT=$OUT/app/statements-final.jl
    for name in ${TRACKED//,/ }; do rm -rf "$OUT/depot/compiled"/*/"$name"; done
    mat mat-control "$OUT/control/replay" "" || { echo "=== control: the founding failed; see $OUT/mat-control.log"; return 1; }
    oracle control "$OUT/control/replay" && oracle final "$FINAL" || return 1
    diff <(grep -E "^(method|global) " "$OUT/oracle-control.log") <(grep -E "^(method|global) " "$OUT/oracle-final.log") |
        grep -E "^[<>] " | sed -E 's/^[<>] //; s/ [^ ]*$/ /' | sort -u > "$OUT/noise.txt"
    echo "=== control: $(wc -l < "$OUT/noise.txt") facts differ between two whole builds of the same commit"
    head -5 "$OUT/noise.txt" | cut -c1-160 | sed 's/^/    /'
}

# The lines of a file that match a pattern, without the noise of the oracle.
facts() {
    if [ -s "$OUT/noise.txt" ]; then grep -E "$1" "$2" | grep -v -F -f "$OUT/noise.txt"; else grep -E "$1" "$2"; fi
}

# $1 = the check, $2 = the pattern of its lines, $3 $4 = the files.
check() {
    local a b lines
    a=$(facts "$2" "$3"); b=$(facts "$2" "$4")
    if [ "$a" == "$b" ]; then
        echo "=== $1: equal ($(echo "$a" | grep -c .) lines)"
        return 0
    fi
    lines=$(diff <(echo "$a") <(echo "$b") | grep -E "^[<>]")
    echo "=== $1: $(echo "$lines" | grep -c .) lines differ (< chain, > founding)"
    echo "$lines" | head -12 | cut -c1-220
    return 1
}

# $1 = a tag of the chain side.
compare_with_final() {
    local failed=0
    shape "run-$1" "$PROGRAM" > "$OUT/shape-$1.txt" || { echo "=== $1: the prelinked program failed"; return 1; }
    oracle "$1" "$CHAIN" && oracle final "$FINAL" || return 1
    check "$1 output" "^shape: " "$OUT/shape-$1.txt" "$OUT/shape-final.txt" || failed=1
    check "$1 method tables" "^method " "$OUT/oracle-$1.log" "$OUT/oracle-final.log" || failed=1
    check "$1 globals" "^global " "$OUT/oracle-$1.log" "$OUT/oracle-final.log" || failed=1
    local roots missing
    roots=$(grep -c "^root " "$OUT/oracle-final.log")
    missing=$(diff <(grep "^root " "$OUT/oracle-$1.log") <(grep "^root " "$OUT/oracle-final.log") | grep -c "^>")
    echo "=== $1 roots: $missing of $roots differ from the founding (counted, not failed)"
    grep "^info" "$OUT/oracle-$1.log" | sed "s/^/    $1 /"
    return $failed
}

compare() { compare_with_final chain; }

decode() {
    lane decode env REPLAY_DECODE=1 "$PROGRAM" || { echo "=== decode: the prelinked program failed; see $OUT/decode.log"; return 1; }
    local line; line=$(grep "^decoded: [0-9]* sources" "$OUT/decode.log") || { echo "=== decode: no count"; return 1; }
    echo "=== decode: $line"
}

fresh() {
    env JULIA_DEPOT_PATH="$DEPOT" "$JULIA" --startup-file=no --project="$OUT/compile-env" -e \
        'using PackageCompiler; PackageCompiler.stop_server(ARGS[1])' "$CHAIN" > "$OUT/stop.log" 2>&1
    # The new server writes its log over the log of the server of the replay.
    cp "$CHAIN/reactive-store/server.log" "$OUT/server-replay.log" 2>/dev/null
    echo "=== fresh: the replay of the server of the chain: $(grep -h -o "rc: replay: [0-9]* candidates, [0-9]* compared, [0-9]* moved, [0-9]* differ" "$OUT/server-replay.log" | awk '{c += $5; m += $7; d += $9} END {print NR " rebuilds, " c + 0 " compared, " m + 0 " moved, " d + 0 " differ"}')"
    # The sources are those of the last rebuild: a new server applies each
    # change since the founding all the same, so the rebuild does not end early
    # (D9).
    mat mat-fresh "$CHAIN" "$ARCHIVE" JULIA_REACTIVE_IMAGE_WRITE=overlay JULIA_REACTIVE_SERVER=1 JULIA_REACTIVE_REBUILD_UNCHANGED=1 ||
        { echo "=== fresh: the rebuild failed; see $OUT/mat-fresh.log"; return 1; }
    # A store whose image grew past its bound founds again by itself, and no
    # server applies a change: the program is linked again from the archive
    # of that founding, and there is no rebuild to compare.
    if grep -q "materialize_app: the store founds again" "$OUT/mat-fresh.log"; then
        link && verify fresh || return 1
        echo "=== fresh: the store founded again by itself, so no new server applied the changes: $(grep -A 1 "the store founds again" "$OUT/mat-fresh.log" | grep -o 'reason = .*' | cut -c1-120)"
        return 0
    fi
    echo "=== fresh: $(grep -h -o "rc: applied [0-9]* expressions and [0-9]* removals" "$CHAIN/reactive-store/server.log" | tail -1)"
    verify fresh && compare_with_final fresh
}

stop() {
    env JULIA_DEPOT_PATH="$DEPOT" "$JULIA" --startup-file=no --project="$OUT/compile-env" -e \
        'using PackageCompiler; PackageCompiler.stop_server(ARGS[1])' "$CHAIN" > "$OUT/stop.log" 2>&1
    echo "=== stop: the server of the store is stopped"
}

steps=${*:-clone app found replay final control compare decode fresh stop}
status=0
for step in $steps; do
    $step || { echo "=== step $step failed"; status=1; [ "$step" == replay ] || [ "$step" == compare ] || break; }
done
[ "$status" == 0 ] || stop > /dev/null 2>&1
echo "=== done $(date +%T), status $status"
exit $status
