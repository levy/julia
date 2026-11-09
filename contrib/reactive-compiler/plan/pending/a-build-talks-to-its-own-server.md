# A build talks to its own server

A rebuild through the compiler server can send its requests to an older
server of the store, and the log of the server can lose its output. Step 5 of
`plan/done/rebuild-applies-in-load-order.md` found both faults. This plan
fixes them in PackageCompiler, branch `reactive`.

## The faults

**An older server answers.** On 2026-11-09 a founding of `omnet_ide` ran for
1 h. At 15:05 a rebuild from a terminal started a server on the old store.
At the end, the founding swapped the new bundle in and deleted the old one,
but it did not stop that server. The next rebuild found no session file,
started a new server, and waited for a server that answers `status` on the
socket path of the store. The old server answered first, so it got the
`apply`, and it failed with the old code of its image. The new server got no
request.

```julia
# _reactive_server_ensure, reactive.jl
process = run(pipeline(detach(cmd); stdout = log, stderr = log); wait = false)
while time() < deadline
    ispath(socket) && startswith(_reactive_request(socket, "status"; quiet = true), "ok") && break
    # any process that answers on `socket` passes, not only `process`
```

**The log loses the output.** `stdout = log, stderr = log` opens the file two
times. Each open has its own offset, so a write to stderr writes over the
start of the output of stdout. A stop by a signal writes a trace of 1.6 KB to
stderr, and that trace replaces the first lines of the log, with the line
`rc: server <pid> listens`. The trim child of a trimmed product
(`trim = :on`) opens its log in the same way.

## Decisions

These are my proposals.

- **D1. A build that starts a server first stops the server that answers on
  the socket path.** That server is not the server of the session, because
  the session server either answered and is used, or it was told to quit.
  The build sends it `quit`. After a `quit`, the build waits up to 10 s for
  the quitting server to remove the socket path, then removes the path
  itself. So the wait reaches only the new server, and the quitting server
  can not remove the path of the new one. No new request and no new field:
  `status` and `quit` exist. The other way, a pid in the answer of
  `status`, adds a field and leaves the old server alive.
- **D2. A founding stops the server of the old store before it swaps the
  bundle**, with `stop_server`, which it calls at its start too. A server
  that a rebuild started during the founding then stops with its store.
- **D3. A log takes one open file for stdout and stderr.** The child
  processes share the file offset, so the writes stay in order. This applies
  to the server log and to the log of the trim child.
- **D4. The test is a new gate, `tool/gate_server.sh`,** on the packages of
  gate I1 (`tool/i1_dependency`). A decoy server, `tool/server_decoy.py`,
  listens on a socket path, writes each request to a file, answers `ok decoy`
  to `status` and `ok` to `quit`, and an error to any other request. It stops
  and removes its path on `quit`.

## Steps

The work is done in the worktrees `julia-own-server` (branch `own-server` of
`merged-next`: the plan and the gate) and `package-compiler-own-server`
(branch `own-server` of `projectured/reactive`: the fix). Each step is a
commit.

- [x] **Step 1: the gate, which fails first.** *Done (2026-11-09).* With
  the PackageCompiler of the IDE build, the gate takes 4 min 15 s at a 6.5
  GB peak, and the three steps fail. `decoy`: the wait of the build takes
  the answer `ok decoy` to `status`, and the decoy gets no `quit`. The
  server of DepApp starts in about 1 s and takes the socket path before the
  `apply`, so on this small image the `apply` reaches the new server; the
  server of `omnet_ide` takes about 3 s. `signal`: the trace of the signal
  writes over the `listens` line. `founding`: the decoy gets no request.
  `gate_server.sh` has these steps:
  - `copy`, `found`: the packages, and a founding of `DepApp` (a child build);
  - `decoy`: a decoy on the socket path of the store, no session file, then
    a rebuild through the server. The rebuild must pass, the decoy must get
    `quit` and no `apply`, and the log must start with `rc: server <pid>
    listens` for the pid of the session;
  - `signal`: a rebuild through the server, then SIGTERM to the server. The
    log must still hold its `listens` line and the trace of the signal;
  - `founding`: a founding of the store in the background. While it runs, a
    decoy starts and a session file names it, as a rebuild from a terminal
    does. When the founding ends, the decoy must have got `quit`;
  - `stop`: the server and the decoys stop.
  With the PackageCompiler of the IDE build (`38dfd6e7`), `decoy`, `signal`
  and `founding` must each fail.
- [ ] **Step 2: the fix.** D1 and D2 and D3 in `src/reactive.jl` of
  PackageCompiler. The gate passes. Gate I1 passes, because it builds with
  the child log of D3.
- [ ] **Step 3: the IDE.** After the owner approves the landing and the push
  of `projectured/PackageCompiler.jl` `reactive`: `Pkg.update("PackageCompiler")`
  in `environment/build` of omnet-julia and of projectured-julia, and a
  precompile there. Then a rebuild of `omnet_ide` passes, and its server log
  starts with the `listens` line.

## Not in this plan

- A rebuild during a founding works on the old store, and the swap discards
  its result. A lock of the store between a founding and a rebuild is a
  separate change.
