# The check scripts of the audit of 2026-11-09

Read-only scripts. Each one maps a base image and an overlay, and counts. They
are the evidence of finding 33 and of findings 12, 13 and 22 of
`plan/pending/a-rebuild-equals-a-whole-build.md`. Step 1 of that plan makes
`tool/overlay_check.py` from the first two.

The arguments are a file, the offset of its blob and the size of its blob, for
the base image and then for the overlay. For the IDE store of 2026-11-09:

    python3 -I rootblocks_check.py sys.so 0x85aa000 0x4bb1c458 sys.7.so 0x1985000 0xc5bd980
    python3 -I keyset_check.py     sys.so 0x85aa000 0x4bb1c458 sys.7.so 0x1985000 0xc5bd980

`binding_names.py`, `overlay_stats.py` and `lists_check.py` take the same
arguments. The other scripts have the offsets of that store in their text; the
offset of the blob in the program `bin/omnet_ide` was `0x8939000`.
