<a name="logo"/>
<div align="center">
<a href="https://julialang.org/" target="_blank">
<img src="doc/src/assets/logo.svg" alt="Julia Logo" width="210" height="142"></img>
</a>
</div>

# A Julia fork: four pieces of compiler and runtime work

This is a fork of [JuliaLang/julia](https://github.com/JuliaLang/julia). It
holds four lines of work on the garbage collector, on how a system image
loads, on how a system image rebuilds, and on ahead-of-time compilation.

Each one lives on its own branch. Three of them start from `release-1.13`. The
fourth starts from the master branch of JuliaLang, because it is the series
proposed there. Each one carries its own documentation, its own measurements
and its own tests. Follow the link in the table to the landing page of the
feature: it says what the feature does, how to build it, how to run it and
what it was measured at.

The Julia README is [README.upstream.md](README.upstream.md). Nothing on this
page describes Julia itself.

| Feature | Branch | Landing page | What it gives you |
| --- | --- | --- | --- |
| **Region garbage collection** | [`gc-regions`](https://github.com/levy/julia/tree/gc-regions) | [contrib/memory-regions](https://github.com/levy/julia/tree/gc-regions/contrib/memory-regions) | free a whole phase of a program at once, with no mark and no sweep |
| **Fast system image rebuild** | [`reactive-compiler`](https://github.com/levy/julia/tree/reactive-compiler) | [contrib/reactive-compiler/doc](https://github.com/levy/julia/blob/reactive-compiler/contrib/reactive-compiler/doc/architecture.md) | rebuild an image after an edit in seconds instead of minutes |
| **Sealed and trimmed AOT** | [`sealed-aot`](https://github.com/levy/julia/tree/sealed-aot) | [contrib/sealed-abstract](https://github.com/levy/julia/tree/sealed-aot/contrib/sealed-abstract) | `--trim=safe` accepts a program that dispatches on abstract types |
| **Faster system image load** | [`sysimage-prelink`](https://github.com/levy/julia/tree/sysimage-prelink) | [the section below](#faster-system-image-load) | a compiled program starts in milliseconds, because the relocation is done once at build time |

---

## Region garbage collection

**Branch [`gc-regions`](https://github.com/levy/julia/tree/gc-regions) ·
[read it here](https://github.com/levy/julia/tree/gc-regions/contrib/memory-regions) ·
[the developer documentation](https://github.com/levy/julia/blob/gc-regions/doc/src/devdocs/gc-regions.md)**

A region is a numbered part of the pool heap that a program frees as one act.
A program opens a window on a region, allocates into it, closes the window,
and later resets the region. Every object the window allocated goes at once.
There is no mark and no sweep.

An escape barrier holds the rule that no object in a region refers to an
object in a younger region. A census reclaims the dead cells of a region that
must live on. The stock collector runs as before, and a program that opens no
window pays one predicted branch on each managed pointer store.

**Use it when a program has phases and each phase throws away what it made.**
A discrete-event simulator that allocates per event, a request loop, a solver
that speculates and then discards. The work is measured against exactly such a
loop.

Measured on an event loop that allocates about 1.7 KB per event:

| collector | events/s | p99 | longest pause |
| --- | --- | --- | --- |
| stock, own heuristics | 7.2 M | 361 ns | 3.83 ms |
| regions, with census | 14.8 M | 70 ns | **55 µs** |

The longest pause falls by a factor of about 69, and the throughput doubles.
[MEASUREMENTS.md](https://github.com/levy/julia/blob/gc-regions/contrib/memory-regions/MEASUREMENTS.md)
holds twelve such measurements with the script and the data file of each.
[COST.md](https://github.com/levy/julia/blob/gc-regions/contrib/memory-regions/COST.md)
says what a program that never opens a window pays for the runtime being
there.

```julia
include("contrib/memory-regions/regions.jl")

@with_region region begin
    simulate_one_slice(model)   # everything allocated here
end
region_reset(region)            # goes at once
```

Build it with `make -j8`, as any Julia. Two defines,
`JL_NO_REGION_ALLOC` and `JL_NO_REGION_STORE_BARRIER`, compile parts of the
runtime out, for a build that measures what each part costs.

Regions beat the stock collector on wall time only when the allocation a unit
of work discards is the larger part of what it allocates. A loop that keeps
most of what it makes does not gain. Read `COST.md` before you adopt it.

The branch holds the runtime as an ordered series, one mechanism per commit,
for a reader who wants to review it rather than run it. The branch
[`gc-regions-wip`](https://github.com/levy/julia/tree/gc-regions-wip)
ends at the same tree, but it keeps the development history that the series
was cut from. Build `gc-regions`.

---

## Fast system image rebuild

**Branch [`reactive-compiler`](https://github.com/levy/julia/tree/reactive-compiler) ·
[read it here](https://github.com/levy/julia/blob/reactive-compiler/contrib/reactive-compiler/doc/architecture.md)**

A build is a snapshot of a store, the way a commit is a snapshot of a Git
object database. After a source edit, a rebuild boots from the image before
it, applies only the expressions that changed, and emits only the
invalidation cone of the edit. Everything else links again from the object
code of the earlier snapshots.

**Use it when you compile a system image or a binary again and again while you
work.** Today an edit to one function costs a full image build, so a person
who builds binaries stops building them.

Measured on a routing simulation:

| | before | after |
| --- | --- | --- |
| system image rebuild | 117 s | **21 s** |
| binary bundle rebuild | 155 s | **12 s** |

A rebuilt binary runs the edit at full speed. `JULIA_REACTIVE_REUSE=1` turns
the runtime patch on and `JULIA_REACTIVE_TIMINGS=1` prints what each part of a
rebuild cost.

The work is staged, and each stage has a gate that must pass before the next
one starts. The plans under
[contrib/reactive-compiler/plan](https://github.com/levy/julia/tree/reactive-compiler/contrib/reactive-compiler/plan)
say which stages are done and which are not. **This is the least finished of
the four.** Read the plans before you rely on it.

---

## Sealed and trimmed ahead-of-time compilation

**Branch [`sealed-aot`](https://github.com/levy/julia/tree/sealed-aot) ·
[read it here](https://github.com/levy/julia/tree/sealed-aot/contrib/sealed-abstract) ·
[the design](https://github.com/levy/julia/blob/sealed-aot/contrib/sealed-abstract/DESIGN.md)**

`juliac --trim=safe` refuses a binary that could reach code the image does not
hold. A dynamic dispatch on an abstract type is exactly that: inference can
not name the targets, so the verifier reports an unresolved call and the build
fails. The stock answer is to rewrite the program, replacing every abstract
element type with a union of concrete types and threading that union through
every container and every signature.

This branch makes the compiler carry that knowledge instead. At build time the
world is closed: every package is loaded, and no new subtype of the program's
own abstract types can appear. So the compiler treats an abstract argument
type as the union of its concrete subtypes, enumerates the targets of each
call and compiles them. It then either resolves the call statically, or leaves
it dynamic with a **verified** target set — the verifier accepts a dynamic
call when every matched method has a compiled instance in the image.

Where enumeration is too wide the build does not refuse. The call falls down a
lattice of evidence — proven by inference, enumerated from the sealed world,
observed by a recorded trace, promised by the program in a seal file — and
every step of that descent is bounded and reported.

**Use it when you want a small self-contained binary from a program that was
not written for one.** The program this was built against is a discrete-event
simulator with a projectional editor, about 300 000 lines.

| toolchain | verifier errors | binary |
| --- | --- | --- |
| stock `juliac` | 8, no binary | — |
| sealed | 0 | 1 800 632 B, runs |

Everything sits behind `SEALED_*` switches. `SEALED_WORLD=0` turns the whole
apparatus off and the toolchain behaves as stock `juliac`.
[MEASUREMENTS.md](https://github.com/levy/julia/blob/sealed-aot/contrib/sealed-abstract/MEASUREMENTS.md)
holds the numbers and how to reproduce each.

---

## Faster system image load

**Branch [`sysimage-prelink`](https://github.com/levy/julia/tree/sysimage-prelink) ·
[the source of the manual section](https://github.com/levy/julia/blob/sysimage-prelink/doc/src/devdocs/sysimg.md?plain=1)**

This section is the landing page of the feature. The manual section that the
branch adds is written for Documenter, so read it as source: GitHub renders
neither its heading anchors nor its cross references.

This branch starts from the master branch of JuliaLang, not from
`release-1.13`, because it is the series proposed there. The port to
`release-1.13` is not published.

A Julia process applies relocations to the system image it just mapped before
it runs your code. The cost is per page, not per pointer: a start writes about
40,000 pages of the image, and the kernel gives each written page a private
copy. Making the image smaller does not help, and one class of pointer left
unfinished keeps the whole cost.

A pre-relocated image does that work once, when the program is built.
`--sysimage-prelink=yes` reserves the room a start needs for the few pointers
that a file cannot hold. `--output-prelinked=<file>` restores the image once
and writes a copy of the program with the restored image inside it. The start
of that program maps the image and runs.

**Use it for a compiled program**, one that holds its own system image and is
linked `-no-pie`, so that the image is at one address at every start. A stock
`julia` maps a `sys.so` that the loader moves, so it cannot use the mode.

Measured on this machine, each program evicted from the page cache and read
back, the minimum of fifteen runs pinned to one core:

| program | start | minor faults | resident |
| --- | --- | --- | --- |
| hello world, normal | 74.9 ms | 30,582 | 163.2 MB |
| hello world, pre-relocated | **7.1 ms** | **2,487** | **66.4 MB** |
| a network simulator, normal | 101.8 ms | 48,209 | 244.9 MB |
| the simulator, pre-relocated | **7.9 ms** | **2,824** | **106.0 MB** |

A program that opens a window with SDL shows the same in a form you can watch:
the window is on screen 183.2 ms after the program starts, and 109.6 ms after
it when the image is pre-relocated.

The resident memory falls because the pages of the image stay clean and
file-backed, so a second process of the same program shares them instead of
making its own dirty copy.

An image that nobody pre-relocates is unchanged, to the byte: the room is
reserved only when `--sysimage-prelink=yes` asks for it. Writing the file needs
Linux; the fast path itself is portable.
