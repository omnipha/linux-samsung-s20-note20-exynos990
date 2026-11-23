#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""List a (newc) cpio archive with NUMERIC uid/gid and octal mode.

GNU cpio's "-itv" renders the owner names it finds in the *host's* passwd
database, which makes it useless for checking an initramfs that must ship a
specific uid (e.g. 1000 for the unprivileged "rescue" account): on a build
host whose uid 1000 is called "gregor" the archive entry then reads
"gregor gregor" and a name-based check would silently pass or fail for the
wrong reason.

This tool parses the archive headers directly and prints one line per entry:

    <mode:06o> <uid> <gid> <type> <path>

with the type being one of f (regular), d (dir), l (symlink), and so on.
The link target of a symlink is appended after the path.

Usage:
    cpio-listing.py ARCHIVE            # plain cpio
    cpio-listing.py -z ARCHIVE.gz      # gzip-compressed cpio
"""

import gzip
import sys

NEW_MAGIC = (b"070701", b"070702")


def _align4(offset):
    """Round `offset` up to the next multiple of 4 (gen_init_cpio padlen)."""
    return (offset + 3) & ~3


def parse(data):
    """Yield (mode, uid, gid, type, path, target) for each entry."""
    off = 0
    end = len(data)
    while off + 110 <= end:
        if data[off:off + 6] not in NEW_MAGIC:
            # Not a header: skip forward one byte and resynchronise.  This
            # happens after the TRAILER!!! record, where the archive is
            # padded to a 512-byte boundary.
            off += 1
            continue
        hdr = data[off:off + 110]
        try:
            mode = int(hdr[14:22], 16)
            uid = int(hdr[22:30], 16)
            gid = int(hdr[30:38], 16)
            namesize = int(hdr[94:102], 16)
            fsize = int(hdr[54:62], 16)
        except ValueError:
            off += 1
            continue
        name = data[off + 110:off + 110 + namesize].rstrip(b"\x00")
        # gen_init_cpio writes the name and the data and then pads the
        # *absolute archive offset* to a 4-byte boundary after each of them
        # (see usr/gen_init_cpio.c: push_pad(padlen(offset, 4))).  Because
        # the 110-byte header is not a multiple of 4, this is not the same
        # as aligning the name length: the body starts at
        #   align4(off + 110 + namesize)
        # and the next entry at
        #   align4(body_off + fsize).
        body_off = _align4(off + 110 + namesize)
        body = data[body_off:body_off + fsize]
        if name == b"TRAILER!!!":
            break
        ftype = "?"
        if mode & 0o170000 == 0o120000:
            ftype = "l"
        elif mode & 0o170000 == 0o040000:
            ftype = "d"
        elif mode & 0o170000 == 0o100000:
            ftype = "f"
        elif mode & 0o170000 == 0o020000:
            ftype = "c"
        elif mode & 0o170000 == 0o060000:
            ftype = "b"
        elif mode & 0o170000 == 0o010000:
            ftype = "p"
        elif mode & 0o170000 == 0o140000:
            ftype = "s"
        yield mode, uid, gid, ftype, name.decode("utf-8", "replace"), body.rstrip(b"\x00")
        off = _align4(body_off + fsize)


def main():
    argv = sys.argv[1:]
    gz = False
    if argv and argv[0] == "-z":
        gz = True
        argv = argv[1:]
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    path = argv[0]
    with (gzip.open(path, "rb") if gz else open(path, "rb")) as fh:
        data = fh.read()
    for mode, uid, gid, ftype, name, body in parse(data):
        line = "%06o %d %d %s %s" % (mode, uid, gid, ftype, name)
        if ftype == "l":
            line += " -> " + body.decode("utf-8", "replace")
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
