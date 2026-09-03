# A tree of regions

This branch (`region-tree`, off `region-maturation`) generalizes the region
chain to a declared tree of lifetimes. The motivating shape is a shared trunk
with per-task leaves: sibling leaves are mutually isolated, and each resets on
its own while the trunk persists. The plan is `plan/pending/region-tree.md`;
this file is the result. No pull request is part of it.

Every claim below is a test in this directory.

## The declaration

A region's number is a topological order of the tree: a parent's number is
smaller than its child's. `region_parent!(child, parent)` (or `region_tree!`)
declares an edge; the default, until a declaration, is the chain
`0 <- 1 <- 2 <- ...`, which reproduces the total order the barrier used
before the tree. `region_uptree[r]` is the bitset of r, its ancestors, and
the root -- the regions a store from region r may legally target.

## Stage 1+2 -- sibling isolation (`sibling_isolation_test.jl`)

The barrier tests `(region_uptree[pr] >> cr) & 1` instead of `cr <= pr`: a
child of region cr stored into a parent of region pr is legal iff cr is pr's
own region or an ancestor. A trunk with two leaves shows the coverage the
chain could not express: a leaf may reference the trunk (an ancestor), but a
store from one leaf into its sibling is an escape in **both** directions, and
a store from the trunk into a leaf (a descendant) is an escape. A forward
parent (`parent >= child`) is rejected at declaration.

## Stage 3 -- the reset (`reset_order_test.jl`, `multithread_tree_test.jl`)

A region with a live child must not reset: a leaf holds a legal leaf -> trunk
reference, which the trunk's reset would dangle. `region_reset` refuses with
`-7` while the region's has-child bit is set. The bit is one word per heap:
a `region_set` marks a region live and its parent gains a child; a
`region_reset` marks it empty and, at the parent's last child, clears the
parent's has-child bit. So a leaf resets freely and the trunk resets only
after its leaves -- proven over 200 rounds of leaf churn with the trunk
intact.

A trunk shared by several threads is one region number with a per-heap
instance each, and trunk objects on different heaps legally reference each
other. `region_reset_global` stops the world, checks the child precondition
on every heap, and resets each instance as one act. `multithread_tree_test.jl`
runs three threads that share a trunk under a lock, each churning its own
distinct-id leaf, then resets the trunk globally.

## Stage 4 -- the cost to ordinary Julia

The tree changes the barrier's cold path only (a mask load instead of a
compare, reached solely while a region is in use) and raises the region
count 4 -> 8. Neither touches code that runs when regions are unused. The
GCBenchmarks serial set, vanilla `v1.13.0-rc3` against this build, min of
three interleaved runs on the isolated core:

| benchmark | tree / vanilla |
| --- | --- |
| append | 1.02 |
| linked tree | 0.98 |
| strings | 1.01 |
| bigint pollard | 0.92 |
| big_arrays single_ref | 1.03 |
| big_arrays many_refs | 0.92 |

The tree holds the maturation baseline: within noise of vanilla, the two
stressors at or below it. The six chain regression suites stay green under
the capacity bump.

## The showcase: sibling leaves keep the collector out (`showcase_tree.jl`)

The tree's distinguishing win over the chain is sibling isolation. The chain
is a total order, so two workers' regions are always ancestor-and-descendant:
one may reference the other, and neither can reset while the other references
in. The tree lets the workers' leaves be siblings — declared children of the
same parent — mutually isolated, each reset per event with no coordination.

A mini event loop makes it concrete: a permanent network (region 0), N=3
worker tasks each owning a sibling leaf and a disjoint stripe of nodes. Every
event allocates a burst of transient messages (each referencing a node, a
legal leaf → region-0 edge), updates node state, then resets its leaf. The
same workload runs again with no regions. Three runs, `-t4`, cores 24–27:

| | wall | stock collections | GC time |
| --- | --- | --- | --- |
| tree (per-leaf reset) | ~6.5 ms | **0** | 0.0 ms |
| stock collector | ~8.0 ms | 6 | ~0.9 ms |

Same final result, no quarantine. The per-event leaf reset frees each event's
garbage wholesale, so it never reaches the stock collector — zero collections
across the whole loop, against six for the same churn under the collector, and
the leaves are mutually isolated by declaration, which the chain's total order
could not express.

## Where it stands

The tree's semantics, its reset, its multi-thread reset, and its showcase are
done and proven. Deferred: `region_subtree_reset` and the subtree census (a
two-level trunk/leaves shape needs neither; a deeper tree wants them) and the
64-region lazy-TLS capacity (8 suffices for a trunk plus per-thread leaves).
