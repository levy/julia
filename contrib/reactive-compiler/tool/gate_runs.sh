#!/bin/bash
# The gate of the code that an expression runs (Step 7 of
# plan/pending/a-rebuild-equals-a-whole-build.md): an expression is evaluated
# again when the code that its evaluation runs changed, and its text did not.
# The application RunApp (tool/r1_runs) loads the path package RunLib. The edit
# of the gate replaces helpers.jl of RunLib: the function of an initializer,
# the function that an initializer calls on a value of an unknown type, the
# function that makes the expansion of a macro, a type whose value a constant
# and a table hold, the function that gives a generated function its body, and
# the functions that give a loop the methods that it defines and the names
# that it exports. users.jl holds the expressions that run them, and stays as
# it is. Two constants of users.jl must stay as they are: one whose
# initializer makes functions of its own, and one whose initializer counts its
# evaluations. statements.jl holds statements that fill a list and a table: the
# edit changes one and removes one, and the rebuild takes back what they did
# (decision D3). lines.jl holds a function that names its own line: the edit
# moves it and leaves its text, and the rebuilt function must name the new
# line (finding 43). A second edit moves the function again and changes nothing
# else. A macro of users.jl defines two methods that carry the lines of a
# function of helpers.jl, which builds the expansion: the edit changes that
# function and one of the methods, and the other method must stay (finding 44).
# markers.jl holds a type whose values the program keeps in the storage of its
# task: a later edit changes the type, and the rebuild must not find a value of
# the type of before in that storage (finding 46). The chain is compared with
# the founding of the edited sources.
# The environment chooses the form of the rebuild: JULIA_REACTIVE_SERVER=1 for
# a server, JULIA_REACTIVE_IMAGE_WRITE=overlay for overlays.
#   copy         - the packages into $OUT/src, where the gate edits them
#   found-chain  - materialize_app founds $OUT/chain/runapp
#   run-s1       - the founded binary prints the values of before the edit
#   edit         - helpers-after.jl replaces helpers.jl,
#                  statements-after.jl replaces statements.jl,
#                  lines-after.jl replaces lines.jl, and markers-after.jl
#                  replaces markers.jl
#   mat-s2       - the rebuild of the edit
#   run-s2       - the rebuilt binary prints the values of after the edit
#   refuse       - statements-refused.jl changes a statement that names no
#                  global: the rebuild refuses it (S1), and the binary prints
#                  the same values
#   move         - lines-moved.jl replaces lines.jl: the edit moves one
#                  function and changes no expression; the rebuilt binary
#                  names the new line
#   retype       - markers-retyped.jl replaces markers.jl: the type of the
#                  values in the storage of the task gets a field
#   trace        - the workload under --trace-compile at the edited sources
#   found-final  - materialize_app founds $OUT/final/runapp at those sources
#   run-final    - the founded binary: as the binary of the step retype
#   compare      - the four checks of the invariant: the method tables, the
#                  roots, the output, the globals
# Pass step names to run some steps, or nothing to run all of them in order.
# Run the gate under bounded-run: the steps take no cap of their own.
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-runs}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}
JULIA=${JULIA:-$JH/usr/bin/julia}
PC=${PC:-$(cd "$JH/.." && pwd)/PackageCompiler.jl}
TOOL=$JH/contrib/reactive-compiler/tool
SRC=$OUT/src
THREADS=${THREADS:-4}
TIMINGS=${TIMINGS:-1}
LANE=${LANE:-16-23}
LIGHT=${LIGHT:-24-27}
CHAIN=$OUT/chain/runapp
FINAL=$OUT/final/runapp
BEFORE="table=1 scaled=6 answer=11 answer_constant=101 theme=1_of_1_fields staged=2 loop=1 exports=TABLE handlers=2 stamp=1_of_1 themes=1_with_1_fields registry=first_second seen=1 notes=loaded line=3 accessors=1_and_10 marked=1_of_1_fields"
AFTER="table=2 scaled=9 answer=12 answer_constant=102 theme=2_of_2_fields staged=3 loop=2_and_3 exports=SCALED_TABLE handlers=3 stamp=1_of_1 themes=1_with_2_fields registry=first_third seen=0 notes=loaded line=5 accessors=2_and_10 marked=2_of_1_fields"
# The values after the step move, and after the step retype.
MOVED=${AFTER/line=5/line=6}
RETYPED=${MOVED/marked=2_of_1_fields/marked=2_of_2_fields}
mkdir -p "$OUT/depot"

# One run on the build lane. $1 = log name, $2.. = the command.
lane() {
    local name=$1; shift
    nice -n 10 taskset -c "$LANE" /usr/bin/time -v \
        env JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=$TIMINGS \
            JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" \
        "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed \(wall|Maximum resident|rc: (file|apply|applied|eval|new [0-9]|warning|removed|refuse|change|replay)|reactive: delta|materialize_app|shape: |=== " "$OUT/$name.log"
    return $rc
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
materialize_app("$SRC/RunApp", ARGS[1];
    workload = "$SRC/workload.jl",
    executables = ["runapp" => "julia_main"],
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

# $1 = a tag, $2 = the bundle, $3 = the expected shape lines, "name=value ...",
# where `_` stands for a space.
runbin() {
    lane "run-$1" "$2/bin/runapp"
    local want got
    want=$(for pair in $3; do echo "shape: ${pair%%=*} = ${pair#*=}" | tr _ ' '; done; echo "shape: state = 0")
    got=$(grep "^shape: " "$OUT/run-$1.log")
    if [ "$want" == "$got" ]; then
        echo "=== run-$1: as expected"
    else
        echo "=== run-$1: not as expected (< expected, > printed)"; diff <(echo "$want") <(echo "$got") | grep "^[<>]"
        return 1
    fi
}

copy() { rm -rf "$SRC" && cp -a "$TOOL/r1_runs" "$SRC" && echo "=== copied the packages to $SRC"; }

edit() {
    cp "$TOOL/r1_runs/helpers-after.jl" "$SRC/RunLib/src/helpers.jl" &&
    cp "$TOOL/r1_runs/statements-after.jl" "$SRC/RunLib/src/statements.jl" &&
    cp "$TOOL/r1_runs/lines-after.jl" "$SRC/RunLib/src/lines.jl" &&
    cp "$TOOL/r1_runs/markers-after.jl" "$SRC/RunLib/src/markers.jl" &&
    echo "=== edited helpers.jl, statements.jl, lines.jl and markers.jl of RunLib"
}

# An edit that moves one function and changes no expression: the function
# names its line, so the rebuild evaluates it again.
move() {
    cp "$TOOL/r1_runs/lines-moved.jl" "$SRC/RunLib/src/lines.jl" && mat mat-moved "$CHAIN" || return 1
    runbin moved "$CHAIN" "$MOVED"
}

# An edit that changes a type whose values the program keeps in the storage of
# its task. An earlier rebuild of the same server evaluated the initializer
# that puts a value there.
retype() {
    cp "$TOOL/r1_runs/markers-retyped.jl" "$SRC/RunLib/src/markers.jl" && mat mat-retyped "$CHAIN" || return 1
    runbin retyped "$CHAIN" "$RETYPED"
}

# A changed statement that names no global: the rebuild refuses it (S1), and
# the program stays as it was.
refuse() {
    cp "$TOOL/r1_runs/statements-refused.jl" "$SRC/RunLib/src/statements.jl"
    if mat mat-refused "$CHAIN"; then
        echo "=== refuse: the rebuild of a statement that names no global passed"; return 1
    fi
    grep -q "S1" "$OUT/mat-refused.log" || { echo "=== refuse: no S1 in the log"; return 1; }
    echo "=== refuse: the rebuild refused the statement that names no global (S1)"
    cp "$TOOL/r1_runs/statements-after.jl" "$SRC/RunLib/src/statements.jl"
    runbin s2-after-refusal "$CHAIN" "$AFTER"
}

trace() {
    light trace-warm "$JULIA" --startup-file=no --project="$SRC/RunApp" "$SRC/workload.jl" || return 1
    # A workload that compiles nothing at run time writes no file: its trace
    # is empty.
    : > "$OUT/trace.jl"
    light trace "$JULIA" --startup-file=no --project="$SRC/RunApp" \
        --trace-compile="$OUT/trace.jl" "$SRC/workload.jl" || return 1
    echo "=== trace: $(grep -c '^precompile' "$OUT/trace.jl") statements"
}

oracle() {
    light "oracle-$1" "$JULIA" --startup-file=no -J "$2/lib/julia/sys.so" "$TOOL/oracle.jl" \
        --tracked RunApp,RunLib --trace "$OUT/trace.jl" || return 1
    grep "^info" "$OUT/oracle-$1.log" | sed "s/^/=== $1 /"
}

# $1 = the check number, $2 = its name, $3 = the pattern of the lines,
# $4 $5 = the files.
check() {
    local a b lines n
    a=$(grep -E "$3" "$4"); b=$(grep -E "$3" "$5")
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

compare() {
    oracle chain "$CHAIN" && oracle final "$FINAL" || return 1
    local failed=0
    check 1 "method tables" "^method " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    check 2 "roots" "^root " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    check 3 "output" "^shape: " "$OUT/run-retyped.log" "$OUT/run-final.log" || failed=1
    check 4 "globals" "^global " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    return $failed
}

steps=${*:-copy found-chain run-s1 edit mat-s2 run-s2 refuse move retype trace found-final run-final compare}
for step in $steps; do
    case $step in
        copy) copy ;;
        found-chain) rm -rf "$OUT/chain" && mat mat-chain "$CHAIN" ;;
        run-s1) runbin s1 "$CHAIN" "$BEFORE" ;;
        edit) edit ;;
        mat-s2) mat mat-s2 "$CHAIN" ;;
        run-s2) runbin s2 "$CHAIN" "$AFTER" ;;
        refuse) refuse ;;
        move) move ;;
        retype) retype ;;
        trace) trace ;;
        found-final) rm -rf "$OUT/final" && mat mat-final "$FINAL" ;;
        run-final) runbin final "$FINAL" "$RETYPED" ;;
        compare) compare ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
