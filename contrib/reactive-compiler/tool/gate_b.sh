#!/bin/bash
# Gate B of plan/pending/robust-incremental-compiler.md: one change of every
# category of the catalog, on the HazardApp package (tool/m6_hazard). The
# tracked files are the root file, shapes.jl, changes.jl, renamed.jl, and
# after the edit renamed2.jl and extra.jl. Every rebuild is compared with a
# founding of the same sources by the oracle (tool/oracle.jl).
#   found-chain  - materialize_app founds $OUT/chain/hazard at the sources S0
#   run-s1       - the founded binary prints the before-values
#   trace-s0     - the workload under --trace-compile at S0: the roots of S0
#   oracle-s1    - the digest of the founded image
#   edit         - the edit: changes-after.jl, HazardApp-after.jl,
#                  data-after.txt, extra.jl, renamed.jl -> renamed2.jl
#   mat-s2       - the rebuild; the log names every category, the kept
#                  method of the @eval loop, and the cone without the caller
#                  of the unchanged method
#   run-s2       - the after-values
#   reformat     - changes-reformat.jl replaces changes.jl
#   mat-s3       - the rebuild applies nothing (H1)
#   run-s3       - the after-values again
#   refresh      - refresh_trace: the workload from the chain image adds
#                  the roots that the edit made (a dynamic dispatch that the
#                  founding's trace never saw)
#   mat-s4       - the rebuild applies nothing and precompiles the new roots
#   run-s4       - the after-values again
#   trace-final  - the roots at the edited sources
#   found-final  - materialize_app founds $OUT/final/hazard at the edited sources
#   run-final    - the founded binary
#   compare-final - the four checks of the invariant: s4 against final
#   restore      - git restores the tracked files; the added files go
#   mat-s5       - the reverse edit
#   run-s5       - the before-values, except `word` (a removed `using` keeps
#                  its binding)
#   compare-s1   - the four checks: s5 against the digest of s1
#   refuse-option - an option of the module: the rebuild is refused, the
#                  store keeps its snapshots, the binary still runs
#   refuse-untracked - a type with an untracked dependent: the same
# Pass step names to run some steps, or nothing to run all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/gate-b}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
JULIA=$JH/usr/bin/julia
PC=${PC:-/home/projectured/workspace/package-compiler-reactive}
TOOL=$JH/contrib/reactive-compiler/tool
HZ=$TOOL/m6_hazard
SRC=$HZ/HazardApp/src
THREADS=${THREADS:-8}
TIMINGS=${TIMINGS:-2}
LANE=${LANE:-16-23}
LIGHT=${LIGHT:-24-27}
CHAIN=$OUT/chain/hazard
FINAL=$OUT/final/hazard
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
    grep -E "Elapsed \(wall|Maximum resident|rc: (change|cone|refuse|removed|applied|new [0-9])|reactive: (delta|front|[0-9]+ direct)|materialize_app|refresh_trace|=== " "$OUT/$name.log"
    return $rc
}

# A light run outside the build lane: the oracle and the trace.
light() {
    local name=$1; shift
    timeout 600s taskset -c "$LIGHT" \
        env JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    return $rc
}

# mat.jl takes the bundle directory as its argument; the store inside it
# decides between a founding and a rebuild. The tracked list is the files
# that exist now: a renamed or added file joins it on the rebuild.
write_mat() {
    cat > "$OUT/mat.jl" <<EOF
import Pkg; Pkg.instantiate()
using PackageCompiler
candidates = ["HazardApp.jl" => "", "shapes.jl" => "HazardApp", "changes.jl" => "HazardApp",
              "renamed.jl" => "HazardApp", "renamed2.jl" => "HazardApp", "extra.jl" => "HazardApp"]
tracked = [joinpath("$SRC", file) => root for (file, root) in candidates if isfile(joinpath("$SRC", file))]
materialize_app("$HZ/HazardApp", ARGS[1];
    tracked,
    workload = "$HZ/workload.jl",
    executables = ["hazard" => "julia_main"],
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

# refresh_trace on the chain: the workload runs from the chain image under
# --trace-compile, and the store's trace becomes the union.
refresh() {
    write_mat
    cat > "$OUT/refresh.jl" <<EOF
import Pkg; Pkg.instantiate()
using PackageCompiler
refresh_trace(ARGS[1])
EOF
    lane refresh "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/refresh.jl" "$CHAIN" || return 1
    grep -q "refresh_trace: the trace is refreshed" "$OUT/refresh.log" || { echo "=== refresh: no refresh line"; return 1; }
    grep -qE "added = [1-9]" "$OUT/refresh.log" || { echo "=== refresh: the refresh added no root"; return 1; }
}

# The binary prints one `change:` line per case. $1 = the log tag, $2 = the
# bundle, $3 = before | after | restored: the expected values.
runbin() {
    lane "run-$1" "$2/bin/hazard" || return 1
    python3 - "$OUT/run-$1.log" "$3" <<'PY'
import re, sys
before = dict(special=1, resig=1, scaler=6, gen=8, box=9, unit=1, crate=16, label="one",
              factor=2, tally=10, word="unbound", quad=4, times2=10, times3=15, note=4,
              renamed=7, corner=7)
after = dict(special=0, resig=2, scaler=7, gen=12, box=6, unit=2, crate=8, label="two",
             factor=3, tally=20, word="exported", quad=9, times2=10, times3=150, note=8,
             renamed=7, extra=42, corner=7)
# A removed `using` keeps its binding: `word` stays resolved after the restore.
restored = dict(before, word="exported")
want = dict(before=before, after=after, restored=restored)[sys.argv[2]]
got = {}
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"change: (\w+) = (.*)$", line)
    if m: got[m.group(1)] = m.group(2)
bad = [k for k in want if got.get(k) != str(want[k])]
extra = [k for k in got if k not in want]
print(f"=== changes({sys.argv[2]}): {len(want) - len(bad)} of {len(want)} as expected"
      + (f"; wrong {', '.join(f'{k}={got.get(k)}' for k in bad)}" if bad else "")
      + (f"; unexpected {', '.join(extra)}" if extra else ""))
sys.exit(1 if bad or extra else 0)
PY
}

edit() {
    cp "$HZ/changes-after.jl" "$SRC/changes.jl" &&
    cp "$HZ/HazardApp-after.jl" "$SRC/HazardApp.jl" &&
    cp "$HZ/data-after.txt" "$SRC/data.txt" &&
    cp "$HZ/extra.jl" "$SRC/extra.jl" &&
    mv "$SRC/renamed.jl" "$SRC/renamed2.jl" && echo "=== edited: changes.jl, HazardApp.jl, data.txt, extra.jl, renamed.jl -> renamed2.jl"
}
reformat() { cp "$HZ/changes-reformat.jl" "$SRC/changes.jl" && echo "=== reformatted changes.jl"; }
restore() {
    git -C "$JH" checkout -- contrib/reactive-compiler/tool/m6_hazard/HazardApp/src &&
    rm -f "$SRC/extra.jl" "$SRC/renamed2.jl" && echo "=== restored HazardApp/src"
}

# The log of the edit's rebuild: every category once, the kept method of
# the @eval loop, and a cone without the caller of the unchanged method.
categories() {
    local log=$OUT/$1.log failed=0 pattern
    for pattern in \
        "rc: change H3 renamed.jl -> renamed2.jl, 1 methods renamed" \
        "rc: change A3 changes.jl:[0-9]+ special \(removed\), 1 methods deleted" \
        "rc: change C4 HazardApp.jl:[0-9]+ include \(includes renamed2.jl\), 0 methods" \
        "rc: change C4 HazardApp.jl:[0-9]+ include \(includes extra.jl\), 0 methods" \
        "rc: change A4 changes.jl:[0-9]+ resig, 1 methods, 1 deleted" \
        "rc: change A6 changes.jl:[0-9]+ s, 1 methods" \
        "rc: change A6 changes.jl:[0-9]+ gen_times, 1 methods" \
        "rc: change B2 changes.jl:[0-9]+ Box, 2 methods, 2 deleted" \
        "rc: change A4 changes.jl:[0-9]+ area_of( \(names Box\))?, 1 methods, 1 deleted" \
        "rc: change B2 changes.jl:[0-9]+ UNIT_BOX \(names Box\), 0 methods" \
        "rc: change B2 changes.jl:[0-9]+ Crate \(names Box\), 2 methods, 2 deleted" \
        "rc: change B2 changes.jl:[0-9]+ crate_size \(names Crate\), 1 methods, 1 deleted" \
        "rc: change B3 changes.jl:[0-9]+ Middle, 0 methods" \
        "rc: change B3 changes.jl:[0-9]+ Item \(names Middle\), 1 methods, 1 deleted" \
        "rc: change C1 changes.jl:[0-9]+ FACTOR, 0 methods" \
        "rc: change C2 changes.jl:[0-9]+ tally, 0 methods" \
        "rc: change C3 changes.jl:[0-9]+ using, 0 methods" \
        "rc: change C3 changes.jl:[0-9]+ guess_word \(resolves word differently\), 1 methods, 1 kept" \
        "rc: change D1 changes.jl:[0-9]+ @twice, 1 methods" \
        "rc: change D1 changes.jl:[0-9]+ @quad \(expands @twice\), 1 methods" \
        "rc: change D1 changes.jl:[0-9]+ quad_one \(expands @quad\), 1 methods" \
        "rc: change D2 changes.jl:[0-9]+ other, 2 methods, 1 kept" \
        "rc: change E1 changes.jl:[0-9]+ NOTE \(reads data.txt\), 0 methods" \
        "rc: change C4 extra.jl:[0-9]+ extra_value \(new file extra.jl\), 1 methods" \
        "rc: cone replaced Tuple\{typeof\(HazardApp.times3\), Int64\}" \
        "rc: cone closed Tuple\{typeof\(HazardApp.use_times3\)\}"
    do
        grep -qE "^$pattern\$" "$log" || { echo "=== $1: no line matches /$pattern/"; failed=1; }
    done
    grep -E "^rc: cone .*use_times2" "$log" && { echo "=== $1: the caller of the kept method is in the cone"; failed=1; }
    grep -q "^rc: refuse" "$log" && { echo "=== $1: a refusal"; failed=1; }
    [ $failed == 0 ] && echo "=== $1: every category is in the log; use_times2 is not in the cone"
    return $failed
}

# The reformat, and the rebuild after a refresh, apply nothing.
empty_apply() {
    grep -qE "^rc: applied 0 expressions and 0 removals" "$OUT/$1.log" ||
        { echo "=== $1: the rebuild did not give an empty apply set"; return 1; }
    grep -E "^rc: applied" "$OUT/$1.log" | sed "s/^/=== $1: /"
}

# The rebuild after the refresh precompiles the roots that the refresh added.
new_roots() {
    grep -qE "^rc: new [1-9][0-9]* method instances after the trace" "$OUT/$1.log" ||
        { echo "=== $1: the refreshed trace made no method instance"; return 1; }
    grep -E "^rc: new [0-9]+ method instances" "$OUT/$1.log" | sed "s/^/=== $1: /"
}

# The workload once to precompile the package, then once under
# --trace-compile: the roots without the noise of package precompilation.
# $1 = the trace file.
trace() {
    light trace-warm "$JULIA" --startup-file=no --project="$HZ/HazardApp" "$HZ/workload.jl" || return 1
    light trace "$JULIA" --startup-file=no --project="$HZ/HazardApp" \
        --trace-compile="$OUT/$1" "$HZ/workload.jl" || return 1
    echo "=== $1: $(grep -c '^precompile' "$OUT/$1") statements, $(grep -c HazardApp "$OUT/$1") of HazardApp"
}

# $1 = the log tag, $2 = the bundle, $3 = the trace file.
oracle() {
    light "oracle-$1" "$JULIA" --startup-file=no -J "$2/lib/julia/sys.so" "$TOOL/oracle.jl" \
        --tracked HazardApp --trace "$OUT/$3" || return 1
    grep "^info" "$OUT/oracle-$1.log" | sed "s/^/=== $1 /"
}

# $1 = the check number, $2 = its name, $3 = the pattern of the lines,
# $4 $5 = the files, $6 = a pattern of lines to leave out (optional).
check() {
    local a b lines n skip=${6:-^\$}
    a=$(grep -E "$3" "$4" | grep -vE "$skip"); b=$(grep -E "$3" "$5" | grep -vE "$skip")
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

# $1 = the chain log tag, $2 = the founding log tag, $3 = the trace file,
# $4 = output lines to leave out of check 3.
compare() {
    local failed=0
    check 1 "method tables" "^method " "$OUT/oracle-$1.log" "$OUT/oracle-$2.log" || failed=1
    check 2 "roots" "^root " "$OUT/oracle-$1.log" "$OUT/oracle-$2.log" || failed=1
    grep -E "^root .*HazardApp" "$OUT/oracle-$1.log" | grep -vqE " (compiled|gensym)$" &&
        { echo "=== check 2: a root of HazardApp is not compiled in the chain"; failed=1; }
    check 3 "output" "^(shape|change): " "$OUT/run-$1.log" "$OUT/run-$2.log" "${4:-}" || failed=1
    check 4 "globals" "^global " "$OUT/oracle-$1.log" "$OUT/oracle-$2.log" || failed=1
    return $failed
}

# A refused rebuild: $1 = the log tag, $2 = the reason pattern. The
# materialize fails, the store keeps its snapshots, no new snapshot
# directory stays, and the binary prints the restored values.
refused() {
    local snapshots
    snapshots=$(ls -d "$CHAIN"/reactive-store/s* | wc -l)
    if mat "mat-$1" "$CHAIN"; then
        echo "=== $1: the rebuild was not refused"; return 1
    fi
    grep -qE "^rc: refuse $2" "$OUT/mat-$1.log" || { echo "=== $1: no refusal line /$2/"; return 1; }
    grep -q "the rebuild is refused" "$OUT/mat-$1.log" || { echo "=== $1: the parent did not report the refusal"; return 1; }
    [ "$(ls -d "$CHAIN"/reactive-store/s* | wc -l)" == "$snapshots" ] ||
        { echo "=== $1: the store changed"; ls "$CHAIN/reactive-store"; return 1; }
    echo "=== $1: refused; the store keeps $snapshots snapshots"
    runbin "$1" "$CHAIN" restored
}

steps=${*:-found-chain run-s1 trace-s0 oracle-s1 edit mat-s2 run-s2 reformat mat-s3 run-s3 refresh mat-s4 run-s4 trace-final found-final run-final compare-final restore mat-s5 run-s5 compare-s1 refuse-option refuse-untracked}
for step in $steps; do
    case $step in
        found-chain) rm -rf "$OUT/chain" && mat mat-chain "$CHAIN" ;;
        run-s1) runbin s1 "$CHAIN" before ;;
        trace-s0) trace trace-s0.jl ;;
        oracle-s1) oracle s1 "$CHAIN" trace-s0.jl ;;
        edit) edit ;;
        mat-s2) mat mat-s2 "$CHAIN" && categories mat-s2 ;;
        run-s2) runbin s2 "$CHAIN" after ;;
        reformat) reformat ;;
        mat-s3) mat mat-s3 "$CHAIN" && empty_apply mat-s3 ;;
        run-s3) runbin s3 "$CHAIN" after ;;
        refresh) refresh ;;
        mat-s4) mat mat-s4 "$CHAIN" && empty_apply mat-s4 && new_roots mat-s4 ;;
        run-s4) runbin s4 "$CHAIN" after ;;
        trace-final) trace trace-final.jl ;;
        found-final) rm -rf "$OUT/final" && mat mat-final "$FINAL" ;;
        run-final) runbin final "$FINAL" after ;;
        compare-final) oracle s4 "$CHAIN" trace-final.jl && oracle final "$FINAL" trace-final.jl && compare s4 final trace-final.jl ;;
        restore) restore ;;
        mat-s5) mat mat-s5 "$CHAIN" ;;
        run-s5) runbin s5 "$CHAIN" restored ;;
        compare-s1) oracle s5 "$CHAIN" trace-s0.jl && compare s5 s1 trace-s0.jl "^change: word = " ;;
        refuse-option) cp "$HZ/HazardApp-optlevel.jl" "$SRC/HazardApp.jl" && refused option "F1 .*@optlevel is a module option"; rc=$?; restore; [ $rc == 0 ] ;;
        refuse-untracked) cp "$HZ/changes-corner.jl" "$SRC/changes.jl" && refused untracked "B2 .*the untracked untracked.jl:[0-9]+ corner_of names the type"; rc=$?; restore; [ $rc == 0 ] ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
