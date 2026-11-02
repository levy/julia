#!/bin/bash
# The gate of a prelinked program under a chain, where the pre-relocated image
# and the reactive compiler meet. The application DepApp of gate I1
# (contrib/reactive-compiler/tool/i1_dependency) founds a store with room for a
# prelink and keeps the object archive of its founding; the gate links that
# archive with a launcher into a program that holds its image and reserves the
# headroom of a region after it, prelinks the program, edits DepLib, rebuilds,
# and starts the program with the chain of the rebuild.
#   copy        - the packages into $OUT/src, where the gate edits them
#   found       - materialize_app founds $OUT/depapp with --sysimage-prelink=yes
#                 and keeps the archive in $OUT/depapp.object/sys-o.a
#   link        - the launcher and the archive into bin/depapp_prelinked, an
#                 ET_EXEC with 320 MB of headroom after its image
#   prelink     - the program restores once and writes itself back
#   run-s1      - the prelinked program with no chain: leaf 3, inner 20, extra 1
#   edit        - leaf-after.jl and inner-after.jl replace their files
#   mat-s2      - the rebuild of the edit writes an overlay and its chain
#                 (JULIA_REACTIVE_IMAGE_WRITE=overlay unless the caller sets it)
#   run-s2      - the prelinked program with the chain: its base loads in
#                 place, and leaf 6, inner 40, extra 2, as the launcher of
#                 PackageCompiler gives from a region
#   starts      - seven starts of each program
# Pass step names to run some steps, or nothing to run all of them in order.
# Run the gate under bounded-run: the steps take no cap of their own.
set -u
OUT=${OUT:-${TMPDIR:-/tmp}/reactive/gate-prelinked}
JH=${JH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
JULIA=${JULIA:-$JH/usr/bin/julia}
PC=${PC:-$(cd "$JH/.." && pwd)/PackageCompiler.jl}
LAUNCHER=${LAUNCHER:-$(cd "$JH/.." && pwd)/projectured-julia/source/tool/builder/launcher.c}
TOOL=$JH/contrib/reactive-compiler/tool
SRC=$OUT/src
APP=$OUT/depapp
ARCHIVE=$OUT/depapp.object/sys-o.a
PROGRAM=$APP/bin/depapp_prelinked
mkdir -p "$OUT/depot"

run() {
    local name=$1; shift
    env JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" "$@" > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed \(wall|Maximum resident|materialize_app|reactive: overlay|pre-relocated|shape: |rror" "$OUT/$name.log"
    return $rc
}

compile_env() {
    mkdir -p "$OUT/compile-env"
    cat > "$OUT/compile-env/Project.toml" <<EOF
[deps]
PackageCompiler = "9b87118b-4619-50d2-8e1e-99f35a4d4d9d"

[sources]
PackageCompiler = {path = "$PC"}
EOF
}

mat() {
    compile_env
    cat > "$OUT/mat.jl" <<EOF
import Pkg; Pkg.instantiate()
using PackageCompiler
materialize_app("$SRC/DepApp", "$APP";
    workload = "$SRC/workload.jl",
    executables = ["depapp" => "julia_main"],
    track_dependencies = true,
    force = true,
    incremental = true,
    cpu_target = "native",
    sysimage_build_args = \`-O2 -g1 --sysimage-prelink=yes\`,
    keep_object_archive = "$ARCHIVE")
EOF
    run "$1" /usr/bin/time -v env JULIA_REACTIVE_TIMINGS=1 \
        JULIA_REACTIVE_IMAGE_WRITE=${JULIA_REACTIVE_IMAGE_WRITE:-overlay} \
        "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/mat.jl"
}

# $1 = a tag, $2 = the program, $3 = the expected shape lines, "name=value ..."
runbin() {
    run "run-$1" env JULIA_REACTIVE_TIMINGS=1 "$2" || return 1
    local want got
    want=$(for pair in $3; do echo "shape: ${pair%%=*} = ${pair#*=}"; done; echo "shape: state = 0")
    got=$(grep "^shape: " "$OUT/run-$1.log")
    if [ "$want" == "$got" ]; then
        echo "=== run-$1: as expected"
    else
        echo "=== run-$1: not as expected"; diff <(echo "$want") <(echo "$got") | grep "^[<>]"
        return 1
    fi
}

copy() { rm -rf "$SRC" "$APP" "$OUT/depapp.object" && cp -a "$TOOL/i1_dependency" "$SRC" && echo "=== copied the packages to $SRC"; }

found() { mat mat-found && [ -f "$ARCHIVE" ] && echo "=== found: the archive is at $ARCHIVE"; }

link() {
    cat > "$OUT/headroom.ld" <<'EOF'
SECTIONS
{
  .reactive_headroom (NOLOAD) : ALIGN(4096) { . = . + 0x14000000; }
}
INSERT AFTER .ldata;
EOF
    cat > "$OUT/link.jl" <<'EOF'
using PackageCompiler
const P = PackageCompiler
program, launcher, archive, script = ARGS
flags = Base.shell_split(join((P.cflags(), P.ldflags(), P.ldlibs()), " "))
P.run_compiler(`-DJULIA_MAIN=\"DepApp.julia_main\" $(P.TLS_SYNTAX) $(P.bitflag()) $(P.march()) -no-pie
                -o $program $launcher -Wl,--whole-archive $archive -Wl,--no-whole-archive
                -Wl,-T,$script $(P.rpath_executable()) $flags`)
EOF
    run link "$JULIA" --startup-file=no --project="$OUT/compile-env" "$OUT/link.jl" \
        "$PROGRAM" "$LAUNCHER" "$ARCHIVE" "$OUT/headroom.ld" || return 1
    readelf -lW "$PROGRAM" | grep -E "LOAD.*RW" | tail -2
    readelf -SW "$PROGRAM" | grep -E "\.ldata|reactive_headroom"
}

prelink() {
    run prelink "$PROGRAM" --julia-args --output-prelinked="$PROGRAM.prelinked" || return 1
    mv "$PROGRAM.prelinked" "$PROGRAM" && echo "=== prelink: the program is prelinked"
}

edit() {
    cp "$TOOL/i1_dependency/leaf-after.jl" "$SRC/DepLib/src/parts/leaf.jl" &&
    cp "$TOOL/i1_dependency/inner-after.jl" "$SRC/DepLib/src/inner.jl" &&
    echo "=== edited leaf.jl and inner.jl of DepLib"
}

mats2() {
    mat mat-s2 || return 1
    ln -sf ../lib/julia/sys.so.chain "$PROGRAM.chain" && echo "=== the chain of the program: $(readlink "$PROGRAM.chain")"
}

runs2() {
    runbin s2 "$PROGRAM" "leaf=6 inner=40 extra=2" || return 1
    grep -q "the prelinked base loads in place" "$OUT/run-s2.log" ||
        { echo "=== run-s2: the base did not load in place"; return 1; }
    runbin s2-launcher "$APP/bin/depapp" "leaf=6 inner=40 extra=2"
}

starts() {
    for program in "$PROGRAM" "$APP/bin/depapp"; do
        echo -n "=== starts of $(basename "$program") (ms):"
        for i in 1 2 3 4 5 6 7; do
            s=$(date +%s%N); env JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" "$program" > /dev/null 2>&1; e=$(date +%s%N)
            echo -n " $(( (e - s) / 1000000 ))"
        done
        echo
    done
}

steps=${*:-copy found link prelink run-s1 edit mat-s2 run-s2 starts}
for step in $steps; do
    case $step in
        run-s1) runbin s1 "$PROGRAM" "leaf=3 inner=20 extra=1" ;;
        mat-s2) mats2 ;;
        run-s2) runs2 ;;
        *) $step ;;
    esac || { echo "=== $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
