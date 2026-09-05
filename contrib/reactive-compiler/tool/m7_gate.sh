#!/bin/bash
# M7 driver. The builder of omnet-julia (branch `reactive-builder`) rebuilds
# the `routing` sample through `bin/build_omnet_legacy_sample routing
# --reactive`: the first build founds the store, every later one compiles the
# edit only. The reactive Julia is first on PATH, so the `bin/` script runs it.
#   instantiate  - the tool environment resolves the reactive PackageCompiler
#   write-app    - `--reactive --no-compile` writes the package and names the
#                  tracked files
#   full         - the founding build, into $OUT/routing
#   run-before   - the binary runs the Backbone configuration; hop mean 2.308011
#   edit         - `packet.hop_count += 1` becomes `+= 2` in
#                  sample/legacy/routing/Routing.jl
#   rebuild      - the same command again: the delta of the edit
#   run-after    - hop mean 4.616022
#   restore      - git restores the file
#   rebuild-restore, run-restored - the reverse edit, and 2.308011 again
# Pass step names to run some steps, or nothing to run all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/m7}
JH=${JH:-/home/projectured/workspace/julia-reactive}
OMNET=${OMNET:-/home/projectured/workspace/omnet-julia-m1}
THREADS=${THREADS:-8}
TIMINGS=${TIMINGS:-2}
LANE=${LANE:-16-23}
APP=$OUT/routing
FILE=sample/legacy/routing/Routing.jl
BUILD="bin/build_omnet_legacy_sample routing --reactive --output=$APP"
mkdir -p "$OUT/depot"

# One bounded run on the build lane. $1 = log name, $2.. = the command.
lane() {
    local name=$1; shift
    systemd-run --user --scope -q -p MemoryMax=24G -p MemorySwapMax=0 \
        nice -n 10 taskset -c "$LANE" \
        timeout 2400s /usr/bin/time -v \
        env PATH="$JH/usr/bin:$PATH" \
            JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=$TIMINGS \
            JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" \
        "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed \(wall|Maximum resident|rc: (file|apply|applied|eval|new [0-9]|warning|removed)|reactive: (delta|ccallable)|materialize_app|Founding|Rebuilding|Compiling|Built|Started|tracked|ERROR|Error|=== " "$OUT/$name.log" | head -60
    return $rc
}

# One simulation run of the built binary, and the hop mean of node[0].
# The `+= 2` edit doubles it. $1 = a tag for the log and the results.
runsim() {
    rm -rf "$OUT/run-$1"; mkdir -p "$OUT/run-$1"
    ( cd "$OUT/run-$1" && lane runsim-$1 "$APP/bin/routing" \
          -f "$OMNET/sample/legacy/routing/ned/omnetpp.ini" -c Backbone )
    local sca="$OUT/run-$1/results/Backbone-#0.sca"
    echo "=== hops($1): $(grep -A 2 'statistic Backbone.node\[0\].app hopCount' "$sca" | grep 'field mean')"
}

edit() {
    local n
    n=$(grep -c "packet.hop_count += 1" "$OMNET/$FILE")
    [ "$n" = 1 ] || { echo "=== the edit does not apply: $n occurrences"; return 1; }
    sed -i 's/packet\.hop_count += 1/packet.hop_count += 2/' "$OMNET/$FILE"
    echo "=== edited $FILE"
}
restore() { git -C "$OMNET" checkout -- "$FILE" && echo "=== restored $FILE"; }

build() { ( cd "$OMNET" && lane "$1" $BUILD ); }

steps=${*:-instantiate write-app full run-before edit rebuild run-after restore rebuild-restore run-restored}
for step in $steps; do
    case $step in
        instantiate) ( cd "$OMNET" && lane instantiate-tool julia --startup-file=no \
                         --project=environment/tool -e 'import Pkg; Pkg.resolve(); Pkg.instantiate()' ) ;;
        write-app) ( cd "$OMNET" && lane write-app $BUILD --no-compile ) ;;
        full) build build-full ;;
        run-before) runsim before ;;
        edit) edit ;;
        rebuild) build build-edit ;;
        run-after) runsim after ;;
        restore) restore ;;
        rebuild-restore) build build-restore ;;
        run-restored) runsim restored ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
