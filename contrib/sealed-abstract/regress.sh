#!/usr/bin/env bash
# The sealed toolchain's regression suite: FEATURE, TIME and SPACE.
#
#     ./regress.sh            run every case and compare against baseline.tsv
#     ./regress.sh record     run every case and WRITE baseline.tsv
#     ./regress.sh <case>…    run only the named cases
#
# WHY THIS EXISTS. The sealed compiler is a patched copy of Julia's, kept as
# working copies that are gitignored and rebuilt by `sealed.sh setup`. Three
# things can regress and no other test in this repository notices any of them:
#
#   FEATURE  an abstract element type stops trimming — the thing the patch is
#            FOR (`abstract6`), or a faithful record of optional fields stops
#            resolving (`product*`, DESIGN.md §8c)
#   TIME     a change makes inference explore more, and a build that took
#            twenty minutes takes an hour
#   SPACE    the same, in memory — a routing build already peaks near 27 GB,
#            and the machine has 62
#
# Every case here is SMALL on purpose: the whole suite runs in a couple of
# minutes, so it can be run before and after a compiler change rather than
# once a week. The expensive whole-model builds (`tool/trim-routing`) are the
# acceptance test, not this.
#
# THE TOLERANCE. Wall and peak are compared with a generous factor, because
# they are wall-clock measurements on a shared machine — the suite is looking
# for a doubling, not for noise. Run it on an idle machine or the space column
# will lie: an earlier run of these cases caught a CONCURRENT build's memory
# because it matched the buildscript by name across the whole process table.
# This one walks the descendants of the build it started, and nothing else.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/sealed_paths.sh"
BASE="$HERE/baseline.tsv"
WORK="$HERE/work-regress"
TOL=1.6                       # fail above this multiple of the baseline
mkdir -p "$WORK"

[ -d "$HERE/env2" ] || { echo "no sealed environment — run ./sealed.sh setup"; exit 1; }

# The peak resident memory of a process tree, sampled while it runs. Descendants
# of OUR build only: matching `juliac-buildscript.jl` across the machine picks
# up any other build in flight.
_descendants() {
    local p=$1 kids
    echo "$p"
    kids=$(pgrep -P "$p" 2>/dev/null) || return 0
    for k in $kids; do _descendants "$k"; done
}

# run_case <name> <source-file> <expected-exit-of-binary>
run_case() {
    local name=$1 src=$2 want=$3
    local exe="$WORK/$name" log="$WORK/$name.log"
    local start end peak=0 rc out
    start=$(date +%s.%N)
    ( julia +1.13 --startup-file=no --project="$HERE/env2" \
        "$SEALED_JULIAC" --output-exe "$exe" \
        --experimental --trim=safe "$src" ) > "$log" 2>&1 &
    local bpid=$!
    while kill -0 $bpid 2>/dev/null; do
        local total=0
        for p in $(_descendants $bpid); do
            local r
            r=$(ps -o rss= -p "$p" 2>/dev/null | tr -d ' ')
            [ -n "$r" ] && total=$((total + r))
        done
        [ "$total" -gt "$peak" ] && peak=$total
        sleep 0.5
    done
    wait $bpid; rc=$?
    end=$(date +%s.%N)
    if [ "$rc" -ne 0 ]; then
        out="BUILD-FAILED($(grep -oE 'finished with [0-9]+ errors' "$log" | grep -oE '[0-9]+' | tail -1))"
    else
        "$exe" > "$WORK/$name.out" 2>&1; local ec=$?
        out=$([ "$ec" = "$want" ] && echo ok || echo "RAN-EXIT=$ec/want=$want")
    fi
    printf '%s\t%.1f\t%d\t%s\n' "$name" "$(echo "$end - $start" | bc)" "$((peak/1024))" "$out"
}

# The cases. `abstract6` is the feature the patch exists for; the `product`
# cases are the union-product class (DESIGN.md §8c) — a record of n optional fields.
build_sources() {
    julia +1.13 --startup-file=no "$HERE/probe.jl" source abstract 6 > "$WORK/abstract6.jl"
    for n in 2 6 10; do
        julia +1.13 --startup-file=no "$HERE/union_product.jl" source "$n" > "$WORK/product$n.jl"
    done
}

CASES_NAME=(abstract6 product2 product6 product10)
CASES_SRC=("$WORK/abstract6.jl" "$WORK/product2.jl" "$WORK/product6.jl" "$WORK/product10.jl")
CASES_EXIT=(21 0 0 0)

mode="${1:-check}"
build_sources
: > "$WORK/results.tsv"
for i in "${!CASES_NAME[@]}"; do
    run_case "${CASES_NAME[$i]}" "${CASES_SRC[$i]}" "${CASES_EXIT[$i]}" >> "$WORK/results.tsv"
done

if [ "$mode" = record ]; then
    cp "$WORK/results.tsv" "$BASE"
    echo "recorded baseline:"; column -t "$BASE"; exit 0
fi

[ -f "$BASE" ] || { echo "no baseline.tsv — run ./regress.sh record on an idle machine"; column -t "$WORK/results.tsv"; exit 1; }

# `unchanged` means MATCHES THE BASELINE — which for a case pinned at
# BUILD-FAILED means it is still failing, in the same way. The state column
# says what that state is, so a green suite is never mistaken for a working
# one. `product6`/`product10` are pinned FAILING until the compiler fix lands
# (DESIGN.md §8c); when they pass, re-record.
fail=0
printf '%-11s %8s %8s %9s %9s  %-18s %s\n' case wall base peak base state verdict
while IFS=$'\t' read -r name wall peak out; do
    b=$(awk -F'\t' -v n="$name" '$1==n {print $2"\t"$3"\t"$4}' "$BASE")
    bwall=$(echo "$b" | cut -f1); bpeak=$(echo "$b" | cut -f2); bout=$(echo "$b" | cut -f3)
    status=unchanged
    [ "$out" != "$bout" ] && { status="FEATURE: $out (was $bout)"; fail=1; }
    awk -v a="$wall" -v b="$bwall" -v t=$TOL 'BEGIN{exit !(b>0 && a > b*t)}' && { status="TIME"; fail=1; }
    awk -v a="$peak" -v b="$bpeak" -v t=$TOL 'BEGIN{exit !(b>0 && a > b*t)}' && { status="SPACE"; fail=1; }
    printf '%-11s %8s %8s %9s %9s  %-18s %s\n' "$name" "$wall" "$bwall" "$peak" "$bpeak" "$out" "$status"
done < "$WORK/results.tsv"
# THE LADDER. Four build cases above catch feature, time and space regressions
# in the toolchain. They do not catch a POLICY regression: a change that makes
# `trace_typeparam` resolve without a trace, or `residual_splat` build at all,
# is a change in what the compiler proves, and nothing here would notice.
# `ladder.sh` asserts each example against its declared EXPECT line.
if [ -x "$HERE/ladder.sh" ]; then
    echo
    echo "--- the example ladder ---"
    ladder_out=$("$HERE/ladder.sh" 2>&1)
    echo "$ladder_out"
    if echo "$ladder_out" | grep -qE "MISMATCH|OUTPUT"; then
        echo "LADDER: an example no longer matches its declaration, or a binary answers wrongly" >&2
        fail=1
    fi
fi

exit $fail
