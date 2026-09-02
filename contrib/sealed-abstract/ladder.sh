#!/usr/bin/env bash
# Build every ladder example at every policy level the toolchain supports, and
# print the matrix.
#
#   ./ladder.sh            every example
#   ./ladder.sh NAME...    only those
#
# The levels map onto what exists today (plan section 42):
#
#   proven   STOCK inference and nothing else: the sealed apparatus off
#            (SEALED_WORLD=0) and the union splitter at Julia's own limit
#            (SEALED_SPLIT_LIMIT=4). Both are needed. With the splitter left at
#            20 000, seven of ten examples passed a "proven" level that did not
#            exist; with the apparatus left on, the verifier accepts a dynamic
#            call whose targets happen to be compiled.
#   sealed   the abstract-as-union map ON, so an abstract type IS the union of
#            its concretes
#   trace    the map off, and the recorded dispatch targets registered
#
# An example is a TEST because it declares which levels must pass and which
# must fail. One that passes too easily is not testing its mechanism.
#
# The declaration is one line in the example:
#
#   # EXPECT proven=pass sealed=pass trace=pass:520
#
# `<level>=<verdict>` states the outcome. The optional `:<n>` bounds the size
# of the compiled set (`codeinfos`) at that level. A bound is how a
# count-shaped defect becomes visible: a compiler that compiles four copies of
# every method still produces a correct binary, and every verdict-only test
# calls that a pass.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/sealed_paths.sh"
cd "$HERE"
W=work-regress/ladder
mkdir -p $W
NAMES=${*:-$(ls examples/*.jl | xargs -n1 basename | sed 's/\.jl$//')}

build() {           # build <program> <out> <extra env...>
    local prog=$1 out=$2; shift 2
    rm -f "$out"
    env "$@" SEALED_TRACE_PROGRAM="$HERE/$prog" timeout 60 julia +1.13 --startup-file=no \
        --project=env2 "$SEALED_JULIAC" --output-exe "$out" --experimental \
        --trim=safe "$3" > "$out.log" 2>&1
    [ $? -eq 0 ] && [ -x "$out" ]
}

# THREE OUTCOMES, not two.
#
#   pass   the compiler produced a binary AND it prints what the source prints
#   fail   the compiler REJECTED the program and said why - a diagnosed
#          refusal, which for a negative test is the correct outcome
#   error  the compiler crashed: no diagnosis, just an exception. Almost never
#          expected. It is only acceptable where a construct is known to be
#          unimplemented and crashing is the agreed placeholder.
#
# The distinction matters because `fail` and `error` look identical from an
# exit code, and only one of them is a compiler doing its job.
classify() {          # classify <binary> <log> <source>
    local bin=$1 log=$2 src=$3
    if [ -x "$bin" ]; then
        local want got
        # `-L seal_hints.jl` so a program that calls a hint runs with no
        # compiler at all. Every hint is the identity there.
        want=$(timeout 60 julia +1.13 --startup-file=no -L seal_hints.jl "$src" 2>/dev/null | tail -1)
        got=$("$bin" 2>&1 | tail -1)
        [ "$got" = "$want" ] && echo pass || echo WRONG
        return
    fi
    if grep -q "Trim verify finished with" "$log" 2>/dev/null; then
        echo fail
    else
        echo error
    fi
}

# ONE EXAMPLE, START TO FINISH. Its row goes to a file so the pool can run
# examples concurrently and the table still prints in a stable order.
one() {
    local n=$1
    local p=examples/$n.jl
    [ -f "$p" ] || return 0
    local pv sl tr d exp verdict cpv csl ctr lvl name rest got count decl want max
    # AN EXAMPLE MAY DECLARE THE SPLIT BUDGET IT IS TESTED UNDER. A union cross
    # product is not a wrong answer, it is a slow one, so the test is whether
    # the compiler FALLS BACK when the product is too wide and still produces a
    # correct binary. `# SPLIT-CASES n` sets SEALED_SPLIT_CASES for this
    # example's builds.
    local sc
    sc=$(grep -m1 "^# SPLIT-CASES " "$p" | awk '{print $3}')
    [ -n "$sc" ] && export SEALED_SPLIT_CASES="$sc" || unset SEALED_SPLIT_CASES
    # AND THE TARGET ROOTS. `sealed_keep` drops every drained target whose
    # module is not a root, and with no roots configured it drops ALL of them,
    # so NO EXAMPLE EXERCISES THE DRAIN. That is a real coverage hole: the
    # drain is a major mechanism and every example is blind to it.
    #
    # `# TRACE-ROOTS Main` turns it on, and no example declares it yet because
    # the obvious attempt does not work: `union_cross_product` with roots set
    # to Main drains 1333 targets and fails with 844 errors, where without
    # roots it drains none and fails with 2. A drain example has to be built
    # so that ONE site is declined, not five with every match of each.
    local tr_roots
    tr_roots=$(grep -m1 "^# TRACE-ROOTS " "$p" | cut -d' ' -f3-)
    [ -n "$tr_roots" ] && export SEALED_TARGET_ROOTS="$tr_roots" || unset SEALED_TARGET_ROOTS
    # A STALE ROW IS A LIE. If this example dies, the table must not print the
    # previous run's verdict for it.
    rm -f $W/$n.row

    rm -f $W/$n.proven; SEALED_WORLD=0 SEALED_SPLIT_LIMIT=4 SEALED_SPLIT=0 \
        SEALED_TRACE_PROGRAM="$HERE/$p" timeout 60 julia +1.13 \
        --startup-file=no --project=env2 "$SEALED_JULIAC" --output-exe $W/$n.proven \
        --experimental --trim=safe "$p" > $W/$n.proven.log 2>&1
    pv=$(classify $W/$n.proven $W/$n.proven.log "$p")

    rm -f $W/$n.sealed; SEALED_TRACE_PROGRAM="$HERE/$p" timeout 60 julia +1.13 \
        --startup-file=no --project=env2 "$SEALED_JULIAC" --output-exe $W/$n.sealed \
        --experimental --trim=safe "$p" > $W/$n.sealed.log 2>&1
    sl=$(classify $W/$n.sealed $W/$n.sealed.log "$p")

    # DELETE THE STALE TRACE FIRST. A recorder that fails leaves the previous
    # run's trace in place, and the build then succeeds on it - so a broken
    # recorder reads as a passing ladder. That is the same stale-artifact bug
    # buildcheck.sh exists for, and it hid a broken recorder once already.
    rm -f $W/$n.trace
    SEALED_RECORD_ONLY=1 SEALED_SPLIT=0 SEALED_TRACE_PROGRAM="$HERE/$p" \
        SEALED_TRACE_OUT=$W/$n.trace timeout 60 julia +1.13 --startup-file=no --project=env2 \
        "$SEALED_JULIAC" --output-exe $W/$n.ignore --experimental --trim=safe \
        entry_from_edges.jl > $W/$n.rec.log 2>&1
    d=$(grep -oE '[0-9]+ entries' $W/$n.rec.log | head -1)
    # No trace file means the RECORDER failed, whatever the builds then do.
    [ -f $W/$n.trace ] || d="RECORDER-FAILED"
    rm -f $W/$n.trace_build
    SEALED_SPLIT=0 SEALED_TRACE_PROGRAM="$HERE/$p" SEALED_TRACE_IN=$W/$n.trace timeout 60 \
        julia +1.13 --startup-file=no --project=env2 "$SEALED_JULIAC" \
        --output-exe $W/$n.trace_build --experimental --trim=safe entry_build_from_trace.jl \
        > $W/$n.trace.log 2>&1
    tr=$(classify $W/$n.trace_build $W/$n.trace.log "$p")

    # HOW MUCH DID IT COMPILE. Some defects are a count, not a crash: the build
    # succeeds, the binary is right, and the compiler compiled four copies of
    # everything. Routing carried 2813 instances of build-time-only work that
    # every pass/fail test in this ladder called correct. `codeinfos` is the
    # size of the compiled set, and every level prints it.
    # SUM THE PROVENANCE LINE, not `codeinfos`. `codeinfos` reported 607 for
    # two programs with different bodies; the provenance counts sum to 269,
    # which is exactly what SEALED_ITEM_DUMP holds for the same build.
    count_of() {
        grep -oE 'SEALED-ITEMS by provenance:.*' "$1" 2>/dev/null | tail -1 |
            grep -oE '=[0-9]+' | tr -d '=' | Base_sum
    }
    Base_sum() { awk '{t += $1} END {if (NR) print t}'; }
    cpv=$(count_of $W/$n.proven.log)
    csl=$(count_of $W/$n.sealed.log)
    ctr=$(count_of $W/$n.trace.log)

    # Compare against the example's own declared expectation. An example that
    # passes a level it declared must FAIL is not testing its mechanism, and
    # that is the failure this ladder exists to catch - seven of ten did it
    # once, against a `proven` level that was not proven.
    # A DECLARATION MAY DEPEND ON THE LOOP. `buildtime_index` fails on the
    # seeded loop because every trace entry is a root, and passes on the
    # frontier loop because no call site asks for its entries. That is the
    # whole point of the example, so both outcomes are declared: an
    # `# EXPECT-FRONTIER` line replaces `# EXPECT` when that loop runs.
    exp=$(grep -m1 "^# EXPECT " "$p" | sed 's/^# EXPECT //')
    if [ "${SEALED_LOOP:-seeded}" = frontier ] && grep -q "^# EXPECT-FRONTIER " "$p"; then
        exp=$(grep -m1 "^# EXPECT-FRONTIER " "$p" | sed 's/^# EXPECT-FRONTIER //')
    fi
    verdict=ok
    for lvl in proven:$pv:${cpv:-} sealed:$sl:${csl:-} trace:$tr:${ctr:-}; do
        name=${lvl%%:*}; rest=${lvl#*:}; got=${rest%%:*}; count=${rest#*:}
        # `<level>=<verdict>[:<maxcodeinfos>]` - the bound is optional, and an
        # example that does not state one is only checked for its verdict.
        decl=$(echo "$exp" | grep -oE "$name=[a-z]+(:[0-9]+)?" | head -1)
        want=${decl#*=}; want=${want%%:*}
        [ -z "$want" ] && continue
        # `error` is a distinct expectation: only declared where a construct
        # is known to be unimplemented and crashing is the agreed placeholder.
        [ "$got" = "$want" ] || verdict="MISMATCH $name want=$want got=$got"
        case "$decl" in
            *:*) max=${decl##*:}
                 if [ -z "$count" ]; then
                     verdict="MISMATCH $name declares :$max but the log has no codeinfos"
                 elif [ "$count" -gt "$max" ]; then
                     verdict="MISMATCH $name compiled $count instances, bound is $max"
                 fi ;;
        esac
    done
    printf '%-24s %-7s %-7s %-7s n=%-5s D=%-11s %s\n' "$n" "$pv" "$sl" "$tr" \
        "${ctr:-?}" "${d:-none}" "$verdict" > $W/$n.row
}

# THE POOL. Every build is its own julia process, so examples are independent.
# The cap keeps the machine from oversubscribing: a build slowed past the 60 s
# timeout would read as a compiler failure, which is the one way parallelism
# could lie. 8 of 32 cores leaves each build a core of its own.
JOBS=${LADDER_JOBS:-8}
running=0
for n in $NAMES; do
    one "$n" &
    running=$((running + 1))
    if [ "$running" -ge "$JOBS" ]; then wait -n; running=$((running - 1)); fi
done
wait

printf '%-24s %-7s %-7s %-7s %-7s %-13s %s\n' example proven sealed trace instances D notes
for n in $NAMES; do
    [ -f $W/$n.row ] && cat $W/$n.row
done
