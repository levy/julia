#!/usr/bin/env python3
# overlay_check: read-only check of a Julia system image overlay composed over its base image.
# It reports the tables of the composed image that are wrong: root_blocks arrays of base
# methods that grew inside their memory and hold the stale base bytes, hashed specializations
# missing from a method's speckeyset, and bindings missing from a module's bindingkeyset.
# Usage: python3 -I overlay_check.py BASE OVERLAY [--verbose] [--base-blob OFF,SIZE] [--overlay-blob OFF,SIZE]
#   BASE is the base image in its file form: lib/julia/sys.so of a bundle, or reactive-store/founding.so.
#   A prelinked program holds the same image with final addresses, and the check does not read that
#   form. OVERLAY is the overlay shared object. The blob of each file is found through the symbols
#   jl_system_image_data and jl_system_image_size; the two --*-blob options override that.
# Exit codes: 0 when no table entry is wrong, 1 when some entry is wrong, 2 for a usage or parse error.
import mmap, struct, sys
from collections import Counter
import numpy as np

TAG = 61
MASK = (1 << TAG) - 1
PAGE = 4096
LIMIT = 20


class CheckError(Exception):
    pass


def align(x, a):
    return (x + a - 1) & ~(a - 1)


def find_blob(m):
    """Return (file offset, size) of the system image data blob of the ELF file mapped in m."""
    if len(m) < 64 or m[:4] != b'\x7fELF' or m[4] != 2 or m[5] != 1:
        raise CheckError('not a 64-bit little-endian ELF file')
    phoff, shoff = struct.unpack_from('<QQ', m, 32)
    phentsize, phnum, shentsize, shnum = struct.unpack_from('<HHHH', m, 54)
    loads = []
    for i in range(phnum):
        p_type, _, p_off, p_vaddr, _, p_filesz, _, _ = struct.unpack_from('<IIQQQQQQ', m, phoff + i * phentsize)
        if p_type == 1:
            loads.append((p_vaddr, p_off, p_filesz))
    sections = [struct.unpack_from('<IIQQQQIIQQ', m, shoff + i * shentsize) for i in range(shnum)]
    found = {}
    for sh in sections:
        if sh[1] not in (2, 11):          # SHT_SYMTAB, SHT_DYNSYM
            continue
        strtab = sections[sh[6]]
        for k in range(sh[5] // 24):
            st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from('<IBBHQQ', m, sh[4] + k * 24)
            if st_shndx == 0 or not st_name:
                continue
            start = strtab[4] + st_name
            name = bytes(m[start:m.find(b'\0', start)])
            if name in (b'jl_system_image_data', b'jl_system_image_size') and name not in found:
                found[name] = (st_value, st_size)
    if b'jl_system_image_data' not in found:
        raise CheckError('symbol jl_system_image_data not found')
    addr, size = found[b'jl_system_image_data']
    for vaddr, off, filesz in loads:
        if vaddr <= addr < vaddr + filesz:
            return off + (addr - vaddr), size
    raise CheckError('jl_system_image_data lies in no loaded segment')


class Composed:
    """The base blob with the overlay composed over it, read through read-only mappings."""

    def __init__(self, ms, sys_off, mo, ov_off):
        u64 = lambda m, p: struct.unpack_from('<Q', m, p)[0]
        self.ms, self.sys_off = ms, sys_off
        sys_end = u64(ms, sys_off) + 8
        const_size = u64(ms, sys_off + sys_end)
        const_start = align(sys_end + 8, 64)
        pos = const_start + const_size
        ssize = u64(ms, sys_off + pos); pos += 8; pos = align(pos, 8) + ssize
        rsize = u64(ms, sys_off + pos); pos += 8; pos = align(pos, 8); relocs_off = pos; pos += rsize
        gsize = u64(ms, sys_off + pos); pos += 8; pos = align(pos, 8) + gsize
        fsize = u64(ms, sys_off + pos); pos += 8; pos = align(pos, 8) + fsize
        roots_off = align(pos, 8)
        self.sys_end, self.const_size, self.const_start = sys_end, const_size, const_start
        self.const_limit = align(const_start + const_size, PAGE) + (64 << 20)

        names = ['magic', 'base_sysimg_size', 'base_const_size', 'base_syms_size', 'page_size', 'npatch_sysimg', 'npatch_const',
                 'new_sysimg_size', 'new_const_size', 'new_syms_size', 'relocs_size', 'gvar_size', 'fptr_size', 'roots_size',
                 'off_patch_idx_sysimg', 'off_patch_sysimg', 'off_patch_idx_const', 'off_patch_const', 'off_new_sysimg',
                 'off_new_const', 'off_new_syms', 'off_relocs', 'off_gvar', 'off_fptr', 'off_roots']
        h = dict(zip(names, struct.unpack_from('<25Q', mo, ov_off)))

        self.base_words = np.frombuffer(ms, dtype='<u8', count=sys_end // 8, offset=sys_off)
        # the composed sysimg: the base words with the runs of the overlay over them
        self.comp = comp = np.array(self.base_words)   # a private copy
        n = h['npatch_sysimg']
        rec = np.frombuffer(mo, dtype='<u8', count=2 * n, offset=ov_off + h['off_patch_idx_sysimg']).reshape(n, 2)
        offs = rec[:, 0].astype(np.int64); sizes = rec[:, 1].astype(np.int64)
        total = int(sizes.sum())
        cum = np.concatenate(([0], np.cumsum(sizes)))[:-1]
        ok = (sizes % 8 == 0) & (offs % 8 == 0) & ((offs + sizes) <= sys_end)
        self.runs_left_out = int((~ok).sum())
        idx = np.nonzero(ok)[0]
        counts = sizes[idx] // 8
        starts = np.concatenate(([0], np.cumsum(counts)))[:-1]
        inner = np.arange(int(counts.sum()), dtype=np.int64) - np.repeat(starts, counts)
        w_pos = np.repeat(offs[idx], counts) + inner * 8
        w_src = np.repeat(cum[idx], counts) + inner * 8
        patch_bytes = np.frombuffer(mo, dtype=np.uint8, count=total, offset=ov_off + h['off_patch_sysimg'])
        nw = np.zeros(len(w_src), dtype='<u8')
        for k in range(8):
            nw |= patch_bytes[w_src + k].astype('<u8') << np.uint64(8 * k)
        comp[w_pos // 8] = nw
        self.new_words = np.frombuffer(mo, dtype='<u8', count=h['new_sysimg_size'] // 8, offset=ov_off + h['off_new_sysimg'])

        # the composed const data: the base const, the patched const pages, the new const data
        cidx = np.frombuffer(mo, dtype='<u4', count=h['npatch_const'], offset=ov_off + h['off_patch_idx_const']).astype(np.int64)
        self.cpage = {int(c): i for i, c in enumerate(cidx)}
        self.base_const = np.frombuffer(ms, dtype=np.uint8, count=const_size, offset=sys_off + const_start)
        self.new_const = np.frombuffer(mo, dtype=np.uint8, count=h['new_const_size'], offset=ov_off + h['off_new_const'])
        self.ov_const_pages = np.frombuffer(mo, dtype=np.uint8, count=h['npatch_const'] * PAGE, offset=ov_off + h['off_patch_const'])

        # the roots: find the datatypes by name
        roots = np.frombuffer(ms, dtype='<u8', count=230, offset=sys_off + roots_off)
        found = {}
        for j, r in enumerate(roots):
            r = int(r)
            if r == 0 or (r >> TAG) != 0 or r >= sys_end or r % 8:
                continue
            try:
                nm = self.type_name(r)
            except Exception:
                continue
            if nm in ('Method', 'Module', 'SimpleVector') and nm not in found:
                found[nm] = (j, r)
        if len(found) != 3:
            raise CheckError('the types Method, Module and SimpleVector are not among the roots of the base; '
                             'a prelinked program holds the image with final addresses: give lib/julia/sys.so')
        base_index = found['Method'][0] - 84          # the first exported data pointer
        mem8 = int(roots[base_index + 73]); mem16 = int(roots[base_index + 74]); mem32 = int(roots[base_index + 75])
        method_type = found['Method'][1]; module_type = found['Module'][1]; self.svec_type = found['SimpleVector'][1]
        self.elsz = {mem8: 1, mem16: 2, mem32: 4}

        # the gc tags of the base: the positions of the headers
        rb = np.frombuffer(ms, dtype=np.uint8, count=rsize, offset=sys_off + relocs_off)
        tags = []
        last = 0
        i = 0
        while True:
            diff = 0; cnt = 0
            while True:
                c = int(rb[i]); i += 1
                diff |= (c & 0x7F) << (7 * cnt); cnt += 1
                if not (c & 0x80):
                    break
            if diff == 0:
                break
            last += diff
            tags.append(last)
        tags = np.array(tags, dtype=np.int64)
        hdr = self.base_words[tags // 8]
        self.methods = tags[hdr == np.uint64(method_type)] + 8
        self.modules = tags[hdr == np.uint64(module_type)] + 8

    def cbytes(self, off, nbytes, composed):
        out = np.empty(nbytes, dtype=np.uint8)
        done = 0
        while done < nbytes:
            o = off + done
            if o >= self.const_size:
                if not composed:
                    return None
                take = nbytes - done
                out[done:] = self.new_const[o - self.const_size:o - self.const_size + take]
                done += take
                continue
            pg = o // PAGE
            take = min(nbytes - done, (pg + 1) * PAGE - o, self.const_size - o)
            if composed and pg in self.cpage:
                s = self.cpage[pg] * PAGE + (o - pg * PAGE)
                out[done:done + take] = self.ov_const_pages[s:s + take]
            else:
                out[done:done + take] = self.base_const[o:o + take]
            done += take
        return out

    def W(self, off, composed):
        if off < self.sys_end:
            return int(self.comp[off // 8]) if composed else int(self.base_words[off // 8])
        if off >= self.const_limit and composed:
            k = (off - self.const_limit) // 8
            if k < len(self.new_words):
                return int(self.new_words[k])
        return None

    def cstr(self, off):
        end = self.ms.find(b'\0', self.sys_off + off, self.sys_off + off + 256)
        return self.ms[self.sys_off + off:end].decode('utf-8', 'replace')

    def type_name(self, d):
        t = int(self.base_words[d // 8]) & MASK       # DataType.name
        s = int(self.base_words[t // 8]) & MASK       # TypeName.name
        return self.cstr(s + 24)

    def keyset_values(self, k, composed):
        hw = self.W(k - 8, composed)
        if hw is None or hw not in self.elsz:
            return None, 0
        length = self.W(k, composed)
        ptr = self.W(k + 8, composed)
        if length is None or ptr is None:
            return None, 0
        t = ptr >> TAG
        if t == 1:
            coff = (ptr & MASK) * 8
        elif t == 0 and self.const_start <= (ptr & MASK) < self.const_start + self.const_size + (64 << 20):
            coff = (ptr & MASK) - self.const_start
        else:
            return None, 0
        if length == 0:
            return set(), 0
        b = self.cbytes(coff, length * self.elsz[hw], composed)
        if b is None:
            return None, 0
        dt = {1: np.uint8, 2: '<u2', 4: '<u4'}[self.elsz[hw]]
        v = np.frombuffer(b.tobytes(), dtype=dt)
        tomb = {1: 0xFF, 2: 0xFFFF, 4: 0xFFFFFFFF}[self.elsz[hw]]
        v = v[(v != 0) & (v != tomb)]
        return set(int(x) for x in v), coff

    def svec_elems(self, s, composed):
        hw = self.W(s - 8, composed)
        if hw != self.svec_type:
            return None
        ln = self.W(s, composed)
        if ln is None or ln > 10_000_000:
            return None
        if s < self.sys_end:
            arr = self.comp if composed else self.base_words
            return arr[(s + 8) // 8:(s + 8) // 8 + ln]
        k = (s + 8 - self.const_limit) // 8
        return self.new_words[k:k + ln]

    def find_nothing(self):
        cnt = Counter()
        for m in self.methods[:2000]:
            sp = self.W(int(m) + 56, False)
            if sp and (sp >> TAG) == 0:
                e = self.svec_elems(sp & MASK, False)
                if e is not None:
                    cnt.update(int(x) for x in e)
        nothing = cnt.most_common(1)[0][0]
        nothing_alt = self.const_start + (nothing & MASK) * 8 if (nothing >> TAG) == 1 else nothing
        return (nothing, nothing_alt)


def check_root_blocks(c):
    W = c.W
    grown = 0; lost = 0; carried = 0; replaced = 0; newarr = 0
    examples = []
    for m in c.methods:
        m = int(m)
        rb0 = W(m + 128, False); rb1 = W(m + 128, True)
        if not rb1:
            continue
        if not rb0 or rb0 != rb1:
            newarr += 1 if rb1 and rb1 != rb0 else 0
            continue
        a = rb1 & MASK
        if a >= c.sys_end:
            continue
        len0 = W(a + 16, False); len1 = W(a + 16, True)
        mem0 = W(a + 8, False); mem1 = W(a + 8, True)
        if len1 <= len0:
            continue
        if mem0 != mem1 and not ((mem1 >> TAG) == 0 and (mem1 & MASK) < c.sys_end and mem0 == mem1):
            replaced += 1
            continue
        grown += 1
        mm = mem1 & MASK
        ptr = W(mm + 8, True)
        if (ptr >> TAG) != 1:
            continue
        coff = (ptr & MASK) * 8
        off = W(a, True)          # the offset of the reference, file form
        if off is None or off > (1 << 32):
            off = W(a, False)
        start = coff + off + 8 * len0
        nb = 8 * (len1 - len0)
        new = c.cbytes(start, nb, True); old = c.cbytes(start, nb, False)
        vals_new = np.frombuffer(new.tobytes(), dtype='<u8'); vals_old = np.frombuffer(old.tobytes(), dtype='<u8')
        nroots0 = None
        r0 = W(m + 120, False)
        if r0 and (r0 >> TAG) == 0 and (r0 & MASK) < c.sys_end:
            nroots0 = W((r0 & MASK) + 16, False)
        same = bool((new == old).all())
        if same:
            lost += 1
        else:
            carried += 1
        examples.append((m, len0, len1, [int(x) for x in vals_new], [int(x) for x in vals_old], nroots0, (c.const_start + start) % PAGE, same))
    return grown, lost, carried, replaced, newarr, examples


def count_hashed(e, nothings):
    for i, x in enumerate(e):
        x = int(x)
        if x in nothings or x == 0:
            return
        yield i, x


def check_methods(c, nothings):
    W = c.W
    nchecked = 0; nentries = 0; missing = 0; bad_methods = 0; skipped = 0
    examples = []
    for m in c.methods:
        m = int(m)
        sp = W(m + 56, True); ks = W(m + 64, True)
        if not sp or not ks or (sp >> TAG) != 0 or (ks >> TAG) != 0:
            continue
        e = c.svec_elems(sp & MASK, True)
        if e is None:
            continue
        vals, coff = c.keyset_values(ks & MASK, True)
        if vals is None:
            skipped += 1
            continue
        nchecked += 1
        miss_here = 0
        for i, x in count_hashed(e, nothings):
            nentries += 1
            if (i + 1) not in vals:
                miss_here += 1
                examples.append((m, i, x, len(e), len(vals), coff))
        if miss_here:
            bad_methods += 1
            missing += miss_here
    return nchecked, nentries, missing, bad_methods, skipped, examples


def check_modules(c, nothings):
    W = c.W
    nchecked = 0; nentries = 0; missing = 0; bad = 0; skipped = 0
    examples = []
    for m in c.modules:
        m = int(m)
        bd = W(m + 16, True); ks = W(m + 24, True)
        if not bd or not ks or (bd >> TAG) != 0 or (ks >> TAG) != 0:
            continue
        e = c.svec_elems(bd & MASK, True)
        if e is None:
            continue
        vals, coff = c.keyset_values(ks & MASK, True)
        if vals is None:
            skipped += 1
            continue
        nchecked += 1
        miss_here = 0
        for i, x in count_hashed(e, nothings):
            nentries += 1
            if (i + 1) not in vals:
                miss_here += 1
                nm = W(m, False)
                examples.append((c.cstr((nm & MASK) + 24) if nm else '?', i, len(e), len(vals), coff))
        if miss_here:
            bad += 1
            missing += miss_here
    return nchecked, nentries, missing, bad, skipped, examples


def parse_blob_option(text):
    try:
        off, size = text.split(',')
        return int(off, 0), int(size, 0)
    except ValueError:
        raise CheckError('a blob option is OFF,SIZE: %r' % text)


def run(argv):
    args = list(argv); verbose = False; blobs = {}; paths = []
    while args:
        a = args.pop(0)
        if a == '--verbose':
            verbose = True
        elif a in ('--base-blob', '--overlay-blob'):
            if not args:
                raise CheckError('%s needs OFF,SIZE' % a)
            blobs[a] = parse_blob_option(args.pop(0))
        elif a.startswith('-'):
            raise CheckError('unknown option %s' % a)
        else:
            paths.append(a)
    if len(paths) != 2:
        raise CheckError('usage: overlay_check.py BASE OVERLAY [--verbose] [--base-blob OFF,SIZE] [--overlay-blob OFF,SIZE]')
    maps = []
    for p in paths:
        try:
            f = open(p, 'rb')
            maps.append(mmap.mmap(f.fileno(), 0, prot=mmap.PROT_READ))
        except (OSError, ValueError) as ex:
            raise CheckError('cannot map %s: %s' % (p, ex))
    ms, mo = maps
    try:
        sys_off = blobs['--base-blob'][0] if '--base-blob' in blobs else find_blob(ms)[0]
        ov_off = blobs['--overlay-blob'][0] if '--overlay-blob' in blobs else find_blob(mo)[0]
        c = Composed(ms, sys_off, mo, ov_off)
    except (struct.error, IndexError, ValueError, KeyError) as ex:
        raise CheckError('cannot parse the images: %s' % ex)

    grown, lost, carried, replaced, newarr, rexamples = check_root_blocks(c)
    nothings = c.find_nothing()
    mres = check_methods(c, nothings)
    bres = check_modules(c, nothings)
    wrong = lost + mres[2] + bres[2]

    print('const data: starts %d bytes into a page' % (c.const_start % PAGE))
    print('root tables: %d grew inside their memory, %d of them hold stale bytes' % (grown, lost))
    print('specializations: %d missing from the key set of %d methods' % (mres[2], mres[3]))
    print('bindings: %d missing from the key set of %d modules' % (bres[2], bres[3]))
    if verbose:
        print('detail: %d overlay runs not word aligned or past the base' % c.runs_left_out)
        print('detail: root tables: %d replaced their memory, %d are new arrays, %d carried new elements' % (replaced, newarr, carried))
        print('detail: methods checked %d, specializations %d, key sets not read %d' % (mres[0], mres[1], mres[4]))
        print('detail: modules checked %d, bindings %d, key sets not read %d' % (bres[0], bres[1], bres[4]))
        for ex in [e for e in rexamples if e[7]][:LIMIT]:
            print('  root table of method at %d: length %d -> %d, new elements %s, base bytes there %s, roots of the base %s, %d bytes into the real page, stale %s' % ex)
        for m, i, x, ln, nv, coff in mres[5][:LIMIT]:
            print('  method at %d: specialization %d (word %#x) of %d, key set of %d values at const offset %d (%d bytes into its real page)' % (m, i, x, ln, nv, coff, (c.const_start + coff) % PAGE))
        for ex in bres[5][:LIMIT]:
            print('  module %s: binding %d of %d, key set of %d values at const offset %d' % ex)
    if wrong:
        print('overlay_check: FAILED (%d + %d + %d wrong entries)' % (lost, mres[2], bres[2]))
        return 1
    print('overlay_check: ok')
    return 0


def main():
    try:
        sys.exit(run(sys.argv[1:]))
    except CheckError as ex:
        print('overlay_check: %s' % ex, file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
