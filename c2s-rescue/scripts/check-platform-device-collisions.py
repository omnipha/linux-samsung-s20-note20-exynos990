#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Host gate for Device Tree platform device name collisions (issue #5).

When Linux boots, platform devices are instantiated from Device Tree nodes
by of_platform_default_populate() and subsystem glue drivers (e.g.
dwc3-exynos calling of_platform_populate()).  Each platform device is
assigned a bus_id by of_device_make_bus_id() (drivers/of/device.c):
  - If the node has a translatable 'reg' property:
      <translated-base-addr-hex>.<node-name-before-@>
    (with an optional '.<mask-ffs>' component if 'mask' is present).
  - If not translatable or no 'reg':
      parent node names are prepended until unique.

When device_add() is called, sysfs creates a symbolic link in
/bus/platform/devices/<bus_id>.  If two distinct DT nodes produce the same
bus_id, the second device_add() fails with:
  sysfs: cannot create duplicate filename '/bus/platform/devices/<bus_id>'
and registration of that platform device aborts.

On c2s (diag12), this killed USB gadget initialization:
  - Stock anchor /usb@10E00000 (status="okay" after stock DTBO overlay,
    reg=<0x10e00000>) became platform device "10e00000.usb".
  - Live gadget child /soc@0/usb@10e00000/usb@0 (reg=<0x0>, translated via
    parent ranges to 0x10e00000) also produced platform device name
    "10e00000.usb".
  - dwc3_exynos_probe() called of_platform_populate() on /soc@0/usb@10e00000,
    device_add failed with -EEXIST, and the DWC3 core was never instantiated,
    leaving /sys/class/udc empty in userspace.

This gate inspects a DTB (or compiles a DTS) and simulates the kernel's
of_platform_default_populate() and of_device_make_bus_id() rules to detect
any collision between platform device names.

Exit codes:
  0  Check passed (no collisions, or collision present when --expect-collision set)
  1  Check failed (collision found, or expected collision missing)
  2  Usage / tooling error
"""

import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fdt

MATCH_COMPATIBLES = {"simple-bus", "simple-mfd", "isa", "arm,amba-bus"}
SKIPPED_COMPATIBLES = {"operating-points-v2"}
SUB_POPULATE_COMPATIBLES = {"samsung,exynos990-dwusb3", "samsung,exynos850-dwusb3"}


def get_cells(node):
    ac = node.prop('#address-cells')
    sc = node.prop('#size-cells')
    ac_val = fdt.cells(ac)[0] if ac else 2
    sc_val = fdt.cells(sc)[0] if sc else 1
    return ac_val, sc_val


def parse_reg(node):
    reg = node.prop('reg')
    if not reg:
        return None
    p = node.parent
    if not p:
        return None
    ac, sc = get_cells(p)
    words = fdt.cells(reg)
    if len(words) < ac + sc:
        return None
    addr = 0
    for w in words[:ac]:
        addr = (addr << 32) | w
    size = 0
    for w in words[ac:ac + sc]:
        size = (size << 32) | w
    return addr, size


def parse_ranges(node):
    ranges_p = node.prop('ranges')
    if ranges_p is None:
        return None
    if len(ranges_p) == 0:
        return []
    p = node.parent
    if not p:
        return None
    child_ac, child_sc = get_cells(node)
    parent_ac, parent_sc = get_cells(p)
    words = fdt.cells(ranges_p)
    entry_size = child_ac + parent_ac + child_sc
    entries = []
    for i in range(0, len(words), entry_size):
        chunk = words[i:i + entry_size]
        if len(chunk) < entry_size:
            break
        c_addr = 0
        for w in chunk[:child_ac]:
            c_addr = (c_addr << 32) | w
        p_addr = 0
        for w in chunk[child_ac:child_ac + parent_ac]:
            p_addr = (p_addr << 32) | w
        sz = 0
        for w in chunk[child_ac + parent_ac:]:
            sz = (sz << 32) | w
        entries.append((c_addr, p_addr, sz))
    return entries


def translate_address(node):
    p = node.parent
    if not p:
        return None
    reg = parse_reg(node)
    if not reg:
        return None
    addr, _ = reg
    curr = p
    while curr.parent is not None:
        ranges = parse_ranges(curr)
        if ranges is None:
            return None
        if len(ranges) == 0:
            pass
        else:
            mapped = False
            for c_addr, p_addr, sz in ranges:
                if c_addr <= addr < c_addr + sz:
                    addr = p_addr + (addr - c_addr)
                    mapped = True
                    break
            if not mapped:
                return None
        curr = curr.parent
    return addr


def of_node_name(node):
    return node.name.split('@')[0]


def of_device_make_bus_id(node):
    curr = node
    dev_name = None
    while curr.parent is not None:
        reg = curr.prop('reg')
        if reg is not None:
            addr = translate_address(curr)
            if addr is not None:
                nname = of_node_name(curr)
                mask = curr.prop('mask')
                if mask:
                    mask_val = fdt.cells(mask)[0]
                    ffs = (mask_val & -mask_val).bit_length() - 1
                    prefix = f"{addr:x}.{ffs:x}.{nname}"
                else:
                    prefix = f"{addr:x}.{nname}"
                if dev_name:
                    return f"{prefix}:{dev_name}"
                else:
                    return prefix
        kbase = curr.name
        if dev_name:
            dev_name = f"{kbase}:{dev_name}"
        else:
            dev_name = kbase
        curr = curr.parent
    return dev_name


def is_available(node):
    st = node.prop("status")
    if not st:
        return True
    return fdt.s(st) in ("okay", "ok")


def is_compatible(node, compat_set):
    c = node.prop("compatible")
    if not c:
        return False
    val = c.split(b'\x00')
    for item in val:
        if item.decode('utf-8', 'replace') in compat_set:
            return True
    return False


def collect_platform_devices(root):
    devices = {}

    chosen = root.kid("chosen")
    if chosen:
        for k in chosen.kids:
            if is_available(k) and is_compatible(k, {"simple-framebuffer"}):
                bid = of_device_make_bus_id(k)
                devices.setdefault(bid, []).append(k.path)

    def bus_create(node, matches, strict=True):
        if strict and not node.prop("compatible"):
            return
        if is_compatible(node, SKIPPED_COMPATIBLES):
            return
        if not is_available(node):
            return

        bid = of_device_make_bus_id(node)
        devices.setdefault(bid, []).append(node.path)

        if is_compatible(node, matches):
            for child in node.kids:
                bus_create(child, matches, strict=True)
        elif is_compatible(node, SUB_POPULATE_COMPATIBLES):
            for child in node.kids:
                bus_create(child, set(), strict=True)

    for child in root.kids:
        bus_create(child, MATCH_COMPATIBLES, strict=True)

    return devices


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dt_file", help="Path to DTB or DTS file to inspect")
    parser.add_argument("--expect-collision", action="store_true",
                        help="Negative control mode: expect at least one collision")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="List all populated platform devices")
    args = parser.parse_args()

    dt_path = args.dt_file
    tmp_dtb = None

    if dt_path.endswith(".dts"):
        tmp_dtb = tempfile.NamedTemporaryFile(suffix=".dtb", delete=False)
        tmp_dtb.close()
        res = subprocess.run(["dtc", "-@", "-I", "dts", "-O", "dtb", "-o", tmp_dtb.name, dt_path],
                             capture_output=True, text=True)
        if res.returncode != 0:
            sys.stderr.write(f"dtc compilation of {dt_path} failed:\n{res.stderr}\n")
            if os.path.exists(tmp_dtb.name):
                os.unlink(tmp_dtb.name)
            sys.exit(2)
        dtb_to_read = tmp_dtb.name
    else:
        dtb_to_read = dt_path

    try:
        data = open(dtb_to_read, "rb").read()
        root = fdt.parse(data)
    finally:
        if tmp_dtb and os.path.exists(tmp_dtb.name):
            os.unlink(tmp_dtb.name)

    devices = collect_platform_devices(root)
    collisions = {bid: paths for bid, paths in devices.items() if len(paths) > 1}

    if args.verbose:
        for bid in sorted(devices):
            paths = devices[bid]
            mark = " [COLLISION]" if len(paths) > 1 else ""
            print(f"  {bid}{mark}: {paths}")

    if args.expect_collision:
        if collisions:
            desc = ", ".join(f"{bid} ({' vs '.join(paths)})" for bid, paths in collisions.items())
            print(f"PASS: negative control: collision correctly detected on: {desc}")
            sys.exit(0)
        else:
            print("FAIL: negative control: expected platform device collision but found none",
                  file=sys.stderr)
            sys.exit(1)
    else:
        if collisions:
            desc = ", ".join(f"{bid} ({' vs '.join(paths)})" for bid, paths in collisions.items())
            print(f"FAIL: platform device name collision detected: {desc}",
                  file=sys.stderr)
            sys.exit(1)
        else:
            print(f"PASS: 0 platform device name collisions ({len(devices)} unique platform devices)")
            sys.exit(0)


if __name__ == "__main__":
    main()
