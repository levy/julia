#!/bin/bash
# Gate C of Stage C (plan/pending/robust-incremental-compiler.md): the
# image of a chain does not grow with the edits, and holds one definition
# per live function. On the HazardApp package (tool/m6_hazard), with the
# edit of M6 (shapes-after.jl) and its reverse.
#   full         - materialize_app founds $OUT/hazard at the sources S0
#   format       - the image is version 3: one function table in the
#                  metadata, no per-shard function table, no duplicate
#                  text definition; prints the loadable size
#   cycle        - $CYCLES times: edit, rebuild, run, reverse, rebuild, run;
#                  the loadable size after every rebuild, and the check of
#                  every run
#   noedit       - two rebuilds with no edit; the second emits no function
#   heap         - the heap of the image holds no closed entry and no
#                  invalid code instance (the oracle's `info dead` line)
#   sizes        - the sizes of the chain: the last reverse against the first
# Pass step names to run some steps, or nothing to run all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/gate-c}
JH=${JH:-/home/projectured/workspace/julia-reactive}
JULIA=$JH/usr/bin/julia
PC=${PC:-/home/projectured/workspace/package-compiler-reactive}
HZ=$JH/contrib/reactive-compiler/tool/m6_hazard
THREADS=${THREADS:-8}
TIMINGS=${TIMINGS:-1}
LANE=${LANE:-16-23}
CYCLES=${CYCLES:-10}
APP=$OUT/hazard
SO=$APP/lib/julia/sys.so
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
    grep -E "Elapsed \(wall|Maximum resident|reactive: ([0-9]+ of|image header|delta)|materialize_app|=== " "$OUT/$name.log"
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

mat() { write_mat && lane "$1" "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl"; }

# The binary prints one `shape:` line per call shape.
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
state = got.get('state')
print(f"=== shapes({sys.argv[2]}): {len(want) - len(bad)} of {len(want)} as expected"
      + (f"; wrong {', '.join(f'{k}={got.get(k)}' for k in bad)}" if bad else "")
      + (f"; missing {', '.join(missing)}" if missing else "")
      + f"; persisted state {state}" + ("" if state == 0 else " (must be 0)"))
sys.exit(1 if bad or state != 0 else 0)
PY
}

# The loadable size of the image: text + data + bss of `size`, not the
# file, whose line tables keep a record of a dead function.
loadable() { size "$SO" | awk 'NR == 2 { print $4 }'; }

# $1 = a tag: append the size of the image now to $OUT/sizes.txt
record() { echo "$1 $(loadable) $(stat -c %s "$SO")" >> "$OUT/sizes.txt"; echo "=== size $1: loadable $(loadable), file $(stat -c %s "$SO")"; }

format() {
    local tables shards dups name n ok=0
    tables=$(nm "$SO" | grep -cE " [a-zA-Z] jl_fvar_(ptrs|names)$")
    shards=$(nm "$SO" | grep -cE " [a-zA-Z] jl_(fvar_(count|ptrs|idxs|names)|clone_(slots|ptrs|idxs))_[0-9]+$")
    # The CRT aliases (`__truncdfhf2`, ...) are local to every object by
    # design (inject_aliases); a Julia function has one definition.
    dups=$(nm "$SO" | awk '$2 ~ /^[Tt]$/ && $3 !~ /^__/ { print $3 }' | sort | uniq -d)
    echo "=== format: $tables of 2 function tables in the metadata, $shards per-shard function tables"
    echo "=== text definitions with one name twice: $(echo "$dups" | grep -c .)"
    echo "$dups" | grep . | head -10 | sed 's/^/===   /'
    [ "$tables" = 2 ] && [ "$shards" = 0 ] && [ -z "$dups" ] && ok=1
    # One text function per live specialization: these three have one.
    for name in driver chained bench_delta; do
        n=$(nm "$SO" | grep -cE " t julia_${name}_[0-9]+(\.r[0-9]+)?$")
        echo "=== text functions of $name: $n of 1"
        [ "$n" = 1 ] || ok=0
    done
    [ "$ok" = 1 ]
}

# The heap of the image holds no closed method table entry and no invalid
# code instance: the `info dead` line of the oracle.
heap() {
    lane heap "$JULIA" --startup-file=no -J "$SO" "$JH/contrib/reactive-compiler/tool/oracle.jl" --tracked HazardApp || return 1
    grep "^info" "$OUT/heap.log" | sed 's/^/=== heap /'
    grep -q "^info dead 0 closed entries, 0 invalid code instances" "$OUT/heap.log"
}

edit() { cp "$HZ/shapes-after.jl" "$HZ/$FILE" && echo "=== edited $FILE"; }
restore() { git -C "$JH" checkout -- "contrib/reactive-compiler/tool/m6_hazard/$FILE" && echo "=== restored $FILE"; }

cycle() {
    local i
    for i in $(seq 1 "$CYCLES"); do
        edit && mat "mat-edit-$i" && record "edit-$i" && runbin "after-$i" after || return 1
        restore && mat "mat-reverse-$i" && record "reverse-$i" && runbin "restored-$i" before || return 1
        format || return 1
    done
}

# A rebuild with no edit reuses everything: the second one emits no function.
noedit() {
    mat mat-noedit-1 && record noedit-1 || return 1
    mat mat-noedit-2 && record noedit-2 || return 1
    grep -E "reactive: [0-9]+ of [0-9]+ functions" "$OUT/mat-noedit-2.log" | grep -q "delta 0 functions" ||
        { echo "=== the second no-edit rebuild emits functions"; return 1; }
    runbin noedit before
}

sizes() {
    [ -f "$OUT/sizes.txt" ] || { echo "=== no sizes recorded"; return 1; }
    local first last
    first=$(awk '$1 == "reverse-1" { print $2 }' "$OUT/sizes.txt")
    last=$(awk '$1 == "reverse-'"$CYCLES"'" { print $2 }' "$OUT/sizes.txt")
    echo "=== sizes (tag loadable file):"; sed 's/^/===   /' "$OUT/sizes.txt"
    [ -n "$first" ] && [ -n "$last" ] || { echo "=== the cycle did not record both ends"; return 1; }
    echo "=== loadable after reverse 1: $first, after reverse $CYCLES: $last, growth $((last - first)) bytes"
}

steps=${*:-full format cycle noedit heap sizes}
for step in $steps; do
    case $step in
        full) rm -rf "$APP" "$OUT/sizes.txt" && mat mat-full && record full && runbin full before ;;
        format) format ;;
        cycle) cycle ;;
        noedit) noedit ;;
        heap) heap ;;
        sizes) sizes ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
