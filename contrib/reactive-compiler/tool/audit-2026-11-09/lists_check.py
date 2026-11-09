#!/usr/bin/env python3
# Read-only check of the relocation lists of an overlay against the lists of its base:
#  - outside the patched runs, inside the base: the full lists of the overlay name the same positions as the base lists
#    (else the region load and the in-place load of a prelinked base end with different words);
#  - a memory reference (two words) has both words in a run or neither;
#  - the delta lists are exactly the positions of the full lists that are in a run or past the base.
import mmap, struct, sys
import numpy as np

def align(x, a):
    return (x + a - 1) & ~(a - 1)

def decode_lists(buf, nlists=4):
    b = np.frombuffer(buf, dtype=np.uint8)
    out = []
    pos = 0
    for _ in range(nlists):
        # find the end of this list: a zero byte that starts a number (the previous byte has no continuation bit)
        chunk_end = pos
        res = []
        step = 1 << 24
        carry_pos = pos
        last = 0
        done = False
        while not done:
            seg = b[carry_pos:carry_pos + step]
            if len(seg) == 0:
                raise RuntimeError('list not terminated')
            ends = np.nonzero(seg < 0x80)[0]
            if len(ends) == 0:
                raise RuntimeError('no terminator in a segment')
            # numbers end at `ends`; the numbers start after the previous end
            starts = np.concatenate(([0], ends[:-1] + 1))
            lens = ends - starts + 1
            maxlen = int(lens.max())
            vals = np.zeros(len(ends), dtype=np.int64)
            for k in range(maxlen):
                sel = lens > k
                vals[sel] |= (seg[starts[sel] + k].astype(np.int64) & 0x7F) << (7 * k)
            z = np.nonzero(vals == 0)[0]
            if len(z):
                cut = int(z[0])
                vals = vals[:cut]
                consumed = int(ends[cut]) + 1
                done = True
            else:
                consumed = int(ends[-1]) + 1
            if len(vals):
                p = np.cumsum(vals) + last
                last = int(p[-1])
                res.append(p)
            carry_pos += consumed
        out.append(np.concatenate(res) if res else np.zeros(0, dtype=np.int64))
        pos = carry_pos
    return out, pos

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
    rsize = u64(ms, sys_off + pos); pos += 8; pos = align(pos, 8); relocs_off = pos
    names = ['magic', 'base_sysimg_size', 'base_const_size', 'base_syms_size', 'page_size', 'npatch_sysimg', 'npatch_const',
             'new_sysimg_size', 'new_const_size', 'new_syms_size', 'relocs_size', 'gvar_size', 'fptr_size', 'roots_size',
             'off_patch_idx_sysimg', 'off_patch_sysimg', 'off_patch_idx_const', 'off_patch_const', 'off_new_sysimg',
             'off_new_const', 'off_new_syms', 'off_relocs', 'off_gvar', 'off_fptr', 'off_roots']
    h = dict(zip(names, struct.unpack_from('<25Q', mo, ov_off)))
    off_delta, delta_size = struct.unpack_from('<2Q', mo, ov_off + 25 * 8 + 8)
    n = h['npatch_sysimg']
    rec = np.frombuffer(mo, dtype='<u8', count=2 * n, offset=ov_off + h['off_patch_idx_sysimg']).reshape(n, 2)
    roffs = rec[:, 0].astype(np.int64); rsizes = rec[:, 1].astype(np.int64)
    rends = roffs + rsizes

    def in_run(p, span=8):
        # does [p, p+span) overlap a run
        k = np.searchsorted(rends, p, side='right')       # first run whose end is > p
        k = np.minimum(k, len(roffs) - 1)
        return (roffs[k] < p + span) & (rends[k] > p)

    base_lists, _ = decode_lists(ms[sys_off + relocs_off:sys_off + relocs_off + rsize])
    full_lists, fpos = decode_lists(mo[ov_off + h['off_relocs']:ov_off + h['off_relocs'] + h['relocs_size']])
    delta_lists, dpos = decode_lists(mo[ov_off + off_delta:ov_off + off_delta + delta_size])
    lname = ['gc tags', 'relocations', 'memory owners', 'memory references']
    for i in range(4):
        b = base_lists[i]; f = full_lists[i]; d = delta_lists[i]
        span = 16 if i >= 2 else 8
        print('%-18s base %9d  overlay full %9d  delta %8d' % (lname[i], len(b), len(f), len(d)))
        b_out = b[~in_run(b, span)] if len(b) else b
        f_base = f[f < sys_end]
        f_out = f_base[~in_run(f_base, span)] if len(f_base) else f_base
        only_base = np.setdiff1d(b_out, f_out, assume_unique=True)
        only_full = np.setdiff1d(f_out, b_out, assume_unique=True)
        print('   outside the runs, inside the base: in the base list only %d, in the overlay list only %d' % (len(only_base), len(only_full)))
        if len(only_base):
            print('     first positions in the base list only:', only_base[:8])
        if len(only_full):
            print('     first positions in the overlay list only:', only_full[:8])
        # delta completeness
        want = f[(f >= sys_end) | in_run(f, span)] if len(f) else f
        md = np.setdiff1d(want, d, assume_unique=True); xd = np.setdiff1d(d, want, assume_unique=True)
        print('   delta list: missing %d, extra %d' % (len(md), len(xd)))
        if i >= 2 and len(f):
            fb = f[f < sys_end]
            a = in_run(fb, 8); c = in_run(fb + 8, 8)
            print('   references of the base with one word in a run and the other not: %d' % int((a != c).sum()))
    # how many base relocations (pointer words) the full lists convert at a region load
    print('positions converted by a region load: %d ; by the delta lists: %d' % (sum(len(x) for x in full_lists), sum(len(x) for x in delta_lists)))

if __name__ == '__main__':
    main()
