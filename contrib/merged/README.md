# `merged` — the compiler our binaries are built with

This branch is the merge of the feature branches of this fork onto a release of
Julia. It carries no work of its own: everything here belongs to a topic branch,
and this branch exists so that one compiler holds all of them.

Base: `v1.13.0-rc4`.

| topic | branch |
| --- | --- |
| the pre-relocated system image | `sysimage-prelink-1.13` |
| the reactive compiler | `reactive-compiler` |

The merge is made from the release: `sysimage-prelink-1.13`, then the reactive
compiler. The earlier merge is a parent, through the strategy `ours`, so that
this branch only moves forward; its content is not taken.

## The rule

**Nothing is fixed here.** A fix belongs on its topic branch, and this branch is
merged again. A commit on `merged` that is not a merge is a mistake, with one
exception: a resolution that neither topic can carry alone, because it exists
only where the two meet. Those commits say so in their message.

## What holds the two together

- `jl_image_pointers` carries ten entries: the six of Julia, then the entry
  thunks and their targets, then the function table and its names. The struct
  in `src/processor.h` lists them in that order.
- The writer declares the three positions of the pre-relocation record once, and
  each branch that writes a fixup list records where it starts. The overlay
  branch of the reactive compiler records none: no pre-relocation reads an
  overlay.
- The record of a pre-relocation is at the end of a file, so the reader looks
  for it only when the image comes from a file and not from a region.
- Each image of an overlay chain sets its own global slots; the root symbol and
  the root task's `nothing` follow for the system image.
- A system image resolves its function pointers before the fixup list, which the
  pre-relocation needs; an incremental image and the overlay chain resolve
  theirs afterwards, as they did.
- The options: the prelink fields come before the reactive fields in
  `src/jloptions.h`, `src/jloptions.c` and `base/options.jl`.
- A prelinked image under a chain loads in place: its pointers hold the
  addresses of its program, so it can not move into a region. The program
  reserves the headroom of the region after its image, the base residual list
  is applied outside the runs that the overlay rewrote, and the delta lists of
  the overlay convert those runs and the new objects. A prelinked base takes a
  chain of one overlay. The chain of an image linked into a program is
  `<program>.chain`, and the overlays are read relative to the real folder of
  the chain file. A region load refuses an image that is prelinked, and takes
  one that has room for a prelink and no address in its record.

## What proves it

- `make -C test prelink`
- the testset "the system image holds `nothing`, the booleans and the symbols"
  in `test/cmdlineargs.jl`
- `contrib/reactive-compiler/tool/gate_b.sh`
- `contrib/reactive-compiler/tool/gate_i1.sh` with `JULIA_REACTIVE_SERVER=1`
  and `JULIA_REACTIVE_IMAGE_WRITE=overlay`: a server and the overlay chain
- `contrib/merged/gate_prelinked_chain.sh`: a prelinked program under a chain
  answers as the launcher of PackageCompiler does from a region, and starts in
  34 ms against 180 ms
- a compiled program: `hello world` starts in 10.7 ms instead of 69.0, with
  3,163 minor page faults instead of 26,611.
