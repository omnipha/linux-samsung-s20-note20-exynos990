#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Independently prove, FROM THE PACKAGED BOOT IMAGE ITSELF (not from the
# staging tree), that
#   1. the ramdisk inside boot.img contains root/.ssh/authorized_keys,
#   2. that file's OpenSSH fingerprint equals the fingerprint of the
#      source public key given on the command line, and
#   3. the file is a regular file with mode 0600 in the cpio archive.
#
# Nothing here trusts the build directory: the Android boot image header
# is parsed, the ramdisk slot is sliced out of boot.img, the gzip stream
# is decompressed and the newc cpio entries are read directly (file mode
# and contents come from the cpio headers, so the answer is what the
# artifact really ships - not what was staged).
#
# No private key is read or written; only public key material is handled
# and only SHA-256 hashes and OpenSSH fingerprints are printed.
#
# Usage: prove-authorized-keys.sh <boot.img> <source-public-key>
# Exit 0 = all three claims proven, 1 = otherwise.

set -euo pipefail

IMG="${1:?usage: prove-authorized-keys.sh <boot.img> <source-public-key>}"
SRC="${2:?usage: prove-authorized-keys.sh <boot.img> <source-public-key>}"

[ -f "${IMG}" ] || { echo "missing boot image: ${IMG}" >&2; exit 1; }
[ -f "${SRC}" ] || { echo "missing source public key: ${SRC}" >&2; exit 1; }

echo "== source"
echo "  boot.img:  ${IMG} ($(stat -c %s "${IMG}") bytes)"
echo "  sha256:    $(sha256sum "${IMG}" | cut -d' ' -f1)"
echo "  src key:   ${SRC} ($(stat -c %s "${SRC}") bytes)"
echo "  src sha256: $(sha256sum "${SRC}" | cut -d' ' -f1)"
echo "  src fingerprint: $(ssh-keygen -lf "${SRC}")"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------- slice ramdisk out
# Android boot image v2: kernel_size @8, ramdisk_size @16, page_size @36
# (all u32 LE). ramdisk offset = page_size + align(kernel_size, page_size).
python3 - "${IMG}" "${TMP}/ramdisk.blob" <<'PYEOF'
import struct, sys

img_path, out_path = sys.argv[1], sys.argv[2]
img = open(img_path, "rb").read()
if img[:8] != b"ANDROID!":
    sys.exit("not an Android boot image (bad magic)")
kernel_size, _, ramdisk_size = struct.unpack_from("<III", img, 8)
page_size = struct.unpack_from("<I", img, 36)[0]
if page_size == 0 or page_size > 0x10000:
    sys.exit("implausible page_size %d" % page_size)

def align_up(v, a):
    return (v + a - 1) & ~(a - 1)

off = page_size + align_up(kernel_size, page_size)
if off + ramdisk_size > len(img):
    sys.exit("ramdisk slot %d+%d beyond image %d"
             % (off, ramdisk_size, len(img)))
open(out_path, "wb").write(img[off:off + ramdisk_size])
print("ramdisk slot: offset %d, %d bytes (kernel %d, page %d)"
      % (off, ramdisk_size, kernel_size, page_size))
if img[off:off + 2] == b"\x1f\x8b":
    print("ramdisk is gzip-compressed (as packaged by mkbootimg)")
else:
    sys.exit("ramdisk slot is not gzip - unexpected packaging")
PYEOF

gzip -dc "${TMP}/ramdisk.blob" > "${TMP}/initramfs.cpio"

# -------------------------------------------- read newc entries directly
# mode + contents come from the archive itself: no cpio(1) extraction, so
# nothing about ownership or the extracting user can mask the result.
python3 - "${TMP}/initramfs.cpio" "/root/.ssh/authorized_keys" \
	"${TMP}/extracted.pub" "${TMP}/entries.txt" <<'PYEOF'
import sys, os

cpio_path, want, out_pub, out_list = sys.argv[1:5]
data = open(cpio_path, "rb").read()

pos = 0
found = None
lines = []
while pos + 110 <= len(data):
    magic = data[pos:pos + 6]
    if magic not in (b"070701", b"070702"):
        break
    hdr = data[pos:pos + 110]
    fields = [hdr[6 + 8 * i:14 + 8 * i].decode("ascii") for i in range(13)]
    # newc header fields are 8-digit HEXADECIMAL ASCII
    mode = int(fields[1], 16)
    filesize = int(fields[6], 16)
    namesize = int(fields[11], 16)
    name_off = pos + 110
    name = data[name_off:name_off + namesize - 1].decode(
        "utf-8", "replace")
    hdr_end = (name_off + namesize + 3) & ~3
    if name == "TRAILER!!!":
        break
    file_start = hdr_end
    file_end = file_start + filesize
    lines.append("%s mode=%06o size=%d" % (name, mode & 0o777777, filesize))
    if name.lstrip("/") == want.lstrip("/"):
        found = (mode, filesize, data[file_start:file_end])
    pos = (file_end + 3) & ~3

if found is None:
    print("entry %s NOT FOUND in the packaged initramfs" % want)
    open(out_list, "w").write("\n".join(lines) + "\n")
    sys.exit(2)

mode, filesize, content = found
open(out_pub, "wb").write(content)
open(out_list, "w").write("\n".join(lines) + "\n")
print("entry %s: cpio mode=%06o (type %o), size=%d"
      % (want, mode & 0o777777, (mode >> 12) & 0o17, filesize))
print("entry content sha256: "
      + __import__("hashlib").sha256(content).hexdigest())
if not content.endswith(b"\n"):
    print("WARNING: key file has no trailing newline")
# show the neighbouring .ssh entries for the mode argument
for l in lines:
    if "/root/.ssh" in l or l.startswith("/root "):
        print("  related: " + l)
PYEOF

# --------------------------------------------------------------- compare
echo "== results"
if [ ! -s "${TMP}/extracted.pub" ]; then
	echo "FAIL: authorized_keys missing from the packaged initramfs"
	exit 1
fi

SRC_FP=$(ssh-keygen -lf "${SRC}" | awk '{print $2}')
DST_FP=$(ssh-keygen -lf "${TMP}/extracted.pub" | awk '{print $2}')
echo "  src fingerprint:        ${SRC_FP}"
echo "  packaged fingerprint:   ${DST_FP}"
RC=0
if [ "${SRC_FP}" = "${DST_FP}" ]; then
	echo "PASS: fingerprint of the packaged authorized_keys matches the source public key"
else
	echo "FAIL: fingerprint mismatch"
	RC=1
fi

MODE_LINE=$(python3 - "${TMP}/initramfs.cpio" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
pos = 0
while pos + 110 <= len(data):
    if data[pos:pos + 6] not in (b"070701", b"070702"):
        break
    hdr = data[pos:pos + 110]
    f = [hdr[6 + 8 * i:14 + 8 * i].decode("ascii") for i in range(13)]
    mode = int(f[1], 16)
    filesize = int(f[6], 16)
    namesize = int(f[11], 16)
    name_off = pos + 110
    name = data[name_off:name_off + namesize - 1].decode("utf-8", "replace")
    hdr_end = (name_off + namesize + 3) & ~3
    if name == "TRAILER!!!":
        break
    if name.lstrip("/") == "root/.ssh/authorized_keys":
        print("%06o %d" % (mode & 0o777777, mode >> 12))
        sys.exit(0)
    pos = (hdr_end + filesize + 3) & ~3
print("missing")
sys.exit(0)
PYEOF
)
MODE=${MODE_LINE% *}
FTYPE=${MODE_LINE#* }
# mode 100600: S_IFREG (100000) + 0600; S_IFREG >> 12 == 8
if [ "${MODE}" = "100600" ] && [ "${FTYPE}" = "8" ]; then
	echo "PASS: packaged authorized_keys is a regular file (S_IFREG) with mode 0600"
else
	echo "FAIL: packaged authorized_keys mode/type is '${MODE_LINE}' (want 100600 / type 8=regular)"
	RC=1
fi

exit "${RC}"
