#!/bin/bash
# The text size of the runtime library and of the system image of every
# installed evidence build: results/data/text.tsv. Not a timing.
#   ./text_sizes.sh /var/tmp/gc-regions-evidence master base checked trusted probe
set -uo pipefail
cd "$(dirname "$0")"
DATA=${DATA:-data}; mkdir -p "$DATA"
root=$1; shift
printf '# build\tlibjulia_internal_text\tsys_so_text\n' > "$DATA/text.tsv"
for n in "$@"; do
    lib=$(size "$root/$n/lib/julia/libjulia-internal.so.1.14" | awk 'NR==2{print $1}')
    sys=$(size "$root/$n/lib/julia/sys.so" | awk 'NR==2{print $1}')
    printf '%s\t%s\t%s\n' "$n" "$lib" "$sys" >> "$DATA/text.tsv"
done
cat "$DATA/text.tsv"
