#!/usr/bin/env bash
# Build the sealed compiler experiment from a clean checkout of Julia 1.13.
#
#   ./sealed.sh setup   -- create the env2 project for the sealed compiler
#   ./sealed.sh build   -- build the abstract six subtype program with it
#   ./sealed.sh compare -- build the same program with the stock juliac
#
# THE COMPILER IS THIS REPOSITORY: `Compiler/` and `contrib/juliac/`, two
# directories up. `sealed_paths.sh` finds it, and `SEALED_JULIA` names another
# checkout. A rebase onto a new Julia tag says what changed underneath.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/sealed_paths.sh"
SHARE="$(julia +1.13 --startup-file=no -e 'print(joinpath(Sys.BINDIR, "..", "share", "julia"))')"

case "${1:-}" in
setup)
    rm -rf "$HERE/env2"
    mkdir -p "$HERE/env2"
    printf '[deps]\nCompiler = "807dbc54-b67e-4c79-8afb-eafe4df6f2e1"\n\n[sources]\nCompiler = {path = "%s/Compiler"}\n' "$SEALED_JULIA" > "$HERE/env2/Project.toml"
    julia +1.13 --startup-file=no --project="$HERE/env2" -e 'using Pkg; Pkg.instantiate()'
    ;;
build)
    mkdir -p "$HERE/work2"
    julia +1.13 --startup-file=no "$HERE/probe.jl" source abstract 6 > "$HERE/work2/abstract6.jl"
    julia +1.13 --startup-file=no --project="$HERE/env2" "$SEALED_JULIAC" \
        --output-exe "$HERE/work2/abstract6" --experimental --trim=safe "$HERE/work2/abstract6.jl"
    rc=0; "$HERE/work2/abstract6" || rc=$?
    echo "sealed abstract n=6 exit code: $rc  (expected 21)"
    ;;
compare)
    mkdir -p "$HERE/work3"
    julia +1.13 --startup-file=no "$HERE/probe.jl" source abstract 6 > "$HERE/work3/abstract6.jl"
    julia +1.13 --startup-file=no "$SHARE/juliac/juliac.jl" \
        --output-exe "$HERE/work3/abstract6" --experimental --trim=safe "$HERE/work3/abstract6.jl" || true
    ;;
*) echo "usage: $0 [setup | build | compare]"; exit 1;;
esac
