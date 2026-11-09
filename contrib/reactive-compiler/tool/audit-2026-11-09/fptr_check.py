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
rsize = u64(ms, sys_off+pos); pos += 8; pos = align(pos,8)+rsize
gsize = u64(ms, sys_off+pos); pos += 8; pos = align(pos,8)+gsize
fsize = u64(ms, sys_off+pos); pos += 8; pos = align(pos,8); fptr_off = pos
names = ['magic','base_sysimg_size','base_const_size','base_syms_size','page_size','npatch_sysimg','npatch_const','new_sysimg_size','new_const_size','new_syms_size','relocs_size','gvar_size','fptr_size','roots_size','off_patch_idx_sysimg','off_patch_sysimg','off_patch_idx_const','off_patch_const','off_new_sysimg','off_new_const','off_new_syms','off_relocs','off_gvar','off_fptr','off_roots']
h = dict(zip(names, struct.unpack_from('<25Q', mo, ov_off)))
bf = np.frombuffer(ms, dtype='<u8', count=fsize//8, offset=sys_off+fptr_off)
of = np.frombuffer(mo, dtype='<u8', count=h['fptr_size']//8, offset=ov_off+h['off_fptr'])
HI = np.uint64(1) << np.uint64(63)
def split(a):
    a = a[a != 0]
    inv = (a & HI) != 0
    return a[~inv].astype(np.int64), (~a[inv]).astype(np.int64)
bspec, binv = split(bf); ospec, oinv = split(of)
print('base table: %d entries, %d specialized, %d wrappers, %d empty' % (len(bf), len(bspec), len(binv), int((bf==0).sum())))
print('overlay table: %d entries, %d specialized, %d wrappers, %d empty' % (len(of), len(ospec), len(oinv), int((of==0).sum())))
print('overlay entries naming a code instance of the base: %d ; a new one: %d' % (int((ospec < sys_end).sum()), int((ospec >= sys_end).sum())))
dropped = np.setdiff1d(np.unique(bspec), np.unique(ospec))
kept = np.intersect1d(np.unique(bspec), np.unique(ospec))
print('code instances of the base with a function in the base table: %d ; still named by the overlay table: %d ; no longer named: %d' % (len(np.unique(bspec)), len(kept), len(dropped)))
n = h['npatch_sysimg']
rec = np.frombuffer(mo, dtype='<u8', count=2*n, offset=ov_off+h['off_patch_idx_sysimg']).reshape(n,2)
roffs = rec[:,0].astype(np.int64); rsizes = rec[:,1].astype(np.int64); rends = roffs + rsizes
cum = np.concatenate(([0], np.cumsum(rsizes)))[:-1]
pb = np.frombuffer(mo, dtype=np.uint8, count=int(rsizes.sum()), offset=ov_off+h['off_patch_sysimg'])
base_words = np.frombuffer(ms, dtype='<u8', count=sys_end//8, offset=sys_off)
def comp_word(p):
    k = np.searchsorted(rends, p, side='right'); k = np.minimum(k, n-1)
    inr = (roffs[k] <= p) & (rends[k] >= p + 8)
    out = base_words[p//8].copy()
    src = cum[k[inr]] + (p[inr] - roffs[k[inr]])
    v = np.zeros(int(inr.sum()), dtype='<u8')
    for j in range(8):
        v |= pb[src + j].astype('<u8') << np.uint64(8*j)
    out[inr] = v
    return out, inr
mw, mw_in = comp_word(dropped + 32)
inf = mw == np.uint64(0xFFFFFFFFFFFFFFFF)
print('no longer named: max_world still unbounded %d ; bounded %d' % (int(inf.sum()), int((~inf).sum())))
sp, sp_in = comp_word(dropped + 120); iv, iv_in = comp_word(dropped + 112); fl, fl_in = comp_word(dropped + 104)
print('no longer named: the word of specptr is in a run for %d, of invoke for %d, of the flags for %d' % (int(sp_in.sum()), int(iv_in.sum()), int(fl_in.sum())))
biv = base_words[(dropped + 112)//8]
print('no longer named: the base file holds a FunctionRef in invoke for %d' % int((biv != 0).sum()))
