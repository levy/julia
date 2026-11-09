#!/usr/bin/env python3
# Read-only inspection, second pass: pages, runs of pages, const page byte positions, residual counts.
import mmap, struct, sys
import numpy as np

def align(x, a):
    return (x + a - 1) & ~(a - 1)

def main():
    sys_path, sys_off, sys_size, ov_path, ov_off, ov_size = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0), sys.argv[4], int(sys.argv[5], 0), int(sys.argv[6], 0)
    fs = open(sys_path, 'rb'); ms = mmap.mmap(fs.fileno(), 0, prot=mmap.PROT_READ)
    fo = open(ov_path, 'rb'); mo = mmap.mmap(fo.fileno(), 0, prot=mmap.PROT_READ)
    page = 4096
    MB = 1 << 20
    sysdata = struct.unpack_from('<Q', ms, sys_off)[0]
    sys_end = sysdata + 8
    csize = struct.unpack_from('<Q', ms, sys_off + sys_end)[0]
    const_start = align(sys_end + 8, 64)
    const_size = csize
    mapped = align(const_start + const_size, page)
    const_limit = mapped + (64 << 20)
    vals = struct.unpack_from('<25Q', mo, ov_off)
    names = ['magic', 'base_sysimg_size', 'base_const_size', 'base_syms_size', 'page_size', 'npatch_sysimg', 'npatch_const',
             'new_sysimg_size', 'new_const_size', 'new_syms_size', 'relocs_size', 'gvar_size', 'fptr_size', 'roots_size',
             'off_patch_idx_sysimg', 'off_patch_sysimg', 'off_patch_idx_const', 'off_patch_const', 'off_new_sysimg',
             'off_new_const', 'off_new_syms', 'off_relocs', 'off_gvar', 'off_fptr', 'off_roots']
    h = dict(zip(names, vals))
    n = h['npatch_sysimg']
    rec = np.frombuffer(mo, dtype='<u8', count=2 * n, offset=ov_off + h['off_patch_idx_sysimg']).reshape(n, 2)
    offs = rec[:, 0].astype(np.int64); sizes = rec[:, 1].astype(np.int64)
    total = int(sizes.sum())
    cum = np.concatenate(([0], np.cumsum(sizes)))[:-1]
    ok = (sizes % 8 == 0) & (offs % 8 == 0) & ((offs + sizes) <= sys_end)
    idx = np.nonzero(ok)[0]
    counts = sizes[idx] // 8
    starts = np.concatenate(([0], np.cumsum(counts)))[:-1]
    inner = np.arange(int(counts.sum()), dtype=np.int64) - np.repeat(starts, counts)
    w_run = np.repeat(idx, counts)
    w_pos = np.repeat(offs[idx], counts) + inner * 8
    w_src = np.repeat(cum[idx], counts) + inner * 8
    base_words = np.frombuffer(ms, dtype='<u8', count=(sys_end // 8), offset=sys_off)
    bw = base_words[w_pos // 8]
    patch_bytes = np.frombuffer(mo, dtype=np.uint8, count=total, offset=ov_off + h['off_patch_sysimg'])
    nw = np.zeros(len(w_src), dtype='<u8')
    for k in range(8):
        nw |= patch_bytes[w_src + k].astype('<u8') << np.uint64(8 * k)
    TAG = 61
    mask = np.uint64((1 << TAG) - 1)
    btag = bw >> np.uint64(TAG); ntag = nw >> np.uint64(TAG)
    boff = bw & mask; noff = nw & mask
    is_spur = (btag == 1) & (ntag == 0) & (noff == np.uint64(const_start) + boff * np.uint64(8))
    spur_per_run = np.bincount(w_run, weights=is_spur.astype(np.float64), minlength=n)
    words_per_run = np.bincount(w_run, minlength=n)
    only = (words_per_run > 0) & (spur_per_run == words_per_run)
    real = ~only
    def pages_of(sel):
        p0 = offs[sel] // page; p1 = (offs[sel] + sizes[sel] - 1) // page
        # expand multi-page runs
        multi = p1 > p0
        ps = [p0[~multi]]
        for a, b in zip(p0[multi], p1[multi]):
            ps.append(np.arange(a, b + 1))
        return np.unique(np.concatenate(ps))
    all_pages = pages_of(np.ones(n, dtype=bool))
    real_pages = pages_of(real)
    def stretches(p):
        return int((np.diff(p) != 1).sum()) + 1
    print('pages touched by all runs: %d (%.1f MB), in %d stretches of consecutive pages' % (len(all_pages), len(all_pages) * page / MB, stretches(all_pages)))
    print('pages touched by the runs that are not only a const-reference rewrite: %d (%.1f MB), in %d stretches' % (len(real_pages), len(real_pages) * page / MB, stretches(real_pages)))
    for gap in (4, 16, 64, 256):
        d = np.diff(all_pages)
        nst = int((d > gap).sum()) + 1
        covered = int(d[d <= gap].sum()) + nst
        print('  all runs, joined over gaps of up to %d pages: %d stretches, %.1f MB' % (gap, nst, covered * page / MB))
    # the words that are not a const-reference rewrite
    rw = ~is_spur
    print('words that are not such a rewrite: %d' % int(rw.sum()))
    b = bw[rw]; x = nw[rw]; bt = btag[rw]; xt = ntag[rw]; xo = noff[rw]; bo = boff[rw]
    c_maxworld = (b == np.uint64(0xFFFFFFFFFFFFFFFF)) & (x < np.uint64(1 << 40))
    c_new_obj = (xt == 0) & (xo >= np.uint64(const_limit))
    c_base_obj = (xt == 0) & (xo < np.uint64(sys_end)) & (xo > 4096) & ~c_maxworld
    c_const_other = (xt == 0) & (xo >= np.uint64(const_start)) & (xo < np.uint64(const_start + const_size))
    c_constref = (xt == 1)
    c_func = (xt == 4)
    c_tag = (xt == 2)
    c_zero = (x == 0)
    c_small = (xt == 0) & (xo <= 4096) & ~c_zero
    print('  a max_world set (~0 -> a world): %d' % int(c_maxworld.sum()))
    print('  new value a reference to a new object of the overlay: %d (base word was 0: %d, was a reference to a base object: %d)' % (
        int(c_new_obj.sum()), int((c_new_obj & (b == 0)).sum()), int((c_new_obj & (bt == 0) & (b != 0)).sum())))
    print('  new value a reference into the base sysimg (or a number in that range): %d (base word was 0: %d)' % (int(c_base_obj.sum()), int((c_base_obj & (b == 0)).sum())))
    print('  new value a DataRef into the base const data, base word something else: %d' % int(c_const_other.sum()))
    print('  new value a ConstDataRef: %d ; a FunctionRef: %d ; a TagRef: %d' % (int(c_constref.sum()), int(c_func.sum()), int(c_tag.sum())))
    print('  new value 0: %d ; a small number (1..4096): %d' % (int(c_zero.sum()), int(c_small.sum())))
    rest = ~(c_maxworld | c_new_obj | c_base_obj | c_const_other | c_constref | c_func | c_tag | c_zero | c_small)
    print('  other: %d' % int(rest.sum()))
    # const pages: where in the const-relative page do the differing bytes lie
    d = const_start % page
    head = page - d      # bytes of a const-relative page that lie in the real page of its first byte
    cidx = np.frombuffer(mo, dtype='<u4', count=h['npatch_const'], offset=ov_off + h['off_patch_idx_const']).astype(np.int64)
    in_head_only = 0; in_tail_only = 0; both = 0; none = 0
    head_bytes = 0; tail_bytes = 0
    cset = set(int(c) for c in cidx)
    tail_with_prev = 0; tail_without_prev = 0
    for i, ci in enumerate(cidx):
        o = int(ci) * page
        if o + page > const_size:
            continue
        a = np.frombuffer(ms, dtype=np.uint8, count=page, offset=sys_off + const_start + o)
        bb = np.frombuffer(mo, dtype=np.uint8, count=page, offset=ov_off + h['off_patch_const'] + i * page)
        df = a != bb
        hb = int(df[:head].sum()); tb = int(df[head:].sum())
        head_bytes += hb; tail_bytes += tb
        if hb and tb: both += 1
        elif hb: in_head_only += 1
        elif tb: in_tail_only += 1
        else: none += 1
    print('const data starts %d bytes into a real page: a const page has its first %d bytes in the real page whose dirty bit the writer reads, and its last %d bytes in the next real page' % (d, head, d))
    print('patched const pages: differing bytes only in the first %d bytes: %d ; only in the last %d bytes: %d ; in both: %d ; no difference: %d' % (head, in_head_only, d, in_tail_only, both, none))
    print('differing bytes in the first part: %d (%.1f per 1000 bytes of it) ; in the last part: %d (%.1f per 1000 bytes of it)' % (
        head_bytes, 1000.0 * head_bytes / (head * len(cidx)), tail_bytes, 1000.0 * tail_bytes / (d * len(cidx))))
    # neighbours: is the next const page patched as well when the last part differs
    nxt = sum(1 for c in cidx if int(c) + 1 in cset)
    print('patched const pages whose next const page is patched too: %d of %d' % (nxt, len(cidx)))
    # the residual list of the prelinked program, if given
    if len(sys.argv) > 8:
        prog, prog_off = sys.argv[7], int(sys.argv[8], 0)
        fp = open(prog, 'rb'); mp = mmap.mmap(fp.fileno(), 0, prot=mmap.PROT_READ)
        rec6 = struct.unpack_from('<6Q', mp, prog_off + sys_size - 48)
        print('program prelink record: address %s, residual_pos %d, capacity %d, fixup_pos %d' % (hex(rec6[0]), rec6[2], rec6[3], rec6[4]))
        relocs_off = align(const_start + const_size + 8, 8)
        # symbols size word, then symbols (0), then relocs size word
        pos = const_start + const_size
        ssize = struct.unpack_from('<Q', mp, prog_off + pos)[0]; pos += 8; pos = align(pos, 8) + ssize
        rsize = struct.unpack_from('<Q', mp, prog_off + pos)[0]; pos += 8; pos = align(pos, 8)
        z = struct.unpack_from('<2Q', mp, prog_off + pos + rec6[2])
        print('program residual list: %d type-tag pointers, %d other pointers' % z)
        # how many 4K pages of the sysimg+const differ between the founding file and the prelinked program
        a = np.frombuffer(ms, dtype='<u8', count=sys_end // 8, offset=sys_off)
        bq = np.frombuffer(mp, dtype='<u8', count=sys_end // 8, offset=prog_off)
        ndiff = 0
        step = 1 << 22
        for s in range(0, len(a), step):
            ndiff += int((a[s:s + step] != bq[s:s + step]).sum())
        print('words of the sysimg that differ between the founding file and the prelinked program: %d of %d' % (ndiff, len(a)))

if __name__ == '__main__':
    main()
