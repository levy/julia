# Seal to an interpreter

**Status: Stages 0 and 1 DONE and measured; Stage 3 (the flagship) measured — the mechanism holds, the retention scope is the open question, with numbers below.**

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

### Stage 1 — what was built, and what it measured

**The fork is built and is the host.** `SEALED_HOST_JULIA` in
`sealed_paths.sh` names it; every script that spelled `julia +1.13` now reads
the variable. The sysimage is built from stock rc3's `Compiler/` — the sealed
`Compiler/` is a package loaded over it and has never been bootstrapped as
`Core.Compiler` (`const SEALED_WORLD = Ref(false)` fails there). A rebuild
must check out stock `Compiler/` first; `make -C src` alone rebuilds the
runtime library without touching the sysimage. `Make.user` is gitignored and
holds one line, `JULIA_PRECOMPILE=1`, as the built siblings do.

**Runtime (C, ~90 lines).** `jl_sealed_retain_method(m)` puts a method's
unspecialized instance into the set `jl_rebuild_methtables` builds from and
exempts its source from `--strip-ir`; `jl_sealed_retain_binding(mod, name)`
keeps a binding through the trim filter; `jl_get_interpreted_calls()` counts;
`JULIA_REPORT_INTERPRETED` names each instance the first time the interpreter
takes it, and each one refused for a `ccall`. `jl_code_or_ci_for_interpreter`
treats a stripped `source` (`nothing`) as absent instead of uncompressing it.

**Verifier (Julia).** Under `SEALED_INTERPRET=1`: every candidate of a dynamic
site is retained with its source and the bindings its body names — a lowered
body spells `Base.round` as `getproperty(%3, :round)` with the module in an
SSA value, so both spellings are resolved; the site is a warning when every
candidate can be interpreted; `unresolved call to function`, `unresolved
finalizer` and `unresolved invoke` are demoted the same way. **The oracle**
infers each candidate at its own signature — the UNSPECIALIZED instance,
never `specialize_method` at a `where` signature, which inserts a UnionAll
key into the specializations cache and segfaults the next lookup (measured)
— and hands every inner call with concrete argument types to the repair loop,
whose round cap is 12 under this mode. The oracle is restricted to the
program: inferring Base methods proves the concrete calls on their error
paths, and compiling those brought 8 326 methods and 112 sites into a 30-line
program.

**Measured, on `interpret_residual.jl` with the fork as host:**

| level | result |
| --- | --- |
| sealed, selective retention | binary 1.8 MB; the interpreter runs `apply_mode(Fast, Float64)` and stops with a clean `MethodError` at `*(2.5, 2)`: no Base method behind it is in the table |
| trace, selective retention | binary 7.4 MB, prints **53**, `INTERPRETED-CALLS 0`: the recorded run compiled the specialization, so nothing interpreted |
| the by-name closure (retired) | depth 3: 8 721 methods retained, 18 MB, still not closed |
| the floor, methods only | 26.6 MB — a `Method` drags the types its signature names |
| the floor, bindings only | 51.9 MB — a binding drags its value graph |
| the floor, both | inference segfaults in `speccache_eq` — open |

**The floor is therefore opt-in** (`SEALED_INTERPRET_FLOOR=1`) and open.
The compressed source of Base is 3.6 MB; what the serializer keeps with it
is not. The selective policy — candidates, their bindings, the oracle's
proven instances, the trace's hot instances — is the default, and a residual
that reaches an uncompiled Base method reports a `MethodError` that names it.

**Open.** A candidate with a `ccall` cannot be interpreted; it must be
compiled at its own signature (`jl_generate_fptr_for_unspecialized` is what
stock does). `Base.MPFR._unchecked_cast` is that class, reached by the ladder's
trace entry through BigFloat printing.

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

### Stage 3 — the flagship, measured

Built on the fork host, `SEALED_INTERPRET=1`, `--trim=unsafe-warn`, split
budget 256, every build inside the ten-minute rule. Each row is one build and
one run of the binary with `JULIA_REPORT_INTERPRETED=1`.

| retention scope | retained | binary | the run |
| --- | --- | --- | --- |
| candidates of each site, unbounded | 24 422 | 88.6 MB | segfault in a generator: `canonicalize(Dates.CompoundPeriod)` has sites with **18 450 candidates** — the whole method table of `+` |
| candidates, ≤ 32 per site (73 sites refused as too wide) | 235 | 22.8 MB | 2 instances interpreted, then a segfault: the runtime's no-source branch calls `jl_code_for_staged` on a NON-generated method, its `assert` gone in release |
| + what the oracle analyses | 3 369 | 28.8 MB | the same stop, now a clean `MissingCodeError` naming `_apply_scalars(Char, Any, Any)`: reached past the inference budget, so never retained |
| + retain before the budget | 4 633 | 30.6 MB | the same stop: retention happened only THROUGH analysis, and the budget cut the chain |
| + the program's callees by name (Base excluded) | **22 088** | **94.3 MB** | **5 methods deep** — `_scalar_operand → _apply → _apply_scalars → _apply_pair → _claim_matches` — then a clean error at Base's generic `getproperty(Any, Symbol)`, which compiled code never calls dynamically |

**What holds.** The runtime half is complete: a residual call goes past
inference into the interpreter, chains through interpreted methods, dispatches
into compiled instances on the way, and a missing method is a named error and
not a crash. Three runtime holes were closed on the way: a stripped source
read as `nothing`, a non-generated method with no source sent to a generator,
and a generated method asked for a body its image cannot produce.

**What does not.** Static retention scope. Every hop the interpreter takes
needs the next method present, and no static rule predicted the chain without
over-approximating by an order of magnitude: the per-site candidates miss the
second hop, the oracle's reach misses the third, and the by-name closure over
the program keeps most of the program. The cost is not source — Base's is
3.6 MB — but what the serializer keeps with a method: the types its signature
names. Nothing here contradicts the design; it says the SCOPE must come from
a run, not from names.

**Two facts for the next step.** The build's own warm run already touches the
residual with the real inputs: `SEALED-WARM-TABLE: 938 instances across 236
methods`. Retaining source for the methods the trace observed covers "same
method, other types" at the trace's size. And the stop at `getproperty(Any,
Symbol)` is a class of its own — Base's generic fallbacks, which compiled code
inlines and interpreted code dispatches to — small, enumerable, and the honest
form of a floor.

### The small example decides the scope — `interpret_blowup.jl`

One site over a 12×12 type product, `SPLIT-CASES 16` so it stays dynamic, and
`argv` deciding how many combinations a run touches: the recorded run takes
3×3, a run with `12` reaches 135 combinations nothing compiled. Every build
under a minute, every answer checked against the source's own output.

| scope | retained | binary | run with `12` |
| --- | --- | --- | --- |
| interpreter off | — | none | the trim refuses, 2 errors |
| candidates of the site only | 2 | 1.8 MB | dies at `getproperty(U1, :v)` |
| + source of every compiled method | 148 | 2.4 MB | the same one method missing |
| + every Core-typed Base method | 8 198 | 20.4 MB | **correct** — 8 142 methods to supply one |
| + the support set instead (`getproperty`, `setproperty!`) | 192 | **3.1 MB** | **correct**: 429 interpreted calls, 155 instances |
| trace level, support set | — | — | `k=3` runs 0 interpreted calls; `k=12` 351, correct |

So the floor is not "Base present": it is the handful of generic fallbacks
compiled code inlines and interpreted code dispatches to, found one at a
time by the run-time report. `SEALED_INTERPRET_SUPPORT_SET` holds them. The
program's residual is covered by the candidates of each site plus the source
of every compiled method — cheap, because their types are already in the
image.

**Two more scope facts from the flagship, found with the runtime naming its
MethodErrors** (`METHOD-ERROR: f with Tuple{…}` under `JULIA_REPORT_INTERPRETED`,
because the trimmed error printer itself fails and hid them):

- `_apply_pair(Char, Int64, Int64)` — a program function one hop below an
  interpreted body, retained by nothing. The closure by name is needed for
  the program, but bounded to **the program's own functions**: following
  every name (a program's methods of `*`, `show`) was the 94 MB; following
  the program's own functions is bounded by its own call graph. `Core` is
  excluded like `Base` — it owns `Core.Compiler`, and the example's retention
  went 192 → 4 089 through it before that was measured.
- `findall` over every package's `getproperty` methods exceeds any limit and
  answers nothing, so the support set names THE generic method with `which`.

### The flagship under the scope the example chose

Each row one build (all inside ten minutes) and one run with the report.

| scope | retained | binary | the run |
| --- | --- | --- | --- |
| candidates + compiled source + support set | 5 551 | 33.6 MB | 3 instances, then `_apply_pair(Char, Int64, Int64)`: a program function one hop below an interpreted body |
| + the program's own functions by name | 12 101 | 44 MB | 9 instances, then `var"#14#15"{PlcaState}` with `(Fsm, Int32, Int32, Int32)`: the `Fsm.on_transition` hook, a closure in a `::Any` field |
| + every capturing closure the program owns (818) | 16 095 | **92.5 MB** | **11 instances**, then `getindex(RefValue{Any})` — a Base generic, the support-set class |

So the mechanism converges the way the design says: each run names one
more thing, and it is always one of three kinds — a program function (the
own-function closure now covers it), a closure in a field (covered), or a
Base generic that compiled code inlines (one support-set entry each). What
does not converge is the SIZE: every program method retained drags the types
its signature names, and 16 095 of them are 92 MB. The floor for a large
program is the program.

**What to decide next.** Either (a) accept that a fully interpretable
program costs its own presence — tens of MB — and keep iterating the support
set until `Benchmark` runs with the counter at zero; or (b) make retention
cheaper in the serializer: a retained method needs its source and its table
entry, not the instantiated types of every signature the trim would
otherwise drop. (b) is C work in `staticdata.c` and is where the size goes.

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
