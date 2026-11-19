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
# Dump the Image strings once: `strings | grep -q` is unusable here because
# grep exits early on a match, strings takes SIGPIPE, and `set -o pipefail`
# would then invert every conditional below (a found defect would report ok).
IMG_STRINGS="${OUTDIR}/verify-image.strings"
strings "${IMAGE}" > "${IMG_STRINGS}" 2> /dev/null
# no build-host paths inside the image
if grep -q "${OUTDIR}" "${IMG_STRINGS}"; then
	bad "Image contains the build output path (not reproducible)"
else
	ok "Image contains no build-host paths"
fi
# The release string must be pinned (CONFIG_LOCALVERSION) and must not carry
# git describe output - otherwise the Image would change on every commit.
RELEASE=$(sed -n 's/^Linux version \([^ ]*\) .*/\1/p' "${IMG_STRINGS}" | head -n1)
if [ "${RELEASE}" = "7.1.0-rc4-c2s-rescue" ]; then
	ok "kernel release string is pinned (${RELEASE})"
else
	bad "kernel release string is not pinned (got '${RELEASE}')"
fi
if grep -qE "^Linux version [^ ]*-(dirty|g[0-9a-f]{7,})" "${IMG_STRINGS}"; then
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

# ------------------------------------------------- console font (issue #4)
# 1440x3088 framebuffer: the 16x32 Terminus font gives 90x96 characters.
# CONFIG_CMDLINE_FORCE=y means fbcon gets its options ONLY through
# CONFIG_CMDLINE - a kernel cmdline appended by the bootloader would be
# ignored, so the font selection must be verified in the built config
# AND in the Image's embedded command line.
section "console font (fbcon=font:TER16x32)"
require_cfg FONTS y
require_cfg FONT_8x16 y   # fallback if the named font is missing
require_cfg FONT_TER16x32 y
if grep -q "fbcon=font:TER16x32" "${CONFIG}"; then
	ok "CONFIG_CMDLINE contains fbcon=font:TER16x32"
else
	bad "CONFIG_CMDLINE does not select the TER16x32 font"
fi
# the font itself must be compiled into the Image, and the option must be
# in the built-in command line (both are read from the same strings dump:
# `strings | grep -q` would break under `set -o pipefail` when grep exits
# early and strings takes SIGPIPE)
IMG_STRINGS="${OUTDIR}/verify-image.strings"
# (already dumped above)
if grep -q "fbcon=font:TER16x32" "${IMG_STRINGS}"; then
	ok "Image embeds the fbcon font option in its command line"
else
	bad "Image command line lacks fbcon=font:TER16x32"
fi
if grep -q "TER16x32" "${IMG_STRINGS}"; then
	ok "TER16x32 font is compiled into the Image"
else
	bad "TER16x32 font not found in the Image"
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

# ------------------------------------------------ regression (issue #4)
# The shipped archive itself (not the staging tree) must carry every
# applet symlink /init calls. The defect this guards against: build.sh
# created applet symlinks in the staging dir but cpio.list shipped only
# /bin/sh, so init died on the first missing applet at boot.
section "shipped-archive applet symlinks (issue #4 regression)"
INIT="${UNPACK}/init"
# applets referenced as bare commands in /init (heuristic: word at a
# command position); these are the ones the menu/services need.
REQUIRED_APPLETS="mount mkdir ip ln sleep timeout od dd awk cat grep tr \
setsid cttyhack telnetd dropbear"
MISSING=""
for a in ${REQUIRED_APPLETS}; do
	# dropbear is a real binary, everything else must be a busybox link
	if [ "$a" = "dropbear" ]; then
		if [ -x "${UNPACK}/usr/sbin/dropbear" ]; then
			ok "shipped archive: ${a} present"
		else
			bad "shipped archive: ${a} MISSING"
			MISSING="${MISSING} ${a}"
		fi
	elif [ -e "${UNPACK}/bin/${a}" ]; then
		if [ "$(readlink "${UNPACK}/bin/${a}")" = "/bin/busybox" ]; then
			ok "shipped archive: /bin/${a} -> /bin/busybox"
		else
			bad "shipped archive: /bin/${a} is not a busybox symlink"
			MISSING="${MISSING} ${a}"
		fi
	else
		bad "shipped archive: /bin/${a} MISSING (init calls it by name)"
		MISSING="${MISSING} ${a}"
	fi
done
# functional: run the shipped busybox through qemu and prove the applets
# actually execute (not just that the symlink exists)
if [ -x "${UNPACK}/bin/busybox" ] && command -v qemu-aarch64 > /dev/null; then
	BBBIN="${UNPACK}/bin/busybox"
	BB_OK=1
	for a in mount ip ln sleep od awk; do
		env -i qemu-aarch64 "${BBBIN}" "${a}" --help > /dev/null 2>&1 \
			|| BBBAD=1
	done
	if [ "${BBBAD:-0}" -eq 0 ]; then
		ok "shipped busybox executes applets under qemu-aarch64"
	else
		bad "shipped busybox cannot execute required applets"
	fi
else
	note "qemu-aarch64 not available; skipped applet execution check"
fi

# ------------------------------------------------ boot menu logic (init)
section "boot menu logic (telnet never default)"
# 1. telnet must be off by default in the shipped config
grep -q '^RESCUE_ENABLE_TELNET="0"' "${UNPACK}/etc/rescue.conf" \
	&& ok "rescue.conf: RESCUE_ENABLE_TELNET=0 (telnet off by default)" \
	|| bad "rescue.conf: RESCUE_ENABLE_TELNET not 0"
# 2. the menu must exist in init and must require an explicit selection
grep -q 'boot_menu' "${INIT}" \
	&& ok "init: boot menu present" \
	|| bad "init: boot menu missing"
grep -q 'enable-telnet' "${INIT}" \
	&& ok "init: telnet armed only via marker/menu selection" \
	|| bad "init: telnet gate missing"
# 3. /init must start telnetd exactly once (inside the gated
#    start_telnetd()); no second, ungated invocation anywhere
TELD_CALLS=$(grep -n '^[[:space:]]*telnetd -F' "${INIT}" | wc -l)
if [ "${TELD_CALLS}" -eq 1 ]; then
	ok "init: telnetd invoked exactly once, gated in start_telnetd()"
else
	bad "init: telnetd invoked ${TELD_CALLS} times (want exactly 1)"
fi
# 4. the marker alone must not be enough: RESCUE_ENABLE_TELNET must also
#    be 1 at that point (the menu sets it; rescue-telnet cannot)
if grep -n 'telnet_armed()' -A3 "${INIT}" | grep -q 'RESCUE_ENABLE_TELNET'; then
	ok "init: telnet_armed requires both marker and config flag"
else
	bad "init: telnet_armed does not check the config flag"
fi

# ------------------------------------------------- boot menu functional
# Exercise the shipped rescue-menu (wrapper) and rescue-menu-keys (input
# helper) with *representative* input streams. Every aarch64 binary runs
# directly through binfmt_misc/qemu-user, so the exact binaries that go
# into the initramfs are tested.
#
# Invariants under test (issue #4):
#   - telnet is selected ONLY by EV_KEY press of 114 or the serial line
#     "telnet"; release (value 0), autorepeat (value 2), foreign keys and
#     EV_SYN never select anything,
#   - events are not lost (persistent poll loop, single reader),
#   - the gpio-keys device is found via sysfs even when it is NOT
#     /dev/input/event0,
#   - menu-echo on the serial line (what a terminal mirrors back) cannot
#     select anything during the drain window,
#   - timeout and missing devices default to rescue,
#   - stdout carries exactly one line: the selected mode.
section "boot menu selection (shipped rescue-menu + rescue-menu-keys)"
MENUDIR="${OUTDIR}/menu-test"
rm -rf "${MENUDIR}"
mkdir -p "${MENUDIR}"
MENU="${UNPACK}/usr/bin/rescue-menu"
KEYS="${UNPACK}/usr/bin/rescue-menu-keys"
if [ ! -x "${KEYS}" ]; then
	bad "shipped archive: /usr/bin/rescue-menu-keys missing"
elif [ ! -x "${MENU}" ]; then
	bad "shipped archive: /usr/bin/rescue-menu missing"
else
	check "rescue-menu parses with busybox ash" \
		env -i "${UNPACK}/bin/busybox" ash -n "${MENU}"
	# the helper must be a static aarch64 executable (it runs via binfmt)
	if LC_ALL=C aarch64-linux-gnu-readelf -h "${KEYS}" 2> /dev/null \
		| grep -qE "^[[:space:]]*Type:[[:space:]]+EXEC"; then
		ok "rescue-menu-keys is a static aarch64 executable"
	else
		bad "rescue-menu-keys is not a static aarch64 executable"
	fi
	check "rescue-menu-keys present in the shipped cpio list" \
		grep -qx "file /usr/bin/rescue-menu-keys .* 0755 0 0" "${WORK}/cpio.list"

	# evdev event files: struct input_event on arm64 is
	# <QQHHi> = tv_sec, tv_usec, type, code, value
	ev() { # ev FILE TYPE CODE VALUE
		python3 -c "
import struct, sys
open(sys.argv[1], 'ab').write(struct.pack('<QQHHi', 0, 0,
    int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])))" \
			"$1" "$2" "$3" "$4"
	}
	# run_keys [-t TIMEOUT] -- TTYFILE EVFILE... ; prints stdout only
	QEMU=$(command -v qemu-aarch64 || true)
	if [ -z "${QEMU}" ]; then
		note "qemu-aarch64 not available; skipped menu functional tests"
	else
		run_keys() {
			local t=3
			if [ "$1" = "-t" ]; then t="$2"; shift 2; fi
			shift # --
			local ttyf="$1"; shift
			local log="${MENUDIR}/keys.log"
			env -i PATH=/usr/bin:/bin RESCUE_MENU_TTY="${ttyf}" \
				timeout 30 "${QEMU}" "${KEYS}" \
				--timeout "${t}" --drain 0.3 \
				--tty "${ttyf}" "$@" \
				2> "${log}"
		}
		NODEV="${MENUDIR}/no-such-device"
		: > "${NODEV}"

		# 1. press 114 -> telnet
		: > "${MENUDIR}/ev1"; ev "${MENUDIR}/ev1" 1 114 1
		[ "$(run_keys -- "${NODEV}" "${MENUDIR}/ev1")" = "telnet" ] \
			&& ok "keys: volume-down press (114, value 1) selects telnet" \
			|| bad "keys: volume-down press did not select telnet"
		# 2. release then press (press after release must still count)
		: > "${MENUDIR}/ev2"; ev "${MENUDIR}/ev2" 1 114 0; ev "${MENUDIR}/ev2" 1 114 1
		[ "$(run_keys -- "${NODEV}" "${MENUDIR}/ev2")" = "telnet" ] \
			&& ok "keys: release+press sequence selects telnet" \
			|| bad "keys: release+press sequence did not select telnet"
		# 3. release alone (value 0) -> rescue
		: > "${MENUDIR}/ev3"; ev "${MENUDIR}/ev3" 1 114 0
		[ "$(run_keys -- "${NODEV}" "${MENUDIR}/ev3")" = "rescue" ] \
			&& ok "keys: release event does not select telnet" \
			|| bad "keys: release event selected telnet"
		# 4. autorepeat (value 2) on 115/116 -> rescue (never telnet)
		: > "${MENUDIR}/ev4"
		ev "${MENUDIR}/ev4" 1 115 2; ev "${MENUDIR}/ev4" 1 116 2
		[ "$(run_keys -- "${NODEV}" "${MENUDIR}/ev4")" = "rescue" ] \
			&& ok "keys: autorepeat events do not select" \
			|| bad "keys: autorepeat events changed the selection"
		# 5. foreign key press (113 mute) + EV_SYN (type 0) -> rescue
		: > "${MENUDIR}/ev5"
		ev "${MENUDIR}/ev5" 1 113 1; ev "${MENUDIR}/ev5" 0 0 0
		[ "$(run_keys -- "${NODEV}" "${MENUDIR}/ev5")" = "rescue" ] \
			&& ok "keys: foreign key press and EV_SYN do not select" \
			|| bad "keys: foreign event selected a mode"
		# 6. volume-up (115) and power (116) press -> rescue
		: > "${MENUDIR}/ev6"
		ev "${MENUDIR}/ev6" 1 115 1
		[ "$(run_keys -- "${NODEV}" "${MENUDIR}/ev6")" = "rescue" ] \
			&& ok "keys: volume-up selects rescue" \
			|| bad "keys: volume-up did not select rescue"
		: > "${MENUDIR}/ev6b"
		ev "${MENUDIR}/ev6b" 1 116 1
		[ "$(run_keys -- "${NODEV}" "${MENUDIR}/ev6b")" = "rescue" ] \
			&& ok "keys: power selects rescue" \
			|| bad "keys: power did not select rescue"
		# 7. timeout -> rescue, and stdout must be exactly one line
		OUT=$(run_keys -t 1 -- "${NODEV}" "${NODEV}")
		[ "${OUT}" = "rescue" ] \
			&& ok "keys: timeout defaults to rescue (telnet off)" \
			|| bad "keys: timeout did not default to rescue"
		[ "$(printf '%s\n' "${OUT}" | wc -l)" -eq 1 ] \
			&& ok "keys: stdout carries exactly one line" \
			|| bad "keys: stdout is not a single line"
		# 8. serial line "telnet" after the drain window -> telnet
		#    (fifo: the helper keeps it open, the writer sends later)
		SER="${MENUDIR}/serial.fifo"
		rm -f "${SER}"; mkfifo "${SER}"
		( exec 3> "${SER}"; sleep 0.6; printf 'telnet\r\n' >&3; sleep 0.2; exec 3>&- ) &
		OUT=$(run_keys -t 3 -- "${SER}" "${NODEV}")
		wait || true
		[ "${OUT}" = "telnet" ] \
			&& ok "keys: serial line 'telnet' selects telnet (after drain)" \
			|| bad "keys: serial 'telnet' did not select telnet"
		# 9. echo of the menu text during the drain window must NOT select:
		#    the banner the helper would echo contains "telnet"; a terminal
		#    with local echo sends exactly such lines back immediately.
		( exec 3> "${SER}"; printf '  vol-down or type telnet : rescue + USB telnet (DEBUG)\r\n' >&3; sleep 0.2; exec 3>&- ) &
		OUT=$(run_keys -t 2 -- "${SER}" "${NODEV}")
		wait || true
		[ "${OUT}" = "rescue" ] \
			&& ok "keys: menu-echo line during drain does not select" \
			|| bad "keys: echoed menu text selected telnet"
		# 9b. buffered input at menu start (arrives during the drain
		#     window, before raw mode could flush it) must not select:
		#     even an exact "telnet\r\n" is discarded there.
		( exec 3> "${SER}"; printf 'telnet\r\n' >&3; sleep 0.2; exec 3>&- ) &
		OUT=$(run_keys -t 2 -- "${SER}" "${NODEV}")
		wait || true
		[ "${OUT}" = "rescue" ] \
			&& ok "keys: buffered line during drain window is discarded" \
			|| bad "keys: buffered line during drain selected telnet"
		# 10. serial line "rescue" and empty Enter -> rescue
		( exec 3> "${SER}"; sleep 0.6; printf 'rescue\n' >&3; sleep 0.2; exec 3>&- ) &
		OUT=$(run_keys -t 3 -- "${SER}" "${NODEV}")
		wait || true
		[ "${OUT}" = "rescue" ] \
			&& ok "keys: serial 'rescue' selects rescue" \
			|| bad "keys: serial 'rescue' failed"
		( exec 3> "${SER}"; sleep 0.6; printf '\r\n' >&3; sleep 0.2; exec 3>&- ) &
		OUT=$(run_keys -t 3 -- "${SER}" "${NODEV}")
		wait || true
		[ "${OUT}" = "rescue" ] \
			&& ok "keys: serial Enter selects rescue" \
			|| bad "keys: serial Enter failed"
		# 11. garbage serial line -> ignored, timeout -> rescue
		( exec 3> "${SER}"; sleep 0.6; printf 'hello world\n' >&3; sleep 0.2; exec 3>&- ) &
		OUT=$(run_keys -t 2 -- "${SER}" "${NODEV}")
		wait || true
		[ "${OUT}" = "rescue" ] \
			&& ok "keys: garbage serial line ignored (timeout -> rescue)" \
			|| bad "keys: garbage serial line changed the selection"

		# 12. events arriving over time on a fifo (writer opens first,
		#     events trickle in) - nothing may be lost
		FIFO="${MENUDIR}/evfifo"
		rm -f "${FIFO}"; mkfifo "${FIFO}"
		( python3 - "${FIFO}" <<'PYEOF' ) &
import struct, sys, time
f = open(sys.argv[1], "wb")  # blocks until the reader side opens
time.sleep(0.5)              # events arrive long after the menu started
f.write(struct.pack("<QQHHi", 0, 0, 0, 0, 0))    # EV_SYN noise
f.write(struct.pack("<QQHHi", 0, 0, 1, 114, 0))  # release first
f.write(struct.pack("<QQHHi", 0, 0, 1, 114, 1))  # then the press
f.flush()
time.sleep(0.5)
f.close()
PYEOF
		FW=$!
		OUT=$(run_keys -t 3 -- "${NODEV}" "${FIFO}")
		wait "${FW}" || true
		[ "${OUT}" = "telnet" ] \
			&& ok "keys: fifo stream (delayed press/release/SYN mix) selects telnet" \
			|| bad "keys: fifo stream lost the key press"
		# 13. fifo writer closes without input: no spin, clean timeout
		FIFO2="${MENUDIR}/evfifo2"
		rm -f "${FIFO2}"; mkfifo "${FIFO2}"
		( exec 3> "${FIFO2}"; exec 3>&- ) &
		OUT=$(run_keys -t 1 -- "${NODEV}" "${FIFO2}")
		wait || true
		[ "${OUT}" = "rescue" ] \
			&& ok "keys: closed fifo writer times out to rescue" \
			|| bad "keys: closed fifo writer did not time out cleanly"

		# ---- wrapper (rescue-menu): sysfs discovery, NOT event0 ----
		# Layout note: input_print_bitmap() (drivers/input/input.c)
		# prints %lx words, most significant word first, skips empty
		# words ABOVE the first non-empty one and then prints the rest
		# (skip_empty is cleared once a word was emitted) - the c2s
		# gpio-keys device (only keys 114/115/116) therefore prints
		# "1c000000000000 0" (word 1 with bits 50/51/52, then word 0).
		FAKE="${MENUDIR}/fakesys"
		rm -rf "${FAKE}"
		mkdir -p "${FAKE}/sys/event0/device/capabilities" \
			"${FAKE}/sys/event7/device/capabilities" \
			"${FAKE}/dev/input"
		# event0 is a hostile device: right name, no volume-key bits
		# (every word empty -> the all-empty "0" print)
		echo "gpio-keys" > "${FAKE}/sys/event0/device/name"
		echo "0" > "${FAKE}/sys/event0/device/capabilities/key"
		# event7 is the real gpio-keys: name AND the bitmap exactly
		# as the kernel would print it
		echo "gpio-keys" > "${FAKE}/sys/event7/device/name"
		echo "1c000000000000 0" > "${FAKE}/sys/event7/device/capabilities/key"
		: > "${FAKE}/dev/input/event7"
		ev "${FAKE}/dev/input/event7" 1 114 1
		run_menu() { # run_menu LOGFILE
			local log="$1"; shift
			env -i PATH=/usr/bin:/bin \
				RESCUE_MENU_SYSFS="${FAKE}/sys" \
				RESCUE_MENU_DEVDIR="${FAKE}/dev/input" \
				RESCUE_MENU_TIMEOUT=3 \
				RESCUE_MENU_KEYS="${KEYS}" \
				timeout 30 "${QEMU}" "${UNPACK}/bin/busybox" ash "${MENU}" \
				2> "${log}"
		}
		OUT=$(run_menu "${MENUDIR}/wrapper.log")
		[ "$(printf '%s\n' "${OUT}" | tail -n 1)" = "telnet" ] \
			&& ok "menu: gpio-keys at event7 (not event0) discovered and used" \
			|| bad "menu: gpio-keys discovery failed (got '$(printf '%s' "${OUT}" | tail -n1)')"
		# ... and event0 must NOT be picked when it lacks the key bits
		# (only its sysfs node exists: event7's directory is removed,
		# so only the hostile event0 remains to discover)
		: > "${FAKE}/dev/input/event7"
		rm -rf "${FAKE}/sys/event7"
		OUT=$(run_menu "${MENUDIR}/wrapper2.log")
		[ "$(printf '%s\n' "${OUT}" | tail -n 1)" = "rescue" ] \
			&& ok "menu: non-gpio event0 (no key caps) is not used" \
			|| bad "menu: hostile event0 was used for input"
		# no gpio-keys at all -> wrapper must still default to rescue
		OUT=$(env -i PATH=/usr/bin:/bin \
			RESCUE_MENU_SYSFS="${MENUDIR}/does-not-exist" \
			RESCUE_MENU_TIMEOUT=3 \
			RESCUE_MENU_KEYS="${KEYS}" \
			timeout 30 "${QEMU}" "${UNPACK}/bin/busybox" ash "${MENU}" \
			2> "${MENUDIR}/wrapper3.log")
		[ "$(printf '%s\n' "${OUT}" | tail -n 1)" = "rescue" ] \
			&& ok "menu: no gpio-keys found -> rescue (telnet off)" \
			|| bad "menu: missing gpio-keys did not default to rescue"
	fi
fi
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

# ------------------------------------------- packaged boot image (DT table)
# If a packaged boot.img exists, its dt slot must contain the Samsung DT
# table (magic 0xd7b7ab1e), not a bare FDT - sboot rejects a bare FDT
# with "[DTH] dt table header check Fail" (the defect of the first
# candidate). The offset formula mirrors sboot: payload_base + aligned
# kernel + aligned ramdisk + 0x1000 (payload_base = image + page_size).
if [ -s "${OUTDIR}/boot.img" ]; then
	section "packaged boot.img Samsung DT table"
	PYDT=$(python3 - "${OUTDIR}/boot.img" "${DTB}" <<'PYEOF'
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
ok = True
msg = []
hdr = struct.unpack(">8I", img[off:off + 0x20])
magic, total, hsize, esize, count, eoff, page, ver = hdr
if magic != 0xD7B7AB1E:
    ok = False; msg.append("dt magic %#x at +%d (raw FDT?)" % (magic, off))
if (hsize, esize, eoff, count, page) != (0x20, 0x20, 0x20, 1, 0x800):
    ok = False; msg.append("header fields %s unexpected" % (hdr,))
ent = struct.unpack(">8I", img[off + 0x20:off + 0x40])
if ent[2:] != (0, 0, 0, 0xFF, 0, 0) or ent[1] != 0x40:
    ok = False; msg.append("entry %s unexpected" % (ent,))
fdt = img[off + 0x40:off + 0x40 + ent[0]]
if fdt != open(dtb_path, "rb").read():
    ok = False; msg.append("wrapped FDT != kbuild DTB")
if b"__symbols__" not in fdt:
    ok = False
    msg.append("wrapped FDT has no /__symbols__ node (sboot libufdt "
               "overlay needs it: 'No node __symbols__ in main dtb.')")
print(("OK " if ok else "BAD ") + "; ".join(msg) or "dt table valid")
sys.exit(0 if ok else 1)
PYEOF
	)
	if [ "${PYDT#OK*}" != "${PYDT}" ]; then
		ok "boot.img dt slot: Samsung DT table, FDT == kbuild DTB, __symbols__ present"
	else
		bad "boot.img dt slot: ${PYDT#BAD }"
	fi
	AVBTOOL_BIN="${C2S_AVBTOOL:-/home/gregor/.local/var/pmbootstrap/chroot_native/usr/bin/avbtool}"
	[ -x "${AVBTOOL_BIN}" ] || AVBTOOL_BIN=avbtool
	check "avbtool verifies the packaged boot.img" \
		"${AVBTOOL_BIN}" verify_image --image "${OUTDIR}/boot.img"
else
	note "no packaged boot.img in ${OUTDIR}; DT-table checks skipped"
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
# Last region: 5 x <0x8.. 0x80000000> 2 GiB chunks -> ends at 0xb00000000.
# (#size-cells=1 caps each entry at 4 GiB, so the 10 GiB region is split.)
check "memory highmem split 0x880000000..0xb00000000 present" \
	grep -qE '0x08 0x80000000 0x80000000 0x09 0x00 0x80000000' "${DTB_TXT}"
# Root must use the stock cell format (#address-cells=2, #size-cells=1):
# lk3rd's add_dt_memory_node() overwrites /memory reg with 3-cell entries
# and of_flat_dt_get_addr_size_prop() rejects reg blocks whose length is
# not a multiple of (root_addr+root_size)*4 = 12 bytes. With the old 2/2
# root every 3-cell root-level reg failed the % 16 test and the kernel
# saw 0 bytes of RAM (silent death before any console output).
PYROOT=$(python3 - "${DTB}" "${SCRIPT_DIR}/fdt.py" <<'PYEOF'
import struct, sys
sys.path.insert(0, sys.argv[2].rsplit('/', 1)[0])
import fdt
root = fdt.parse(open(sys.argv[1], 'rb').read())
ac = fdt.cells(root.prop('#address-cells'))[0]
sc = fdt.cells(root.prop('#size-cells'))[0]
ok = (ac, sc) == (2, 1)
msg = 'root cells #address=%d #size=%d' % (ac, sc)
bad = []
for n in root.kids:
    reg = n.prop('reg')
    if reg is None:
        continue
    words = len(reg) // 4
    if words % 3 != 0:
        bad.append('%s: reg has %d words, not a 3-cell multiple' % (n.path, words))
if bad:
    ok = False
    msg += '; ' + '; '.join(bad)
else:
    msg += '; all root-level regs are 3-cell multiples'
print(('OK ' if ok else 'BAD ') + msg)
sys.exit(0 if ok else 1)
PYEOF
)
if [ "${PYROOT#OK*}" != "${PYROOT}" ]; then
	ok "DTB ${PYROOT#OK }"
else
	bad "DTB ${PYROOT#BAD }"
fi
# __reserved_mem_check_root() compares /reserved-memory #address/#size-cells
# against the root cells and returns -EINVAL on mismatch (reservations lost).
check "reserved-memory cells match root (2/1)" \
	grep -q '#size-cells = <0x01>' \
	<(awk '/^[[:space:]]*reserved-memory \{/{f=1} f&&/#size-cells/{print;exit}' "${DTB_TXT}")
check "reserved-memory children use 3-cell reg" \
	grep -qE '<0x00 0xf1000000 0x10f6800>' "${DTB_TXT}"
check "reg_dummy supply on usbdrd" \
	grep -q "vdd10-supply" "${DTB_TXT}"
# sboot's libufdt overlay step requires /__symbols__ in the main DTB;
# without it the device stops in "ODIN MODE (DT Load Fail)" with
# "No node __symbols__ in main dtb." (DTC_FLAGS_exynos990-c2s = -@).
check "DTB carries a /__symbols__ node (sboot libufdt requirement)" \
	grep -qE "^[[:space:]]*__symbols__ \{" "${DTB_TXT}"

# --------------------------------------------- stock DTBO overlay compatibility
# sboot applies the stock dtbo.img entry for this board's hw_rev onto our dt
# slot FDT before booting.  Each entry's /__fixups__ must resolve through our
# /__symbols__ or the boot aborts:
#   "failed to perform fixups in overlay" -> "[UFDT] DT Overlay FAIL."
# The gate replays that merge locally with all 9 stock dtbo.img entries:
#   positive control : stock base must accept every entry (tool works),
#   negative control : the previous candidate (DTB without anchor nodes)
#                      must FAIL (the defect the anchors fix),
#   gate             : our built DTB must accept every entry.
# Anchors are generated by c2s-rescue/scripts/gen-overlay-anchors.py from the
# fixtures; see arch/arm64/boot/dts/exynos/c2s-overlay-anchors.dtsi.
section "stock DTBO overlay compatibility (fdtoverlay)"
FIXTURES="${C2S_DTBO_FIXTURES:-/tmp/opencode/dtbo-fixtures}"
if ! command -v fdtoverlay > /dev/null; then
	bad "fdtoverlay not found in PATH (device-tree-compiler)"
elif [ ! -f "${FIXTURES}/stock-base.dtb" ] || \
     [ ! -f "${FIXTURES}/prev-base-without-anchors.dtb" ] || \
     ! ls "${FIXTURES}"/overlay*.dtbo > /dev/null 2>&1; then
	bad "DTBO fixtures missing in ${FIXTURES} (need stock-base.dtb," \
	    "prev-base-without-anchors.dtb, overlay0..8.dtbo; set C2S_DTBO_FIXTURES)"
else
	_tmpdir=$(mktemp -d)
	# positive control: stock base x all entries
	_pos=0
	for _ov in "${FIXTURES}"/overlay*.dtbo; do
		if fdtoverlay -i "${FIXTURES}/stock-base.dtb" \
			-o "${_tmpdir}/merged.dtb" "${_ov}" > /dev/null 2>&1; then
			_pos=$((_pos+1))
		fi
	done
	_nov=$(ls "${FIXTURES}"/overlay*.dtbo | wc -l)
	check "fdtoverlay positive control: stock base accepts all ${_nov} stock entries" \
		test "${_pos}" -eq "${_nov}"
	# negative control: previous candidate must fail (no anchor nodes)
	_neg_ok=1
	for _ov in "${FIXTURES}"/overlay*.dtbo; do
		if fdtoverlay -i "${FIXTURES}/prev-base-without-anchors.dtb" \
			-o "${_tmpdir}/merged.dtb" "${_ov}" > /dev/null 2>&1; then
			_neg_ok=0
		fi
	done
	check "fdtoverlay negative control: previous candidate fails (anchors needed)" \
		test "${_neg_ok}" -eq 1
	# the gate: our built DTB must accept every stock entry
	_gate=0
	for _ov in "${FIXTURES}"/overlay*.dtbo; do
		if fdtoverlay -i "${DTB}" -o "${_tmpdir}/merged.dtb" \
			"${_ov}" > /dev/null 2>&1; then
			_gate=$((_gate+1))
		else
			bad "fdtoverlay failed: ${_ov##*/} against built DTB"
		fi
	done
	if [ "${_gate}" -eq "${_nov}" ]; then
		ok "fdtoverlay gate: built DTB accepts all ${_nov} stock dtbo entries"
	fi
	rm -rf "${_tmpdir}"
fi

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
