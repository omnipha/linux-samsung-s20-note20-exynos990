# USB gadget state machine for the c2s rescue image (sourced, POSIX sh).
#
# This file is sourced by /init on the device AND by
# c2s-rescue/scripts/fault-injection.sh on the build host, so that the
# *exact* code shipped in the initramfs can be exercised against a fake
# configfs/UDC tree with controlled faults (NCM failure, RNDIS failure,
# absent UDC, all-success). Nothing here is a test hook: the path
# parameters only exist because the host harness runs the same code in a
# temporary directory.
#
# There is exactly ONE UDC on this device (10e00000.dwc3). ACM, NCM and
# RNDIS are functions of ONE configfs gadget bound to that one UDC - the
# machine below never claims simultaneous or independent UDCs. What it
# does guarantee is that a network function failure (NCM or RNDIS
# creation, linking or binding) cannot prevent the ACM function - and
# with it the ttyGS rescue console - from being created, linked and
# bound: the network functions are optional, ACM is mandatory, and a
# failed full bind falls back to an ACM-only bind on the same UDC.
#
# Path parameters (defaults are the device paths):
#   C2S_CONFIGFS  configfs mount point        (default /sys/kernel/config)
#   C2S_UDC_DIR   UDC class directory         (default /sys/class/udc)
#   C2S_LOG       append gadget log lines here instead of the kernel log
#   C2S_BIND_TRIES   bind attempts            (default 5)
#   C2S_BIND_DELAY   seconds between attempts (default 1)
#   C2S_UDC_TRIES    UDC discovery attempts   (default 10)
#   C2S_UDC_DELAY    seconds between them     (default 0.5)
#
# Results exported to the caller:
#   C2S_GADGET_STATUS  0 = bound (network active), 1 = setup failed,
#                      2 = no UDC (nothing enumerated),
#                      3 = every bind attempt failed (nothing enumerated)
#   C2S_GADGET_STAGE   machine-readable stage string (see the log lines)
#   C2S_GADGET_LINKED  space-separated function instances linked into
#                      configs/c.1 (what the host would see, if a UDC
#                      were bound)
#   C2S_GADGET_UDC     bound UDC name, empty if not bound
#   C2S_NCM_IF         NCM netdev name, empty if NCM is not in use
#   C2S_RNDIS_IF       RNDIS netdev name, empty if RNDIS is not in use

C2S_CONFIGFS="${C2S_CONFIGFS:-/sys/kernel/config}"
C2S_UDC_DIR="${C2S_UDC_DIR:-/sys/class/udc}"
C2S_BIND_TRIES="${C2S_BIND_TRIES:-5}"
C2S_BIND_DELAY="${C2S_BIND_DELAY:-1}"
C2S_UDC_TRIES="${C2S_UDC_TRIES:-10}"
C2S_UDC_DELAY="${C2S_UDC_DELAY:-0.5}"

c2s_glog() {
    if [ -n "${C2S_LOG:-}" ]; then
        echo "c2s-rescue: $*" >> "${C2S_LOG}"
        return 0
    fi
    if [ -w "${KMSG:-/dev/kmsg}" ]; then
        echo "c2s-rescue: $*" > "${KMSG}" 2> /dev/null && return 0
    fi
    echo "c2s-rescue: $*"
}

# Bind the gadget to the UDC. Kept in one function so callers (and the
# host fault harness) can see exactly where enumeration starts.
# A failed usb_gadget_register_driver() leaves configfs with udc_name
# cleared again (gadget_dev_desc_UDC_store() error path), so retrying
# and unlinking functions between attempts is legal.
c2s_bind_udc() {
    _cfg="$1"
    _udc="$2"
    _i=1
    while [ "${_i}" -le "${C2S_BIND_TRIES}" ]; do
        if echo "${_udc}" > "${_cfg}/UDC" 2> /dev/null; then
            return 0
        fi
        [ "${_i}" -lt "${C2S_BIND_TRIES}" ] && sleep "${C2S_BIND_DELAY}"
        _i=$((_i + 1))
    done
    return 1
}

c2s_gadget_setup() {
    cfg="${C2S_CONFIGFS}/usb_gadget/c2s"
    C2S_GADGET_STATUS=1
    C2S_GADGET_STAGE="cfgfs-fail"
    C2S_GADGET_LINKED=""
    C2S_GADGET_UDC=""
    C2S_NCM_IF=""
    C2S_RNDIS_IF=""

    # ---------------------------------------------------------- skeleton
    mkdir -p "${cfg}" || {
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:${C2S_GADGET_STAGE}" \
                 "cannot create ${cfg}"
        return "${C2S_GADGET_STATUS}"
    }
    # Linux Foundation example VID/PID (Documentation/usb/gadget_configfs.rst)
    echo 0x1d6b > "${cfg}/idVendor"
    echo 0x0104 > "${cfg}/idProduct"
    echo 0x0100 > "${cfg}/bcdDevice"
    echo 0x0200 > "${cfg}/bcdUSB"

    mkdir -p "${cfg}/strings/0x409"
    echo "c2s rescue"  > "${cfg}/strings/0x409/product"
    echo "omnipha"     > "${cfg}/strings/0x409/manufacturer"
    echo "c2s-rescue"  > "${cfg}/strings/0x409/serialnumber"

    mkdir -p "${cfg}/configs/c.1/strings/0x409"
    echo "c2s rescue (ACM console + NCM/RNDIS)" \
        > "${cfg}/configs/c.1/strings/0x409/configuration"
    echo 500 > "${cfg}/configs/c.1/MaxPower"

    # ------------------------------------------------------- ACM (required)
    # Creating this instance allocates gserial line 0, and
    # gserial_alloc_line() calls gs_console_init() for line 0
    # (drivers/usb/gadget/function/u_serial.c), which register_console()s
    # the ttyGS console with CON_PRINTBUFFER: from this point every
    # printk (and everything /init logs through /dev/kmsg) is fanned out
    # to the USB serial console and kept in the ring buffer for `dmesg`.
    # This happens BEFORE any bind and independently of NCM/RNDIS, so the
    # rescue console exists even when the network functions cannot be set
    # up. NCM/RNDIS never allocate a gserial line, so ACM is always ttyGS0.
    if ! mkdir -p "${cfg}/functions/acm.usb2"; then
        C2S_GADGET_STAGE="acm-instance-fail"
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:${C2S_GADGET_STAGE}" \
                 "cannot create the ACM function instance - no rescue console"
        return "${C2S_GADGET_STATUS}"
    fi
    # Make the console binding explicit (idempotent: gs_console_init()
    # returns immediately if port->console is set). Guarded, because the
    # configfs attribute only exists with CONFIG_U_SERIAL_CONSOLE.
    echo 1 > "${cfg}/functions/acm.usb2/console" 2> /dev/null || true
    if ! ln -s "${cfg}/functions/acm.usb2" "${cfg}/configs/c.1/" 2> /dev/null; then
        C2S_GADGET_STAGE="acm-link-fail"
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:${C2S_GADGET_STAGE}" \
                 "cannot link the ACM function - no rescue console"
        return "${C2S_GADGET_STATUS}"
    fi
    C2S_GADGET_LINKED="acm.usb2"
    c2s_glog "gadget stage=${C2S_GADGET_STATUS}:acm-linked" \
             "ACM console function linked (ttyGS0 console registered)"

    # --------------------------------------------------- NCM / RNDIS (optional)
    # Each network function is attempted on its own; a failure only drops
    # that link, it never aborts the machine and never unlinks ACM.
    # ifname may only be written while the function is not linked into a
    # configuration (u_ether opts->refcnt == 0), i.e. before the ln -s.
    if mkdir -p "${cfg}/functions/ncm.usb0" \
       && echo "ncm%d" > "${cfg}/functions/ncm.usb0/ifname" 2> /dev/null \
       && ln -s "${cfg}/functions/ncm.usb0" "${cfg}/configs/c.1/" 2> /dev/null; then
        C2S_GADGET_LINKED="${C2S_GADGET_LINKED} ncm.usb0"
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:ncm-linked" \
                 "NCM linked into the same gadget (single UDC)"
    else
        rm -rf "${cfg}/functions/ncm.usb0" 2> /dev/null
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:ncm-skipped" \
                 "NCM setup failed; continuing with ACM" \
                 "on the single UDC"
    fi

    if mkdir -p "${cfg}/functions/rndis.usb1" \
       && echo "rndis%d" > "${cfg}/functions/rndis.usb1/ifname" 2> /dev/null \
       && ln -s "${cfg}/functions/rndis.usb1" "${cfg}/configs/c.1/" 2> /dev/null; then
        C2S_GADGET_LINKED="${C2S_GADGET_LINKED} rndis.usb1"
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:rndis-linked" \
                 "RNDIS linked into the same gadget (single UDC)"
    else
        rm -rf "${cfg}/functions/rndis.usb1" 2> /dev/null
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:rndis-skipped" \
                 "RNDIS setup failed; continuing with ACM" \
                 "on the single UDC"
    fi

    # ----------------------------------------------------------- UDC
    # The dwc3-exynos UDC may finish probing after configfs is mounted,
    # so discovery is retried. An empty class directory is NOT a setup
    # failure: it means no USB device will appear at all, which the
    # caller must be able to tell apart from "bound but broken".
    _i=1
    _udc=""
    while [ "${_i}" -le "${C2S_UDC_TRIES}" ]; do
        _udc=$(ls -1 "${C2S_UDC_DIR}" 2> /dev/null | head -n 1)
        [ -n "${_udc}" ] && break
        [ "${_i}" -lt "${C2S_UDC_TRIES}" ] && sleep "${C2S_UDC_DELAY}"
        _i=$((_i + 1))
    done
    if [ -z "${_udc}" ]; then
        C2S_GADGET_STATUS=2
        C2S_GADGET_STAGE="udc-absent"
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:${C2S_GADGET_STAGE}" \
                 "no UDC in ${C2S_UDC_DIR}; linked=[${C2S_GADGET_LINKED}]" \
                 "- NOTHING enumerated on USB (ACM function exists, no UDC)"
        return "${C2S_GADGET_STATUS}"
    fi

    # ----------------------------------------------------------- bind
    # Preferred bind: every linked function (ACM + whatever network
    # functions made it). If that fails, drop the network functions and
    # retry with ACM alone on the SAME UDC - the independent fallback
    # that keeps the console channel alive when networking cannot bind.
    if c2s_bind_udc "${cfg}" "${_udc}"; then
        C2S_GADGET_STATUS=0
        C2S_GADGET_STAGE="bound"
        C2S_GADGET_UDC="${_udc}"
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:${C2S_GADGET_STAGE}" \
                 "udc=${_udc} linked=[${C2S_GADGET_LINKED}]"
    else
        c2s_glog "gadget stage=${C2S_GADGET_STATUS}:bind-failed-full" \
                 "bind with [${C2S_GADGET_LINKED}] failed on ${_udc};" \
                 "falling back to ACM only"
        for _f in "${cfg}/configs/c.1/ncm.usb0" "${cfg}/configs/c.1/rndis.usb1"; do
            [ -L "${_f}" ] && rm -f "${_f}"
        done
        C2S_GADGET_LINKED="acm.usb2"
        if c2s_bind_udc "${cfg}" "${_udc}"; then
            C2S_GADGET_STATUS=0
            C2S_GADGET_STAGE="bound-acm-fallback"
            C2S_GADGET_UDC="${_udc}"
            c2s_glog "gadget stage=${C2S_GADGET_STATUS}:${C2S_GADGET_STAGE}" \
                     "udc=${_udc} linked=[${C2S_GADGET_LINKED}]" \
                     "- network functions dropped, console channel up"
        else
            C2S_GADGET_STATUS=3
            C2S_GADGET_STAGE="bind-failed-all"
            c2s_glog "gadget stage=${C2S_GADGET_STATUS}:${C2S_GADGET_STAGE}" \
                     "all bind attempts failed on ${_udc};" \
                     "NOTHING enumerated (functions linked but not bound)"
            return "${C2S_GADGET_STATUS}"
        fi
    fi

    # --------------------------------------------------- read back netdevs
    # Only functions still linked have registered a netdev; read the
    # actual names (gether_set_ifname() substituted %d at bind time).
    if [ -L "${cfg}/configs/c.1/ncm.usb0" ]; then
        C2S_NCM_IF=$(cat "${cfg}/functions/ncm.usb0/ifname" 2> /dev/null)
    fi
    if [ -L "${cfg}/configs/c.1/rndis.usb1" ]; then
        C2S_RNDIS_IF=$(cat "${cfg}/functions/rndis.usb1/ifname" 2> /dev/null)
    fi
    c2s_glog "gadget stage=${C2S_GADGET_STAGE}:netdevs" \
             "ncm=${C2S_NCM_IF:-none} rndis=${C2S_RNDIS_IF:-none}"
    return "${C2S_GADGET_STATUS}"
}
