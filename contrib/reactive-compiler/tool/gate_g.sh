#!/bin/bash
# Gate G of Stage G (plan/pending/robust-incremental-compiler.md): Gate D
# with the overlay image (`JULIA_REACTIVE_IMAGE_WRITE=overlay` on every
# rebuild; the founding writes whole). The same steps and checks as
# gate_d.sh, in gate-g, plus the start of the bundle after the edits.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-g}
export IMAGE=overlay
exec bash "$here/gate_d.sh" "$@"
