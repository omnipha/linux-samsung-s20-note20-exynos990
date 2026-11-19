#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build the c2s rescue kernel image, the c2s device tree and the matching
# initramfs.
#
# Everything that is not part of the kernel tree itself (busybox, dropbear,
# the staged root filesystem, the generated cpio) is created outside of the
# repository, so the checkout stays free of binaries and of foreign code.
#
# Usage:
#   c2s-rescue/scripts/build.sh [--outdir DIR] [--jobs N]
#
# Exit code 0 means: Image, DTB and initramfs were built and recorded.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RESCUE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
REPO_DIR=$(cd -- "${RESCUE_DIR}/.." && pwd)

OUTDIR="${C2S_OUTDIR:-/tmp/opencode/c2s-out}"
JOBS="$(nproc 2>/dev/null || echo 4)"

# External, redistributable binary dependencies. They are *not* part of this
# repository; the expected SHA-256 sums are verified before use.
DROPBEAR_TARBALL="${C2S_DROPBEAR_TARBALL:-/home/gregor/sm7635-build/dropbear-2026.94.tar.bz2}"
DROPBEAR_SHA256="e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81"
BUSYBOX_DEB="${C2S_BUSYBOX_DEB:-/home/gregor/sm7635-build/busybox-static_1.37.0-7ubuntu1_arm64.deb}"
BUSYBOX_SHA256="fcf50794faf920455895d7ef103d1c54b9ebf7f18d2e52982dbf3903b7769592"

while [ $# -gt 0 ]; do
	case "$1" in
	--outdir) OUTDIR="$2"; shift 2 ;;
	--jobs)   JOBS="$2";   shift 2 ;;
	-h|--help)
		sed -n '2,20p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

LOG="${OUTDIR}/build.log"
mkdir -p "${OUTDIR}"
: > "${LOG}"

# Every step records its command, its exit code and (where useful) the size
# and SHA-256 of the result, so the build can be reproduced and audited.
step() {
	echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) :: $*" | tee -a "${LOG}"
}

run() {
	local desc="$1"; shift
	echo "+ $*" | tee -a "${LOG}"
	set +e
	"$@" >> "${LOG}" 2>&1
	local rc=$?
	set -e
	echo "--- exit ${rc}: ${desc}" | tee -a "${LOG}"
	if [ "${rc}" -ne 0 ]; then
		echo "FAILED: ${desc} (see ${LOG})" >&2
		exit "${rc}"
	fi
	return 0
}

sha256_of() {
	sha256sum "$1" | cut -d' ' -f1
}

# ---------------------------------------------------------------- toolchain
step "environment"
{
	echo "date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "repo:        ${REPO_DIR}"
	echo "git rev:     $(git -C "${REPO_DIR}" rev-parse HEAD)"
	echo "git describe: $(git -C "${REPO_DIR}" describe --always --dirty 2>/dev/null || echo unknown)"
	echo "host:        $(uname -srm)"
	echo "gcc:         $(aarch64-linux-gnu-gcc --version | head -n1)"
	echo "make:        $(make --version | head -n1)"
	echo "gzip:        $(gzip --version | head -n1)"
	echo "cpio:        $(cpio --version | head -n1)"
	echo "dtc:         $(dtc --version)"
	echo "out dir:     ${OUTDIR}"
	echo "jobs:        ${JOBS}"
} | tee -a "${LOG}"

# ------------------------------------------------------------- dependencies
step "verifying external dependencies"
for f in "${DROPBEAR_TARBALL}" "${BUSYBOX_DEB}"; do
	if [ ! -f "$f" ]; then
		echo "missing external dependency: $f" >&2
		exit 1
	fi
done
echo "${DROPBEAR_SHA256}  ${DROPBEAR_TARBALL}" | sha256sum -c - | tee -a "${LOG}"
echo "${BUSYBOX_SHA256}  ${BUSYBOX_DEB}" | sha256sum -c - | tee -a "${LOG}"

WORK="${OUTDIR}/work"
rm -rf "${WORK}"
mkdir -p "${WORK}"

# ------------------------------------------------------------------ busybox
step "extracting busybox (arm64, static)"
run "busybox dpkg-deb -x" dpkg-deb -x "${BUSYBOX_DEB}" "${WORK}/busybox"
BUSYBOX_SRC="${WORK}/busybox/usr/bin/busybox"
if [ ! -x "${BUSYBOX_SRC}" ]; then
	echo "busybox not found at ${BUSYBOX_SRC}" >&2
	exit 1
fi
echo "busybox sha256: $(sha256_of "${BUSYBOX_SRC}")" | tee -a "${LOG}"
file "${BUSYBOX_SRC}" | tee -a "${LOG}"

# ---------------------------------------------------------------- dropbear
step "building dropbear (aarch64, static, pubkey-only)"
mkdir -p "${WORK}/dropbear-src"
run "dropbear untar" tar -xf "${DROPBEAR_TARBALL}" -C "${WORK}/dropbear-src" --strip-components=1
cp "${RESCUE_DIR}/dropbear/localoptions.h" "${WORK}/dropbear-src/localoptions.h"
(
	cd "${WORK}/dropbear-src"
	./configure \
		--host=aarch64-linux-gnu \
		--prefix=/usr \
		--enable-static \
		--disable-zlib \
		--disable-utmp
	make PROGRAMS="dropbear dropbearkey"
) >> "${LOG}" 2>&1 || { echo "FAILED: dropbear build" >&2; exit 1; }
DROPBEAR_BIN="${WORK}/dropbear-src/dropbear"
DROPBEARKEY_BIN="${WORK}/dropbear-src/dropbearkey"
echo "dropbear sha256:    $(sha256_of "${DROPBEAR_BIN}")" | tee -a "${LOG}"
echo "dropbearkey sha256: $(sha256_of "${DROPBEARKEY_BIN}")" | tee -a "${LOG}"
file "${DROPBEAR_BIN}" | tee -a "${LOG}"

# ----------------------------------------------------- rescue-menu-keys
# The boot menu input front end is a small static aarch64 C program: it
# keeps every gpio-keys evdev device and the USB ACM serial line open in
# one persistent poll loop (the shell variant re-opened the device for
# every read, which loses queued evdev events - the keys looked dead),
# handles raw tty/no-echo and the press/release/repeat semantics.
step "building rescue-menu-keys (aarch64, static)"
KEYS_SRC="${RESCUE_DIR}/src/rescue-menu-keys.c"
if [ ! -f "${KEYS_SRC}" ]; then
	echo "missing source: ${KEYS_SRC}" >&2
	exit 1
fi
run "rescue-menu-keys compile" aarch64-linux-gnu-gcc \
	-O2 -Wall -Wextra -static -s \
	-o "${WORK}/rescue-menu-keys" "${KEYS_SRC}"
echo "rescue-menu-keys sha256: $(sha256_of "${WORK}/rescue-menu-keys")" | tee -a "${LOG}"
file "${WORK}/rescue-menu-keys" | tee -a "${LOG}"

# ------------------------------------------------------------- root staging
ROOT="${WORK}/root"
mkdir -p "${ROOT}/bin" "${ROOT}/sbin" "${ROOT}/usr/bin" "${ROOT}/usr/sbin" \
         "${ROOT}/etc" "${ROOT}/root/.ssh" "${ROOT}/dev" "${ROOT}/proc" \
         "${ROOT}/sys" "${ROOT}/tmp" "${ROOT}/run" "${ROOT}/sys/kernel/config"

# busybox: the binary plus the applet symlinks we actually use
cp "${BUSYBOX_SRC}" "${ROOT}/bin/busybox"
chmod 0755 "${ROOT}/bin/busybox"
APPLETS="sh ash mount umount mkdir rmdir mknod ln ls cat cp mv rm dmesg sleep \
hostname ip ifconfig route grep sed awk vi less more head tail cut tr sort \
kill killall pidof ps top setsid cttyhack telnet telnetd udhcpc udhcpd nc \
netstat sysctl login passwd printf test chmod chown stat dd tar gzip gunzip \
uname env date echo expr find xargs tee touch which timeout od"
for a in ${APPLETS}; do
	ln -sf /bin/busybox "${ROOT}/bin/${a}"
done
ln -sf /bin/busybox "${ROOT}/sbin/init"

# dropbear
cp "${DROPBEAR_BIN}" "${ROOT}/usr/sbin/dropbear"
cp "${DROPBEARKEY_BIN}" "${ROOT}/usr/bin/dropbearkey"
chmod 0755 "${ROOT}/usr/sbin/dropbear" "${ROOT}/usr/bin/dropbearkey"

# configuration and account files
cp "${RESCUE_DIR}/initramfs/init" "${ROOT}/init"
chmod 0755 "${ROOT}/init"
cp "${RESCUE_DIR}/initramfs/etc/passwd" "${ROOT}/etc/passwd"
cp "${RESCUE_DIR}/initramfs/etc/group" "${ROOT}/etc/group"
cp "${RESCUE_DIR}/initramfs/etc/shells" "${ROOT}/etc/shells"
cp "${RESCUE_DIR}/initramfs/etc/issue" "${ROOT}/etc/issue"
cp "${RESCUE_DIR}/initramfs/etc/rescue.conf" "${ROOT}/etc/rescue.conf"
mkdir -p "${ROOT}/usr/bin"
cp "${RESCUE_DIR}/initramfs/usr/bin/rescue-telnet" "${ROOT}/usr/bin/rescue-telnet"
chmod 0755 "${ROOT}/usr/bin/rescue-telnet"
cp "${RESCUE_DIR}/initramfs/usr/bin/rescue-menu" "${ROOT}/usr/bin/rescue-menu"
chmod 0755 "${ROOT}/usr/bin/rescue-menu"
cp "${WORK}/rescue-menu-keys" "${ROOT}/usr/bin/rescue-menu-keys"
chmod 0755 "${ROOT}/usr/bin/rescue-menu-keys"
chmod 0644 "${ROOT}/etc/rescue.conf" "${ROOT}/etc/issue" "${ROOT}/etc/shells"

# SSH host keys are generated on the device at first boot (-R); the operator's
# public key is the only credential. The public key is *not* part of this
# repository: the operator installs it into the staged rootfs at build time
# via C2S_AUTHORIZED_KEYS, or copies it in afterwards.
AUTHKEYS="${C2S_AUTHORIZED_KEYS:-}"
if [ -n "${AUTHKEYS}" ] && [ -f "${AUTHKEYS}" ]; then
	cp "${AUTHKEYS}" "${ROOT}/root/.ssh/authorized_keys"
	chmod 0600 "${ROOT}/root/.ssh/authorized_keys"
	echo "authorized_keys installed from ${AUTHKEYS}" | tee -a "${LOG}"
else
	echo "NOTE: no C2S_AUTHORIZED_KEYS given; the initramfs ships without" | tee -a "${LOG}"
	echo "      an authorized_keys file, so dropbear will not start until" | tee -a "${LOG}"
	echo "      the operator adds one. See c2s-rescue/docs/boot-and-open-points.md" | tee -a "${LOG}"
fi
chmod 0700 "${ROOT}/root" "${ROOT}/root/.ssh"

# ------------------------------------------------------------- cpio list
step "generating initramfs cpio list"
LIST="${WORK}/cpio.list"
{
	echo "# c2s rescue initramfs (generated by c2s-rescue/scripts/build.sh)"
	echo "dir /bin 0755 0 0"
	echo "dir /sbin 0755 0 0"
	echo "dir /usr 0755 0 0"
	echo "dir /usr/bin 0755 0 0"
	echo "dir /usr/sbin 0755 0 0"
	echo "dir /etc 0755 0 0"
	echo "dir /root 0700 0 0"
	echo "dir /root/.ssh 0700 0 0"
	echo "dir /dev 0755 0 0"
	echo "dir /proc 0755 0 0"
	echo "dir /sys 0755 0 0"
	echo "dir /tmp 1777 0 0"
	echo "dir /run 0755 0 0"
	echo "file /init ${ROOT}/init 0755 0 0"
	echo "file /bin/busybox ${ROOT}/bin/busybox 0755 0 0"
	echo "file /usr/sbin/dropbear ${ROOT}/usr/sbin/dropbear 0755 0 0"
	echo "file /usr/bin/dropbearkey ${ROOT}/usr/bin/dropbearkey 0755 0 0"
	echo "file /etc/passwd ${ROOT}/etc/passwd 0600 0 0"
	echo "file /etc/group ${ROOT}/etc/group 0600 0 0"
	echo "file /etc/shells ${ROOT}/etc/shells 0644 0 0"
	echo "file /etc/issue ${ROOT}/etc/issue 0644 0 0"
	echo "file /etc/rescue.conf ${ROOT}/etc/rescue.conf 0644 0 0"
	echo "file /usr/bin/rescue-telnet ${ROOT}/usr/bin/rescue-telnet 0755 0 0"
	echo "file /usr/bin/rescue-menu ${ROOT}/usr/bin/rescue-menu 0755 0 0"
	echo "file /usr/bin/rescue-menu-keys ${ROOT}/usr/bin/rescue-menu-keys 0755 0 0"
	# Every applet /init calls must be resolvable by name: emit one symlink
	# per staged applet (regression for the issue #4 defect where only
	# /bin/sh made it into the archive while /init calls mount, ip, ln ...).
	for a in ${APPLETS}; do
		echo "slink /bin/${a} /bin/busybox 0755 0 0"
	done
	echo "slink /sbin/init /init 0755 0 0"
	# The kernel opens /dev/console before it executes /init
	# (console_on_rootfs(), init/main.c), so the node must exist in the cpio.
	echo "nod /dev/console 0600 0 0 c 5 1"
	if [ -f "${ROOT}/root/.ssh/authorized_keys" ]; then
		echo "file /root/.ssh/authorized_keys ${ROOT}/root/.ssh/authorized_keys 0600 0 0"
	fi
} > "${LIST}"

# gen_init_cpio must be reachable as usr/gen_init_cpio relative to the
# current directory (usr/gen_initramfs.sh), so build a scratch tree that
# contains the kbuild helper.
SCRATCH="${WORK}/scratch"
mkdir -p "${SCRATCH}/usr"
cp "${REPO_DIR}/usr/gen_initramfs.sh" "${SCRATCH}/usr/"
cp "${REPO_DIR}/usr/gen_init_cpio.c" "${SCRATCH}/usr/"
(
	cd "${SCRATCH}/usr"
	cc -O2 -o gen_init_cpio gen_init_cpio.c
)

# Pin every cpio entry to the commit timestamp so repeated builds of the
# same revision produce byte-identical archives (-d feeds gen_init_cpio -t,
# which also replaces per-file mtimes).
# Reproducibility: the archive mtimes and the kernel build timestamp are
# pinned to the timestamp of the commit that introduced the c2s board support
# (13e4b531bcc1), NOT to HEAD: otherwise every follow-up commit would change
# the Image and the sha256 sums recorded in c2s-rescue/docs would go stale.
# Override with SOURCE_DATE_EPOCH if ever needed.
C2S_EPOCH_COMMIT=13e4b531bcc17f85f3de3b75da1cc16569a0f2a4
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "${REPO_DIR}" log -1 --format=%ct "${C2S_EPOCH_COMMIT}" 2>/dev/null || echo 1794605179)}"
echo "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}" | tee -a "${LOG}"
run "generate initramfs" env -C "${SCRATCH}" \
	"${REPO_DIR}/usr/gen_initramfs.sh" -o "${WORK}/initramfs.cpio" \
	-d "@${SOURCE_DATE_EPOCH}" -u squash -g squash "${LIST}"
gzip -9 -n -c "${WORK}/initramfs.cpio" > "${WORK}/initramfs.cpio.gz"
echo "initramfs.cpio.gz sha256: $(sha256_of "${WORK}/initramfs.cpio.gz")" | tee -a "${LOG}"
ls -l "${WORK}/initramfs.cpio.gz" | tee -a "${LOG}"

# ------------------------------------------------------------- kernel build
step "configuring the kernel"
KBUILD="${OUTDIR}/kbuild"
mkdir -p "${KBUILD}"
run "make c2s_rescue_defconfig" make -C "${REPO_DIR}" O="${KBUILD}" \
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- c2s_rescue_defconfig

# Inject the initramfs source. The file name contains ".cpio." exactly once,
# so usr/Makefile uses it verbatim and skips a second compression pass
# (usr/Makefile:39-43).
# Copy the archive into the kbuild tree and reference it *relative*: the
# whole .config is embedded into the Image (CONFIG_IKCONFIG), so an absolute
# out-dir path in INITRAMFS_SOURCE would leak the build path into the binary
# and make two machines' Images differ (usr/Makefile:26-42 resolves the
# single ".cpio." file verbatim).
cp "${WORK}/initramfs.cpio.gz" "${KBUILD}/initramfs.cpio.gz"
run "scripts/config --set-str INITRAMFS_SOURCE" \
	"${REPO_DIR}/scripts/config" --file "${KBUILD}/.config" \
	--set-str INITRAMFS_SOURCE "initramfs.cpio.gz"
run "make olddefconfig" make -C "${REPO_DIR}" O="${KBUILD}" \
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

grep -E "^CONFIG_INITRAMFS_SOURCE" "${KBUILD}/.config" | tee -a "${LOG}"
INITRAMFS_CFG=$(grep -E '^CONFIG_INITRAMFS_SOURCE=' "${KBUILD}/.config" | cut -d'"' -f2)
if [ "$(readlink -f "${KBUILD}/${INITRAMFS_CFG}")" \
	!= "$(readlink -f "${KBUILD}/initramfs.cpio.gz")" ]; then
	echo "ERROR: CONFIG_INITRAMFS_SOURCE does not resolve to the staged archive" >&2
	exit 1
fi

# Reproducibility: pin the build counter and the build timestamp so that two
# builds of the same tree produce a byte-identical Image. Without this the
# kernel embeds "#N SMP PREEMPT <date>" (init/Makefile:32-38, which honours
# KBUILD_BUILD_VERSION / KBUILD_BUILD_TIMESTAMP).
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="${SOURCE_DATE_EPOCH}"
export KBUILD_BUILD_USER="c2s-rescue"
export KBUILD_BUILD_HOST="c2s-rescue"
# Pin the release string: setlocalversion would otherwise append the git
# describe output (commit hash + -dirty), which changes the Image on every
# new commit and makes the documented hashes meaningless. LOCALVERSION is
# deliberately set (to any value) so the scm_version suffix is omitted
# entirely (scripts/setlocalversion:200-211).
export LOCALVERSION=""
echo "KBUILD_BUILD_TIMESTAMP=${KBUILD_BUILD_TIMESTAMP}" | tee -a "${LOG}"

step "building Image and DTB"
run "make Image" make -C "${REPO_DIR}" O="${KBUILD}" \
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"${JOBS}" Image
# The per-DTB target name is not addressable with O= builds (the path is
# doubled by Makefile:1592), so build the dtbs umbrella target and select
# the c2s DTB afterwards.
run "make dtbs" make -C "${REPO_DIR}" O="${KBUILD}" \
	ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"${JOBS}" dtbs

IMAGE="${KBUILD}/arch/arm64/boot/Image"
DTB="${KBUILD}/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb"

step "build results"
{
	echo "Image:      ${IMAGE}"
	echo "  size:     $(stat -c %s "${IMAGE}") bytes"
	echo "  sha256:   $(sha256_of "${IMAGE}")"
	echo "DTB:        ${DTB}"
	echo "  size:     $(stat -c %s "${DTB}") bytes"
	echo "  sha256:   $(sha256_of "${DTB}")"
	echo "initramfs:  ${WORK}/initramfs.cpio.gz"
	echo "  size:     $(stat -c %s "${WORK}/initramfs.cpio.gz") bytes"
	echo "  sha256:   $(sha256_of "${WORK}/initramfs.cpio.gz")"
	echo "  cpio:     $(sha256_of "${WORK}/initramfs.cpio")"
	echo "log:        ${LOG}"
} | tee "${OUTDIR}/build-record.txt" | tee -a "${LOG}"

step "done"
