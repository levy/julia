#!/usr/bin/env python3
# overlay_other_base: give the overlay in a file the checksum of another base
# image, for the gate of a prelinked program under a chain. The field is the
# 29th 8-byte word of the header, which starts the data of the overlay; its
# high half is the mark of the field.
# Usage: python3 -I -B overlay_other_base.py OVERLAY
import mmap, os, struct, sys
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import overlay_check

MARK = 0x62617365

with open(sys.argv[1], 'r+b') as f:
    m = mmap.mmap(f.fileno(), 0)
    at = overlay_check.find_blob(m)[0] + 28 * 8
    (word,) = struct.unpack_from('<Q', m, at)
    if word >> 32 != MARK:
        sys.exit('overlay_other_base: the overlay has no checksum of its base: %#x' % word)
    struct.pack_into('<Q', m, at, word ^ 1)
    m.flush()
