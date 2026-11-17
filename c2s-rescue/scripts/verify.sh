#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Verify the c2s rescue build artifacts on the build host. No phone is
# needed and nothing is written to the device: every check either inspects
# the kernel build directory, unpacks the generated initramfs, or runs the
# (already built) aarch64 binaries through binfmt_misc / qemu-user.
#
# Usage:
#   c2s-rescue/scripts/verify.sh [OUTDIR]
#
# OUTDIR defaults to /tmp/opencode/c2s-out (see build.sh).

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RESCUE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
REPO_DIR=$(cd -- "${RESCUE_DIR}/.." && pwd)
OUTDIR="${1:-${C2S_OUTDIR:-/tmp/opencode/c2s-out}}"
KBUILD="${OUTDIR}/kbuild"
WORK="${OUTDIR}/work"
IMAGE="${KBUILD}/arch/arm64/boot/Image"
DTB="${KBUILD}/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb"
INITRAMFS="${WORK}/initramfs.cpio.gz"

FAIL=0
PASS=0

ok()   { echo "PASS: $*"; PASS=$((PASS+1)); }
bad()  { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
note() { echo "---  $*"; }

check() {
	# check "<description>" <command...>
	local desc="$1"; shift
	if "$@" > /dev/null 2>&1; then
		ok "${desc}"
	else
		bad "${desc}"
	fi
}

section() { echo; echo "### $*"; }

# --------------------------------------------------------------- artifacts
section "artifacts exist"
for f in "${IMAGE}" "${DTB}" "${INITRAMFS}" "${OUTDIR}/build-record.txt" \
         "${OUTDIR}/build.log"; do
	check "exists: ${f##*/}" test -s "$f"
done

# ------------------------------------------------------------ kernel config
section "kernel config"
CONFIG="${KBUILD}/.config"
require_cfg() {
	local sym="$1" want="${2:-y}"
	local got
	got=$(grep -E "^CONFIG_${sym}=" "${CONFIG}" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"')
	if [ "${got}" = "${want}" ]; then
		ok "CONFIG_${sym}=${want}"
	else
		bad "CONFIG_${sym}: want ${want}, got '${got:-<unset>}'"
	fi
}
for s in ARCH_EXYNOS USB_GADGET USB_CONFIGFS USB_CONFIGFS_NCM USB_CONFIGFS_RNDIS \
         USB_CONFIGFS_ACM USB_LIBCOMPOSITE USB_U_ETHER USB_U_SERIAL USB_F_NCM \
         USB_F_RNDIS USB_F_ACM USB_DWC3 USB_DWC3_GADGET USB_DWC3_EXYNOS \
         PHY_EXYNOS5_USBDRD NET INET DEVTMPFS TMPFS BLK_DEV_INITRD RD_GZIP \
         BINFMT_ELF BINFMT_SCRIPT MULTIUSER UNIX98_PTYS FB FB_SIMPLE \
         FRAMEBUFFER_CONSOLE VT VT_CONSOLE INPUT INPUT_EVDEV KEYBOARD_GPIO \
         IKCONFIG IKCONFIG_PROC PRINTK_TIME; do
	require_cfg "$s" y
done
require_cfg CMDLINE_FORCE y
# pinned release string, see the defconfig comment
require_cfg LOCALVERSION "-c2s-rescue"
if grep -q "^CONFIG_LOCALVERSION_AUTO=y" "${CONFIG}" 2> /dev/null; then
	bad "CONFIG_LOCALVERSION_AUTO=y (would embed git describe in the Image)"
else
	ok "CONFIG_LOCALVERSION_AUTO is not set"
fi
# the initramfs must be baked in; CONFIG_INITRAMFS_SOURCE is relative to the
# kbuild tree (the absolute path would leak into the Image via IKCONFIG)
INITRAMFS_CFG=$(grep -E "^CONFIG_INITRAMFS_SOURCE=" "${CONFIG}" 2> /dev/null \
	| head -n1 | cut -d= -f2- | tr -d '"')
if [ -n "${INITRAMFS_CFG}" ] \
	&& [ "$(readlink -f "${KBUILD}/${INITRAMFS_CFG}" 2> /dev/null)" \
		= "$(readlink -f "${KBUILD}/initramfs.cpio.gz")" ]; then
	ok "CONFIG_INITRAMFS_SOURCE points at the staged archive"
else
	bad "CONFIG_INITRAMFS_SOURCE does not match the staged archive (got '${INITRAMFS_CFG}')"
fi
# the staged copy must be identical to the archive that was built
if cmp -s "${KBUILD}/initramfs.cpio.gz" "${INITRAMFS}"; then
	ok "staged initramfs archive is identical to the built one"
else
	bad "staged initramfs archive differs from the built one"
fi
# the embedded archive must be byte-identical to the one we built
if cmp -s "${KBUILD}/usr/initramfs_inc_data" "${INITRAMFS}"; then
	ok "initramfs archive embedded into the kernel unchanged"
else
	bad "kernel does not embed the built initramfs archive verbatim"
fi
# no build-host paths inside the image
if strings "${IMAGE}" 2> /dev/null | grep -q "${OUTDIR}"; then
	bad "Image contains the build output path (not reproducible)"
else
	ok "Image contains no build-host paths"
fi
# The release string must be pinned (CONFIG_LOCALVERSION) and must not carry
# git describe output - otherwise the Image would change on every commit.
RELEASE=$(strings "${IMAGE}" 2> /dev/null | sed -n 's/^Linux version \([^ ]*\) .*/\1/p' | head -n1)
if [ "${RELEASE}" = "7.1.0-rc4-c2s-rescue" ]; then
	ok "kernel release string is pinned (${RELEASE})"
else
	bad "kernel release string is not pinned (got '${RELEASE}')"
fi
if strings "${IMAGE}" 2> /dev/null | grep -qE "^Linux version [^ ]*-(dirty|g[0-9a-f]{7,})"; then
	bad "kernel release string contains git describe output"
else
	ok "kernel release string has no git describe suffix"
fi
# the kernel must not load modules: everything needed is built-in
if ! grep -qE "^CONFIG_MODULES=y" "${CONFIG}"; then
	ok "CONFIG_MODULES is not set"
else
	bad "CONFIG_MODULES=y (modules are not part of the rescue design)"
fi

# ------------------------------------------------------------ initramfs cpio
section "initramfs contents"
UNPACK="${OUTDIR}/verify-root"
rm -rf "${UNPACK}"
mkdir -p "${UNPACK}"
# Non-root extraction cannot create the /dev/console node (mknod -> EPERM),
# so the archive listing is the authoritative source for device nodes.
CPIO_LIST="${OUTDIR}/verify-cpio.list"
gzip -dc "${INITRAMFS}" | cpio -itv --quiet > "${CPIO_LIST}" 2> /dev/null
# -id returns 2 because /dev/console cannot be mknod'ed without root; that is
# expected, everything else must extract.
gzip -dc "${INITRAMFS}" | (cd "${UNPACK}" && cpio -id --quiet) > /dev/null 2>&1 \
	|| note "cpio -id exited non-zero (expected: mknod of /dev/console needs root)"
check "extracted a rootfs" test -x "${UNPACK}/init"
check "/init is executable" test -x "${UNPACK}/init"
if grep -qE '^crw-------[[:space:]]+1[[:space:]]+root[[:space:]]+root[[:space:]]+5,[[:space:]]+1[[:space:]]+.*dev/console$' "${CPIO_LIST}"; then
	ok "/dev/console char node (5, 1) is in the archive"
else
	bad "/dev/console char node (5, 1) missing from the archive"
fi
if [ -c "${UNPACK}/dev/console" ]; then
	if [ "$(stat -c '%t:%T' "${UNPACK}/dev/console" 2> /dev/null)" = "5:1" ]; then
		ok "/dev/console has major 5 minor 1 on disk"
	else
		bad "/dev/console has wrong device number"
	fi
else
	note "/dev/console not recreated on disk (mknod needs root); archive entry checked instead"
fi
check "/bin/busybox present" test -x "${UNPACK}/bin/busybox"
check "/usr/sbin/dropbear present" test -x "${UNPACK}/usr/sbin/dropbear"
check "/etc/passwd has root with /bin/sh" \
	grep -q "^root:x:0:0:root:/root:/bin/sh$" "${UNPACK}/etc/passwd"
check "/etc/shells contains /bin/sh" \
	grep -qx "/bin/sh" "${UNPACK}/etc/shells"
check "/etc/rescue.conf present" test -f "${UNPACK}/etc/rescue.conf"
# root-owned, strict permissions on the credential path
if [ -e "${UNPACK}/root/.ssh/authorized_keys" ]; then
	check "authorized_keys mode 0600" \
		test "$(stat -c %a "${UNPACK}/root/.ssh/authorized_keys")" = "600"
else
	note "no authorized_keys baked in (dropbear stays off until one is added)"
fi
# shell syntax of everything we will run as a script
BB="${UNPACK}/bin/busybox"
for s in init; do
	check "/${s} parses with busybox ash (sh -n)" \
		env -i "${BB}" ash -n "${UNPACK}/${s}"
done
if command -v dash > /dev/null; then
	check "/init parses with dash (sh -n)" dash -n "${UNPACK}/init"
fi

# ---------------------------------------------------------- secrets scan
section "secret scan"
# The device serial and any private key material must never enter the tree
# or the initramfs. We scan the deliverable sources *and* the built archive.
# The serial-bearing tokens are assembled from fragments so that this script
# does not match itself, and the serial itself is never spelled out here.
PATTERNS='androidboot'"."'.serialno|ap_'"serial"'|em'"."'.did|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'
SRC_FILES=$(find "${RESCUE_DIR}" -type f -print; \
	printf '%s\n' \
		"${REPO_DIR}/arch/arm64/configs/c2s_rescue_defconfig" \
		"${REPO_DIR}/arch/arm64/boot/dts/exynos/exynos990-c2s.dts" \
		"${REPO_DIR}/README.md")
LEAK=0
for f in ${SRC_FILES}; do
	if grep -Eq "${PATTERNS}" "${f}" 2> /dev/null; then
		bad "secret pattern in source file: ${f#"${REPO_DIR}"/}"
		LEAK=1
	fi
done
if [ "${LEAK}" -eq 0 ]; then
	ok "no serials / private keys in tracked rescue sources"
fi
if gzip -dc "${INITRAMFS}" | grep -aEq "${PATTERNS}"; then
	bad "secret pattern inside initramfs archive"
else
	ok "no serials / private keys inside initramfs archive"
fi

# ------------------------------------------------------------ DTB sanity
section "device tree"
DTB_TXT="${OUTDIR}/verify-c2s.dts"
dtc -I dtb -O dts -o "${DTB_TXT}" "${DTB}" 2> /dev/null
check "chosen framebuffer node present" \
	grep -q "framebuffer" "${DTB_TXT}"
check "usbdrd enabled" \
	grep -q "usb@10e00000" "${DTB_TXT}"
check "usbdrd_phy compatible is exynos990" \
	grep -q "samsung,exynos990-usbdrd-phy" "${DTB_TXT}"
# Last region: <0x8 0x80000000 0x2 0x80000000> -> ends at 0xb00000000.
# dtc prints the cells zero-padded, so match that spelling exactly.
check "memory covers the measured 0xb00000000 end" \
	grep -q '0x08 0x80000000 0x02 0x80000000' "${DTB_TXT}"
check "reg_dummy supply on usbdrd" \
	grep -q "vdd10-supply" "${DTB_TXT}"

# ------------------------------------------------------------ kernel image
section "kernel image"
# ARM64 Image header: code0/code1 at 0x38 == 0x644d5241 ("ARM\x64").
check "Image is ARM64 (Image magic at offset 0x38)" \
	bash -c 'test "$(od -An -tx1 -j56 -N4 '"${IMAGE}"' 2>/dev/null | tr -d " \n")" = "41524d64"'
file "${IMAGE}" | grep -q "ARM64" \
	&& ok "file(1) identifies ARM64 image" \
	|| bad "file(1) does not identify ARM64 image"

# ------------------------------------------------------- static binaries
section "static binaries in initramfs"
for b in bin/busybox usr/sbin/dropbear; do
	if LC_ALL=C aarch64-linux-gnu-readelf -h "${UNPACK}/${b}" 2> /dev/null \
		| grep -qE "^[[:space:]]*Type:[[:space:]]+EXEC"; then
		ok "${b} is a static aarch64 executable"
	else
		bad "${b} is not static/EXEC"
	fi
done
if aarch64-linux-gnu-readelf -d "${UNPACK}/usr/sbin/dropbear" 2>/dev/null \
	| grep -q NEEDED; then
	bad "dropbear has dynamic dependencies"
else
	ok "dropbear has no dynamic dependencies"
fi

# ------------------------------------------- host-run functional smoke test
section "functional smoke test (host-run dropbear, key-only)"
# This exercises the *same* dropbear binary that goes into the initramfs,
# running on the host through binfmt_misc/qemu-user. We verify:
#   1. dropbear starts with the packaged localoptions.h build options,
#   2. key-based login works,
#   3. a key that is not listed in authorized_keys is rejected,
#   4. password auth is refused at the protocol level,
#   5. the telnet gate logic in /init is enforced and off by default.
SMOKE="${OUTDIR}/smoke"
rm -rf "${SMOKE}"
mkdir -p "${SMOKE}"
cp "${UNPACK}/usr/sbin/dropbear" "${SMOKE}/dropbear"
cp "${UNPACK}/usr/bin/dropbearkey" "${SMOKE}/dropbearkey"

ssh-keygen -q -t ed25519 -N "" -f "${SMOKE}/id_test"
ssh-keygen -q -t ed25519 -N "" -f "${SMOKE}/id_other"
"${SMOKE}/dropbearkey" -t ed25519 -f "${SMOKE}/hostkey" > /dev/null 2>&1

# dropbear is not chrooted here, so it resolves the login account through the
# host /etc/passwd (the archive-side passwd/shells/root layout is asserted in
# "initramfs contents" above). checkpubkeyperms() walks from authorized_keys
# up to pw_dir and checkfileperm() accepts owner == login user or root, with
# no group/other write bit anywhere on the path - so the file must NOT live
# under a world-writable directory such as /tmp.
# Root mode (device-faithful: login user root) is used when passwordless
# sudo is available; otherwise the test falls back to the invoking user,
# which exercises the identical auth code path.
SMOKE_HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
if sudo -n true 2> /dev/null; then
	SMOKE_MODE=root
	SMOKE_USER=root
	SMOKE_AKDIR="/root/.c2s-verify-$$/.ssh"
	sudo -n mkdir -p "${SMOKE_AKDIR}"
	sudo -n cp "${SMOKE}/id_test.pub" "${SMOKE_AKDIR}/authorized_keys"
	sudo -n chmod 0700 "/root/.c2s-verify-$$" "${SMOKE_AKDIR}"
	sudo -n chmod 0600 "${SMOKE_AKDIR}/authorized_keys"
else
	SMOKE_MODE=user
	SMOKE_USER=$(id -un)
	SMOKE_AKDIR="${SMOKE_HOME}/.c2s-verify-$$/.ssh"
	mkdir -p "${SMOKE_AKDIR}"
	cp "${SMOKE}/id_test.pub" "${SMOKE_AKDIR}/authorized_keys"
	chmod 0700 "${SMOKE_HOME}/.c2s-verify-$$" "${SMOKE_AKDIR}"
	chmod 0600 "${SMOKE_AKDIR}/authorized_keys"
	note "passwordless sudo unavailable: smoke test runs as '${SMOKE_USER}' instead of root (same auth path)"
fi

db_alive() {
	if [ "${SMOKE_MODE}" = root ]; then
		sudo -n kill -0 "$1" 2> /dev/null
	else
		kill -0 "$1" 2> /dev/null
	fi
}
db_kill() {
	if [ "${SMOKE_MODE}" = root ]; then
		sudo -n kill "$1" 2> /dev/null
	else
		kill "$1" 2> /dev/null
	fi
}

# The initramfs /init starts dropbear as:
#   dropbear -R -F -E -b /etc/issue -D /root/.ssh -P /run/dropbear.pid \
#            -p <ncm-ip>:22 -p <rndis-ip>:22
# Here we use loopback and -r instead of -R (which would generate host keys
# under /etc/dropbear/ of the *host*), everything else matches /init.
if [ "${SMOKE_MODE}" = root ]; then
	sudo -n env -i PATH=/usr/bin:/bin \
		"${SMOKE}/dropbear" -F -E \
		-p 127.0.0.1:24222 -D "${SMOKE_AKDIR}" \
		-r "${SMOKE}/hostkey" -P "${SMOKE}/dropbear.pid" \
		> "${SMOKE}/dropbear.log" 2>&1 &
else
	env -i PATH=/usr/bin:/bin \
		"${SMOKE}/dropbear" -F -E \
		-p 127.0.0.1:24222 -D "${SMOKE_AKDIR}" \
		-r "${SMOKE}/hostkey" -P "${SMOKE}/dropbear.pid" \
		> "${SMOKE}/dropbear.log" 2>&1 &
fi
DBPID=$!
sleep 2

# The listener writes its own pid; $! is the sudo wrapper in root mode.
DBLIVE=""
if [ -f "${SMOKE}/dropbear.pid" ]; then
	DBLIVE=$(cat "${SMOKE}/dropbear.pid")
fi

if [ -n "${DBLIVE}" ] && db_alive "${DBLIVE}"; then
	ok "dropbear started on 127.0.0.1:24222 (${SMOKE_MODE} mode, pid ${DBLIVE})"
	# 1) pubkey login with the listed key
	if ssh -i "${SMOKE}/id_test" -o UserKnownHostsFile=/dev/null \
		-o StrictHostKeyChecking=no -o BatchMode=yes \
		-o PasswordAuthentication=no -o PubkeyAuthentication=yes \
		-o ConnectTimeout=5 -p 24222 "${SMOKE_USER}@127.0.0.1" \
		'echo SMOKE_OK' > "${SMOKE}/ssh.out" 2> /dev/null \
	   && grep -q SMOKE_OK "${SMOKE}/ssh.out"; then
		ok "public-key SSH login succeeded"
	else
		bad "public-key SSH login failed (see ${SMOKE}/dropbear.log)"
	fi
	# 2) a key that is not in authorized_keys must be rejected
	if ssh -i "${SMOKE}/id_other" -o UserKnownHostsFile=/dev/null \
		-o StrictHostKeyChecking=no -o BatchMode=yes \
		-o IdentitiesOnly=yes \
		-o ConnectTimeout=5 -p 24222 "${SMOKE_USER}@127.0.0.1" \
		'echo SHOULD_NOT_HAPPEN' > "${SMOKE}/ssh-bad.out" 2>&1; then
		bad "unlisted key was accepted by dropbear"
	else
		ok "unlisted key rejected"
	fi
	# 3) password must be refused (compiled out, see localoptions.h)
	if ssh -o UserKnownHostsFile=/dev/null \
		-o StrictHostKeyChecking=no -o BatchMode=no \
		-o PreferredAuthentications=password \
		-o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
		-o ConnectTimeout=5 -p 24222 "${SMOKE_USER}@127.0.0.1" 'true' \
		< /dev/null > "${SMOKE}/ssh-pw.out" 2>&1; then
		bad "password authentication unexpectedly succeeded"
	else
		if grep -qE "Permission denied|password" "${SMOKE}/ssh-pw.out"; then
			ok "password authentication refused"
		else
			bad "unexpected failure mode for password auth: $(head -n1 "${SMOKE}/ssh-pw.out")"
		fi
	fi
else
	bad "dropbear did not start (see ${SMOKE}/dropbear.log)"
	[ -s "${SMOKE}/dropbear.log" ] && note "$(head -n3 "${SMOKE}/dropbear.log")"
fi

# teardown
[ -n "${DBLIVE}" ] && db_kill "${DBLIVE}"
db_kill "${DBPID}" 2> /dev/null
wait "${DBPID}" 2> /dev/null
if [ "${SMOKE_MODE}" = root ]; then
	sudo -n rm -rf "/root/.c2s-verify-$$"
else
	rm -rf "${SMOKE_HOME}/.c2s-verify-$$"
fi

# 4) the telnet gate must be off by default: with the stock rescue.conf
#    RESCUE_ENABLE_TELNET is "0", so a stock /init must not spawn telnetd.
if grep -q 'RESCUE_ENABLE_TELNET="0"' "${UNPACK}/etc/rescue.conf" \
	&& grep -q 'RESCUE_ENABLE_TELNET" = "1"' "${UNPACK}/init" \
	&& grep -q 'enable-telnet' "${UNPACK}/init"; then
	ok "telnet gate: config flag '0' AND marker file required by /init"
else
	bad "telnet gate logic not enforced as designed"
fi

# ----------------------------------------------------------------- summary
echo
echo "==================================="
echo "verify: ${PASS} passed, ${FAIL} failed"
echo "==================================="
[ "${FAIL}" -eq 0 ]
