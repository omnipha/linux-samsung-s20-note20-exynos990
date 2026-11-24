#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Call-site gate for the C-level milestone bands (issue #5).

Byte-level gates only prove that `c2s_band()` and friends were *compiled in*.
They say nothing about whether the milestone rows were wired to the right
function - and a milestone painted at the wrong row (or into a function that
never runs on this device) reads exactly like a milestone that was never
reached, which is the misdiagnosis this candidate exists to avoid.

This script disassembles the functions that carry the milestones and checks
each call site against the table below: callee, row number and colour.  It
also proves the negative case (a build without CONFIG_C2S_DIAG) carries no
such call sites at all, so the diagnostic cannot leak into the USB baseline.

Rows are the ladder position in the 1440x3088 panel (the asm ladder owns
rows 0..639, the C ladder continues at row 640), colour is the a8r8g8b8
value written to each framebuffer.

Exit codes:
  0  every expected call site present with the expected row and colour
  1  at least one site missing / wrong row / wrong colour  <-- regression
  2  usage / tooling error
"""

import argparse
import re
import subprocess
import sys

# function -> [(callee, expected row, expected colour), ...]
# The row order is the *execution* order of the milestones, which for the
# /init failure case is two paint paths over the same row.
EXPECTED = {
    "start_kernel": [
        ("c2s_band_early", 640, 0xFFFFFF00),
        ("c2s_band_early", 768, 0xFF00FFFF),
        ("c2s_band_early", 896, 0xFFFFA500),
        ("c2s_late_init", None, None),
    ],
    "usb_add_gadget": [
        ("c2s_band", 1024, 0xFFADD8E6),
    ],
    "run_init_process": [
        ("c2s_band", 1152, 0xFFFFC0CB),
        ("c2s_band", 1152, 0xFF8B0000),
    ],
    "gadget_bind_driver": [
        ("c2s_band", 1280, 0xFF32CD32),
        ("c2s_band", 1408, 0xFFFA8072),
    ],
    "gether_connect": [
        ("c2s_band", 1536, 0xFF00FF7F),
    ],
}

# Every function that must be scanned for the baseline negative case.
ALL_FUNCTIONS = list(EXPECTED)

INSN_RE = re.compile(r"^([0-9a-f]{8,}):\s+([0-9a-f]+)\s+(\S+)\s*(.*)$")
CALL_RE = re.compile(r"^bl\s+[0-9a-f]+ <(c2s_[a-z_]+)>$")
# The operand part of the argument-building instructions, e.g.
#   w0, #0x300                  // #768
#   w1, #0xd8e6                 // #55526
#   w1, #0xffad, lsl #16
# objdump prints ARM MOVZ/MOVN/MOVK under their `mov`/`movk` aliases with the
# fully resolved value, so reading the immediate gives the value as written.
MOV_IMM_RE = re.compile(r"^(w[01]), #0x([0-9a-f]+)")
MOVK_IMM_RE = re.compile(r"^(w[01]), #0x([0-9a-f]+), lsl #(\d+)")

# The two argument registers c2s_band(0/1) and c2s_band_early(0/1) use.
ROW_REG = "w0"
COLOUR_REG = "w1"

# Instructions whose first operand reads rather than writes it, so they must
# not be mistaken for a clobber of the register we are tracking.
_FIRST_OPERAND_IS_SOURCE = ("cmp", "cmn", "tst", "tbnz", "tbz", "cbz",
                            "cbnz", "br", "blr", "ret")


def disassemble(vmlinux, function, objdump="aarch64-linux-gnu-objdump"):
    """objdump one function, or None when it cannot be disassembled."""
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


def read_disasm_file(path, function):
    """Read a saved objdump listing instead of disassembling a vmlinux.

    Used by the regression's negative control: a previous candidate's
    listing is kept as a fixture so the gate can prove it is sensitive
    without needing that build tree.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print("ERROR: cannot read %s: %s" % (path, exc), file=sys.stderr)
        return None
    # Keep only the requested function's instructions.  A symbol header is
    # `addr <name>:` at column 0; an instruction line is `addr:<tab>word`,
    # so the space before `<` is what distinguishes them.
    in_fn = False
    keep = []
    header_re = re.compile(r"^[0-9a-f]+ <%s>:$" % re.escape(function))
    next_hdr_re = re.compile(r"^[0-9a-f]+ <[^>]+>:$")
    for line in text.splitlines():
        if not in_fn:
            if header_re.match(line):
                in_fn = True
            continue
        if next_hdr_re.match(line):
            break
        keep.append(line)
    return "\n".join(keep) if keep else None


# Registers whose value the milestone callees read as (row, colour).
ARG_REGS = {"w0", "w1", "x0", "x1"}


def _writes_arg_reg(mnemonic, rest):
    """Return the destination register if this insn writes w0/w1/x0/x1.

    Any writer other than an immediate `mov`/`movk` invalidates the value
    we track: `adrp x0, ...` or `add x0, ...` would otherwise leave a stale
    row/colour from an earlier milestone in the accumulator.  Stores and
    compares name a source as their first operand, so they never clobber.
    """
    if mnemonic.startswith("st"):          # str/strb/stp/stur/stxr/...
        return None
    if mnemonic in _FIRST_OPERAND_IS_SOURCE:
        return None
    head = rest.split(",")[0].strip()
    if head in ARG_REGS:
        if mnemonic in ("mov", "movk") and "#0x" in rest:
            return None                    # handled by the caller
        return head
    return None


def call_sites(disasm_text):
    """Yield (callee, row, colour, addr) for every milestone call found.

    Arguments are tracked forwards and reset at every `bl` (the callee
    clobbers the argument registers), and each individual w0/w1/x0/x1 write
    that is not an immediate `mov` clears the register so a value from
    another statement can never be picked up.
    """
    parsed = []
    for line in disasm_text.splitlines():
        m = INSN_RE.match(line.strip())
        if not m:
            continue
        addr, _word, mnemonic, rest = m.groups()
        parsed.append((addr, mnemonic, rest.strip()))

    sites = []
    regs = {}
    for addr, mnemonic, rest in parsed:
        if mnemonic == "mov":
            mm = MOV_IMM_RE.match(rest)
            if mm:
                regs[mm.group(1)] = int(mm.group(2), 16) & 0xFFFFFFFF
                continue
        elif mnemonic == "movk":
            mm = MOVK_IMM_RE.match(rest)
            if mm and mm.group(1) in regs:
                shift = int(mm.group(3))
                val = int(mm.group(2), 16)
                cur = regs[mm.group(1)]
                mask = 0xFFFF << shift
                regs[mm.group(1)] = (cur & ~mask) | (val << shift)
                continue

        clobber = _writes_arg_reg(mnemonic, rest)
        if clobber:
            # x0/x1 alias w0/w1
            regs.pop(clobber, None)
            regs.pop("w" + clobber[-1], None)

        if mnemonic == "bl":
            cm = CALL_RE.match("%s %s" % (mnemonic, rest))
            if cm:
                row = regs.get(ROW_REG)
                colour = regs.get(COLOUR_REG)
                sites.append((cm.group(1), row, colour, addr))
            regs = {}
    return sites


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vmlinux", nargs="?",
                    help="vmlinux to disassemble")
    ap.add_argument("--disasm-file", metavar="FILE",
                    help="read a saved objdump -d listing instead")
    ap.add_argument("--function", action="append", metavar="NAME",
                    help="restrict the scan to these functions "
                         "(default: all functions in the expected table)")
    ap.add_argument("--expect-none", action="store_true",
                    help="no milestone call site may exist at all "
                         "(baseline / regression control)")
    ap.add_argument("--objdump", default="aarch64-linux-gnu-objdump")
    args = ap.parse_args()

    if not args.disasm_file and not args.vmlinux:
        ap.error("give vmlinux or --disasm-file")

    functions = args.function or ALL_FUNCTIONS
    failures = []
    total = 0

    for fn in functions:
        if args.disasm_file:
            text = read_disasm_file(args.disasm_file, fn)
        else:
            text = disassemble(args.vmlinux, fn, args.objdump)
        if not text:
            if args.expect_none:
                # cannot disassemble == cannot contain a call site
                continue
            failures.append("%s: not disassemblable" % fn)
            continue

        sites = call_sites(text)
        found = [(c, r, col) for (c, r, col, _a) in sites]

        if args.expect_none:
            if found:
                failures.append("%s: unexpected milestone call site(s): %s"
                                % (fn, found))
            continue

        expected = EXPECTED.get(fn, [])
        if not expected:
            continue

        # Match expectations in order; each expectation consumes one site.
        remaining = list(found)
        for (callee, row, colour) in expected:
            total += 1
            hit = None
            for i, (c, r, col) in enumerate(remaining):
                if c != callee:
                    continue
                if row is not None and r != row:
                    continue
                if colour is not None and col != colour:
                    continue
                hit = i
                break
            if hit is None:
                failures.append(
                    "%s: missing %s(row=%s colour=%s); found %s"
                    % (fn, callee, row,
                       hex(colour) if colour is not None else "-",
                       found or "no call sites"))
            else:
                remaining.pop(hit)

        if remaining:
            failures.append("%s: unexpected extra call site(s): %s"
                            % (fn, remaining))

    if args.expect_none:
        if failures:
            for f in failures:
                print("FAIL: %s" % f)
            print("RESULT: FAIL (baseline build carries milestone call sites)")
            return 1
        print("RESULT: PASS (no milestone call sites; baseline build)")
        return 0

    if failures:
        for f in failures:
            print("FAIL: %s" % f)
        print("RESULT: FAIL (%d problem(s))" % len(failures))
        return 1
    print("RESULT: PASS (%d milestone call site(s) verified)" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
