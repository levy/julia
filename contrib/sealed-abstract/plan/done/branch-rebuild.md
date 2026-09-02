# Rebuild the branch as a readable series (done 2026-09-02)

The original line held 51 commits: nine patch levels, then the campaign
with its corrections, refuted attempts and instrument bugs in the main
line. The branch was rebuilt as a direct series of 26 commits over the
same base (v1.13.0-rc3):

1. the opening documents (README.md, DESIGN.md);
2. one driver fix (julia-config.jl resolved from the running Julia);
3-13. the mechanisms, one per commit: the sealed world, the split
   budget, verified dynamic dispatch, the admission policy, the repair
   pass, the instrument, coverage, provenance, the frame-walk fix, the
   error explanations, the precompiled self-inference;
14-17. the seal vocabulary and the compiler honoring each claim;
18-21. the two loops, the trace as evidence, the edge log, the flagged
   generic fallback;
22-24. the harness and probes, the trace tooling, the ladder and the
   regression suite;
25-26. MEASUREMENTS.md and HISTORY.md.

Rules the rebuild followed: each commit does one thing and states its
reason; corrections and refuted attempts live in HISTORY.md, not in the
main line; measurements live in MEASUREMENTS.md with reproduction steps;
design decisions and the plan-section register live in DESIGN.md;
changes to stock files never share a commit with new ladder or document
files.

The final tree equals the old tip except a deliberate list: the
documents above; the driver's machine-absolute julia-config path fixed;
six stray execute bits dropped; the stale spike README replaced; stale
"the compiler is elsewhere" comments in sealed.sh and .gitignore
corrected; dead references to the simulator repository's trimming guide
retargeted to DESIGN.md; sealed_patch.py dropped (summarized in
HISTORY.md); *.cov added to .gitignore.

Each compiler commit was verified by building the abstract-six-subtypes
probe with the intermediate compiler (0 errors, the binary runs); the
tip was verified with regress.sh (feature, time, space, both ladders)
and a full flagship rebuild against the oracle hashes.
