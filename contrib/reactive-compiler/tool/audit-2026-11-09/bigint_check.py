import mmap, struct
import numpy as np
def align(x, a): return (x + a - 1) & ~(a - 1)
sys_path, sys_off, sys_size = 'lib/julia/sys.so', 0x85aa000, 0x4bb1c458
ov_path, ov_off = 'lib/julia/sys.7.so', 0x1985000
fs = open(sys_path,'rb'); fo = open(ov_path,'rb')
ms = mmap.mmap(fs.fileno(), 0, prot=mmap.PROT_READ)
mo = mmap.mmap(fo.fileno(), 0, prot=mmap.PROT_READ)
u64 = lambda m,p: struct.unpack_from('<Q', m, p)[0]
sysdata = u64(ms, sys_off); sys_end = sysdata + 8
const_size = u64(ms, sys_off + sys_end); const_start = align(sys_end + 8, 64)
pos = const_start + const_size
ssize = u64(ms, sys_off+pos); pos += 8; pos = align(pos,8)+ssize
rsize = u64(ms, sys_off+pos); pos += 8; pos = align(pos,8); relocs_off = pos
TAG = 61; MASK = (1 << TAG) - 1
base_words = np.frombuffer(ms, dtype='<u8', count=sys_end//8, offset=sys_off)
def cstr(off):
    end = ms.find(b'\0', sys_off + off, sys_off + off + 256)
    return ms[sys_off + off:end].decode('utf-8', 'replace')
def type_name(d):
    t = int(base_words[d // 8]) & MASK
    s = int(base_words[t // 8]) & MASK
    return cstr(s + 24)
b = np.frombuffer(ms, dtype=np.uint8, count=rsize, offset=sys_off + relocs_off)
ends = np.nonzero(b[:40000000] < 0x80)[0]
starts = np.concatenate(([0], ends[:-1] + 1)); lens = ends - starts + 1
vals = np.zeros(len(ends), dtype=np.int64)
for k in range(int(lens.max())):
    sel = lens > k
    vals[sel] |= (b[starts[sel] + k].astype(np.int64) & 0x7F) << (7 * k)
z = int(np.nonzero(vals == 0)[0][0])
tags = np.cumsum(vals[:z])
hdr = base_words[tags // 8]
uniq, cnt = np.unique(hdr, return_counts=True)
names = {}
for u, c in zip(uniq, cnt):
    u = int(u)
    if (u >> TAG) == 0 and u < sys_end:
        try:
            nm = type_name(u)
        except Exception:
            nm = '?'
        if nm in ('BigInt', 'BigFloat', 'Task', 'OpaqueClosure'):
            names.setdefault(nm, []).append((u, int(c)))
print(names)
names2 = ['magic','base_sysimg_size','base_const_size','base_syms_size','page_size','npatch_sysimg','npatch_const','new_sysimg_size','new_const_size','new_syms_size','relocs_size','gvar_size','fptr_size','roots_size','off_patch_idx_sysimg','off_patch_sysimg']
h = dict(zip(names2, struct.unpack_from('<16Q', mo, ov_off)))
n = h['npatch_sysimg']
rec = np.frombuffer(mo, dtype='<u8', count=2*n, offset=ov_off+h['off_patch_idx_sysimg']).reshape(n,2)
pages_with_runs = np.unique(rec[:,0].astype(np.int64) // 4096)
for nm, lst in names.items():
    for u, c in lst:
        pos = tags[hdr == np.uint64(u)]
        pg = np.unique(pos // 4096)
        hit = np.isin(pg, pages_with_runs).sum()
        print('%s: %d objects on %d pages; pages that also hold a patch run of this overlay: %d' % (nm, c, len(pg), int(hit)))
