#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""CFG-reachability regression for the C2S diagnostic marker ladder.

Marker *bytes* in the Image prove the code was compiled in; they say nothing
about whether the CPU can ever execute it.  The defect this gate exists for:

  arch/arm64/kernel/head.S (primary_entry) placed the M1b green band between
  the `0:` label and the `1:` label, while the MMU-off entry path - the path
  this device actually takes, because the bootloader disables the MMU before
  jumping to the kernel - executed `b 1f` and jumped *over* the whole block.
  Every byte-level gate still passed (the movz/movk colour build was present
  and solid), and the green band simply never appeared on the panel.

This script builds a control-flow graph from the *disassembly* of a function
and reports, per marker, whether its first instruction is reachable from the
function entry point.  For primary_entry it additionally splits reachability
at the `cbnz x19` MMU-state branch: that branch selects the two entry paths,
and it is the fall-through (MMU-off) side the defect skipped.

Exit codes:
  0  every marker reachable (or no markers at all, i.e. a baseline build)
  1  at least one marker unreachable  <-- the regression this guards
  2  usage / tooling error
"""

import argparse
import re
import subprocess
import sys

# Marker colours as built in head.S.  The painters build a 64-bit value for
# a "stp x4, x4" store, i.e. TWO a8r8g8b8 pixels per store, so the low and
# the high 32-bit half carry the same colour.  The keys below are the full
# 64-bit values; the low 32 bits are the a8r8g8b8 colour that reaches the
# panel.
MARKER_COLOURS = {
    0xFFFFFFFFFFFFFFFF: "M1-white",
    0xFF00FF00FF00FF00: "M1b-green",
    0xFFFF0000FFFF0000: "M2-red",
    0xFF0000FFFF0000FF: "M3-blue",
    0xFFFF00FFFFFF00FF: "M4-magenta",
}

# The stride/height prologue every band painter emits; used to locate the
# colour build in front of it (same anchor the Image-level band gate uses).
STRIDE = 0x1680  # 5760 bytes = 1440 px * 4
HEIGHT = 0x80  # 128 rows

INSN_RE = re.compile(r"^([0-9a-f]{8,}):\s+([0-9a-f]+)\s+(\S+)\s*(.*)$")
TARGET_RE = re.compile(r"\b([0-9a-f]{8,})\b")
X4_MOV_RE = re.compile(r"^x4, #0x([0-9a-f]+)$")
X4_MOVK_RE = re.compile(r"^x4, #0x([0-9a-f]+), lsl #(\d+)$")


def disassemble(vmlinux, function, objdump="aarch64-linux-gnu-objdump"):
    """Return the objdump text for one function, or None if unavailable."""
    try:
        proc = subprocess.run(
            [objdump, "-d", "--disassemble=%s" % function, vmlinux],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError as exc:
        print("ERROR: cannot run %s: %s" % (objdump, exc), file=sys.stderr)
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    return proc.stdout


def read_disasm_file(path):
    """Read a saved objdump listing instead of disassembling a vmlinux.

    Used by the regression's negative control: the pre-fix disassembly is
    kept as a fixture in the repository so the gate can prove it is
    sensitive without needing the old build tree.
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print("ERROR: cannot read %s: %s" % (path, exc), file=sys.stderr)
        return None
    if not text.strip():
        print("ERROR: %s is empty" % path, file=sys.stderr)
        return None
    return text


def parse_instructions(text):
    """Parse objdump output into [(addr, mnemonic, operands), ...]."""
    insns = []
    for line in text.splitlines():
        m = INSN_RE.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        mnemonic = m.group(3)
        operands = m.group(4).split("//")[0].strip()
        insns.append((addr, mnemonic, operands))
    return insns


def build_cfg(insns):
    """Return {addr: [successor addresses]} plus the ordered address list."""
    if not insns:
        return {}, []
    order = [a for a, _, _ in insns]
    lo, hi = order[0], order[-1]
    index = {addr: i for i, addr in enumerate(order)}

    def fallthrough(addr):
        i = index[addr]
        return order[i + 1] if i + 1 < len(order) else None

    cfg = {}
    for addr, mnemonic, operands in insns:
        succ = []
        # Terminal: no successors at all.
        if mnemonic in ("ret", "eret", "br", "brk", "hlt"):
            cfg[addr] = succ
            continue
        target = None
        tm = TARGET_RE.search(operands)
        if tm:
            cand = int(tm.group(1), 16)
            if lo <= cand <= hi:
                target = cand
        if mnemonic in ("b", "b.al"):
            # Unconditional: only the target (fallthrough is unreachable).
            cfg[addr] = [target] if target is not None else []
            continue
        if mnemonic in ("bl", "blr", "blraa", "blrab", "braa", "brab"):
            # Calls return; for reachability *within* this function only the
            # fallthrough matters (the callee's body is a different function).
            nxt = fallthrough(addr)
            cfg[addr] = [nxt] if nxt is not None else []
            continue
        if mnemonic.startswith("b.") or mnemonic in (
            "cbz",
            "cbnz",
            "tbz",
            "tbnz",
        ):
            # Conditional: both the target and the fallthrough.
            nxt = fallthrough(addr)
            succ = [t for t in (target, nxt) if t is not None]
            cfg[addr] = succ
            continue
        # Ordinary instruction: fallthrough only.
        nxt = fallthrough(addr)
        cfg[addr] = [nxt] if nxt is not None else []
    return cfg, order


def reachable(cfg, start, cut=None):
    """Set of addresses reachable from `start` following cfg edges.

    `cut` is an optional {addr: allowed_successors} override: the edges of
    that address are replaced by the given list.  It is used to split the
    CFG at the MMU-state branch: for the cache-off path the branch's
    *taken* edge is removed, for the cache-on path its *fallthrough* edge.
    Both paths still start at the function entry, so code that runs before
    the branch (e.g. the M1 band) belongs to both paths.
    """
    if start is None:
        return set()
    seen = set()
    stack = [start]
    while stack:
        addr = stack.pop()
        if addr in seen:
            continue
        seen.add(addr)
        succ = cfg.get(addr, ())
        if cut is not None and addr in cut:
            succ = cut[addr]
        for nxt in succ:
            if nxt not in seen:
                stack.append(nxt)
    return seen


def find_markers(insns):
    """Locate band markers by their stride+height prologue.

    Returns [(marker_addr, colour), ...] in address order.  The colour build
    (movz x4 + up to 3 movk x4) immediately in front of the prologue is
    reconstructed the same way the Image-level gate does, so a truncated
    build yields a wrong colour and simply does not match a known marker.
    """
    markers = []
    for i in range(len(insns) - 1):
        addr, mnemonic, operands = insns[i]
        if mnemonic != "mov" or operands != "x9, #0x%x" % STRIDE:
            continue
        nxt_addr, nxt_mnem, nxt_ops = insns[i + 1]
        if nxt_mnem != "mov" or nxt_ops != "x10, #0x%x" % HEIGHT:
            continue
        # Walk back over the colour build: movz x4 + movk x4 (lsl 16/32/48).
        colour = None
        marker_addr = None
        chunks = []
        j = i - 1
        while j >= 0:
            b_addr, b_mnem, b_ops = insns[j]
            if b_mnem == "movk":
                m = X4_MOVK_RE.match(b_ops)
                if not m:
                    break
                chunks.append((int(m.group(2)), int(m.group(1), 16)))
                marker_addr = b_addr
                j -= 1
                continue
            if b_mnem == "mov":
                m = X4_MOV_RE.match(b_ops)
                if not m:
                    break
                chunks.append((0, int(m.group(1), 16)))
                marker_addr = b_addr
                break
            break
        if marker_addr is None or len(chunks) < 1:
            continue
        # chunks are collected newest-first; rebuild low16 -> high16.
        chunks.reverse()
        colour = 0
        for shift, value in chunks:
            colour |= (value & 0xFFFF) << shift
        # A marker is recognised by its *shape* (a colour build in front of
        # the stride/height prologue), not by its colour value: colour
        # correctness is the business of the Image-level band gate, and a
        # marker with a broken colour must still be reachability-checked.
        markers.append((marker_addr, colour))
    markers.sort()
    return markers


def find_mmu_branch(insns):
    """Locate `cbnz x19, ...` in primary_entry; returns (addr, target, next)."""
    for i, (addr, mnemonic, operands) in enumerate(insns):
        if mnemonic != "cbnz":
            continue
        if not operands.startswith("x19,"):
            continue
        tm = TARGET_RE.search(operands)
        if not tm:
            continue
        target = int(tm.group(1), 16)
        nxt = insns[i + 1][0] if i + 1 < len(insns) else None
        return addr, target, nxt
    return None


def main():
    ap = argparse.ArgumentParser(
        description="Check that C2S diagnostic markers are reachable "
        "through the CFG of their function."
    )
    ap.add_argument(
        "vmlinux",
        nargs="?",
        help="path to the vmlinux to disassemble (omit when using "
        "--disasm-file)",
    )
    ap.add_argument(
        "--function",
        default="primary_entry",
        help="function to analyse (default: primary_entry)",
    )
    ap.add_argument(
        "--objdump",
        default="aarch64-linux-gnu-objdump",
        help="objdump binary to use",
    )
    ap.add_argument(
        "--disasm-file",
        help="read a saved objdump listing instead of disassembling the "
        "vmlinux (used for the regression's negative control fixture)",
    )
    ap.add_argument(
        "--expect-none",
        action="store_true",
        help="require that NO markers be present (baseline build)",
    )
    ap.add_argument(
        "--expect-unreachable",
        action="store_true",
        help="invert the verdict: PASS only if at least one marker is "
        "unreachable (negative control for the gate itself)",
    )
    args = ap.parse_args()

    if args.disasm_file:
        text = read_disasm_file(args.disasm_file)
        source = args.disasm_file
    elif args.vmlinux:
        text = disassemble(args.vmlinux, args.function, args.objdump)
        source = args.vmlinux
    else:
        print(
            "ERROR: need a vmlinux path or --disasm-file", file=sys.stderr
        )
        return 2
    if text is None:
        print(
            "ERROR: could not disassemble %s in %s"
            % (args.function, source),
            file=sys.stderr,
        )
        return 2

    insns = parse_instructions(text)
    if not insns:
        print(
            "ERROR: no instructions parsed for %s" % args.function,
            file=sys.stderr,
        )
        return 2

    cfg, order = build_cfg(insns)
    entry = order[0]
    reach = reachable(cfg, entry)
    print(
        "CFG %s: %d instructions, entry=0x%x, reachable=%d"
        % (args.function, len(insns), entry, len(reach))
    )

    markers = find_markers(insns)
    if not markers:
        if args.expect_none:
            print("PASS: no diagnostic markers in %s (baseline build)" % args.function)
            return 0
        if args.expect_unreachable:
            print(
                "RESULT: FAIL (no diagnostic markers found - the negative "
                "control fixture is not usable)"
            )
            return 1
        print(
            "FAIL: no diagnostic markers found in %s (markers lost?)" % args.function
        )
        return 1

    if args.expect_none:
        for addr, colour in markers:
            print(
                "FAIL: marker %s @ 0x%x present although baseline build expected"
                % (MARKER_COLOURS.get(colour, "0x%016x" % colour), addr)
            )
        return 1

    # Split reachability at the MMU-state branch when analysing primary_entry.
    # The two entry paths are the two successors of `cbnz x19`:
    #   taken     -> cache-on  path (MMU and caches were on at entry)
    #   fallthrough -> cache-off path (MMU off; the path this device takes)
    # Both paths start at the function entry, so code before the branch
    # (the M1 band) belongs to both; only the branch's own edges are cut.
    mmu_branch = None
    if args.function == "primary_entry":
        mmu_branch = find_mmu_branch(insns)
        if mmu_branch is None:
            print("FAIL: primary_entry has no `cbnz x19` MMU-state branch")
            return 1
        branch_addr, target, nxt = mmu_branch
        print(
            "MMU branch @ 0x%x: taken(cache-on)=0x%x fallthrough(cache-off)=0x%x"
            % (branch_addr, target, nxt)
        )
        # cache-off path: the branch is not taken -> only the fallthrough.
        reach_off = reachable(cfg, entry, cut={branch_addr: [nxt]})
        # cache-on path: the branch is taken -> only the target.
        reach_on = reachable(cfg, entry, cut={branch_addr: [target]})

    failed = 0
    for addr, colour in markers:
        name = MARKER_COLOURS.get(colour, "0x%016x" % colour)
        if addr not in reach:
            print("FAIL: marker %s @ 0x%x unreachable from entry" % (name, addr))
            failed += 1
            continue
        if mmu_branch is not None:
            on_off = addr in reach_off
            on_on = addr in reach_on
            if not on_off:
                print(
                    "FAIL: marker %s @ 0x%x NOT reachable on the MMU-off "
                    "(cache-off) entry path - the path this device takes"
                    % (name, addr)
                )
                failed += 1
                continue
            if not on_on:
                print(
                    "FAIL: marker %s @ 0x%x NOT reachable on the MMU-on "
                    "(cache-on) entry path" % (name, addr)
                )
                failed += 1
                continue
            print(
                "PASS: marker %s @ 0x%x reachable from entry and from both "
                "MMU-state paths (cache-off + cache-on)" % (name, addr)
            )
        else:
            print(
                "PASS: marker %s @ 0x%x reachable from %s entry"
                % (name, addr, args.function)
            )

    if args.expect_unreachable:
        # Negative control: the caller wants the gate to *reject* this
        # input.  Unreachable markers are the expected outcome here, so a
        # clean run means the checker is insensitive and must not be
        # trusted as a regression gate.
        if failed:
            print(
                "RESULT: PASS (%d marker(s) unreachable - gate correctly "
                "rejects this input)" % failed
            )
            return 0
        print(
            "RESULT: FAIL (gate did NOT flag unreachable markers - it is "
            "insensitive and cannot guard this regression)"
        )
        return 1

    if failed:
        print("RESULT: FAIL (%d marker(s) unreachable)" % failed)
        return 1
    print("RESULT: PASS (%d marker(s) reachable)" % len(markers))
    return 0


if __name__ == "__main__":
    sys.exit(main())
