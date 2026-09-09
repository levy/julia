#!/bin/bash
# Gate F of Stage F (plan/pending/robust-incremental-compiler.md): Gate D
# with the image written by pages (`JULIA_REACTIVE_IMAGE_WRITE=pages` on
# every rebuild; the founding writes whole). The same steps and checks as
# gate_d.sh, in $OUT/../gate-f: each rebuild within the bound, every image
# passes the oracle, a child rebuild from image k equals the server's k+1.
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-f}
export IMAGE=pages
exec bash "$here/gate_d.sh" "$@"
