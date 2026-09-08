# The robust incremental compiler

The continuation of `reactive-materialization.md`. That plan made a rebuild
that boots from the previous image, compiles the delta of one method edit,
and links it with the old text objects: 17 s against 155 s for the routing
binary, with a direct call from the delta into reused code. This plan makes
that rebuild robust, reliable and complete: every kind of change is applied
or refused, the compiler process never executes the program, dead code
leaves the image, and a server saves an image without an exit.

## The invariant

**For any sequence of applied edits, the incremental image is semantically
equal to the founding image of the final sources.** Semantic equality is:

1. the same method tables in the current world, for every module of the
   tracked sources: the same signatures, the same lowered code;
2. a valid code instance for every root of the trace, in both images;
3. the same program output for the workload;
4. no state of any workload in the heap: every global of the tracked
   modules has the value that its top-level expression gives.

Images are not byte-equal, and the plan does not ask for it. Inference is
not a pure function of the source: its recursion limits depend on the root
that inference started from, so a recomputed code instance can differ from
the one that a founding gives. It is equally valid; it is not the same.

The universal fallback is the founding build. It is always correct and
always available. A change that the compiler cannot apply becomes a
refusal with a reason, never a stale image.

## Decisions

Recorded 2026-09-05, from the discussion that started this plan:

- **The trace is store state.** A throwaway process runs the workload
  under `--trace-compile`; the statements are the roots of the store. The
  user refreshes the trace with a command. A rebuild never runs the
  workload.
- **The compiler process never executes the program.** It evaluates
  top-level expressions and infers; compile-time execution (macros,
  generated functions) is compilation and stays. So the heap carries no
  execution state, and harness rule 8 of `doc/architecture.md` disappears
  instead of being a rule.
- **Apply or refuse, never ignore.** Every change gets a category from the
  catalog below. A category that the compiler cannot apply is refused with
  its name and the reason.
- **The function table is fresh on every build.** The old text objects are
  a library of named functions; the fresh `metadata.o` holds the one table
  of the live functions; the linker drops what nothing names. This lands
  before the server, because the save path of the server is simpler with
  fresh ids.
- **The world is the dependency tracker of code.** World ages, backedges
  and binding partitions stay the only invalidation of compiled code. The
  plan adds a tracker at one level only: top-level evaluation.
- **The oracle comes first.** A standing differential gate tests the
  invariant after every stage, so it is Stage 0.
- **PackageCompiler founds and bundles; the reactive compiler rebuilds.**
  Recorded 2026-09-05. The compiler calls the public API of
  PackageCompiler for the founding and the bundle, and owns the rebuild
  from Stage D on. The fork of PackageCompiler is retired at Stage D. The
  log entry "2026-09-05, PackageCompiler" has the detail.
- **The compiler's heap is never trimmed.** Recorded 2026-09-08. A
  trimmed image has no parser, no `eval` and no ledger, so the child and
  the server cannot run inside it. The store keeps the untrimmed image as
  the state of the compiler; a trimmed image is a product that a save
  derives from that heap, with the reused code as roots of the trim, and
  a trim failure of the delta is a refusal. Stage E.
- **The image is a log between foundings.** Recorded 2026-09-08. A save
  writes again only the pages of the image that the process wrote and
  appends the new objects; a dead object on a clean page stays until a
  founding compacts the image, the way the global slots stay. The
  trimmed product pulls the other way, prune against append, so it stays
  a whole write. Stages F and G.
- **The options are orthogonal.** Recorded 2026-09-08. The server, the
  trimmed product and the way the image is written are three keywords of
  `materialize_app`, each with an environment default, and any
  combination is valid. The section "The options" lists them.

## The options

Every option is a keyword of `materialize_app`, with an environment
variable as its default, so that a build tool or a gate script sets it
without a code change. The store records nothing of them: a store built
one way can be rebuilt another way, except where the value changes the
image format, which is a founding.

| Keyword | Variable | Values | Default | Stage |
| --- | --- | --- | --- | --- |
| `server` | `JULIA_REACTIVE_SERVER` | `false`, `true` | `false` | D, built |
| — | `JULIA_REACTIVE_SERVER_SAVES` | saves before a restart | 200 | D, built |
| — | `JULIA_REACTIVE_SERVER_RSS_KB` | resident size before a restart | 16 GB | D, built |
| `trim` | `JULIA_REACTIVE_TRIM` | `:off`, `:on`, `:once` | `:off` | E |
| `image` | `JULIA_REACTIVE_IMAGE_WRITE` | `:whole`, `:pages`, `:overlay` | `:whole` | F, G |
| `compact` | `JULIA_REACTIVE_COMPACT` | `(saves = N, growth = f)` | `(50, 0.25)` | F |
| `founding` | — | `false`, `true` | `false` | F |
| — | `JULIA_REACTIVE_TIMINGS` | 0, 1, 2 | 0 | built |
| — | `JULIA_REACTIVE_HEAPDUMP` | a path | unset | built |
| — | `JULIA_REACTIVE_DIRTY_PAGES` | a path | unset | F, built |

- `server`: the rebuild runs in the server of the store, started from the
  last image if none answers; the two variables bound its life.
- `trim`: `:on` writes the trimmed product beside every save, `:once`
  beside this build only, `:off` never. The product is a second bundle
  under `<app_dir>/trimmed/` with its own `bin/` and `lib/julia/sys.so`;
  the untrimmed bundle and the store's image stay as they are. A store
  founded with `:off` can turn it on later: the product derives from the
  heap at any save. A build without a trim-clean program refuses with the
  verifier's reason.
- `image`: how a save writes the image. `:whole` serializes the heap, as
  now. `:pages` copies the clean pages of the base image and writes again
  the pages the process wrote, with the new objects appended; the
  linker still runs. `:overlay` writes the delta as its own shared object
  with the patches of the base, and the loader applies them; no link. A
  change of this value is a founding, because the format of the image
  differs. The trimmed product is always a whole write.
- `compact`: with `:pages` or `:overlay` the image keeps its garbage; the
  next build founds again after `saves` saves since the last founding, or
  when the loadable size grew by the fraction `growth` since it. `founding
  = true` founds now.
- `JULIA_REACTIVE_REUSE` and `JULIA_REACTIVE_IMAGE` are internal: the
  builder sets them for the child and the server.

## The model

The state of the compiler is the heap of a Julia process: every type,
method, code instance, binding and the world counter. The image is that
heap, serialized, plus the machine code of the live code instances. A
restore of the image is a restart of the compiler, and takes one second.
So a server and a chain of child processes are the same design; the server
removes the restore and makes the front incremental.

A change is a set of top-level expressions to re-evaluate. The runtime
invalidates the compiled code that the re-evaluation reaches. The set is
the textual diff of the tracked sources, closed under the dependencies of
top-level evaluation: the macros that an expression expanded, the bindings
that a signature or an initializer resolved, the files that an evaluation
read, the includes that it made. Julia does not record those; the apply
loop does.

After the apply, the invalid code instances are known exactly. Inference of
their method instances, and of the new callees that inference finds, gives
the new code instances. No execution is needed. A specialization behind a
dynamic dispatch that no trace saw is compiled by the JIT of the binary at
run time: correct, slower on its first call, and fixed by a refresh of the
trace.

The delta is the set of code instances that are valid in the world and not
in the image. The image names its functions, so the delta calls a reused
function by symbol and the fresh table names the live functions by symbol.
The link joins the old text objects, the delta, the fresh heap and the
fresh table, and drops every function that the table does not name.

## The catalog of changes

Each category names the change, how the apply set is found, what the
invalidation reaches, the stage that covers it, and the state today.

| id | change | apply set | reach | stage | today |
| --- | --- | --- | --- | --- | --- |
| A1 | add a method | the expression | callers whose dispatch changes | done | done |
| A2 | change a method body | the expression | callers of the method | done | done |
| A3 | remove a method | `delete_method` on the signature of the removed expression | callers | B | done |
| A4 | change a signature | A3 then A1 | callers | B | done |
| A5 | keyword or default arguments | one expression, several methods | callers | done | done |
| A6 | generated function, callable struct | the expression | callers | B (test) | done |
| B1 | add a type | the expression | none | done | done |
| B2 | change the fields or parameters of a struct | the expression, then every tracked expression whose signature, field type or initializer names the type | all code on the type, by binding partitions | B | done; a value of the old type in an untyped container is not found |
| B3 | change a supertype | B2 for the type and for every subtype, transitively | large | B | done |
| C1 | change a `const` | the expression | code that read the binding | B (test) | done |
| C2 | change the initial value of a global | the expression | none | B (test) | done |
| C3 | `using`, `import`, `export`, `public` | the expression, then every tracked expression whose name resolution changes | binding partitions | B | done; a removed `using` keeps its binding; a conflict is refused |
| C4 | add or remove an `include` | the root file, tracked; the new file's expressions, or the removal of the old file's methods | as the contents | B | done for a tracked file; an untracked file is refused |
| C5 | add, remove or rename a module | remove and add its contents | large | B | an added module block is applied; a changed header or root file is refused |
| D1 | change a macro | every tracked expression that expands it, transitively | as their contents | B | done; the heads are syntactic |
| D2 | `@eval` loops, one expression with many methods | the expression; skip a method whose lowered code did not change | as the contents | B | done by the runtime method filter |
| E1 | a file that top-level evaluation reads | the expressions that read it (recorded) | as the expressions | B | done for the string literals of the expression |
| F1 | module-level compiler options | every expression of the module | the module | refuse | needs a founding |
| F2 | the workload or the trace | none | coverage only | A | done |
| F3 | preferences, dependency versions, Julia flags, Base | the package image or the sysimage | everything | refuse (E later) | needs a founding |
| H1 | comments, whitespace, line numbers | none; update the line numbers of the methods in place | none | B | done; a quoted line number stays until the next evaluation |
| H2 | docstrings | the expression | none | done | done |
| H3 | move or rename a file | content-keyed diff, not path-keyed | none | B | done |
| T1 | a static call site becomes dynamic under `trim` | the verifier names it | refusal | E | — |

Every category is supportable, and the cost degrades toward a founding: a
`convert` method or a supertype change invalidates most of the program, and
the rebuild then costs about what a founding costs. F1 and F3 are refused
until the ledger tracks the sources of the dependencies ("Beyond").

A refusal is also the answer when the apply set leaves the tracked sources:
a method of an untracked package whose signature names a redefined type,
or a macro of an untracked package that a tracked expression expands
(the expansion is in the tracked expression, so that one is fine; the
reverse, a tracked macro that an untracked file expands, is the refusal).

## Stage 0 — the oracle

The differential gate that tests the invariant. It runs after every later
stage and is the acceptance test of each. Done 2026-09-05 for HazardApp;
the entry "2026-09-05, Gate 0" below.

- [x] `tool/oracle_gate.sh`: for an application and a sequence of edits
      E1 to En, build the chain (a founding at S0, one rebuild for each
      edit) and the founding of Sn, and compare the two images:
      1. the method tables of the tracked modules: for each module, the
         set of (signature, hash of the lowered code) in the current world;
      2. every root of the trace has a valid code instance in both;
      3. the workload's output, by hash;
      4. the values of the globals of the tracked modules, against the
         values after a plain load of the sources.
      The gate prints one line per check and a size line: the number of
      functions in the text of each image. *As built:* check 4 compares
      the globals of the chain with the globals of the founding, which
      holds the values after the top-level expressions because the
      founding never runs the workload; the size line is the `info` lines
      of the oracle. Checks 3 and 4 report a difference of the persisted
      state alone as expected until Stage A, and fail on anything else.
- [x] the comparison runs inside each binary: *as built,* `tool/oracle.jl`
      runs under the fork's `julia -J <bundle>/lib/julia/sys.so`, so no
      entry of the application is needed; the gate diffs the two texts.
- [x] the edit sequences: the two-edit chain on HazardApp, where the
      second edit changes `driver` only, so that the third build calls
      `chained` of the second build's delta by its symbol. The routing
      `+= 2` edit and its reverse are not in the gate yet: the founding of
      the routing binary costs 2 min 37 s twice; add it when a stage
      changes the routing path.
- [x] a record of the result on today's rebuild: checks 1 and 2 pass;
      checks 3 and 4 differ by the persisted state alone (`state` 4
      against 0, `FINALIZED` 4 against 0) until Stage A.

**Gate 0.** The oracle runs on the two-edit chain; checks 1 and 2 pass;
the third build links and runs with `chained` of the second build by
symbol; checks 3 and 4 report the known difference. Passed 2026-09-05.

## Stage A — the rebuild without execution

The trace as store state, and inference as the only work of the rebuild.

- [x] the founding keeps its trace. As built: `create_app` runs its
      trace process inside and keeps nothing, so `_materialize_full` runs
      the same steps itself before `create_app` — `ensurecompiled`, then
      `run_precompilation_script` from `Base.JLOptions().image_file` — and
      adds `precompile(Tuple{typeof(Pkg.julia_main)})` for each executable
      and the statements of `precompile_statements_file`. The founding is
      `create_app(...; incremental = true, precompile_statements_file =
      trace)`, and the trace lands in `reactive-store/trace.jl`.
      `incremental = false` and `precompile_execution_file` are refused.
- [x] `refresh_trace(app_dir)`. As built: the throwaway process starts
      from the current image, `rc_keep_statements` keeps the statements of
      the old trace that still precompile, then the workload runs under
      `--trace-compile`; the trace is the roots of the union. The builder
      exposes it as `--refresh-trace` (`refresh_trace::Bool` of
      `build_executable`, refused without `reactive` or without a store).
- [x] the rebuild child precompiles `trace.jl` (`rc_precompile_trace`:
      inference only, codegen at the write of the image, the reuse skips
      what the image has). It never runs the workload. `rebuild_workload.jl`
      did not go away: it is the file that the founding and the refresh
      trace, renamed `trace_workload.jl` in the builder.
- [ ] the scan of the invalid code instances that no statement names: not
      built. Observed on routing: the child reports "cone 0 replaced, 0
      closed" for the edit of `handle_message!` while the delta has 380
      roots and the trace makes 36 new instances — `replaced` needs the
      name bound in the module of the file (it is a method of
      `NetworkModule.handle_message!`), and `closed` finds no capped code
      instance at all. The diagnostics of the child do not see the
      invalidations that the image sees; Stage B builds the ledger on the
      same seam and measures the scan there.
- [x] harness rule 8 and the `state` line of M6 are gone; `state` reads 0
      in all three runs of M6 and in the chain of the oracle.
- [x] measured. The run after the edit: 61.3-61.9 s without a refresh,
      61.3-61.8 s after one, against 61.4 s before the edit and 61.8-63.2 s
      after the restore — equal within 1 %. The SETUP phases are identical,
      so the JIT compiles nothing at run time: the roots of the trace cover
      the cone of the edit. Two outliers were the load of the lane: a
      66.0 s run after the edit with 1768 involuntary context switches, and
      a 68.3 s run before the edit right after the founding.

Two limits of `--trace-compile`, met on routing. A Unitful signature
prints as `Base.Rational{Int64}(num=1, den=1)`, which does not parse as a
constructor: 914 of the 3203 statements of the founding trace do not
precompile, and the child lists them in `trace.jl.unresolved` and prints
ten; a refresh drops them. A workload script runs in the `Main` of the
trace process, so its own functions and closures are traced as `Main.*`:
the trace keeps no `Main` statement (`_reactive_roots`). Before that
filter, the 2 statements a refresh added after the routing edit were two
such closures; with it, the refresh adds nothing: the roots of the founding
cover the edit.

**Gate A.** M6: 14 of 14 shapes, `state` 0 in all three runs; 28 statements
precompiled, 0 unresolved; rebuilds 7.9-8.7 s. M7: the same hop means
(2.308011 → 4.616022 → 4.616022 after the refresh → 2.308011); run time
after the edit within 1 % of the run before it on a quiet lane. Gate 0
passes check 4: the chain and the founding agree on 35 methods, 27 roots,
16 output lines and 2 globals. Passed 2026-09-05.

The rebuild time did not drop: 18-19 s through the builder, the child
8-10 s, against 17 s and 8-9 s before. The 8 s target assumed that the
workload was most of the rebuild; it cost about 1 s, and the precompile of
the trace costs 1.4 s (0.7 s after a refresh), while the front, the heap
write and the link stay. The rebuild time is the subject of Stage C.

## Stage B — the recorder and the classifier

The tracker of top-level evaluation, the apply set closed under it, and the
refusal of what it cannot apply.

- [x] the ledger: for each tracked file, for each top-level expression
      (keyed by the hash of the expression with line numbers stripped),
      the methods that it defines (their signatures, evaluated in the
      module), the bindings that it assigns, the macros that it expands
      (the heads of every `macrocall`, through recursive expansion), the
      global references of its signatures and initializers, and the files
      that its evaluation reads. The ledger of the old sources is computed
      in the rebuild child from the store's copy, because the image holds
      the modules and types that the signatures need; the ledger of the
      new sources is computed after the apply. *As built:* `rc_ledger` in
      `reactive_child.jl`, on `ReactiveSourceDiff.file_entries`; an item
      is the entry, its syntactic kind and defined name, and its methods.
      The methods of an old item are the live methods of the table whose
      file is the item's file and whose line is inside the item
      (`rc_methods_by_file`, `rc_assign_methods!`); a generator, at
      `none:0`, belongs to no item. The macro heads, the type-level names
      and the read paths are syntactic (`macro_heads`,
      `type_level_names`, `read_paths`: every string literal of the
      expression that names a file relative to the source directory).
      The store keeps `reads.txt`, the hash of every file that an
      expression could read.
- [x] A3, A4: a removed or re-signed expression deletes its methods by
      `delete_method` before the additions of the same file. *As built:*
      the removals go first, in file order; a changed expression deletes
      its old methods after its evaluation, so a replacement of the same
      signature is a dead entry and one without a replacement makes the
      change an A4. `rc_delete_method` deletes the generator's method with
      a generated method.
- [x] B2, B3: a changed type re-evaluates every tracked expression that
      names the type in a signature, a field type or an initializer, in
      file order; a changed supertype does the same for every subtype,
      transitively. Julia 1.12 allows the redefinition of a struct; the
      compiler process has no instances of the old type, because it never
      executes the program. *As built:* the dependents are the tracked
      expressions whose `type_level_names` name the type; a type whose
      shape (`type_shape`: fields, parameters, supertype) did not change
      is an A2 of its constructors. Limit: a value of the old type inside
      an untyped container of a `const` is not found; the invariant's
      check 4 sees it.
- [x] C3: a changed `using`, `import`, `export` or `public` re-evaluates
      every tracked expression of the module whose free names resolve
      differently before and after. *As built:* the free names of every
      expression of the module are resolved before and after the apply of
      the `using`; an expression whose resolution differs joins the
      queue. A removed `using` is not applied: Julia has no un-import, so
      the binding stays (`rc: removed ... not applied, the binding
      stays`). An import that conflicts with a binding of the module is
      refused (Julia ignores it), and a `using` of a package that is not
      in the image is an F3 refusal.
- [x] C4, C5: the builder tracks the root file of each package; an added
      `include` evaluates the new file, a removed one deletes the methods
      of the old file, a module block is removed and added as a whole.
      Any other change of a root file is refused. *As built:* an include
      item is never evaluated; it names a tracked file (else a C4
      refusal), and the file's own entries carry the change. A removed
      tracked file deletes its methods. A new module block is a C5
      addition; a changed module header, and any other expression of a
      root file outside its module, is a C5 refusal.
- [x] D1: a changed macro re-evaluates every tracked expression whose
      ledger names the macro, transitively through macros that expand to
      macros. *As built:* the macro heads are syntactic, so a macro that
      builds a `macrocall` at expansion time is invisible; the transitive
      closure runs over the tracked macros.
- [x] D2: before the re-evaluation of a method expression, compare the
      lowered code of each method it defines with the existing one, and
      skip the definition when they are equal. First measure whether
      Julia's `jl_method_def` already skips an identical redefinition.
      *As built:* `jl_method_def` never skips: an identical redefinition
      moves the world and invalidates every caller. The runtime hook
      `jl_reactive_set_method_filter` (`src/method.c`) asks a Julia filter
      before the insertion; `rc_method_filter` keeps the live method when
      the module, the signature, the method flags and the uncompressed IR
      (`code`, `slotflags`, `ssaflags`, `ssavaluetypes`,
      `propagate_inbounds`, `has_fcall`, `inlining`) are equal. A kept
      method keeps its own line table. A generated method is never kept.
- [x] E1: `include_dependency` and the file reads of top-level evaluation
      are recorded; a changed file re-evaluates its readers. *As built:*
      the reads are the syntactic `read_paths`, hashed into `reads.txt`
      at every rebuild; an expression whose read file changed is an E1
      change.
- [x] H1, H3: the line numbers of the methods of an unchanged expression
      are updated in place; the diff keys expressions by content, so a
      moved file is a move, not a removal and an addition. *As built:* the
      `line` of the methods of an unchanged item moves to the new item
      (`lines updated` in the report); a kept method of D2 moves too. The
      files match by path, then by content (a renamed file), then a lone
      leftover pair (renamed and edited). A reformat re-evaluates nothing,
      so a `LineNumberNode` inside a quoted literal (a macro body) keeps
      the line of the last evaluation.
- [x] the classifier: every change gets an id from the catalog; the apply
      report lists the changes by id, the apply set by size, and every
      refusal with its id and reason. A refusal stops the rebuild before
      the apply, with the founding as the advice. *As built:*
      `rc_classify`; the report is one `rc: change <id> <file>:<line>
      <name> (<note>), N methods[, K kept][, D deleted]` line per change
      and a summary line; a refusal is `rc: refuse <id> <where>: <reason>`,
      the child exits 3 before any evaluation, the parent removes the
      snapshot and errors "the rebuild is refused; a founding build
      applies the change".
- [x] a refusal for an apply set that leaves the tracked sources: a
      method of an untracked file whose signature names a redefined type,
      or an untracked file that expands a changed tracked macro. *As
      built:* the first (`rc_methods_on_type`: a live method outside the
      tracked files whose signature names the type is a B2 refusal). The
      second is not detected: an expansion leaves no trace in the
      expander's method, so an untracked expander of a tracked macro is
      invisible. Documented as a limit.

**Gate B.** A second tracked file of HazardApp, `src/changes.jl`, with one
case per category: A3 (the dispatch falls to a general method after the
removal), A4, A6, B2 with three dependents, B3 with a subtype, C1, C2, C3,
C4 (a new file), D1 with a transitive expansion, D2 (an `@eval` loop with
one changed method: the callers of the others keep their code instances),
E1, H1 (a reformat gives an empty apply set), H3 (a renamed file gives an
empty apply set). Each case gives the new value after the edit and the old
value after the reverse edit, and Gate 0 passes on the sequence. Two
refusal cases: an option change of a module, and an untracked dependent.
*As built:* `tool/gate_b.sh`, passed; the entry "2026-09-05, Gate B" in the
log. Three deviations. The chain refreshes its trace before the comparison
with the founding of the final sources: the edit made an 18-element report
whose `vect` is a dynamic dispatch, and its runtime specializations are
roots that only a trace at the edited sources holds; the rebuild after the
refresh applies nothing and precompiles them. The oracle's digest is
canonical: the gensym counters of anonymous functions, closures and
generators are dropped from the signatures and the code, the
`LineNumberNode` literals inside quoted code are stripped, and a root of
the trace that names a gensym of a tracked module has the state `gensym`.
And the reverse edit does not restore `word`: a removed `using` keeps its
binding, so `guess_word` stays `exported`; the gate expects that.

## Stage C — the fresh table and the dead code

The old text objects become a library of named functions; the fresh table
names the live ones; the linker drops the rest.

*Design, as decided before the code (2026-09-05).* The format gets version
3, under `JULIA_REACTIVE_IMAGE=1` (which `materialize_app` sets for the
founding and for a rebuild; reuse implies it); a stock build keeps version
2 unchanged, and a rebuild from a version 2 image is refused. Version 3
holds the function table in `metadata.o`: `jl_image_pointers` gains
`fvar_ptrs` and `fvar_names`, both in id order, so no `fvar_idxs` is
needed; the shard table keeps `gvar_offsets` and `gvar_idxs` per shard and
puts null in the function and clone fields; the loader takes the one
target. The ids are assigned in `reactive_rebase`, because the serializer
consumes them before `jl_dump_native`: the reused functions come first, in
the order of the loaded image (compact, which keeps a wrapper before its
specialization), then the delta with `fvar_base` = the reused count; the
names of the reused functions travel in `jl_native_code_desc_t` and are
copied out before `compile` deletes it. `shard_base` stays as the counter
of the global-slot shards and as the `.r<N>` tag. `FunctionSections` and
`DataSections` go on the target options of the reactive output path;
`create_sysimage` gains `gc_sections`, which adds `-Wl,--gc-sections` to
the link. The exported symbols of an image are few (`jl_image_pointers`,
`jl_system_image_*`, the ccallable entries), so the fresh table is the
root that keeps a function; the per-shard tables of the old objects are
hidden and unreferenced, and go with the functions that only they named.
The size check of Gate C measures the loadable sections (`size`), not the
file: the line tables of `-g1` keep a record of a dead function.

- [x] the emission puts each function in its own section
      (`FunctionSections`, and `DataSections` for the globals) in the
      reactive output path; today the target options set neither.
      *As built:* both options go on the `TargetOptions` of the reactive
      output path in `jl_dump_native_impl` (aotcompile.cpp).
- [x] the fresh `metadata.o` holds the one function table: an array of
      symbol references, one per live code instance, in a fresh order,
      with a fresh `jl_fvar_idxs`. A reused code instance contributes the
      name that the loaded image has for it; a delta code instance its own
      name. The per-shard `jl_fvar_ptrs_<s>` tables of the old objects are
      no longer read; the header counts one function shard.
      *As built:* `jl_fvar_ptrs` (data) and `jl_fvar_names` (NUL-joined,
      `.lrodata`) in `metadata.o`, reached by `jl_image_pointers_t`
      `fvar_ptrs`/`fvar_names`; the table is in id order, so no fresh
      `jl_fvar_idxs` exists. The header's `nshards` counts the global-slot
      shards (the function and clone fields of a shard are null). The
      founding of the oracle chain: `version 3 shards 8 functions 36628`;
      `nm` shows no `jl_fvar_*_<n>` and no `jl_clone_*_<n>`.
- [x] the global slots stay per shard and append-only: the old machine
      code addresses its `jl_sysimg_gvars_<s>` slots directly, so their
      tables stay and the heap fills them. A dead function's globals cost
      a slot and a root until a founding. Record this as the residue that
      a founding compacts.
      *As built:* per shard `jl_gvar_offsets_<s>` and `jl_gvar_idxs_<s>`
      stay; the residue is recorded in `doc/architecture.md`.
- [x] the ids of functions are fresh per build: `fvar_base` and
      `shard_base` go; `gvar_base` stays for the slots. The `.r<N>` suffix
      of the delta's names stays, because the name counter restarts in
      every build.
      *As built:* `reactive_rebase` numbers the reused functions first, in
      the order of the loaded image, then the delta; `fvar_base` stays as
      the reused count and `shard_base` as the global-slot shard counter
      (the `.r<N>` tag). Neither is an offset into an old table now.
- [x] the multi-target case is declared out of the format: an image with
      clones is not chainable. `materialize_app` refuses a `cpu_target`
      with more than one target.
      *As built:* `create_sysimage(reactive_image = true)` refuses a
      `cpu_target` with a `;` and a non-Linux host (`--gc-sections`).
- [x] the link adds `--gc-sections`; check that it drops the unreferenced
      function sections of an object that `--whole-archive` included.
      *As built:* `create_sysimage(gc_sections = true)`, set by
      `reactive_image`. It drops the unreferenced CRT aliases
      (`__extendhfsf2`, `__gnu_*`) that a stock image holds in five copies;
      `__truncdfhf2` stays local to every object by design of
      `inject_aliases`, so Gate C's duplicate check skips the `__` names.
- [x] the heap side: a replaced method stays in the image, found by
      Gate 0. Julia does not close the world of a replaced typemap entry:
      both entries stay valid, dispatch takes the newest one (`gf.c`,
      `get_intersect_visitor`, "must pick the newest insertion"), and the
      old method keeps its source, its specializations and its text. The
      oracle counted seven `shadowed` entries after the two-edit chain of
      HazardApp and none in a founding. Since Stage B the child deletes
      the old methods of a changed expression, which closes their entries
      (`shadowed 0` in the chain of Gate B and of the oracle gate), but
      the closed entry, its method and its code instances are serialized
      still. The reactive serialization must drop a closed entry with its
      method; the invalid code instances (`max_world` closed) go with it.
      Check the `staticdata.c` sysimage path for both (the branches at
      lines 1691-1767 are the package image path).
      *As built:* the reactive serialization (`staticdata.c`) prunes the
      heap. A dead entry has a finite `max_world` and `jl_typeinf_world`
      outside `[min_world, max_world]`; a dead code instance fails
      `codeinst_may_be_runnable(ci, 0)`. The prune walks `defs`, the
      method cache, the leaf cache, `mi->cache` and the `ci->next` chains
      through `record_field_change`; an emptied slot of an eqtable becomes
      the tombstone of the iddict (key `jl_nothing`, value null). The
      front end (`collect_all_method_defs`) visits the live entries only
      (`reactive_visit_methods`), so no dead entry reaches the emission.
      The oracle's `info dead` line counts both (`tool/oracle.jl`); Gate
      C's `heap` step requires zero.
- [x] one delta holds two text functions of one method instance: the
      second build of the oracle chain emits `julia_driver_1060.r8` and
      `julia_driver_1598.r8` for the one specialization of `driver`. Find
      the second code instance and drop it.
      *As built:* the delta list names a method instance twice when the
      main queue and the `invokelatest_queue` of `typeinf_ext_toplevel`
      both hold it; the emission dedups by code instance, and one text
      function comes out. Gate C's `format` step counts one text function
      of `driver`, `chained` and `bench_delta` after every cycle.
- [x] `nm` of the image after a chain shows one definition per live
      function: after the reverse edit of M6, `bench_delta` has one
      definition, and `julia_bench_delta_1526.r8` is gone.
      *As built:* Gate C's `format` step lists every text name with two
      definitions (none; the CRT aliases `__*` are local to every object
      by design). A stock `create_app` leaves `hazard_entry.1` and two
      `jlcapi_hazard_entry_*` wrappers of the entry point; they are one
      definition each.

**Gate C.** M6 and M7 through Gate 0, with no closed typemap entry, no
deleted method and no invalid code instance in the heap of the chain's
image. The size of the image after ten edit-and-reverse cycles equals the
size after one, within the residue of the global slots. The delta of a
rebuild with no edit is zero functions from the second rebuild on.
*Passed 2026-09-08* (`tool/gate_c.sh`, the log entry below): the residue
is 32 bytes per slot, 45 slots per rebuild of the M6 edit, and the gate
bounds the growth of a chain by it.

## Stage D — the server

A compiler process that stays, applies edits, and saves an image without an
exit.

- [x] a throwaway test of `fork` in a Julia process: one Julia thread, no
      GC threads; the child serializes a system image with the exit path
      and exits; the parent continues and serializes again. This decides
      the save path before any server code exists.
      *As built (2026-09-08):* `fork` works, with one repair in the child.
      A plain `fork` hung the child and corrupted the parent: the JIT
      writes new code through a descriptor of `/proc/self/mem` that it
      opened at start (`cgmemmgr.cpp`, the self-memory allocator), and
      after a fork that descriptor names the parent's memory. The child's
      first toplevel thunk landed in the parent and the child ran zeros
      (a write to `jl_fptr_args`, reported as `ReadOnlyMemoryError`).
      `jl_reactive_fork()` (cgmemmgr.cpp) forks and, in the child, opens
      the child's own `/proc/self/mem` before anything compiles. The
      bundled libuv has no `uv_loop_fork`, so the child keeps the epoll
      descriptor of the parent; it runs the loop only inside the writer's
      wait for an empty scheduler, while the parent waits for it. With one
      Julia thread the process has no GC thread. The test: from the Gate
      C store's image with reuse, the child wrote a delta (5 functions,
      2.2 s) through `jl_write_compiler_output` and `_exit`; the parent
      collected, defined one more function and wrote its own delta at
      exit (17 functions); both objects link with the store's ancestors
      and both images run their functions from image code.
- [x] if `fork` fails: an audit of `staticdata.c` for the mutations that
      the serialization makes on the live heap, and an in-process save
      that undoes or avoids them. Record the list in the plan.
      *Not needed:* `fork` works; the child's serialization mutates the
      child's copy of the heap only.
- [x] the server: a Julia process in the output mode of the child
      (`jl_generating_output()` true for its whole life), with a command
      loop on a socket: `apply`, `save`, `refresh-trace`, `quit`. The
      builder starts it, or connects to one that runs.
      *As built (2026-09-08):* `src/reactive_server.jl` of PackageCompiler,
      loaded by the server script after the child harness. The builder
      starts `julia --sysimage=<last image> --output-o=<store>/server.a
      <script>` with `JULIA_REACTIVE_REUSE=1`, detached, its log in the
      store, and records the session (socket, base snapshot, pid) in
      `server.toml`; a later `materialize_app(...; server = true)` (or
      `JULIA_REACTIVE_SERVER=1`) reuses the server that answers `status`.
      The socket is a Unix socket in the temp directory (a socket path
      holds 107 bytes, a store path can be longer); raw `socket`,
      `connect`, `read` and `write` calls on both sides, one request per
      connection, one line each way, no libuv. `apply <spec.toml>` runs
      `rc_apply_tracked` and the trace on the arguments of the spec (the
      same arguments the child script embeds); `save <archive>` forks
      through `jl_reactive_fork`, the child runs the tail of the object
      script, `jl_reactive_set_output(archive)` and
      `jl_write_compiler_output`, then `_exit`; `status` answers the world,
      the saves and the resident size; `quit` clears the output and exits.
      A refusal is an exception (`RcRefusal`): the child exits with 3 as
      before, the server answers `refused`. `refresh-trace` is not a
      request: the trace is store state, and an `apply` precompiles it.
      On HazardApp an apply answers in 0.1 s and a save in 2.4 s; the
      builder's step is 3.2 s with the link, inside a process whose own
      start costs 5 s more.
- [x] the state invariant: after `save`, the server learns the names of
      the image it wrote, so that the reuse test of the next save sees the
      delta as image code. A restart from the last image gives the same
      next delta as the server would give.
      *As decided (2026-09-08):* the server learns nothing after a save.
      The code instances that a save emits exist in the parent (the apply
      inferred and compiled them), but the slot values of the emitted
      text are objects that codegen made in the child, and the parent has
      no copy; a table of names alone would not let the next save reuse
      the text. So the reuse test of every save sees the image the server
      loaded as image code, the delta of a save holds every change since
      the server started (a few functions per edit; codegen, no
      inference), and the image of a save links the founding's texts, the
      deltas of the base chain and the new delta: one image per save,
      the older deltas of the server unlinked. A snapshot records its
      base. The memory item below bounds the delta with a restart. Gate D
      checks the restart against the server by the oracle.
- [x] the incremental front: the server keeps the world of the last save;
      the scan for the delta filters code instances by `min_world` above
      it instead of a walk of every method table.
      *As built (2026-09-08):* not by the world of the last save but by
      the direct list of the image's code. The front walks the methods
      once, and every code instance of the loaded image that is still
      valid in a build world is reused on the spot; a method instance
      that such code serves in every world stays off the worklist, so the
      compile pass sees the new code only, and the reused callees it
      finds join the list through a set. On the routing sample the walk
      costs 11 ms and the direct list 40 ms (32975 code instances, 28876
      method instances served), where the compile pass took 1.4 s. The
      pass over the methods with a compilable signature
      (`infer_all_method_defs!`) runs for the methods newer than the
      loaded image only; it took 1.2 s for every method. What is left of
      the save is the heap: 3.2 s for 3 million objects (the queue 1.8 s,
      the write 1.2 s), and the dump of the object 0.5 to 1.2 s.
- [x] the memory of the server: JIT code and old method versions stay
      until a restart; the builder restarts the server from the last
      image after a bounded number of saves or a bounded resident size.
      *As built (2026-09-08):* `status` answers the saves and the
      resident size; past `JULIA_REACTIVE_SERVER_SAVES` (200) or
      `JULIA_REACTIVE_SERVER_RSS_KB` (16 GB) the builder quits the server
      and starts one from the last image, which holds the same state. On
      the routing sample the resident size is 500 MB after ten saves,
      flat: the code of ten edits of one function is small.

**Gate D.** Ten routing edits in a row through the server: each rebuild in
at most 4 s; the resident size after ten saves; kill the server after save
k, restart from image k, apply edit k+1: the same delta as the server gives,
by Gate 0. Every image of the ten passes Gate 0.
*Measured 2026-09-08* (`tool/gate_d.sh`): a rebuild of the routing sample
through the server is apply 2.0 s (the trace 1.4 s), save 6.5 s (the
front 1.3 s, the heap 3.2 s, the dump 1.2 s), link 1.4 s. The bound of 4
s is below the heap write of a full image (3.2 s) plus its dump and link
(2.6 s); the front and the trace were the parts that the server could
still cut, and it cut them. Stage F is the item that meets the bound:
an image written by pages. The log entry below has the outcome of the
other checks.

## Stage E — the trimmed product

A trimmed image derived from the compiler's heap at a save, with the
reused code as roots, so that a trim-clean program keeps its trimmed
binary through the edits. Option `trim`.

- [ ] the trim pipeline of a store: a prerequisite, and a decision.
      The trimmed flagship binary is built by `tool/trim-routing` of
      omnet-julia (`trim_phase.sh`: `--trim=safe --experimental
      --output-exe` from an entry file) with the sealed-abstract compiler
      of the `sealed-aot` branch of julia-aot, not through
      PackageCompiler, which has no trim at all; with the stock verifier
      of this branch the routing sample is not trim-clean. So the
      trimmed product of a save needs either the sealed-abstract
      compiler on the `reactive-compiler` branch (a merge of that
      compiler work), or a program that the stock verifier accepts for
      Gate E, with the flagship after the merge. The user decides.
- [ ] the reused code counts as compiled: the trim verifier
      (`verify_typeinf_trim`) takes the reused code instances as resolved
      callees, and the reachability prune of trim
      (`jl_prune_module_bindings`, `jl_prune_method_specializations`)
      takes them as roots. Their edges were verified when they were
      compiled, and a code instance that an edit invalidated is not
      reused, so the check holds. The inferred IR of the reused code is
      in the untrimmed heap, so reachability can be computed from it.
- [ ] a trim failure is a refusal: an edit that makes a static call site
      dynamic invalidates the caller, the caller lands in the delta, the
      verifier names it, and the rebuild answers `refused` with the
      verifier's reason (catalog id T1). The store and the product are
      unchanged.
- [ ] the second output of a save: after the untrimmed archive, a second
      forked child writes the trimmed archive with `jl_options.trim` set
      for that write only (the trimmed heap, the fresh table of the
      reachable functions, the delta's and the reused text; the linker
      drops the rest). The builder links it into `<app_dir>/trimmed/`.
      Without the server the child writes both archives before its exit.
- [ ] the option `trim` (`:off`, `:on`, `:once`) and its variable; the
      product's bundle beside the untrimmed one; `trim = :on` on a store
      founded with `:off`.
- [ ] the incremental verification: the reachable set of a save is the
      reachable set of the base plus the delta's cone minus what the
      edits invalidated; the verifier walks the delta's edges only. Until
      then a save with `trim = :on` pays a whole pass, a few seconds on
      the routing sample.

**Gate E.** The routing sample (the flagship is trim-clean) founded with
`trim = :on`: the trimmed product of every one of ten edits runs the
Backbone configuration with the hop mean of the edit; its loadable size
stays within the residue of the trimmed founding's; the untrimmed image
passes Gate 0 as in Gate D; an edit that adds a method to a static call
site is refused with the verifier's reason and leaves both bundles as
they were.

## Stage F — the image written by pages

A save writes again only the pages of the image that the process wrote
and appends the new objects; the clean pages are copied from the base
image's file. Option `image = :pages`. This is the item that meets the
bound of Gate D.

- [x] the measurement first: a throwaway experiment protects the pages of
      the loaded image at start (`mprotect`), counts the pages that one
      routing edit and its save write, and lists the writers (the method
      tables, the caches, the bindings, the GC). This decides the gain
      before any writer code exists. The GC must not write into the
      image's pages during a collection (the image's objects are
      permanently marked); if it does, the dirty set is every page, and
      the design changes to a diff of the objects at the write.
      *Measured (2026-09-08):* `JULIA_REACTIVE_DIRTY_PAGES=<path>` makes
      the loader protect the data pages of the image after the
      relocations (`reactive_dirty_protect`, staticdata.c), the fault
      handler mark a page and lift its protection at its first write
      (`jl_reactive_dirty_fault`, signals-unix.c), and the writer append a
      report with the writers named by `dladdr`. The routing image has
      41799 data pages (167 MB). A plain start writes 67 to 77 pages. A
      full collection writes none: `gc_try_setmark_tag` returns before
      the store when the object is marked, and the image's objects stay
      marked. A child rebuild with one edit wrote 1666 pages (6.6 MB, 4
      %) before its save, 1450 of them by the compile hint of the trace:
      it stored the precompiled flag into the method instance and the
      code instance of every statement, and the serializer clears both
      flags at the write, so every rebuild stored them again. Under
      reuse the two stores skip the objects of the image (the direct
      list serves them, flag or not), and 219 pages remain (876 KB, 0.5
      %): the invalidations of the edit (`jl_method_table_activate`, 59
      pages), the locks inside image objects (31), the caches and the
      type caches, the pushes into image arrays and the write barrier's
      remembered bit. The save's own writes come after the snapshot of
      the bitmap and do not count: the prune of the backedge lists
      rewrites 24000 pages in place, the locks 1200, the direct list's
      sets 130. A page written by nothing holds objects that reference
      the base's objects only, and every base object stays in a log, so a
      copied page cannot dangle; a page written by a deletion or an
      invalidation is serialized again with the prune.
- [ ] the dirty pages of the runtime: under `image = :pages` the loader
      protects the image's data pages, the fault handler sets the page's
      bit and unprotects it, and the writer reads the bitmap
      (`jl_reactive_dirty_pages`). The base of the bitmap is the image the
      process loaded: the server accumulates the pages since its start,
      which matches the delta it writes; a child's pages are its own.
- [ ] the writer: the bytes of a clean page come from the base image's
      file, the objects of a dirty page are serialized again in place with
      the pruning of the reactive format, the new objects are appended
      after the base, and the relocation lists are merged by page. The
      constant data, the symbols and the global-slot records are appended
      the same way. The heap write drops from 3.4 s to the dirty pages
      and the new objects.
- [ ] the dump without LLVM: the blob becomes a raw section of the object
      through the assembler or a direct ELF writer, not an LLVM global.
      The dump drops from 1.2 s to the copy.
- [ ] the garbage of the log: a dead object on a clean page stays; the
      prune of dead entries applies on the pages that changed, which is
      where a deletion writes; the option `compact` founds again after
      `saves` saves or a growth of `growth`, and `founding = true` founds
      now. The growth per edit is reported with the sizes.
- [ ] the option `image` and its variable; a change of the value is a
      founding; the trimmed product is always a whole write.
- [ ] the child and the server both write by pages: the child from the
      pages of its own run, the server from the pages since its start.

**Gate F.** Gate D with `image = :pages`: each rebuild in at most 4 s;
every image passes Gate 0; a child rebuild from image k equals the
server's image k+1 by Gate 0; the loadable size after ten edits against
the size after one, within the residue of the slots and the garbage the
log reports; a founding after the ten compacts to the size of a fresh
founding within the residue of the slots. Gate C on the page-written
images.

## Stage G — the overlay image

A save writes the delta as its own shared object, with the new objects,
the patches of the base's objects and the fresh function table; the
loader applies the patches to the mapped base at start. No link of the
whole image. Option `image = :overlay`.

- [ ] the format of an overlay: the new objects with relocations into the
      base, the patch list of the base's dirty pages, the fresh function
      table, the delta's text; a chain of overlays over one base.
- [ ] the loader: the base is mapped as now, the overlays in order, each
      one's patches applied and relocations resolved; the function table
      of the last overlay names the live functions.
- [ ] the builder: no link; the bundle gains one shared object per save;
      `compact` bounds their number through a founding.
- [ ] the option and the founding on a change of it.

**Gate G.** Gate F with `image = :overlay`: each rebuild in about 1 s; the
same checks; a bundle with ten overlays starts within the residue of the
start of the founding's bundle.

## Beyond

The items that the catalog leaves open, not planned in detail.

- F3 for dependencies: the sources of the packages of the Manifest are
  available; the same diff applies to them, at the cost of a ledger for
  every package. Until then a version change is a founding.
- the compaction of the global slots without a founding.

## Risks

- `fork` in a Julia process is untested. The GC, the signal handlers and
  the thread pool of the runtime were not written for it. The throwaway
  test of Stage D is first for that reason, and the in-process save is the
  fallback.
- The redefinition of a struct in Julia 1.12 makes a new type; methods on
  the old type stay on the old type until re-evaluated. Stage B finds the
  dependents in the tracked sources; a dependent outside them is a
  refusal. A dependent inside a package image (a dependency that names an
  application type in a signature) cannot exist, because a dependency
  does not know the application.
- Inference from the trace can give a code instance that differs from the
  founding's for the same method instance. The invariant is semantic, and
  the oracle compares signatures, lowered code, output and globals, not
  images.
- A dynamic dispatch that no trace saw runs through the JIT of the binary.
  Correct, and a refresh of the trace fixes the speed. Gate A measures the
  cost.
- The single-target rule becomes a rule of the format in Stage C. A
  multi-target image cannot be chained.
- The GC could write into the image's pages during a collection (a mark
  bit, a remembered-set entry). Then the dirty set of Stage F is every
  page and the page design gives nothing; the measurement item is first
  for that reason, and the fallback is a diff of the objects at the
  write, which keeps the walk.
- The relocation lists of the image may not merge by page (an entry that
  spans two pages, an order that is not by offset). Stage F's writer then
  rebuilds the lists of the dirty pages from the objects, at a cost.
- The log grows with garbage between foundings; a long session without
  a founding loses the size that Gate C won. The `compact` option and the
  growth report bound it.
- Trim and the log pull the other way. A trimmed product stays a whole
  write; a session that wants both a fast rebuild and a trimmed binary at
  every save pays the trim's pass each time.
- A page protected by `mprotect` costs a fault on its first write. The
  compiler process writes few image pages; a program that writes many
  (the server never runs the program) would pay it.

## Log

**2026-09-08, the plan.** Two questions after Gate D: whether the
incremental compile can keep a trimmed binary, with and without the
server, and whether the image can be appended to or partly overwritten
instead of written whole. Both are yes; the decisions "The compiler's
heap is never trimmed", "The image is a log between foundings" and "The
options are orthogonal" record the answers, the section "The options"
the controls, and Stages E, F and G the work, with the measurement of
the dirty pages first.

**2026-09-08, Gate D.** The server (`tool/gate_d.sh`, ten routing edits
through one server). The founding 3:07; every edit k gives the hop mean
(k+1) times the founding's, exact; every image holds 0 closed entries, 0
invalid code instances and 0 shadowed methods; a child rebuild from the
copy of the bundle after save 5 with edit 6 equals the server's image 6
by the oracle (1637 methods, 3203 roots, 11 globals) and runs the same
mean; the resident size of the server is 492 MB after the first save and
502 MB after the tenth. The one check that fails is the bound: a rebuild
is 7.0 to 7.6 s of `materialize_app` (one 11.2 s), where the plan says
4 s. The parts: the apply 1.9 s the first time and 0.4 s after (the
signatures of the trace are cached, and a statement that did not resolve
stays failed), the save 5.6 to 6.0 s, the link 1.4 s. Inside the save:
the collections 0.0 s, the front 0.2 s (the walk of the methods 11 ms,
the direct list 42 ms for 32974 code instances, the pass over the new
methods 118 ms; it was 1.4 s and 1.2 s before), the emission of the
delta about 0.6 s, the heap 3.4 s for 3 million objects (the queue 2.0
s, the write 1.1 s), the dump of the object 1.2 s. The heap, the dump
and the link are the floor of a full image, 6 s; the bound of 4 s needs
an image that is not written whole, which the plan does not have.

Three findings. A plain `fork` hung the child and corrupted the parent:
the JIT writes code through a `/proc/self/mem` descriptor opened at
start, and after a fork it names the parent's memory; `jl_reactive_fork`
opens the child's own. The front print used `round` with `digits` in
the world of the compiler, where that method is too new; the child's
exception unwound into the loop, answered the request from the child
and left it on the socket while the parent waited; the child of a save
exits on any error now. And the founding's trace comes from the C
printer of `--trace-compile`, which prints a struct in a type parameter
with its field names, a form that no constructor accepts, while the
trace of a refresh comes from Julia's `show`, positional; the child
rewrites the first form into the second (113 statements of the routing
trace), and about 800 of 3203 stay unresolved: modules the routing
binary does not load and type forms the printer cannot round-trip.

**2026-09-08, Gate C.** The fresh table and the dead code (`tool/gate_c.sh`).
The chain on HazardApp: founding 1:00 and 6.2 GB; an edit or its reverse
8.7 s (12 functions, 45 slots; 6 expressions applied, 1 method kept, 5
replaced, 4 new method instances after the trace); a rebuild with no edit
8.8 s and 0 functions. The image is version 3 with one function table and
one text definition per live function after every rebuild (`driver`,
`chained`, `bench_delta` one each); the heap holds 0 closed entries and 0
invalid code instances; the loadable size after reverse 1 is 166141133,
after reverse 10 166166261: 25128 bytes over 810 slots in 18 rebuilds,
under the bound of 35136 (32 bytes per slot, 512 per rebuild). The size
step of the gate fails beyond the bound. The older gates pass on the same
build: M6 14 of 14 shapes and `state` 0 three times (founding 1:02, edit
10.9 s, restore 9.0 s); Gate B checks 1-4 equal both ways (70/47/34/6 and
69/47/32/6, `dead 0`); the oracle gate checks 1-4 equal (69/47/16/6).
M7 on the routing sample of omnet-julia: founding 3:02 and 9.5 GB, the
edit 20.9 s (63951 of 64096 functions reused, 884 emitted, 708 slots),
the refresh 19.7 s (6 functions, 2 slots), the restore 18.3 s (1
function, 6 slots), hop means 2.308011, 4.616022, 4.616022, 2.308011.
The no-edit rebuild after an edit is 13 KB larger than the edit's image,
and the reverse edit 13 KB smaller again: an edit invalidates the cache
entries that the trace made, the next rebuild makes them again. The
growth across a cycle is the slots.

The first run of the gate found the chain growing 2.7 KB per rebuild
beyond the slots, and a no-edit rebuild growing 19 KB. Seven roots, found
with `JULIA_REACTIVE_HEAPDUMP` (one line per object with its first
referrer, `tool/heap_chain.py` follows a chain): every `Module()` of a
rebuild stayed through `Base.usings_backedges`, and the compiled method of
the warm-up through `scanned_methods` of its module, so both lists are
weak in a reactive image (staticdata.c); a closure in the object script of
PackageCompiler rooted the script's module through the method table (a
loop); a `--output-o` process runs no `__init__`, so the temporary files
of the child stayed on the disk and their paths in
`Base.Filesystem.TEMP_CLEANUP` (the script purges the list before the
write); the child kept its state in `Main.rc_state`, the set of every
method instance (cleared); `Method.interferences` linked every dead
`hazard_entry` to the next, so the set is weak in a reactive image; the
`@ccallable` entry point resolved in the world of the compiler named the
deleted method (the latest world only); and a deleted method keeps its
code instances open, so the previous image served them (the build skips a
method that `jl_methtable_lookup` no longer finds; the skip also drops the
leftovers of Base's bootstrap). What remains is the residue proper: a slot
of the loaded image keeps its value, so the founding's `@ccallable`
wrapper keeps the founding's code instance of its target and the deleted
method behind it, once.

The checkout moved to `julia-reactive-compiler` during the work: the
tools derive the checkout from their own location now, and a store pins
the absolute paths of its snapshot, so a moved checkout needs a founding.

**2026-09-05, PackageCompiler.** PackageCompiler founds and bundles; the
reactive compiler rebuilds. Today `materialize_app` calls two public
functions of it, `create_app` for the founding and `create_sysimage` for
the rebuild. Stage C takes the link (`--gc-sections`, the fresh table) and
Stage D takes the rebuild (a server is not one child and one exit), so
after Stage D the compiler calls PackageCompiler once per store, at the
founding, through public keywords (`precompile_statements_file` for the
trace that the store keeps). The fork of PackageCompiler on branch
`reactive` is retired then. The compiler stays in `contrib/reactive-compiler`
of the Julia tree: the runtime patch and the tool must match versions.

**2026-09-05, Gate 0.** `tool/oracle.jl` and `tool/oracle_gate.sh`. The
chain: a founding in 59 s and 6.0 GB, the first edit in 8.6 s (138 direct
calls), the second edit in 7.9 s (11 direct calls, one of them
`julia_chained_1424.r8` of the second build, named as an undefined symbol
by the third build's delta and defined once by the image). The founding of
the final sources: 58 s. The digests: 35 methods and 37 valid code
instances in both images; checks 1 and 2 equal; checks 3 and 4 differ by
`state` and `FINALIZED` alone (4 in the chain, 0 in the founding).

Two findings. A replaced method stays valid in the typemap: Julia keeps
both entries and dispatch takes the newest, so the digest keeps the newest
entry of each signature and counts the others as `shadowed` (seven in the
chain, none in the founding); Stage C drops them. And a foldable callee
with a constant argument leaves no call in its caller: the first `chained`
was `x + 1`, and the third build named no symbol of the second; it now
reads a `Ref`.

**2026-09-05, Gate A.** The rebuild without execution. M6 (`tool/m6_gate.sh`,
no `state` line): founding 61 s and 6.0 GB, the edit 8.7 s, the restore
7.9 s, 14 of 14 shapes and `state` 0 in all three runs, the trace 28
statements and 0 unresolved. Oracle: founding 1:07, s2 9.2 s (178 direct
calls), s3 8.3 s (11 direct calls, `julia_chained_1556.r8` of s2 named by
the delta of s3), the founding of the final sources 1:26, checks 1-4 all
equal. M7 (`tool/m7_gate.sh`, with the `refresh` and `run-refreshed`
steps): founding 3:12 and 9.4 GB on a fresh depot, 3203 statements; the
edit 18.6 s (385 roots, 347 direct calls; 2289 statements precompiled and
914 unresolved in 1.36 s; 26 new method instances); the refresh 18.0 s
(2289 kept, 914 dropped, 0 added; 4 roots); the restore 17.8 s (1 root);
runs 68.3 (before, right after the founding), 61.3, 61.8, 63.2 s; an
earlier series with the same code but the `Main` closures still traced:
61.4, 61.8, 61.9, 61.3, 61.8 s. The founding once took 5:44 with three
image writes: `materialize_app` consumed `incremental` and `create_app`
defaulted to a fresh sysimage; it forwards `incremental = true` now.

**2026-09-05, Gate B.** The recorder and the classifier (`tool/gate_b.sh`,
`src/changes.jl` of HazardApp with the fourteen cases and two refusals).
The chain: founding 2:13 and 6.1 GB; the trace 47 statements, 23 of
HazardApp; the edit 20.7 s (every category in the report, `use_times2` out
of the cone, 2 methods kept by the filter, 9 deleted, 21 lines updated, 44
new method instances); the reformat 15.4 s (0 expressions, 0 removals, 30
lines updated); the refresh 4.2 s (48 kept, 1 dropped, 2 added: the
runtime specializations of the report's `vect`); the rebuild after it 12.4
s (0 expressions, 6 new method instances); the founding of the final
sources 1:17 and 6.0 GB; checks 1-4 equal (70 methods, 47 roots, 34
output lines, 6 globals; 66 and 65 code instances, 0 shadowed). The
restore 12.4 s (20 expressions, 2 removals, 1 kept, 10 deleted, 21 lines
updated, 15 new method instances); its digest against the digest of the
first image: checks 1-4 equal (69 methods, 47 roots, 32 lines, 6 globals),
`word` excepted. The refusals: `F1 HazardApp.jl:10 other: @optlevel is a
module option` and `B2 changes.jl:79 Corner: the untracked untracked.jl:3
corner_of names the type`, the store and the binary unchanged in both.
The two older gates pass on the same tools: M6 14 of 14 and `state` 0
three times; the oracle gate checks 1-4 equal (69 methods, 47 roots,
16 lines, 6 globals) with `shadowed 0` in the chain, where Gate 0 had
seven: the child deletes the old methods of a changed expression now.

Six findings. `jl_method_def` never skips an identical redefinition, so
D2 is the runtime filter `jl_reactive_set_method_filter`: the child keeps
a method whose module, signature, flags and uncompressed IR are equal, and
the kept method keeps its own line table. The generator of a generated
method is an anonymous method at `none:0`: the ledger owns no such method,
so `rc_delete_method` deletes it with its generated method, or it stays as
dead code that no founding has. The gensym counters of anonymous
functions, closures and generators differ between a chain and a founding,
and a quoted `LineNumberNode` (the body of a macro, the answer of a
generator) keeps the line of its last evaluation through a reformat: the
oracle drops the counters and strips the quoted lines, and a root that
names a gensym of a tracked module has the state `gensym`. A dynamic
dispatch that the founding's trace never saw is compiled by the JIT of the
binary until a refresh of the trace and a rebuild, so the gate refreshes
before it compares. A removed `using` is not applied: Julia has no
un-import. And an untracked expander of a tracked macro is invisible,
because an expansion leaves no trace in the expander's method.

**2026-09-05, the plan.** Written from the discussion of the six points:
restart or server; the catalog; the tracker; no execution in the compiler;
dead code; the save without an exit. Two decisions closed the discussion:
the trace is store state that the user refreshes, and the fresh table lands
before the server. The oracle moved to Stage 0, because every later stage
is accepted through it.
