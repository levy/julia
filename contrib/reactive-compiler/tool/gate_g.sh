#!/bin/bash
# Gate G of Stage G (plan/pending/robust-incremental-compiler.md): Gate D
# with the overlay image (`JULIA_REACTIVE_IMAGE_WRITE=overlay` on every
# rebuild; the founding writes whole). The same steps and checks as
# gate_d.sh, in gate-g, plus the start of the bundle after the edits.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/7c34d767-9c8b-40c1-8ef9-6fa021e2073f/scratchpad/gate-g}
export IMAGE=overlay
exec bash "$here/gate_d.sh" "$@"
