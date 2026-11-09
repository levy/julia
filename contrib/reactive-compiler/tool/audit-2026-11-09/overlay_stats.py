#!/usr/bin/env python3
# Read-only inspection of a founding image blob and its overlay blob.
# usage: overlay_stats.py <sys.so> <blob file offset> <blob size> <overlay.so> <blob file offset> <blob size>
import mmap, struct, sys
import numpy as np

def align(x, a):
    return (x + a - 1) & ~(a - 1)

def parse_blob(m, base, size):
    pos = 0
    def u64(p):
        return struct.unpack_from('<Q', m, base + p)[0]
    sec = {}
    sysdata = u64(pos)
    sec['sysimg'] = (0, sysdata + 8)
    pos += 8 + sysdata
    csize = u64(pos); pos += 8
    pos = align(pos, 64)
    sec['const'] = (pos, csize)
    pos += csize
    sec['blob_span'] = pos
    ssize = u64(pos); pos += 8; pos = align(pos, 8)
    sec['symbols'] = (pos, ssize); pos += ssize
    rsize = u64(pos); pos += 8; pos = align(pos, 8)
    sec['relocs'] = (pos, rsize); pos += rsize
    gsize = u64(pos); pos += 8; pos = align(pos, 8)
    sec['gvar'] = (pos, gsize); pos += gsize
    fsize = u64(pos); pos += 8; pos = align(pos, 8)
    sec['fptr'] = (pos, fsize); pos += fsize
    pos = align(pos, 8)
    sec['roots'] = (pos, size - pos)
    return sec

def main():
    sys_path, sys_off, sys_size, ov_path, ov_off, ov_size = sys.argv[1], int(sys.argv[2], 0), int(sys.argv[3], 0), sys.argv[4], int(sys.argv[5], 0), int(sys.argv[6], 0)
    fs = open(sys_path, 'rb'); ms = mmap.mmap(fs.fileno(), 0, prot=mmap.PROT_READ)
    fo = open(ov_path, 'rb'); mo = mmap.mmap(fo.fileno(), 0, prot=mmap.PROT_READ)
    sec = parse_blob(ms, sys_off, sys_size)
    page = 4096
    MB = 1 << 20
    print('--- base blob', sys_size, 'bytes = %.1f MB' % (sys_size / MB))
    for k in ('sysimg', 'const', 'symbols', 'relocs', 'gvar', 'fptr', 'roots'):
        print('  %-8s offset %12d size %12d (%.1f MB)' % (k, sec[k][0], sec[k][1], sec[k][1] / MB))
    const_start, const_size = sec['const']
    mapped = align(const_start + const_size, page)
    const_limit = mapped + (64 << 20)
    print('  const_start %% 4096 = %d' % (const_start % page))
    print('  mapped (end of const, page aligned) = %d ; tail of the blob after it = %.1f MB' % (mapped, (sys_size - mapped) / MB))
    print('  const_limit = %d' % const_limit)
    print('  gvar slots of the base: %d' % (sec['gvar'][1] // 8))
    print('  fptr record entries of the base: %d' % (sec['fptr'][1] // 8))
    # prelink record at the end
    tail = struct.unpack_from('<6Q', ms, sys_off + sys_size - 48)
    print('  prelink record (addr, stubs, residual_pos, residual_capacity, fixup_pos, magic): %s' % (tuple(hex(x) for x in tail),))

    # overlay header
    names = ['magic', 'base_sysimg_size', 'base_const_size', 'base_syms_size', 'page_size', 'npatch_sysimg', 'npatch_const',
             'new_sysimg_size', 'new_const_size', 'new_syms_size', 'relocs_size', 'gvar_size', 'fptr_size', 'roots_size',
             'off_patch_idx_sysimg', 'off_patch_sysimg', 'off_patch_idx_const', 'off_patch_const', 'off_new_sysimg',
             'off_new_const', 'off_new_syms', 'off_relocs', 'off_gvar', 'off_fptr', 'off_roots']
    vals = struct.unpack_from('<25Q', mo, ov_off)
    h = dict(zip(names, vals))
    h['external_fns_begin'], h['ngvars'] = struct.unpack_from('<2I', mo, ov_off + 25 * 8)
    h['off_delta_relocs'], h['delta_relocs_size'] = struct.unpack_from('<2Q', mo, ov_off + 25 * 8 + 8)
    print('--- overlay blob', ov_size, 'bytes = %.1f MB' % (ov_size / MB))
    for k in ('magic', 'base_sysimg_size', 'base_const_size', 'base_syms_size', 'page_size'):
        print('  %-18s %s' % (k, hex(h[k]) if k == 'magic' else h[k]))
    for k in ('npatch_sysimg', 'npatch_const'):
        print('  %-18s %d' % (k, h[k]))
    for k in ('new_sysimg_size', 'new_const_size', 'new_syms_size', 'relocs_size', 'delta_relocs_size', 'gvar_size', 'fptr_size', 'roots_size'):
        print('  %-18s %12d (%.2f MB)' % (k, h[k], h[k] / MB))
    print('  external_fns_begin %d, ngvars %d' % (h['external_fns_begin'], h['ngvars']))
    print('  base_sysimg_size == const_limit: %s' % (h['base_sysimg_size'] == const_limit))
    print('  const page patches: %d pages = %.2f MB' % (h['npatch_const'], h['npatch_const'] * page / MB))

    # the patch runs
    n = h['npatch_sysimg']
    rec = np.frombuffer(mo, dtype='<u8', count=2 * n, offset=ov_off + h['off_patch_idx_sysimg']).reshape(n, 2)
    offs = rec[:, 0]; sizes = rec[:, 1]
    total = int(sizes.sum())
    print('--- sysimg patch runs: %d runs, payload %.2f MB, records %.2f MB' % (n, total / MB, 16 * n / MB))
    print('  run size histogram (bytes: count):')
    for s in (8, 16, 24, 32, 40, 48, 64, 128, 256, 1024, 1 << 62):
        pass
    bins = [8, 16, 24, 32, 48, 64, 128, 256, 1024, 4096, 1 << 62]
    lo = 0
    for b in bins:
        c = int(((sizes > lo) & (sizes <= b)).sum())
        print('    (%d, %s]: %d' % (lo, b if b < (1 << 62) else 'inf', c))
        lo = b
    pages = np.unique(offs // page)
    print('  distinct 4K pages that hold the start of a run: %d' % len(pages))
    in_base = offs < sec['sysimg'][1]
    print('  runs inside the base sysimg: %d ; past it: %d' % (int(in_base.sum()), int((~in_base).sum())))

    # word-level comparison with the base file
    cum = np.concatenate(([0], np.cumsum(sizes)))[:-1]
    pb = ov_off + h['off_patch_sysimg']
    TAG = 61
    nwords = 0
    same = 0
    spurious_const = 0     # base word ConstDataRef(x), new word DataRef(const_start + 8x)
    other_const_to_data = 0
    base_zero_new_nonzero = 0
    base_nonzero_new_zero = 0
    both_reloc_differ = 0
    plain = 0
    runs_only_spurious = 0
    runs_single_word = 0
    sys_end = sec['sysimg'][1]
    whole = total // 8
    # vectorized per-word arrays for runs with size % 8 == 0 that lie in the base
    ok = in_base & (sizes % 8 == 0) & (offs % 8 == 0) & ((offs + sizes) <= sys_end)
    idx = np.nonzero(ok)[0]
    w_off = np.repeat(offs[idx], (sizes[idx] // 8).astype(np.int64))
    w_run = np.repeat(idx, (sizes[idx] // 8).astype(np.int64))
    # position inside the run
    counts = (sizes[idx] // 8).astype(np.int64)
    starts = np.concatenate(([0], np.cumsum(counts)))[:-1]
    inner = np.arange(int(counts.sum()), dtype=np.int64) - np.repeat(starts, counts)
    w_pos = w_off.astype(np.int64) + inner * 8
    w_src = np.repeat(cum[idx], counts).astype(np.int64) + inner * 8
    base_words = np.frombuffer(ms, dtype='<u8', count=(sys_end // 8), offset=sys_off)
    bw = base_words[w_pos // 8]
    patch_bytes = np.frombuffer(mo, dtype=np.uint8, count=total, offset=pb)
    # the payload is not word aligned in general: gather per word
    nw = np.zeros(len(w_src), dtype='<u8')
    for k in range(8):
        nw |= patch_bytes[w_src + k].astype('<u8') << np.uint64(8 * k)
    nwords = len(nw)
    eq = bw == nw
    btag = bw >> np.uint64(TAG); ntag = nw >> np.uint64(TAG)
    mask = np.uint64((1 << TAG) - 1)
    boff = bw & mask; noff = nw & mask
    is_spur = (btag == 1) & (ntag == 0) & (noff == np.uint64(const_start) + boff * np.uint64(8))
    in_const_region = (ntag == 0) & (noff >= np.uint64(const_start)) & (noff < np.uint64(const_start + const_size))
    print('--- words of the runs inside the base (%d runs, %d words)' % (len(idx), nwords))
    print('  equal to the base file word (forced pair or whole patch): %d' % int(eq.sum()))
    print('  base ConstDataRef(x) -> new DataRef(const_start + 8x), the same target: %d' % int(is_spur.sum()))
    print('  new word a DataRef into the const data of the base, any base word: %d' % int(in_const_region.sum()))
    print('  base word 0 -> new word not 0: %d' % int(((bw == 0) & (nw != 0)).sum()))
    print('  base word not 0 -> new word 0: %d' % int(((bw != 0) & (nw == 0)).sum()))
    print('  new word is all ones or a small integer change (|delta| < 2^32, both tags 0): %d' % int(((btag == 0) & (ntag == 0) & ~eq & ~in_const_region & (np.abs(bw.astype(np.int64) - nw.astype(np.int64)) < (1 << 32))).sum()))
    # runs made only of spurious words
    spur_per_run = np.bincount(w_run, weights=is_spur.astype(np.float64), minlength=n)
    words_per_run = np.bincount(w_run, minlength=n)
    only = (words_per_run > 0) & (spur_per_run == words_per_run)
    print('  runs whose every word is such a ConstDataRef -> DataRef rewrite: %d of %d' % (int(only.sum()), n))
    print('  runs with at least one such word: %d' % int((spur_per_run > 0).sum()))
    # a word that held UINT64_MAX in the base and holds a world now (max_world)
    mw = (bw == np.uint64(0xFFFFFFFFFFFFFFFF)) & (nw < np.uint64(1 << 32))
    print('  base word ~0 -> a small number (a max_world set): %d' % int(mw.sum()))
    # distinct pages touched by all runs in the base
    allpages = set()
    p0 = (offs[in_base] // page); p1 = ((offs[in_base] + sizes[in_base] - 1) // page)
    print('  distinct pages touched by runs in the base (first..last page of each run): about %d' % len(np.unique(np.concatenate((p0, p1)))))
    # const pages
    cidx = np.frombuffer(mo, dtype='<u4', count=h['npatch_const'], offset=ov_off + h['off_patch_idx_const'])
    if len(cidx):
        print('--- const page patches: %d, first %d last %d ; pages past the base const: %d' % (len(cidx), int(cidx[0]), int(cidx[-1]), int((cidx.astype(np.int64) * page >= const_size).sum())))
        # how many const pages differ from the base only in a few bytes
        diffs = []
        for i, ci in enumerate(cidx[:20000]):
            o = int(ci) * page
            if o + page > const_size:
                continue
            a = np.frombuffer(ms, dtype=np.uint8, count=page, offset=sys_off + const_start + o)
            b = np.frombuffer(mo, dtype=np.uint8, count=page, offset=ov_off + h['off_patch_const'] + i * page)
            diffs.append(int((a != b).sum()))
        d = np.array(diffs)
        if len(d):
            print('  bytes that differ per patched const page: median %d, mean %.1f, max %d ; pages with <= 8 bytes changed: %d of %d' % (int(np.median(d)), d.mean(), d.max(), int((d <= 8).sum()), len(d)))

if __name__ == '__main__':
    main()
