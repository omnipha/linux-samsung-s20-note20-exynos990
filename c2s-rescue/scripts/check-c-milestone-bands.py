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
value written to each framebuffer.  The scanout discriminator
(c2s_scanout_probe) carries one colour per splash buffer, so expectations
are positional argument lists rather than a fixed (row, colour) pair.

Exit codes:
  0  every expected call site present with the expected arguments
  1  at least one site missing / wrong argument               <-- regression
  2  usage / tooling error
"""

import argparse
import re
import subprocess
import sys

# function -> [(callee, expected argument tuple), ...]
# Arguments are positional and match the callee's prototype:
#   c2s_band_early(u32 row, u32 colour)          -> (row, colour)
#   c2s_scanout_probe(u32 row, c0, c1, c2)       -> (row, fb0, fb1, fb2)
#   c2s_band(u32 row, u32 colour)                -> (row, colour)
#   c2s_late_init(void)                          -> ()
#   c2s_mark_idmap_gone(void)                    -> ()
#   c2s_mark_linear_ready(void)                  -> ()
# An expectation lists only the arguments this gate pins; extra arguments
# of a call site are ignored.  The order is the *execution* order of the
# milestones within a function.
#
# An EMPTY list means something specific and is not the same as a missing
# key: "this function must carry no milestone call site at all".  That is
# how the deferred USB rows (diag10) are pinned - the band layout moved the
# C ladder into rows that cannot coexist with 1024/1152/1280/1408/1536, so
# a USB milestone reappearing is a regression even though the callee itself
# still exists in the tree.  A key that is absent from this table entirely
# is not checked at all (only reachable through an explicit --function).
EXPECTED = {
    "start_kernel": [
        ("c2s_band_early", (640, 0xFFFFFF00)),
        # Issue #5 change B - the scanout discriminator sits between C1 and
        # C2, in the same ID-map phase: fb0 red, fb1 green, fb2 blue at
        # rows 1024..1151 (moved here from 1664: that row is inside the
        # logo band and could not be read back).
        ("c2s_scanout_probe", (1024, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF)),
        ("c2s_band_early", (768, 0xFF00FFFF)),
        ("c2s_band_early", (896, 0xFFFFA500)),
        ("c2s_late_init", ()),
    ],
    # setup_arch(): S1 before cpu_uninstall_idmap(), then the two mapping
    # markers, then S2 right after paging_init() and S3 at the end.
    # check-c2s-paint-paths.py pins that arrangement against the source;
    # this table pins rows and colours against the disassembly.
    "setup_arch": [
        ("c2s_band_early", (2496, 0xFF008080)),
        ("c2s_mark_idmap_gone", ()),
        ("c2s_mark_linear_ready", ()),
        ("c2s_band_early", (2624, 0xFF800080)),
        ("c2s_band_early", (2752, 0xFFC0C0C0)),
    ],
    # diag10: the C2..C3 bisect tick.  c2s_late_init() runs inside that
    # window (init/main.c, right after mm_core_init()), so a band there
    # separates "the window was walked through" from "the window was
    # never entered" - subject to the standing rule that a missing band
    # may also be a paint/scanout failure.  Row 2880 is the first free
    # 128-row slot after S3 (S3 ends at 2879) and outside the logo zone;
    # 0xff000080 (dark navy) appears nowhere else in the ladder.
    "c2s_late_init": [
        ("c2s_band", (2880, 0xFF000080)),
    ],
    # diag9 removed every USB milestone call site: rows 1280/1408/1536 sit
    # in the logo band, and 1024/1152 became the discriminator and are
    # simply dropped until diag10 re-places them.
    "usb_add_gadget": [],
    "run_init_process": [],
    "gadget_bind_driver": [],
    "gether_connect": [],
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
# Both the 32-bit (wN) and 64-bit (xN) spellings are tracked: AAPCS64 passes
# a u32 argument in the low 32 bits of x0..x3, and a 64-bit immediate like
# `mov x1, #0x10000000000000` must clobber the tracked value rather than be
# read as `mov` whose "#0x" the caller ignores.
MOV_IMM_RE = re.compile(r"^([wx][0-3]), #0x([0-9a-f]+)")
# `, lsl #N` is omitted by objdump when the shift is zero
# (`movk x3, #0xcccd`), so it has to be optional.
MOVK_IMM_RE = re.compile(r"^([wx][0-3]), #0x([0-9a-f]+)(?:, lsl #(\d+))?")

# Argument registers read by the milestone callees, normalised to rN so that
# wN and xN alias without special-casing every access.
ARG_COUNT = 4

# Registers whose value the milestone callees read as their arguments.
ARG_REGS = {"r%d" % i for i in range(ARG_COUNT)} | \
           {"%s%d" % (p, i) for p in "wx" for i in range(ARG_COUNT)}


def _norm_reg(name):
    """Map a wN/xN operand onto the abstract register name rN (or None)."""
    if len(name) == 2 and name[0] in "rwx" and name[1] in "0123":
        return "r" + name[1]
    return None


def _reg_32(value):
    """The low 32 bits, which is all AAPCS64 guarantees for a u32 argument."""
    return value & 0xFFFFFFFF


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


def _writes_arg_reg(mnemonic, rest):
    """Return the normalised register if this insn writes one of r0..r3.

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
        return _norm_reg(head)
    return None


def call_sites(disasm_text):
    """Yield (callee, argument tuple, addr) for every milestone call found.

    Arguments are tracked forwards and reset at every `bl` (the callee
    clobbers the argument registers), and each individual write to r0..r3
    that is not an immediate `mov`/`movk` clears the register so a value
    from another statement can never be picked up.  The yielded tuple is
    (r0, r1, r2, r3) with None for a register whose value could not be
    tracked - the caller decides how many of them an expectation pins.
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
                key = _norm_reg(mm.group(1))
                if key:
                    regs[key] = _reg_32(int(mm.group(2), 16))
                continue
        elif mnemonic == "movk":
            mm = MOVK_IMM_RE.match(rest)
            if mm:
                key = _norm_reg(mm.group(1))
                if key and key in regs:
                    shift = int(mm.group(3) or 0)
                    val = int(mm.group(2), 16)
                    mask = (0xFFFF << shift) & 0xFFFFFFFF
                    regs[key] = (regs[key] & ~mask | (val << shift)) & \
                        0xFFFFFFFF
                    continue
                if key:
                    # half of an immediate built from an unknown base
                    regs.pop(key, None)
                continue

        clobber = _writes_arg_reg(mnemonic, rest)
        if clobber:
            regs.pop(clobber, None)

        if mnemonic == "bl":
            cm = CALL_RE.match("%s %s" % (mnemonic, rest))
            if cm:
                args = tuple(regs.get("r%d" % i) for i in range(ARG_COUNT))
                sites.append((cm.group(1), args, addr))
            regs = {}
    return sites


def _fmt_args(args, expected=None):
    """Render an argument tuple for a failure message."""
    out = []
    for i, value in enumerate(args):
        if expected is not None and i < len(expected) and \
                expected[i] is None:
            out.append("-")
            continue
        out.append("-" if value is None else hex(value))
    return "(%s)" % ", ".join(out)


def _matches(args, expected):
    """Positional match: every pinned argument must be present and equal."""
    for i, want in enumerate(expected):
        if want is None:
            continue
        if i >= len(args) or args[i] is None or args[i] != want:
            return False
    return True


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
        found = [(callee, argv) for (callee, argv, _a) in sites]

        if args.expect_none:
            if found:
                failures.append("%s: unexpected milestone call site(s): %s"
                                % (fn, found))
            continue

        if fn not in EXPECTED:
            # Not in the table at all: nothing is asserted about this
            # function (only reachable through an explicit --function).
            continue

        expected = EXPECTED[fn]
        if not expected:
            # An empty list is a positive requirement: this function must
            # carry no milestone call site at all.  It is what pins the
            # removal of the USB milestone rows in diag9 - the callee
            # still exists in the tree, so nothing else would notice a
            # call site creeping back in.
            total += 1
            if found:
                failures.append("%s: must carry no milestone call site, "
                                "found %s" % (fn, found))
            continue

        # Match expectations in order; each expectation consumes one site.
        remaining = list(found)
        for (callee, want) in expected:
            total += 1
            hit = None
            for i, (site_callee, site_args) in enumerate(remaining):
                if site_callee != callee:
                    continue
                if not _matches(site_args, want):
                    continue
                hit = i
                break
            if hit is None:
                failures.append(
                    "%s: missing %s%s; found %s"
                    % (fn, callee, _fmt_args(want),
                       [_fmt_args(a) for _c, a in found] or "no call sites"))
            else:
                remaining.pop(hit)

        if remaining:
            failures.append("%s: unexpected extra call site(s): %s"
                            % (fn, [_fmt_args(a) for _c, a in remaining]))

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
