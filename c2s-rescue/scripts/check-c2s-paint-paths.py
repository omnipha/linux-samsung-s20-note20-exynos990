#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Mapping-path gate for the C-level band painter (issue #5, diag9).

The disassembly gate (check-c-milestone-bands.py) can only see *which* row a
milestone paints.  It cannot see *how* it paints it, and diag9's whole point
is the how:

  * fb2 (0xfac00000) is reserved WITHOUT no-map, so its only correct alias
    after paging_init() is phys_to_virt().  ioremap_wc() refuses RAM.
  * fb0/fb1 are no-map reservations, so phys_to_virt() is wrong for them and
    early_memremap()/ioremap_wc() is right.
  * the boot ID map exists only until cpu_uninstall_idmap(), the linear map
    only after paging_init(); the dozen lines between the two have neither.

Three defects would each be invisible to a photo but fatal to the readout:

  1. fb2 skipped whenever fb0/fb1 could not be mapped, or a band kicked only
     because fb0/fb1 painted - then "no band" no longer separates "kernel
     died" from "the fixmap helper failed".
  2. fb2 written through phys_to_virt() before paging_init(), or written
     through the identity alias after cpu_uninstall_idmap() - a translation
     fault, i.e. the diagnostic kills the thing it measures.
  3. a milestone band painted inside that window, which would fault for the
     same reason.

This gate reads the two source files directly and pins all three.  Source,
not disassembly, because what has to hold is a *branch condition* and a
*call-site placement*, and neither survives a compiler pass intact.

Exit codes:
  0  every required property present
  1  at least one property missing                     <-- regression
  2  usage / IO error
"""

import argparse
import re
import sys

REPO_DEFAULT = "arch/arm64/kernel/c2s_diag_bands.c"
SETUP_DEFAULT = "arch/arm64/kernel/setup.c"

# The window in setup_arch() that has neither an identity mapping nor a
# linear mapping for the splash buffers.  Everything below is phrased in
# terms of these two markers rather than of line numbers, so an unrelated
# edit that shifts the file does not produce a false failure.
IDMAP_GONE_CALL = "cpu_uninstall_idmap()"
LINEAR_READY_CALL = "paging_init()"
MEMBLOCK_CALL = "arm64_memblock_init()"

# Paint entry points that must never appear inside the window.
BAND_CALLS = ("c2s_band_early(", "c2s_scanout_probe(", "c2s_band(")


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError as exc:
        print("ERROR: cannot read %s: %s" % (path, exc), file=sys.stderr)
        return None


def function_body(text, name):
    """Return the body of the first function whose definition mentions `name`.

    Matches e.g. `static void __init c2s_paint_band_early(...)` and
    `void c2s_band(u32 row, u32 colour)`, then takes everything up to the
    brace that closes the definition.  Returns None when there is no such
    function, which is itself a gate failure (the property being checked
    was deleted rather than moved).
    """
    head = re.search(r"^[^\n{;]*\b%s\s*\([^;{]*\)\s*\{" % re.escape(name),
                     text, re.M)
    if not head:
        return None
    start = text.index("{", head.start())
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
    return None


def loop_region(body, probe="for (fb = 0;"):
    """Return the text of the first `for` loop that starts with `probe`."""
    idx = body.find(probe)
    if idx < 0:
        return None
    open_paren = body.find("(", idx)
    if open_paren < 0:
        return None
    # find the matching ')' of the for-conditions
    depth = 0
    for i in range(open_paren, len(body)):
        if body[i] == "(":
            depth += 1
        elif body[i] == ")":
            depth -= 1
            if depth == 0:
                cond_end = i + 1
                break
    else:
        return None
    brace = body.find("{", cond_end)
    if brace < 0:
        return None
    depth = 0
    for i in range(brace, len(body)):
        if body[i] == "{":
            depth += 1
        elif body[i] == "}":
            depth -= 1
            if depth == 0:
                return body[brace + 1:i]
    return None


def code_lines(text):
    """(lineno, source) for every line that is not part of a comment.

    The properties below are about statements, and this file documents the
    forbidden window in prose right next to the code - a plain substring
    search would find `cpu_uninstall_idmap()` in the very comment that
    explains it and pin the wrong ordering.  Only whole-line comments are
    dropped; a trailing `/* ... */` on a code line is harmless because the
    patterns are anchored at the start of the line.
    """
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if s.startswith("*") or s.startswith("/*") or s.startswith("//"):
            continue
        yield n, line


def line_index(text, pattern, occurrence=1):
    """1-based line number of the `occurrence`-th *code* line matching.

    `pattern` is a regular expression anchored where it matters (statements
    are matched as ``^\\s*name\\(\\);`` so that a mention inside prose does
    not count as a call).
    """
    rx = re.compile(pattern)
    seen = 0
    for n, line in code_lines(text):
        if rx.search(line):
            seen += 1
            if seen == occurrence:
                return n
    return None


def check_bands(text):
    """Properties that must hold in c2s_diag_bands.c."""
    failures = []
    ok = []

    def need(cond, good, bad):
        if cond:
            ok.append(good)
        else:
            failures.append(bad)

    # --- 1. per-buffer independence and kick-if-any -------------------
    paint = function_body(text, "c2s_paint_band_early")
    if paint is None:
        failures.append("c2s_paint_band_early: function not found (the "
                        "shared band painter was deleted or renamed)")
        return failures, ok

    loop = loop_region(paint)
    if loop is None:
        failures.append("c2s_paint_band_early: the per-buffer for loop was "
                        "not found")
    else:
        # Every buffer must be attempted unconditionally: no early exit
        # out of the loop may be possible.
        for kw in ("return", "break"):
            if re.search(r"\b%s\b" % kw, loop):
                failures.append("c2s_paint_band_early: `%s` inside the "
                                "per-buffer loop - a failure in one buffer "
                                "would abort the others" % kw)
            else:
                ok.append("c2s_paint_band_early: per-buffer loop has no "
                          "`%s` (all three buffers are always attempted)" % kw)
        if "c2s_paint_early_fb(" not in loop:
            failures.append("c2s_paint_band_early: the loop does not call "
                            "c2s_paint_early_fb()")
        # The diag8 defect: fb2 skipped whenever its linear alias was not
        # ready, which in the ID-map phase (where the alias never is) meant
        # fb2 was never painted at all.
        if re.search(r"continue;", loop) and "C2S_FB_LINEAR" in loop:
            failures.append("c2s_paint_band_early: the loop can `continue` "
                            "past fb2 (C2S_FB_LINEAR) - in the ID-map phase "
                            "fb2 would never be painted, which is exactly "
                            "the defect diag9 fixes")
        if "painted = true" not in loop:
            failures.append("c2s_paint_band_early: the loop does not "
                            "accumulate a `painted` result")
        if "pr_err" not in loop:
            failures.append("c2s_paint_band_early: a failed buffer is not "
                            "reported (no pr_err in the loop) - a mapping "
                            "failure would be silent")

    need(re.search(r"if\s*\(\s*painted\s*\)\s*\n\s*c2s_kick_early\(", paint),
         "c2s_paint_band_early: DECON kick is issued iff any buffer painted",
         "c2s_paint_band_early: the DECON kick is not guarded by `painted` - "
         "it would be skipped even when fb2 painted, or issued when nothing "
         "did")

    # --- 2. fb2's phys_to_virt branch is gated on !idmap ---------------
    early_fb = function_body(text, "c2s_paint_early_fb")
    if early_fb is None:
        failures.append("c2s_paint_early_fb: function not found")
    else:
        need("fb == C2S_FB_LINEAR && !idmap && c2s_linear_alive()"
             in early_fb,
             "c2s_paint_early_fb: fb2 linear alias gated on !idmap and "
             "c2s_linear_alive()",
             "c2s_paint_early_fb: the fb2 phys_to_virt() branch is not "
             "gated on `!idmap && c2s_linear_alive()` - it would take the "
             "linear address while the ID map is still in TTBR0, or before "
             "paging_init() has built the linear map")
        need("phys_to_virt(" in early_fb,
             "c2s_paint_early_fb: fb2 is painted through phys_to_virt()",
             "c2s_paint_early_fb: no phys_to_virt() - fb2 has no fixmap "
             "alias, so it could not be painted at all after "
             "cpu_uninstall_idmap()")
        # The identity path must remain reachable for all buffers, fb2
        # included: that is the phase C1/probe/S1 run in.
        need(re.search(r"if\s*\(\s*idmap\s*\)\s*\n\s*p\s*=\s*\(void\s*\*\)"
                       r"\(phys\s*&\s*PAGE_MASK\)", early_fb),
             "c2s_paint_early_fb: identity alias used while idmap (fb2 not "
             "skipped in the ID-map phase)",
             "c2s_paint_early_fb: the idmap branch no longer writes through "
             "the identity alias")

    # --- 3. the two phase flags are markers, not the memstart sentinel --
    idmap = function_body(text, "c2s_idmap_alive")
    if idmap is None:
        failures.append("c2s_idmap_alive: function not found")
    else:
        need("c2s_idmap_removed" in idmap and "memstart_addr" in idmap,
             "c2s_idmap_alive: combines the marker with the sentinel",
             "c2s_idmap_alive: does not test c2s_idmap_removed - between "
             "cpu_uninstall_idmap() and arm64_memblock_init() the sentinel "
             "is still -1 and an identity write would fault")

    linear = function_body(text, "c2s_linear_alive")
    if linear is None:
        failures.append("c2s_linear_alive: function not found")
    else:
        need("c2s_linear_ready_flag" in linear,
             "c2s_linear_alive: answers from the paging_init() marker",
             "c2s_linear_alive: does not test c2s_linear_ready_flag - "
             "memstart_addr turns valid before paging_init(), so "
             "phys_to_virt() could be taken with no linear map present")

    # --- 4. the markers themselves are defined ------------------------
    need("void __init c2s_mark_idmap_gone(void)" in text,
         "c2s_mark_idmap_gone() is defined",
         "c2s_mark_idmap_gone() is not defined")
    need("void __init c2s_mark_linear_ready(void)" in text,
         "c2s_mark_linear_ready() is defined",
         "c2s_mark_linear_ready() is not defined")

    # --- 5. late path: fb2 via linear alias, fb0/fb1 via ioremap_wc ----
    late = function_body(text, "c2s_late_init")
    if late is None:
        failures.append("c2s_late_init: function not found")
    else:
        need("ioremap_wc(c2s_fb_phys[fb]" in late,
             "c2s_late_init: fb0/fb1 still taken with ioremap_wc()",
             "c2s_late_init: fb0/fb1 are no longer ioremap_wc()ed")
        need(re.search(r"if\s*\(\s*fb\s*==\s*C2S_FB_LINEAR\s*\)\s*\n\s*"
                       r"continue;", late) is not None,
             "c2s_late_init: ioremap loop skips fb2 (it is RAM now)",
             "c2s_late_init: the ioremap_wc() loop no longer skips fb2 - "
             "__ioremap_prot() refuses a pfn_is_map_memory() range, so fb2 "
             "would be left unmapped in the late path")
        need("phys_to_virt(c2s_fb_phys[C2S_FB_LINEAR])" in late,
             "c2s_late_init: fb2 alias taken from the linear map",
             "c2s_late_init: fb2 has no phys_to_virt() alias")

    band = function_body(text, "c2s_band")
    if band is None:
        failures.append("c2s_band: function not found")
    else:
        need("dcache_clean_inval_poc(" in band,
             "c2s_band: cacheable fb2 alias is cleaned before the kick",
             "c2s_band: no dcache_clean_inval_poc() - a band written "
             "through the cacheable linear alias could stay in the CPU "
             "cache and never reach DRAM")

    return failures, ok


def check_setup(text):
    """Properties that must hold in arch/arm64/kernel/setup.c."""
    failures = []
    ok = []

    i_uninstall = line_index(text, r"^\s*cpu_uninstall_idmap\(\)")
    i_paging = line_index(text, r"^\s*paging_init\(\)")
    i_memblock = line_index(text, r"^\s*arm64_memblock_init\(\)")
    i_mark_gone = line_index(text, r"^\s*c2s_mark_idmap_gone\(\);")
    i_mark_lin = line_index(text, r"^\s*c2s_mark_linear_ready\(\);")
    i_s1 = line_index(text, r"^\s*c2s_band_early\(2496,")
    i_s2 = line_index(text, r"^\s*c2s_band_early\(2624,")
    i_s3 = line_index(text, r"^\s*c2s_band_early\(2752,")

    for label, idx in (("cpu_uninstall_idmap()", i_uninstall),
                       ("paging_init()", i_paging),
                       ("arm64_memblock_init()", i_memblock),
                       ("c2s_mark_idmap_gone()", i_mark_gone),
                       ("c2s_mark_linear_ready()", i_mark_lin),
                       ("S1 c2s_band_early(2496,...)", i_s1),
                       ("S2 c2s_band_early(2624,...)", i_s2),
                       ("S3 c2s_band_early(2752,...)", i_s3)):
        if idx is None:
            failures.append("%s: not found in setup_arch()" % label)

    # Nothing that paints may sit in the window that has neither mapping.
    if i_uninstall is not None and i_paging is not None:
        window = [l for _n, l in code_lines(text)
                  if i_uninstall < _n < i_paging]
        hit = [c for c in BAND_CALLS if any(c in l for l in window)]
        if hit:
            failures.append("setup_arch: %s called between %s and %s - the "
                            "window has no identity and no linear mapping "
                            "for the splash buffers, so the paint faults"
                            % (", ".join(hit), IDMAP_GONE_CALL,
                               LINEAR_READY_CALL))
        else:
            ok.append("setup_arch: no band call inside the "
                      "%s..%s window" % (IDMAP_GONE_CALL, LINEAR_READY_CALL))

    def before(a, b, why):
        if a is None or b is None:
            return
        if a < b:
            ok.append(why)
        else:
            failures.append("setup_arch: line %d is not before line %d - %s"
                            % (a, b, why))

    before(i_s1, i_uninstall,
           "S1 is painted while the ID map is still installed")
    before(i_uninstall, i_mark_gone,
           "c2s_mark_idmap_gone() follows cpu_uninstall_idmap()")
    if i_mark_gone is not None and i_memblock is not None:
        # The marker only changes behaviour while memstart_addr is still
        # the -1 sentinel, i.e. before arm64_memblock_init().
        if i_mark_gone < i_memblock:
            ok.append("c2s_mark_idmap_gone() runs before "
                      "arm64_memblock_init() (while the sentinel is set)")
        else:
            failures.append("setup_arch: c2s_mark_idmap_gone() is after "
                            "arm64_memblock_init() - memstart_addr is "
                            "already valid there, so the marker closes "
                            "nothing")
    before(i_paging, i_mark_lin,
           "c2s_mark_linear_ready() follows paging_init()")
    before(i_mark_lin, i_s2,
           "S2 is painted after the linear map exists")
    before(i_s2, i_s3, "S2 precedes S3")

    return failures, ok


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bands-c", default=REPO_DEFAULT,
                    help="painter source (default: %s)" % REPO_DEFAULT)
    ap.add_argument("--setup-c", default=SETUP_DEFAULT,
                    help="setup.c source (default: %s)" % SETUP_DEFAULT)
    ap.add_argument("--bands-c-only", action="store_true",
                    help="check only the painter (used with a fixture for "
                         "the negative control)")
    args = ap.parse_args()

    failures = []
    total_ok = 0

    bands = read(args.bands_c)
    if bands is None:
        return 2
    f, o = check_bands(bands)
    failures += ["%s: %s" % (args.bands_c, x) for x in f]
    total_ok += len(o)

    if not args.bands_c_only:
        setup = read(args.setup_c)
        if setup is None:
            return 2
        f, o = check_setup(setup)
        failures += ["%s: %s" % (args.setup_c, x) for x in f]
        total_ok += len(o)

    if failures:
        for x in failures:
            print("FAIL: %s" % x)
        print("RESULT: FAIL (%d problem(s))" % len(failures))
        return 1
    print("RESULT: PASS (%d paint-path propert%s verified)"
          % (total_ok, "y" if total_ok == 1 else "ies"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
