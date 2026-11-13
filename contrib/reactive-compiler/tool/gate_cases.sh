#!/bin/bash
# The gate of the edit cases (Step 3 of
# plan/pending/a-rebuild-equals-a-whole-build.md): a table of small edits, each
# one a case that a rebuild must apply as a whole build does, or refuse. The
# cases say again, in the form of this gate, the documented limits of Revise.jl
# and the edits of its test suite: the server of a rebuild does the job of
# Revise, with the image of a whole build as its goal.
# The application CaseApp (tool/r1_cases) loads the path package CaseLib. Each
# file of CaseLib/src/cases holds one module with a function `shown`, and the
# file of the same name in cases-after holds the module after the edit. A case
# of more than one file has a folder of its name beside its file, with the
# files that the module includes; the folder in cases-after is the folder after
# the edit. The program prints what `shown` answers for each case.
#   copy         - the packages into $OUT/src, with a CaseLib.jl that includes
#                  each case
#   found-chain  - materialize_app founds $OUT/chain/caseapp
#   cases        - each case in its turn: its text of after replaces its text
#                  of before, and one rebuild follows. A rebuild that is refused
#                  is no fault: the case keeps its text of before, and the gate
#                  counts it. A build that stops because an input of the store
#                  changed counts as a refusal. A case that
#                  r1_cases/must-refuse.txt names must be refused, and each
#                  other case must be applied: a refusal of it is a fault of
#                  the part of the rebuild that takes most edits. A store
#                  that founds again by itself is a fault: the comparison at
#                  the end would then test only the cases after that whole
#                  build, so the gate gives the store a bound that it does
#                  not reach (JULIA_REACTIVE_COMPACT). $CASES
#                  names the cases to take, by file name
#                  with no extension; the default is all of them
#   run-chain    - the rebuilt binary prints the line of each case
#   trace        - the workload under --trace-compile at the edited sources
#   found-final  - materialize_app founds $OUT/final/caseapp at those sources
#   run-final    - the founded binary prints the line of each case
#   control      - a second whole build of the same sources, with the tracked
#                  packages compiled again: the lines of the oracle that differ
#                  between the two whole builds are the noise of the oracle (the
#                  hash method of an enum holds the build id of its module)
#   compare      - the checks of the invariant: the method tables, the output
#                  and the globals must be equal. The roots are counted and not
#                  failed: the edit of a case gives the program values of other
#                  types to print, and only a new trace names their methods
# Pass step names to run some steps, or nothing to run all of them in order.
# Run the gate under bounded-run: the steps take no cap of their own.
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-cases}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
JULIA=${JULIA:-$JH/usr/bin/julia}
PC=${PC:-$(cd "$JH/.." && pwd)/PackageCompiler.jl}
TOOL=$JH/contrib/reactive-compiler/tool
SRC=$OUT/src
THREADS=${THREADS:-4}
TIMINGS=${TIMINGS:-1}
LANE=${LANE:-16-23}
LIGHT=${LIGHT:-24-27}
CHAIN=$OUT/chain/caseapp
FINAL=$OUT/final/caseapp
mkdir -p "$OUT/depot"

# One run on the build lane. $1 = log name, $2.. = the command.
lane() {
    local name=$1; shift
    nice -n 10 taskset -c "$LANE" /usr/bin/time -v \
        env JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=$TIMINGS \
            JULIA_REACTIVE_COMPACT="${JULIA_REACTIVE_COMPACT:-100000,1000}" \
            JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" \
        "$@" > "$OUT/$name.log" 2>&1
}

# A light run outside the build lane: the oracle and the trace.
light() {
    local name=$1; shift
    taskset -c "$LIGHT" env JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    return $rc
}

# mat.jl takes the bundle directory as its argument; the store inside it
# decides between a founding and a rebuild.
write_mat() {
    cat > "$OUT/mat.jl" <<EOF
import Pkg; Pkg.instantiate()
using PackageCompiler
materialize_app("$SRC/CaseApp", ARGS[1];
    workload = "$SRC/workload.jl",
    executables = ["caseapp" => "julia_main"],
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

mat() { write_mat && lane "$1" "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl" "$2"; }

# The files of the cases, by name, in the order of the names.
case_names() { (cd "$TOOL/r1_cases/CaseLib/src/cases" && ls *.jl | sed 's/\.jl$//' | sort); }

# The module that the file of a case defines.
case_module() { sed -n 's/^module \([A-Za-z_][A-Za-z_0-9]*\).*/\1/p' "$TOOL/r1_cases/CaseLib/src/cases/$1.jl" | head -1; }

# CaseLib.jl is written here and not kept in the tree: it includes each case
# by a literal path, and names the module of each case for the application.
copy() {
    rm -rf "$SRC" && cp -a "$TOOL/r1_cases" "$SRC" || return 1
    local name modules=""
    {
        echo "# The library of the gate of the edit cases (tool/gate_cases.sh): one module"
        echo "# for each case. The gate writes this file from the list of the case files."
        echo "module CaseLib"
        for name in $(case_names); do
            echo "include(\"cases/$name.jl\")"
            modules="$modules:$(case_module "$name"), "
        done
        echo "const CASES = ($modules)"
        echo "end"
    } > "$SRC/CaseLib/src/CaseLib.jl"
    echo "=== copied the packages to $SRC with $(case_names | wc -l) cases"
}

runbin() {
    lane "run-$1" "$2/bin/caseapp" || { echo "=== run-$1: the program failed; see $OUT/run-$1.log"; return 1; }
    echo "=== run-$1: $(grep -c '^shape: ' "$OUT/run-$1.log") lines"
}

# Put the text of a case into the sources: its file, and its folder when it
# has one. $1 = the folder that holds the text, $2 = the name of the case.
put_case() {
    cp "$1/$2.jl" "$SRC/CaseLib/src/cases/$2.jl" || return 1
    rm -rf "$SRC/CaseLib/src/cases/$2"
    if [ -d "$1/$2" ]; then cp -a "$1/$2" "$SRC/CaseLib/src/cases/$2" || return 1; fi
}

# Each case in its turn. A refusal keeps the text of before for that case, so
# the sources at the end are those that the chain holds. A rebuild that fails
# in another way is a fault: the case keeps its text of before, the chain is
# founded again at the sources that it holds, and the gate goes on and fails at
# the end.
cases() {
    local name applied=0 refused=0 faults=0
    : > "$OUT/refused.txt"
    : > "$OUT/faults.txt"
    for name in ${CASES:-$(case_names)}; do
        [ -f "$TOOL/r1_cases/cases-after/$name.jl" ] || { echo "=== cases: $name has no text of after"; return 1; }
        put_case "$TOOL/r1_cases/cases-after" "$name" || return 1
        if mat "mat-$name" "$CHAIN"; then
            if grep -q "materialize_app: the store founds again" "$OUT/mat-$name.log"; then
                faults=$((faults + 1))
                echo "    $name: FAULT: the store founded again by itself, so this rebuild tested nothing"
                echo "$name" >> "$OUT/faults.txt"
                continue
            fi
            applied=$((applied + 1))
            echo "    $name: $(grep -h -o "rc: applied [0-9]* expressions and [0-9]* removals" "$OUT/mat-$name.log" "$CHAIN/reactive-store/server.log" 2>/dev/null | tail -1)"
            if grep -qx "$name" "$TOOL/r1_cases/must-refuse.txt"; then
                faults=$((faults + 1))
                echo "    $name: FAULT: the rebuild applied a case that it must refuse"
                echo "$name" >> "$OUT/faults.txt"
            fi
        elif grep -q "the rebuild is refused\|an input of the store changed" "$OUT/mat-$name.log"; then
            refused=$((refused + 1))
            put_case "$TOOL/r1_cases/CaseLib/src/cases" "$name" || return 1
            if grep -q "the rebuild is refused" "$OUT/mat-$name.log"; then
                echo "    $name: refused: $(grep -A 1 "the rebuild is refused" "$OUT/mat-$name.log" | tail -1 | cut -c1-200)"
            else
                echo "    $name: stopped: $(grep -o "an input of the store changed: [^.]*" "$OUT/mat-$name.log" | head -1 | cut -c1-200)"
            fi
            echo "$name" >> "$OUT/refused.txt"
            if ! grep -qx "$name" "$TOOL/r1_cases/must-refuse.txt"; then
                faults=$((faults + 1))
                echo "    $name: FAULT: the rebuild refused a case that it must apply"
                echo "$name" >> "$OUT/faults.txt"
            fi
        else
            faults=$((faults + 1))
            put_case "$TOOL/r1_cases/CaseLib/src/cases" "$name" || return 1
            echo "    $name: FAULT: $(grep -m 1 -o "the server answered .*\|ERROR: .*" "$OUT/mat-$name.log" | cut -c1-220)"
            echo "$name" >> "$OUT/faults.txt"
            rm -rf "$OUT/chain"
            mat "mat-refound-$name" "$CHAIN" || { echo "=== cases: the founding after the fault of $name failed"; return 1; }
        fi
    done
    echo "=== cases: $applied applied, $refused refused, $faults faults"
    [ "$faults" == 0 ]
}

trace() {
    light trace-warm "$JULIA" --startup-file=no --project="$SRC/CaseApp" "$SRC/workload.jl" || return 1
    : > "$OUT/trace.jl"
    light trace "$JULIA" --startup-file=no --project="$SRC/CaseApp" \
        --trace-compile="$OUT/trace.jl" "$SRC/workload.jl" || return 1
    echo "=== trace: $(grep -c '^precompile' "$OUT/trace.jl") statements"
}

oracle() {
    light "oracle-$1" "$JULIA" --startup-file=no -J "$2/lib/julia/sys.so" "$TOOL/oracle.jl" \
        --tracked CaseApp,CaseLib --trace "$OUT/trace.jl" || return 1
    grep "^info" "$OUT/oracle-$1.log" | sed "s/^/=== $1 /"
}

# A second whole build of the same sources. A fact of the oracle that differs
# between two whole builds says nothing about a rebuild: its key goes to
# noise.txt, the line without its last word.
control() {
    rm -rf "$OUT/control" "$OUT/depot/compiled"/*/CaseLib "$OUT/depot/compiled"/*/CaseApp
    mat mat-control "$OUT/control/caseapp" || { echo "=== control: the founding failed; see $OUT/mat-control.log"; return 1; }
    oracle control "$OUT/control/caseapp" && oracle final "$FINAL" || return 1
    diff <(grep -E "^(method|global) " "$OUT/oracle-control.log") <(grep -E "^(method|global) " "$OUT/oracle-final.log") |
        grep -E "^[<>] " | sed -E 's/^[<>] //; s/ [^ ]*$/ /' | sort -u > "$OUT/noise.txt"
    echo "=== control: $(wc -l < "$OUT/noise.txt") facts differ between two whole builds of the same sources"
}

# The lines of a file that match a pattern, without the noise of the oracle.
facts() {
    if [ -s "$OUT/noise.txt" ]; then grep -E "$1" "$2" | grep -v -F -f "$OUT/noise.txt"; else grep -E "$1" "$2"; fi
}

# $1 = the check number, $2 = its name, $3 = the pattern of the lines,
# $4 $5 = the files.
check() {
    local a b lines n
    a=$(facts "$3" "$4"); b=$(facts "$3" "$5")
    if [ "$a" == "$b" ]; then
        echo "=== check $1 $2: equal ($(echo "$a" | grep -c .) lines)"
        return 0
    fi
    lines=$(diff <(echo "$a") <(echo "$b") | grep -E "^[<>]")
    n=$(echo "$lines" | grep -c .)
    echo "=== check $1 $2: $n lines differ (< chain, > founding)"
    echo "$lines" | head -40 | cut -c1-240
    return 1
}

compare() {
    oracle chain "$CHAIN" && oracle final "$FINAL" || return 1
    local failed=0
    check 1 "method tables" "^method " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    check 2 "roots (counted, not failed)" "^root " "$OUT/oracle-chain.log" "$OUT/oracle-final.log"
    check 3 "output" "^shape: " "$OUT/run-chain.log" "$OUT/run-final.log" || failed=1
    check 4 "globals" "^global " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    return $failed
}

steps=${*:-copy found-chain cases run-chain trace found-final run-final control compare}
status=0
for step in $steps; do
    case $step in
        copy) copy ;;
        found-chain) rm -rf "$OUT/chain" && mat mat-chain "$CHAIN" && echo "=== found-chain: founded" ;;
        cases) cases || { echo "=== step cases has faults"; status=1; } ;;
        run-chain) runbin chain "$CHAIN" ;;
        trace) trace ;;
        found-final) rm -rf "$OUT/final" && mat mat-final "$FINAL" && echo "=== found-final: founded" ;;
        run-final) runbin final "$FINAL" ;;
        control) control ;;
        compare) compare ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T), status $status"
exit $status
