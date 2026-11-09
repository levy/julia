# A rebuild applies the changes in the load order

A rebuild evaluates the changed expressions in the order of the tracked file
list. That order is not the order in which Julia loads the files. When an edit
adds a name in one file and uses it in a file that the list puts first, the
rebuild stops with an `UndefVarError`, and the store server keeps a heap with
half of the apply in it. This plan makes the apply follow the load order of the
founding.

## The fault

On 2026-11-09 the rebuild of `omnet_ide` after a landing stopped with:

```
UndefVarError: `LegacyIniFolderEntry` not defined in `OmnetIde.LegacyIniFileEntryToWidgetModule`
Suggestion: this global was defined as `OmnetLegacySimulatorPresentation.LegacyIniFolderEntry` but not assigned a value.
```

The edit added `@document struct LegacyIniFolderEntry` in
`OmnetLegacySimulatorPresentation` and a method on it in `OmnetIde`. In the
tracked list of the store, the file of `OmnetIde` is number 5 and the file of
the struct is number 198. The apply evaluated file 5 first.

The order key is `rc_order(item) = (item.file, item.entry.lines.start)` in
`stdlib/ReactiveCompiler/src/child.jl`: the index of the file in the list,
then the line. The list comes from `tracked_sources` of PackageCompiler: the
files of the application packages first, then the path packages of the
Manifest in alphabetical order, each one as a walk of its includes. So
`ProjecturedKernel` is file 294, after every package that uses it.

The key has a second fault inside one package. Julia evaluates an included
file at the line of its `include`. The key evaluates a whole file before the
files that it includes:

```julia
# DepLib.jl, the root file, file 1
module DepLib
include("extra.jl")      # line 3: extra.jl is file 2, it defines module Extra
using .Extra             # line 4
end

# the order now:     (1, 4) using .Extra   → Extra does not exist yet
#                    (2, 1) module Extra
# the load order:    module Extra, then using .Extra
```

## The model

The apply evaluates the changes in the order in which the founding loaded
them:

- a package after the packages that it loads;
- inside a package, the items of an included file at the line of its
  `include`, and the items of a file after the `include` lines above them.

The key of an item is a path of numbers, compared from left to right:

```julia
# rank of the package, then the line of each include from the root file down
# to the file of the item, then the line of the item
rc_order(item) = [rank(package), line of include in root, ..., line of item]

# DepLib.jl:4 `using .Extra`      → [r, 4]
# extra.jl:1  `module Extra`      → [r, 3, 1]   comes first: 3 < 4
```

A shorter path that is a prefix of a longer one comes first, so an `include`
line comes before the items of its file. The apply skips the `include` items
themselves, as it does now.

## Decisions

These are my proposals. The owner approves them with the plan.

- **D1. The key is computed in `ReactiveCompiler`, not in the list of
  PackageCompiler.** The order of a list can not say that the items of a file
  go between two lines of another file. The child has the two facts that the
  key needs: the order in which the process loaded the packages, and the
  `include` items of the new ledger. No change to PackageCompiler.
- **D2. The rank of a package is its index in `Base.loaded_modules_order`**
  of the server. Julia loads a package after its dependencies, so that order
  holds every dependency edge of the image. A package that is not loaded (a
  new path package, a C4 root file) gets a rank after every loaded package.
  Nothing loaded can name it: `rc_new_dependency` refuses a `using` of it (F3).
- **D3. The position of a file is the `include` item of the new ledger whose
  path is that file.** The path is computed by `rc_include_path`, the rule
  that the classify step uses now. A tracked file with no such item keeps the
  order of the list after the known files of its package, and the server
  prints one line `rc: order: no include of <file>`.
  *As built (a refinement found in Step 2):* the new ledger holds every
  tracked file only when `rc_needs_all_files` says so: when a change is of
  a kind other than a method or an `:other` expression. Then the key is
  exact. When the ledger holds the changed files alone, every change is a
  method or an `:other` expression, and the key is the rank of the package,
  the index of the file in the list, and the line. That order is right
  across packages, and the order of method definitions does not matter. The
  one case that it can get wrong: an `:other` expression after an `include`
  in a parent file that depends on a changed method of the included file. A
  parse of every file for that case would cost about 6 s on every rebuild
  with a changed `precompile` list, so the plan accepts it. The line
  `rc: order: no include of <file>` appears only when the ledger holds every
  file.
- **D4. The removals keep their order.** They delete methods before any
  evaluation, so their order does not change the result.
- **D5. The same step also fixes the world of the module lookup in the apply
  loop.** `rc_resolve_module` at `child.jl:902` runs at the world of the loop,
  so after the loop makes a new module, Julia prints "access to binding … in a
  world prior to its definition world". The lookup goes through
  `Base.invokelatest`, as the H2 branch above it does. It needs the same image
  build and the same founding, so it costs nothing extra here.

## Steps

The work is done in a worktree `julia-rebuild-load-order` of `merged-next`.
Each step is a commit.

- [x] **Step 1: the test, which fails first.** *Done (25c29e9131,
  8c2de9ee70).* On the `+merged` Julia without the fix, `mat-s3` fails with
  `UndefVarError: Part not defined in DepLib`; with the `DepApp` part of
  the edit taken out, it fails with `UndefVarError: Added not defined in
  DepLib`. So each of the two parts fails on its own. The run of the gate
  needs `PC=~/.julia/packages/PackageCompiler/VcvCs`, the PackageCompiler
  of the IDE build: the default `workspace/PackageCompiler.jl` is 6 commits
  behind and has no `track_dependencies`. The trace step starts from an
  empty file, because the binary of the gate is now fully inferred and its
  workload compiles nothing at run time. *As built:* the module is
  `Added` in `parts/added.jl`, and the binary prints the lines of a plain
  function `shape_lines`, so the edit changes that function and
  `julia_main`, the `@ccallable` entry point, stays as it is. Gate I1
  (`tool/gate_i1.sh`, packages in `tool/i1_dependency`) gets three more steps
  after `refuse`:
  - `edit-order`: one edit with two parts.
    - Across packages: `DepLib` adds `struct Part` and exports it, and `DepApp`
      adds a method on `Part`. `DepApp` is first in the list.
    - Inside a package: `DepLib.jl` adds `include(joinpath(_PARTS,
      "extra.jl"))`, a new file with `module Extra`, and a `using .Extra`
      after it.
  - `mat-s3`: the rebuild of that edit;
  - `run-s3`: the binary prints a value through `Part` and through `Extra`.
  The steps `trace`, `found-final` and `compare` then include this edit too.
  On `merged-next` now, `mat-s3` must fail with the `UndefVarError`. The gate
  comment says that the edits of `DepApp` are new.
- [x] **Step 2: the order key.** *Done (a5de8e5458).* The worktree build
  takes 14 min 18 s at a 9.6 GB peak; `rc_warm` passes with the checks of
  the key. In
  `child.jl`:
  - a table from each new file to its position, made after the new ledger;
  - the rank of each package from `Base.loaded_modules_order`;
  - `rc_order` takes the table, and `RcQueue` holds it;
  - D5, the lookup of the loop through `Base.invokelatest`.
  *As built:* `RcLoadOrder` holds one key per file, a tuple of numbers, and
  `rc_load_order(files, roots, items, every_file)` makes it. The package of
  a root file is its name, because `tracked_sources` finds the root file at
  `src/<package>.jl`. A check in `rc_warm`, the self-test before every
  apply, puts a `using` after the module of the include above it, and
  `Base` before a package that is not loaded. Checked in the `+merged`
  Julia: `Base.loaded_modules_order` holds the modules of the image in load
  order, and `(1, 137, 5) < (1, 197)`.
- [x] **Step 3: the documents.** `doc/architecture.md` and the stage log of
  `robust-incremental-compiler.md` say "in the load order" where they say "in
  file order", with the rule of the key.
- [x] **Step 4: the gates.** Build the worktree (`make`). Gate I1 passes with
  the new steps. Gate B (one change of every category of the catalog, on
  `HazardApp`, compared with a founding by the oracle) and gate C pass,
  because the new key changes the order of every queue.
  *Gate I1 passes (2026-11-09):* `mat-s3` applies the edit, `run-s3` prints
  part 5 and added 7, and the four checks of the oracle are equal between
  the chain and the founding of the final sources (method tables 10 lines,
  roots 0, output 6, globals 1). *Gate B passes:* both comparisons with a
  founding are equal in all four checks, and the two refusals hold. *Gate
  C:* every step passes but `sizes`. The chain grows 103 568 bytes over 10
  edit-and-reverse cycles, and the bound is 35 136 bytes. That step fails
  on the `+merged` Julia without this change too: 100 568 bytes against the
  same bound. So it is older than this plan, and it is not part of it. The
  3 000 bytes of difference fit the longer path of the worktree, which the
  image holds in its file names.
- [ ] **Step 5: the IDE.** After the owner approves the landing on
  `merged-next`: `make` in `julia-merged-next`, then `bin/build_omnet_ide
  --found` in omnet-julia (about 1 h, peak 23 GB). Then one test edit in a
  copy of the change that adds a struct in a dependency and a method on it in
  `OmnetIde`. The rebuild must apply it, and the binary must start. Remove the
  edit and rebuild. The test edit is never committed.

## Not in this plan

- A rebuild that stops halfway leaves its heap in the server. The next
  request then applies to a half-applied heap. A stop of the server after an
  error is a separate change.
- An order for two new packages that load each other. D2 puts every new
  package last, and F3 refuses a `using` of a package that is not loaded.
