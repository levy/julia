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
# else. A second function of lines.jl logs: a server evaluates it two times,
# and the id of its log statement must be that of a whole build (finding 47). Two macros of users.jl define methods that carry the lines of a
# function of helpers.jl, which builds the expansion. The edit changes each of
# those functions. Of the first macro it changes one method, and the other one
# must stay. Of the second macro it changes no method: the rebuild does not
# evaluate the user again, and its method must stay (finding 44).
# markers.jl holds a type whose values the program keeps in the storage of its
# task: a later edit changes the type, and the rebuild must not find a value of
# the type of before in that storage (finding 46). moved.jl holds what the edit
# removes or moves: a function and a struct that go to another module with
# their exports, while a third module names the struct in a signature, a
# `using` line, a struct, a constant, and a module that gets another name; no
# name of before must stay (finding 1, decision D2). Two functions of moved.jl
# change places between a module that defines one and a module that imports it
# by its name: each must be the function of its new module (finding 49). A
# macro of markers.jl defines two types and an alias from one struct, and the
# second type has a field of the type that the step retype changes: the
# methods of users.jl that name the second type and the alias must be those of
# the new type (finding 52). The program calls the first of these methods
# through a dynamic call, so the trace has a statement that names the second
# type: after the step retype the statement has the same text and another
# type, and the rebuild must compile it for the new type (finding 10).
# order.jl holds the use of a macro that reads a definition that comes after
# it in the load order: a whole build expands the use before that definition
# exists, and a rebuild that evaluates the use again would expand it with the
# definition. The step order changes a struct that the use names, and the
# rebuild must refuse (finding 53). The step fail makes an edit that throws
# at its evaluation, and then its fix: a server must hold nothing of the edit
# that failed (finding 7, decision D4). The step input changes an input that
# no tracked source holds, and the build must stop with its name (finding 8,
# decision D5). The chain is compared with the founding of the edited sources.
# The environment chooses the form of the rebuild: JULIA_REACTIVE_SERVER=1 for
# a server, JULIA_REACTIVE_IMAGE_WRITE=overlay for overlays.
#   copy         - the packages into $OUT/src, where the gate edits them
#   found-chain  - materialize_app founds $OUT/chain/runapp
#   run-s1       - the founded binary prints the values of before the edit
#   edit         - helpers-after.jl replaces helpers.jl,
#                  statements-after.jl replaces statements.jl,
#                  lines-after.jl replaces lines.jl, markers-after.jl
#                  replaces markers.jl, and moved-after.jl replaces moved.jl
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
#   order        - order-after.jl replaces order.jl: the rebuild refuses to
#                  evaluate again the use of a macro that reads a later
#                  definition, and the binary prints the same values
#   fail         - an edit adds a method and a constant whose initializer
#                  throws: the build fails. The fix takes both out, and the
#                  next rebuild holds nothing of the failed edit
#   late         - an edit adds a method, and the link of the build fails,
#                  after the save of a server: the next build starts a new
#                  server from the last snapshot of the store, and the program
#                  holds the method
#   input        - the Manifest entry of a package changes, then the text of
#                  the workload: each build stops and names the input
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
BEFORE="table=1 scaled=6 answer=11 answer_constant=101 theme=1_of_1_fields staged=2 loop=1 exports=TABLE handlers=2 stamp=1_of_1 themes=1_with_1_fields registry=first_second seen=1 notes=loaded line=3 accessors=1_and_10 marked=1_of_1_fields steady=7 height=1 logged=3 journey=3 token=8_of_Left left=Token_travel+travel removed=+Gone+GONE+Before-After onlooker=+stay+Right handover=6_and_7_of_Early_and_Late+carry-bring badge=6 layout=plain"
AFTER="table=2 scaled=9 answer=12 answer_constant=102 theme=2_of_2_fields staged=3 loop=2_and_3 exports=SCALED_TABLE handlers=3 stamp=1_of_1 themes=1_with_2_fields registry=first_third seen=0 notes=loaded line=5 accessors=2_and_10 marked=2_of_1_fields steady=7 height=2 logged=5 journey=3 token=8_of_Right left=-travel removed=-Gone-GONE-Before+After onlooker=-stay-Right handover=6_and_7_of_Late_and_Early-carry+bring badge=6 layout=plain"
# The values after the step move, and after the step retype.
MOVED=${AFTER/line=5/line=6}
MOVED=${MOVED/logged=5/logged=6}
RETYPED=${MOVED/marked=2_of_1_fields/marked=2_of_2_fields}
mkdir -p "$OUT/depot"

# One run on the build lane. $1 = log name, $2.. = the command.
lane() {
    local name=$1; shift
    nice -n 10 taskset -c "$LANE" /usr/bin/time -v \
        env JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=$TIMINGS \
            JULIA_REACTIVE_COMPACT="${JULIA_REACTIVE_COMPACT:-100000,1000}" \
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
    cp "$TOOL/r1_runs/moved-after.jl" "$SRC/RunLib/src/moved.jl" &&
    echo "=== edited helpers.jl, statements.jl, lines.jl, markers.jl and moved.jl of RunLib"
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

# An edit that makes the rebuild evaluate again an expression that reads a
# definition that comes after it: the rebuild refuses it, and the program stays
# as it was.
order() {
    cp "$TOOL/r1_runs/order-after.jl" "$SRC/RunLib/src/order.jl"
    if mat mat-order "$CHAIN"; then
        echo "=== order: the rebuild of an expression that reads a later definition passed"
        runbin after-order "$CHAIN" "$RETYPED"
        return 1
    fi
    grep -q "defines other methods than the program holds" "$OUT/mat-order.log" ||
        { echo "=== order: no refusal of the expression in the log"; return 1; }
    echo "=== order: the rebuild refused the expression that reads a later definition"
    cp "$TOOL/r1_runs/RunLib/src/order.jl" "$SRC/RunLib/src/order.jl"
    runbin after-order "$CHAIN" "$RETYPED"
}

# An edit with a mistake: a new method in a file that loads early, and a
# constant whose initializer throws in a file that loads late. The build
# fails. The fix takes both out again, and the rebuild that follows must hold
# nothing of the failed edit: the comparison at the end finds a method that
# stayed in a server.
fail() {
    cp "$SRC/RunLib/src/helpers.jl" "$OUT/helpers-good.jl" && cp "$SRC/RunLib/src/order.jl" "$OUT/order-good.jl" || return 1
    echo 'stray_of_a_failed_edit() = 1' >> "$SRC/RunLib/src/helpers.jl"
    echo 'const BROKEN_BY_THE_EDIT = no_such_function_of_the_edit()' >> "$SRC/RunLib/src/order.jl"
    if mat mat-fail "$CHAIN"; then
        echo "=== fail: the rebuild of an edit that throws passed"; return 1
    fi
    grep -q "no_such_function_of_the_edit" "$OUT/mat-fail.log" ||
        { echo "=== fail: the log does not name the error of the edit"; return 1; }
    echo "=== fail: the rebuild of an edit that throws failed, as it must"
    cp "$OUT/helpers-good.jl" "$SRC/RunLib/src/helpers.jl" && cp "$OUT/order-good.jl" "$SRC/RunLib/src/order.jl" || return 1
    # The fix gives the sources of the last snapshot. The rebuild must save
    # all the same, so that the image shows what the server holds, so it does
    # not end early (D9).
    JULIA_REACTIVE_REBUILD_UNCHANGED=1 mat mat-fixed "$CHAIN" || return 1
    runbin fixed "$CHAIN" "$RETYPED"
}

# A build that fails late. A folder has the name of the file that the link of
# the build writes, so the link fails after the server applied the edit and
# saved it. The server then holds an edit that the store does not name, and
# its session says so (`pending`). The next build must start a new server from
# the last snapshot of the store. The method of the edit stays in the sources:
# the comparison at the end finds it when the chain holds it another number of
# times than one.
late() {
    local lib=$CHAIN/lib/julia store=$CHAIN/reactive-store next
    next=$(( $(sed -n 's/^id = \([0-9]*\)$/\1/p' "$store/store.toml" | sort -n | tail -1) + 1 ))
    echo 'method_of_a_late_failure() = 1' >> "$SRC/RunLib/src/helpers.jl"
    mkdir "$lib/sys.$next.so" "$lib/sys.so.next" || return 1
    if mat mat-late "$CHAIN"; then
        echo "=== late: the build passed with no file for its link"; return 1
    fi
    rmdir "$lib/sys.$next.so" "$lib/sys.so.next" || return 1
    if [ "${JULIA_REACTIVE_SERVER:-}" == 1 ]; then
        grep -q "^pending = $next$" "$store/server.toml" ||
            { echo "=== late: the session of the server does not name the pending snapshot $next"; return 1; }
    fi
    echo "=== late: the build failed at its link, as it must"
    mat mat-late-again "$CHAIN" || return 1
    if [ "${JULIA_REACTIVE_SERVER:-}" == 1 ]; then
        grep -q "pending = $next" "$OUT/mat-late-again.log" ||
            { echo "=== late: the next build did not start a new server for the pending snapshot"; return 1; }
        echo "=== late: the next build started a new server"
    fi
    runbin late "$CHAIN" "$RETYPED"
}

# An input of the store outside its tracked sources changes: the Manifest
# entry of a package, then the text of the workload. The image holds the input
# of its whole build, so each build stops and names the input, and the program
# stays as it was.
input() {
    local manifest=$SRC/RunApp/Manifest.toml
    cp "$manifest" "$OUT/Manifest-good.toml" && cp "$SRC/workload.jl" "$OUT/workload-good.jl" || return 1
    sed -i '/^\[\[deps.RunLib\]\]/,/^$/ s/^version = .*/version = "0.1.1"/' "$manifest"
    if mat mat-input-manifest "$CHAIN"; then
        echo "=== input: the rebuild with another Manifest entry passed"; return 1
    fi
    grep -q "an input of the store changed: the Manifest entry of RunLib" "$OUT/mat-input-manifest.log" ||
        { echo "=== input: the log does not name the Manifest entry"; return 1; }
    cp "$OUT/Manifest-good.toml" "$manifest"
    echo '# a line that the whole build did not read' >> "$SRC/workload.jl"
    if mat mat-input-workload "$CHAIN"; then
        echo "=== input: the rebuild with another workload passed"; return 1
    fi
    grep -q "an input of the store changed: the workload" "$OUT/mat-input-workload.log" ||
        { echo "=== input: the log does not name the workload"; return 1; }
    cp "$OUT/workload-good.jl" "$SRC/workload.jl"
    echo "=== input: the build stopped for the Manifest entry and for the workload, and named each"
    runbin after-input "$CHAIN" "$RETYPED"
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
    # A store that founds again by itself makes a whole build in the middle of
    # the chain, and the checks would then test only the rebuilds after it.
    if grep -l "materialize_app: the store founds again" "$OUT"/mat-*.log; then
        echo "=== compare: the store of the chain founded again by itself in the logs above"; failed=1
    fi
    check 1 "method tables" "^method " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    check 2 "roots" "^root " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    # The last binary of the chain: the one of the step late, of the step
    # fail, or of the step retype.
    local last=$OUT/run-retyped.log
    [ -f "$OUT/run-fixed.log" ] && last=$OUT/run-fixed.log
    [ -f "$OUT/run-late.log" ] && last=$OUT/run-late.log
    check 3 "output" "^shape: " "$last" "$OUT/run-final.log" || failed=1
    check 4 "globals" "^global " "$OUT/oracle-chain.log" "$OUT/oracle-final.log" || failed=1
    return $failed
}

steps=${*:-copy found-chain run-s1 edit mat-s2 run-s2 refuse move retype order fail late input trace found-final run-final compare}
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
        order) order ;;
        fail) fail ;;
        late) late ;;
        input) input ;;
        trace) trace ;;
        found-final) rm -rf "$OUT/final" && mat mat-final "$FINAL" ;;
        run-final) runbin final "$FINAL" "$RETYPED" ;;
        compare) compare ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
