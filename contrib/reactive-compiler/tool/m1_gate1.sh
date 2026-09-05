#!/bin/bash
# M1 / Gate 1 driver: a rebuild with no edit links every text object of the
# previous build with a fresh sysimg.o and metadata.o, boots, and runs the
# routing model.
#   A   - the routing model, built from the stock system image of the patched
#         Julia and linked as A.so
#   B   - the same source again, built from A.so with JULIA_REACTIVE_REUSE=1;
#         B.so = A's text objects + B's text objects + B's sysimg.o + metadata.o
#   C   - the same source a third time, built from B.so; C.so = A's + B's + C's
#         text objects + C's sysimg.o + metadata.o. It shows whether the delta
#         of a no-edit build converges to zero.
#   D   - a fourth time, built from C.so, to show the convergence.
# Steps: build-a, link-a, run-a, build-b, link-b, run-b, build-c, link-c, run-c,
# build-d, link-d, run-d. Pass step names to run some steps, or nothing to run
# all of them in order.
set -u
OUT=${OUT:-/tmp/claude-1001/-home-projectured-workspace-projectured-julia/ff3540b2-ffb0-4fd3-8928-610aacb586c1/scratchpad/m1}
JH=${JH:-/home/projectured/workspace/julia-reactive}
JULIA=$JH/usr/bin/julia
TOOL=$JH/contrib/reactive-compiler/tool
# A worktree of omnet-julia pinned to the commit that M0 measured (e21ba2cd),
# so that the gate does not move with the live checkout.
OMNET=${OMNET:-/home/projectured/workspace/omnet-julia-m1}
THREADS=${THREADS:-8}
# TIMINGS=2 lists every code instance of the delta in the build log
TIMINGS=${TIMINGS:-1}
mkdir -p "$OUT"

# One Julia run of the routing model, bounded, on the build lane. The depot is
# stacked: the caches of the patched Julia go to $OUT/depot, the packages come
# from ~/.julia, and the caches of the user's Julia stay untouched.
# $1 = log name, $2.. = julia arguments after the project
jl() {
    local name=$1; shift
    ( cd "$OMNET" && systemd-run --user --scope -q -p MemoryMax=24G -p MemorySwapMax=0 \
        nice -n 10 taskset -c 16-23 env JULIA_IMAGE_THREADS=$THREADS JULIA_REACTIVE_TIMINGS=${TIMINGS:-1} \
            JULIA_DEPOT_PATH="$OUT/depot:$HOME/.julia:" ${JL_ENV:-} \
        timeout 2400s /usr/bin/time -v \
        "$JULIA" --project=package/OmnetLegacyRoutingExample --startup-file=no --pkgimages=no \
                 "$@" "$TOOL/m0_build.jl" ) > "$OUT/$name.log" 2>&1
    local rc=$?
    echo "=== $name exit $rc at $(date +%T)"
    grep -E "Elapsed|Maximum resident|^reactive:|Network hash|Sequential time" "$OUT/$name.log"
    return $rc
}

# Link a system image from object files: the rule of sysimage.mk
link() {
    local so=$1; shift
    g++ -shared -fPIC -L"$JH/usr/lib/julia" -L"$JH/usr/lib" -o "$so" \
        -Wl,--whole-archive "$@" -Wl,--no-whole-archive -ljulia-internal -ljulia > "$OUT/$(basename "$so").link.log" 2>&1
    local rc=$?
    echo "=== link $(basename "$so") exit $rc; $(ls -la "$so" 2>/dev/null | awk '{print $5}') bytes; $(wc -l < "$OUT/$(basename "$so").link.log") log lines"
    return $rc
}

extract() {
    local dir=$1 archive=$2
    rm -rf "$dir"; mkdir -p "$dir"
    (cd "$dir" && ar x "$archive") || return 1
    echo "=== $dir: $(ls "$dir" | tr '\n' ' ')"
}

build_a() {
    echo "=== build A starts $(date +%T); omnet HEAD $(git -C "$OMNET" rev-parse --short HEAD)"
    jl A --sysimage="$JH/usr/lib/julia/sys.so" -C native --output-o "$OUT/A.a"
}
link_a() { extract "$OUT/xa" "$OUT/A.a" && link "$OUT/A.so" "$OUT"/xa/*.o; }
run_a() { jl run-A --sysimage="$OUT/A.so"; }
# A reactive build boots from the previous image: B from A.so, C from B.so.
# $1 = the build, $2 = the previous build
build_next() {
    echo "=== build $1 starts $(date +%T), from $2.so"
    JL_ENV="JULIA_REACTIVE_REUSE=1" jl "$1" --sysimage="$OUT/$2.so" -C native --output-o "$OUT/$1.a"
}
# The image of a reactive build links the text objects of every build before
# it, its own text objects, and its own sysimg.o and metadata.o.
# $1 = the build, $2.. = the lowercase names of the builds before it
link_next() {
    local b=$1; shift
    local lb; lb=$(echo "$b" | tr 'A-Z' 'a-z')
    extract "$OUT/x$lb" "$OUT/$b.a" || return 1
    local objs=()
    for p in "$@"; do objs+=("$OUT"/x$p/text*.o); done
    link "$OUT/$b.so" "${objs[@]}" "$OUT"/x$lb/text*.o "$OUT/x$lb/sysimg.o" "$OUT/x$lb/metadata.o"
}

steps=${*:-build-a link-a run-a build-b link-b run-b build-c link-c run-c build-d link-d run-d}
for step in $steps; do
    case $step in
        build-a) build_a ;;
        link-a) link_a ;;
        run-a) run_a ;;
        build-b) build_next B A ;;
        link-b) link_next B a ;;
        run-b) jl run-B --sysimage="$OUT/B.so" ;;
        build-c) build_next C B ;;
        link-c) link_next C a b ;;
        run-c) jl run-C --sysimage="$OUT/C.so" ;;
        build-d) build_next D C ;;
        link-d) link_next D a b c ;;
        run-d) jl run-D --sysimage="$OUT/D.so" ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
