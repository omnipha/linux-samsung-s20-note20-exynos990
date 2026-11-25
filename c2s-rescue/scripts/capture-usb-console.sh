#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Capture the c2s rescue USB serial console (ACM/ttyGS) on the *host*
# while the coordinator performs the hardware run.
#
# Usage:
#   c2s-rescue/scripts/capture-usb-console.sh [outfile] [device]
#
#   outfile   where to append the capture   (default: c2s-ttygs-<ts>.log)
#   device    CDC-ACM device                (default: first /dev/ttyACM*)
#
# What you get:
#   - every kernel printk that the ttyGS console prints AFTER the ACM
#     function is registered (the console is registered by /init at the
#     `acm-linked` stage, see /usr/lib/c2s-gadget.sh), and
#   - every init line that /init writes through /dev/kmsg
#     (printk.devkmsg=on is on the kernel command line, so devkmsg_write()
#     does not ratelimit/drop them),
#   - plus, at the moment the port is opened, the kernel's replay of the
#     ring buffer captured so far (CON_PRINTBUFFER on the ttyGS console,
#     drivers/usb/gadget/function/u_serial.c) - that is how the messages
#     printed BEFORE the ACM instance existed can still be read.
#
# Limits (read before reporting results):
#   - the ttyGS console keeps at most GS_CONSOLE_BUF_SIZE = 8192 bytes;
#     overflow is DROPPED, not blocked, so a host that opens the port
#     late can miss early lines that never fitted in the buffer;
#   - `dmesg`/`cat /proc/kmsg` over SSH shows the FULL ring buffer, the
#     serial console shows only what fit in the 8 KiB console buffer plus
#     what arrives while the port is open;
#   - nothing here reaches the device: this script only reads a local
#     tty device on the host.
#
# Exit code 0 = capture started/finished cleanly, 1 = no device found.

set -uo pipefail

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="${1:-c2s-ttygs-${TS}.log}"
DEV="${2:-}"

if [ -z "${DEV}" ]; then
	for d in /dev/ttyACM* /dev/ttyUSB*; do
		[ -c "${d}" ] || continue
		DEV="${d}"
		break
	done
fi
if [ -z "${DEV}" ] || [ ! -c "${DEV}" ]; then
	echo "no CDC-ACM/serial device found (plug the rescue device, or pass the device path)" >&2
	echo "nothing was captured - this is a host-side limitation, not a device result" >&2
	exit 1
fi

echo "== capturing ${DEV} -> ${OUT}"
echo "== host timestamps are added by this script; device lines keep the"
echo "== kernel <N> prefix (printk) or the 'c2s-rescue:' prefix (init)"
# raw mode: no line discipline mangling, no echo, binary-safe
stty -F "${DEV}" raw -echo -echoe -echok -echoctl -echoke -hupcl \
	baudrate 115200 cs8 -cstopb -parenb 2> /dev/null || true
exec 3< "${DEV}"
trap 'exec 3<&-; echo; echo "== capture closed: ${OUT} ($(stat -c %s "${OUT}" 2>/dev/null || echo 0) bytes)"; exit 0' INT TERM
while IFS= read -r -u 3 line; do
	printf '%s %s\n' "$(date -u +%H:%M:%S)" "${line}" >> "${OUT}"
	echo "${line}"
done
