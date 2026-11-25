# c2s rescue: evidence log (issue #1)

Host-only evidence collected while preparing the minimal kernel and USB
rescue image for the Galaxy S20 Ultra / Note20 (c2s, Exynos990). No file
was written to the device, nothing was flashed or rebooted; all device
data was captured through read-only ADB against the running vendor
kernel (TWRP-booted 4.19.87).

## Device evidence (read-only ADB)

Capture script: reproducible via the same commands (all read-only);
full raw log was 238 lines, verified to contain **zero** occurrences of
the device serial or of the serial-bearing command line tokens before
anything was kept (the serial itself is deliberately not quoted here
nor anywhere else in this repository). The `/proc/cmdline` was never
stored (it contains the serial); only an allowlisted subset of tokens
was recorded.

### Memory layout (`/proc/iomem`, "System RAM")

```
80000000-baafffff     System RAM
c1200000-dfffffff     System RAM
e1900000-ffffffff     System RAM
880000000-affffffff   System RAM   <- last region ends at 0xb00000000
```

Consequence for the DTS: the last `memory@80000000` block must reach
top = 0xb00000000. The shipped `exynos990-c2s.dts` had
`0x2 0x7e800000`; fixed in this branch (see
`arch/arm64/boot/dts/exynos/exynos990-c2s.dts`). The highmem region
(0x880000000..0xb00000000) is 10 GiB and is now expressed as five 2 GiB
chunks, because the root now uses `#size-cells = <1>` (32-bit size
cell) and a single entry cannot exceed 4 GiB.

### Framebuffer

```
/sys/class/graphics/fb0:
  virtual_size     = 1440,6176
  stride           = 5760
  bits_per_pixel   = 32
  modes            = U:1440x3088p-0
```

1440 * 3088 * 4 bytes = 17.3 MiB at the splash address 0xf1000000
matches `stride = 1440*4 = 5760`, 32 bpp. The DTS `simple-framebuffer`
node uses exactly this geometry; mainline `FB_SIMPLE` reads it from
`/chosen` at boot. Vendor `/chosen` has `bootargs`, `bootargs_ext`,
`linux,initrd-start/end` but **no** framebuffer node, so the region is
provided by the board DTS instead.

### USB / UDC

```
/sys/class/udc/ -> 10e00000.dwc3
```

This matches the mainline `usb@10e00000` dwc3 node in
`exynos990.dtsi` (`dr_mode = "otg"`, gadget-capable). The configfs
gadget in `/init` binds to this UDC. Vendor `maximum-speed` is
`super-speed-plus`; mainline dwc3-exynos currently negotiates less
(see open points).

### Input (hardware keys)

```
gpio_keys  Phys=gpio-keys/input0  EV=3 KEY=1c000000000000 0
```

Present alongside touchscreen devices. The vendor gpio-keys layout
(VOLUMEUP/VOLUMEDOWN/POWER, all `GPIO_ACTIVE_LOW`) is already correct
in `exynos990-c2s.dts`; `CONFIG_KEYBOARD_GPIO` + `INPUT_EVDEV` expose
it as `/dev/input/event*` for the rescue menu.

### UART (console)

Vendor DT lists `serial@10540000` / `serial@10840000` with
`samsung,exynos-uart`; **no mainline driver binds that compatible**
(the mainline Exynos serial driver does not cover exynos990's UART
block in this tree). Result: no serial console on this device with the
mainline kernel - `CONFIG_CMDLINE` uses `console=tty0` (framebuffer
console) only. Documented as an open point.

### Vendor `/chosen` (redacted, allowlisted tokens only)

`root=/dev/ram0`, `androidboot.hardware=exynos990`,
`loop.max_part=7`, `console=ram`, `loglevel=4`, `bootmode=2`,
`oops=panic`, `androidboot.dtbo_idx=7`,
`androidboot.verifiedbootstate=orange` and the bootloader/model
strings were recorded. Serial-bearing tokens were filtered at capture
time and never stored.

### Reserved memory

Vendor reserved-memory children (abox*, camera, ...) overlap the
`abox` region `f7fb0000-fa9fffff`; the splash at 0xf1000000 is
**not** in `/proc/iomem` as reserved, which is consistent with using
it as a simple-framebuffer region chosen by us.

## lk3rd RAM-boot failure root cause: root cell format (issue #4)

Host-side analysis of the lk3rd 2.3 sources (`~/github_repos/lk3rd`,
tag 2.3, HEAD `602fe05d300a…`) explains why the previous candidates
showed no sign of life under `fastboot boot`:

- lk3rd with mainline quirks **disabled** (quirks==0, the stock
  `boot_fb_boot` path) runs `add_dt_memory_node()`
  (`lib/fdtapi/fdtapi.c`), which **overwrites** the `/memory` `reg`
  property with 3-cell entries `<u64 addr u32 size>` (a missing node
  is added; an existing one is replaced — `fdt_add_subnode` returns
  `-FDT_ERR_EXISTS`, which is ignored, and `set_fdt_val` swaps the
  value regardless).
- The kernel then parses `/memory` with `of_flat_dt_get_addr_size_prop()`
  (`drivers/of/fdt.c`), which requires
  `len % ((dt_root_addr_cells + dt_root_size_cells) * 4) == 0`.
  With the previous root (`#address-cells=2`, `#size-cells=2`) the
  expected stride is 16 bytes but lk3rd writes 12 — every entry is
  rejected, the kernel sees **0 bytes of RAM** and dies before any
  console output. That matches the observed total silence (no LCD,
  no USB re-enumeration).
- lk3rd with quirks **enabled** (quirks==1, `mainline_boot` path)
  performs no memory surgery — but then hard-codes
  `/chosen bootargs = root=/dev/mem0 initrd=0x84000000,0x1000000`
  and `linux,initrd-start/end`; neutralised by
  `CONFIG_CMDLINE_FORCE=y`.
- The quirks flag is persisted in the `lk3rd` partition at offset
  0x175000; its power-on default (erased flash) is unknown, so the
  active path per boot is not known from the host.

Fix: the root of `exynos990-c2s.dts` now uses the stock cell format
`#address-cells = <2>`, `#size-cells = <1>`; every root-level `reg`
(including `/memory` and the `/chosen` framebuffer, whose cells are
taken from the parent) is expressed in 3-cell form, and the 10 GiB
highmem region is split into five 2 GiB chunks (32-bit size cell).
`/reserved-memory` must match the root cells
(`__reserved_mem_check_root()` returns `-EINVAL` otherwise), so it
and both children were converted to 2/1 + 3-cell `reg` as well.
All 74+ root-level anchor nodes in `c2s-overlay-anchors.dtsi`
already carry 3-cell `reg` and are correct under the new root
without regeneration (regenerated output verified byte-identical).

New gates in `c2s-rescue/scripts/verify.sh`: root cells must be 2/1
and every root-level `reg` a 3-cell multiple; `/reserved-memory`
must carry `#size-cells = <0x01>`; the memory spelling gate now
matches the five-chunk split ending at 0xb00000000.

## Kernel / initramfs build evidence

Environment (also in `build-record.txt` / `build.log`, produced by
`c2s-rescue/scripts/build.sh`):

| Item | Value |
|---|---|
| git rev | `13e4b531bcc17f85f3de3b75da1cc16569a0f2a4` |
| host | Linux 7.0.0-42-generic x86_64 |
| cross gcc | aarch64-linux-gnu-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| make / gzip / cpio / dtc | 4.4.1 / 1.14 / GNU 2.15 / DTC 1.7.2 |
| SOURCE_DATE_EPOCH | 1794605179 (timestamp of commit 13e4b531bcc1, pinned) |

External dependencies (verified by sha256 in `build.sh`, never
committed to the repo):

| File | sha256 |
|---|---|
| dropbear-2026.94.tar.bz2 | `e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81` |
| busybox-static 1.37.0-7ubuntu1 arm64 .deb | `fcf50794faf920455895d7ef103d1c54b9ebf7f18d2e52982dbf3903b7769592` |
| extracted `/usr/bin/busybox` | `c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02` |

Artifacts (byte-identical across two consecutive builds; issue #1
state - the DTB has since gained `/__symbols__` via `dtc -@`, see
`build-record.md`):

| Artifact | Size | sha256 |
|---|---|---|
| `Image` | 11,432,448 B | `dd6785a0a73841ca37ce7b623f2e782df5f3a6cb2e2a927c231ceea1b5f27f97` |
| `exynos990-c2s.dtb` | 38,288 B | `4e4e5702ce715ff4d8c0bc066a0c8d66a039473fdea49c423bc4d4cc8ad79b0f` |
| `initramfs.cpio.gz` | 2,211,972 B | `c84d00ec2981bc47b649a212d6d47c8d26ed13f0e082e24536fdc87fd8f581ff` |
| unpacked `initramfs.cpio` | | `df3e43d6fff5b0fc337a82704e7290c574b9c9fb225dc1a68e0500c24d5611fb` |

Reproducibility measures (all proven by a second full build producing
the same hashes):

- `SOURCE_DATE_EPOCH` = the pinned board-commit timestamp feeds
  `gen_initramfs.sh -d` (pinned cpio mtimes) and `KBUILD_BUILD_TIMESTAMP`
  (pinned `UTS_VERSION` in the Image).
- `KBUILD_BUILD_VERSION=1` pins the `#N` build counter.
- `CONFIG_LOCALVERSION="-c2s-rescue"` with `CONFIG_LOCALVERSION_AUTO`
  off pins the release string; otherwise the kernel release would carry
  the `git describe` output and every commit would change the `Image`.
- `CONFIG_INITRAMFS_SOURCE` is set to the *relative* path
  `initramfs.cpio.gz` inside the kbuild tree; an absolute path would
  leak the build directory into the Image via CONFIG_IKCONFIG.
- `KBUILD_BUILD_USER/HOST` pinned so `LINUX_COMPILE_BY@HOST` is
  constant.

Dropbear cross-build (static, aarch64, pubkey-only via
`c2s-rescue/dropbear/localoptions.h`):

```
dropbear    sha256 2fbd5988bd77e138acf6e0588943924bcd866585befb19204e45fb33a7ccfe9b  (1,487,336 B)
dropbearkey sha256 17f4e9a03f2d48cabd26358feabe11ed8d35f930f01ce11e8956c6df3f0378c6  (1,248,200 B)
```

## Host verification evidence (`verify.sh`)

`c2s-rescue/scripts/verify.sh` runs 140 checks, all passing on the
current artifacts. Beyond the issue #1 checks below it now covers
(issue #4): the shipped-archive applet symlinks, the console font
(`FONTS`/`FONT_TER16x32` config, `fbcon=font:TER16x32` in the embedded
cmdline and in the Image strings), and the boot menu - the exact
`rescue-menu-keys` binary from the archive is executed via qemu-user
against representative event streams (press/release/autorepeat/EV_SYN/
foreign keys, delayed fifo streams, gpio-keys NOT at event0 via a fake
sysfs tree, timeout, serial line handling incl. the drain window that
discards echoed menu text) and must always select `telnet` ONLY via an
explicit volume-down press or the serial line `telnet`; the packaged
`boot.img` dt slot is parsed independently (Samsung DT table magic
`0xd7b7ab1e` at the exact offset sboot computes, FDT byte-equal to the
kbuild DTB, `/__symbols__` present - the node sboot's libufdt overlay
step needs, whose absence stopped the previous candidate on the device
with "No node __symbols__ in main dtb.") and verified with avbtool.
A further section replays sboot's DTBO merge locally with `fdtoverlay`:
the built DTB must accept all 9 stock `dtbo.img` entries
(the overlay's `/__fixups__` resolves through the base `/__symbols__`),
with a positive control (stock base passes all 9 - proves the tool
invocation works) and a negative control (the anchorless predecessor
DTB fails - proves the gate detects the defect the anchor nodes in
`arch/arm64/boot/dts/exynos/c2s-overlay-anchors.dtsi`, generated by
`c2s-rescue/scripts/gen-overlay-anchors.py`, fix; 138 of 225 labels
required by the stock overlays were missing from the base tree).
The fixtures live host-only in `/tmp/opencode/dtbo-fixtures` and are
never committed.

- kernel config: ~35 required `=y` symbols, `CONFIG_MODULES` unset,
  `CONFIG_INITRAMFS_SOURCE` pointing at the staged archive, pinned
  `CONFIG_LOCALVERSION` with `LOCALVERSION_AUTO` off.
- initramfs: cpio listing contains `dev/console` as char 5:1,
  `/init` + busybox + dropbear + rescue config present, `/init`
  parses under busybox ash and dash.
- secrets: the rescue sources and the built archive contain no
  serials and no private key material.
- DTB: framebuffer node, `usb@10e00000`, exynos990 usbdrd-phy
  compatible, full memory coverage up to 0xb00000000, dummy
  regulators present.
- Image: ARM64 magic (`41 52 4d 64` at offset 0x38), no build-host
  paths inside the binary, embedded initramfs byte-identical to the
  standalone archive, release string `7.1.0-rc4-c2s-rescue` without a
  `git describe` suffix.
- static binaries: busybox and dropbear are static aarch64 ELF,
  dropbear has no `NEEDED` entries.
- functional smoke test (same dropbear binary as in the initramfs,
  run on the host via qemu-user/binfmt): public-key login succeeds,
  an unlisted key is rejected, password auth is refused (compiled
  out), telnet gate requires both the config flag and the marker
  file.

## Device interaction bounds honoured

- read-only ADB only; no flashing, no reboot, no writes, no persistent
  config on the phone during this issue.
- no device serial, serial-bearing cmdline, or private key material
  was committed, posted, or stored in any artifact (checked by the
  verify secret scan).

## Issue #4 correction round (coordinator review of candidate `69702078…`)

Host-only evidence for the corrected build (no device access, no flash,
no reboot). The previous candidate is superseded; see
`build-record.md` for the full record.

* Minimal USB baseline: `CONFIG_C2S_DIAG` is not set in the final
  `.config`; the built `Image` contains no `movz` with the diagnostic
  framebuffer immediates 0xf100/0xf980/0xfac0, and `primary_entry`'s
  disassembly has no framebuffer address and no `mov x4, #0xffff`
  prologue. Positive control: the same scan flags the preserved
  diagnostic reference Image. The diagnostic implementation itself is
  kept in the tree and reproducible via
  `arch/arm64/configs/c2s_rescue_diag_defconfig`.
* USB gadget state machine: `/usr/lib/c2s-gadget.sh` (shipped in the
  initramfs) creates and links ACM first (mandatory), then NCM and RNDIS
  independently (optional), then binds the single UDC; a failed full
  bind is retried ACM-only on the same UDC. Host fault injection
  (fake configfs/UDC) ran the shipped file through five controlled
  cases: NCM failure, RNDIS failure, absent UDC, all-success,
  unbindable UDC - 10 checks, 0 failures. The cases prove the fallback
  *sequence*; they cannot prove USB enumeration, ttyGS delivery, netdev
  creation or SSH reachability, because no UDC, cable or host
  controller exists here. The harness prints these limits with its
  results.
* AVB: the current `boot.img` footer is `Algorithm: SHA256_RSA4096`,
  rollback index 13, public key sha1 `fcbc02ced423008be3a706f4e85a7366e9b4db6f`
  (the key that signed the installed vbmeta, recorded earlier in this
  file). `avbtool verify_image --image boot.img --key $C2S_AVB_KEY`
  passes (signature + embedded key). The superseded candidate
  `6970207865d6cbb3…` had `Algorithm: NONE`: structure and hash only,
  unsigned, not compatible with verified boot - it is labelled as such
  and is not a deliverable.
* Verification: `c2s-rescue/scripts/verify.sh` -> 170 passed, 0 failed
  (serial run; the dropbear smoke test binds a fixed host port and must
  not run concurrently).
* Not proven here: that the device boots this image, that the USB
  console or SSH is reachable on hardware, and that the device accepts
  the AVB chain. Those require the coordinator's hardware run.

## Issue #4 SSH-key blocker (candidate `4b823391…` -> candidate `5a0426dc…`)

Coordinator finding: the packaged initramfs of `4b823391…` contained no
`root/.ssh/authorized_keys` ("NOTE: no C2S_AUTHORIZED_KEYS given" in the
build log) and `/init` skips dropbear without it - that artifact could
not provide SSH. Host-only remediation (no device access):

* rebuilt the identical baseline with
  `C2S_AUTHORIZED_KEYS=$HOME/.ssh/id_ed25519.pub` and repackaged with
  `C2S_AVB_KEY`; private keys were never read, printed or committed.
* proof taken from the **exact boot.img** with
  `c2s-rescue/scripts/prove-authorized-keys.sh`: Android boot header
  parsed -> ramdisk slot sliced (offset 11763712, 2,496,684 B) ->
  gzip decompressed -> newc cpio entry read directly:
  `mode=100600` (regular file, 0600), size 97 B,
  content sha256 `153d52616cdce489bf501401c79e12382e66053e85e787fbc925954e0e122c38`,
  OpenSSH fingerprint `SHA256:kX1/T8o7ReIa9OJgX0ADSD03lf/XvAFw5lqbAAUonAE`
  on both sides - identical to the source public key.
* AVB unchanged and re-proven on the new image:
  `Algorithm: SHA256_RSA4096`, `Rollback Index: 13`, public key sha1
  `fcbc02ced423008be3a706f4e85a7366e9b4db6f`, and
  `avbtool verify_image --image boot.img --key $C2S_AVB_KEY` passes.
* unchanged: `CONFIG_C2S_DIAG` off (config + Image instruction scan +
  `primary_entry` disassembly, with positive control), the
  ACM-independent gadget state machine (`/usr/lib/c2s-gadget.sh`),
  DT table and stock DTBO overlay gates (9/9), telnet off, key-only
  dropbear, host fault injection 10/10.
* `verify.sh` -> 174 passed, 0 failed (4 new gates prove the packaged
  key from the image, so a rebuild without `C2S_AUTHORIZED_KEYS` now
  fails verification instead of shipping an SSH-less image).

Not proven (hardware only): boot, USB enumeration, ttyGS console
delivery, dropbear startup, and a successful SSH login with this key.

## Issue #4 DECON refresh trigger (combined candidate `63421d04…`)

Host-only evidence class for the new trigger + marker code, built with
`C2S_DEFCONFIG=c2s_rescue_diag_defconfig` on top of the committed USB
fixes (`8b45338c198d`) and the marker code already in `8c410514`.

### Source evidence (register semantics)

* `DECON0_BASE_ADDR = 0x19050000` (`platform/exynos9830/include/dpu/
  display_sfr.h:40`); c2s targets the exynos9830 platform (`target/c2s/
  rules.mk:4`). The DT of this kernel tree has no `decon` node at that
  address (the driver is out-of-tree in lk3rd), so the base was taken
  from the bootloader's own header, not from a guessed DT value.
* Full refresh sequence source-verified against
  `platform/exynos9830/dpu/decon_core.c:114-134` (`decon_show_buffer_update`)
  + the functions it calls, with the exact offsets/bits listed in
  `diag-milestones.md` and reproduced by the new `c2s_decon_refresh`
  macro in head.S.
* Masked-RMW semantics from `platform/exynos9830/include/dpu/decon.h:476-482`
  (`decon_write_mask`).
* sboot handoff value: `writel(0x3070, 0x19050070)` (`app/exynos_boot/
  boot/cmd_boot.c:730-731`) — decoded as bits 4/5/6 + 12/13 set, bit 0
  clear. Explains the masking, and the trigger's restore step matches.
* Bounded polls chosen (16384 iterations each): the arch timer is
  disabled before `kernel_entry` (`cmd_boot.c:732-734`) so a wall-clock
  timeout cannot be built from `udelay()`; iteration-bounded loops are
  the only usable primitive in that window. They are *not* a proven
  equivalent of the vendor's timing (vendor: 300 ms shadow-update
  timeout, 20 ms run-status poll, `udelay(10)` steps,
  `include/dpu/decon.h:79`): the host cannot measure the boot-time CPU
  frequency or the number of MMIO reads that fit into the vendor's
  deadlines, so no wall-clock equivalence is claimed — the counters are
  an arbitrary upper bound chosen to keep the boot deterministic, and
  a too-small counter can only cause the sequence to fall through
  early.
* Bounded polling bounds the *loop* only. It does not protect against
  an MMIO read from `0x19050000` that hangs the bus or raises an
  external abort (e.g. a TZSASC/secure-access refusal in the
  non-secure world): such an access stops the CPU regardless of any
  counter, and no code in this patch can prevent it.

### M2 MMU/MAIR analysis (source-proven, not measured on hardware)

* `MAIR_EL1_SET` (`arch/arm64/mm/proc.S:74-79`) programs index 4 to
  `MT_DEVICE_nGnRE` (`asm/memory.h:175`); `msr mair_el1` in `__cpu_setup`
  is unconditional (proc.S:539) and happens in `primary_entry` before
  `b __primary_switch` -> `__enable_mmu` -> `__primary_switched`. So at
  M2 the attribute index 4 that `PROT_DEVICE_nGnRE` uses is already
  programmed.
* M2 runs at **EL1**: `init_kernel_el` sets `spsr = INIT_PSTATE_EL1` and
  erets to EL1 in both EL1 and EL2 entry cases (`init_el1` at head.S:533,
  `init_el2` at head.S:544, both erets at head.S:542/588), and
  `finalise_el2` runs *after* the M2 block (head.S:502). Therefore
  `mair_el1` is the register that is in effect at M2 (not `mair_el2`),
  regardless of whether we entered at EL1 or EL2.
* `create_init_idmap()` is called once from head.S:164 into
  `__pi_init_idmap_pg_dir` and stays in TTBR0 through M2 because:
  - `map_kernel()` (early_map_kernel -> map_kernel) only installs
    TTBR1 (`idmap_cpu_replace_ttbr1`);
  - `remap_idmap_for_lpa2()` (the only TTBR0 swapper in `early_map_kernel`)
    fires only when `va_bits > VA_BITS_MIN`, i.e. only when
    `cpu_has_lpa2()` (cpufeature.h:1063-1075, reading
    `ID_AA64MMFR0_EL1.TGRAN_*`) reports support. The Exynos990 cores are
    Cortex-A76 + Cortex-A55 (`arm,cortex-a76`/`arm,cortex-a55`,
    exynos990.dtsi:74-109) — Armv8.2-A parts; FEAT_LPA2 arrived in
    Armv8.7-A, so these cores do not implement it and the host expects
    the branch to be skipped. The host cannot measure the ID-register
    read, so this is recorded as an *architectural* expectation, not a
    host observation. If the branch were taken, the
    `init_pg_dir` pool (sized by `INIT_DIR_SIZE`, which does not
    include the diag extras) would be at risk; the same code then calls
    `create_init_idmap` a second time (map_kernel.c:190), so the C2S
    entries including DECON would still be present in the rebuilt ID
    map that ends up in TTBR0.
* The DECON entry uses `dev_prot = __pgprot(PROT_DEVICE_nGnRE) &
  ~clrmask` (`clrmask = PTE_SHARED` from both callers). `PTE_WRITE`
  (bit 51) is distinct from `PTE_SHARED` (bits 8/9), so the mapping
  keeps the M2 writes permitted.
* Page-table budget: measured against a faithful model of the real
  `map_range()` recursion at this config's geometry (level spans
  39/30/21/12 bits, root level 0) - the three FB ranges cost 4 tables,
  the DECON page costs 2, total 6 on top of the kernel-image mapping
  (which the reserve already covers). `EARLY_IDMAP_DIAG_EXTRA_PAGES = 32`
  is unchanged and comfortably above that.

### Image/verify evidence

* `verify.sh /tmp/opencode/c2s-diag3-out`: **173 passed, 0 failed** on
  the combined candidate, including a new **instruction-level** DECON
  gate that requires `movz xN, #0x1905, lsl #16` in `>= 2` places
  (observed count: 3 — the M1 and M2 call sites plus the `map_range`
  device-map constant). The gate counts occurrences globally and
  cannot localise them; the per-call-site evidence is the disassembly
  below.
* `verify.sh /tmp/opencode/c2s-diag3-base-out`: **173 passed, 0 failed**
  on the paired baseline; the new gate is mode-aware and reports
  `count=0` there.
* Disassembly of `/tmp/opencode/c2s-diag3-out/kbuild/vmlinux`:
  `primary_entry` block at `ffff8000806cc158` contains
  `ldr w5, [x4, #96]` / `orr w5, w5, #0x3f` / `str w5, [x4, #96]`
  (all-win shadow update request), `orr w5, w5, #0x3` on `[x4]`
  (direct on, mask 0x3 — note that this ORR writes bit 28 back with the
  value the preceding read returned; it does not force bit 28 to 0,
  see the SRESET note above), `orr w5, w5, #0x80000000` on `[x4, #96]`
  (global update request), `tbnz w5, #4` (RUN_STATUS poll),
  `[x4, #112]` `and w5, w5, #0xffffffef` + `orr w5, w5, #0x1`
  (enable: clear `HW_TRIG_MASK_DECON`, set `HW_TRIG_EN`), `cbz w5` on
  `[x4, #96]` (update-done poll), and the inverse pair for the disable
  (restore `HW_TRIG_MASK_DECON`, clear `HW_TRIG_EN`). The same block
  repeats in `__primary_switched` at `ffff8000806e85a4` — this
  address-by-address disassembly is what proves the trigger is present
  in **both individual call sites**. `map_range.o` carries the
  `0x19050000` constant for the device mapping.
* `GLOBAL_CONTROL` bit 28 (SRESET): the vendor's own
  `decon_reg_direct_on_off()` (`cal/decon_reg.c:61-67`) uses the same
  mask `0x3` and therefore also writes bit 28 back as read; vendor
  `decon_reg_reset()` (`cal/decon_reg.c:30-46`) writes bit 28 as 1 on
  purpose (line 33) and polls for self-clear (lines 34-38). Our macro
  matches the vendor's masked-RMW semantics, but the value of bit 28 at
  the time we run is **not verified** by this patch — it is expected to
  be 0 because vendor's reset waits for the self-clear before handing
  over, but that is an assumption about the running bootloader, not a
  host-measured fact.

### Not proven (hardware only)

* Panel visibility of the M1/M2 bands, or of the intermediate state
  during the trigger. That requires a hardware run with a photo.
* Whether the DECON SFRs still accept writes from EL1 at this point
  (TZSASC / ARM SMMU for display, DECON secure-access-control). sboot
  reaches them from EL3/EL1 as part of the video path; the kernel's
  non-secure world may or may not. The bounded polls prevent a hang
  either way.
* Whether sboot's 0x3070 mask on bits 4/5/6/12/13 is still in effect
  at M2 or was cleared/rewritten by the display powerdown that lk3rd
  runs before jumping to the kernel. This is a hardware question;
  the trigger's design is safe under either assumption (every write
  is masked and idempotent for the state we care about).
* That the trigger is *effective*: only "did the band actually appear
  on the panel" counts as proof. A blank panel after this candidate
  narrows but does not close the space of causes.

## Issue #5: M1b control-flow fix and passwordless sudo (candidate `13cdc38c…`)

### The M1b defect, proved from the disassembly

Candidate 4 (`852e868d…`) placed the M1b green band between the `0:`
and `1:` labels of `primary_entry`. The MMU-off entry path - the one
this device takes, because the bootloader disables the MMU before
jumping to the kernel - executes `b 1f` and therefore jumped over the
whole block. The green band was compiled in, solid, and **unreachable
on the device's own path**.

Two independent pieces of evidence:

* **Reachability.** `c2s-rescue/scripts/check-marker-reachability.py`
  builds a CFG from the disassembly of `primary_entry`, splits it at
  the `cbnz x19` MMU-state branch and requires each marker to be
  reachable on both sides. On the pre-fix vmlinux it reports
  `FAIL: marker M1b-green @ 0xffff8000806cc224 NOT reachable on the
  MMU-off (cache-off) entry path - the path this device takes`
  (M1-white passes on both sides). On the fixed build both markers
  reach on both paths.
* **Negative control.** The pre-fix objdump listing is committed as a
  fixture and the checker must reject it
  (`--expect-unreachable`). If that input ever reported PASS the gate
  would be insensitive and the regression unguarded.

The fix moves label `1:` to immediately after the `0:` block's
`blr x2`, before the M1b block. Label numbering was checked first:
within `primary_entry` the only numeric label references are
`cbnz x19, 0f` and `b 1f`, and there is no `1b` anywhere in
`head.S`, so no other reference can be retargeted. The other `1:`/`2:`
labels live in `record_mmu_state`, `init_kernel_el` and later
functions, which the move does not touch.

### Passwordless sudo, proved on the host

The image must let the SSH login user run `sudo -n id` without a
password. The implementation uses sudo-rs 0.2.15 from the
postmarketOS aarch64 package set, plus musl, libpam, libgcc_s and
`pam_permit.so`.

* **Native proof of the elevation path** (x86_64 host, the host's own
  sudo-rs 0.2.13, setuid): with the *exact* candidate `/etc/sudoers`
  + `/etc/sudoers.d/90-rescue` + `/etc/pam.d/sudo` bind-mounted over
  the host's, and the caller dropped to a non-root uid,
  `sudo -n id` returned `uid=0(root) gid=0(root) groups=0(root)`
  (RC=0). Root was correctly refused at that point
  ("sudo: I'm sorry root. I'm afraid I can't do that") because it had
  no rule. The host's `/etc/sudoers` was restored afterwards and
  `sudo -n id` re-verified working.
* **Proof of the shipped configuration** (aarch64 sudo-rs under
  qemu, in a root-owned chroot of the packed rootfs):
  `sudo -n -l -U rescue` prints
  `User rescue may run the following commands on <host>:
      (ALL : ALL) NOPASSWD: ALL`, and `sudo -n id` prints
  `uid=0(root) gid=0(root) groups=0(root)`.
* **Negative control**: with the setuid bit cleared and the command run
  as an unprivileged account inside the same chroot, sudo-rs refuses
  with `sudo: sudo must be owned by uid 0 and have the setuid bit
  set`. This control must run as a non-root caller - sudo-rs only
  enforces the check then - while `chroot()` needs `CAP_SYS_CHROOT`,
  so the tree is entered by root and the command is then run via
  `sudo -u`.

The load-bearing implementation facts, all from the source:

* sudo-rs refuses to load a sudo binary that is not owned by uid 0
  **with** the setuid bit; the archive entry is `104755 0 0`.
* sudo-rs refuses a sudoers file that is not root-owned mode 0440;
  both `/etc/sudoers` and `/etc/sudoers.d/90-rescue` are `100440 0 0`.
* sudo-rs refuses an inactive `@includedir`; the shipped
  `/etc/sudoers` has an active `@includedir /etc/sudoers.d`.
* sudo-rs aborts with a PAM error when `/etc/pam.d/sudo` is missing;
  the image ships one with `pam_permit` on all four stacks.
* sudo-rs rejects `Defaults !authenticate` as an unknown setting; the
  shipped file does not contain it.
* dropbear opens `authorized_keys` with `seteuid()` to the
  authenticating user (`svr-authpubkey.c`), so a root-owned 0600 file
  is unreadable for a uid 1000 login. dropbear is therefore started
  **without** `-D` so each account resolves its own
  `~/.ssh/authorized_keys`, and `/home/rescue` is owned by uid 1000 so
  dropbear's `checkpubkeyperms()` path walk accepts it.
* `sudo -n id` needs `id` on sudo-rs's `secure_path`
  (`/usr/bin:/bin:/usr/sbin:/sbin`); busybox's `id` applet was not
  linked into the image and was added.

### Not proven (device only)

* That `sudo -n id` elevates on the device. qemu-user does not
  emulate setuid elevation, so the non-root elevation path is proven
  natively on the host and must be confirmed on the device.
* That the panel shows any of the five bands, that the USB gadget
  enumerates, and that a key-only SSH login succeeds. These are the
  issue #5 done-when conditions and need the coordinator's hardware
  run.

### S2MPS19 PMIC Chip-ID Register Offset Verification (Issue #19)

* **Question**: Is register offset `0x00` (`S2MPS19_REG_PMICID`) used by the ACPM selftest driver (`drivers/firmware/samsung/exynos990-pmic-probe.c`) correct?
* **Source Evidence (z3s Reference)**:
  - `docs/session-findings/SESSION3_FINDINGS.md` §3.6 ("Go/no-go smoke test, READ ONLY FIRST"):
    Documents the read-only ACPM smoke test on physical Exynos 990 hardware:
    ```
    API: handle->ops->pmic.read_reg(handle, acpm_chan_id, type, reg, chan, &val)
    ACPMTEST: OK chipid=0x00
    ACPMTEST: LDO2(vqmmc)=0x00 LDO15(vmmc)=0x2e (en=bits7:6, 0xC0=on)
    ```
    Later on lines 278-281:
    ```
    ACPMTEST: OK chipid=0x03
    ACPMTEST: enable vmmc ret=0
    ACPMTEST: enable vqmmc ret=0
    ACPMTEST: AFTER LDO2(vqmmc)=0xee LDO15(vmmc)=0xee
    ```
  - Reference implementation in `z3s-mainline-linux/kernel/drivers/acpm-pmic/exynos990-pmic-probe.c`:
    Line 21: `#define S2MPS19_REG_PMICID 0x00`
  - Samsung PMIC register architecture across all Samsung S2M family PMIC drivers (e.g. `s2mps11`, `s2mps13`, `s2mps14`, `s2mps15`, `s2mps18`, `s2mps19`) places the PMIC ID / revision register at offset `0x00`.
* **Conclusion**:
  Offset `0x00` is exact, verified on hardware, and confirmed across both Samsung PMIC register maps and z3s devlog/session records. No change to the offset value is required; documented with full attribution.
