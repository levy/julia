# Seal to an interpreter

**Status: Stage 0 DONE and measured; Stage 1 needs a decision (see its section).**

## The idea

A call the trim cannot resolve is an error today, because the binary has no
way to execute a dynamic call: `jl_apply_generic` finds the method, finds no
compiled code, asks for inference, and the Compiler is not in the image. The
idea is to let that call run in the **interpreter** instead. The interpreter
is small, it dispatches on the one value that actually arrives — exactly once,
so there is no product of types to split — and the trace says which calls are
hot and must be compiled. The split budget then bounds performance, not
correctness, and a promise the program could not prove becomes a slow path
rather than a wrong binary.

## What already exists — measured, not assumed

1. **The interpreter is in every binary.** `src/interpreter.c` is 938 lines
   and is linked into `libjulia`. Nothing extra ships.
2. **The runtime already falls back to it, one step before the crash.**
   `jl_compile_method_internal` (`src/gf.c:3635`): under
   `compile_enabled ∈ {OFF, MIN}` it takes `jl_code_for_interpreter(mi)`,
   checks `!jl_code_requires_compiler(src)`, and installs
   `jl_fptr_interpret_call` — **without inference**. Only past that block does
   it call `jl_type_infer`, which is where the routing binary died twice in
   `seals-into-source` Stage 5.
3. **An over-budget site already compiles to a dynamic call.** What fails is
   the binary's inability to execute one.
4. **`ccall` needs the compiler.** `interpreter.c:356` throws on
   `foreigncall`; `jl_code_requires_compiler` (`toplevel.c:434`) detects it.
   A residual method that contains one must be compiled, not interpreted.
5. **The toolchain runs stock juliaup 1.13.0-rc3, and the binaries link its
   `libjulia`.** The fork's `src/` is neither built nor linked — `usr/bin/julia`
   does not exist, and the crash trace named `/cache/build/…/julia-ci/src/gf.c`.
   Every sealed mechanism so far is Julia (`Compiler/`, `contrib/`). **A C
   change takes effect only after the fork is built and the host is switched
   to it**, which is a stage of its own.
6. **`--strip-ir` under `--trim` clears `Method.source` for every method.**
   `strip_all_codeinfos__` (`staticdata.c:2606`): `should_strip_ir =
   jl_options.trim`, so the per-module `compile=min` exemption below it never
   applies in a trimmed build. Keeping source means not passing `--strip-ir`.
7. **Trim keeps only methods with a compiled instance.** `MIs` comes from
   `jl_get_llvm_cis` and `jl_rebuild_methtables` builds the table from it
   (`staticdata.c:2992`, `precompile_utils.c:10`). A method with no instance
   leaves the table; retaining one needs C.
8. **The verifier's check is per method, not per specialization.**
   `verifytrim.jl:431`: a call is "covered" if ANY instance of the matched
   method exists. So a missing SPECIALIZATION passes `--trim=safe` at 0 errors
   and dies at startup — the exact shape Stage 5 measured twice. Stage 0
   reproduces it on purpose.
9. **The flag is reachable from Julia.** `compile_enabled` is field 21 of
   `Base.JLOptions`, offset 100; `JL_OPTIONS_COMPILE_MIN` is 3; Base itself
   reads the struct through `cglobal(:jl_options)`. A binary parses no julia
   options, so `_main` writes the field itself.

## Stages

### Stage 0 — the runtime half, with no C

`SEALED_INTERPRET=1` at build time does two things:

- `juliac.jl` omits `--strip-ir` (keeps `--strip-metadata`), so `Method.source`
  survives (fact 6).
- `juliac-buildscript.jl` bakes the flag and `_main` stores
  `JL_OPTIONS_COMPILE_MIN` into `jl_options.compile_enabled` before `main`
  runs (facts 2, 9).

The example, `examples/interpret_residual.jl`: one generic method, one
specialization compiled by a direct call, a second reached only through a
`Vector{Any}`. The method stays in the table through the first (fact 7), the
verifier passes at 0 errors through the per-method check (fact 8), and the
binary dies at startup today. With the two levers it must print what the
source prints.

**Gate.** Today: 0 verifier errors, crash at startup. With `SEALED_INTERPRET=1`:
0 errors, correct output. Record the binary sizes with and without IR.

**Measured — the gate is half passed, and the half that failed is the useful
result.**

| build | verify | binary | at run time |
| --- | --- | --- | --- |
| levers off, `--trim=safe` | 0 errors | 1 786 392 B | `Internal error: during type inference of apply_mode(Main.Fast, Core.Float64)` — the Stage 5 crash, on 30 lines |
| levers on, `--trim=safe` | 0 errors | **39 563 664 B** | past inference, INTO the interpreter, which executes the body and dies one call later: `MethodError: getproperty(Base, :round)` |

So the runtime half works: the flag routes the call to the interpreter and
the retained source is executed. What stops it is the table, not the
mechanism. The lowered body spells `Base.round` as a dynamic
`getproperty(Base, :round)`, that Base method has no compiled instance, and
trim dropped it (fact 7). **What an interpreted body calls must also be in the
table, transitively** — the boundary Stage 1 exists for.

**The ladder row is `proven=fail sealed=WRONG trace=fail`.** The hole is the
sealed verifier's alone: stock inference and the trace build both refuse the
program. Stage 2's soundness fix is therefore local to the sealed
per-method check.

**Two corrections to the facts above.** (8) held exactly: the example passes
`--trim=safe` at 0 errors in every variant once `(Fast, Int)` is really
compiled; an earlier "2 errors" came from constant propagation folding the
direct call despite `@noinline`, which left the method with no instance at all
— `Base.inferencebarrier` keeps it honest. And keeping IR for the whole image
costs **38 MB** (1.8 → 39.6 MB): `--strip-ir` is one flag, so it also keeps
every compiled instance's inferred IR. Retention must be selective, or the
flagship's binary is unusable. Stage 4 moves ahead of Stage 3.

**Two more results that decide Stage 1's shape.**

- A generic entrypoint at `(Fast, Real)` changes nothing: Julia refuses an
  abstract signature as compileable unless the parameter is `@nospecialize`d
  (`jl_normalize_to_compilable_sig`), and only `jl_get_unspecialized` sets the
  `Method.unspecialized` field that `gf.c:3603` consults.
- With `@nospecialize(x::Real)` in the source — `seal_collapse` by hand — the
  build FAILS with 4 errors: the generic body's own calls, `*(Real, Int)` and
  `round(Type{Int}, Real)`, are now the dynamic calls. That is the repair
  loop's own note ("a generic body has more unresolved calls, not fewer") and
  the measured `+` blowup (2 errors → 75). The no-C path has the same
  transitive coverage problem as the interpreter, in native form, and the
  verifier has to prove it at build time instead of dispatch answering it at
  run time.

### Stage 1 — retention: a method with no instance stays in the table

Needs C (facts 5, 7): `jl_sealed_retain_method(m)` appends the method's
unspecialized instance to `MIs` before `jl_rebuild_methtables`; a counter in
`jl_fptr_interpret_call` with an exported getter; and one line at the first
interpretation of each instance (`gf.c:3644`) naming it, so the residual is a
ranked list and not a silence. This stage also builds the fork and adds
`SEALED_HOST_JULIA` to `sealed_paths.sh`, so scripts stop naming `julia +1.13`.

**The alternative, with no C**, is to compile the residual method
generically — `seal_collapse` (§46) applied to every residual automatically.
Stage 0 measured it on the example: the generic body's inner calls become the
next residual, and the verifier must prove every one of them at build time.
The interpreter instead lets DISPATCH answer them at run time on the concrete
value, one at a time. Both are linear in methods; only the interpreter avoids
proving Base generically.

**The decision.** The interpreter path needs the fork built and the host
switched — one infrastructure step, then two small C additions. The generic
path needs no C and is bounded by the same transitive set, proven rather than
dispatched. Stage 0's number that matters for either: retention must be
selective, because unselective IR is 38 MB.

### Stage 2 — the verifier sorts the residual

Under `SEALED_INTERPRET=1`, a `CallMissing` whose candidate methods (the
`matchvec` the verifier already has) all have source with no `foreigncall`,
`cfunction` or opaque closure is **interpretable**: demote to a warning and
retain the candidates. Any other is still an error. The ladder gains an
`interp` level with its own EXPECT verdict.

### Stage 3 — the flagship

T1S at `SEALED_INTERPRET=1` and split budget 256: the 97 errors become
warnings, the binary builds — does it run, and how many interpreted calls per
event on `Benchmark`? Zero means done. Any other number is a ranked list of
what to compile next, replacing the error list.

### Stage 4 — scope and size

Retention scoped by the trace: the transitive closure by METHOD TABLE from
every dynamic site, not by type. Size accounting against the stripped build.

## Risks, each with its answer

- **A hot path falls to the interpreter silently.** The Stage 1 counter, and
  the traced run as referee: it must report zero interpreted calls on the
  benchmark path.
- **Fact 8 is a correctness hole today**, interpreter or not: a binary can
  pass `--trim=safe` and crash. Stage 2's classification makes the verifier
  check the specialization, not the method.
- **An interpreted body dispatches on the trimmed method table.** That is the
  sealed world's own table, so a sealed assumption holds in both modes.
