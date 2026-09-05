#!/usr/bin/env python3
"""M0: compare the emitted functions of two image builds.

Julia writes `--output-o` as an archive of `text#N.o` partitions plus
`metadata.o` and `sysimg.o`. This tool reads every text partition, cuts it into
functions, and gives each function a fingerprint that does not depend on the
things fact 8 of the plan says are unstable:

  * the counter in every generated name (`j_foo_1234`, `jl_global#77`), which
    is canonicalized by replacing every run of digits with `#`;
  * the position of a function in its partition and the partition it landed
    in, which do not enter the fingerprint at all;
  * the bytes at a relocation site, which are masked, while the canonical name
    of the relocation target is kept in emission order.

Two builds are then compared as multisets of (canonical name, fingerprint).

    python3 m0_objdiff.py A.a A2.a      # determinism
    python3 m0_objdiff.py A.a B.a       # one edit

A relocation against a local data label (a constant pool entry, `.LCPI3_1`)
contributes the first 16 bytes at that label, so a changed literal is seen. A
section-relative target is canonicalized to its section name; the addend is
dropped. A `jl_global#N` slot is compared by its canonical name, not by the
object it will hold. A PC-relative reference that the assembler resolved leaves
no relocation and is not masked. The last three make the tool report a
difference where the code may be the same, or the same where a slot differs;
the second is the one to remember when reading the numbers.
"""
import bisect
import hashlib
import os
import re
import struct
import subprocess
import sys
import tempfile
from collections import Counter

SHT_SYMTAB, SHT_RELA, SHT_NOBITS = 2, 4, 8
SHF_EXECINSTR = 0x4
STT_NOTYPE, STT_OBJECT, STT_FUNC, STT_SECTION = 0, 1, 2, 3
STB_LOCAL = 0

# x86_64 relocation types and the width of the field they patch.
RELOC_WIDTH = {1: 8, 24: 8, 2: 4, 3: 4, 4: 4, 9: 4, 10: 4, 11: 4, 22: 4, 23: 4,
               41: 4, 42: 4}

DIGITS = re.compile(r"\d+")
# `get_pointer_to_constant` names a merged constant `_j_const#<count>`, and a
# later merge appends `.1`: the name is a counter, the content is elsewhere. A
# string constant is `_j_str_<content>#<count>`, with the same suffixes, in
# the plain or in the mangled (`YY.` for `#`, `DOT.` for `.`) spelling.
CONST = re.compile(r"^_j_const.*")
STR = re.compile(r"^(_j_str_.*?)(YY\.#|##)(DOT\.#|\.#)?$")


def canonical(name):
    name = DIGITS.sub("#", name)
    name = CONST.sub("_j_const", name)
    return STR.sub(r"\1", name)


class Elf:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        d = self.data
        assert d[:4] == b"\x7fELF" and d[4] == 2, "not an ELF64 file: " + path
        shoff, = struct.unpack_from("<Q", d, 0x28)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", d, 0x3A)
        self.sections = []
        for i in range(shnum):
            off = shoff + i * shentsize
            (name, typ, flags, addr, offset, size, link, info, align, entsize) = \
                struct.unpack_from("<IIQQQQIIQQ", d, off)
            self.sections.append(dict(name=name, type=typ, flags=flags, offset=offset,
                                      size=size, link=link, info=info, entsize=entsize))
        shstr = self.sections[shstrndx]
        for s in self.sections:
            s["sname"] = self.cstr(shstr["offset"] + s["name"])

    def cstr(self, off):
        end = self.data.index(b"\0", off)
        return self.data[off:end].decode("utf-8", "replace")

    def symbols(self):
        """(name, type, shndx, value, size, binding) for every symbol of every symtab."""
        out = []
        for s in self.sections:
            if s["type"] != SHT_SYMTAB:
                continue
            strtab = self.sections[s["link"]]
            n = s["size"] // 24
            for i in range(n):
                off = s["offset"] + i * 24
                name, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", self.data, off)
                out.append((self.cstr(strtab["offset"] + name), info & 0xF, shndx, value, size, info >> 4))
        return out

    def label_bytes(self, sym, n=32):
        """The bytes at a local data label up to the next label, at most n; b'' if it is not one.

        A constant-pool label has size 0 in the symbol table, so its extent is
        the distance to the next label of the section.
        """
        name, typ, shndx, value, size, binding = sym
        if binding != STB_LOCAL or typ not in (STT_NOTYPE, STT_OBJECT):
            return b""
        if shndx == 0 or shndx >= len(self.sections):
            return b""
        sec = self.sections[shndx]
        if sec["flags"] & SHF_EXECINSTR or sec["type"] == SHT_NOBITS:
            return b""
        if not hasattr(self, "_label_ends"):
            self._label_ends = {}
            per_section = {}
            for s in self.symbols():
                if s[5] == STB_LOCAL and s[1] in (STT_NOTYPE, STT_OBJECT) and s[2] != 0:
                    per_section.setdefault(s[2], []).append(s[3])
            for sh, values in per_section.items():
                values = sorted(set(values))
                for i, v in enumerate(values):
                    end = values[i + 1] if i + 1 < len(values) else self.sections[sh]["size"]
                    self._label_ends[(sh, v)] = end
        end = self._label_ends.get((shndx, value), value + n)
        start = sec["offset"] + value
        return self.data[start:start + min(n, max(end - value, 0))]

    def relocations(self):
        """{target section index: [(offset, type, symbol index, addend)]}"""
        out = {}
        for s in self.sections:
            if s["type"] != SHT_RELA:
                continue
            lst = out.setdefault(s["info"], [])
            n = s["size"] // 24
            for i in range(n):
                off = s["offset"] + i * 24
                r_offset, r_info, r_addend = struct.unpack_from("<QQq", self.data, off)
                lst.append((r_offset, r_info & 0xFFFFFFFF, r_info >> 32, r_addend))
        return out


def fingerprints(path):
    """Counter of (canonical name, fingerprint) over the functions of one object."""
    elf = Elf(path)
    syms = elf.symbols()
    relocs = elf.relocations()
    out = Counter()
    for shndx, sec in enumerate(elf.sections):
        if not (sec["flags"] & SHF_EXECINSTR) or sec["size"] == 0:
            continue
        funcs = sorted((v, sz, nm) for (nm, t, sh, v, sz, b) in syms
                       if sh == shndx and t == STT_FUNC and sz > 0)
        if not funcs:
            continue
        starts = [f[0] for f in funcs]
        base = sec["offset"]
        body = [bytearray(elf.data[base + v: base + v + sz]) for (v, sz, nm) in funcs]
        targets = [[] for _ in funcs]
        for (r_off, r_type, r_sym, r_add) in sorted(relocs.get(shndx, [])):
            i = bisect.bisect_right(starts, r_off) - 1
            if i < 0:
                continue
            v, sz, nm = funcs[i]
            if r_off >= v + sz:
                continue
            width = RELOC_WIDTH.get(r_type, 4)
            lo = r_off - v
            body[i][lo:lo + width] = b"\0" * width
            sym = syms[r_sym]
            sname, stype, sshndx = sym[0], sym[1], sym[2]
            if stype == STT_SECTION or sname == "":
                tname = "@" + elf.sections[sshndx]["sname"]
            else:
                tname = canonical(sname)
            lit = elf.label_bytes(sym)
            if lit:
                tname += "=" + lit.hex()
            targets[i].append("%s:%d" % (tname, r_type))
        for i, (v, sz, nm) in enumerate(funcs):
            h = hashlib.sha1(bytes(body[i]) + b"|" + "|".join(targets[i]).encode()).hexdigest()[:16]
            out[(canonical(nm), h)] += 1
    return out


def archive_fingerprints(archive):
    """Extract the archive and fingerprint every text partition."""
    total = Counter()
    with tempfile.TemporaryDirectory(prefix="m0_", dir=os.path.dirname(archive) or None) as d:
        subprocess.run(["ar", "x", os.path.abspath(archive)], cwd=d, check=True)
        members = sorted(m for m in os.listdir(d) if m.startswith("text"))
        for m in members:
            c = fingerprints(os.path.join(d, m))
            print("    %-14s %8d functions" % (m, sum(c.values())), file=sys.stderr)
            total.update(c)
    return total


def compare(a, b, label_a, label_b):
    na, nb = sum(a.values()), sum(b.values())
    same = sum((a & b).values())
    names_a = Counter()
    for (nm, h), k in a.items():
        names_a[nm] += k
    names_b = Counter()
    for (nm, h), k in b.items():
        names_b[nm] += k
    only_b = b - a                      # in B, no identical twin in A
    name_known = sum(k for (nm, h), k in only_b.items() if names_a[nm] > 0)
    name_new = sum(only_b.values()) - name_known
    print("=== %s vs %s" % (label_a, label_b))
    print("    functions in %-3s        %9d" % (label_a, na))
    print("    functions in %-3s        %9d" % (label_b, nb))
    print("    identical (name+code)   %9d   = %.2f%% of %s" % (same, 100.0 * same / max(nb, 1), label_b))
    print("    changed (name known)    %9d   = %.2f%%" % (name_known, 100.0 * name_known / max(nb, 1)))
    print("    new (name unknown)      %9d   = %.2f%%" % (name_new, 100.0 * name_new / max(nb, 1)))
    return only_b, names_a


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    pa, pb = sys.argv[1], sys.argv[2]
    la, lb = (os.path.basename(p).rsplit(".", 1)[0] for p in (pa, pb))
    print("reading %s" % pa, file=sys.stderr)
    a = archive_fingerprints(pa)
    print("reading %s" % pb, file=sys.stderr)
    b = archive_fingerprints(pb)
    only_b, names_a = compare(a, b, la, lb)
    if "--list" in sys.argv:
        print("--- functions of %s without an identical twin in %s (name: count)" % (lb, la))
        byname = Counter()
        for (nm, h), k in only_b.items():
            byname[nm] += k
        for nm, k in byname.most_common(int(os.environ.get("M0_LIST", "60"))):
            print("    %6d  %s" % (k, nm))


if __name__ == "__main__":
    main()
