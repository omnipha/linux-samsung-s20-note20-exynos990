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

## Candidate 3 (turn 2026-11-23): DECON refresh trigger

Candidate 2 paints the M2 band but never pushes it to the panel: sboot
writes `writel(0x3070, 0x19050070)` (`lk3rd app/exynos_boot/boot/
cmd_boot.c:730-731`) right before `kernel_entry`, which sets bit 4 of
`HW_SW_TRIG_CONTROL` (`HW_TRIG_MASK_DECON`,
`platform/exynos9830/include/dpu/cal/regs-decon.h:190`) plus the slave
mask bits and the trigger edge/value (bits 5, 6, 12, 13), and clears
bit 0 (`HW_TRIG_EN`, `regs-decon.h:193`). So the panel is masked from
DECON at handoff. Without an unmasking refresh sequence, plain writes
to the framebuffer never reach the display, no matter how correct the
colour or geometry is.

### Register evidence (lk3rd, exynos9830 platform, target/c2s)

| register | offset | bits used | file:line |
|---|---|---|---|
| `DECON0_BASE_ADDR` | `0x19050000` | - | `platform/exynos9830/include/dpu/display_sfr.h:40` (c2s uses `PLATFORM := exynos9830`, `target/c2s/rules.mk:4`) |
| `GLOBAL_CONTROL` | `0x0000` | `DECON_EN (1<<1)`, `DECON_EN_F (1<<0)`, `RUN_STATUS (1<<4)`, **`SRESET (1<<28)` must never be written** | `regs-decon.h:103-116` |
| `SHADOW_REG_UPDATE_REQ` | `0x0060` | `GLOBAL (1<<31)`, `FOR_DECON (0x3f)` | `regs-decon.h:168-172` |
| `HW_SW_TRIG_CONTROL` | `0x0070` | `HW_TRIG_EN (1<<0)`, `HW_TRIG_MASK_DECON (1<<4)`, `HW_TRIG_MASK_SLAVE0 (1<<5)`, `HW_TRIG_MASK_SLAVE1 (1<<6)`, `HW_TRIG_EDGE_POLARITY (1<<12)`, `HW_TRIG_ACTIVE_VALUE (1<<13)` | `regs-decon.h:177-193` |

Vendor refresh function (`decon_show_buffer_update`,
`platform/exynos9830/dpu/decon_core.c:114-134`) mirrors this sequence:

1. `decon_reg_all_win_shadow_update_req` (`cal/decon_reg.c:1923-1930`):
   mask `0x3f`, val `~0` → `SHADOW_REG_UPDATE_REQ |= 0x3f`
2. `decon_reg_direct_on_off(1)` (`cal/decon_reg.c:61`): mask
   `DECON_EN|DECON_EN_F`, val `~0` → `GLOBAL_CONTROL |= 0x3`
3. `decon_reg_update_req_global` (`cal/decon_reg.c:1775`):
   mask `GLOBAL (1<<31)`, val `~0` → `SHADOW_REG_UPDATE_REQ |= 1<<31`
4. `decon_reg_wait_run_status_timeout (20ms)`: poll `RUN_STATUS`
5. `decon_reg_set_trigger(ENABLE)` when `psr_mode == DECON_MIPI_COMMAND_MODE`
   (`cal/decon_reg.c:1970-1989`): mask `HW_TRIG_EN|HW_TRIG_MASK_DECON`,
   val `HW_TRIG_EN` → clear `HW_TRIG_MASK_DECON`, set `HW_TRIG_EN`
6. `decon_reg_wait_update_done_timeout (SHADOW_UPDATE_TIMEOUT=300ms,
   decon.h:79)` (`cal/decon_reg.c:1998-2012`): poll
   `SHADOW_REG_UPDATE_REQ == 0`
7. `decon_reg_set_trigger(DISABLE)`: mask `HW_TRIG_EN|HW_TRIG_MASK_DECON`,
   val `HW_TRIG_MASK_DECON` → restore `HW_SW_TRIG_CONTROL` to the
   masked state matching sboot's `0x3070` handoff.

`decon_write_mask` (`include/dpu/decon.h:476-482`):
`val = (val & mask) | (old & ~mask)` — a masked RMW. The head.S
implementation reproduces that exactly: every write to `GLOBAL_CONTROL`
and `HW_SW_TRIG_CONTROL` uses the same masks the vendor's own refresh
uses, so bits outside those masks are written back with the value the
preceding read returned, not with a value we picked. That is *not* a
proof that `GLOBAL_CONTROL` bit 28 (SRESET, write-1-to-reset) never
receives a 1 from us: vendor evidence (`cal/decon_reg.c:30-46`,
`decon_reg_reset()`) deliberately *does* write bit 28 as 1
(`write_mask(..., ~0, SRESET)`, line 33) and polls for it to self-clear
(lines 34-38), and `decon_reg_direct_on_off()` (lines 61-67) uses mask
`0x3` exactly as we do — so both it and our macro write back whatever
the hardware reported for bit 28. At this point in the boot we do not
verify that value; it is normally 0 because vendor's own `decon_reg_
reset()` waited for self-clear before handing off to the kernel, but
that is an assumption about the running sboot/lk3rd sequence, not a
host-measured fact. c2s has `psr_mode = 2` (MIPI command) and
`trig_mode = 0` (hw trigger), so branch (2)/`DECON_SW_TRIG` is not
taken.

### Implementation

* **head.S**: `c2s_decon_refresh id` macro (immediately before
  `SYM_CODE_START(primary_entry)`) implementing steps 1-7 with only
  `x4..x6`; the arch timer is disabled before `kernel_entry`
  (  `cmd_boot.c:732-734`), so the two waits are bounded iteration
  counters (`0x4000` each). The bound prevents the *loop* from spinning
  forever when DECON's RUN_STATUS never sets or SHADOW_REG_UPDATE_REQ
  never clears; it does not make a DECON MMIO read safe — a read from
  `0x19050000` that hangs the bus, or that raises an external abort
  (e.g. if TZSASC blocks the non-secure world), stops the CPU
  regardless of any counter. On loop timeout the sequence simply falls
  through. Invoked once after the
  M1 band and `dsb sy` (MMU off → plain physical device access) and
  once after the M2 band + `dc civac` flush loops (MMU on → device
  map below).
* **map_range.c**: `create_init_idmap()` gained a fourth `CONFIG_C2S_DIAG`
  entry, `map_range(&ptep, 0x19050000, 0x19051000, 0x19050000, dev_prot,
  ...)` with `dev_prot = __pgprot(PROT_DEVICE_nGnRE) & ~clrmask`. The
  prot's `PTE_WRITE` bit survives the `clrmask = PTE_SHARED` applied by
  both callers, so M2's DECON SFR stores are writable.
* **kernel-pgtable.h**: `EARLY_IDMAP_DIAG_EXTRA_PAGES = 32` is unchanged
  (still comfortably above the ~6 tables the three FB ranges + DECON
  actually cost, measured against `map_range`'s recursion at the real
  CONFIG_PGTABLE_LEVELS=5 / 4K-page geometry).

### M2 safety analysis (this is the part that used to be open)

* MAIR_EL1 index 4 = `MAIR_ATTR_DEVICE_nGnRE` is programmed
  unconditionally by `__cpu_setup` (`arch/arm64/mm/proc.S:539`,
  `MAIR_EL1_SET` at proc.S:74-79) *before* `__enable_mmu`, which is
  reached only via `b __primary_switch`. So at M2, index 4 = nGnRE is
  already live in the register that VMSA actually reads.
* At M2 the active EL is always **EL1**: `init_kernel_el` sets
  `spsr_el2 = INIT_PSTATE_EL1` and erets to EL1 (head.S:487-490), and
  `finalise_el2` (VHE, `head.S:404`) runs *after* the M2 paint inside
  `__primary_switched`. So `mair_el1` is the register in play at M2,
  not `mair_el2`. (This is the specific concern from the milestone
  notes; it is now source-proven, not assumed.)
* `CONFIG_ARM64_LPA2=y` + `CONFIG_ARM64_VA_BITS=52` in the c2s defconfig
  would normally force the idmap to be rebuilt into `init_pg_dir`
  (via `remap_idmap_for_lpa2()` in map_kernel.c:165-198) — that pool
  is sized by `INIT_DIR_SIZE`, which does not include the diag extras.
  That rebuild is gated on `cpu_has_lpa2()` (cpufeature.h:1063-1075),
  which reads `ID_AA64MMFR0_EL1.TGRAN_*`; `early_map_kernel`
  (map_kernel.c:260-263) downgrades `va_bits` to `VA_BITS_MIN` and
  skips the rebuild when it reports false. The Exynos990 CPU cores are
  Cortex-A76 + Cortex-A55 (`arm,cortex-a76`/`arm,cortex-a55` in
  exynos990.dtsi:74-109) — Armv8.2-A parts; FEAT_LPA2 was introduced
  in Armv8.7-A, so these cores do not implement it and the host can
  *expect* `cpu_has_lpa2()` to return false. Note this is still not a
  host measurement (only the SoC's ID registers can answer it) — the
  documented architecture of the CPU cores is the basis, and the
  claim is deliberately weaker than "proved": if a future part with
  LPA2 ran this Image, the fallback in map_kernel.c:260-263 would
  instead rebuild the idmap into `init_pg_dir`, which is sized without
  the diag extras.
* `map_kernel()` only writes TTBR1 (`idmap_cpu_replace_ttbr1`,
  map_kernel.c:99); `early_map_kernel` never touches TTBR0 on the
  non-LPA2 path. So the C2S idmap entries (FB + DECON) are still the
  ones TTBR0 points at when `__primary_switched` runs.

### Artefacts (candidate 3, combined build: markers + trigger + committed USB fixes)

| Artefact | Pfad | Größe (B) | sha256 |
|---|---|---|---|
| boot.img (signed, candidate 3) | `/tmp/opencode/c2s-diag3-out/boot.img` | 61 865 984 | `63421d0402a4cfbae7fde455344c1d8a0f4167ddb54560affead94fc44d40991` |
| Image (diag3) | `/tmp/opencode/c2s-diag3-out/kbuild/arch/arm64/boot/Image` | 11 891 200 | `e096ecfe98ac8923e271ae0626a191819ac76fe2d004dfcf14a71cd647e2f8ad` |
| DTB (diag3, with committed USB fixes) | `/tmp/opencode/c2s-diag3-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 867 | `43424d49fc43e92ef00cff558058a3edb232592ab3bd89e6f4262b449fb122f2` |
| baseline (no markers/trigger) boot.img | `/tmp/opencode/c2s-diag3-base-out/boot.img` | 61 865 984 | `abcd8fdc0e0af01b5d2ba59670106f8a6e4bf2e2bc1ebef1a907194bac49c7c0` |

* `CONFIG_C2S_DIAG=y` in `/tmp/opencode/c2s-diag3-out/kbuild/.config`.
* Disassembly of `/tmp/opencode/c2s-diag3-out/kbuild/vmlinux`:
  `primary_entry` contains `mov x4, #0x19050000` at
  `ffff8000806cc158` followed by `ldr/str [x4, #96]` (SHADOW_REG_UPDATE_REQ
  @ 0x60), `ldr/str [x4]` (GLOBAL_CONTROL @ 0x00, ORR with `#0x3` — this
  mask leaves bit 28 equal to whatever the preceding read returned, see
  the SRESET note above; it is *not* an instruction that writes 0 to
  bit 28), `tbnz w5, #4` (RUN_STATUS poll) and
  `ldr/str [x4, #112]` (HW_SW_TRIG_CONTROL @ 0x70, `and w5, w5, #0xffffffef`
  then `orr w5, w5, #0x1` for the enable step and the inverse for the
  disable step). The same block appears in `__primary_switched`
  (`ffff8000806e84ac`) at `ffff8000806e85a4`. `map_range.o` carries the
  `0x19050000` constant for the device mapping.
  This address-by-address disassembly is the direct evidence that the
  trigger is present in **both individual call sites** (M1 in
  `primary_entry`, M2 in `__primary_switched`).
* **verify.sh**: 173 passed / 0 failed on the diag3 candidate **and** on
  the paired baseline. The added DECON gate is an instruction-level
  MOVZ scan for `0x1905` (`movz xN, #0x1905, lsl #16`): diag mode
  requires `count >= 2` and baseline mode requires `count == 0`. The
  gate only counts occurrences in the Image and cannot tell *where*
  they are, so it does NOT prove the two call sites individually;
  per-call-site verification comes from the vmlinux disassembly above.
* **9-overlay merge gate** (fdtoverlay of stock overlay0..8 on the
  built DTB): still passes with the same shape as the candidate-2 gate
  - live `/soc@0/usb@10e00000/usb@0` `dr_mode = "peripheral"`, no
    `maximum-speed`, status `okay`; live PHY: both `vbus-supply` and
    `vbus-boost-supply` present (phandle `0x11` = `reg_dummy`); the
    inert shell `/usb@10E00000` keeps `status = "okay"` but has
    `compatible = "samsung,exynos-dwusb"`, which matches no driver
    (and is not in `of_platform_default_populate`'s match table, see
    `drivers/of/platform.c:371-377`), so the shell children are never
    instantiated; the shell dwc3 on `0x10e00000` is not probed.
* **authorized_keys**: `verify.sh` reads the packaged cpio, confirms
  the fingerprint matches `~/.ssh/id_ed25519.pub`
  (`SHA256:kX1/T8o7ReIa9OJgX0ADSD03lf/XvAFw5lqbAAUonAE`), mode 0600.

### What this candidate is and is not

* **is**: an Image whose `primary_entry` and `__primary_switched`
  paint their bands *and* invoke a DECON command-mode refresh whose
  every write is a source-verified masked RMW. If the kernel really
  entered and DECON/panel are still healthy, the bands should now
  actually reach the panel; if the panel remains blank, the failure
  is either upstream of `primary_entry` or the display path itself
  (DPU powered down, panel off, MIPI link dead, ...) — a *different*
  failure class than the pure "we painted DRAM but never refreshed"
  that candidates 1 and 2 could not distinguish from.
* **is not**: proof of any specific on-panel pixel. Only a hardware
  run with the operator's camera on the display can show that. The
  bounded polls (16384 iterations each) mean a hung DECON does not
  hang the boot; but a hung DECON also means no visible band.
* **is not**: pstore/ramoops. That channel is deliberately out of
  this candidate (see `evidence.md` and `boot-and-open-points.md`).

M3 and the display-independent trace region remain open.

## Candidate 4 (turn 2026-11-23): M1b + M2 fix + M3 + M4 ladder

Candidate 3 landed on hardware as: white band (rows 0..127) over the
standing Samsung logo, **no** red band, **no** USB enumeration, **no**
SSH. Three facts make "the kernel died before M2" the only fully
consistent hypothesis - but one more candidate symptom is
indistinguishable from it: M1's `c2s_decon_refresh m1` is the sole
piece of code in `primary_entry` that performs **MMIO while the MMU is
off**, so a hang or external abort there stops the CPU in exactly the
place where the white band has already been written to DRAM and may
already have been latched. This candidate turns that ambiguity into a
readable band.

### Defect found while auditing the emitted encodings

Every marker paints with `stp x4, x4, [x6], #16`, which stores 64 bits
= **two** a8r8g8b8 pixels per store. For a solid band both 32-bit
halves must therefore carry the same colour, i.e. the value needs all
four 16-bit chunks set. Auditing `objdump` against that rule found two
real defects:

| marker | code before | painted colour before | code after | painted colour after |
|---|---|---|---|---|
| M1 white | 4 chunks (`movz` + 3 `movk`) | solid `0xffffffff` | unchanged | solid `0xffffffff` |
| M2 red | `movz #0` + `movk #0xffff<<16` only (2 chunks) | alternating `0xffff0000` / `0x00000000` = red **and black** stripes | 4 chunks | solid `0xffff0000` |
| M1b green | 2 chunks, and offset `0x12c000` (rows 245, not 256) | alternating `0xff00ff00` / `0` at the wrong rows | 4 chunks, offset `0x168000` | solid `0xff00ff00`, rows 256..383 |
| M3 blue | 2 chunks (`movz #0x00ff` + `movk #0xff00<<16`) | alternating `0xff0000ff`/`0`, and **identical to M4's build** | 4 chunks | solid `0xff0000ff`, rows 384..511 |
| M4 magenta | 2 chunks | alternating `0xffff00ff`/`0`, identical to M3's | 4 chunks | solid `0xffff00ff`, rows 512..639 |

M1 proved on hardware *because* it already had all four chunks; M2/M3/M4
would have painted striped, near-invisible bands. Candidate 2/3's
"M2 red not observed" was therefore partly a **painting** defect, not
only a control-flow defect.

### The ladder

| marker | rows | colour (AARRGGBB) | where | MMU | DECON refresh |
|---|---|---|---|---|---|
| M1 | 0..127 | white `0xffffffff` | `primary_entry`, first code | off | yes (`m1`) |
| M1b | 256..383 | green `0xff00ff00` | `primary_entry`, after `create_init_idmap` + cache maintenance, before `init_kernel_el` | off | **no** |
| M3 | 384..511 | blue `0xff0000ff` | `__primary_switch`, immediately after `__enable_mmu()` | on | **no** |
| M2 | 128..255 | red `0xffff0000` | `__primary_switched`, first code | on | yes (`m2`) |
| M4 | 512..639 | magenta `0xffff00ff` | `__primary_switch`, after `__pi_early_map_kernel()`, before the jump to `__primary_switched` | on | **no** |

Readout contract:

* white only -> M1's refresh never returned, or the CPU died before M1b;
  **M1b green present but nothing else** -> M1's refresh returned and
  `create_init_idmap()` completed, so the fault is at or after
  `init_kernel_el()`/`__cpu_setup()`/`__enable_mmu()`.
* green + blue -> `__enable_mmu()` returned and the MMU is on with the
  ID map still in TTBR0 (M3 paints through it), so the fault is inside
  `__pi_early_map_kernel()` (relocation, BSS clear, TTBR1 build).
* red -> the ID map survived `early_map_kernel()` and M2 ran with the
  MMU on.
* magenta -> the whole early path up to `start_kernel()` completed.

M1b/M3/M4 deliberately paint and, where the D-cache is on, `dc civac`+
`dsb sy` the band but perform **no** DECON MMIO. Only M1 and M2 trigger
a refresh, so a band painted after the last refresh is latched by that
same refresh later in the sequence (M1b/M3/M2) or by M2's refresh
(M4's own trigger is not issued), keeping the number of MMIO-while-MMU-off
sites at exactly the one that is already proven on hardware.

### Host evidence (candidate 4)

* Build: `C2S_DEFCONFIG=c2s_rescue_diag_defconfig
  C2S_AUTHORIZED_KEYS=$HOME/.ssh/id_ed25519.pub build.sh`, exit 0.
* `verify.sh /tmp/opencode/c2s-diag5-out`: **173 passed, 0 failed**
  (same count as the diag3 baseline; the added band gate replaces
  nothing).
* New gate: instruction-level scan of the **packaged** Image that
  anchors on the fixed `movz x9, #5760` / `movz x10, #128` prologue of
  every marker and walks the colour build in front of it, requiring
  exactly `movz` + 3 `movk` into `x4` and `lo32 == hi32`.
  * on this candidate: 5 markers, all `SOLID` (RC=0).
  * negative control on the diag3 Image: `marker@0x6e84b0
    colour=0x00000000ffff0000 TRUNCATED (2/4 chunks)` (RC=1), i.e. the
    gate fails on the very defect it was written for.
* DECON MMIO count in `vmlinux` is still **3** (`mov xN, #0x19050000`
  at `primary_entry` = M1, `create_init_idmap()` = the idmap device
  constant, `__primary_switched` = M2); M1b/M3/M4 add none.
* Kernel payload extracted from the signed `boot.img` (Samsung
  `ANDR` header, `kernel_size` at +8, payload at `+0x800`) is
  byte-identical to `kbuild/.../Image`, and the band gate run against
  that extracted payload reports the same 5 `SOLID` markers.

### Artefacts (candidate 4)

| Artefact | Path | Size (B) | sha256 |
|---|---|---|---|
| boot.img (signed, candidate 4) | `/tmp/opencode/c2s-diag5-out/boot.img` | 61 865 984 | `852e868d1e4c3a9d608797116f230a9e31f2cc5abff0890406907c2fa9809f5b` |
| Image (diag5) | `/tmp/opencode/c2s-diag5-out/kbuild/arch/arm64/boot/Image` | 11 891 200 | `d6c45e58d6f60e7d52280f492ccf37e262ab5019d93c73cd6b649df30dec80ee` |
| DTB | `/tmp/opencode/c2s-diag5-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 867 | `43424d49fc43e92ef00cff558058a3edb232592ab3bd89e6f4262b449fb122f2` |
| initramfs | `/tmp/opencode/c2s-diag5-out/work/initramfs.cpio.gz` | 2 496 684 | `eaa35da0a3029b371af55fc19c7049ac52f0ce893dd451a559c0a0a0ee48ce8d` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table
`d7b7ab1e` ok, `avbtool verify_image` OK.

Band addresses in the Image (offset = VA - `0xffff800080000000`):

| marker | Image offset | first instruction | value |
|---|---|---|---|
| M1 white | `0x6cc0b8` | `mov x4, #0xffff` | `0xffffffffffffffff` |
| M1b green | `0x6cc224` | `mov x4, #0xff00` | `0xff00ff00ff00ff00` |
| M3 blue | `0x6cc814` | `mov x4, #0x00ff` | `0xff0000ffff0000ff` |
| M4 magenta | `0x6cc928` | `mov x4, #0x00ff` | `0xffff00ffffff00ff` |
| M2 red | `0x6e84b0` | `mov x4, #0x0` | `0xffff0000ffff0000` |

### Still open

* sudo/NOPASSWD packaging (binary + active `@includedir` + root-owned
  0440 rule verified in the packed cpio) - required by issue #5 task 3,
  **not** in this candidate.
* The USB gadget path fixes for issue #5 task 2 are separate from the
  markers; this candidate changes only `head.S` and `verify.sh`.
* Every claim about what the panel shows remains host-unverified until
  the coordinator runs the hardware readout.

## Candidate 5 (turn 2026-11-23): M1b control-flow fix + passwordless sudo

### Defect: the M1b green band was unreachable on the device's own path

Candidate 4 shipped M1b between the `0:` and `1:` labels of
`primary_entry`. The MMU-off entry path - the one this device takes,
because the bootloader disables the MMU before jumping to the kernel -
executes `b 1f` to skip the dcache maintenance, which jumped **over the
whole M1b block**. Every byte-level gate passed (the movz+3×movk colour
build was present and solid) and the green band could never appear on
the panel. The cache-on path fell through into M1b, so the band was
reachable from one of the two entry paths but not the other.

The fix moves label `1:` to immediately after the `0:` block's `blr x2`,
i.e. **before** the M1b block, so the cache-off path's `b 1f` lands on
the M1b block and the cache-on path falls through into it. Both paths
then execute M1b and join at the `mov x0, x19` that follows. Label
numbering was checked first: within `primary_entry` the only numeric
label references are `cbnz x19, 0f` and `b 1f`, and there is **no `1b`
anywhere in `head.S`**, so moving `1:` cannot retarget any other
reference (the other `1:`/`2:` labels live in `record_mmu_state`,
`init_kernel_el` and later functions).

### New regression: CFG-reachability gate

Marker *bytes* in the Image prove the code was compiled in; they say
nothing about whether the CPU can ever execute it. This is exactly the
defect above, which is why a byte-level gate could not catch it.

`c2s-rescue/scripts/check-marker-reachability.py` builds a control-flow
graph from the **disassembly** of a function and reports, per marker,
whether its first instruction is reachable from the function entry. For
`primary_entry` it additionally splits reachability at the `cbnz x19`
MMU-state branch and requires the marker to be reachable on **both** the
cache-off and the cache-on path. It is wired into `verify.sh` for
`primary_entry` (M1 + M1b), `__primary_switch` (M3 + M4) and
`__primary_switched` (M2).

The gate carries its own **negative control**: a committed pre-fix
objdump listing (`c2s-rescue/tests/fixtures/primary_entry.prefix-m1b-unreachable.txt`)
which the checker must *reject* (`--expect-unreachable`). If that input
ever reports PASS the gate has become insensitive and the regression is
no longer guarded - the control therefore proves the gate is sensitive
rather than merely asserting it.

A second gate defect was found and fixed while wiring it in: the
M4 colour key in `MARKER_COLOURS` was wrong (`0xFFFF00FFFF00FFFF`, cyan)
instead of the actual build `0xFFFF00FFFFFF00FF`. The checker keys
markers by *shape* (a colour build in front of the stride/height
prologue), so reachability verdicts were unaffected, but M4 was reported
under a wrong name.

### Passwordless sudo for the SSH login user (issue #5 task 3)

The image now ships an unprivileged login account and passwordless sudo
for it, so an SSH session is not root:

| component | value |
|---|---|
| login account | `rescue`, uid 1000 gid 1000, home `/home/rescue`, shell `/bin/sh` |
| sudo | `sudo-rs 0.2.15` (postmarketOS aarch64 package), setuid root, `/usr/bin/sudo` |
| runtime | musl loader + `libc.musl-aarch64.so.1`, `libpam.so.0.85.1`, `libgcc_s.so.1`, `pam_permit.so` |
| sudoers | `/etc/sudoers` root-owned 0440 with an **active** `@includedir /etc/sudoers.d`; `/etc/sudoers.d/90-rescue` root-owned 0440 granting `NOPASSWD: ALL` to `rescue` and `root` |
| PAM | `/etc/pam.d/sudo` with `pam_permit` on auth/account/password/session |
| keys | the operator key is installed for **both** `root` and `rescue` (dropbear resolves `~/.ssh/authorized_keys` per user) |
| dropbear | started **without** `-D`, so each account reads its own `<home>/.ssh/authorized_keys` |

Non-obvious constraints that the implementation had to satisfy:

* **sudo-rs is unusually strict.** It refuses a sudo binary that is not
  owned by uid 0 *with* the setuid bit, refuses a sudoers file that is
  not root-owned mode 0440, refuses an inactive `@includedir`, and
  aborts outright when `/etc/pam.d/sudo` is missing. `Defaults
  !authenticate` is rejected as an unknown setting.
* **The `-D` removal is required, not cosmetic.** dropbear opens
  `authorized_keys` with `seteuid()` to the authenticating user
  (`svr-authpubkey.c`), so a root-owned 0600 key file is unreadable for
  a uid 1000 login. With `-D /root/.ssh` forced for everyone, the
  `rescue` account could never authenticate. Per-user `~/.ssh` is
  therefore the only workable arrangement, and `/home/rescue` must be
  owned by uid 1000 so dropbear's `checkpubkeyperms()` path walk (owner
  == login user or root, no group/other write) accepts it.
* **`sudo -n id` needs `id` on the image's PATH.** sudo-rs's
  `secure_path` is `/usr/bin:/bin:/usr/sbin:/sbin`, and busybox's `id`
  applet was not linked into the initramfs, so `id`/`whoami`/`groups`
  were added to the `APPLETS` list. Without this the acceptance command
  fails with `id: command not found`.
* **gen_initramfs.sh's `-u squash -g squash` does not apply here.** That
  remap only runs for *directory* sources; a plain cpio list file is
  `cat`'d verbatim, so the uid/gid written into the list are the ones
  that land in the archive. This is why `/home/rescue` can really be
  uid 1000. New helper `c2s-rescue/scripts/cpio-listing.py` parses the
  newc headers and prints **numeric** mode/uid/gid: `cpio -itv` resolves
  the uid against the *host* passwd database, so an entry that must be
  owned by uid 1000 renders as `gregor gregor` on this build host and a
  name-based check would be meaningless.
* **Setuid survives packing.** `gen_init_cpio` writes `mode | S_IFREG`
  verbatim, and the kernel's initramfs unpacker does `vfs_fchown` then
  `vfs_fchmod(wfile, mode)`; `chmod_common` keeps `S_IALLUGO` (which
  includes `S_ISUID`) and sets no `ATTR_KILL_PRIV`.

### Host evidence (candidate 5)

* Build: `C2S_DEFCONFIG=c2s_rescue_diag_defconfig
  C2S_AUTHORIZED_KEYS=$HOME/.ssh/id_ed25519.pub
  C2S_OUTDIR=/tmp/opencode/c2s-diag6-out build.sh`, exit 0.
* `verify.sh /tmp/opencode/c2s-diag6-out`: **217 passed, 0 failed**
  (candidate 4 had 173; the increase is the new sudo and CFG gates).
* **CFG gate, `primary_entry` on this candidate:** M1-white *and*
  M1b-green reachable from entry **and from both** MMU-state paths
  (cache-off + cache-on). M3 + M4 reachable from `__primary_switch`,
  M2 reachable from `__primary_switched`.
* **CFG negative control:** the committed pre-fix listing is rejected
  (`RESULT: PASS (1 marker(s) unreachable - gate correctly rejects this
  input)`), i.e. the gate is sensitive.
* **Band gate on the packaged kernel payload:** 5 markers, all `SOLID`.
  The payload embedded in `boot.img` (Samsung `ANDR` header,
  `kernel_size` at +8 = 12 808 704, payload at +2048) is **byte-identical**
  to `kbuild/.../Image`.
* **Functional sudo under qemu, in a root-owned chroot of the packed
  rootfs:** `sudo -n -l -U rescue` prints `(ALL : ALL) NOPASSWD: ALL`;
  `sudo -n id` prints `uid=0(root) gid=0(root) groups=0(root)`.
* **sudo negative control:** with the setuid bit cleared and the command
  run as an unprivileged account inside the same chroot, sudo-rs refuses
  with `sudo: sudo must be owned by uid 0 and have the setuid bit set`.
  This control *must* run as non-root: sudo-rs only enforces the check
  for a non-root caller, and `chroot()` needs `CAP_SYS_CHROOT`, so the
  tree is entered by root and the command is then run via `sudo -u`.
* **Native (x86_64) proof of the elevation path:** with the exact
  candidate `/etc/sudoers` + `/etc/sudoers.d/90-rescue` + `/etc/pam.d/sudo`
  bound over the host's sudo-rs 0.2.13 and the caller dropped to a
  non-root uid, `sudo -n id` returned `uid=0(root) gid=0(root)
  groups=0(root)`. Root was correctly refused ("I'm sorry root. I'm
  afraid I can't do that") because it had no rule at that point. The
  host's `/etc/sudoers` was restored and re-verified afterwards.

### Artefacts (candidate 5)

| Artefact | Path | Size (B) | sha256 |
|---|---|---|---|
| boot.img (signed, candidate 5) | `/tmp/opencode/c2s-diag6-out/boot.img` | 61 865 984 | `13cdc38ca0725706d7367ef9fcd023e1ce5bdd034f8436720da67e9688c49243` |
| Image (diag6) | `/tmp/opencode/c2s-diag6-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `909d03e1c971302f9b805384d2ac97f958add003a85d9029417c1b50f952eb9a` |
| DTB | `/tmp/opencode/c2s-diag6-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 867 | `43424d49fc43e92ef00cff558058a3edb232592ab3bd89e6f4262b449fb122f2` |
| initramfs | `/tmp/opencode/c2s-diag6-out/work/initramfs.cpio.gz` | 3 367 458 | `515de1c3d5d9cb4ef6196d4382bfd6b7e3c41a17461e00662e486769758c70fa` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table
`d7b7ab1e` ok, `avbtool verify_image` OK, FDT 141 867 B == kbuild DTB.

Band addresses in the Image (offset = VA - `0xffff800080000000`):

| marker | Image offset | first instruction | value |
|---|---|---|---|
| M1 white | `0x6cc0b8` | `mov x4, #0xffff` | `0xffffffffffffffff` |
| M1b green | `0x6cc224` | `mov x4, #0xff00` | `0xff00ff00ff00ff00` |
| M3 blue | `0x6cc814` | `mov x4, #0x00ff` | `0xff0000ffff0000ff` |
| M4 magenta | `0x6cc928` | `mov x4, #0x00ff` | `0xffff00ffffff00ff` |
| M2 red | `0x6e84b0` | `mov x4, #0x0` | `0xffff0000ffff0000` |

### Still open

* **qemu-user does not emulate setuid elevation**, so a non-root
  `sudo -n id` cannot be exercised on the build host: the elevation
  path is proven natively on the host's sudo-rs and must be confirmed
  on the device with `sudo -n id`.
* USB gadget enumeration (issue #5 task 2) and the panel readout
  (issue #5 task 1) are hardware-only; no host evidence can substitute.
* Every claim about what the panel shows remains host-unverified until
  the coordinator runs the hardware readout.

## Candidate 6 (turn 2026-11-24): C-level milestone ladder (issue #5)

Candidate 5 proved the whole asm ladder on hardware - white, red, green,
blue and magenta all present over the Samsung logo - but the USB path still
never enumerated. The five asm markers are MMU-off/early-MMU only: they say
nothing about what `start_kernel()` did, whether the UDC was ever
registered, or whether `/init` exec'd. This candidate adds C-level bands
that continue the ladder from row 640 downwards.

### Why the two entry points (the part that needed a design decision)

The bands are written from two different places with different mapping
lifetimes, so there are two entry points rather than one:

| entry point | section | mapping | used for |
|---|---|---|---|
| `c2s_band_early(row, colour)` | `.init.text` | boot ID map, then `early_memremap()` | rows 640, 768, 896 (before `free_initmem()`) |
| `c2s_band(row, colour)` | `.text` | `ioremap_wc()` taken once by `c2s_late_init()` | rows 1024 and above |

`early_memremap()` lives in `.init.text`, so calling it from `.text` is a
section mismatch that modpost reports as an error - which is exactly the
first build failure this candidate hit, and why the API was split instead
of having one function do both. `c2s_late_init()` runs from `start_kernel()`
immediately after `mm_core_init()`, the point at which vmap and slab are up
(`mm/mm_init.c` calls `vmalloc_init()` there) and therefore `ioremap*()`
becomes legal.

Two mapping facts drive the rest:

* **fb0 and fb1 are `no-map` reserved memory** (`reserved-memory/framebuffer@f1000000`
  and `reserved-memory/audio@f7fb0000` in the DT), so `pfn_is_map_memory()`
  is false for them: `ioremap_wc()` maps them legally, and they are not in
  the linear map.
* **fb2 (`0xfac00000`) is unreserved RAM**. It is painted only while the
  boot ID map is still live (strictly before `arm64_memblock_init()`), which
  is the row-640 milestone; afterwards the page allocator owns it and
  `ioremap_wc()` would refuse to map it (and correctly so - writing there
  would corrupt the buddy allocator).

`ioremap_wc()` (PROT_NORMAL_NC) rather than `ioremap_cache()` is deliberate:
`simplefb` maps the very same physical range with `ioremap_wc()`
(`drivers/video/fbdev/simplefb.c:602`), so our alias carries the same
memory type fbcon writes through. A cacheable alias of an NC range would be
a mismatched-attribute alias; the plain stores through the NC alias reach
memory directly, and `mb()` orders them against the DECON MMIO.

### The ladder

| milestone | rows | colour (AARRGGBB) | where | mapping |
|---|---|---|---|---|
| C1 `start_kernel()` entry | 640..767 | yellow `0xffffff00` | first statement of `start_kernel()` | boot ID map (fb2 painted too) |
| C2 `setup_arch()` done | 768..895 | cyan `0xff00ffff` | after `setup_arch()` returns | `early_memremap()` |
| C3 `console_init()` done | 896..1023 | orange `0xffffa500` | after `console_init()` | `early_memremap()` |
| C4 UDC registered | 1024..1151 | pale blue `0xffadd8e6` | `usb_add_gadget()` success | `ioremap_wc()` |
| C5 `/init` exec attempted | 1152..1279 | pink `0xffffc0cb`, dark red `0xff8b0000` on failure | `run_init_process()` | `ioremap_wc()` |
| C6 gadget bound | 1280..1407 | lime `0xff32cd32` | `gadget_bind_driver()` success | `ioremap_wc()` |
| C6 gadget bind failed | 1408..1535 | salmon `0xfffa8072` | `gadget_bind_driver()` `err_bind` path | `ioremap_wc()` |
| C7 netdev carrier on | 1536..1663 | spring green `0xff00ff7f` | `gether_connect()` after `netif_carrier_on()` | `ioremap_wc()` |

Readout contract (execution order, not row order - the rows run top-down so
one photo reads as a timeline, but C4..C7 all happen after `/init` starts):

* **640 yellow only** - the kernel never left `start_kernel()`'s first
  statement, i.e. it died in the asm path after `__primary_switched`.
  (Candidate 5's hardware run already showed the asm ladder completing, so
  this case should not occur.)
* **640 + 768, no 896** - died between `setup_arch()` and `console_init()`
  (or `early_memremap()` failed there).
* **up to 896 orange, no 1024** - the kernel ran to `console_init()` but
  the UDC was never registered. That is a *driver probe* failure, not an
  enumeration failure: look at dwc3/exynos probe and the DT PHY supplies.
* **1024 pale blue present, no 1280/1408** - the UDC registered but the
  gadget driver never bound, or bound without ever reaching
  `gether_connect()`. The `c2s-gadget.sh` stage log (`KMSG`) is the
  companion readout for this case.
* **1280 lime** - the gadget driver bound and the UDC started.
* **1408 salmon** - bind/udc_start/connect control failed; this is the
  `err_bind` path and is the failure the `bind-failed-full` log line in
  `c2s-gadget.sh` reports from the userspace side.
* **1536 spring green** - the netdev carrier went up, i.e. the host has
  enumerated and the function is live. This is the "USB works" milestone.

The two milestones that are *not* visible as separate bands: the `/init`
attempt paints pink before `kernel_execve()` (so it appears even if exec
never returns) and overpaints dark red if exec fails - the final colour of
row 1152 is what distinguishes the two cases.

### Host-verified evidence (candidate 6)

* Build: `C2S_DEFCONFIG=c2s_rescue_diag_defconfig
  C2S_AUTHORIZED_KEYS=$HOME/.ssh/id_ed25519.pub
  C2S_OUTDIR=/tmp/opencode/c2s-diag7-out build.sh`, exit 0.
* `verify.sh /tmp/opencode/c2s-diag7-out`: **219 passed, 0 failed**
  (candidate 5 had 217; the increase is the new call-site gate plus its
  negative control).
* **Modpost is clean**: `c2s_band_early()` and `c2s_late_init()` sit in
  `.init.text` and `c2s_band()` in `.text`, with no `.text` → `.init.*`
  reference anywhere - the section-mismatch class that forced the API split
  is gone from the build output.
* **New gate, `check-c-milestone-bands.py`**: walks the disassembly of all
  five milestone-bearing functions and checks callee, row *and* colour per
  call site (10 sites: three `c2s_band_early` + one `c2s_late_init` in
  `start_kernel`, one in `usb_add_gadget`, two in `run_init_process`, two
  in `gadget_bind_driver`, one in `gether_connect`). Byte gates only prove
  `c2s_band()` was compiled in; they cannot tell a milestone wired to the
  wrong row from one that was never reached.
* **Gate negative control**: `c2s-rescue/tests/fixtures/gether_connect.wrong-row.txt`
  is a saved disassembly of `gether_connect()` with the row changed from
  1536 to 1537. The gate must *reject* it (`RESULT: FAIL`), otherwise it
  cannot detect row/colour drift. It does reject it.
* **Compile-out control**: a fresh `c2s_rescue_defconfig` baseline build
  (`/tmp/opencode/c2s-diag7-base-out`) has `# CONFIG_C2S_DIAG is not set`,
  no `c2s_band`/`c2s_late_init`/`c2s_decon_kick` symbols in `vmlinux`, and
  zero framebuffer MOVZ immediates in the Image. Its `verify.sh` run also
  reports **219 passed, 0 failed**, with the baseline branch of the new
  gate confirming no milestone call sites exist - so the diagnostic cannot
  leak into the USB baseline image.
* `CONFIG_C2S_DIAG=y` in the final `.config`; `arch/arm64/kernel/Makefile`
  carries `CFLAGS_REMOVE_c2s_diag_bands.o := -fstack-protector
  -fstack-protector-strong` and `KASAN_SANITIZE_c2s_diag_bands.o := n`
  (the painter runs before `boot_init_stack_canary()`).

### Artefacts (candidate 6, diag)

| Artefact | Path | Size (B) | sha256 |
|---|---|---|---|
| boot.img (signed, candidate 6) | `/tmp/opencode/c2s-diag7-out/boot.img` | 61 865 984 | `ed506c5f3b0712ca8f514f5617fd47997d991d7445eff7a30b6f831d73ffa751` |
| Image (diag7) | `/tmp/opencode/c2s-diag7-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `c79875f6f563fcb17df6da0c1c4ec24760a91690b35f8d21d5317a44ef6b2153` |
| DTB | `/tmp/opencode/c2s-diag7-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 867 | `43424d49fc43e92ef00cff558058a3edb232592ab3bd89e6f4262b449fb122f2` |
| initramfs | `/tmp/opencode/c2s-diag7-out/work/initramfs.cpio.gz` | 3 367 458 | `515de1c3d5d9cb4ef6196d4382bfd6b7e3c41a17461e00662e486769758c70fa` |

The DTB and initramfs are byte-identical to candidate 5 - this candidate
changes no device-tree content and no initramfs content, only the kernel
Image. AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table
`d7b7ab1e` ok, `avbtool verify_image` OK.

### Artefacts (candidate 6, paired baseline)

| Artefact | Path | Size (B) | sha256 |
|---|---|---|---|
| boot.img (signed, baseline) | `/tmp/opencode/c2s-diag7-base-out/boot.img` | 61 865 984 | `085a4b7168519cce2f1e00efa1f70a0433ac967642b05cf3b18074f9bb3a5d3b` |
| Image (baseline) | `/tmp/opencode/c2s-diag7-base-out/kbuild/arch/arm64/boot/Image` | 12 677 632 | `a713350af1a6036ee779d5ffdc1144a598c6605e8d15a7677687932cb2b21505` |

### Still open

* Every claim about what the panel shows remains host-unverified until
  the coordinator runs the hardware readout (issue #5 task 1).
* Which of fb0/fb1 the DECON actually scans out is still not proven from
  sources; both are painted on every late milestone, so the readout is
  unaffected, but a band visible in one buffer and not the other would
  identify the scanout source.
* fbcon may overwrite C bands at rows >= 640 if the console ever renders;
  so far no console text has appeared on the panel.
* The dwc3/exynos root cause behind the USB failure is still not proven
  from sources - this candidate *locates* the failure in the ladder, it
  does not fix it.
