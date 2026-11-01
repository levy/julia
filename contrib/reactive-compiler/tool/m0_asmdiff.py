#!/usr/bin/env python3
"""M0: compare the emitted functions of two image builds by their disassembly.

`m0_objdiff.py` fingerprints the bytes of a function with the relocation sites
masked. That misses one thing: a `call` to a function in the same section is
resolved by the assembler and leaves no relocation, so its bytes depend on the
layout. In a one-partition build every call is such a call. This tool
fingerprints the text of `objdump -d -r` instead, with every symbol reference
canonicalized, so that only the instructions and their operands remain.

    python3 m0_asmdiff.py A.a A2.a            # determinism
    python3 m0_asmdiff.py A.a B.a --list      # one edit, with the names
    python3 m0_asmdiff.py A.a B.a --explain 5 # the first five differing pairs

The normalization of one instruction line:

  * the address is dropped, and so is an alignment `nop`;
  * `<sym+0x1c>` becomes `<canonical sym>`, and a resolved `(%rip)` displacement
    next to it becomes `@(%rip)`; a jump into the function itself becomes the
    index of the target instruction, `<L17>`, so that padding of a different
    length does not move every later jump;
  * an instruction that a relocation patches loses the symbolic target that
    objdump prints for it (the nearest symbol to zero, not the callee);
  * a relocation line keeps its type and the canonical target; the addend is
    dropped, except that a local data label (`.LCPI3_1`) is replaced by the
    bytes stored at it, as many as the instruction reads, so that a changed
    literal is seen;
  * a `jl_global#N` slot is canonicalized to `jl_global#`, so a slot renumbering
    is not a difference, but a different object in the slot is not seen either;
  * immediates are kept as they are.

The canonical form of a symbol replaces every run of digits with `#`. Two builds
are compared as multisets of (canonical function name, fingerprint).
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

# M0_MASK_FRAME=1 masks every frame-relative operand (`-0x18(%rbp)`), to
# measure how much of a difference is only the order of the stack slots.
MASK_FRAME = os.environ.get("M0_MASK_FRAME") == "1"
FRAME = re.compile(r"-?0x[0-9a-f]+\(%r[bs]p\)")

HEADER = re.compile(r"^([0-9a-f]+) <(.+)>:$")
RELOC = re.compile(r"^\t+[0-9a-f]+: (R_X86_64_\w+)\t(.*)$")
SYMREF = re.compile(r"\b[0-9a-f]+ <([^>+]+)(\+0x[0-9a-f]+)?>")
# A resolved reference to the same section (`lea 0x9c8c7a(%rip),%rcx # <sym>`)
# leaves no relocation; the displacement is the layout, the comment the target.
RIP = re.compile(r"-?0x[0-9a-f]+\(%rip\)")
DIGITS = re.compile(r"\d+")
SECTIONS = (".text", ".rodata", ".lrodata", ".data", ".ldata", ".bss", ".lbss",
            ".eh_frame", ".debug")


def canonical(name):
    return DIGITS.sub("#", name)


NOP = re.compile(r"^(data16 |cs )*(nop|nopw|nopl|xchg\s+%ax,%ax)")
WIDTH = ((r"broadcast[fi](32x4|128)", 16), (r"broadcast(ss|d)\s", 4),
         (r"broadcast(sd|q|i64x2)", 8), (r"broadcast[bw]\s", 2),
         (r"%zmm", 64), (r"%ymm", 32), (r"(sd|q)\s", 8), (r"(ss|ps|d|l)\s", 4), (r"%xmm", 16))


def literal_width(insn):
    """The bytes an instruction reads from a constant-pool label, by its operand width."""
    for pat, n in WIDTH:
        if re.search(pat, insn):
            return n
    return 8


def function_texts(path):
    """{exact function name: normalized text} for one object.

    Two passes over each function. The first collects (address, instruction,
    relocation) rows. The second turns a reference into the function itself
    into the index of the target instruction, so that alignment padding of a
    different length does not move every later jump; drops the padding; and
    drops the symbolic target that objdump prints for a field that a relocation
    will fill, because that target is the nearest symbol to zero, not the
    callee.
    """
    elf = O.Elf(path)
    label_syms = {sym[0]: sym for sym in elf.symbols() if sym[0].startswith(".L")}
    out = subprocess.run(["objdump", "-d", "-r", "--no-show-raw-insn", path],
                         capture_output=True, text=True, check=True).stdout
    funcs = {}
    name = None
    start = 0
    rows = []

    def flush():
        if name is None:
            return
        index = {}
        for i, (addr, insn, reloc) in enumerate(rows):
            index[addr] = i
        lines = []
        for addr, insn, reloc in rows:
            if reloc is not None:
                insn = SYMREF.sub("", insn).rstrip(" #")
            else:
                def ref(mm):
                    sym, off = mm.group(1), mm.group(2) or ""
                    if sym != name:
                        return "<%s%s>" % (canonical(sym), off)
                    target = start + (int(off[1:], 16) if off else 0)
                    return "<L%d>" % index[target] if target in index else "<.%s>" % off
                if SYMREF.search(insn):
                    insn = RIP.sub("@(%rip)", insn)
                insn = SYMREF.sub(ref, insn)
            if MASK_FRAME:
                insn = FRAME.sub("S(%rbp)", insn)
            lines.append(insn)
            if reloc is not None:
                typ, target = reloc
                sym = re.split(r"[+-]0x", target, maxsplit=1)[0]
                if sym in label_syms:
                    lit = elf.label_bytes(label_syms[sym], literal_width(insn))
                    lines.append("  %s .L=%s" % (typ, lit.hex()))
                elif sym.startswith(SECTIONS):
                    lines.append("  %s %s" % (typ, sym))
                else:
                    lines.append("  %s %s" % (typ, canonical(sym)))
        funcs[name] = "\n".join(lines)

    for line in out.split("\n"):
        m = HEADER.match(line)
        if m:
            flush()
            name = m.group(2)
            start = int(m.group(1), 16)
            rows = []
            continue
        if name is None:
            continue
        m = RELOC.match(line)
        if m:
            if rows:
                rows[-1] = (rows[-1][0], rows[-1][1], (m.group(1), m.group(2)))
            continue
        m = re.match(r"^ *([0-9a-f]+):\t(.*)$", line)
        if m:
            insn = m.group(2)
            if NOP.match(insn):
                continue
            rows.append((int(m.group(1), 16), insn, None))
    flush()
    return funcs


def fingerprints(path, keep_text=False):
    """Counter of (canonical name, fingerprint); optionally the texts by canonical name."""
    funcs = function_texts(path)
    c = Counter()
    texts = defaultdict(list)
    for nm, text in funcs.items():
        h = hashlib.sha1(text.encode()).hexdigest()[:16]
        c[(canonical(nm), h)] += 1
        if keep_text:
            texts[canonical(nm)].append((h, nm, text))
    return c, texts


def archive_fingerprints(archive, keep_text=False):
    total = Counter()
    texts = defaultdict(list)
    with tempfile.TemporaryDirectory(prefix="m0_", dir=os.path.dirname(archive) or None) as d:
        subprocess.run(["ar", "x", os.path.abspath(archive)], cwd=d, check=True)
        for m in sorted(x for x in os.listdir(d) if x.startswith("text")):
            c, t = fingerprints(os.path.join(d, m), keep_text)
            print("    %-14s %8d functions" % (m, sum(c.values())), file=sys.stderr)
            total.update(c)
            for k, v in t.items():
                texts[k].extend(v)
    return total, texts


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    pa, pb = sys.argv[1], sys.argv[2]
    explain = int(sys.argv[sys.argv.index("--explain") + 1]) if "--explain" in sys.argv else 0
    la, lb = (os.path.basename(p).rsplit(".", 1)[0] for p in (pa, pb))
    print("reading %s" % pa, file=sys.stderr)
    a, ta = archive_fingerprints(pa, explain > 0)
    print("reading %s" % pb, file=sys.stderr)
    b, tb = archive_fingerprints(pb, explain > 0)
    only_b, names_a = O.compare(a, b, la, lb)
    if "--list" in sys.argv:
        print("--- functions of %s without an identical twin in %s (name: count)" % (lb, la))
        byname = Counter()
        for (nm, h), k in only_b.items():
            byname[nm] += k
        for nm, k in byname.most_common(int(os.environ.get("M0_LIST", "60"))):
            print("    %6d  %s" % (k, nm))
    if explain:
        shown = 0
        for nm in sorted(nm for (nm, h) in only_b if len(ta.get(nm, [])) == 1 and len(tb.get(nm, [])) == 1):
            (ha, xa, txa), (hb, xb, txb) = ta[nm][0], tb[nm][0]
            print("--- %s: %s vs %s" % (nm, xa, xb))
            for line in difflib.unified_diff(txa.split("\n"), txb.split("\n"), la, lb, n=1, lineterm=""):
                print("    " + line)
            shown += 1
            if shown >= explain:
                break


if __name__ == "__main__":
    main()
