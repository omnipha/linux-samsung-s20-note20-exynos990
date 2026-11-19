# c2s rescue diagnostic milestones (issue #4)

Diagnostic candidate for issue #4: the kernel dies so early that no log is
ever produced (lk3rd `fastboot boot` prints "Booting OKAY", then the device
disconnects and stays dead; TWRP `/proc/last_kmsg` contains only the LK log,
pstore is empty). The candidate therefore writes its progress as **plain
physical stores into the framebuffers from the very first kernel
instructions**, while the MMU and D-cache are still off, so the result is
visible on the panel even if the kernel never executes another instruction.

Everything in this file is gated by `CONFIG_C2S_DIAG`
(`arch/arm64/Kconfig`, enabled only in `arch/arm64/configs/c2s_rescue_defconfig`).
No `-D` flags are passed to the DTS build, and no DTB content depends on
the diagnostic.

## M1 - kernel entry (implemented)

* **Code:** `arch/arm64/kernel/head.S`, `primary_entry`, first instructions,
  guarded by `#ifdef CONFIG_C2S_DIAG`, immediately before
  `bl record_mmu_state` / `bl preserve_boot_args`.
* **Execution context:** bootloader entry contract - MMU off, D-cache off,
  x0 = FDT physical address, x1..x3 =0. M1 runs before anything else and
  before the stack is set up, so it is register-only: `movz`/`movk`, `stp`,
  `add`, `subs`, `b.ne`, `dsb sy`. It calls nothing and uses no stack, no
  literal pool and no `adrp` data reference, and it never touches x0..x3
  (they are preserved for `preserve_boot_args()`), x19, x20, x21 or x29/x30.
* **Action:** paint a **white band (0xffffffff)** into three framebuffers:

  | buffer | physical base | why |
  |---|---|---|
  | splash / `cont_splash_mem` | `0xf1000000` | reserved as framebuffer in our DTB (`framebuffer@f1000000`), used by simplefb |
  | LOGO window | `0xf9800000` | `CONFIG_DISPLAY_LOGO_BASE_ADDRESS`, DECON window programmed by lk3rd |
  | FONT window | `0xfac00000` | `CONFIG_DISPLAY_FONT_BASE_ADDRESS`, DECON window programmed by lk3rd |

  Band geometry: rows 0..127 (128 rows), full width 1440 px, stride 5760 B
  (1440 * 4, a8r8g8b8), written as 16-byte `stp` pairs, 360 stores per row,
  then `dsb sy`.
* **Milestone table:**

  | milestone | where | marker | visible proof |
  |---|---|---|---|
  | M1 - kernel entry, MMU off | `head.S:primary_entry`, first code | white band, rows 0..127, in `0xf1000000` + `0xf9800000` + `0xfac00000` | photo of the panel: top 128 rows white (or already visible over the previous content) |
  | M2 - MMU enabled | not implemented in this step | (planned: different colour, rows 128..255) | - |
  | M3 - `early_init_dt_scan` finished | not implemented in this step | (planned: different colour, rows 256..383) | - |

  M2 and M3 are deliberately **not** part of this candidate; they follow as
  their own step after M1 has been built and verified.

### Assumptions recorded for M1 (safest variant, taken as noted)

1. **MMU and D-cache are off at entry.** This is the documented arm64 boot
   contract that `head.S` itself relies on (`preserve_boot_args()` does
   `dcache_inval_poc`, `create_init_idmap()` assumes "MMU is off"), and
   lk3rd calls `disable_mmu_dcache()` before `kernel_entry(...)`. M1 does
   not run a `dc civac` loop: with the D-cache off, stores reach DRAM
   directly. If the assumption were wrong (entered with caches on), the
   band might sit in cache and never reach DRAM - that outcome is
   distinguishable from "M1 never ran" (blank panel) by the fact that
   nothing at all is seen, and is recorded here as a possible cause.
2. **Which buffer is scanned out is unknown.** The DECON/DPP window
   programming lives in lk3rd; the actual panel scanout source on the
   kernel path is not proven from sources. Mitigation: M1 paints **all
   three** candidate buffers with the same band, so any of them being
   scanned shows the same white band. A per-buffer identifier band is not
   part of M1 (kept minimal) - see open points.
3. **White as the band colour:** unambiguous for every channel order, so a
   wrong `a8r8g8b8`/`b8g8r8a8` assumption cannot make the band invisible.
4. **Height 128 rows** chosen so the band is clearly visible but does not
   require any knowledge of the actual pixel format layout beyond
   stride = 1440 * 4.

### Readout path (proven)

* **Panel photo** after `fastboot boot <diag boot.img>`: white band in the
  top rows = kernel reached M1; no change at all = kernel never reached
  `primary_entry` (or entered with caches on, see assumption 1).
* **pstore / ramoops / `/proc/last_kmsg` are NOT used as readout** and are
  *not* part of this candidate: `c2s_rescue_defconfig` has no
  `CONFIG_PSTORE*`/`CONFIG_PSTORE_RAMOOPS`, our DTB has no ramoops
  reserved region, and no readout path through TWRP or lk3rd for a ramoops
  region could be established from sources in this step. Documented here as
  **nicht belegt** (not proven); it stays out of the candidate.

### Open points (for M2/M3 and for the hardware run)

* Per-buffer identifier band (which of the three buffers is really scanned)
  is deferred; if the white band shows, that question is moot for M1.
* M2 (MMU on) and M3 (after `early_init_dt_scan`) are the next step, each
  as a separate build/verification pass with their own colour and rows.
* Whether the trace region at `0xc8000000` + `fastboot ramdump:` remains
  needed once framebuffer bands are proven visible.

## Diag candidate build (M1) - artifacts

Built with the unmodified `c2s-rescue/scripts/build.sh` /
`package-bootimg.sh` into `/tmp/opencode/c2s-diag-out` (the reference
outdir `/tmp/opencode/c2s-out` and its boot.img `37c28a8b…` are
untouched). `verify.sh /tmp/opencode/c2s-diag-out`: **139 passed,
0 failed**. `avbtool verify_image` on the packed boot.img: ok
(SHA256_RSA4096, rollback 13, patch 2025-08). The reference run reports
140 passing checks; the one check that is absent for the diag run is
"authorized_keys mode 0600", because this build was made without
`C2S_AUTHORIZED_KEYS` (the `if`-guarded check is skipped when no key is
staged). Line-by-line diff of both `verify.sh` runs shows no other
difference.

| artifact | path | size | sha256 |
|---|---|---|---|
| boot.img (diag candidate) | `/tmp/opencode/c2s-diag-out/boot.img` | 61 865 984 | `6e01d76279143295154c907758af8960d3388d0a5ee9f3c2fd94215b6ebfa737` |
| Image (diag) | `/tmp/opencode/c2s-diag-out/kbuild/arch/arm64/boot/Image` | 11 760 128 | `dc52e8c2c0022c0043c07527599246b96b12b2122339243e4b8b40b07099e1cb` |
| DTB (diag) | `/tmp/opencode/c2s-diag-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 740 | `6afe6322273ffed7207eb14235d2ad7d9c4de2ba63f86bf8f97fc75ffcc799f6` |
| initramfs (diag) | `/tmp/opencode/c2s-diag-out/work/initramfs.cpio.gz` | 2 492 480 | `be89d277aa32cd31506edd7ea4a0eb334891c5c1012e9e575a968b6c88c075ff` |

Host-verified evidence that M1 is really in this image:

* `CONFIG_C2S_DIAG=y` in `/tmp/opencode/c2s-diag-out/kbuild/.config`
  (only enabled in `c2s_rescue_defconfig`).
* Disassembly of the diag vmlinux: `primary_entry` begins with
  `movz x4,#0xffff; movk …` (white), `0xf1000000` / `0xf9800000` /
  `0xfac00000` band loops (128 rows, stride 5760), `dsb sy`, then
  `bl record_mmu_state`. The byte pattern of the first four M1
  instructions (`e4ff9fd2 e4ffbff2 e4ffdff2 e4fffff2`) is present in the
  diag Image at file offset `0x6cc0b8` and **absent** from the reference
  Image `7a2b8568…`.
* DTB sha256 is byte-identical to the reference DTB
  (`6afe6322…`) - the diagnostic changes no device-tree content.
* initramfs differs from the reference archive only because the working
  tree's rescue initramfs (rescue-menu additions) is what was built; no
  diagnostic content is in the initramfs.
* M2 (MMU enabled) and M3 (after `early_init_dt_scan`) are **not** in
  this candidate, per the frozen step plan.

Hardware readout (blocked by the device coordinator lock, host-only
session): `fastboot boot /tmp/opencode/c2s-diag-out/boot.img`, then
photo of the panel. White band across the top 128 rows = kernel reached
`primary_entry` with MMU off; no visible change = kernel never reached
M1 (see assumptions above).

## Candidate 2 (turn 2026-11-19 ~15:54): M2 added (MMU on, D-cache on)

M2 paints a **red** band (a8r8g8b8 `0xffff0000`, rows 128..255, offset
`0xb4000`, stride 5760) into the same three framebuffers, in
`__primary_switched()` (head.S) - the first code reached after
`__enable_mmu()` and still before `start_kernel()`.

### Access path (the part that needed a design decision)

With the MMU on, `0xf1000000` is only writable if some page table maps
it. The kernel image mapping does not cover the splash buffers, and the
linear map (`__va()`) does not exist yet (it is built in
`paging_init()`, far after start_kernel). The path used here:

* `create_init_idmap()` (arch/arm64/kernel/pi/map_range.c) is extended,
  guarded by `CONFIG_C2S_DIAG`, to identity-map the three framebuffer
  ranges `0xf1000000/0xf9800000/0xfac00000`, each `0x10f6800` bytes
  (same geometry as the DT `cont_splash_mem` node), with `PAGE_KERNEL`.
* The initial ID map is loaded into **TTBR0** in `__primary_switch()`
  and stays there until `cpu_uninstall_idmap()` in `setup_arch()` -
  which runs *after* `start_kernel()` is entered. So at
  `__primary_switched()` time the ID map is still the active TTBR0, and
  VA == PA for the framebuffers: the stores hit DRAM exactly like M1's
  MMU-off stores.
* Extra ID-map page tables are budgeted via a new
  `EARLY_IDMAP_DIAG_EXTRA_PAGES` (32) added to `INIT_IDMAP_DIR_SIZE`
  in `arch/arm64/include/asm/kernel-pgtable.h` (3 FBs, up to 9 L3
  tables + L2 each at 4 KiB granule; 5-level page tables,
  `CONFIG_PGTABLE_LEVELS=5`, `CONFIG_ARM64_4K_PAGES=y`).
* Because the D-cache is on from `__enable_mmu()` onwards, the painted
  band is cleaned to PoC afterwards (`dc civac` per 64 B line over
  `0xb4000` bytes = 11520 lines per buffer, then `dsb sy`) so the DECON
  scanout sees the new colour instead of stale cache lines.

### Host-verified evidence (candidate 2)

* Build: `C2S_OUTDIR=/tmp/opencode/c2s-diag2-out build.sh` exit 0,
  Image built from this tree (M2 compiled in).
* Disassembly of `/tmp/opencode/c2s-diag2-out/kbuild/vmlinux`
  `__primary_switched` @ `ffff8000806e8474`: `movz x4,#0`;
  `movk x4,#0xffff,lsl#16`; `mov x9,#0x1680` (5760);
  `mov x11,#0xb0000; movk x11,#0x4000` (0xb4000); band loop with
  `stp x4,x4,[x6],#16`; `dc civac, x6` ×11520 per buffer; `dsb sy`;
  then the original `init_cpu_task` sequence.
* Image byte offsets: M2 header pair (`040080d2 e4ffbff2`) at
  `0x6e8478`, first `dc civac x6` (`267e0bd5`) at `0x6e84c8`;
  M1 pattern (`e4ff9fd2`) still present at `0x6cc0b8`.
* `map_range.o` contains the FB constants (`mov x3,#0xf1000000`) in
  `create_init_idmap` - the ID-map extension is compiled in.
* `CONFIG_C2S_DIAG=y` in `/tmp/opencode/c2s-diag2-out/kbuild/.config`.

### Artefakte (candidate 2)

| Artefakt | Pfad | Größe (B) | sha256 |
|---|---|---|---|
| boot.img | `/tmp/opencode/c2s-diag2-out/boot.img` | 61 865 984 | `66bb7b8a3bceb39f30179079f9b81b8d72c6d4577a3fa36897a36516c5881c6a` |
| Image | `/tmp/opencode/c2s-diag2-out/kbuild/arch/arm64/boot/Image` | 11 891 200 | `0ae41ecbac01d89eece5c9eb92366ad1d101d7937daafc49b27ec3b978aecd0d` |
| DTB | `/tmp/opencode/c2s-diag2-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 740 | `6afe6322273ffed7207eb14235d2ad7d9c4de2ba63f86bf8f97fc75ffcc799f6` (identisch zu Referenz) |
| initramfs | `/tmp/opencode/c2s-diag2-out/work/initramfs.cpio.gz` | 2 492 480 | `be89d277aa32cd31506edd7ea4a0eb334891c5c1012e9e575a968b6c88c075ff` |

`avbtool verify_image`: OK (rollback 13, DT-Table `d7b7ab1e` ok).
`verify.sh /tmp/opencode/c2s-diag2-out`: **139 passed, 0 failed**
(reference run: 139/0 - equal).

### Readout contract (candidate 2)

* White band, rows 0..127: M1 reached (MMU off).
* Red band, rows 128..255 below it: M2 reached (MMU + D-cache on,
  before start_kernel). Red on top of / next to white proves the stores
  went through the TTBR0 ID map while the MMU was live.
* No band change vs candidate 1: kernel died between M1 and M2
  (i.e. in `__enable_mmu()`/`__pi_early_map_kernel()`), a *new* failure
  class that candidate 1 could not distinguish from "bootloader never
  entered the kernel".

M3 and the display-independent trace region are still open (see plan);
this candidate does not implement them.
