# `merged` — the compiler our binaries are built with

This branch is the merge of the feature branches of this fork onto a release of
Julia. It carries no work of its own: everything here belongs to a topic branch,
and this branch exists so that one compiler holds all of them.

Base: `v1.13.0-rc4`.

| topic | branch |
| --- | --- |
| the pre-relocated system image | `sysimage-prelink-1.13` |
| the reactive compiler | `reactive-compiler` |

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
- A system image resolves its function pointers before the fixup list, which the
  pre-relocation needs; an incremental image and the overlay chain resolve
  theirs afterwards, as they did.

## What proves it

- `make -C test prelink`
- the testset "the system image holds `nothing`, the booleans and the symbols"
  in `test/cmdlineargs.jl`
- `contrib/reactive-compiler/tool/gate_b.sh`
- a compiled program: `hello world` starts in 10.7 ms instead of 69.0, with
  3,163 minor page faults instead of 26,611.
