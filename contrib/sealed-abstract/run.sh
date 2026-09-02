#!/usr/bin/env bash
# Report the parametric answer under both compilers.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
echo "=== stock compiler ==="
julia +1.13 --startup-file=no "$HERE/parametric_check.jl"
if [ -d "$HERE/env2" ]; then
    echo "=== sealed compiler ==="
    julia +1.13 --startup-file=no --project="$HERE/env2" -e \
        "using Compiler; Compiler.activate!(; reflection=true); Compiler.SEALED_WORLD[]=true; include(\"$HERE/parametric_check.jl\"); report(\"sealed\")"
else
    echo "=== sealed compiler: run ./sealed.sh setup first ==="
fi
