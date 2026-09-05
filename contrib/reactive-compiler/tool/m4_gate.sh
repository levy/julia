#!/bin/bash
# M4 driver. The materialize entry point (src/Materialize.jl) replaces the
# hand-run chain of m1_gate1.sh:
#   s1      - the full build into an empty store
#   s2..s4  - materialize with no source change; the delta must converge to 0
#   s5      - the M0 edit applied to the file on disk (`pk.hop_count += 1`
#             becomes `+= 2` in `routing_handle!`), then materialize; the
#             delta must be the cone of the edit
#   s6      - materialize again with no change, to show convergence after
#             the edit
#   full    - the same edit built from the base image into a second store:
#             the full build that s5 is measured against
# Every run and build goes through the store; the gate only edits the file,
# calls the driver in the build lane, and compares.
# Pass step names to run some steps, or nothing to run all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/m4}
JH=${JH:-/home/projectured/workspace/julia-reactive}
JULIA=$JH/usr/bin/julia
RC=$JH/contrib/reactive-compiler
# A worktree of omnet-julia pinned to the commit that M0 measured (e21ba2cd).
OMNET=${OMNET:-/home/projectured/workspace/omnet-julia-m1}
THREADS=${THREADS:-8}
TIMINGS=${TIMINGS:-2}
LANE=${LANE:-16-23}
STORE=$OUT/store
FULL=$OUT/store-full
FILE=sample/legacy/routing/scenario/routing.jl
mkdir -p "$OUT"

# One driver call, bounded, on the build lane.
# $1 = log name, $2.. = the arguments of Materialize.jl
lane() {
    local name=$1; shift
    systemd-run --user --scope -q -p MemoryMax=24G -p MemorySwapMax=0 \
        nice -n 10 taskset -c "$LANE" \
        timeout 2400s /usr/bin/time -v \
        "$JULIA" --startup-file=no "$RC/src/Materialize.jl" "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed \(wall|Maximum resident|^=== |Network hash|Avg hops|Sequential time|reactive: delta|m4: (file|apply|applied|eval|new [0-9]|warning|removed)" "$OUT/$name.log"
    return $rc
}

# $1 = the store directory
write_config() {
    mkdir -p "$1"
    cat > "$1/store.toml" <<EOF
[config]
julia_home = "$JH"
project_dir = "$OMNET"
project = "package/OmnetLegacyRoutingExample"
packages = ["OmnetLegacyRoutingExample", "OmnetSimulator"]
tracked = ["$FILE"]
tracked_modules = ["OmnetLegacyRoutingExample.Routing"]
workload = "OmnetLegacyRoutingExample.run_scenario(:routing_small; mode = :seq)"
threads = $THREADS
timings = $TIMINGS
EOF
    echo "=== config written to $1"
}

edit() {
    local n
    n=$(grep -c "pk.hop_count += 1" "$OMNET/$FILE")
    [ "$n" = 1 ] || { echo "=== the edit does not apply: $n occurrences"; return 1; }
    sed -i 's/pk\.hop_count += 1/pk.hop_count += 2/' "$OMNET/$FILE"
    echo "=== edited $FILE"
}
restore() { git -C "$OMNET" checkout -- "$FILE" && echo "=== restored $FILE"; }

# The delta of the edit build against the cone that the child printed. Every
# root of the delta must be in the cone, and every replaced or closed method
# instance must be a root.
compare_edit() {
    python3 - "$STORE/s5/build.log" <<'PY'
import re, sys
sets = {"replaced": set(), "closed": set(), "new": set()}
roots, edges = set(), set()
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"m4: cone (replaced|closed|new) (.*)$", line)
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
                ("closed not emitted", (replaced | closed) - roots),
                ("root new", roots & new)):
    for sig in sorted(s): print(f"    {name}: {sig[:200]}")
PY
}

steps=${*:-init s1 run-s1 s2 s3 s4 edit s5 compare run-s5 s6 full run-full restore}
for step in $steps; do
    case $step in
        init) write_config "$STORE" && write_config "$FULL" ;;
        s1) lane mat-s1 "$STORE" materialize ;;
        run-s1) lane run-s1 "$STORE" run ;;
        s2) lane mat-s2 "$STORE" materialize ;;
        s3) lane mat-s3 "$STORE" materialize ;;
        s4) lane mat-s4 "$STORE" materialize ;;
        edit) edit ;;
        s5) lane mat-s5 "$STORE" materialize ;;
        compare) compare_edit ;;
        run-s5) lane run-s5 "$STORE" run ;;
        s6) lane mat-s6 "$STORE" materialize ;;
        full) lane mat-full "$FULL" materialize ;;
        run-full) lane run-full "$FULL" run ;;
        restore) restore ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
