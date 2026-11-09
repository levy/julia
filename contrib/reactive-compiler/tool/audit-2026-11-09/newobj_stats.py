import mmap, struct
import numpy as np
from collections import Counter
def align(x, a): return (x + a - 1) & ~(a - 1)
sys_path, sys_off, sys_size = 'lib/julia/sys.so', 0x85aa000, 0x4bb1c458
ov_path, ov_off = 'lib/julia/sys.7.so', 0x1985000
fs = open(sys_path,'rb'); fo = open(ov_path,'rb')
ms = mmap.mmap(fs.fileno(), 0, prot=mmap.PROT_READ)
mo = mmap.mmap(fo.fileno(), 0, prot=mmap.PROT_READ)
u64 = lambda m,p: struct.unpack_from('<Q', m, p)[0]
sysdata = u64(ms, sys_off); sys_end = sysdata + 8
const_size = u64(ms, sys_off + sys_end); const_start = align(sys_end + 8, 64)
mapped = align(const_start + const_size, 4096); const_limit = mapped + (64 << 20)
names = ['magic','base_sysimg_size','base_const_size','base_syms_size','page_size','npatch_sysimg','npatch_const','new_sysimg_size','new_const_size','new_syms_size','relocs_size','gvar_size','fptr_size','roots_size','off_patch_idx_sysimg','off_patch_sysimg','off_patch_idx_const','off_patch_const','off_new_sysimg','off_new_const','off_new_syms','off_relocs','off_gvar','off_fptr','off_roots']
h = dict(zip(names, struct.unpack_from('<25Q', mo, ov_off)))
TAG = 61; MASK = (1 << TAG) - 1
base_words = np.frombuffer(ms, dtype='<u8', count=sys_end//8, offset=sys_off)
new_words = np.frombuffer(mo, dtype='<u8', count=h['new_sysimg_size']//8, offset=ov_off+h['off_new_sysimg'])
def cstr(off):
    end = ms.find(b'\0', sys_off + off, sys_off + off + 256)
    return ms[sys_off + off:end].decode('utf-8', 'replace')
def type_name(d):
    if d >= sys_end: return '<new type>'
    t = int(base_words[d // 8]) & MASK
    s = int(base_words[t // 8]) & MASK
    return cstr(s + 24)
# decode the gc tags of the overlay's full list, keep those past the base
b = np.frombuffer(mo, dtype=np.uint8, count=h['relocs_size'], offset=ov_off + h['off_relocs'])
# vectorized decode of the first list
ends = np.nonzero(b < 0x80)[0]
starts = np.concatenate(([0], ends[:-1] + 1)); lens = ends - starts + 1
vals = np.zeros(len(ends), dtype=np.int64)
for k in range(int(lens[:20000000].max())):
    sel = lens > k
    vals[sel] |= (b[starts[sel] + k].astype(np.int64) & 0x7F) << (7 * k)
z = int(np.nonzero(vals == 0)[0][0])
tags = np.cumsum(vals[:z])
new_tags = tags[tags >= const_limit]
print('objects of the overlay: %d' % len(new_tags))
hdr = new_words[(new_tags - const_limit)//8]
sizes = np.diff(np.concatenate((new_tags, [const_limit + h['new_sysimg_size']])))
cnt = Counter(); byt = Counter()
uniq, inv = np.unique(hdr, return_inverse=True)
csum = np.bincount(inv, weights=sizes.astype(np.float64)); ccnt = np.bincount(inv)
rows = []
for u, s, c in zip(uniq, csum, ccnt):
    u = int(u)
    nm = type_name(u & MASK) if (u >> TAG) == 0 else 'tag %d' % (u >> TAG)
    rows.append((s, c, nm, u))
agg = {}
for s, c, nm, u in rows:
    a = agg.setdefault(nm, [0, 0]); a[0] += s; a[1] += c
print('new objects by type (bytes of the sysimg, count), largest first:')
for nm, (s, c) in sorted(agg.items(), key=lambda kv: -kv[1][0])[:16]:
    print('  %-28s %10.2f MB %9d' % (nm, s / (1 << 20), c))
# the largest new objects
order = np.argsort(-sizes)[:12]
print('largest new objects:')
for i in order:
    u = int(hdr[i]); nm = type_name(u & MASK) if (u >> TAG) == 0 else '?'
    off = int(new_tags[i]) + 8
    first = int(new_words[(off - const_limit)//8])
    print('  %-22s %9.2f MB at %d, first word %d' % (nm, sizes[i] / (1 << 20), off, first))
# memories with their data in the new const data
gm = [int(u) for u, (s, c, nm, uu) in zip(uniq, rows) if nm == 'GenericMemory']
tot_const = 0; big = []
for i in np.nonzero(np.isin(hdr, np.array(gm, dtype=np.uint64)))[0]:
    off = int(new_tags[i]) + 8
    ln = int(new_words[(off - const_limit)//8]); ptr = int(new_words[(off - const_limit)//8 + 1])
    if (ptr >> TAG) == 1:
        coff = (ptr & MASK) * 8
        if coff >= const_size:
            big.append((ln, coff - const_size, int(hdr[i])))
big.sort(reverse=True)
print('new memories with data in the new const data: %d ; the largest by element count:' % len(big))
for ln, co, hd in big[:8]:
    print('   %10d elements at new const offset %d (memory type at %d)' % (ln, co, hd))
