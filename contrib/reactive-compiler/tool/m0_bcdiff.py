#!/usr/bin/env python3
"""M0: compare the functions of two bitcode archives, as `llvm-dis` prints them.

`--output-unopt-bc` and `--output-bc` write the module before and after Julia's
LLVM pipeline, as an archive of `text#N_unopt.bc` / `text#N_opt.bc` members.
Comparing the same two builds at both levels and at the object level says
where a difference is born: in codegen, in the passes, or in the backend.

    python3 m0_bcdiff.py L1.opt.bc.a L2.opt.bc.a               # counts
    python3 m0_bcdiff.py L1.opt.bc.a L2.opt.bc.a --explain 5   # first five diffs
    M0_DIS=/usr/bin/llvm-dis-20 ...                            # the llvm-dis to use

The normalization of one line of a function body:

  * a global reference `@name` or `@"name"` has every run of digits replaced by
    `#`, so that a counter (`julia_foo_123`, `jl_global#7`, `_j_const#3.1`) is
    not a difference;
  * `!dbg !123` and every other metadata attachment `!kind !N` is dropped;
  * an attribute group `#N` is canonicalized to `#`;
  * local values (`%12`, `%"x::Int"`) and labels are kept as they are.

The text of the whole file is never held in memory: functions are hashed as
they stream by, and a second pass collects the texts of the differing names.
"""
import difflib
import hashlib
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m0_objdiff as O

DIS = os.environ.get("M0_DIS", "llvm-dis-20")
DEFINE = re.compile(r'^define .*?@("?)([^"(]+)\1\(')
GLOBAL = re.compile(r'@("?)([^"\s(),]+)\1')
META = re.compile(r'(, | )![a-zA-Z_.]+ !\d+')
ATTR = re.compile(r'#\d+')
# M0_MASK_SLOTS=1 hides the GC frame slot that a root got: the byte offset of
# a `getelementptr i8` into a frame, and the name of a `ptr` local, also when
# parameter attributes (`ptr nocapture readonly %6`, `ptr ... sret({...}) align
# 8 %13`) stand between the type and the name. It is a coarse mask, so a
# difference that survives it is not a slot assignment.
MASK_SLOTS = os.environ.get("M0_MASK_SLOTS") == "1"
SLOT = re.compile(r'(getelementptr inbounds nuw i8, ptr %\d+, i64 )\d+')
PTR = re.compile(r'\bptr((?: (?:[a-z_.]+(?:\([^()]*(?:\([^()]*\)[^()]*)*\))?'
                 r'|"[^"]*"(?:="[^"]*")?|\d+))*) %\d+')


def norm(line):
    line = META.sub("", line)
    line = ATTR.sub("#", line)
    if MASK_SLOTS:
        line = SLOT.sub(r'\1#', line)
        line = PTR.sub(r'ptr\1 %#', line)
    return GLOBAL.sub(lambda m: "@" + O.canonical(m.group(2)), line)


def stream_functions(path):
    """Yield (canonical name, exact name, [normalized lines]) for every define."""
    p = subprocess.Popen([DIS, "-o", "-", path], stdout=subprocess.PIPE, text=True, bufsize=1 << 20)
    name = None
    lines = []
    for line in p.stdout:
        if name is None:
            m = DEFINE.match(line)
            if m:
                name = m.group(2)
                lines = [norm(line.rstrip("\n"))]
            continue
        lines.append(norm(line.rstrip("\n")))
        if line.startswith("}"):
            yield O.canonical(name), name, lines
            name = None
    p.wait()
    if p.returncode != 0:
        raise RuntimeError("%s failed on %s" % (DIS, path))


def members(archive, d):
    subprocess.run(["ar", "x", os.path.abspath(archive)], cwd=d, check=True)
    return sorted(os.path.join(d, x) for x in os.listdir(d) if x.startswith("text"))


def fingerprints(paths):
    c = Counter()
    for path in paths:
        n = 0
        for cname, name, lines in stream_functions(path):
            h = hashlib.sha1("\n".join(lines).encode()).hexdigest()[:16]
            c[(cname, h)] += 1
            n += 1
        print("    %-24s %8d functions" % (os.path.basename(path), n), file=sys.stderr)
    return c


def texts(paths, wanted):
    t = defaultdict(list)
    for path in paths:
        for cname, name, lines in stream_functions(path):
            if cname in wanted:
                t[cname].append((name, lines))
    return t


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    pa, pb = sys.argv[1], sys.argv[2]
    explain = int(sys.argv[sys.argv.index("--explain") + 1]) if "--explain" in sys.argv else 0
    la, lb = (os.path.basename(p).split(".")[0] for p in (pa, pb))
    with tempfile.TemporaryDirectory(prefix="m0_", dir=os.path.dirname(pa) or None) as da, \
            tempfile.TemporaryDirectory(prefix="m0_", dir=os.path.dirname(pb) or None) as db:
        ma, mb = members(pa, da), members(pb, db)
        print("reading %s" % pa, file=sys.stderr)
        a = fingerprints(ma)
        print("reading %s" % pb, file=sys.stderr)
        b = fingerprints(mb)
        only_b, names_a = O.compare(a, b, la, lb)
        if "--list" in sys.argv:
            byname = Counter()
            for (nm, h), k in only_b.items():
                byname[nm] += k
            print("--- functions of %s without an identical twin in %s (name: count)" % (lb, la))
            for nm, k in byname.most_common(int(os.environ.get("M0_LIST", "40"))):
                print("    %6d  %s" % (k, nm))
        if explain:
            wanted = set(nm for (nm, h) in only_b)
            ta, tb = texts(ma, wanted), texts(mb, wanted)
            shown = 0
            for nm in sorted(wanted):
                if len(ta.get(nm, [])) != 1 or len(tb.get(nm, [])) != 1:
                    continue
                (xa, txa), (xb, txb) = ta[nm][0], tb[nm][0]
                print("--- %s: %s vs %s" % (nm, xa, xb))
                n = 0
                for line in difflib.unified_diff(txa, txb, la, lb, n=1, lineterm=""):
                    print("    " + line)
                    n += 1
                    if n > int(os.environ.get("M0_LINES", "60")):
                        print("    ...")
                        break
                shown += 1
                if shown >= explain:
                    break


if __name__ == "__main__":
    main()
