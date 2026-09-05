#!/bin/bash
# M6 driver. The two Stage 1 hazards, on the HazardApp package
# (tool/m6_hazard): every call shape across the reuse boundary, and a
# redefined `@ccallable` method.
#   full         - materialize_app founds the store of HazardApp (a fresh
#                  $OUT/hazard: a store that exists would make it a rebuild)
#   run-before   - the built binary prints the before-values
#   edit         - shapes-after.jl replaces HazardApp/src/shapes.jl
#   mat-edit     - materialize_app again: the delta of the edit; the log must
#                  say that the previous image exports `hazard_entry`
#   run-after    - the rebuilt binary prints the after-values; the bench line
#                  gives the trampoline cost per call; the `state` line says
#                  what the rebuild workloads left in a global of the image
#   restore      - git restores shapes.jl
#   mat-restore  - the reverse edit
#   run-restored - the before-values again
# Pass step names to run some steps, or nothing to run all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/m6}
JH=${JH:-/home/projectured/workspace/julia-reactive}
JULIA=$JH/usr/bin/julia
PC=${PC:-/home/projectured/workspace/package-compiler-reactive}
HZ=$JH/contrib/reactive-compiler/tool/m6_hazard
THREADS=${THREADS:-8}
TIMINGS=${TIMINGS:-2}
LANE=${LANE:-16-23}
APP=$OUT/hazard
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
    grep -E "Elapsed \(wall|Maximum resident|rc: (file|apply|applied|eval|new [0-9]|warning|removed)|reactive: (delta|front|ccallable)|materialize_app|shape:|bench:|=== " "$OUT/$name.log"
    return $rc
}

write_mat() {
    cat > "$OUT/mat.jl" <<EOF
import Pkg; Pkg.instantiate()
using PackageCompiler
materialize_app("$HZ/HazardApp", "$APP";
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
    echo "=== wrote $OUT/mat.jl and $OUT/compile-env"
}

# The binary prints one `shape:` line per call shape and one `bench:` line.
# $1 = a tag for the log, $2 = before | after: the expected values.
runbin() {
    lane run-$1 "$APP/bin/hazard" || return 1
    python3 - "$OUT/run-$1.log" "$2" <<'PY'
import re, sys
before = dict(noinline=3, inline=2, nospec=11, const=42, cfunc=2, kwargs=3,
              varargs=3, invoke=0.0, oc=101, sparam=8, finalizer=1,
              reverse=1001, cone=2, ccallable=1)
after = dict(noinline=6, inline=3, nospec=12, const=42, cfunc=4, kwargs=6,
             varargs=6, invoke=0.0, oc=102, sparam=8, finalizer=2,
             reverse=2002, cone=4, ccallable=2)
want = before if sys.argv[2] == "before" else after
got = {}
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"shape: (\w+) = (.*)$", line)
    if m: got[m.group(1)] = float(m.group(2))
bad = [k for k in want if got.get(k) != want[k]]
missing = [k for k in want if k not in got]
# `state` is what the rebuild workloads so far left in `FINALIZED`: reported,
# not checked, because it says what the image holds and not what the code does
print(f"=== shapes({sys.argv[2]}): {len(want) - len(bad)} of {len(want)} as expected"
      + (f"; wrong {', '.join(f'{k}={got.get(k)}' for k in bad)}" if bad else "")
      + (f"; missing {', '.join(missing)}" if missing else "")
      + f"; persisted state {got.get('state')}")
sys.exit(1 if bad else 0)
PY
}

# $1 = the log of a rebuild; the compiler must report the alias it did not emit.
alias_skipped() {
    grep -q "reactive: ccallable hazard_entry is exported by the previous image" "$OUT/$1.log" ||
        { echo "=== the rebuild did not skip the alias of hazard_entry"; return 1; }
}

edit() { cp "$HZ/shapes-after.jl" "$HZ/$FILE" && echo "=== edited $FILE"; }
restore() { git -C "$JH" checkout -- "contrib/reactive-compiler/tool/m6_hazard/$FILE" && echo "=== restored $FILE"; }

steps=${*:-full run-before edit mat-edit run-after restore mat-restore run-restored}
for step in $steps; do
    case $step in
        full) rm -rf "$APP" && write_mat && lane mat-full "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" ;;
        run-before) runbin before before ;;
        edit) edit ;;
        mat-edit) lane mat-edit "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" && alias_skipped mat-edit ;;
        run-after) runbin after after ;;
        restore) restore ;;
        mat-restore) lane mat-restore "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" && alias_skipped mat-restore ;;
        run-restored) runbin restored before ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
