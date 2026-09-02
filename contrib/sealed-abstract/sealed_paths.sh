# WHERE THE SEALED COMPILER LIVES: two directories up. This ladder is part
# of the compiler's own repository (`contrib/sealed-abstract` on the
# `sealed-aot` branch, over `Compiler/` and `contrib/juliac/`), so a
# checkout of the branch tests itself with no sibling checkout at all.
# Set SEALED_JULIA to build against another checkout.
#
# Source this file. It sets SEALED_JULIA, SEALED_JULIAC and SEALED_HINTS.
_sp_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEALED_JULIA="${SEALED_JULIA:-$_sp_here/../..}"
if [ ! -d "$SEALED_JULIA/Compiler" ]; then
    echo "no sealed compiler at $SEALED_JULIA — expected the julia-aot worktree" >&2
    echo "  git -C <julia checkout> worktree add ../julia-aot sealed-aot" >&2
    exit 1
fi
SEALED_JULIA="$(cd "$SEALED_JULIA" && pwd)"
SEALED_JULIAC="$SEALED_JULIA/contrib/juliac/juliac.jl"
# THE HINTS ARE THE PROGRAM'S HALF, so this repository names its own file. The
# buildscript errors if the path it is given does not exist.
export SEALED_HINTS="$_sp_here/seal_hints.jl"
unset _sp_here
