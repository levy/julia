#!/usr/bin/env bash
# Build the union-product example at several widths and print the curve.
#
#     ./product.sh 4 8 10 12 14
#
# Each row is one record of n optional strings, whose constructor call splits
# 2^n ways under the sealed toolchain (DESIGN.md §8c). The point of the
# script is the SHAPE of the wall-clock column, not any one number.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/sealed_paths.sh"
mkdir -p "$HERE/work-product"
printf '%3s  %9s  %9s  %7s  %s\n' n "2^n" "wall(s)" "peak(MB)" "result"
for n in "$@"; do
    src="$HERE/work-product/rec$n.jl"
    exe="$HERE/work-product/rec$n"
    julia +1.13 --startup-file=no "$HERE/union_product.jl" source "$n" > "$src"
    start=$(date +%s.%N)
    ( julia +1.13 --startup-file=no --project="$HERE/env2" \
        "$SEALED_JULIAC" --output-exe "$exe" \
        --experimental --trim=safe "$src" ) > "$HERE/work-product/rec$n.log" 2>&1 &
    bpid=$!
    peak=0
    while kill -0 $bpid 2>/dev/null; do
        c=$(pgrep -f "juliac-buildscript.jl" | head -1)
        if [ -n "$c" ]; then
            r=$(ps -o rss= -p "$c" 2>/dev/null | tr -d ' ')
            [ -n "$r" ] && [ "$r" -gt "$peak" ] 2>/dev/null && peak=$r
        fi
        sleep 1
    done
    wait $bpid; rc=$?
    end=$(date +%s.%N)
    errs=$(grep -oE "Trim verify finished with [0-9]+ errors" "$HERE/work-product/rec$n.log" | tail -1 | grep -oE "[0-9]+")
    if [ "$rc" -eq 0 ]; then
        out=$("$exe" 2>&1 | tail -1)
    else
        out="FAILED (${errs:-?} errors)"
    fi
    printf '%3s  %9s  %9.1f  %7s  %s\n' "$n" "$((2**n))" \
        "$(echo "$end - $start" | bc)" "$((peak/1024))" "$out"
done
