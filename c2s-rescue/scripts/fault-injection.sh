#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Host-side fault injection for the c2s rescue USB gadget state machine.
#
# The harness runs the *exact* code shipped in the initramfs
# (/usr/lib/c2s-gadget.sh, extracted from the built cpio archive when one
# exists, otherwise the source file) against a fake configfs + fake UDC
# class directory in a temporary directory, with controlled faults:
#
#   1. NCM failure        (function instance creation is made to fail)
#   2. RNDIS failure      (same, for the RNDIS instance)
#   3. absent UDC         (empty UDC class directory)
#   4. all-success        (every function links, UDC present)
#   5. bind-unwritable    (UDC file not writable -> every bind attempt
#                          fails; exercises the ACM-only fallback and the
#                          "nothing enumerated" stage)
#
# What this proves (host-only):
#   - the state machine keeps ACM linked and bound when NCM or RNDIS
#     setup fails: ACM enumeration is an independent fallback on the ONE
#     UDC (10e00000.dwc3), not a second UDC;
#   - an absent UDC is reported as status 2 (stage=udc-absent) and is
#     distinguishable from a bind failure (status 3) and from setup
#     failure (status 1);
#   - the stage machine logs every transition it reached.
#
# What this does NOT prove (stages that cannot be observed on a host):
#   - that any USB device is actually enumerated on hardware (no UDC, no
#     cable, no host controller here);
#   - that ttyGS0 delivers kernel messages (needs the real gserial
#     gadget + a CDC-ACM host driver);
#   - that NCM/RNDIS netdevs come up or that dropbear is reachable;
#   - configfs-specific semantics (EBUSY on ifname after linking,
#     udc_name locking, function re-binding): the fake tree is a plain
#     directory tree, so it models the *sequence*, not the kernel's
#     configfs behaviour.
#
# Usage: c2s-rescue/scripts/fault-injection.sh [OUTDIR]
# Exit code 0 = every case matched its expectation.

set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RESCUE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
REPO_DIR=$(cd -- "${RESCUE_DIR}/.." && pwd)
OUTDIR="${1:-${C2S_OUTDIR:-/tmp/opencode/c2s-out}}"
WORK="${OUTDIR}/work"
UNPACK="${OUTDIR}/verify-root"

PASS=0
FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
note() { echo "---  $*"; }

# Prefer the shipped archive content: the harness must test what boots.
GADGET_SRC="${UNPACK}/usr/lib/c2s-gadget.sh"
if [ -s "${GADGET_SRC}" ]; then
	echo "### testing the shipped /usr/lib/c2s-gadget.sh from the initramfs"
else
	GADGET_SRC="${RESCUE_DIR}/initramfs/usr/lib/c2s-gadget.sh"
	note "initramfs not unpacked yet; testing the source tree copy"
	if [ ! -s "${GADGET_SRC}" ]; then
		echo "FAIL: no gadget state machine to test" >&2
		exit 1
	fi
fi

BASE=$(mktemp -d /tmp/opencode/c2s-fault.XXXXXX)
trap 'rm -rf "${BASE}"' EXIT

# run_case NAME UDC_PRESENT NCM_FAULT RNDIS_FAULT BIND_UNWRITABLE
#   -> prints stdout, writes the log to $BASE/$NAME.log, exports
#      CASE_STATUS / CASE_STAGE / CASE_LINKED / CASE_NCM / CASE_RNDIS
run_case() {
	local name="$1" udc="$2" ncm_fault="$3" rndis_fault="$4" bind_unw="$5"
	local root="${BASE}/${name}"
	rm -rf "${root}"
	mkdir -p "${root}/config/usb_gadget" "${root}/udc" "${root}/log"
	if [ "${udc}" = yes ]; then
		# the device has exactly one UDC
		: > "${root}/udc/10e00000.dwc3"
	fi

	# Fault injection is done purely through the filesystem layout the
	# state machine walks: a regular file where mkdir -p expects a
	# directory makes that creation fail (mkdir: File exists).
	if [ "${ncm_fault}" = yes ]; then
		mkdir -p "${root}/config/usb_gadget/preexist"
		: > "${root}/config/usb_gadget/preexist/ncm.usb0"
	fi
	if [ "${rndis_fault}" = yes ]; then
		mkdir -p "${root}/config/usb_gadget/preexist"
		: > "${root}/config/usb_gadget/preexist/rndis.usb1"
	fi

	# The NCM/RNDIS fault above must land on the path the state machine
	# uses (usb_gadget/c2s/functions/ncm.usb0). Since c2s is created by
	# the code itself, we instead pre-create the c2s/functions tree with
	# the blocking file in place.
	if [ "${ncm_fault}" = yes ] || [ "${rndis_fault}" = yes ]; then
		local f="${root}/config/usb_gadget/c2s/functions"
		mkdir -p "${f}"
		[ "${ncm_fault}" = yes ]   && : > "${f}/ncm.usb0"
		[ "${rndis_fault}" = yes ] && : > "${f}/rndis.usb1"
	fi
	if [ "${bind_unw}" = yes ]; then
		# model a UDC that refuses to bind: the UDC attribute file is
		# read-only, so every "echo $udc > UDC" write fails.
		mkdir -p "${root}/config/usb_gadget/c2s"
		: > "${root}/config/usb_gadget/c2s/UDC"
		chmod 0444 "${root}/config/usb_gadget/c2s/UDC"
	fi

	CASE_LOG="${root}/gadget.log"
	: > "${CASE_LOG}"
	local status stage
	status=$(env -i PATH=/usr/bin:/bin HOME="${root}" \
		C2S_CONFIGFS="${root}/config" \
		C2S_UDC_DIR="${root}/udc" \
		C2S_LOG="${CASE_LOG}" \
		C2S_BIND_TRIES=2 C2S_BIND_DELAY=0 \
		C2S_UDC_TRIES=2  C2S_UDC_DELAY=0 \
		sh -c ". \"\$1\" && c2s_gadget_setup; echo \"\$?\"" \
		_ "${GADGET_SRC}" 2> "${root}/stderr.log")
	CASE_STATUS="${status##*$'\n'}"
	CASE_STAGE=$(sed -n 's/.*gadget stage=[0-9]*:\([a-z-]*\).*/\1/p' "${CASE_LOG}" | tail -n1)
	CASE_LINKED=$(sed -n 's/.*linked=\[\([^]]*\)\].*/\1/p' "${CASE_LOG}" | tail -n1)
	CASE_NCM=$(sed -n 's/.*ncm=\([a-z0-9]*\).*/\1/p' "${CASE_LOG}" | tail -n1)
	CASE_RNDIS=$(sed -n 's/.*rndis=\([a-z0-9]*\).*/\1/p' "${CASE_LOG}" | tail -n1)
	[ -n "${CASE_LINKED}" ] || CASE_LINKED="<none>"
	echo "### case: ${name} (status=${CASE_STATUS} stage=${CASE_STAGE} linked=[${CASE_LINKED}])"
	sed 's/^/    | /' "${CASE_LOG}"
	[ -s "${root}/stderr.log" ] && sed 's/^/    ! /' "${root}/stderr.log"
	# The linked set as the fake configfs now sees it (ground truth
	# independent of what the state machine logged): entries other than
	# the strings/ dir and the MaxPower attribute are the function links.
	CASE_FS_LINKED=$(cd "${root}/config/usb_gadget/c2s/configs/c.1" 2>/dev/null \
		&& ls -1 | grep -vx 'strings' | grep -vx 'MaxPower' \
		 | tr '\n' ' ' | sed 's/ $//')
	[ -n "${CASE_FS_LINKED}" ] || CASE_FS_LINKED="<none>"
}

has_word() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

echo "### fault injection against: ${GADGET_SRC}"
echo "### scratch: ${BASE}"

# ------------------------------------------------------------------ case 1
run_case "ncm-fail" yes yes no no
if [ "${CASE_STATUS}" = 0 ] && has_word "${CASE_FS_LINKED}" "acm.usb2"; then
	ok "case 1 NCM failure: ACM still linked and bound (status 0, fallback holds)"
else
	bad "case 1 NCM failure: status=${CASE_STATUS} stage=${CASE_STAGE} fs=[${CASE_FS_LINKED}]; ACM must survive an NCM failure"
fi
if has_word "${CASE_FS_LINKED}" "ncm.usb0"; then
	bad "case 1 NCM failure: ncm.usb0 is linked despite the injected fault"
else
	ok "case 1 NCM failure: ncm.usb0 not linked (fault took effect)"
fi

# ------------------------------------------------------------------ case 2
run_case "rndis-fail" yes no yes no
if [ "${CASE_STATUS}" = 0 ] && has_word "${CASE_FS_LINKED}" "acm.usb2"; then
	ok "case 2 RNDIS failure: ACM still linked and bound (status 0, fallback holds)"
else
	bad "case 2 RNDIS failure: status=${CASE_STATUS} stage=${CASE_STAGE} fs=[${CASE_FS_LINKED}]; ACM must survive a RNDIS failure"
fi
if has_word "${CASE_FS_LINKED}" "rndis.usb1"; then
	bad "case 2 RNDIS failure: rndis.usb1 is linked despite the injected fault"
else
	ok "case 2 RNDIS failure: rndis.usb1 not linked (fault took effect)"
fi

# ------------------------------------------------------------------ case 3
run_case "udc-absent" no no no no
if [ "${CASE_STATUS}" = 2 ] && [ "${CASE_STAGE}" = "udc-absent" ]; then
	ok "case 3 absent UDC: status 2 / stage udc-absent (no UDC => nothing enumerated, clearly reported)"
else
	bad "case 3 absent UDC: got status=${CASE_STATUS} stage=${CASE_STAGE}, want 2/udc-absent"
fi
if has_word "${CASE_FS_LINKED}" "acm.usb2"; then
	ok "case 3 absent UDC: ACM function still linked (ready the moment a UDC appears)"
else
	bad "case 3 absent UDC: ACM not linked: fs=[${CASE_FS_LINKED}]"
fi

# ------------------------------------------------------------------ case 4
run_case "all-ok" yes no no no
if [ "${CASE_STATUS}" = 0 ] && [ "${CASE_STAGE}" = "bound" ] \
   && [ "${CASE_FS_LINKED}" = "acm.usb2 ncm.usb0 rndis.usb1" ]; then
	ok "case 4 all-success: status 0 / stage bound, all three functions linked on the single UDC"
else
	bad "case 4 all-success: status=${CASE_STATUS} stage=${CASE_STAGE} fs=[${CASE_FS_LINKED}]"
fi
if [ "${CASE_LINKED}" != "${CASE_FS_LINKED}" ]; then
	bad "case 4 all-success: logged linked=[${CASE_LINKED}] != file system [${CASE_FS_LINKED}]"
else
	ok "case 4 all-success: state machine report matches the tree"
fi

# ------------------------------------------------------------------ case 5
run_case "bind-unwritable" yes no no yes
if [ "${CASE_STATUS}" = 3 ] && [ "${CASE_STAGE}" = "bind-failed-all" ]; then
	ok "case 5 unbindable UDC: status 3 / stage bind-failed-all (ACM-only retry also failed, NOTHING enumerated)"
else
	bad "case 5 unbindable UDC: status=${CASE_STATUS} stage=${CASE_STAGE}, want 3/bind-failed-all"
fi
if grep -q "bind-failed-full" "${CASE_LOG}" \
   && grep -q "acm.usb2" "${CASE_LOG}"; then
	ok "case 5 unbindable UDC: full bind attempted first, ACM-only fallback attempted afterwards"
else
	bad "case 5 unbindable UDC: fallback sequence not logged"
fi

# --------------------------------------------------------------- summary
echo
echo "fault-injection: ${PASS} passed, ${FAIL} failed"
echo
echo "Limits of these results (cannot be observed on this host):"
echo "  - no USB enumeration is proven: no UDC, cable, or host controller"
echo "    is present, so 'bound' means the state machine completed, not"
echo "    that a host saw a device;"
echo "  - ttyGS0 console delivery, netdev creation, and SSH reachability"
echo "    need a hardware run by the coordinator;"
echo "  - the fake configfs is a plain directory tree: kernel-side"
echo "    configfs errors (EBUSY, udc_name locking) are not reproduced;"
echo "  - therefore these tests are necessary evidence for the fallback"
echo "    logic, not proof of device behaviour."
echo
[ "${FAIL}" -eq 0 ]
