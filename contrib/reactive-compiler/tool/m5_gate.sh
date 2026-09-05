#!/bin/bash
# M5 driver. PackageCompiler (branch `reactive`, worktree
# package-compiler-reactive) rebuilds the `routing` sample bundle of
# omnet-julia after an on-disk edit, through `materialize_app`:
#   write-app    - the builder writes the app package (build/app/routing),
#                  with --no-compile
#   full         - materialize_app founds the store: a normal create_app
#                  plus the text objects and the tracked sources
#   smoke        - the built binary answers --build-info
#   edit         - `packet.hop_count += 1` becomes `+= 2` in
#                  sample/legacy/routing/Routing.jl
#   mat-edit     - materialize_app again: the delta of the edit
#   compare-edit - the delta against the cone the child printed
#   smoke-edit   - the rebuilt binary answers --build-info
#   restore      - git restores the file
#   mat-restore  - the reverse edit, through the same path
#   mat-noop     - no change; the delta must shrink toward zero
# Pass step names to run some steps, or nothing to run all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/m5}
JH=${JH:-/home/projectured/workspace/julia-reactive}
JULIA=$JH/usr/bin/julia
PC=${PC:-/home/projectured/workspace/package-compiler-reactive}
OMNET=${OMNET:-/home/projectured/workspace/omnet-julia-m1}
THREADS=${THREADS:-8}
TIMINGS=${TIMINGS:-2}
LANE=${LANE:-16-23}
APP=$OUT/routing
FILE=sample/legacy/routing/Routing.jl
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
    grep -E "Elapsed \(wall|Maximum resident|rc: (file|apply|applied|eval|new [0-9]|warning|removed)|reactive: (delta|front)|materialize_app|Started|=== " "$OUT/$name.log"
    return $rc
}

write_mat() {
    cat > "$OUT/mat.jl" <<EOF
import Pkg; Pkg.instantiate()
using PackageCompiler
materialize_app("$OMNET/build/app/routing", "$APP";
    tracked = ["$OMNET/$FILE" => "OmnetLegacyRouting"],
    workload = "$OMNET/source/build/workload/Batch.jl",
    executables = ["routing" => "julia_main"],
    force = true,
    incremental = true,
    include_lazy_artifacts = true,
    cpu_target = "native",
    sysimage_build_args = \`-O3 -g1\`,
    precompile_statements_file = "$OMNET/asset/precompile/WorkloadStatements.jl")
EOF
    mkdir -p "$OUT/compile-env"
    cat > "$OUT/compile-env/Project.toml" <<EOF
[deps]
PackageCompiler = "9b87118b-4619-50d2-8e1e-99f35a4d4d9d"

[sources]
PackageCompiler = {path = "$PC"}
EOF
    echo "=== wrote $OUT/mat.jl and $OUT/compile-env"
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

# $1 = the log to compare: the delta roots against the cone the child printed.
compare() {
    python3 - "$OUT/$1.log" <<'PY'
import re, sys
sets = {"replaced": set(), "closed": set(), "new": set()}
roots, edges = set(), set()
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"rc: cone (replaced|closed|new) (.*)$", line)
    if m: sets[m.group(1)].add(m.group(2).strip()); continue
    m = re.match(r"reactive delta: :(root|edge) (.*)$", line)
    if m: (roots if m.group(1) == "root" else edges).add(m.group(2).strip())
replaced, closed, new = sets["replaced"], sets["closed"], sets["new"]
cone = replaced | closed | new
print(f"=== compare: replaced {len(replaced)}, closed {len(closed)}, new {len(new)}, "
      f"delta roots {len(roots)}, edges {len(edges)}; "
      f"roots outside the cone {len(roots - cone)}, "
      f"closed not emitted {len((replaced | closed) - roots)}")
for name, s in (("root outside the cone", roots - cone),
                ("closed not emitted", (replaced | closed) - roots)):
    for sig in sorted(s): print(f"    {name}: {sig[:200]}")
PY
}

steps=${*:-write-app full smoke run-before edit mat-edit compare-edit smoke-edit run-after restore mat-restore compare-restore mat-noop}
for step in $steps; do
    case $step in
        run-before) runsim before ;;
        run-after) runsim after ;;
        write-app)
            write_mat
            ( cd "$OMNET" && lane instantiate-tool "$JULIA" --startup-file=no \
                  --project=environment/tool -e 'import Pkg; Pkg.instantiate()' ) &&
            ( cd "$OMNET" && OMNET_BUILD_WHAT=sample OMNET_BUILD_COMMAND=bin/build_omnet_legacy_sample \
                  lane write-app "$JULIA" --startup-file=no --project=environment/tool \
                  source/tool/build_binary.jl routing --no-compile ) ;;
        full) lane mat-full "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" ;;
        smoke) lane smoke "$APP/bin/routing" --build-info ;;
        edit) edit ;;
        mat-edit) lane mat-edit "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" ;;
        compare-edit) compare mat-edit ;;
        smoke-edit) lane smoke-edit "$APP/bin/routing" --build-info ;;
        restore) restore ;;
        mat-restore) lane mat-restore "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" ;;
        compare-restore) compare mat-restore ;;
        mat-noop) lane mat-noop "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
