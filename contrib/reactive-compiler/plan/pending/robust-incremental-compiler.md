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
| A3 | remove a method | `delete_method` on the signature of the removed expression | callers | B | reported, not applied |
| A4 | change a signature | A3 then A1 | callers | B | not applied |
| A5 | keyword or default arguments | one expression, several methods | callers | done | done |
| A6 | generated function, callable struct | the expression | callers | B (test) | untested |
| B1 | add a type | the expression | none | done | done |
| B2 | change the fields or parameters of a struct | the expression, then every tracked expression whose signature, field type or initializer names the type | all code on the type, by binding partitions | B | not applied |
| B3 | change a supertype | B2 for the type and for every subtype, transitively | large | B | not applied |
| C1 | change a `const` | the expression | code that read the binding | B (test) | untested |
| C2 | change the initial value of a global | the expression | none | B (test) | untested |
| C3 | `using`, `import`, `export`, `public` | the expression, then every tracked expression whose name resolution changes | binding partitions | B | not applied |
| C4 | add or remove an `include` | the root file, tracked; the new file's expressions, or the removal of the old file's methods | as the contents | B | needs a founding |
| C5 | add, remove or rename a module | remove and add its contents | large | B | needs a founding |
| D1 | change a macro | every tracked expression that expands it, transitively | as their contents | B | not applied |
| D2 | `@eval` loops, one expression with many methods | the expression; skip a method whose lowered code did not change | as the contents | B | applied with needless invalidation |
| E1 | a file that top-level evaluation reads | the expressions that read it (recorded) | as the expressions | B | not tracked |
| F1 | module-level compiler options | every expression of the module | the module | refuse | needs a founding |
| F2 | the workload or the trace | none | coverage only | A | done |
| F3 | preferences, dependency versions, Julia flags, Base | the package image or the sysimage | everything | refuse (E later) | needs a founding |
| H1 | comments, whitespace, line numbers | none; update the line numbers of the methods in place | none | B | the diff ignores them; lines are not updated |
| H2 | docstrings | the expression | none | done | done |
| H3 | move or rename a file | content-keyed diff, not path-keyed | none | B | not applied |

Every category is supportable, and the cost degrades toward a founding: a
`convert` method or a supertype change invalidates most of the program, and
the rebuild then costs about what a founding costs. F1 and F3 are refused
until Stage E tracks the sources of the dependencies.

A refusal is also the answer when the apply set leaves the tracked sources:
a method of an untracked package whose signature names a redefined type,
or a macro of an untracked package that a tracked expression expands
(the expansion is in the tracked expression, so that one is fine; the
reverse, a tracked macro that an untracked file expands, is the refusal).

## Stage 0 — the oracle

The differential gate that tests the invariant. It runs after every later
stage and is the acceptance test of each.

- [ ] `tool/oracle_gate.sh`: for an application and a sequence of edits
      E1 to En, build the chain (a founding at S0, one rebuild for each
      edit) and the founding of Sn, and compare the two images:
      1. the method tables of the tracked modules: for each module, the
         set of (signature, hash of the lowered code) in the current world;
      2. every root of the trace has a valid code instance in both;
      3. the workload's output, by hash;
      4. the values of the globals of the tracked modules, against the
         values after a plain load of the sources.
      The gate prints one line per check and a size line: the number of
      functions in the text of each image.
- [ ] the comparison runs inside each binary: a `--reactive-oracle` entry
      that walks the modules and prints the digest, so that the gate
      compares two texts.
- [ ] the edit sequences: the routing `+= 2` edit and its reverse; the
      HazardApp edit and its reverse; and a two-edit chain on HazardApp,
      where the second edit changes `driver` only, so that the third build
      calls a function of the second build's delta by its symbol.
- [ ] a record of the result on today's rebuild: checks 1 to 3 are
      expected to pass; check 4 is expected to fail on HazardApp (the
      `state` global is 2 after the edit) until Stage A.

**Gate 0.** The oracle runs on the three sequences; checks 1 to 3 pass;
the two-edit chain links and runs; check 4 reports the known failure.

## Stage A — the rebuild without execution

The trace as store state, and inference as the only work of the rebuild.

- [ ] the founding keeps its trace: `create_app` already runs the
      precompile script in a throwaway process under `--trace-compile`;
      `materialize_app` writes the statements to `reactive-store/trace.jl`.
- [ ] `refresh_trace`: a throwaway process starts from the current image,
      runs the workload under `--trace-compile`, and the union of the
      statements replaces `trace.jl`; a statement whose signature no longer
      resolves is dropped. The builder exposes it as
      `bin/build_omnet_legacy_sample routing --reactive --refresh-trace`.
- [ ] the rebuild child boots from the image, applies the diff, and
      executes `trace.jl`: `precompile` of a valid statement is a lookup,
      `precompile` of an invalid one infers the cone. It never runs the
      workload; `rebuild_workload.jl` goes away.
- [ ] the invalid code instances that no statement of the trace names (a
      callee that a root reached by inference) are inferred through their
      callers: after the trace, a scan of the invalid code instances with
      a valid caller re-infers what the roots missed. Measure whether the
      scan finds anything; drop it if not.
- [ ] harness rule 8 and the `state` line of M6 go: the `state` global
      must read 0 after the edit and after the reverse edit.
- [ ] measure the run after the edit with and without a refresh of the
      trace, to see the cost of a specialization that the JIT compiles at
      run time.

**Gate A.** M6: 14 of 14 shapes, `state` 0 in all three runs. M7: the
routing rebuild in at most 8 s (front 2.3 s, the inference of the cone,
the heap and the link), against 17 s; the same hop means; run time after
the edit within 5 % of the run before it. Gate 0 passes check 4.

## Stage B — the recorder and the classifier

The tracker of top-level evaluation, the apply set closed under it, and the
refusal of what it cannot apply.

- [ ] the ledger: for each tracked file, for each top-level expression
      (keyed by the hash of the expression with line numbers stripped),
      the methods that it defines (their signatures, evaluated in the
      module), the bindings that it assigns, the macros that it expands
      (the heads of every `macrocall`, through recursive expansion), the
      global references of its signatures and initializers, and the files
      that its evaluation reads. The ledger of the old sources is computed
      in the rebuild child from the store's copy, because the image holds
      the modules and types that the signatures need; the ledger of the
      new sources is computed after the apply.
- [ ] A3, A4: a removed or re-signed expression deletes its methods by
      `delete_method` before the additions of the same file.
- [ ] B2, B3: a changed type re-evaluates every tracked expression that
      names the type in a signature, a field type or an initializer, in
      file order; a changed supertype does the same for every subtype,
      transitively. Julia 1.12 allows the redefinition of a struct; the
      compiler process has no instances of the old type, because it never
      executes the program.
- [ ] C3: a changed `using`, `import`, `export` or `public` re-evaluates
      every tracked expression of the module whose free names resolve
      differently before and after.
- [ ] C4, C5: the builder tracks the root file of each package; an added
      `include` evaluates the new file, a removed one deletes the methods
      of the old file, a module block is removed and added as a whole.
      Any other change of a root file is refused.
- [ ] D1: a changed macro re-evaluates every tracked expression whose
      ledger names the macro, transitively through macros that expand to
      macros.
- [ ] D2: before the re-evaluation of a method expression, compare the
      lowered code of each method it defines with the existing one, and
      skip the definition when they are equal. First measure whether
      Julia's `jl_method_def` already skips an identical redefinition.
- [ ] E1: `include_dependency` and the file reads of top-level evaluation
      are recorded; a changed file re-evaluates its readers.
- [ ] H1, H3: the line numbers of the methods of an unchanged expression
      are updated in place; the diff keys expressions by content, so a
      moved file is a move, not a removal and an addition.
- [ ] the classifier: every change gets an id from the catalog; the apply
      report lists the changes by id, the apply set by size, and every
      refusal with its id and reason. A refusal stops the rebuild before
      the apply, with the founding as the advice.
- [ ] a refusal for an apply set that leaves the tracked sources: a
      method of an untracked file whose signature names a redefined type,
      or an untracked file that expands a changed tracked macro.

**Gate B.** A second tracked file of HazardApp, `src/changes.jl`, with one
case per category: A3 (the dispatch falls to a general method after the
removal), A4, A6, B2 with three dependents, B3 with a subtype, C1, C2, C3,
C4 (a new file), D1 with a transitive expansion, D2 (an `@eval` loop with
one changed method: the callers of the others keep their code instances),
E1, H1 (a reformat gives an empty apply set), H3 (a renamed file gives an
empty apply set). Each case gives the new value after the edit and the old
value after the reverse edit, and Gate 0 passes on the sequence. Two
refusal cases: an option change of a module, and an untracked dependent.

## Stage C — the fresh table and the dead code

The old text objects become a library of named functions; the fresh table
names the live ones; the linker drops the rest.

- [ ] the emission puts each function in its own section
      (`FunctionSections`, and `DataSections` for the globals) in the
      reactive output path; today the target options set neither.
- [ ] the fresh `metadata.o` holds the one function table: an array of
      symbol references, one per live code instance, in a fresh order,
      with a fresh `jl_fvar_idxs`. A reused code instance contributes the
      name that the loaded image has for it; a delta code instance its own
      name. The per-shard `jl_fvar_ptrs_<s>` tables of the old objects are
      no longer read; the header counts one function shard.
- [ ] the global slots stay per shard and append-only: the old machine
      code addresses its `jl_sysimg_gvars_<s>` slots directly, so their
      tables stay and the heap fills them. A dead function's globals cost
      a slot and a root until a founding. Record this as the residue that
      a founding compacts.
- [ ] the ids of functions are fresh per build: `fvar_base` and
      `shard_base` go; `gvar_base` stays for the slots. The `.r<N>` suffix
      of the delta's names stays, because the name counter restarts in
      every build.
- [ ] the multi-target case is declared out of the format: an image with
      clones is not chainable. `materialize_app` refuses a `cpu_target`
      with more than one target.
- [ ] the link adds `--gc-sections`; check that it drops the unreferenced
      function sections of an object that `--whole-archive` included.
- [ ] the heap side: check whether the serializer keeps an invalid code
      instance (`max_world` set to 0 at line 1767 of `staticdata.c`) and a
      deleted method in the image. If it does, the reactive path skips
      them, and a method table entry of a deleted method is not written.
- [ ] `nm` of the image after a chain shows one definition per live
      function: after the reverse edit of M6, `bench_delta` has one
      definition, and `julia_bench_delta_1526.r8` is gone.

**Gate C.** M6 and M7 through Gate 0. The size of the image after ten
edit-and-reverse cycles equals the size after one, within the residue of
the global slots. The delta of a rebuild with no edit is zero functions
from the second rebuild on.

## Stage D — the server

A compiler process that stays, applies edits, and saves an image without an
exit.

- [ ] a throwaway test of `fork` in a Julia process: one Julia thread, no
      GC threads; the child serializes a system image with the exit path
      and exits; the parent continues and serializes again. This decides
      the save path before any server code exists.
- [ ] if `fork` fails: an audit of `staticdata.c` for the mutations that
      the serialization makes on the live heap, and an in-process save
      that undoes or avoids them. Record the list in the plan.
- [ ] the server: a Julia process in the output mode of the child
      (`jl_generating_output()` true for its whole life), with a command
      loop on a socket: `apply`, `save`, `refresh-trace`, `quit`. The
      builder starts it, or connects to one that runs.
- [ ] the state invariant: after `save`, the server learns the names of
      the image it wrote, so that the reuse test of the next save sees the
      delta as image code. A restart from the last image gives the same
      next delta as the server would give.
- [ ] the incremental front: the server keeps the world of the last save;
      the scan for the delta filters code instances by `min_world` above
      it instead of a walk of every method table.
- [ ] the memory of the server: JIT code and old method versions stay
      until a restart; the builder restarts the server from the last
      image after a bounded number of saves or a bounded resident size.

**Gate D.** Ten routing edits in a row through the server: each rebuild in
at most 4 s; the resident size after ten saves; kill the server after save
k, restart from image k, apply edit k+1: the same delta as the server gives,
by Gate 0. Every image of the ten passes Gate 0.

## Stage E — beyond

Not planned in detail; the items that the catalog leaves open.

- F3 for dependencies: the sources of the packages of the Manifest are
  available; the same diff applies to them, at the cost of a ledger for
  every package. Until then a version change is a founding.
- `--trim` and reactive reuse: the trim verifier walks the edges that
  reuse skips. With the fresh table and the reachability that the server
  knows, trim can become incremental. Its own milestone.
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

## Log

**2026-09-05, the plan.** Written from the discussion of the six points:
restart or server; the catalog; the tracker; no execution in the compiler;
dead code; the save without an exit. Two decisions closed the discussion:
the trace is store state that the user refreshes, and the fresh table lands
before the server. The oracle moved to Stage 0, because every later stage
is accepted through it.
