#!/bin/bash
# M1 / Gate 1 and M2 / Gate 2 driver. Gate 1: a rebuild with no edit links
# every text object of the previous build with a fresh sysimg.o and
# metadata.o, boots, and runs the routing model. Gate 2: a rebuild after a
# one-function edit emits the cone of the edit.
#   A   - the routing model, built from the stock system image of the patched
#         Julia and linked as A.so
#   B   - the same source again, built from A.so with JULIA_REACTIVE_REUSE=1;
#         B.so = A's text objects + B's text objects + B's sysimg.o + metadata.o
#   C   - the same source a third time, built from B.so; C.so = A's + B's + C's
#         text objects + C's sysimg.o + metadata.o. It shows whether the delta
#         of a no-edit build converges to zero.
#   D   - a fourth time, built from C.so, to show the convergence.
#   E   - the edit build: the same source with RC_EDIT=1 (`pk.hop_count += 1`
#         becomes `+= 2` in `routing_handle!`, see m0_build.jl), built from
#         D.so. Gate 2 compares its delta with the cone of the edit.
#   F   - the edit built from the stock system image: the full build that E
#         is measured against, in time and in the run.
# Steps: build-a, link-a, run-a, build-b, link-b, run-b, build-c, link-c, run-c,
# build-d, link-d, run-d, build-e, link-e, run-e, compare-e, build-f, link-f,
# run-f. Pass step names to run some steps, or nothing to run all of them in
# order.
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
    grep -E "Elapsed|Maximum resident|^reactive:|Network hash|Sequential time|Avg hops|^m0_build: (edit|new)" "$OUT/$name.log"
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

# A full build boots from the stock system image.
# $1 = the build, $2 = more environment for the build script, or nothing
build_full() {
    echo "=== build $1 starts $(date +%T); omnet HEAD $(git -C "$OMNET" rev-parse --short HEAD)"
    JL_ENV="${2:-}" jl "$1" --sysimage="$JH/usr/lib/julia/sys.so" -C native --output-o "$OUT/$1.a"
}
# $1 = the build
link_full() {
    local b=$1
    local lb; lb=$(echo "$b" | tr 'A-Z' 'a-z')
    extract "$OUT/x$lb" "$OUT/$b.a" && link "$OUT/$b.so" "$OUT"/x$lb/*.o
}
# A reactive build boots from the previous image: B from A.so, C from B.so.
# $1 = the build, $2 = the previous build, $3 = more environment, or nothing
build_next() {
    echo "=== build $1 starts $(date +%T), from $2.so"
    JL_ENV="JULIA_REACTIVE_REUSE=1 ${3:-}" jl "$1" --sysimage="$OUT/$2.so" -C native --output-o "$OUT/$1.a"
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

# Gate 2: the delta of the edit build against the cone that the build script
# printed. The cone has two parts: the method instances that the edit closed
# (with the specializations of the replaced method), and the method instances
# that the scenario made after the edit (the specializations of the new method
# and of its closures). Every root of the delta must be in one of the two
# parts, and every closed method instance must be a root.
# $1 = the build
compare_edit() {
    python3 - "$OUT/$1.log" <<'PY'
import re, sys
closed, new, roots, edges = set(), set(), set(), set()
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"m0_build: cone (replaced|closed|new) (.*)$", line)
    if m: (new if m.group(1) == "new" else closed).add(m.group(2).strip()); continue
    m = re.match(r"reactive delta: :(root|edge) (.*)$", line)
    if m: (roots if m.group(1) == "root" else edges).add(m.group(2).strip())
print(f"=== compare: closed {len(closed)}, new {len(new)}, delta roots {len(roots)}, delta edges {len(edges)}; "
      f"roots closed {len(roots & closed)}, roots new {len(roots & new)}, "
      f"roots outside the cone {len(roots - closed - new)}, closed not emitted {len(closed - roots)}")
for name, s in (("root outside the cone", roots - closed - new), ("closed not emitted", closed - roots),
                ("root new", roots & new), ("edge", edges)):
    for sig in sorted(s): print(f"    {name}: {sig[:200]}")
PY
}

steps=${*:-build-a link-a run-a build-b link-b run-b build-c link-c run-c build-d link-d run-d build-e link-e run-e compare-e build-f link-f run-f}
for step in $steps; do
    case $step in
        build-a) build_full A ;;
        link-a) link_full A ;;
        run-a) jl run-A --sysimage="$OUT/A.so" ;;
        build-b) build_next B A ;;
        link-b) link_next B a ;;
        run-b) jl run-B --sysimage="$OUT/B.so" ;;
        build-c) build_next C B ;;
        link-c) link_next C a b ;;
        run-c) jl run-C --sysimage="$OUT/C.so" ;;
        build-d) build_next D C ;;
        link-d) link_next D a b c ;;
        run-d) jl run-D --sysimage="$OUT/D.so" ;;
        build-e) build_next E D RC_EDIT=1 ;;
        link-e) link_next E a b c d ;;
        run-e) jl run-E --sysimage="$OUT/E.so" ;;
        compare-e) compare_edit E ;;
        build-f) build_full F RC_EDIT=1 ;;
        link-f) link_full F ;;
        run-f) jl run-F --sysimage="$OUT/F.so" ;;
        *) echo "unknown step $step"; exit 2 ;;
    esac || { echo "=== step $step failed"; exit 1; }
done
echo "=== done $(date +%T)"
