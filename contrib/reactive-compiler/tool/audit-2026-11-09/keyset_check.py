#!/usr/bin/env python3
# Read-only check: after the overlay is applied over the founding image, does every hashed
# specialization of a base Method appear in the method's speckeyset, and every binding of a
# base Module in its bindingkeyset? Both key sets are bits memories in the const data.
import mmap, struct, sys
import numpy as np

def align(x, a):
    return (x + a - 1) & ~(a - 1)

TAG = 61
MASK = (1 << TAG) - 1

def main():
    sys_path, sys_off, sys_size, ov_path, ov_off, ov_size = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0), sys.argv[4], int(sys.argv[5], 0), int(sys.argv[6], 0)
    fs = open(sys_path, 'rb'); ms = mmap.mmap(fs.fileno(), 0, prot=mmap.PROT_READ)
    fo = open(ov_path, 'rb'); mo = mmap.mmap(fo.fileno(), 0, prot=mmap.PROT_READ)
    page = 4096
    u64 = lambda m, p: struct.unpack_from('<Q', m, p)[0]
    sysdata = u64(ms, sys_off)
    sys_end = sysdata + 8
    const_size = u64(ms, sys_off + sys_end)
    const_start = align(sys_end + 8, 64)
    pos = const_start + const_size
    ssize = u64(ms, sys_off + pos); pos += 8; pos = align(pos, 8) + ssize
    rsize = u64(ms, sys_off + pos); pos += 8; pos = align(pos, 8); relocs_off = pos; pos += rsize
    gsize = u64(ms, sys_off + pos); pos += 8; pos = align(pos, 8) + gsize
    fsize = u64(ms, sys_off + pos); pos += 8; pos = align(pos, 8) + fsize
    roots_off = align(pos, 8)
    mapped = align(const_start + const_size, page)
    const_limit = mapped + (64 << 20)

    names = ['magic', 'base_sysimg_size', 'base_const_size', 'base_syms_size', 'page_size', 'npatch_sysimg', 'npatch_const',
             'new_sysimg_size', 'new_const_size', 'new_syms_size', 'relocs_size', 'gvar_size', 'fptr_size', 'roots_size',
             'off_patch_idx_sysimg', 'off_patch_sysimg', 'off_patch_idx_const', 'off_patch_const', 'off_new_sysimg',
             'off_new_const', 'off_new_syms', 'off_relocs', 'off_gvar', 'off_fptr', 'off_roots']
    h = dict(zip(names, struct.unpack_from('<25Q', mo, ov_off)))

    base_words = np.frombuffer(ms, dtype='<u8', count=sys_end // 8, offset=sys_off)
    # the composed sysimg: the base words with the runs of the overlay over them
    comp = np.array(base_words)   # a private copy
    n = h['npatch_sysimg']
    rec = np.frombuffer(mo, dtype='<u8', count=2 * n, offset=ov_off + h['off_patch_idx_sysimg']).reshape(n, 2)
    offs = rec[:, 0].astype(np.int64); sizes = rec[:, 1].astype(np.int64)
    total = int(sizes.sum())
    cum = np.concatenate(([0], np.cumsum(sizes)))[:-1]
    ok = (sizes % 8 == 0) & (offs % 8 == 0) & ((offs + sizes) <= sys_end)
    print('runs not word aligned or past the base (left out of the composed words): %d' % int((~ok).sum()))
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
    new_words = np.frombuffer(mo, dtype='<u8', count=h['new_sysimg_size'] // 8, offset=ov_off + h['off_new_sysimg'])

    # the composed const data: the base const, the patched const pages, the new const data
    cidx = np.frombuffer(mo, dtype='<u4', count=h['npatch_const'], offset=ov_off + h['off_patch_idx_const']).astype(np.int64)
    cpage = {int(c): i for i, c in enumerate(cidx)}
    base_const = np.frombuffer(ms, dtype=np.uint8, count=const_size, offset=sys_off + const_start)
    new_const = np.frombuffer(mo, dtype=np.uint8, count=h['new_const_size'], offset=ov_off + h['off_new_const'])
    ov_const_pages = np.frombuffer(mo, dtype=np.uint8, count=h['npatch_const'] * page, offset=ov_off + h['off_patch_const'])

    def cbytes(off, nbytes, composed):
        out = np.empty(nbytes, dtype=np.uint8)
        done = 0
        while done < nbytes:
            o = off + done
            if o >= const_size:
                if not composed:
                    return None
                take = nbytes - done
                out[done:] = new_const[o - const_size:o - const_size + take]
                done += take
                continue
            pg = o // page
            take = min(nbytes - done, (pg + 1) * page - o, const_size - o)
            if composed and pg in cpage:
                s = cpage[pg] * page + (o - pg * page)
                out[done:done + take] = ov_const_pages[s:s + take]
            else:
                out[done:done + take] = base_const[o:o + take]
            done += take
        return out

    def W(off, composed):
        if off < sys_end:
            return int(comp[off // 8]) if composed else int(base_words[off // 8])
        if off >= const_limit and composed:
            k = (off - const_limit) // 8
            if k < len(new_words):
                return int(new_words[k])
        return None

    def cstr(off):
        end = ms.find(b'\0', sys_off + off, sys_off + off + 256)
        return ms[sys_off + off:end].decode('utf-8', 'replace')

    def type_name(d):
        t = int(base_words[d // 8]) & MASK       # DataType.name
        s = int(base_words[t // 8]) & MASK       # TypeName.name
        return cstr(s + 24)

    # the roots: find the datatypes by name
    roots = np.frombuffer(ms, dtype='<u8', count=230, offset=sys_off + roots_off)
    found = {}
    for j, r in enumerate(roots):
        r = int(r)
        if r == 0 or (r >> TAG) != 0 or r >= sys_end or r % 8:
            continue
        try:
            nm = type_name(r)
        except Exception:
            continue
        if nm in ('Method', 'Module', 'SimpleVector') and nm not in found:
            found[nm] = (j, r)
    print('roots found:', found)
    jm = found['Method'][0]
    base_index = jm - 84          # the first exported data pointer
    mem8 = int(roots[base_index + 73]); mem16 = int(roots[base_index + 74]); mem32 = int(roots[base_index + 75])
    method_type = found['Method'][1]; module_type = found['Module'][1]; svec_type = found['SimpleVector'][1]
    print('memory types (roots): %d %d %d names %s %s %s' % (mem8, mem16, mem32, type_name(mem8), type_name(mem16), type_name(mem32)))
    elsz = {mem8: 1, mem16: 2, mem32: 4}

    # the gc tags of the base: the positions of the headers
    rb = np.frombuffer(ms, dtype=np.uint8, count=rsize, offset=sys_off + relocs_off)
    # decode the first list
    tags = []
    last = 0
    i = 0
    cont = (rb & 0x80) != 0
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
    print('objects of the base (gc tags): %d' % len(tags))
    hdr = base_words[tags // 8]
    methods = tags[hdr == np.uint64(method_type)] + 8
    modules = tags[hdr == np.uint64(module_type)] + 8
    print('Method objects: %d ; Module objects: %d' % (len(methods), len(modules)))

    # nothing: the most common element of the specializations
    def keyset_values(k, composed):
        hw = W(k - 8, composed)
        if hw is None or hw not in elsz:
            return None, 0
        length = W(k, composed)
        ptr = W(k + 8, composed)
        if length is None or ptr is None:
            return None, 0
        t = ptr >> TAG
        if t == 1:
            coff = (ptr & MASK) * 8
        elif t == 0 and const_start <= (ptr & MASK) < const_start + const_size + (64 << 20):
            coff = (ptr & MASK) - const_start
        else:
            return None, 0
        if length == 0:
            return set(), 0
        b = cbytes(coff, length * elsz[hw], composed)
        if b is None:
            return None, 0
        dt = {1: np.uint8, 2: '<u2', 4: '<u4'}[elsz[hw]]
        v = np.frombuffer(b.tobytes(), dtype=dt)
        tomb = {1: 0xFF, 2: 0xFFFF, 4: 0xFFFFFFFF}[elsz[hw]]
        v = v[(v != 0) & (v != tomb)]
        return set(int(x) for x in v), coff

    def svec_elems(s, composed):
        hw = W(s - 8, composed)
        if hw != svec_type:
            return None
        ln = W(s, composed)
        if ln is None or ln > 10_000_000:
            return None
        if s < sys_end:
            arr = comp if composed else base_words
            return arr[(s + 8) // 8:(s + 8) // 8 + ln]
        k = (s + 8 - const_limit) // 8
        return new_words[k:k + ln]

    # find `nothing`
    from collections import Counter
    cnt = Counter()
    for m in methods[:2000]:
        sp = W(int(m) + 56, False)
        if sp and (sp >> TAG) == 0:
            e = svec_elems(sp & MASK, False)
            if e is not None:
                cnt.update(int(x) for x in e)
    nothing = cnt.most_common(1)[0][0]
    print('nothing: word %#x (tag %d)' % (nothing, nothing >> TAG))
    nothing_alt = const_start + (nothing & MASK) * 8 if (nothing >> TAG) == 1 else nothing
    nothings = (nothing, nothing_alt)

    def check_methods(composed):
        nchecked = 0; nentries = 0; missing = 0; bad_methods = 0; skipped = 0
        examples = []
        where = []
        for m in methods:
            m = int(m)
            sp = W(m + 56, composed); ks = W(m + 64, composed)
            if not sp or not ks or (sp >> TAG) != 0 or (ks >> TAG) != 0:
                continue
            e = svec_elems(sp & MASK, composed)
            if e is None:
                continue
            vals, coff = keyset_values(ks & MASK, composed)
            if vals is None:
                skipped += 1
                continue
            nchecked += 1
            miss_here = 0
            for i, x in enumerate(e):
                x = int(x)
                if x in nothings or x == 0:
                    break
                nentries += 1
                if (i + 1) not in vals:
                    miss_here += 1
                    if len(examples) < 5:
                        examples.append((m, i, x, len(e), len(vals), (ks & MASK), coff))
            if miss_here:
                bad_methods += 1
                missing += miss_here
                where.append(coff)
        return nchecked, nentries, missing, bad_methods, skipped, examples, where

    def check_modules(composed):
        nchecked = 0; nentries = 0; missing = 0; bad = 0; skipped = 0
        examples = []
        for m in modules:
            m = int(m)
            bd = W(m + 16, composed); ks = W(m + 24, composed)
            if not bd or not ks or (bd >> TAG) != 0 or (ks >> TAG) != 0:
                continue
            e = svec_elems(bd & MASK, composed)
            if e is None:
                continue
            vals, coff = keyset_values(ks & MASK, composed)
            if vals is None:
                skipped += 1
                continue
            nchecked += 1
            miss_here = 0
            for i, x in enumerate(e):
                x = int(x)
                if x in nothings or x == 0:
                    break
                nentries += 1
                if (i + 1) not in vals:
                    miss_here += 1
                    if len(examples) < 5:
                        nm = W(m, False)
                        examples.append((cstr((nm & MASK) + 24) if nm else '?', i, len(e), len(vals), coff))
            if miss_here:
                bad += 1
                missing += miss_here
        return nchecked, nentries, missing, bad, skipped, examples

    print('base methods that gained hashed specializations and kept their key set memory, by the place of the key set:')
    mechanism(methods, W, svec_elems, keyset_values, nothings, const_start, const_size, cpage, elsz)
    for composed in (True,):
        label = 'founding image with the overlay applied' if composed else 'founding image alone'
        r = check_methods(composed)
        print('%s: methods checked %d, hashed specializations %d, missing from the key set %d (in %d methods), key sets not read %d' % (label, r[0], r[1], r[2], r[3], r[4]))
        for ex in r[5]:
            m, i, x, ln, nv, ks, coff = ex
            real_page_off = (const_start + coff) % page
            print('   method at %d: specialization %d (word %#x) of %d, key set of %d values at const offset %d (%d bytes into its real page)' % (m, i, x, ln, nv, coff, real_page_off))
        if composed and r[6]:
            w = np.array(r[6])
            print('   key sets with a missing entry: %d' % len(w))
        r = check_modules(composed)
        print('%s: modules checked %d, bindings %d, missing from the key set %d (in %d modules), key sets not read %d' % (label, r[0], r[1], r[2], r[3], r[4]))
        for ex in r[5]:
            print('   module %s: binding %d of %d, key set of %d values at const offset %d' % ex)

def mechanism(methods, W, svec_elems, keyset_values, nothings, const_start, const_size, cpage, elsz_of, page=4096):
    # For the base methods that gained hashed specializations and kept their key set memory:
    # where does the key set lie in its real page, and did the overlay carry its change?
    d = const_start % page
    stats = {}
    for m in methods:
        m = int(m)
        sp0 = W(m + 56, False); ks0 = W(m + 64, False)
        sp1 = W(m + 56, True); ks1 = W(m + 64, True)
        if not sp0 or not ks0 or not sp1 or not ks1:
            continue
        if (ks0 & MASK) != (ks1 & MASK) and not ((ks1 >> TAG) == 0 and (ks0 >> TAG) == 0 and ks0 == ks1):
            continue
        if ks0 != ks1:
            continue                      # the key set memory was replaced
        e0 = svec_elems(sp0 & MASK, False); e1 = svec_elems(sp1 & MASK, True)
        if e0 is None or e1 is None:
            continue
        def nh(e):
            c = 0
            for x in e:
                x = int(x)
                if x in nothings or x == 0:
                    break
                c += 1
            return c
        n0 = nh(e0); n1 = nh(e1)
        if n1 <= n0:
            continue
        v1, coff = keyset_values(ks1 & MASK, True)
        if v1 is None:
            continue
        hw = W((ks1 & MASK) - 8, True)
        nbytes = W(ks1 & MASK, True) * elsz_of[hw]
        lo = (const_start + coff) % page
        first_real = (const_start + coff) // page
        last_real = (const_start + coff + nbytes - 1) // page
        missing = sum(1 for i in range(n0, n1) if (i + 1) not in v1)
        if first_real == last_real:
            cls = 'one real page, in the part the writer tracks right (offset >= %d)' % d if lo >= d else 'one real page, in the part tracked by the next bit (offset < %d)' % d
        else:
            cls = 'spans %s real pages' % ('2' if last_real == first_real + 1 else '3 or more')
        st = stats.setdefault(cls, [0, 0, 0, 0])
        st[0] += 1; st[1] += (n1 - n0); st[2] += missing; st[3] += 1 if missing else 0
    for cls, st in sorted(stats.items()):
        print('  %-72s: %5d methods, %6d new hashed specializations, %5d missing from the key set (%d methods)' % (cls, st[0], st[1], st[2], st[3]))

if __name__ == '__main__':
    main()
