#!/usr/bin/env python3
"""heap_chain.py DUMP PATTERN [N]: for the first N (default 3) objects of a
JULIA_REACTIVE_HEAPDUMP dump whose line matches PATTERN, print the chain of
first referrers up to a root (an object that a top-level list reached)."""
import re, sys
dump, pat = sys.argv[1], re.compile(sys.argv[2])
n = int(sys.argv[3]) if len(sys.argv) > 3 else 3
lines, parent = {}, {}
for line in open(dump, errors="replace"):
    line = line.rstrip("\n")
    head, _, tail = line.partition(" <- ")
    addr = head.split(" | ", 1)[0]
    lines[addr] = head
    if tail:
        parent[addr] = tail.split(" ", 1)[0]
starts = [a for a, h in lines.items() if pat.search(h)][:n]
for a in starts:
    seen = set()
    while a in lines and a not in seen:
        seen.add(a)
        print("  " + lines[a][:150])
        a = parent.get(a)
    print("  " + ("(root)" if a is None else "(cycle)"))
    print()
