#!/usr/bin/env bash
# Build and report the TRUTH about it.
#
#   buildcheck.sh <out> <entry> [-- extra juliac args]
#
# WHY THIS EXISTS. A failed juliac build leaves the PREVIOUS binary in place,
# so `[ -x $out ]` reports success for a build that failed. That is not a
# hypothetical: a filter that dropped every entry the example needed was
# measured as working, committed as working, and a 6-minute routing build was
# spent on it, because two runs both read the same stale 2 940 312-byte file.
#
# So: remove the output first, and believe the exit code.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/sealed_paths.sh"
OUT=$1; ENTRY=$2; shift 2
rm -f "$OUT"
start=$(date +%s)
julia +1.13 --startup-file=no --project="$HERE/env2" \
    "$SEALED_JULIAC" --output-exe "$OUT" \
    --experimental --trim=safe "$ENTRY" "$@" > "$OUT.log" 2>&1
rc=$?
wall=$(( $(date +%s) - start ))
if [ $rc -eq 0 ] && [ -x "$OUT" ]; then
    printf 'BUILD OK   %ss  %s bytes  ran: %s\n' "$wall" "$(stat -c%s "$OUT")" "$("$OUT" 2>&1 | tail -1)"
else
    printf 'BUILD FAIL %ss  rc=%s  %s\n' "$wall" "$rc" \
        "$(grep -oE 'finished with [0-9]+ errors?' "$OUT.log" | tail -1)"
    exit 1
fi
