#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Package the c2s rescue build into a boot image that the stock c2s
# bootloader (sboot) accepts, i.e. an Android boot image v2 with the same
# geometry the shipped boot.img / TWRP recovery.img use:
#
#   header version   2
#   page size        2048
#   kernel load      0x10008000   (base 0x10000000 + offset 0x8000)
#   ramdisk load     0x11000000
#   tags load        0x10000100
#   dtb              wrapped in a Samsung DT table (magic 0xd7b7ab1e,
#                    header/entry 0x20 each, 1 entry custom [0,0xff,0,0],
#                    FDT at +0x40) - sboot rejects a bare FDT in the dt
#                    slot with "[DTH] dt table header check Fail"
#
# The image is built exactly like the TWRP recovery image that is
# already proven to boot on this device (see the device notes):
#   - os_version 11.0.0 and os_patch_level 2025-08 (the security patch
#     level the installed vbmeta expects),
#   - a product name in the Samsung "SRPTB27CxxxU" scheme,
#   - an AVB hash footer (SHA256_RSA4096, rollback index 13) that matches
#     the installed vbmeta descriptor set.
#
# The AVB footer is signed with the *host* key that signed the installed
# vbmeta. That key is NOT part of this repository: it is passed in via
# C2S_AVB_KEY and stays on the build host.
#
# Usage:
#   c2s-rescue/scripts/package-bootimg.sh [--outdir DIR] [--name NAME]
#
# Exit code 0 means: a boot.img was written and verified with avbtool.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RESCUE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
REPO_DIR=$(cd -- "${RESCUE_DIR}/.." && pwd)

OUTDIR="${C2S_OUTDIR:-/tmp/opencode/c2s-out}"
BOOT_NAME="${C2S_BOOT_NAME:-SRPTB27C018RU}"
OS_VERSION="${C2S_OS_VERSION:-11.0.0}"
OS_PATCH_LEVEL="${C2S_OS_PATCH_LEVEL:-2025-08}"
ROLLBACK_INDEX="${C2S_ROLLBACK_INDEX:-13}"
# The boot partition is 61865984 bytes (15104 * 4096); the AVB footer
# lives in the tail of the partition, the image itself is padded to the
# partition size.
PARTITION_SIZE="${C2S_PARTITION_SIZE:-61865984}"
CMDLINE="${C2S_CMDLINE:-androidboot.hardware=exynos990 androidboot.selinux=permissive loop.max_part=7}"

AVBTOOL="${C2S_AVBTOOL:-/home/gregor/.local/var/pmbootstrap/chroot_native/usr/bin/avbtool}"

while [ $# -gt 0 ]; do
	case "$1" in
	--outdir) OUTDIR="$2"; shift 2 ;;
	--name)   BOOT_NAME="$2"; shift 2 ;;
	-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

KBUILD="${OUTDIR}/kbuild"
IMAGE="${KBUILD}/arch/arm64/boot/Image"
DTB="${KBUILD}/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb"
RAMDISK="${OUTDIR}/work/initramfs.cpio.gz"
OUT="${OUTDIR}/boot.img"

for f in "${IMAGE}" "${DTB}" "${RAMDISK}"; do
	if [ ! -s "$f" ]; then
		echo "missing build artifact: $f" >&2
		echo "run c2s-rescue/scripts/build.sh --outdir ${OUTDIR} first" >&2
		exit 1
	fi
done
if [ ! -x "${AVBTOOL}" ]; then
	echo "avbtool not found at ${AVBTOOL} (set C2S_AVBTOOL)" >&2
	exit 1
fi

mkdir -p "${OUTDIR}"

echo "kernel:   ${IMAGE} ($(stat -c %s "${IMAGE}") bytes)"
echo "ramdisk:  ${RAMDISK} ($(stat -c %s "${RAMDISK}") bytes)"
echo "dtb:      ${DTB} ($(stat -c %s "${DTB}") bytes)"

# ------------------------------------------------------------ boot image
# The kernel Image is an arm64 Image (64-byte header, "ARM\x64"). The
# stock bootloader expects it at text_offset 0x80000 from the 2 MB
# aligned base 0x10000000, which is exactly what header_version 2 with
# --base 0x10000000 --kernel_offset 0x8000 encodes.
#
# The DT payload is NOT a bare FDT: sboot (f958c -> f9338) reads the dt
# slot of the boot image and checks the *Samsung DT table header*
# (magic 0xd7b7ab1e, see f9824 "[DTH] dt table header check Fail").
# The installed stock boot.img carries exactly that wrapper (verified at
# offset 40280064 in the backup: header 0x20, entry_size 0x20,
# entries_offset 0x20, page_size 0x800, one entry id 0 / rev 0 /
# custom [0,0xff,0,0], FDT at +0x40), as does the proven TWRP
# recovery.img (57298944, same template). A bare FDT in this slot is
# rejected with FDT_ERR_BADMAGIC, which is the failure mode seen on the
# device for the raw-FDT candidate.
echo "== building Samsung DT table wrapper"
DT_TABLE="${OUTDIR}/dt-table.bin"
python3 - "${DTB}" "${DT_TABLE}" <<'PYEOF'
import struct, sys

dtb_path, out_path = sys.argv[1], sys.argv[2]
fdt = open(dtb_path, "rb").read()
if struct.unpack(">I", fdt[:4])[0] != 0xD00DFEED:
    sys.exit("input is not a FDT (bad magic)")

HEADER_SIZE = 0x20
ENTRY_SIZE = 0x20
FDT_OFFSET = HEADER_SIZE + ENTRY_SIZE  # 0x40, matches stock exactly
total = FDT_OFFSET + len(fdt)

header = struct.pack(">8I",
                     0xD7B7AB1E,   # magic: DT table header
                     total,        # total_size: header + entry + fdt
                     HEADER_SIZE,  # header_size
                     ENTRY_SIZE,   # entry_size
                     1,            # dt_entry_count
                     HEADER_SIZE,  # dt_entries_offset
                     0x800,        # page_size (2048, boot image page)
                     0)            # version
entry = struct.pack(">8I",
                    len(fdt),      # dt_size
                    FDT_OFFSET,    # dt_offset (from table start)
                    0,             # device id
                    0,             # rev
                    0, 0xFF, 0, 0) # custom [0, 0xff, 0, 0]

with open(out_path, "wb") as f:
    f.write(header + entry + fdt)

print("dt-table:  %s (%d bytes = 0x%x header + 0x%x entry + %d fdt)"
      % (out_path, total, HEADER_SIZE, ENTRY_SIZE, len(fdt)))
PYEOF

echo "== building boot image"
mkbootimg \
	--kernel "${IMAGE}" \
	--ramdisk "${RAMDISK}" \
	--dtb "${DT_TABLE}" \
	--cmdline "${CMDLINE}" \
	--os_version "${OS_VERSION}" \
	--os_patch_level "${OS_PATCH_LEVEL}" \
	--header_version 2 \
	--pagesize 2048 \
	--base 0x10000000 \
	--kernel_offset 0x8000 \
	--ramdisk_offset 0x01000000 \
	--tags_offset 0x00000100 \
	--dtb_offset 0x00000000 \
	--board "${BOOT_NAME}" \
	-o "${OUTDIR}/boot-unsigned.img"

echo "== adding AVB hash footer"
# The footer is added with the host key that signed the installed
# vbmeta (rollback index 13). Without it sboot refuses the image.
if [ -n "${C2S_AVB_KEY:-}" ] && [ -f "${C2S_AVB_KEY}" ]; then
	"${AVBTOOL}" add_hash_footer \
		--image "${OUTDIR}/boot-unsigned.img" \
		--partition_size "${PARTITION_SIZE}" \
		--partition_name boot \
		--algorithm SHA256_RSA4096 \
		--key "${C2S_AVB_KEY}" \
		--rollback_index "${ROLLBACK_INDEX}"
else
	echo "NOTE: no C2S_AVB_KEY given; adding an unsigned (algorithm NONE)"
	echo "      footer. The result will NOT boot on a device with AVB"
	echo "      enabled - it is only useful for format inspection."
	"${AVBTOOL}" add_hash_footer \
		--image "${OUTDIR}/boot-unsigned.img" \
		--partition_size "${PARTITION_SIZE}" \
		--partition_name boot \
		--algorithm NONE \
		--rollback_index "${ROLLBACK_INDEX}"
fi

# avbtool rewrites the image in place: it pads it to the partition size
# and appends the footer. The result is the deliverable boot.img.
test -f "${OUTDIR}/boot-unsigned.img" || { echo "boot-unsigned.img vanished" >&2; exit 1; }
mv -f "${OUTDIR}/boot-unsigned.img" "${OUT}"

echo "== verifying"
"${AVBTOOL}" verify_image --image "${OUT}"

# Independent DT-table sanity check: parse the dt slot of the finished
# image at the exact offset sboot computes (payload_base + aligned
# kernel + aligned ramdisk + 0x1000, where payload_base = image + page
# size), then compare the wrapped FDT byte-for-byte against the kbuild
# DTB. This is what would have caught the raw-FDT defect.
echo "== verifying Samsung DT table in the packed image"
python3 - "${OUT}" "${DTB}" <<'PYEOF'
import struct, sys

img_path, dtb_path = sys.argv[1], sys.argv[2]
img = open(img_path, "rb").read()
if img[:8] != b"ANDROID!":
    sys.exit("not an Android boot image")
page_size = struct.unpack("<I", img[36:40])[0]
kernel_size = struct.unpack("<I", img[8:12])[0]
ramdisk_size = struct.unpack("<I", img[16:20])[0]

def align_up(v, a):
    return (v + a - 1) & ~(a - 1)

off = page_size + align_up(kernel_size, page_size) \
    + align_up(ramdisk_size, page_size)
if off + 0x40 > len(img):
    sys.exit("dt slot offset %d beyond image size %d" % (off, len(img)))

hdr = struct.unpack(">8I", img[off:off + 0x20])
magic, total, hsize, esize, count, eoff, page, ver = hdr
if magic != 0xD7B7AB1E:
    sys.exit("dt table magic %#x != 0xD7B7AB1E at offset %d (raw FDT?)"
             % (magic, off))
if (hsize, esize, eoff, count, page) != (0x20, 0x20, 0x20, 1, 0x800):
    sys.exit("unexpected dt table header fields: %s" % (hdr,))
if off + total > len(img):
    sys.exit("dt table total_size %d exceeds image" % total)

ent = struct.unpack(">8I", img[off + 0x20:off + 0x40])
dt_size, dt_offset, dev_id, rev, c0, c1, c2, c3 = ent
if dt_size != total - 0x40 or dt_offset != 0x40:
    sys.exit("unexpected dt entry: %s" % (ent,))
if (dev_id, rev, c0, c1, c2, c3) != (0, 0, 0, 0xFF, 0, 0):
    sys.exit("unexpected dt entry id/rev/custom: %s" % (ent,))

fdt = img[off + 0x40:off + 0x40 + dt_size]
ref = open(dtb_path, "rb").read()
if fdt != ref:
    sys.exit("wrapped FDT differs from the kbuild DTB")
print("dt-table ok: at +%d, magic %#x, total %#x, entry custom [0,0xff,0,0],"
      " FDT %d bytes == kbuild DTB" % (off, magic, total, dt_size))
PYEOF

{
	echo "boot.img: ${OUT}"
	echo "  size:    $(stat -c %s "${OUT}") bytes"
	echo "  sha256:  $(sha256sum "${OUT}" | cut -d' ' -f1)"
	echo "  name:    ${BOOT_NAME}"
	echo "  os:      ${OS_VERSION} / patch ${OS_PATCH_LEVEL}"
	echo "  rollback: ${ROLLBACK_INDEX}"
	echo "  dt slot: Samsung DT table (magic 0xd7b7ab1e), 1 entry," \
		"custom [0,0xff,0,0], FDT at +0x40; wrapper + packed image" \
		"verified"
} | tee "${OUTDIR}/bootimg-record.txt"
