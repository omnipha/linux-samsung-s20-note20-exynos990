#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Host-side test and fault-injection harness for c2s-blockmap and c2s-flash-boot.
#
# Tests both tools against a fake sysfs, devtmpfs, and /run tmpfs directory
# tree, exercising positive controls and all required negative controls:
#   1. blockmap: creates /dev/block/by-name symlinks matching PARTNAME from uevent
#   2. flash-boot positive control: valid hash + size, saves backup to /run,
#      writes with dd, verifies readback hash, returns 0 / OK
#   3. negative control: wrong image hash -> refused, partition unchanged
#   4. negative control: wrong image size -> refused, partition unchanged
#   5. negative control: wrong partition name -> refused, non-boot untouched
#   6. negative control: short readback -> detected and failed
#   7. negative control: insufficient RAM for backup -> refused, partition untouched
#
# Usage: c2s-rescue/scripts/test-flash-boot.sh [OUTDIR]

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RESCUE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
OUTDIR="${1:-${C2S_OUTDIR:-/tmp/opencode/c2s-out}}"
UNPACK="${OUTDIR}/verify-root"

PASS=0
FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# Prefer the shipped unpacked files if available, otherwise the source tree files.
if [ -s "${UNPACK}/usr/sbin/c2s-blockmap" ]; then
    BLOCKMAP_BIN="${UNPACK}/usr/sbin/c2s-blockmap"
    FLASH_BIN="${UNPACK}/usr/sbin/c2s-flash-boot"
    echo "### testing shipped binaries from unpacked initramfs"
else
    BLOCKMAP_BIN="${RESCUE_DIR}/initramfs/usr/sbin/c2s-blockmap"
    FLASH_BIN="${RESCUE_DIR}/initramfs/usr/sbin/c2s-flash-boot"
    echo "### testing source tree scripts"
fi

if [ ! -f "${BLOCKMAP_BIN}" ] || [ ! -f "${FLASH_BIN}" ]; then
    echo "FAIL: tools not found: ${BLOCKMAP_BIN} or ${FLASH_BIN}" >&2
    exit 1
fi

TMP=$(mktemp -d /tmp/opencode/c2s-flash-test.XXXXXX)
trap 'rm -rf "${TMP}"' EXIT

FAKE_SYS="${TMP}/sys"
FAKE_DEV="${TMP}/dev"
FAKE_RUN="${TMP}/run"

mkdir -p "${FAKE_SYS}/class/block" "${FAKE_DEV}/block/by-name" "${FAKE_RUN}"

# Set up fake partition layout:
# sda (whole disk), sda1 (PARTNAME=sec_efs), sda2 (PARTNAME=boot), sda3 (PARTNAME=recovery)
setup_fake_layout() {
    rm -rf "${FAKE_SYS}/class/block"/* "${FAKE_DEV}"/* "${FAKE_RUN}"/*
    mkdir -p "${FAKE_SYS}/class/block/sda" \
             "${FAKE_SYS}/class/block/sda1" \
             "${FAKE_SYS}/class/block/sda2" \
             "${FAKE_SYS}/class/block/sda3" \
             "${FAKE_DEV}/block/by-name" \
             "${FAKE_RUN}"

    # sda
    cat << 'EOF' > "${FAKE_SYS}/class/block/sda/uevent"
MAJOR=8
MINOR=0
DEVNAME=sda
DEVTYPE=disk
EOF
    echo 262144 > "${FAKE_SYS}/class/block/sda/size"
    : > "${FAKE_DEV}/sda"

    # sda1: sec_efs (4096 bytes = 8 sectors)
    cat << 'EOF' > "${FAKE_SYS}/class/block/sda1/uevent"
MAJOR=8
MINOR=1
DEVNAME=sda1
DEVTYPE=partition
PARTN=1
PARTNAME=sec_efs
EOF
    echo 8 > "${FAKE_SYS}/class/block/sda1/size"
    dd if=/dev/zero of="${FAKE_DEV}/sda1" bs=512 count=8 status=none

    # sda2: boot (8192 bytes = 16 sectors)
    cat << 'EOF' > "${FAKE_SYS}/class/block/sda2/uevent"
MAJOR=8
MINOR=2
DEVNAME=sda2
DEVTYPE=partition
PARTN=2
PARTNAME=boot
EOF
    echo 16 > "${FAKE_SYS}/class/block/sda2/size"
    # initial contents: filled with 0xAA
    python3 -c 'import sys; sys.stdout.buffer.write(b"\xaa" * 8192)' > "${FAKE_DEV}/sda2"

    # sda3: recovery (8192 bytes = 16 sectors)
    cat << 'EOF' > "${FAKE_SYS}/class/block/sda3/uevent"
MAJOR=8
MINOR=3
DEVNAME=sda3
DEVTYPE=partition
PARTN=3
PARTNAME=recovery
EOF
    echo 16 > "${FAKE_SYS}/class/block/sda3/size"
    python3 -c 'import sys; sys.stdout.buffer.write(b"\xbb" * 8192)' > "${FAKE_DEV}/sda3"
}

# ------------------------------------------------------------- 1. c2s-blockmap
setup_fake_layout
MAP_OUT=$(C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" /bin/sh "${BLOCKMAP_BIN}" 2>&1)
if [ -L "${FAKE_DEV}/block/by-name/boot" ] \
   && [ "$(readlink "${FAKE_DEV}/block/by-name/boot")" = "${FAKE_DEV}/sda2" ]; then
    ok "blockmap: created by-name/boot -> /dev/sda2"
else
    bad "blockmap: by-name/boot missing or points to wrong target"
fi

if [ -L "${FAKE_DEV}/block/by-name/recovery" ] \
   && [ "$(readlink "${FAKE_DEV}/block/by-name/recovery")" = "${FAKE_DEV}/sda3" ] \
   && [ -L "${FAKE_DEV}/block/by-name/sec_efs" ]; then
    ok "blockmap: created by-name/recovery and by-name/sec_efs correctly"
else
    bad "blockmap: missing expected partition symlinks"
fi

# ------------------------------------------------ 2. flash-boot: positive control
# Generate a new valid boot image of exactly 8192 bytes
NEW_BOOT_IMG="${TMP}/new_boot.img"
python3 -c 'import sys; sys.stdout.buffer.write(b"\x55" * 8192)' > "${NEW_BOOT_IMG}"
NEW_BOOT_HASH=$(sha256sum "${NEW_BOOT_IMG}" | awk '{print $1}')
INITIAL_BOOT_HASH=$(sha256sum "${FAKE_DEV}/sda2" | awk '{print $1}')

FLASH_OUT=$(C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" C2S_RUN_DIR="${FAKE_RUN}" \
    /bin/sh "${FLASH_BIN}" "${NEW_BOOT_IMG}" "${NEW_BOOT_HASH}" 2>&1)
FLASH_RC=$?

if [ "${FLASH_RC}" -eq 0 ] && printf '%s\n' "${FLASH_OUT}" | grep -q "OK: successfully flashed"; then
    ok "flash-boot positive control: exit code 0 and OK printed"
else
    bad "flash-boot positive control failed (rc=${FLASH_RC}): ${FLASH_OUT}"
fi

# Verify backup was created with the initial contents
if [ -f "${FAKE_RUN}/boot-backup.img" ] \
   && [ "$(sha256sum "${FAKE_RUN}/boot-backup.img" | awk '{print $1}')" = "${INITIAL_BOOT_HASH}" ]; then
    ok "flash-boot positive control: backup saved to /run with original partition contents"
else
    bad "flash-boot positive control: backup missing or hash mismatch"
fi

# Verify partition actually has the new contents
if [ "$(sha256sum "${FAKE_DEV}/sda2" | awk '{print $1}')" = "${NEW_BOOT_HASH}" ]; then
    ok "flash-boot positive control: partition storage verified with new image contents"
else
    bad "flash-boot positive control: partition storage content does not match image"
fi

# ------------------------------------------------ 3. negative control: wrong hash
setup_fake_layout
MAP_OUT=$(C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" /bin/sh "${BLOCKMAP_BIN}" 2>&1)
WRONG_HASH="0000000000000000000000000000000000000000000000000000000000000000"
NEG_HASH_OUT=$(C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" C2S_RUN_DIR="${FAKE_RUN}" \
    /bin/sh "${FLASH_BIN}" "${NEW_BOOT_IMG}" "${WRONG_HASH}" 2>&1 || true)
if printf '%s\n' "${NEG_HASH_OUT}" | grep -q "FAIL: image sha256 mismatch"; then
    ok "flash-boot negative control: wrong hash refused with FAIL"
else
    bad "flash-boot negative control: wrong hash was not rejected: ${NEG_HASH_OUT}"
fi
if [ "$(sha256sum "${FAKE_DEV}/sda2" | awk '{print $1}')" = "${INITIAL_BOOT_HASH}" ]; then
    ok "flash-boot negative control: wrong hash left partition untouched"
else
    bad "flash-boot negative control: wrong hash modified the partition"
fi

# ------------------------------------------------ 4. negative control: wrong size
setup_fake_layout
MAP_OUT=$(C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" /bin/sh "${BLOCKMAP_BIN}" 2>&1)
SHORT_IMG="${TMP}/short_boot.img"
python3 -c 'import sys; sys.stdout.buffer.write(b"\x55" * 4096)' > "${SHORT_IMG}"
SHORT_HASH=$(sha256sum "${SHORT_IMG}" | awk '{print $1}')
NEG_SIZE_OUT=$(C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" C2S_RUN_DIR="${FAKE_RUN}" \
    /bin/sh "${FLASH_BIN}" "${SHORT_IMG}" "${SHORT_HASH}" 2>&1 || true)
if printf '%s\n' "${NEG_SIZE_OUT}" | grep -q "FAIL: size mismatch"; then
    ok "flash-boot negative control: wrong size refused with FAIL"
else
    bad "flash-boot negative control: wrong size was not rejected: ${NEG_SIZE_OUT}"
fi
if [ "$(sha256sum "${FAKE_DEV}/sda2" | awk '{print $1}')" = "${INITIAL_BOOT_HASH}" ]; then
    ok "flash-boot negative control: wrong size left partition untouched"
else
    bad "flash-boot negative control: wrong size modified the partition"
fi

# -------------------------------------- 5. negative control: wrong partition name
# Target by-name/boot pointed at /dev/sda3 (which has PARTNAME=recovery)
setup_fake_layout
ln -sf "${FAKE_DEV}/sda3" "${FAKE_DEV}/block/by-name/boot"
NEG_PART_OUT=$(C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" C2S_RUN_DIR="${FAKE_RUN}" \
    /bin/sh "${FLASH_BIN}" "${NEW_BOOT_IMG}" "${NEW_BOOT_HASH}" 2>&1 || true)
if printf '%s\n' "${NEG_PART_OUT}" | grep -q "FAIL: target partition name 'recovery' is not 'boot'"; then
    ok "flash-boot negative control: non-boot partition name refused with FAIL"
else
    bad "flash-boot negative control: non-boot partition name was not rejected: ${NEG_PART_OUT}"
fi
if [ "$(sha256sum "${FAKE_DEV}/sda3" | awk '{print $1}')" = "$(python3 -c 'import sys; sys.stdout.buffer.write(b"\xbb" * 8192)' | sha256sum | awk '{print $1}')" ]; then
    ok "flash-boot negative control: non-boot partition left untouched"
else
    bad "flash-boot negative control: non-boot partition was overwritten"
fi

# ---------------------------------------------- 6. negative control: short readback
# Simulate a device that returns fewer bytes than PART_SIZE on readback
setup_fake_layout
MAP_OUT=$(C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" /bin/sh "${BLOCKMAP_BIN}" 2>&1)
python3 -c 'import sys; sys.stdout.buffer.write(b"\x55" * 8192)' > "${NEW_BOOT_IMG}"
NEW_BOOT_HASH=$(sha256sum "${NEW_BOOT_IMG}" | awk '{print $1}')

NEG_RB_OUT=$(
    PATH="${TMP}/mockrb:${PATH}"
    mkdir -p "${TMP}/mockrb"
    # Mock head to return a truncated stream on readback
    cat << 'MOCK' > "${TMP}/mockrb/head"
#!/bin/sh
for last; do :; done
exec /usr/bin/head -c 4096 "$last"
MOCK
    chmod +x "${TMP}/mockrb/head"
    C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" C2S_RUN_DIR="${FAKE_RUN}" \
        /bin/sh "${FLASH_BIN}" "${NEW_BOOT_IMG}" "${NEW_BOOT_HASH}" 2>&1 || true
)
if printf '%s\n' "${NEG_RB_OUT}" | grep -q "FAIL: short readback"; then
    ok "flash-boot negative control: short readback detected with FAIL"
else
    bad "flash-boot negative control: short readback was not rejected: ${NEG_RB_OUT}"
fi

# ---------------------------------- 7. negative control: insufficient RAM in /run
setup_fake_layout
MAP_OUT=$(C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" /bin/sh "${BLOCKMAP_BIN}" 2>&1)
python3 -c 'import sys; sys.stdout.buffer.write(b"\x55" * 8192)' > "${NEW_BOOT_IMG}"
NEW_BOOT_HASH=$(sha256sum "${NEW_BOOT_IMG}" | awk '{print $1}')
# Create a mock df that reports 0 available space
NEG_RAM_OUT=$(
    PATH="${TMP}/mockdf:${PATH}"
    mkdir -p "${TMP}/mockdf"
    cat << 'MOCK' > "${TMP}/mockdf/df"
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "tmpfs           1000 1000         0 100% /run"
MOCK
    chmod +x "${TMP}/mockdf/df"
    C2S_SYSFS_DIR="${FAKE_SYS}" C2S_DEV_DIR="${FAKE_DEV}" C2S_RUN_DIR="${FAKE_RUN}" \
        /bin/sh "${FLASH_BIN}" "${NEW_BOOT_IMG}" "${NEW_BOOT_HASH}" 2>&1 || true
)
if printf '%s\n' "${NEG_RAM_OUT}" | grep -q "FAIL: insufficient RAM in"; then
    ok "flash-boot negative control: insufficient RAM refused with explicit FAIL"
else
    bad "flash-boot negative control: insufficient RAM was not rejected: ${NEG_RAM_OUT}"
fi
if [ "$(sha256sum "${FAKE_DEV}/sda2" | awk '{print $1}')" = "${INITIAL_BOOT_HASH}" ]; then
    ok "flash-boot negative control: insufficient RAM left partition untouched"
else
    bad "flash-boot negative control: insufficient RAM modified the partition"
fi

echo
echo "flash-boot-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
