#!/bin/bash
# The correctness batteries. Override the binary with
#   JULIA=/path/to/julia ./run.sh    (default: this checkout's ../../julia)
set -euo pipefail
cd "$(dirname "$0")"
JULIA="${JULIA:-../../julia}"
run() { "$JULIA" --startup-file=no "$@"; }

echo "== correctness batteries =="
run v2_regression.jl
run stage3_safety.jl
