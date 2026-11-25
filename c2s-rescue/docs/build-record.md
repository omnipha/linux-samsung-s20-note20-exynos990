# c2s rescue: build record (issue #1)

This file documents how the artifacts of issue #1 were produced and
how to reproduce them. The authoritative, machine-generated record is
`$OUTDIR/build-record.txt` and `$OUTDIR/build.log` (both written by
`c2s-rescue/scripts/build.sh`).

## Source

| Item | Value |
|---|---|
| repository | `omnipha/linux-samsung-s20-note20-exynos990` |
| branch | `feature/issue-1-c2s-minimal-kernel-rescue` |
| base commit | `13e4b531bcc17f85f3de3b75da1cc16569a0f2a4` |
| base commit date | 2026-11-13T22:26:19+01:00 |
| change | last `memory@80000000` block of `exynos990-c2s.dts` |

## Environment

| Item | Value |
|---|---|
| host kernel | Linux 7.0.0-42-generic x86_64 |
| cross compiler | aarch64-linux-gnu-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| make | GNU Make 4.4.1 |
| gzip | gzip 1.14 |
| cpio | cpio (GNU cpio) 2.15 |
| dtc | Version: DTC 1.7.2 |
| parallel jobs | 8 |
| output directory | `/tmp/opencode/c2s-out` (outside the repository) |

## External dependencies (not part of this repository)

`build.sh` verifies these before use and refuses to continue on a
mismatch:

| File | sha256 |
|---|---|
| `/home/gregor/sm7635-build/dropbear-2026.94.tar.bz2` | `e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81` |
| `/home/gregor/sm7635-build/busybox-static_1.37.0-7ubuntu1_arm64.deb` | `fcf50794faf920455895d7ef103d1c54b9ebf7f18d2e52982dbf3903b7769592` |

Derived binaries (recorded in `build.log`):

| Binary | sha256 | Size |
|---|---|---|
| busybox (extracted from the .deb) | `c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02` | - |
| dropbear (cross-built, static) | `2fbd5988bd77e138acf6e0588943924bcd866585befb19204e45fb33a7ccfe9b` | 1,487,336 B |
| dropbearkey (cross-built, static) | `17f4e9a03f2d48cabd26358feabe11ed8d35f930f01ce11e8956c6df3f0378c6` | 1,248,200 B |

## Commands executed by `build.sh`

1. `sha256sum` check of both external inputs.
2. `dpkg-deb -x` for busybox; curated applet symlinks are created in
   the staged rootfs.
3. Dropbear cross build:
   `./configure --host=aarch64-linux-gnu --prefix=/usr --enable-static
   --disable-zlib --disable-utmp` with
   `c2s-rescue/dropbear/localoptions.h` copied over the stock
   `localoptions.h`, then `make PROGRAMS="dropbear dropbearkey"`.
   The `crypt() not available` warning from configure is expected
   (password auth is compiled out on purpose).
4. Initramfs: `usr/gen_init_cpio` is built standalone, and
   `usr/gen_initramfs.sh` is run from a scratch directory that contains
   it (`usr/gen_initramfs.sh` invokes `usr/gen_init_cpio` by relative
   path), with an explicit cpio list that names every file, mode and
   owner. `-d @<SOURCE_DATE_EPOCH>` pins all mtimes; the result is
   gzipped with `gzip -9 -n`.
5. Kernel: `make c2s_rescue_defconfig`, then `scripts/config
   --set-str INITRAMFS_SOURCE initramfs.cpio.gz` (relative path),
   then `make olddefconfig`, `make Image`, `make dtbs`.

## Reproducibility measures

| Knob | Value | Reason |
|---|---|---|
| `SOURCE_DATE_EPOCH` | 1794605179 (timestamp of commit 13e4b531bcc1, not HEAD) | pins cpio mtimes and `UTS_VERSION` |
| `KBUILD_BUILD_TIMESTAMP` | same value | pins the build date in `UTS_VERSION` |
| `KBUILD_BUILD_VERSION` | 1 | pins the `#N` build counter |
| `KBUILD_BUILD_USER` / `_HOST` | `c2s-rescue` | pins `LINUX_COMPILE_BY@HOST` |
| `CONFIG_LOCALVERSION` | `-c2s-rescue`, `LOCALVERSION_AUTO` off | pins the release string so the Image does not change per commit (no `git describe` suffix) |
| `CONFIG_INITRAMFS_SOURCE` | `initramfs.cpio.gz` (relative) | the whole `.config` is embedded via IKCONFIG; an absolute path would leak the build directory into the `Image` |

Result: two consecutive full builds produced byte-identical artifacts.

## Artifacts (sha256)

Issue #1 state (historical; the DTB has since gained `/__symbols__`,
see "The `/__symbols__` requirement" below):

| Artifact | Size | sha256 |
|---|---|---|
| `Image` | 11,432,448 B | `dd6785a0a73841ca37ce7b623f2e782df5f3a6cb2e2a927c231ceea1b5f27f97` |
| `exynos990-c2s.dtb` | 38,288 B | `4e4e5702ce715ff4d8c0bc066a0c8d66a039473fdea49c423bc4d4cc8ad79b0f` |
| `initramfs.cpio.gz` | 2,211,972 B | `c84d00ec2981bc47b649a212d6d47c8d26ed13f0e082e24536fdc87fd8f581ff` |
| `initramfs.cpio` (uncompressed) | | `df3e43d6fff5b0fc337a82704e7290c574b9c9fb225dc1a68e0500c24d5611fb` |

## Initramfs layout

```
/init                              (PID 1, busybox ash)
/bin/busybox                       (static aarch64)
/bin/sh -> /bin/busybox
/sbin/init -> /init
/usr/sbin/dropbear                 (static aarch64, pubkey only)
/usr/bin/dropbearkey
/usr/bin/rescue-telnet             (telnet arm/disarm helper)
/etc/passwd  /etc/group  /etc/shells  /etc/issue  /etc/rescue.conf
/root/.ssh/                        (0700; authorized_keys only if C2S_AUTHORIZED_KEYS is given)
/dev/console                       (char 5:1 - required, the kernel opens it before /init runs)
```

`/etc/passwd` and `/etc/group` are shipped with mode 0600, `/etc/shadow`
deliberately not shipped at all.

## Verification

`c2s-rescue/scripts/verify.sh` - 140 checks, all passing (issue #4
state; the issue #1 record had 79 checks):

| Group | Checks |
|---|---|
| artifacts | Image, DTB, initramfs, build-record.txt, build.log exist and are non-empty |
| kernel config | ~35 required `=y` symbols, `CMDLINE_FORCE=y`, `MODULES` unset, pinned `LOCALVERSION`, `LOCALVERSION_AUTO` unset, `INITRAMFS_SOURCE` resolves to the staged archive, staged copy identical, embedded copy identical |
| console font (issue #4) | `FONTS`/`FONT_8x16`/`FONT_TER16x32` `=y`, `fbcon=font:TER16x32` in `CONFIG_CMDLINE`, in the Image's embedded cmdline and in the Image strings (the font itself compiled in) |
| image hygiene | no build-host path inside the `Image`, release string pinned without `git describe` suffix |
| initramfs | cpio listing has `dev/console` as char 5:1, `/init` executable, busybox/dropbear present, passwd/shells/rescue.conf content, `/init` parses under busybox ash and dash |
| applet symlinks (issue #4) | every applet `/init` calls is a shipped `/bin/<applet> -> /bin/busybox` symlink; the shipped busybox executes the applets under qemu-aarch64 |
| boot menu logic (issue #4) | `RESCUE_ENABLE_TELNET="0"` default, telnetd invoked exactly once, gated by marker AND config flag |
| boot menu selection (issue #4) | the shipped `rescue-menu-keys` binary is exercised under qemu-user against representative streams: press 114 -> telnet, release/autorepeat/EV_SYN/foreign keys never select, 115/116 -> rescue, timeout -> rescue (stdout exactly one line), serial lines (`telnet`/`rescue`/Enter/garbage) incl. the drain window that discards echoed menu text, fifo streams with delayed events (nothing lost), gpio-keys discovered via a fake sysfs tree at `event7` while a hostile same-named `event0` without key caps is ignored, missing sysfs -> rescue |
| packaged boot.img (issue #4) | dt slot parsed at the sboot offset: Samsung DT table magic `0xd7b7ab1e`, header/entry layout, FDT byte-equal to the kbuild DTB, `__symbols__` present (sboot libufdt overlay requirement - the missing node is what stopped the previous candidate); avbtool verifies the footer |
| stock DTBO overlay (issue #4) | `fdtoverlay` merges all 9 stock `dtbo.img` entries into the built DTB (positive control: stock base accepts all 9; negative control: the anchorless predecessor fails - the gate detects the defect the anchor nodes fix) |
| secret scan | no serial/private-key patterns in tracked rescue sources or in the archive |
| DTB | framebuffer node, `usb@10e00000`, exynos990 usbdrd-phy compatible, memory up to 0xb00000000, dummy regulators |
| kernel image | ARM64 magic `41 52 4d 64` at offset 0x38, `file(1)` agrees |
| static binaries | busybox, dropbear and `rescue-menu-keys` are static aarch64 ELF, dropbear has no `NEEDED` |
| smoke test | dropbear starts, pubkey login works, unlisted key rejected, password auth refused, telnet gate enforced |

The smoke test runs the exact dropbear binary that is shipped, on the
build host, via qemu-user/binfmt. It uses passwordless sudo when
available (login user `root`, device-faithful) and otherwise falls back
to the invoking user; both paths exercise the same authentication
code.

## Boot image packaging (issue #4): the Samsung DT table

`c2s-rescue/scripts/package-bootimg.sh` wraps `build.sh`'s artifacts
into a flashable Android boot image v2 (page 2048, header v2,
kernel 0x10008000, ramdisk 0x11000000, `SRPTB27C018RU`, os 11.0.0 /
patch 2025-08, AVB hash footer SHA256_RSA4096 rollback 13) and adds the
AVB footer with the host key that signed the installed vbmeta
(`C2S_AVB_KEY`, never part of this repository).

**The dt slot must contain a Samsung DT table, not a bare FDT.** sboot
computes the dt offset of the boot image as

```
payload_base + align_down(kernel_size-1, 0x800)
             + align_down(ramdisk_size-1, 0x800) + 0x1000
  == page_size + align_up(kernel_size, page) + align_up(ramdisk_size, page)
```

(that is exactly where `mkbootimg` places the `--dtb` payload; verified
independently for the stock `boot.img`, TWRP `recovery.img` and this
image - the magic lands at 40280064 / 55115776 / 14258176
respectively), then checks the 64-byte header at that offset for magic
`0xd7b7ab1e`. A bare FDT (`0xd00dfeed`) fails that check with
`[DTH] dt table header check Fail: FDT_ERR_BADMAGIC`, which is what the
first flashable candidate triggered on the device.

Template (byte-for-byte what the installed stock boot.img carries at
40280064, big-endian):

```
offset  field                     stock boot.img   our image
0x00    magic                     0xd7b7ab1e       0xd7b7ab1e
0x04    total_size (hdr+ent+fdt)  0x000533d8       0xff1f   (0x40 + 65247)
0x08    header_size               0x20             0x20
0x0c    entry_size                0x20             0x20
0x10    dt_entry_count            1                1
0x14    dt_entries_offset         0x20             0x20
0x18    page_size                 0x800            0x800
0x1c    version                   0                0
0x20    [entry] dt_size           0x00053398       0xfedf
0x24    [entry] dt_offset         0x40             0x40
0x28    [entry] device id         0                0
0x2c    [entry] rev               0                0
0x30    [entry] custom[0..3]      0 / 0xff / 0 / 0  0 / 0xff / 0 / 0
0x40    FDT (0xd00dfeed ...)      ...              exynos990-c2s.dtb verbatim
```

The single entry with `custom = [0, 0xff, 0, 0]` matches every board
id (`f9164` entry selection accepts rev 0..255), same as stock. The
inner FDT is our `exynos990-c2s.dtb` byte-for-byte - a full device
tree, which is what the stock boot.img entry is as well (no
`fragment@`/`__overlay__` nodes), so no overlay is constructed.

### The `/__symbols__` requirement (measured on the device)

The first flashable candidate (`b8140be7…`) got past the DT table -
sboot accepted the `0xd7b7ab1e` wrapper - but stopped with

```
No node __symbols__ in main dtb. failed to perform fixups in overlay
[UFDT] DT Overlay FAIL.
```

and the device came back in Download mode ("ODIN MODE (DT Load Fail)").
sboot applies a DTBO overlay to the main DTB with libufdt
(`f9714` -> `ufdt_overlay_apply`, `0x125a24`); libufdt needs the *base*
DTB to carry a `/__symbols__` node so it can resolve the overlay's
`/__fixups__` references. Measured on the host:

| DTB | `/__symbols__` | `/__fixups__` |
|---|---|---|
| stock `boot.img` dt slot (boots) | 1 | 0 |
| our dt slot before the fix | 0 | 0 |
| our dt slot now | 1 | 0 |
| vendor `dtbo.img` (the overlay) | 9 | 9 (+9 `__local_fixups__`) |

The base DTB therefore carries `__symbols__` and no `__fixups__`, the
overlay carries both - the same split as the vendor images.

Fix: `DTC_FLAGS_exynos990-c2s := -@` in
`arch/arm64/boot/dts/exynos/Makefile`. `dtc -@` is what generates
`/__symbols__` (and `/__fixups__` where a node is referenced by
label); it is the same flag upstream uses for every base DTB that
overlays are applied to (`scripts/Makefile.dtbs`: "Set -@ if the target
is a base DTB that overlay is applied onto"), and the same flag the
vendor DTBs are built with. It is applied to the c2s DTB only - no
other board and no other DT logic is touched.

Verified: the DTB built without `-@` is still 38,288 B /
`4e4e5702…` (unchanged), the DTB with `-@` is 65,247 B /
`6592f9b8…`, and the decompiled trees are identical apart from the
`__symbols__` node and the phandles `-@` adds.

`package-bootimg.sh` verifies this twice: on `dt-table.bin` before
`mkbootimg`, and again by parsing the *finished* image at the sboot
offset (magic/total/header/entry/custom + FDT byte-equality with the
kbuild DTB + presence of `__symbols__`). `verify.sh` repeats the
finished-image parse independently.

Residual (hardware-only) risks: whether sboot's DTBO overlay then
applies cleanly to *our* tree (the overlay fragments target vendor
nodes; sboot merges what it can), and the rendering of the `TER16x32`
font on the real 1440x3088 framebuffer.

### Overlay anchor nodes (fix for candidate `840cfeb2…`)

`840cfeb2…` (the `__symbols__`-carrying candidate) still aborted on the
device with `DTB LOAD FAIL / FDT_ERR_BADMAGIC` - never reproduced
locally; the image is not on the build host anymore, so the root cause
of *that* error string is not confirmed here. Independently of it, the
DTB it was built from had a proven second defect: having `/__symbols__`
is necessary but
not sufficient. sboot merges the *stock* `dtbo.img` entry for this
board's hw_rev onto our FDT before every boot, and each overlay's
`/__fixups__` resolves phandle references through *paths* named in the
base `/__symbols__`. Measured on the host against all 9 stock entries:
the base needs 225 distinct labels; our tree (339 symbols) provided
only 87 - 138 were missing (abox 39, usi 23, hsi2c 18, spi 8, mcdhdr 6,
pinctrl 5, uart 3, pcie 2, ...), so libufdt hit an unresolvable fixup.

Fix: `arch/arm64/boot/dts/exynos/c2s-overlay-anchors.dtsi`, generated
by `c2s-rescue/scripts/gen-overlay-anchors.py` (uses the in-tree
`c2s-rescue/scripts/fdt.py` parser) from the host-only fixtures in
`/tmp/opencode/dtbo-fixtures` (stock base + 9 stock entries + the
previous anchorless DTB). For every missing label it emits a disabled
shell node at the stock path carrying the stock label; properties whose
phandle targets lie outside the subtree are dropped, intra-subtree
references are renumbered (0x10001+), and `status = "disabled"` keeps
mainline drivers from binding to the shells. The generator output is
byte-reproducible; `exynos990-c2s.dts` includes the dtsi. The DTB grows
65,247 B -> 141,756 B (`db2030c0…`); `/__symbols__` 339 -> 477.

Verified host-side (`verify.sh`, "stock DTBO overlay compatibility"):
`fdtoverlay` merges each of the 9 stock entries into the built DTB
without error (positive control: the stock base accepts all 9;
negative control: the anchorless DTB fails, i.e. the gate can detect
the old defect). All 140 checks pass.

Still hardware-only: which of the 9 entries sboot actually selects for
this board's hw_rev (entry 8, `samsung,C2S EUR OPENX 24`, rev
0x18..0xff, is the likely one) and whether the disabled anchor shells
cause any late probe issue once sboot flips them to `okay` (the overlay
enables ~73 of them; most carry vendor compatibles no mainline driver
matches, and clock/reset references were dropped so the rest fail to
probe harmlessly).

### Current candidate (issue #4)

| Artifact | Size | sha256 |
|---|---|---|
| `boot.img` (partition-sized, AVB footer) | 61,865,984 B | `37c28a8b1328875ab9685abdb47c383ea705aed9298c47aa0c735b91eb3cc2e0` |
| `Image` | 11,760,128 B | `7a2b856853c9086cec5256ab76f14a84470d46720d10aa88ddabd80831565598` |
| `exynos990-c2s.dtb` | 141,740 B | `6afe6322273ffed7207eb14235d2ad7d9c4de2ba63f86bf8f97fc75ffcc799f6` |
| `initramfs.cpio.gz` | 2,492,606 B | `abda4c98cf900f91c24683757e061f22795664fd2324a158430719eb924eb3e3` |
| `dt-table.bin` | 141,804 B | `b2f1729cf311090468e2acb3098904dcaa5ebcefe324dfd9346c176c9911f46a` |

at `/tmp/opencode/c2s-out/boot.img` (outside the repository).
avbtool: `SHA256_RSA4096`, rollback index 13, flags 0, partition name
`boot`, hash descriptor image size 14,401,536 B. Packed DT table at
+14,258,176 (lk3rd's/sboot's dt-slot offset for this payload
geometry), `0x229ec` bytes, single entry `custom = [0, 0xff, 0, 0]`,
inner FDT byte-equal to the kbuild DTB. Image header: `ANDROID!`,
header version 2, pagesize 2048, base `0x10000000`, kernel offset
`0x8000`, ramdisk offset `0x01000000`, tags offset `0x00000100`,
dtb offset 0, board `SRPTB27C018RU`, os `11.0.0` / patch `2025-08`.
Boot cmdline in the image header (superseded at boot by
`CONFIG_CMDLINE_FORCE`): `androidboot.hardware=exynos990
androidboot.selinux=permissive loop.max_part=7`; the kernel forces
`console=tty0 loglevel=7 ignore_loglevel fbcon=font:TER16x32`.

This DTB revision carries the root cell format change to the stock
2/1 (`#address-cells = <2>`, `#size-cells = <1>`) — see
`evidence.md`, "lk3rd RAM-boot failure root cause" — and therefore
differs from the previous candidate (`db2030c0…`, 141,756 B).

The `Image`, `exynos990-c2s.dtb` and `initramfs.cpio.gz` are
byte-identical across rebuilds. The `boot.img` digest is not: avbtool
generates a random salt per `add_hash_footer` run, so only the vbmeta
block (606 bytes at offset 14,401,792) differs between two packagings
of the same artifacts - the image content itself (bytes 0..14,401,535)
is identical. The sha256 above identifies *one* packaged candidate;
compare the content, not the digest, when checking reproducibility.
The salt-independent content digest of the current candidate is
`2d9060133c574a6e33dcc6d70b3ba63fcf6ce5c0f7b460baf626480bacef26f9`
(sha256 of bytes 0..14,401,535).

Previous candidates (superseded):
`3aadb74c03f795028f3812898727af5e841d41d6901d1f0aebca46d1881ddff0`
(141,756 B DTB, root cells 2/2 — every root-level `reg` failed the
kernel's stride test under lk3rd's 3-cell memory surgery),
`33e23ccfd82a2ff7315aab72a48746710aa1ada78532b60dc2dd609561bf6ca1`
(65,247 B DTB: DT table + `__symbols__`, but no overlay anchors),
`b8140be72b1102d818d28ff2f6b800a0ac1f4d01623f23fd4089c828f1543f78`
(no `__symbols__`).

## Reproduce

```sh
git checkout feature/issue-1-c2s-minimal-kernel-rescue
./c2s-rescue/scripts/build.sh --outdir /tmp/opencode/c2s-out
./c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-out
# boot image (issue #4): needs the host AVB key via C2S_AVB_KEY
C2S_AVB_KEY=/path/to/avb_key.pem \
  ./c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-out
```

## Issue #4 diagnostic candidate (M1)

Frozen step plan executed: `CONFIG_C2S_DIAG` (arch/arm64/Kconfig, enabled
only in `c2s_rescue_defconfig`) gates the M1 marker block as the very
first instructions of `primary_entry` in `arch/arm64/kernel/head.S`
(register-only, physical stores into the three framebuffers with the MMU
off). Milestones, assumptions, artifacts and the host evidence are
documented in `c2s-rescue/docs/diag-milestones.md`; the diag boot.img is
`/tmp/opencode/c2s-diag-out/boot.img`
(sha256 `6e01d76279143295154c907758af8960d3388d0a5ee9f3c2fd94215b6ebfa737`).
The reference build `/tmp/opencode/c2s-out` (boot.img `37c28a8b…`) is
byte-unchanged: the diag build went into a separate outdir, and the diag
DTB sha256 equals the reference DTB sha256 (`6afe6322…`), proving the
device-tree is untouched. Hardware readout (panel photo after
`fastboot boot`) remains blocked by the device coordinator lock.

## Issue #4: USB-C rescue channel (ACM/ttyGS console)

The rescue image now carries an **independent USB serial console** in
addition to the gadget network interfaces, so that kernel and init
messages are readable over the USB cable before (and completely without)
the network path and without any display being attached.

### What changed

| Item | Change |
|---|---|
| `arch/arm64/configs/c2s_rescue_defconfig` | `CONFIG_U_SERIAL_CONSOLE=y`; `CONFIG_CMDLINE` = `console=ttyGS0 loglevel=7 ignore_loglevel fbcon=font:TER16x32 console=tty0 printk.devkmsg=on` |
| `c2s-rescue/initramfs/init` | ACM function instance created **first**; `log()` writes through `/dev/kmsg` |
| `c2s-rescue/scripts/verify.sh` | 11 new gates (USB serial console: config + Image + init ordering) |

### Why this order and these details

* `console=ttyGS0` is the **first** console= token, `console=tty0` the
  **last** one. The last `console=` token is the preferred console
  (`preferred_console` in `__add_preferred_console()`,
  `kernel/printk/printk.c`), i.e. what a later open of `/dev/console`
  resolves to: the framebuffer behaviour (and the `fbcon=font:TER16x32`
  gate) is unchanged. `ttyGS0` is nevertheless *enabled* as well, and
  every enabled console prints every `printk` message - so the USB line
  receives the whole log.
* `CONFIG_U_SERIAL_CONSOLE=y` is what makes the console exist at all:
  `gs_console_init()` (`drivers/usb/gadget/function/u_serial.c`)
  `register_console()`s `ttyGS` with `CON_PRINTBUFFER`, so the ring
  buffer is replayed into the USB line when the console appears.
* The console is registered when the ACM function instance is created
  (`acm_alloc_instance()` -> `gserial_alloc_line()` -> `gs_console_init()`
  for line 0), therefore `/init` creates `acm.usb2` **before** NCM/RNDIS.
  NCM/RNDIS do not allocate gserial lines, so ACM is always `ttyGS0`.
  `gserial_alloc_line()` only inits the console for **port 0**; the
  explicit `echo 1 > .../acm.usb2/console` is the idempotent explicit
  form of the same thing and is guarded (`2>/dev/null || true`) because
  the configfs attribute only exists with `CONFIG_U_SERIAL_CONSOLE`.
* `printk.devkmsg=on`: `devkmsg_write()` (`kernel/printk/printk.c`)
  ratelimits writes to `/dev/kmsg` unless this is set, and init lines
  would be dropped silently.
* init writes through `/dev/kmsg` instead of writing to `/dev/ttyGS0`
  directly: the USB serial *console* drops what does not fit into its
  8 KiB buffer (counted as `missed` bytes in `u_serial.c`) instead of
  blocking, while a plain write to the tty blocks once the 8 KiB TX
  buffer is full and the host does not read. A blocked PID 1 would take
  down the whole rescue channel (dropbear, menu, supervision). The
  `/dev/kmsg` route keeps the line in the ring buffer as well, so
  `dmesg` over SSH returns the complete boot log.

### Artifacts (build host, `/tmp/opencode/c2s-out`)

| Artifact | Size | sha256 |
|---|---|---|
| `Image` | 11,891,200 B | `391777429f6f7a406eb71bdbe9c87c2097b21985625344acc417532876d70af4` |
| `exynos990-c2s.dtb` | 141,740 B | `6afe6322273ffed7207eb14235d2ad7d9c4de2ba63f86bf8f97fc75ffcc799f6` |
| `initramfs.cpio.gz` | 2,493,164 B | `86206c81ff433ee2176df77c68f1ccc25e18b534511e3eaf02fd78db6cfb8bb1` |
| `boot.img` | 61,865,984 B | `6970207865d6cbb3295521bb63a2e45ff39560931d3481f7b62f4fc15c1cdd3d` |

The DTB is byte-identical to the previous candidate (`6afe6322…`): the
device tree was not touched by this change.

### Verification

`c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-out` -> **150 passed,
0 failed** (139 before, +11 new gates). Covered by the new gates:
`CONFIG_U_SERIAL_CONSOLE=y`, `console=ttyGS0` in the built config and
in the embedded Image command line, `console=tty0` as the last console=
token, `printk.devkmsg=on`, the `ttyGS` driver name in the Image, ACM
created before NCM/RNDIS in `/init`, the non-fatal console attribute
write, `log()` writing through `/dev/kmsg`, and the unchanged
key-only dropbear path. The pre-existing gates (boot-image DT table,
`avbtool verify_image`, DTB sanity, stock DTBO overlay compatibility,
initramfs cpio/applet regression, telnet gate, host-run dropbear
key-only smoke test) still pass unchanged.

## Issue #4 corrections (coordinator verification): minimal USB baseline,
## independent ACM enumeration, signed AVB

The coordinator's review of candidate `69702078…` found three defects.
This section records the corrected build; the previous sections are kept
unchanged as the record of the earlier candidate.

### 1. `CONFIG_C2S_DIAG` disabled for the minimal USB baseline

`arch/arm64/configs/c2s_rescue_defconfig` no longer sets
`CONFIG_C2S_DIAG=y`. The diagnostic candidate wrote milestone markers as
plain stores into three framebuffer addresses (0xf1000000, 0xf9800000,
0xfac00000) from the very first instructions of `primary_entry`
(`arch/arm64/kernel/head.S`, M1) and again with the MMU on (M2), plus
extra initial ID-map coverage (`arch/arm64/pi/map_range.c`,
`arch/arm64/include/asm/kernel-pgtable.h`). That is display-specific
code in the kernel's entry path and does not belong in a minimal USB
observation baseline.

Preservation, not deletion:

* the implementation in `head.S`, `map_range.c`, `kernel-pgtable.h` and
  the `C2S_DIAG` Kconfig symbol are untouched;
* `arch/arm64/configs/c2s_rescue_diag_defconfig` is a new (copy of the
  old) defconfig with `CONFIG_C2S_DIAG=y`, so the earlier diagnostic
  build stays reproducible with
  `make ARCH=arm64 c2s_rescue_diag_defconfig`.

Proof is taken from the *final artifacts*, not the sources:

* `.config` of the built kernel: `CONFIG_C2S_DIAG` not set;
* Image scan (instruction level): no `movz` with the M1/M2 framebuffer
  immediates 0xf100/0xf980/0xfac0 (opcode 0xd2a00000|hw). The same scan
  run against the preserved diagnostic reference Image
  (`/tmp/opencode/c2s-diag-ref/Image.diag`, override with
  `C2S_DIAG_REF_IMAGE`) DOES find them - a positive control so the
  negative result is meaningful;
* `primary_entry` disassembly: no framebuffer addresses, no
  `mov x4, #0xffff` diagnostic prologue.

Result: `Image` shrank 11,891,200 -> 11,760,128 bytes.

### 2. ACM enumerates independently of NCM/RNDIS (state machine + fault injection)

The previous `/init` created ACM, NCM and RNDIS and only bound the UDC
after *all* of them were linked, so an NCM/RNDIS failure (mkdir, ifname,
ln) aborted setup and the ACM console never enumerated.

The gadget setup now lives in `/usr/lib/c2s-gadget.sh`, sourced by
`/init` and tested as-is by `c2s-rescue/scripts/fault-injection.sh`:

* ACM is mandatory: instance created, console attribute written, linked
  first; a failure there is fatal and reported as such;
* NCM and RNDIS are optional: each is attempted independently; a failure
  only drops that link (`ncm-skipped` / `rndis-skipped`) and never
  unlinks ACM;
* bind order: full link set first; if the full bind fails, the network
  symlinks are removed and the ACM-only bind is retried on the SAME UDC
  (`bound-acm-fallback`);
* there is exactly one UDC (`10e00000.dwc3` on this device): one
  gadget, one bind site, no claim of simultaneous or independent UDCs;
* stage/status reporting distinguishes "stage reached" from "no USB":
  status 0 bound, 1 setup failed before bind, 2 no UDC present, 3 every
  bind failed - statuses 2 and 3 mean NOTHING enumerated on USB.

`/init` only configures addresses for netdevs that actually exist, and
never starts dropbear when no USB network interface exists (console-only
stage).

Host fault injection (`verify.sh` section "USB state machine fault
injection") runs the shipped `c2s-gadget.sh` against a fake
configfs/UDC tree:

| Case | Injected fault | Result | Proves | Does NOT prove |
|---|---|---|---|---|
| 1 NCM failure | `functions/ncm.usb0` creation fails | status 0, stage `bound`, linked `[acm.usb2 rndis.usb1]` | ACM survives an NCM failure and stays bound; NCM genuinely absent | that USB enumerates on hardware |
| 2 RNDIS failure | `functions/rndis.usb1` creation fails | status 0, stage `bound`, linked `[acm.usb2 ncm.usb0]` | ACM survives a RNDIS failure | that a host sees the device |
| 3 absent UDC | empty UDC class dir | status 2, stage `udc-absent`, ACM still linked | "no UDC" is distinguishable from a broken bind; nothing enumerated is reported explicitly | anything about USB electrical behaviour |
| 4 all-success | none | status 0, stage `bound`, linked `[acm.usb2 ncm.usb0 rndis.usb1]`, report == tree | full path works; single UDC bind site | that the real configfs/UDC accepts the bind |
| 5 unbindable UDC | `UDC` attribute read-only | full bind fails, ACM-only fallback attempted, status 3 `bind-failed-all` | fallback sequence runs; failure is reported as "NOTHING enumerated" | that a real dwc3 bind can fail this way (kernel semantics not modelled) |

The fake tree models the *sequence*, not kernel configfs semantics
(no EBUSY, no `udc_name` locking, no netdev registration). These tests
are necessary evidence for the fallback logic, not proof of device
behaviour - hardware evidence remains with the coordinator.

Host-side console capture for the hardware run:
`c2s-rescue/scripts/capture-usb-console.sh [outfile] [device]` opens the
CDC-ACM device in raw mode and timestamps every line; it documents that
the ttyGS console buffer is 8 KiB (`GS_CONSOLE_BUF_SIZE`, overflow is
dropped) and that `CON_PRINTBUFFER` replays the ring buffer at console
registration, while `dmesg` over SSH is the complete buffer.

### 3. AVB: signed form required, unsigned result labelled

Candidate `6970207865d6cbb3…` was packaged **without** `C2S_AVB_KEY`, so
its footer is `Algorithm: NONE`: avbtool proved structure and hash only,
no cryptographic signature, not compatible with any verified-boot
policy. That artifact is labelled as structure-and-hash only and is
superseded.

`package-bootimg.sh` now:

* fails unless `C2S_AVB_KEY` is given (or `C2S_ALLOW_UNSIGNED=1` is
  explicitly set for an inspection-only build, clearly labelled);
* adds `--algorithm SHA256_RSA4096 --key $C2S_AVB_KEY
  --rollback_index 13`;
* runs `avbtool info_image`, requires `Algorithm: SHA256_RSA4096` and
  rollback index 13, and runs
  `avbtool verify_image --key $C2S_AVB_KEY` so the embedded public key
  is checked against the authorized host key, not merely present.

The host key stays off the repository (`C2S_AVB_KEY` path only; the
verify gate reads it from the environment).

### Artifacts of this build (build host, `/tmp/opencode/c2s-out`)

| Artifact | Size | sha256 |
|---|---|---|
| `Image` | 11,760,128 B | `5489149e0d59eb302c9d8a26533b2414666d8f177f1967aa2f6a03ad76ccfdd2` |
| `exynos990-c2s.dtb` | 141,740 B | `6afe6322273ffed7207eb14235d2ad7d9c4de2ba63f86bf8f97fc75ffcc799f6` |
| `initramfs.cpio.gz` | 2,496,563 B | `80e84e4e9a5ccd11bc3abeef044f5dbae77ea035943cca11ac7d52669edafcbd` |
| `boot.img` | 61,865,984 B | `4b823391eea9e14014eee5129e68f847be6e5b38e85d91b963f041518e34e5e7` |

DTB byte-identical to the previous candidate (`6afe6322…`): the device
tree was not touched.

AVB (`avbtool info_image` / `verify_image`):

* `Algorithm: SHA256_RSA4096`, `Rollback Index: 13`,
  `Public key (sha1): fcbc02ced423008be3a706f4e85a7366e9b4db6f`
  (same key as the installed vbmeta recorded in `evidence.md`);
* `verify_image` with `--key $C2S_AVB_KEY` passes: signature and
  embedded public key verified;
* the DT slot still parses as the Samsung DT table (magic 0xd7b7ab1e,
  FDT == kbuild DTB).

What this does NOT prove: nothing about device acceptance. Host AVB
verification proves the artifact's internal cryptographic consistency
and its compatibility with the recorded verified-boot policy (algorithm
and rollback index); whether the device accepts the image is a hardware
question for the coordinator (locked vs unlocked chain, rollback
enforcement).

### Verification

`c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-out` -> **170 passed,
0 failed** (150 before, +20 new gates: minimal-baseline
`CONFIG_C2S_DIAG` gates with positive control, `primary_entry`
disassembly, ACM-fallback state machine structure, single-UDC bind
site, console-only SSH gate, shipped `c2s-gadget.sh`, fault-injection
run + its stated limitations, AVB algorithm/signature gates, capture
helper documentation).

## Issue #4: SSH key baked into the packaged artifact (coordinator blocker)

The coordinator found a confirmed blocker in candidate
`4b823391eea9e14014eee5129e68f847be6e5b38e85d91b963f041518e34e5e7`
(61,865,984 B): its packaged initramfs had **no**
`root/.ssh/authorized_keys` (build log: "NOTE: no C2S_AUTHORIZED_KEYS
given"), and `/init` deliberately skips dropbear when that file is
absent - so that artifact could not provide SSH even if USB worked. It
is **not** hardware-ready and is superseded.

The same baseline was rebuilt and repackaged with the operator's public
key supplied through `C2S_AUTHORIZED_KEYS`:

```
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
C2S_AVB_KEY=/path/to/avb_key.pem \
c2s-rescue/scripts/build.sh --outdir /tmp/opencode/c2s-out
C2S_AVB_KEY=/path/to/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-out
```

No key material is printed or committed: only the *public* key is baked
in (mode 0600 inside the initramfs), the private key never leaves the
operator's `~/.ssh`, and the AVB key stays on the build host.

### Independent proof from the exact artifact

`c2s-rescue/scripts/prove-authorized-keys.sh <boot.img> <pubkey>` does
not look at the staging tree at all: it parses the Android boot image
header, slices the ramdisk slot out of `boot.img`, decompresses the
gzip stream and reads the newc cpio entry (mode and contents come from
the archive's own headers). Result for this artifact:

```
entry /root/.ssh/authorized_keys: cpio mode=100600 (regular file), size=97
entry content sha256: 153d52616cdce489bf501401c79e12382e66053e85e787fbc925954e0e122c38
src fingerprint:      SHA256:kX1/T8o7ReIa9OJgX0ADSD03lf/XvAFw5lqbAAUonAE
packaged fingerprint: SHA256:kX1/T8o7ReIa9OJgX0ADSD03lf/XvAFw5lqbAAUonAE
PASS: fingerprint of the packaged authorized_keys matches the source public key
PASS: packaged authorized_keys is a regular file (S_IFREG) with mode 0600
```

The proof is part of `verify.sh` (section "packaged boot.img:
root/.ssh/authorized_keys"), so a future build that forgets
`C2S_AUTHORIZED_KEYS` fails the verification instead of silently
shipping an SSH-less image.

### Artifacts of this build (build host, `/tmp/opencode/c2s-out`)

| Artifact | Size | sha256 |
|---|---|---|
| `boot.img` | 61,865,984 B | `5a0426dc8eae34bd8acb17cd5617fbad243b9d33485f0139ee43f46e9a36cd19` |
| `Image` | 11,760,128 B | `e76231352894124d2434e130f338ad2842848c86e4a4425644af9caee59a2f69` |
| `initramfs.cpio.gz` | 2,496,684 B | `eaa35da0a3029b371af55fc19c7049ac52f0ce893dd451a559c0a0a0ee48ce8d` |
| `exynos990-c2s.dtb` | 141,740 B | `6afe6322273ffed7207eb14235d2ad7d9c4de2ba63f86bf8f97fc75ffcc799f6` (unchanged) |

The `Image` hash differs from the previous candidate
(`5489149e…`) only because the initramfs (with the key) is embedded in
the kernel; the kernel code itself is unchanged - same size
(11,760,128 B), same `CONFIG_C2S_DIAG` state, same DT table, same
`c2s-gadget.sh` state machine with the ACM-independent fallback.

AVB (unchanged policy): `Algorithm: SHA256_RSA4096`, `Rollback Index:
13`, public key sha1 `fcbc02ced423008be3a706f4e85a7366e9b4db6f`;
`avbtool verify_image --image boot.img --key $C2S_AVB_KEY` passes.

### Verification

`c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-out` -> **174 passed,
0 failed** (170 before, +4: the packaged-artifact authorized_keys
presence, fingerprint match, mode 0600 and the helper's exit status).

### What is still NOT proven

Host verification proves that the artifact ships the operator's public
key with the right mode and that the AVB footer is signed by the
authorized key. It proves **nothing** about the device: not that the
image boots, not that USB enumerates, not that the ttyGS console
delivers messages, not that dropbear starts or that SSH accepts the key
(`/init` still requires at least one USB network interface for
dropbear - with only the ACM console there is nothing to bind to).
Those remain hardware questions for the coordinator.

## Issue #4: DECON refresh trigger after the M1/M2 band paints (combined candidate)

### What changed
`arch/arm64/kernel/head.S` gains a `c2s_decon_refresh id` macro
(guarded by `CONFIG_C2S_DIAG`, used at two call sites) implementing
lk3rd's `decon_show_buffer_update()` refresh sequence
(`platform/exynos9830/dpu/decon_core.c:114-134`) with the registers
documented in `c2s-rescue/docs/diag-milestones.md`: all-win shadow
update request, direct-on, global update request, run-status poll,
`HW_SW_TRIG_CONTROL` masked enable (unmask + arm), update-done poll,
masked disable (restore to the sboot `0x3070` handoff state).
`arch/arm64/kernel/pi/map_range.c` gains a fourth `CONFIG_C2S_DIAG`
entry in `create_init_idmap()` that identity-maps the DECON0 SFR page
`0x19050000` with `PROT_DEVICE_nGnRE` so the M2 call site can reach it
while TTBR0 still holds the initial ID map. `c2s-rescue/scripts/verify.sh`
gains a mode-aware DECON-trigger gate (instruction-level MOVZ scan for
`0x19050000`, `>= 2` hits in a diag build, `0` in a baseline build).

### What the evidence does and does not show

The gate is **instruction-level** on the built Image, not source-level:
it counts `movz xN, #0x1905, lsl #16` occurrences in the linked Image
(diag build: `count >= 2`, baseline build: `count == 0`). That count
alone does **not** prove that the two occurrences are the M1 and M2
call sites — it cannot tell where in the Image they are. Per-call-site
evidence comes from the `vmlinux` disassembly (see the address-by-address
listing in `diag-milestones.md`): the M1 block in `primary_entry` at
`ffff8000806cc158` and the M2 block in `__primary_switched` at
`ffff8000806e85a4`. The gate proves the Image is not silently
deconfig'd or stripped; the disassembly proves the call sites.
Neither proves the DECON or the panel accept the writes; a panel update
is hardware evidence only.

Two M2-specific concerns were source-proven rather than assumed:
MAIR_EL1 index 4 is programmed unconditionally by `__cpu_setup` before
the MMU is turned on, and `init_kernel_el` always drops to EL1 before
M2 (so `mair_el1`, not `mair_el2`, is in play; `finalise_el2`/VHE runs
after M2). `remap_idmap_for_lpa2()` would normally rebuild the ID map
into `init_pg_dir` (sized without the diag extras) when
`CONFIG_ARM64_LPA2=y` + `VA_BITS=52`. That rebuild is gated on
`cpu_has_lpa2()` (cpufeature.h:1063-1075), which reads
`ID_AA64MMFR0_EL1.TGRAN_*`; the Exynos990 cores are Cortex-A76 +
Cortex-A55 (`exynos990.dtsi:74-109`), i.e. Armv8.2-A parts, and
FEAT_LPA2 is an Armv8.7-A feature — so the host *expects* the branch
to be skipped, but only the SoC's ID registers can confirm it.

### Artifacts of this build (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag3, signed) | `/tmp/opencode/c2s-diag3-out/boot.img` | 61 865 984 | `63421d0402a4cfbae7fde455344c1d8a0f4167ddb54560affead94fc44d40991` |
| Image (diag3) | `/tmp/opencode/c2s-diag3-out/kbuild/arch/arm64/boot/Image` | 11 891 200 | `e096ecfe98ac8923e271ae0626a191819ac76fe2d004dfcf14a71cd647e2f8ad` |
| DTB (diag3) | `/tmp/opencode/c2s-diag3-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 867 | `43424d49fc43e92ef00cff558058a3edb232592ab3bd89e6f4262b449fb122f2` |
| boot.img (baseline) | `/tmp/opencode/c2s-diag3-base-out/boot.img` | 61 865 984 | `abcd8fdc0e0af01b5d2ba59670106f8a6e4bf2e2bc1ebef1a907194bac49c7c0` |

### Verification

* `verify.sh /tmp/opencode/c2s-diag3-out`: **173 passed, 0 failed** (the
  added DECON gate is green, `count=3`; that is the global Image count
  — two of them are the M1/M2 call sites, the third is the `map_range`
  device-map constant — per-site locations come from the disassembly
  above).
* `verify.sh /tmp/opencode/c2s-diag3-base-out`: **173 passed, 0 failed**
  (baseline mode green, `count=0`).
* 9-overlay merge gate: re-checked manually after the diag3 build -
  live `usb@0` still `dr_mode="peripheral"` with no `maximum-speed`,
  PHY both supplies present, inert shell `usb@10E00000` keeps
  `status="okay"` and `samsung,exynos-dwusb` compatible (no driver match).
* authorized_keys: packaged cpio checked against
  `~/.ssh/id_ed25519.pub` fingerprint (`SHA256:kX1/T8o7ReIa9OJgX0ADSD03lf/XvAFw5lqbAAUonAE`),
  mode 0600.
* Source diff vs the USB-only baseline `eaa841ac` (commit `f732bf00034a`,
  `c2s_rescue_defconfig`): only the marker code (`8c410514`) and the
  new trigger + verify gate are added. The DTB bytes are byte-identical
  between `eaa841ac`, `8c410514` and this candidate (`43424d49…`, same
  USB fix content); the Image now carries the four diagnostic immediates
  (`0xf100`, `0xf980`, `0xfac0`, `0x1905`) under `CONFIG_C2S_DIAG`, none
  of which are present in `eaa841ac`'s Image.

### What is still NOT proven

* Whether DECON/panel accept the writes (panel update needs a hardware
  run; a blank panel on a device with a hung DECON cannot be
  distinguished from "DECON never saw the writes").
* Whether the DECON registers are in the same state after the bounded
  polls as before (each call site ends with the masked disable that
  restores sboot's handoff value for bits 0/4 and preserves 5/6/12/13,
  but the intermediate enable/disable writes are unverified on
  hardware).
* pstore/ramoops: explicitly NOT implemented; that channel's survival
  and TWRP readout are unproven from sources (see `evidence.md`).
* The `earlier` USB-only image `eaa841ac` hangs at boot with zero USB
  signals for 200s - unexplained, coordinator-owned, not part of this
  commit's scope; this candidate does not attempt to fix it.

## Build 5 (turn 2026-11-23): marker ladder M1b/M2-fix/M3/M4

### Build commands (build host)

```
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag5-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag5-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag5-out
```

`build.sh` exit 0; `package-bootimg.sh` exit 0; `verify.sh` exit 0.

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag5, signed) | `/tmp/opencode/c2s-diag5-out/boot.img` | 61 865 984 | `852e868d1e4c3a9d608797116f230a9e31f2cc5abff0890406907c2fa9809f5b` |
| Image (diag5) | `/tmp/opencode/c2s-diag5-out/kbuild/arch/arm64/boot/Image` | 11 891 200 | `d6c45e58d6f60e7d52280f492ccf37e262ab5019d93c73cd6b649df30dec80ee` |
| DTB | `/tmp/opencode/c2s-diag5-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 867 | `43424d49fc43e92ef00cff558058a3edb232592ab3bd89e6f4262b449fb122f2` |
| initramfs | `/tmp/opencode/c2s-diag5-out/work/initramfs.cpio.gz` | 2 496 684 | `eaa35da0a3029b371af55fc19c7049ac52f0ce893dd451a559c0a0a0ee48ce8d` |
| initramfs cpio (uncompressed) | `/tmp/opencode/c2s-diag5-out/work/initramfs.cpio` | - | `f4cc661bf359e3cf7e589e9577e19cf6bab6ef079d176fb61a943e929fbeb46b` |

The DTB is byte-identical to candidates 2/3 (`43424d49…`) and the
initramfs is byte-identical to the diag3 candidate — this build changes
only `arch/arm64/kernel/head.S` (markers) and `c2s-rescue/scripts/verify.sh`
(new gate).

### Verification

* `verify.sh /tmp/opencode/c2s-diag5-out`: **173 passed, 0 failed**
  — the same count as the diag3 baseline. Two of the reported lines
  differ textually from diag3 (`count=6` instead of `count=3` for the
  framebuffer MOVZ gate, because two more markers move the `0xf100`
  immediate, and the PID/path embedded in the dropbear and
  fault-injection lines); the gate *sets* are otherwise identical.
* New band-colour gate: **5 markers, all `SOLID`** on the packaged
  Image; **negative control** on `/tmp/opencode/c2s-diag3-out` fails
  with `marker@0x6e84b0 colour=0x00000000ffff0000 TRUNCATED (2/4 chunks)`.
* DECON MMIO count in the Image: still `3` (`0x19050000` in M1, in
  `create_init_idmap()`, and in M2) — M1b/M3/M4 add no MMIO.
* AVB: `avbtool verify_image` OK, algorithm `SHA256_RSA4096`,
  rollback index **13**, Samsung DT table `d7b7ab1e`, FDT 141 867 B ==
  kbuild DTB, wrapper + packed image verified.
* authorized_keys: packaged cpio checked against
  `~/.ssh/id_ed25519.pub` (`SHA256:kX1/T8o7ReIa9OJgX0ADSD03lf/XvAFw5lqbAAUonAE`),
  mode 0600, regular file read from the packed cpio (not the staging tree).
* Packed-image integrity: the kernel payload embedded in `boot.img`
  (Samsung `ANDR` header, `kernel_size` at offset 8 = 11 891 200,
  payload at `0x800`) compares **byte-identical** to
  `kbuild/arch/arm64/boot/Image`, and the band gate run against a
  file extracted from `boot.img` reports the same 5 `SOLID` markers.

### Source diff for this build

```
 arch/arm64/kernel/head.S     | 315 ++++++++++++++++++++++++
 c2s-rescue/scripts/verify.sh |  95 +++++++++
 c2s-rescue/docs/*.md         | (records only)
 3 files changed, 410 insertions(+)
```

`git status`: only those three paths are modified; nothing staged yet at
the time of writing.

### What is still NOT proven

* Whether the panel shows any of the five bands (hardware only).
* Whether M1's DECON refresh returns at all on hardware — M1b exists
  precisely to break the tie between "died before M2" and "the MMU-off
  MMIO at 0x19050000 hung".
* The sudo/NOPASSWD packaging required by issue #5 task 3 is **not** in
  this build; `verify.sh` has no sudo gate yet.
* USB gadget enumeration (issue #5 task 2) is not exercised by this
  build beyond the DT/gadget gates that already passed for diag3.

## Build 6 (turn 2026-11-23): M1b control-flow fix + passwordless sudo

### What changed

* `arch/arm64/kernel/head.S`: label `1:` in `primary_entry` moved to
  immediately after the `0:` cache-clean block and **before** the M1b
  block. Previously the MMU-off entry path's `b 1f` jumped over the
  whole M1b green band, so it could never appear on the device's own
  entry path even though every byte-level gate passed.
* `c2s-rescue/scripts/check-marker-reachability.py` (new): CFG
  reachability checker for the marker ladder. Builds a control-flow
  graph from the disassembly of a function and requires each marker to
  be reachable from the entry point; for `primary_entry` it splits
  reachability at the `cbnz x19` MMU-state branch and requires the
  marker to be reachable on **both** the cache-off and cache-on path.
* `c2s-rescue/tests/fixtures/primary_entry.prefix-m1b-unreachable.txt`
  (new): the committed pre-fix objdump listing that the checker must
  reject - the gate's own negative control.
* `c2s-rescue/scripts/cpio-listing.py` (new): parses newc cpio headers
  and prints numeric mode/uid/gid. `cpio -itv` resolves the uid against
  the host passwd database, which makes an ownership gate for uid 1000
  meaningless on a build host whose uid 1000 has a different name.
* `c2s-rescue/scripts/verify.sh`: new CFG-reachability section (with
  the fixture negative control), new "passwordless sudo" section
  (archive ownership/mode/uid gates + content gates + a functional
  qemu chroot test with a setuid negative control), and a new
  "packaged boot.img: sudo payload" section that re-proves the whole
  sudo/sudoers/rescue-account payload inside the **signed** image.
* `c2s-rescue/initramfs/etc/{passwd,group}`: added the `rescue` account
  (uid/gid 1000, home `/home/rescue`, shell `/bin/sh`).
* `c2s-rescue/initramfs/etc/sudoers`,
  `c2s-rescue/initramfs/etc/sudoers.d/90-rescue`,
  `c2s-rescue/initramfs/etc/pam.d/sudo` (new): sudo-rs configuration.
* `c2s-rescue/initramfs/init`: dropbear is started **without** `-D`
  (per-user `~/.ssh/authorized_keys`); the start condition now accepts
  the key file of either `rescue` or `root`.
* `c2s-rescue/scripts/build.sh`: stages sudo-rs + musl + libpam +
  libgcc_s + pam_permit from the postmarketOS aarch64 `.apk` packages
  (each SHA-256 verified), installs the operator key for both `root` and
  `rescue`, adds the `id`/`whoami`/`groups` busybox applets, and
  emits the new cpio entries with the correct uid/gid/mode.

### Build commands (build host)

```
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag6-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag6-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag6-out
```

`build.sh` exit 0; `package-bootimg.sh` exit 0; `verify.sh` exit 0
(**217 passed, 0 failed**; build 5 had 173).

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag6, signed) | `/tmp/opencode/c2s-diag6-out/boot.img` | 61 865 984 | `13cdc38ca0725706d7367ef9fcd023e1ce5bdd034f8436720da67e9688c49243` |
| Image (diag6) | `/tmp/opencode/c2s-diag6-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `909d03e1c971302f9b805384d2ac97f958add003a85d9029417c1b50f952eb9a` |
| DTB | `/tmp/opencode/c2s-diag6-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 867 | `43424d49fc43e92ef00cff558058a3edb232592ab3bd89e6f4262b449fb122f2` |
| initramfs | `/tmp/opencode/c2s-diag6-out/work/initramfs.cpio.gz` | 3 367 458 | `515de1c3d5d9cb4ef6196d4382bfd6b7e3c41a17461e00662e486769758c70fa` |

The Image grew by 917 504 B and the initramfs by 870 774 B against
build 5; the growth is the sudo-rs runtime (sudo 726 008 B + musl
723 480 B + libpam 67 472 B + pam_permit 67 400 B + libgcc_s
133 008 B). The partition has ample headroom: the payload is ~16.2 MB
of a 61 865 984 B image.

### Verification highlights

* CFG reachability on `primary_entry`: M1-white **and** M1b-green
  reachable from the entry and from both MMU-state paths.
* CFG negative control: the committed pre-fix listing is rejected.
* Band gate on the kernel payload extracted from the signed `boot.img`:
  5 markers, all `SOLID`; the payload is byte-identical to
  `kbuild/.../Image` (`909d03e1…`).
* Packaged ramdisk: `104755 0 0 f usr/bin/sudo` (setuid root),
  `100440 0 0 f etc/sudoers`, `100440 0 0 f etc/sudoers.d/90-rescue`,
  `100644 0 0 f etc/pam.d/sudo`, `100600 1000 1000 f
  home/rescue/.ssh/authorized_keys`, `100600 0 0 f
  root/.ssh/authorized_keys`.
* Functional sudo in a root-owned chroot of the packed rootfs:
  `sudo -n -l -U rescue` -> `(ALL : ALL) NOPASSWD: ALL`;
  `sudo -n id` -> `uid=0(root) gid=0(root) groups=0(root)`.
* sudo negative control: without the setuid bit and with a non-root
  caller, sudo-rs refuses ("sudo must be owned by uid 0 and have the
  setuid bit set").
* AVB: `avbtool verify_image` OK, algorithm `SHA256_RSA4096`, rollback
  index **13**, Samsung DT table `d7b7ab1e`, FDT 141 867 B == kbuild
  DTB, wrapper + packed image verified.

### What is still NOT proven

* That the panel shows any of the five bands (hardware only).
* That the USB gadget enumerates and that SSH with key-only login
  works on the device (hardware only).
* That `sudo -n id` elevates on the device: qemu-user does not emulate
  setuid, so the non-root elevation path is proven natively on the host
  (x86_64 sudo-rs 0.2.13) and must be confirmed on the device.

## Build 7 (turn 2026-11-24): C-level milestone ladder

### Build commands (build host)

```
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag7-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag7-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag7-out
```

The paired baseline (the same tree, `CONFIG_C2S_DIAG` off) was built the
same way into `/tmp/opencode/c2s-diag7-base-out` and verified as well.

`build.sh` exit 0; `package-bootimg.sh` exit 0; `verify.sh` exit 0 for both
(**219 passed, 0 failed** each; build 6 had 217).

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag7, signed) | `/tmp/opencode/c2s-diag7-out/boot.img` | 61 865 984 | `ed506c5f3b0712ca8f514f5617fd47997d991d7445eff7a30b6f831d73ffa751` |
| Image (diag7) | `/tmp/opencode/c2s-diag7-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `c79875f6f563fcb17df6da0c1c4ec24760a91690b35f8d21d5317a44ef6b2153` |
| DTB | `/tmp/opencode/c2s-diag7-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 867 | `43424d49fc43e92ef00cff558058a3edb232592ab3bd89e6f4262b449fb122f2` |
| initramfs | `/tmp/opencode/c2s-diag7-out/work/initramfs.cpio.gz` | 3 367 458 | `515de1c3d5d9cb4ef6196d4382bfd6b7e3c41a17461e00662e486769758c70fa` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag7-base-out/boot.img` | 61 865 984 | `085a4b7168519cce2f1e00efa1f70a0433ac967642b05cf3b18074f9bb3a5d3b` |
| Image (baseline) | `/tmp/opencode/c2s-diag7-base-out/kbuild/arch/arm64/boot/Image` | 12 677 632 | `a713350af1a6036ee779d5ffdc1144a598c6605e8d15a7677687932cb2b21505` |

DTB and initramfs are byte-identical to build 6: this build changes only
the kernel Image. AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT
table `d7b7ab1e`, FDT 141 867 B == kbuild DTB.

### What changed in the kernel

* `include/linux/c2s_diag.h` - the diagnostic API: `c2s_band_early()`
  (`.init.text`, boot ID map and `early_memremap()`),
  `c2s_late_init()` (`.init.text`, takes the long-lived mappings) and
  `c2s_band()` (`.text`, plain stores through those mappings).
* `arch/arm64/kernel/c2s_diag_bands.c` - the painter: band fill, DECON0
  shadow update, and the two mapping strategies.
* `init/main.c` - milestones at `start_kernel()` entry (row 640), after
  `setup_arch()` (768), after `console_init()` (896), the
  `c2s_late_init()` call after `mm_core_init()`, and the `/init` exec
  attempt (1152).
* `drivers/usb/gadget/udc/core.c` - UDC registered (1024), gadget bound
  (1280), bind failed (1408).
* `drivers/usb/gadget/function/u_ether.c` - netdev carrier on (1536).

### Host evidence

* Modpost is clean: no `.text` -> `.init.text` reference remains. The
  split API exists because `early_memremap()` lives in `.init.text` and
  calling it from `.text` is a section mismatch.
* New gate `c2s-rescue/scripts/check-c-milestone-bands.py` verifies callee,
  row and colour of all 10 milestone call sites in the disassembly of the
  five functions that carry them.
* Gate negative control: the committed fixture
  `c2s-rescue/tests/fixtures/gether_connect.wrong-row.txt` (row 1536
  changed to 1537) is rejected - the gate is sensitive to row drift.
* Compile-out control: the paired baseline has no `c2s_*` symbols, zero
  framebuffer MOVZ immediates in the Image and no milestone call sites;
  its `verify.sh` run is 219/0 as well.

### What is still NOT proven

* That the panel shows any of the C bands (hardware only).
* Where the USB failure actually is - the ladder locates it, it does not
  fix it.

## Build 8 (turn 2026-11-24): fb2 no-map, scanout discriminator, HS cap

### Build commands (build host)

```
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag8-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag8-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag8-out
```

The paired baseline (the same tree, `CONFIG_C2S_DIAG` off) was built the
same way into `/tmp/opencode/c2s-diag8-base-out` and verified as well.

`build.sh` exit 0; `package-bootimg.sh` exit 0; `verify.sh` exit 0 for both
(**223 passed, 0 failed** each; build 7 had 219 - the increase is two new
DTB gates and two new negative controls).

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag8, signed) | `/tmp/opencode/c2s-diag8-out/boot.img` | 61 865 984 | `8b3fda3012fea74c34f7ac6ae3ac1f409b2c81b0d523e40d90c381a5e577cfe0` |
| Image (diag8) | `/tmp/opencode/c2s-diag8-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `ca3675094b22f73700b640baa209e1a6fcd07cdc2f3cc6b97bc53c05b44afce1` |
| DTB | `/tmp/opencode/c2s-diag8-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 142 056 | `e70691b32d5b7dea0fdd44b9db93c076d419d5c1abe6faaa0fb099f06d5aeac6` |
| initramfs | `/tmp/opencode/c2s-diag8-out/work/initramfs.cpio.gz` | 3 367 458 | `515de1c3d5d9cb4ef6196d4382bfd6b7e3c41a17461e00662e486769758c70fa` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag8-base-out/boot.img` | 61 865 984 | `f45220b4edfbcc324f4a13c7fe986e1ce99940c923849915b487fc6f6cb3fb62` |
| Image (baseline) | `/tmp/opencode/c2s-diag8-base-out/kbuild/arch/arm64/boot/Image` | 12 677 632 | `7a3e44eaaddd0e23a895cd4b82b782fe05254f466f8124cd39a9c3258dd37d87` |

The initramfs is byte-identical to build 7. The DTB grew by 189 B (the new
fb2 reservation plus `maximum-speed`). AVB: `SHA256_RSA4096`, rollback
index **13**, Samsung DT table `d7b7ab1e`, FDT 142 056 B == kbuild DTB.

### What changed

* `arch/arm64/boot/dts/exynos/exynos990-c2s.dts` - **change A**: a third
  no-map reservation `fb2_splash_mem: framebuffer@fac00000`
  (`reg = <0x0 0xfac00000 0x10f6800>`), which is exactly the framebuffer
  range; fb2 is no longer unreserved RAM, so `memblock_mark_nomap()` keeps
  it out of the linear map and out of the buddy, and `ioremap_wc()` accepts
  it. **change C**: `maximum-speed = "high-speed"` on `&usbdrd_dwc3_live`,
  one property and nothing else.
* `arch/arm64/kernel/c2s_diag_bands.c` - the painter was refactored into
  `c2s_paint_early_fb()` (per buffer, chunked `early_memremap()`, ID-map
  identity otherwise) and `c2s_kick_early()` (one DECON kick). The old
  "skip fb2 outside the ID-map phase" rule is gone: fb2 is painted in all
  three phases. `c2s_late_init()` now maps three buffers and logs
  `c2s: milestone mappings incomplete: fb0=... fb1=... fb2=... decon=...`
  if any mapping failed. New `c2s_scanout_probe()` paints one band with a
  different colour per buffer.
* `include/linux/c2s_diag.h` - declares `c2s_scanout_probe()` (plus a
  no-op stub in the `#else` branch).
* `init/main.c` - the discriminator call site right after C1:
  `c2s_scanout_probe(1664, 0xffff0000, 0xff00ff00, 0xff0000ff)`, still in
  the ID-map phase and before `setup_arch()`.
* `c2s-rescue/scripts/check-c-milestone-bands.py` - the argument tracker
  was widened from `w0`/`w1` to `w0..w3`/`x0..x3` (the discriminator is the
  only four-argument milestone) and the expectations became positional
  argument lists. It verifies 11 call sites now.
* `c2s-rescue/tests/fixtures/start_kernel.scanout-wrong-row.txt` and
  `start_kernel.scanout-wrong-colour.txt` - new negative controls.
* `c2s-rescue/scripts/verify.sh` - two new DTB gates (fb2 `no-map`
  reservation with the exact range; `maximum-speed = "high-speed"` on the
  live gadget node resolved through `/__symbols__/usbdrd_dwc3_live`) and the
  two new negative controls wired in.

### Host evidence

* `check-c-milestone-bands.py` on the diag8 vmlinux: **PASS (11 milestone
  call site(s) verified)**. The discriminator call site disassembles to
  four immediate loads, so the gate reads the real colours:
  `mov w3, #0xff0000ff` / `mov w2, #0xff00ff00` / `mov w1, #0xffff0000` /
  `mov w0, #0x680` then `bl <c2s_scanout_probe>`.
* All three negative controls are rejected by the gate (wrong row 1536 ->
  1537, wrong discriminator row 1664 -> 1665, wrong fb2 colour
  `0xff0000ff` -> `0xff0000fe`).
* The baseline build has zero `c2s_*` symbols and zero milestone call
  sites; its `verify.sh` run is 223/0 as well.
* The DT gates are checked against the *built* DTB, not the source: the fb2
  node is found by path with `reg` cells `[0x00, 0xfac00000, 0x10f6800]`
  and a `no-map` property, and the speed gate resolves
  `/soc@0/usb@10e00000/usb@0` through `/__symbols__/usbdrd_dwc3_live` so it
  cannot accidentally match the inert anchors shell that carries the
  `usbdrd_dwc3` label.

### What is still NOT proven

* That the panel shows the discriminator band, or any of the C bands -
  hardware only.
* That `maximum-speed = "high-speed"` fixes the USB failure: it is a
  one-variable candidate (no `usb3-phy` exists on this port, and TWRP
  enumerates HS on the same port and cable), not a proven fix.


## Build 9 (turn 2026-11-24): logo-zone layout, fb2 linear alias, setup_arch bands

### Build commands (build host)

```
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag9-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag9-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag9-out
```

The paired baseline (the same tree, `CONFIG_C2S_DIAG` off) was built the
same way into `/tmp/opencode/c2s-diag9-base-out` and verified as well.

`build.sh` exit 0; `package-bootimg.sh` exit 0; `verify.sh` exit 0 for both
(**229 passed, 0 failed** each; build 8 had 223).

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag9, signed) | `/tmp/opencode/c2s-diag9-out/boot.img` | 61 865 984 | `d307a3398fd02e4e9788f5e84e4b5c010bcf87f556d5bbd67593ba95c2b9439e` |
| Image (diag9) | `/tmp/opencode/c2s-diag9-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `254119d2b6db10f76cbdab046bfc861ac1f9acb201f4df4d34a52cd2f897b1c0` |
| DTB | `/tmp/opencode/c2s-diag9-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 142 044 | `68e5f8ca89d33230eff26cce7b97e6496574c5894c74dd07249d54f2e5be242b` |
| initramfs | `/tmp/opencode/c2s-diag9-out/work/initramfs.cpio.gz` | 3 367 458 | `515de1c3d5d9cb4ef6196d4382bfd6b7e3c41a17461e00662e486769758c70fa` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag9-base-out/boot.img` | 61 865 984 | `601918e341e1e92f2fb0e1de1f916107af26a347afb1e85f179a80a52b23a5e5` |
| Image (baseline) | `/tmp/opencode/c2s-diag9-base-out/kbuild/arch/arm64/boot/Image` | 12 677 632 | `226efb60a6e377930427464b1a2b2a16e20e9bc9f35e06672c22551e0e32673a` |

The initramfs is byte-identical to builds 7 and 8 (no initramfs change).
AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e`
ok, FDT 142 044 B == kbuild DTB.

### What changed in the kernel

* `arch/arm64/boot/dts/exynos/exynos990-c2s.dts` - fb2 stays reserved
  **without** `no-map` (diag8 already removed the property; this build
  keeps it and adds the fb2/fb0/fb1 gate in both directions).
* `arch/arm64/kernel/c2s_diag_bands.c` - the painter:
  * two new phase markers (`c2s_mark_idmap_gone()`,
    `c2s_mark_linear_ready()`) replace the `memstart_addr` sentinel as
    the phase discriminator, because the sentinel cannot express the
    window between `cpu_uninstall_idmap()` and `paging_init()`;
  * the fb2 branch of `c2s_paint_early_fb()` is gated on
    `!idmap && c2s_linear_alive()` and writes through `phys_to_virt()`
    (cacheable, so the fill is followed by `dcache_clean_inval_poc()`);
  * `c2s_paint_band_early()` attempts all three buffers independently,
    logs a `pr_err` per failure and kicks the DECON iff at least one
    buffer was painted;
  * `c2s_late_init()` takes fb0/fb1 with `ioremap_wc()` and fb2 with the
    linear alias; `c2s_band()` cleans the cache for the cacheable alias
    only.
* `arch/arm64/kernel/setup.c` - the three new setup_arch() milestones and
  the two markers:
  * S1 `c2s_band_early(2496, 0xff008080)` right after
    `setup_machine_fdt()` (still the ID map);
  * `c2s_mark_idmap_gone()` right after `cpu_uninstall_idmap()`;
  * `c2s_mark_linear_ready()` + S2 `c2s_band_early(2624, 0xff800080)`
    right after `paging_init()`;
  * S3 `c2s_band_early(2752, 0xffc0c0c0)` as the last statement of
    `setup_arch()`.
* `init/main.c` - the scanout discriminator moved from row 1664 to row
  1024 (1664 is inside the logo band and could not be read back); the
  two `c2s_band(1152, ...)` call sites in `run_init_process()` removed.
* `drivers/usb/gadget/udc/core.c` and
  `drivers/usb/gadget/function/u_ether.c` - the five USB milestone call
  sites (1024, 1280, 1408, 1536) and the stale `#include
  <linux/c2s_diag.h>` removed.
* `include/linux/c2s_diag.h` - the two marker declarations plus their
  stubs for the `!CONFIG_C2S_DIAG` build.
* `arch/arm64/Kconfig` - the `C2S_DIAG` help text updated for the new
  paint paths.

### Host evidence

* `check-c-milestone-bands.py` on the diag9 vmlinux: **PASS (14 milestone
  call site(s) verified)** - five in `start_kernel()` (C1, the
  discriminator, C2, C3, `c2s_late_init()`), five in `setup_arch()` (S1,
  the two markers, S2, S3) and four *empty* expectations that assert the
  USB functions carry no call site at all.
* The disassembly confirms the intended order in `setup_arch()`:
  `c2s_band_early(2496)` < `c2s_mark_idmap_gone()` <
  `arm64_memblock_init()` < `paging_init()` < `c2s_mark_linear_ready()` <
  `c2s_band_early(2624)` < `c2s_band_early(2752)`.
* `check-c2s-paint-paths.py`: **PASS (21 paint-path properties
  verified)**. Its negative control (the painter with fb2 skipped and the
  loop aborting on the first failure) is rejected with three separate
  assertions.
* **Negative controls, all rejected**:
  `gether_connect.wrong-row.txt` (the leftover USB call site, which the
  empty expectation must reject), `start_kernel.scanout-wrong-row.txt`
  (discriminator row 1024 -> 1025), `start_kernel.scanout-wrong-colour.txt`
  (fb2 colour `0xff0000ff` -> `0xff0000fe`), the new
  `setup_arch.s3-wrong-row.txt` (S3 row 2752 -> 2753), and the two paint
  path controls - `c2s_diag_bands.skip-fb2-and-abort.txt` (fb2 skipped,
  loop aborts on first failure, kick dropped) and
  `setup_arch.band-in-forbidden-window.txt` (S2 painted between
  `cpu_uninstall_idmap()` and `paging_init()`).
* **DTB gates, now in both directions**: fb2 must carry **no** `no-map`
  (with it, `phys_to_virt()` would fault) and fb0/fb1 must be covered by
  `no-map` reservations of the full `0x10f6800` bytes (fb1 is matched by
  *containment*, because it lies wholly inside the vendor audio
  reservation and has no node of its own).
* The baseline build has zero `c2s_*` symbols and zero milestone call
  sites; its `verify.sh` run is 229/0 as well.

### What is still NOT proven

* Everything about the panel remains host-unverified: whether the DECON
  scans fb0, fb1 or fb2, whether `setup_arch()` completes, and where - if
  anywhere - the C ladder is actually visible. The logo band is a
  **hypothesis**; a missing band never proves the kernel stopped.
* C2 and C3 were absent from the diag8 photo although they sat in the
  visible gap. This build repaints them through a different path (fb2 via
  the linear alias instead of `ioremap_wc()`), so the next photo can tell
  a paint failure from a scanout problem.
* The USB failure root cause is unchanged: `maximum-speed = "high-speed"`
  is still a one-variable candidate, and the USB milestone bands are gone
  until diag10.

## Build 10 (turn 2026-11-24): C2..C3 bisect tick + the pre-workqueue kick fix

diag10, step 1. The C2..C3 window (`init/main.c`, `setup_arch()` done at
C2 to `console_init()` returned at C3) is ~140 lines wide and a single gap
in it says nothing about which half failed. `c2s_late_init()` is called
from inside that window - right after `mm_core_init()` - and lives in the
painter, so it is the one bisect point that needs no second source file.

### Build commands (build host)

```
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag10-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag10-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag10-out
```

The paired baseline (same tree, `CONFIG_C2S_DIAG` off) went to
`/tmp/opencode/c2s-diag10-base-out` the same way.

`build.sh` exit 0; `package-bootimg.sh` exit 0; `verify.sh` exit 0 for both
(**230 passed, 0 failed** each; build 9 had 229 - the extra check is the
new negative control below).

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag10, signed) | `/tmp/opencode/c2s-diag10-out/boot.img` | 61 865 984 | `d106f34d5381b2337aba5cc9a7785498ccbb1138229694c238f8f881b9a6e504` |
| Image (diag10) | `/tmp/opencode/c2s-diag10-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `e10d83c1d8e36bcc1938020baaf4de9acb3a0dc71a9bcbc5db1b38a5de2a6a07` |
| DTB | `/tmp/opencode/c2s-diag10-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 142 044 | `68e5f8ca89d33230eff26cce7b97e6496574c5894c74dd07249d54f2e5be242b` |
| initramfs | `/tmp/opencode/c2s-diag10-out/work/initramfs.cpio.gz` | 3 367 458 | `515de1c3d5d9cb4ef6196d4382bfd6b7e3c41a17461e00662e486769758c70fa` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag10-base-out/boot.img` | 61 865 984 | `8620f202dd87f703332468d533fee2387ee1ff8ca9b81a4299b3fc46cf7cfee0` |
| Image (baseline) | `/tmp/opencode/c2s-diag10-base-out/kbuild/arch/arm64/boot/Image` | 12 677 632 | `226efb60a6e377930427464b1a2b2a16e20e9bc9f35e06672c22551e0e32673a` |

The DTB and the initramfs are byte-identical to build 9 (neither the
device tree nor the rootfs changed); the baseline `Image` is too - the only
delta is the diag `Image`, i.e. this build really adds code to
`CONFIG_C2S_DIAG=y` only. AVB: `SHA256_RSA4096`, rollback index **13**,
Samsung DT table `d7b7ab1e` ok, FDT 142 044 B == kbuild DTB.

### What changed

* `arch/arm64/kernel/c2s_diag_bands.c`
  * **The defect this build exists to prevent.** `c2s_band()` deferred the
    DECON refresh with `if (irqs_disabled()) schedule_work(...)` - legal
    from the USB call sites (the workqueues exist by the time any
    initcall/driver probe runs), but `c2s_late_init()` is called from
    `init/main.c` with IRQs already disabled from the `local_irq_disable()`
    *before* `setup_arch()`, and `workqueue_init_early()` - which creates
    `system_percpu_wq` - runs dozens of lines *after* it. The first call
    would have reached `__queue_work()` with a `wq == NULL` and
    dereferenced it, i.e. the diagnostic would have killed the boot it is
    supposed to observe, one line after `mm_core_init()`. The condition is
    now `irqs_disabled() && system_percpu_wq`: before the workqueues exist
    the refresh runs synchronously (bounded MMIO, no allocation, the same
    sequence `c2s_kick_early()` issues in the ID-map phase), and the
    atomic deferral for dwc3's spinlock is kept once they do exist.
  * the new `C2S_LATE_ROW` (2880, first free 128-row slot after S3's
    2879 and outside the logo zone) / `C2S_LATE_COLOUR` (0xff000080, dark
    navy, unique in the ladder) and the `c2s_band(C2S_LATE_ROW,
    C2S_LATE_COLOUR)` call at the end of `c2s_late_init()`.
  * the comment that shipped with that tick was corrected: a **visible**
    band proves the allocator/vmap came up and this paint path plus one
    DECON refresh worked; a **missing** band still proves nothing, because
    the fill, the cache clean, the mappings taken above or the scanout can
    have failed while execution carried on. The header comment's standing
    rule ("a missing band is never proof that execution stopped") is not
    relaxed by this candidate.
* `c2s-rescue/scripts/check-c-milestone-bands.py` - `c2s_late_init` added
  to the expected table with `("c2s_band", (2880, 0xff000080))`; it was
  absent before, so the new call site was unchecked.
* `c2s-rescue/scripts/check-c2s-paint-paths.py` - three new properties
  (25 now, was 21): the deferred kick must be guarded on
  `system_percpu_wq`, the guard must read `irqs_disabled() &&
  system_percpu_wq`, and `c2s_late_init()` must paint its tick via the
  late path (`c2s_band`, not the `__init` `c2s_band_early()`, which would
  reach `early_memremap()` in `.init.text` after that memory is released).
* `c2s-rescue/tests/fixtures/c2s_late_init.wrong-row.txt` (new) -
  negative control for the new call site (row 2880 -> 2881).
* `c2s-rescue/scripts/verify.sh` - the new fixture wired into the C
  milestone negative-control loop.

### Host evidence

* `check-c-milestone-bands.py` on the diag10 vmlinux: **PASS (15 milestone
  call site(s) verified)** - build 9's fourteen plus the new
  `c2s_late_init` entry. The disassembly of `c2s_late_init` shows
  `mov w0, #0xb40` / `mov w1, #0x80` + `movk w1, #0xff00, lsl #16` /
  `bl c2s_band`, i.e. row 2880 and colour 0xff000080 exactly as pinned.
* `check-c2s-paint-paths.py`: **PASS (25 paint-path properties verified)**.
* `verify.sh` on the diag build: **230 passed, 0 failed**; on the paired
  baseline: **230 passed, 0 failed**.
* **Negative controls, all rejected** (rc=1 each):
  `c2s_late_init.wrong-row.txt` (2880 -> 2881);
  a painter copy with the kick guard reverted to
  `if (irqs_disabled())` - rejected by the
  `irqs_disabled() && system_percpu_wq` property; a copy with that guard
  reverted *and* the `c2s_band(C2S_LATE_ROW, C2S_LATE_COLOUR)` call
  removed - rejected by both that property and the "the C2..C3 bisect
  band is not painted here" property; plus all four pre-existing
  milestone fixtures and both pre-existing paint-path fixtures
  (`c2s_diag_bands.skip-fb2-and-abort.txt` still rejected with rc=1).
* The negative controls were run against temporary copies under
  `/tmp/opencode/`; the working tree was never modified by them.

### What is still NOT proven

* No hardware run: nothing here shows the band appearing on the panel, and
  `HOST_CANDIDATE_READY` is a build/gate claim only. #5 and #4 stay open
  until a photo of the panel or a USB/console observation backs them.
* The value of the new tick is conditional and symmetric: visible tick
  means the window was walked through to `c2s_late_init()` and the gap to
  C3 shrinks to `console_init()` and its surroundings; a missing tick
  still allows "the paint or the scanout failed", exactly as before.
* The C2..C3 window is bisected at one point only (`mm_core_init()`).
  Finer ticks inside the window, the initcall/USB phase readout and the
  on-panel text readout are not in this build.
* The USB failure root cause is unchanged: `maximum-speed = "high-speed"`
  is still a one-variable candidate, and the USB milestone call sites are
  still removed until a later diag10 step re-places them in visible rows.

## Build 11 (turn 2026-11-24): diag11 stage bands (K1-K4, U1-U5) & fbcon

Completes diag11 by wiring kernel-side stage bands into `init/main.c` (K1
after `console_init()`/`locking_selftest()`, K2 at entry to `kernel_init()`,
K3 after `do_initcalls()`, K4 in `run_init_process()`), complementary to
userspace U1-U5 stage bands in `/usr/lib/c2s-gadget.sh` and K4 entry band in
`/init`.

### Build commands (build host)

```sh
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag11-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag11-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag11-out
```

Paired baseline (`CONFIG_C2S_DIAG` off) built into `/tmp/opencode/c2s-diag11-base-out`:

```sh
C2S_DEFCONFIG=c2s_rescue_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag11-base-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag11-base-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag11-base-out
```

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag11, signed) | `/tmp/opencode/c2s-diag11-out/boot.img` | 61 865 984 | `97c57b61864dcff6f39a99aae36f3685fae710579026c39452241eaa1c5ad3ca` |
| Image (diag11) | `/tmp/opencode/c2s-diag11-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `555382c9732ec0335e33486c4fcafb48bc4d9fae1dad76f63070fdd1d5b9399c` |
| DTB | `/tmp/opencode/c2s-diag11-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 142 044 | `68e5f8ca89d33230eff26cce7b97e6496574c5894c74dd07249d54f2e5be242b` |
| initramfs | `/tmp/opencode/c2s-diag11-out/work/initramfs.cpio.gz` | 3 368 927 | `0442b7815dc02f7ca52222b5b9985dd8ec1b31d61f733fe11b20021f66d95df7` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag11-base-out/boot.img` | 61 865 984 | `ee64346be73c3b158422766e21c70a650a8e2f5ddd61901239db4acd45485111` |
| Image (baseline) | `/tmp/opencode/c2s-diag11-base-out/kbuild/arch/arm64/boot/Image` | 12 677 632 | `70c0c673d1c61ad0383aede97313fc21a6f47c8302b0447142dfe28479a8ef8d` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 142 044 B == kbuild DTB.

### Host evidence

* `check-c-milestone-bands.py` on diag11 vmlinux: **PASS (20 milestone call site(s) verified)**.
* `check-c-milestone-bands.py --expect-none` on baseline vmlinux: **PASS (no milestone call sites; baseline build)**.
* `check-c2s-paint-paths.py`: **PASS (25 paint-path properties verified)**.
* `fault-injection.sh`: **10 passed, 0 failed**.
* `verify.sh`: **231 passed, 0 failed** on diag11; **231 passed, 0 failed** on baseline.
* Negative controls: all 6 rejected (`kernel_init.wrong-row.txt`, `c2s_late_init.wrong-row.txt`,
  `setup_arch.s3-wrong-row.txt`, `start_kernel.scanout-wrong-colour.txt`,
  `start_kernel.scanout-wrong-row.txt`, `gether_connect.wrong-row.txt`).

## Build 12 (turn 2026-11-24): diag12 panel text console (independent kernel dmesg console)

Implements milestone diag12: a self-contained panel text console directly registered
from `c2s_late_init()` using in-kernel font `font_vga_8x16` scaled 2x to 16x32 pixel cells
(90 columns x 96 rows) on a8r8g8b8 panel buffers (stride 5760). Registered with `CON_PRINTBUFFER`
to replay all prior `printk()` logs. Clears screen to black on registration, scrolls with `memmove`,
maintains cache to PoC, kicks DECON synchronously, and neutralizes post-registration milestone
bands (`c2s_band` and `c2s_band_32`). Includes kernel cmdline options `loglevel=8`, `ignore_loglevel`,
`panic=0`, `panic_on_oops=1`, and `CONFIG_PANIC_TIMEOUT=0`. Userspace `/init` and `c2s-gadget.sh`
log each stage to `/dev/kmsg` and `/dev/console`.

### Build commands (build host)

```sh
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag12-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag12-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag12-out
```

Paired baseline (`CONFIG_C2S_DIAG` off) built into `/tmp/opencode/c2s-diag12-base-out`:

```sh
C2S_DEFCONFIG=c2s_rescue_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag12-base-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag12-base-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag12-base-out
```

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag12, signed) | `/tmp/opencode/c2s-diag12-out/boot.img` | 61 865 984 | `e641d6575b9763822fcf19c063d09e4b3a3981e5e13f69509f7504d6fa13cdee` |
| Image (diag12) | `/tmp/opencode/c2s-diag12-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `6e299e8c73e95373a2dce8a17478453374b1f8e64b56dda8a7b429450d32a0a9` |
| DTB | `/tmp/opencode/c2s-diag12-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 142 044 | `68e5f8ca89d33230eff26cce7b97e6496574c5894c74dd07249d54f2e5be242b` |
| initramfs | `/tmp/opencode/c2s-diag12-out/work/initramfs.cpio.gz` | 3 369 013 | `cd0445405f92cfdeb9efe15bb01559f50e487c62e1b93ef564063fda91975da8` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag12-base-out/boot.img` | 61 865 984 | `48f3632df2a4cd66a0749002a729c2aee96f1b95fa61f7ba5b70bfa1dd829040` |
| Image (baseline) | `/tmp/opencode/c2s-diag12-base-out/kbuild/arch/arm64/boot/Image` | 12 677 632 | `63bb4ec79e920dd34904b757699f702e060ef639c893242e8537612df9d727ec` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 142 044 B == kbuild DTB.

### Host evidence

* `check-c-milestone-bands.py` on diag12 vmlinux: **PASS (20 milestone call site(s) verified)**.
* `check-c-milestone-bands.py --expect-none` on baseline vmlinux: **PASS (no milestone call sites; baseline build)**.
* `check-c2s-paint-paths.py`: **PASS (34 paint-path and console properties verified)**.
* `fault-injection.sh`: **10 passed, 0 failed**.
* `verify.sh`: **244 passed, 0 failed** on diag12; **245 passed, 0 failed** on baseline.
* Console negative controls: console registration removal rejected, font reference removal rejected.

## Build 13 (turn 2026-11-24): diag13 DWC3 gadget UDC registration collision fix

Resolves issue #5: during diag12 boot, `dwc3_exynos_probe()` failed to populate its child device
because of a sysfs name collision:
`sysfs: cannot create duplicate filename '/bus/platform/devices/10e00000.usb'`
resulting in `device_add` failure, no DWC3 core device registration, and empty `/sys/class/udc`
(`gadget stage=2:udc-absent`).

### Root cause proof

Linux generates platform device bus IDs in `drivers/of/device.c:of_device_make_bus_id()` formatted
as `%llx.%pOFn` when a `reg` property translates into a physical address.
Two distinct nodes in the merged device tree yielded the duplicate bus ID `10e00000.usb`:
1. `/soc@0/usb@10e00000/usb@0` (the live DWC3 gadget core with label `usbdrd_dwc3_live`, `reg = <0x0 0x10000>`
   translated by parent glue `ranges = <0x0 0x10e00000 0x10000>` to physical address `0x10e00000`, node name `usb`).
2. `/usb@10E00000` (the stock root-level anchor node with label `udc`, `reg = <0x00 0x10e00000 0x10000>`,
   compatible `"samsung,exynos-dwusb"`, node name `usb`), which stock DTBO entry `fragment@82` re-enables
   with `status = "okay"`.

During boot, `/usb@10E00000` was registered first during `arch_initcall` (`of_platform_default_populate_init`).
Later, when `dwc3-exynos` driver probed in `do_initcalls` and called `of_platform_populate()` on its child,
`of_device_add()` attempted to register `/soc@0/usb@10e00000/usb@0` as `10e00000.usb`, hitting `-EEXIST`.

### Fix

1. Renamed the live child node in `arch/arm64/boot/dts/exynos/exynos990.dtsi` from `usbdrd_dwc3_live: usb@0`
   to `usbdrd_dwc3_live: dwc3@0`. Its bus ID becomes `10e00000.dwc3`, matching standard DWC3 naming and eliminating
   any collision with `usb@*` nodes.
2. In `arch/arm64/boot/dts/exynos/exynos990-c2s.dts`, deleted the `compatible` property from inert anchor shells
   `&udc` and `&usbdrd_phy0` (`/delete-property/ compatible;`). Even when sboot overlay flips their status to `"okay"`,
   `of_platform_bus_create()` skips nodes lacking compatible strings, preventing platform device creation.
3. Preserved overlay safety: label `usbdrd_dwc3` remains on the inert root shell (`/usb@10E00000/dwc3`) and does not
   land on the live node. Kept `dr_mode = "peripheral"`.
4. Dynamic UDC discovery in `/usr/lib/c2s-gadget.sh` (`ls -1 /sys/class/udc | head -n 1`) cleanly binds to `10e00000.dwc3`.

### Host gates

- Added `c2s-rescue/scripts/check-platform-device-collisions.py`: simulates Linux device tree platform device
  population (`of_platform_default_populate`, `dwc3_exynos_probe`, `of_device_make_bus_id`) and checks for duplicate bus IDs.
- Added negative control fixture `c2s-rescue/tests/fixtures/platform-device-collision.diag12.dts` reproducing the diag12 collision.
- Extended `c2s-rescue/scripts/verify.sh` with both the negative control check and verification across all 9 merged DTB variants (0 collisions).

### Build commands (build host)

```sh
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag13-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag13-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag13-out
```

Paired baseline (`CONFIG_C2S_DIAG` off) built into `/tmp/opencode/c2s-diag13-base-out`:

```sh
C2S_DEFCONFIG=c2s_rescue_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag13-base-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag13-base-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag13-base-out
```

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag13, signed) | `/tmp/opencode/c2s-diag13-out/boot.img` | 61 865 984 | `3ec6348cbfb7202e9ae6618dbdfd2c0df289ecccb751d7e768e30a34129f3c5e` |
| Image (diag13) | `/tmp/opencode/c2s-diag13-out/kbuild/arch/arm64/boot/Image` | 12 808 704 | `6e299e8c73e95373a2dce8a17478453374b1f8e64b56dda8a7b429450d32a0a9` |
| DTB | `/tmp/opencode/c2s-diag13-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 968 | `194ea35d91e38201ac2eea44f13c6940d43acba41dfbb91959ab25a1c5b768f2` |
| initramfs | `/tmp/opencode/c2s-diag13-out/work/initramfs.cpio.gz` | 3 369 013 | `cd0445405f92cfdeb9efe15bb01559f50e487c62e1b93ef564063fda91975da8` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag13-base-out/boot.img` | 61 865 984 | `8b3e3de7c6d5bfde5839667b466e4ad02d0666415dd23c938f4d654c2164b11e` |
| Image (baseline) | `/tmp/opencode/c2s-diag13-base-out/kbuild/arch/arm64/boot/Image` | 12 677 632 | `63bb4ec79e920dd34904b757699f702e060ef639c893242e8537612df9d727ec` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 141 968 B == kbuild DTB.

### Host evidence

* `check-c-milestone-bands.py` on diag13 vmlinux: **PASS (20 milestone call site(s) verified)**.
* `check-c-milestone-bands.py --expect-none` on baseline vmlinux: **PASS (no milestone call sites; baseline build)**.
* `check-c2s-paint-paths.py`: **PASS (34 paint-path and console properties verified)**.
* `check-platform-device-collisions.py`: **PASS (0 collisions across 9 merged DTBs)**.
* `fault-injection.sh`: **10 passed, 0 failed**.
* `verify.sh`: **246 passed, 0 failed** on diag13; **246 passed, 0 failed** on baseline.
* Platform device collision negative control: diag12 collision reproduced and detected.

## Build 14 (turn 2026-11-24): diag14 CONFIG_UNIX enablement for passwordless sudo-rs

Resolves issue #5 sudo defect: on hardware boot of diag13, running passwordless sudo:
`rescue@c2s$ sudo -n /bin/id -> sudo: cannot execute '/bin/id': Address family not supported by protocol (os error 97)`

### Root cause proof

sudo-rs 0.2.15 creates a Unix domain socketpair (`AF_UNIX` / `AF_LOCAL`) between its monitor
process and the executed command. In diag13, the kernel defconfig omitted `CONFIG_UNIX=y`
(`# CONFIG_UNIX is not set`), causing `socketpair(AF_UNIX, ...)` syscall to fail with `EAFNOSUPPORT` (errno 97).
Host qemu-user chroot testing previously succeeded because the host kernel handled the syscall with its own `CONFIG_UNIX=y`.

### Fix

1. Enabled `CONFIG_UNIX=y` in both `arch/arm64/configs/c2s_rescue_diag_defconfig` and `arch/arm64/configs/c2s_rescue_defconfig` alongside `CONFIG_NET=y`.
2. Checked AF_UNIX dependencies: sudo-rs requires only `CONFIG_UNIX=y`; dropbear localoptions compile out PAM/passwords and agent forwarding; no unrelated symbols enabled.
3. Added host gate in `c2s-rescue/scripts/verify.sh`:
   - `require_cfg UNIX y` in kernel config checks.
   - Negative control verifying that an unset `CONFIG_UNIX` (`# CONFIG_UNIX is not set`) is detected and rejected.
   - Strengthened functional sudo check in chroot to verify `/usr/bin/sudo -n /bin/id`.

### Build commands (build host)

```sh
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag14-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag14-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag14-out
```

Paired baseline (`CONFIG_C2S_DIAG` off) built into `/tmp/opencode/c2s-diag14-base-out`:

```sh
C2S_DEFCONFIG=c2s_rescue_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag14-base-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag14-base-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag14-base-out
```

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag14, signed) | `/tmp/opencode/c2s-diag14-out/boot.img` | 61 865 984 | `acf4099ee735924d17ced6b99c19180e6d4e74ffbdabc472907c7064dd70449f` |
| Image (diag14) | `/tmp/opencode/c2s-diag14-out/kbuild/arch/arm64/boot/Image` | 12 876 288 | `2de054b2a11e191e5c07d125e0133cb929e69bcd5a69ec2471f9bf1d75be1d69` |
| DTB | `/tmp/opencode/c2s-diag14-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 141 968 | `194ea35d91e38201ac2eea44f13c6940d43acba41dfbb91959ab25a1c5b768f2` |
| initramfs | `/tmp/opencode/c2s-diag14-out/work/initramfs.cpio.gz` | 3 369 013 | `cd0445405f92cfdeb9efe15bb01559f50e487c62e1b93ef564063fda91975da8` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag14-base-out/boot.img` | 61 865 984 | `bc3d5a46db52970d0123f2d60ffe3ecb128d9ac6d89b93743c85a4df87935bea` |
| Image (baseline) | `/tmp/opencode/c2s-diag14-base-out/kbuild/arch/arm64/boot/Image` | 12 743 168 | `c9271e284c396f9767c32730be5e7660acb8944b5beabfc37ffe7a0ead3e4d34` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 141 968 B == kbuild DTB.

### Host evidence

* `check-c-milestone-bands.py` on diag14 vmlinux: **PASS (20 milestone call site(s) verified)**.
* `check-c-milestone-bands.py --expect-none` on baseline vmlinux: **PASS (no milestone call sites; baseline build)**.
* `check-c2s-paint-paths.py`: **PASS (34 paint-path and console properties verified)**.
* `check-platform-device-collisions.py`: **PASS (0 collisions across 9 merged DTBs)**.
* `fault-injection.sh`: **10 passed, 0 failed**.
* `verify.sh`: **249 passed, 0 failed** on diag14; **249 passed, 0 failed** on baseline.
* `CONFIG_UNIX` negative control: unset CONFIG_UNIX rejected by require_cfg.

## Diag15 (Candidate 14): UFS storage bring-up, block device mapping, and safe boot partition flashing

Issue #5 step: provide rescue kernel with access to internal UFS storage, parse GPT partitions without udev, provide host-verified safe boot partition flasher with backup and readback verification, and evaluate reboot-mode.

### Changes

1. **Kernel drivers and defconfig**:
   - Ported Exynos 990 UFS PHY driver (`drivers/phy/samsung/phy-exynos990-ufs.c`), wired into `phy-samsung-ufs.h`, `phy-samsung-ufs.c`, `Makefile`.
   - Ported `exynos990_uic_attr`, `exynos990_ufs_pre_link`, `exynos990_ufs_drvs`, and match entry into `drivers/ufs/host/ufs-exynos.c` (backed by reference z3s mainline kernel 6.12).
   - Enabled `CONFIG_SCSI=y`, `CONFIG_BLK_DEV_SD=y`, `CONFIG_SCSI_UFSHCD=y`, `CONFIG_SCSI_UFSHCD_PLATFORM=y`, `CONFIG_SCSI_UFS_EXYNOS=y`, `CONFIG_PHY_SAMSUNG_UFS=y`, `CONFIG_PARTITION_ADVANCED=y`, `CONFIG_EFI_PARTITION=y`, `CONFIG_REBOOT_MODE=y`, `CONFIG_SYSCON_REBOOT_MODE=y`.
2. **Device tree**:
   - `exynos990.dtsi`: Added fixed-clock stubs (`ufs_unipro`, `ufs_core_clock`), `sysreg_hsi1`, `ufs_0` (HCI, unipro, ufsp reg blocks, SPI 321), and `ufs_0_phy` (PMA, PMU syscon, oscclk).
   - `exynos990-c2s.dts`: Added `ufs_vcc_reg` (GPIO fixed regulator on `gpg1 0` GPIO_ACTIVE_HIGH, matching stock c2s DT `xboot-ldo` anchor), enabled `ufs_0` and `ufs_0_phy`, deleted `compatible` from inert anchor `&ufs` to prevent platform-device collisions.
3. **Initramfs userspace tools**:
   - `/usr/sbin/c2s-blockmap`: scans `/sys/class/block/*/uevent`, resolves `PARTNAME`, creates symlinks in `/dev/block/by-name/<partlabel>`.
   - `/usr/sbin/c2s-flash-boot <image> <expected-sha256>`: strict safeguards: verifies file exists and matches expected sha256; verifies partition exists, resolves to `boot` (refuses any other partition), matches image size; verifies sufficient tmpfs space in `/run` before saving backup; writes with `dd`, executes `sync`, reads back partition and verifies sha256 checksum.
   - `/init`: calls `scan_storage` immediately following gadget initialization to log block device discovery to `/dev/kmsg` and populate blockmap.
4. **Reboot-mode evaluation**:
   - Downstream Samsung Exynos 990 bootloaders (sboot/LK) use vendor `sec_reboot.c` and private SMC/TrustZone calls without a documented `syscon-reboot-mode` DT binding or documented magic value for recovery reboot. Rather than guessing magic numbers, reboot-mode DT node is omitted until hardware/bootloader contract is established, while `CONFIG_SYSCON_REBOOT_MODE=y` is pre-enabled in defconfigs.
5. **Host gates and test suites**:
   - Added `c2s-rescue/scripts/test-flash-boot.sh` testing positive write/backup/readback flow and negative controls (wrong hash, wrong size, non-boot target partition, short readback, insufficient RAM).
   - `verify.sh`: added `CONFIG_SCSI` presence and negative control rejection checks, cpio permissions/ownership for new tools, `/init` storage checks, DT UFS node validation, and execution of `test-flash-boot.sh`.

### Build commands (build host)

```sh
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag15-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag15-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag15-out
```

Paired baseline (`CONFIG_C2S_DIAG` off) built into `/tmp/opencode/c2s-diag15-base-out`:

```sh
C2S_DEFCONFIG=c2s_rescue_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag15-base-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag15-base-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag15-base-out
```

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag15, signed) | `/tmp/opencode/c2s-diag15-out/boot.img` | 61 865 984 | `025ab1e8adde443fb5ba46029f6cd38f3ee55f2626618f1d0f99599c3a7bfa51` |
| Image (diag15) | `/tmp/opencode/c2s-diag15-out/kbuild/arch/arm64/boot/Image` | 13 285 888 | `fb9bd8b27e9ab9d7500b2116f1deef3887692a07cd4245b2cf9dfa1a185393ea` |
| DTB | `/tmp/opencode/c2s-diag15-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 143 360 | `6544b0de6d1fd4ed05836f5a4344a1f15805d95541c9d713acc3d86e4776c502` |
| initramfs | `/tmp/opencode/c2s-diag15-out/work/initramfs.cpio.gz` | 3 371 888 | `8ec27e4575cac1f7d5cb6206c73807ba964740dadaea47bd2432fe08020d4e63` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag15-base-out/boot.img` | 61 865 984 | `472206dbfbd7dd7cf44c879fb2bb8fa016c3281fb1db794c650ca9c1fdd85571` |
| Image (baseline) | `/tmp/opencode/c2s-diag15-base-out/kbuild/arch/arm64/boot/Image` | 13 154 816 | `289af0434ae3c880903f9e223848500a2d60ae0c78092118bcff60cf286f476d` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 143 360 B == kbuild DTB.

### Host evidence

* `check-c-milestone-bands.py` on diag15 vmlinux: **PASS (20 milestone call site(s) verified)**.
* `check-c-milestone-bands.py --expect-none` on baseline vmlinux: **PASS (no milestone call sites; baseline build)**.
* `check-c2s-paint-paths.py`: **PASS (34 paint-path and console properties verified)**.
* `check-platform-device-collisions.py`: **PASS (0 collisions across 9 merged DTBs)**.
* `fault-injection.sh`: **10 passed, 0 failed**.
* `test-flash-boot.sh`: **14 passed, 0 failed** (positive and all negative control tests verified).
* `verify.sh`: **306 passed, 0 failed** on diag15; **306 passed, 0 failed** on baseline.
* `CONFIG_SCSI` negative control: unset CONFIG_SCSI rejected by require_cfg.
* `CONFIG_UNIX` negative control: unset CONFIG_UNIX rejected by require_cfg.

## Diag16 (Candidate 15): Unused clock and power domain disable prevention (`clk_ignore_unused pd_ignore_unused`)

Issue #5 step: hardware measurement of diag15 showed panel console freezing after late cleanup calls "clk: Disabling unused clocks" and "PM: genpd: Disabling unused power domains" (47.7/48.6 s kernel time) because no mainline clock or power domain drivers exist for Exynos 990 to manage active hardware blocks.

### Changes

1. **Kernel defconfigs**:
   - Added `clk_ignore_unused pd_ignore_unused` to `CONFIG_CMDLINE` in `arch/arm64/configs/c2s_rescue_diag_defconfig` and `arch/arm64/configs/c2s_rescue_defconfig`.
   - Kept `console=tty0` as the last `console=` token, preserving preferred framebuffer console routing.
   - Preserved `CONFIG_UNIX=y`, UFS drivers, DT, initramfs, and all other configurations.
2. **Host verification gates**:
   - `verify.sh`: added `require_cmdline_opt` checking `clk_ignore_unused` and `pd_ignore_unused` presence in `CONFIG_CMDLINE` and `verify-image.strings`.
   - Added negative controls testing each option: removing `clk_ignore_unused` or `pd_ignore_unused` from `CONFIG_CMDLINE` causes `require_cmdline_opt` to reject the configuration.

### Build commands (build host)

```sh
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag16-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag16-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag16-out
```

Paired baseline (`CONFIG_C2S_DIAG` off) built into `/tmp/opencode/c2s-diag16-base-out`:

```sh
C2S_DEFCONFIG=c2s_rescue_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag16-base-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag16-base-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag16-base-out
```

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag16, signed) | `/tmp/opencode/c2s-diag16-out/boot.img` | 61 865 984 | `b86972cc51d897613faaa2cec8c3486a7e8c9d8fe9650a49bc8450f8f1f43656` |
| Image (diag16) | `/tmp/opencode/c2s-diag16-out/kbuild/arch/arm64/boot/Image` | 13 285 888 | `e53947ca4626f2d2c824397e7dfe9a877dbbf5ce104c904ded193bc4cf4cac6d` |
| DTB | `/tmp/opencode/c2s-diag16-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 143 360 | `6544b0de6d1fd4ed05836f5a4344a1f15805d95541c9d713acc3d86e4776c502` |
| initramfs | `/tmp/opencode/c2s-diag16-out/work/initramfs.cpio.gz` | 3 371 885 | `eedeeca08a100386671c4ef0ef29efbf3737d5a5bb0bdaaff0ba8af60155ed6e` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag16-base-out/boot.img` | 61 865 984 | `5096babaf157901eda3b5a2a1340c186e4ffaeacfbd29a79786d8f3fec35c0fe` |
| Image (baseline) | `/tmp/opencode/c2s-diag16-base-out/kbuild/arch/arm64/boot/Image` | 13 154 816 | `c45c4cbd42652939d9551137c68e5a8d11c44cddb923a82534168acd22757024` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 143 360 B == kbuild DTB.

### Host evidence

* `check-c-milestone-bands.py` on diag16 vmlinux: **PASS (20 milestone call site(s) verified)**.
* `check-c-milestone-bands.py --expect-none` on baseline vmlinux: **PASS (no milestone call sites; baseline build)**.
* `check-c2s-paint-paths.py`: **PASS (34 paint-path and console properties verified)**.
* `check-platform-device-collisions.py`: **PASS (0 collisions across 9 merged DTBs)**.
* `fault-injection.sh`: **10 passed, 0 failed**.
* `test-flash-boot.sh`: **14 passed, 0 failed** (positive and all negative control tests verified).
* `verify.sh`: **312 passed, 0 failed** on diag16; **312 passed, 0 failed** on baseline.
* `CONFIG_SCSI` negative control: unset CONFIG_SCSI rejected by require_cfg.
* `CONFIG_UNIX` negative control: unset CONFIG_UNIX rejected by require_cfg.
* `clk_ignore_unused` negative control: missing clk_ignore_unused rejected by require_cmdline_opt.
* `pd_ignore_unused` negative control: missing pd_ignore_unused rejected by require_cmdline_opt.

## diag17 candidate: ACPM mailbox, S2MPS19 PMIC & S2DOS05 / s6sy761 touch bring-up (issues #13, #12)

### Changes

1. **#13 ACPM & S2MPS19 PMIC stack**:
   - `drivers/mailbox/exynos-mailbox.c`: added `samsung,exynos990-mbox` match data with INTGR0 doorbell shift 16 and INTMR0/1 masking.
   - `drivers/firmware/samsung/exynos-acpm.c`: added `samsung,exynos990-acpm-ipc` match data (initdata base 0x7000).
   - `drivers/firmware/samsung/exynos990-pmic-probe.c`: smoke test platform driver reading PMIC chip ID and LDO status via ACPM channel 2.
   - `drivers/regulator/s2mps19-acpm-regulator.c`: regulator driver for BUCK4M, LDO2, LDO15, and LDO27 via ACPM channel 2.
   - DT nodes in `exynos990.dtsi`: `apm_mbox_pclk`, `apm_sram@2039000`, `mailbox@15900000`, `acpm_ipc` with `pmic_probe` and `acpm_pmic_regulators`.
2. **#12 Touchscreen & display sub-PMIC**:
   - `drivers/regulator/s2dos05-regulator.c`: standalone I2C regulator driver for S2DOS05 touchscreen rails (LDO2 `tsp_io` 1.8V, LDO3 `tsp_avdd` 3.0V).
   - DT nodes in `exynos990.dtsi`: `tsp_i2c_clk`, USI front-ends `usi_dp` (0x105900c0, mode 3 I2C) and `usi_touch` (0x108d00c0, mode 3 I2C), child HSI2C nodes with S2DOS05 at 0x60 and Samsung Y79A / s6sy761 touch at 0x48.
   - `exynos990-c2s.dts`: deleted `compatible` property on root inert shells `&hsi2c_4` and `&hsi2c_15` to prevent platform device name collisions.
3. **Verification gates**:
   - Config gates and negative controls for `CONFIG_EXYNOS_ACPM_PROTOCOL`, `CONFIG_REGULATOR_S2MPS19_ACPM`, `CONFIG_REGULATOR_S2DOS05`, `CONFIG_TOUCHSCREEN_S6SY761`.
   - DT gates and negative controls for mailbox, ACPM, S2DOS05, and touch nodes.

### Build commands (build host)

```sh
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag17-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag17-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag17-out
```

Paired baseline (`CONFIG_C2S_DIAG` off) built into `/tmp/opencode/c2s-diag17-base-out`:

```sh
C2S_DEFCONFIG=c2s_rescue_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag17-base-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag17-base-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag17-base-out
```

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag17, signed) | `/tmp/opencode/c2s-diag17-out/boot.img` | 61 865 984 | `5b0fa89a052ed2f217327adfaf7d2ddc2ab9ea5c41faad6cdbfe86dbea4793d8` |
| Image (diag17) | `/tmp/opencode/c2s-diag17-out/kbuild/arch/arm64/boot/Image` | 13 353 472 | `1b6fec17080e72bf44c2d724aa46525fdf91dc4ac5a011ca47d39a8646a43420` |
| DTB | `/tmp/opencode/c2s-diag17-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 147 258 | `a733fb3c20a5be28e74f025aef5480950678166309c7c5be2ce1bcdca9838140` |
| initramfs | `/tmp/opencode/c2s-diag17-out/work/initramfs.cpio.gz` | 3 371 885 | `eedeeca08a100386671c4ef0ef29efbf3737d5a5bb0bdaaff0ba8af60155ed6e` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag17-base-out/boot.img` | 61 865 984 | `15a68001914c603bcba87347368a45c79c67528e702e880422ff6271cf98cb41` |
| Image (baseline) | `/tmp/opencode/c2s-diag17-base-out/kbuild/arch/arm64/boot/Image` | 13 156 864 | `7c4525a851e36ff5d9d49a5c8a17b9e936c8b11f4a043ae780223fdd5dc89794` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 147 258 B == kbuild DTB.

### Host evidence

* `verify.sh`: **337 passed, 0 failed** on diag17; **337 passed, 0 failed** on baseline.
* `CONFIG_EXYNOS_ACPM_PROTOCOL` negative control: unset symbol rejected.
* `CONFIG_REGULATOR_S2MPS19_ACPM` negative control: unset symbol rejected.
* `CONFIG_REGULATOR_S2DOS05` negative control: unset symbol rejected.
* `CONFIG_TOUCHSCREEN_S6SY761` negative control: unset symbol rejected.
* DT ACPM negative control: missing acpm-ipc node rejected.
* DT touch negative control: missing s6sy761 node rejected.
* `check-platform-device-collisions.py`: **0 name collisions across all 9 merged DTBs**.

## diag18 candidate: DRM/KMS simpledrm display & Panfrost Mali-G77 GPU bring-up (issues #9, #10)

### Changes

1. **#9 Display for Wayland (DRM/KMS simpledrm)**:
   - `drivers/gpu/drm/sysfb/simpledrm.c`: added 64-bit DMA mask `dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64))` in `simpledrm_probe()` to support high-memory framebuffer mapping.
   - `arch/arm64/boot/dts/exynos/exynos990-c2s.dts`: in `chosen`, added `#address-cells = <2>; #size-cells = <1>; ranges;` and attached `memory-region = <&cont_splash_mem>;` to `framebuffer0` (resolves simple-framebuffer error -22 "No memory resource").
   - `c2s_rescue_defconfig` & `c2s_rescue_diag_defconfig`: enabled `CONFIG_DRM=y`, `CONFIG_DRM_SIMPLEDRM=y`, `CONFIG_DRM_FBDEV_EMULATION=y`, and disabled `CONFIG_FB_SIMPLE`.
2. **#10 GPU Mali-G77 (Panfrost & Exynos 990 G3D power domain)**:
   - `drivers/gpu/drm/panfrost/panfrost_features.h` & `panfrost_issues.h`: defined G77 feature and issue flags matching G57 with revision aliases for `r0p0` and `r0p1`.
   - `drivers/gpu/drm/panfrost/panfrost_gpu.c`: added `GPU_MODEL(g77, 0x9000, GPU_REV(g77, 0, 0), GPU_REV(g77, 0, 1))`.
   - `drivers/pmdomain/samsung/exynos-pm-domains.c`: added `exynos990_cfg` (`local_pwr_cfg = 0x1`) and compatible `"samsung,exynos990-pd"` matching downstream PMU hardware.
   - `arch/arm64/boot/dts/exynos/exynos990.dtsi`: added fixed-clock `gpu_clk` (800MHz), power domain `pd_g3d: power-domain@15862200`, and GPU node `gpu: gpu@18500000` (`arm,mali-valhall-jm`, IRQs 301, 302, 300).
   - `c2s_rescue_defconfig` & `c2s_rescue_diag_defconfig`: enabled `CONFIG_DRM_PANFROST=y`.
3. **Verification gates**:
   - Config gates and negative controls for `CONFIG_DRM`, `CONFIG_DRM_SIMPLEDRM`, `CONFIG_DRM_FBDEV_EMULATION`, and `CONFIG_DRM_PANFROST`.
   - DT gates and negative controls for `simple-framebuffer` (`memory-region`), `power-domain@15862200`, and `gpu@18500000`.

### Build commands (build host)

```sh
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag18-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag18-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag18-out
```

Paired baseline (`CONFIG_C2S_DIAG` off) built into `/tmp/opencode/c2s-diag18-base-out`:

```sh
C2S_DEFCONFIG=c2s_rescue_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag18-base-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag18-base-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag18-base-out
```

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag18, signed) | `/tmp/opencode/c2s-diag18-out/boot.img` | 61 865 984 | `8276b052977aa439de2173e7fbdd8b7ca768e1d7528fe6be7b4e5000904840a0` |
| Image (diag18) | `/tmp/opencode/c2s-diag18-out/kbuild/arch/arm64/boot/Image` | 14 019 072 | `a04fb29b1412e6b5bf749cd64564c0b1c4719efb236daae26d0ac2d011ba8e98` |
| DTB | `/tmp/opencode/c2s-diag18-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 147 957 | `77a936acf1987a29d990cf7068402b69fa4433d17eedcca1db9f8930e8b827a3` |
| initramfs | `/tmp/opencode/c2s-diag18-out/work/initramfs.cpio.gz` | 3 371 885 | `eedeeca08a100386671c4ef0ef29efbf3737d5a5bb0bdaaff0ba8af60155ed6e` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag18-base-out/boot.img` | 61 865 984 | `d7ce5a1219c7a79942594f9a820b6dca14a0c690818e2d2676fd222154634e24` |
| Image (baseline) | `/tmp/opencode/c2s-diag18-base-out/kbuild/arch/arm64/boot/Image` | 13 888 000 | `067f761bb74a4f04a97805a225bfa3e279545857f0da5a13494de3d1eb020027` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 147 957 B == kbuild DTB.

### Host evidence

* `verify.sh`: **351 passed, 0 failed** on diag18; **351 passed, 0 failed** on baseline.
* `CONFIG_DRM` negative control: unset symbol rejected.
* `CONFIG_DRM_SIMPLEDRM` negative control: unset symbol rejected.
* `CONFIG_DRM_PANFROST` negative control: unset symbol rejected.
* DT simple-framebuffer memory-region negative control: missing memory-region rejected.
* DT GPU node negative control: missing gpu@18500000 node rejected.
* DT G3D power-domain negative control: missing power-domain@15862200 node rejected.
* `check-platform-device-collisions.py`: **0 name collisions across all 9 merged DTBs**.

## diag19 candidate: Touch axis initialization & probe, GPU supply & OPP table, PMIC chip-id documentation (PACKAGE 2, issues #17, #18, #19)

### Changes

1. **#17 Touchscreen (s6sy761 & pinctrl)**:
   - `drivers/input/touchscreen/s6sy761.c`:
     - Initialized single-touch (`ABS_X`/`Y`) and multi-touch (`ABS_MT_POSITION_X`/`Y`) abs parameters from panel dimensions.
     - Called `touchscreen_parse_properties` for both single and multi-touch to eliminate `"the axis have not been set"` warning.
     - Enabled sensing at power-on (`S6SY761_SENSE_ON`) in `s6sy761_power_on` so touch interrupts fire without requiring userspace input device open.
     - Added dynamic-debug/info logging across initialization, open/close, and IRQ handling.
   - `arch/arm64/configs/c2s_rescue_diag_defconfig` & `c2s_rescue_defconfig`: enabled `CONFIG_DYNAMIC_DEBUG=y`.
   - `arch/arm64/boot/dts/exynos/exynos990-c2s.dts`: added `attn_irq: attn-irq-pins` (`gpa1-0`, `EXYNOS_PIN_FUNC_EINT`, pull none, drive LV1) in `&pinctrl_alive` and attached `pinctrl-names = "default"; pinctrl-0 = <&attn_irq>;` to `&touchscreen`.
   - `c2s-rescue/initramfs/usr/sbin/c2s-touch-probe`: added safe, read-only diagnostic tool (dmesg, /proc/interrupts, regulator states, gpio debugfs, i2c bus scan, input devices).
2. **#18 GPU Mali-G77 (G3D supply regulator, OPP table, devfreq handling)**:
   - `arch/arm64/boot/dts/exynos/exynos990-c2s.dts`:
     - Added fixed-regulator `g3d_reg: regulator-g3d` matching `s_vdd_buck1` (800000 uV, always-on, boot-on).
     - Added `gpu_opp_table: opp-table-gpu` (`operating-points-v2`) with 8 frequencies (156 to 832 MHz) and 800000 uV supply matching stock `gpu_dvfs_table`.
     - Attached `mali-supply = <&g3d_reg>;` and `operating-points-v2 = <&gpu_opp_table>;` to `&gpu` (`gpu@18500000`).
   - `drivers/gpu/drm/panfrost/panfrost_device.c`: made devfreq and regulator initialization non-fatal, ensuring GPU probe succeeds even if dynamic frequency scaling encounters errors.
   - `c2s-rescue/initramfs/usr/sbin/c2s-gpu-probe`: added safe, read-only GPU probe script (dmesg, /sys/class/devfreq, /dev/dri/renderD128, /sys/class/drm, regulators).
3. **#19 PMIC S2MPS19 Chip-ID Offset Verification**:
   - `drivers/firmware/samsung/exynos990-pmic-probe.c`: documented register offset `0x00` (`S2MPS19_REG_PMICID`) against z3s bring-up records (`SESSION3_FINDINGS.md` §3.6) and Samsung S2M PMIC architecture.
   - `c2s-rescue/docs/evidence.md`: added detailed verification section confirming offset `0x00` on physical hardware (`ACPMTEST: OK chipid=0x00` / `0x03`).
4. **Verification gates**:
   - Config gate and negative control for `CONFIG_DYNAMIC_DEBUG`.
   - Initramfs archive gates and negative controls for `/usr/sbin/c2s-touch-probe` and `/usr/sbin/c2s-gpu-probe` (mode 0755, root-owned).
   - DT gates and negative controls for `touchscreen` (`pinctrl-0`, `touchscreen-size-x`, `touchscreen-size-y`), `gpu` (`mali-supply`, `operating-points-v2`), and `regulator-g3d` (`s_vdd_buck1`, `opp-table-gpu`).
   - Source code gates and negative controls for `S2MPS19_REG_PMICID` definition and `evidence.md` PMIC documentation.

### Build commands (build host)

```sh
C2S_DEFCONFIG=c2s_rescue_diag_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag19-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag19-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag19-out
```

Paired baseline (`CONFIG_C2S_DIAG` off) built into `/tmp/opencode/c2s-diag19-base-out`:

```sh
C2S_DEFCONFIG=c2s_rescue_defconfig \
C2S_OUTDIR=/tmp/opencode/c2s-diag19-base-out \
C2S_AUTHORIZED_KEYS="$HOME/.ssh/id_ed25519.pub" \
c2s-rescue/scripts/build.sh

C2S_AVB_KEY=/tmp/opencode/avb-key/avb_key.pem \
c2s-rescue/scripts/package-bootimg.sh --outdir /tmp/opencode/c2s-diag19-base-out

c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-diag19-base-out
```

### Artifacts (build host)

| artifact | path | size (B) | sha256 |
|---|---|---|---|
| boot.img (diag19, signed) | `/tmp/opencode/c2s-diag19-out/boot.img` | 61 865 984 | `ee450e7348b48be712aa7844bb820ed0840d48cfeb2c4451b1bbc285424e31c3` |
| Image (diag19) | `/tmp/opencode/c2s-diag19-out/kbuild/arch/arm64/boot/Image` | 14 275 072 | `bb3d304604a9d8394a071791150e1f2b94774c927a87c71f658d584a89656210` |
| DTB | `/tmp/opencode/c2s-diag19-out/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | 149 113 | `d960900a96ed64b86fdc01efae65a8c42cfdf0b753dca46aa132696697d31f89` |
| initramfs | `/tmp/opencode/c2s-diag19-out/work/initramfs.cpio.gz` | 3 373 089 | `b13ffdec751c55fbd2801b885d6d93df285d72c1ec442f7f0e3c2cb83e91fc20` |
| boot.img (baseline, signed) | `/tmp/opencode/c2s-diag19-base-out/boot.img` | 61 865 984 | `da394b07c52c1ea93401df4da4990f2c67ccda43fe62f9bf7b250bd377b22556` |
| Image (baseline) | `/tmp/opencode/c2s-diag19-base-out/kbuild/arch/arm64/boot/Image` | 14 141 952 | `1a86f76c7c2fa6adc0713814ede657f0acb1f6ab7402c9e493480faae6087c3b` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 149 113 B == kbuild DTB.

### Host evidence

* `verify.sh`: **380 passed, 0 failed** on diag19; **380 passed, 0 failed** on baseline.
* `CONFIG_DYNAMIC_DEBUG` negative control: unset symbol rejected.
* `c2s-touch-probe` negative control: missing binary rejected.
* `c2s-gpu-probe` negative control: missing binary rejected.
* DT touch pinctrl negative control: missing `attn-irq` pinctrl rejected.
* DT touch size negative control: missing `touchscreen-size-x` rejected.
* DT GPU mali-supply negative control: missing `mali-supply` rejected.
* DT GPU OPP negative control: missing `operating-points-v2` rejected.
* DT G3D regulator negative control: missing `s_vdd_buck1` rejected.
* `S2MPS19_REG_PMICID` negative control: missing definition rejected.
* `evidence.md` PMIC documentation negative control: missing documentation rejected.
* `check-platform-device-collisions.py`: **0 name collisions across all 9 merged DTBs**.

### Hardware Measurements (diag19 on c2s, Package 3)

* **Flash & Boot Recovery**:
  - Pre-flash backup: `~/phone-second-life-data/mb008/backups/2026-11-25-1309-pre-diag19/boot-pre.img` (sha256 `8276b052977aa439de2173e7fbdd8b7ca768e1d7528fe6be7b4e5000904840a0`, host == device).
  - Image flashed: `/run/diag19-boot.img` sha256 `ee450e7348b48be712aa7844bb820ed0840d48cfeb2c4451b1bbc285424e31c3`.
  - `/usr/sbin/c2s-flash-boot /run/diag19-boot.img ee450e73...`: OK (rc=0).
  - Recovery hash unchanged: `4d5f4b584a30a490a4235ad5d19fb8a4f4662193db88b10c6efce66c49d34982`.
  - Reboot via `busybox reboot -f`: USB gadget (`1d6b:0104`) re-enumerated, host IP set on `enxaa6f4b34bcd0` (`192.168.42.2/24`), SSH restored.
* **Test (a) Kernel & Identity**:
  - `uname -r`: `7.1.0-rc4-c2s-rescue`.
  - Boot partition hash: `ee450e7348b48be712aa7844bb820ed0840d48cfeb2c4451b1bbc285424e31c3` (diag19 verified).
  - `sudo -n /bin/id` as rescue: `uid=0(root) gid=0(root) groups=0(root)`.
  - dmesg errors: 0 Oops, 0 panic, 0 BUG, 0 WARNING.
* **Test (b) ACPM & Regulators (#19)**:
  - ACPMTEST log: `exynos990-pmic-probe firmware:power-management:pmic-probe: ACPMTEST: OK chipid=0x00`, `LDO2(vqmmc)=0x2c LDO15(vmmc)=0x2e (en=bits7:6, 0xC0=on)`.
  - Chip ID: register offset `0x00` (`S2MPS19_REG_PMICID`) confirmed on hardware; proves AP -> mailbox -> APM -> SPEEDY -> S2MPS19 path end-to-end.
  - Regulators: `ufs-vcc` enabled; `tsp_io` enabled (1.8V); `tsp_avdd` enabled (3.0V); `s_vdd_buck1` (800mV); `vqmmc`, `vmmc`, `VDD_WIFI_0P95`, `wacom_avdd` disabled.
* **Test (c) GPU Subsystem (#18)**:
  - `c2s-gpu-probe`: Mali-G77 (id `0x9080`), clock rate 800MHz, Panfrost 1.6.0 on minor 1.
  - Panfrost dmesg: dummy regulator message eliminated; supply linked to `s_vdd_buck1`.
  - Devfreq (`18500000.gpu`): `cur_freq=156000000`, `governor=simple_ondemand`, available frequencies: 156, 260, 377, 455, 572, 702, 800, 832 MHz.
  - DRM nodes: `/dev/dri/card0` (simpledrm), `/dev/dri/card1` (panfrost), `/dev/dri/renderD128` (panfrost, major 226, minor 128).
  - Render proof blocker: Missing arm64 userspace Mesa/kmscube/vulkaninfo binaries and shared libraries in rescue initramfs.
* **Test (d) Touch Subsystem (#17)**:
  - `c2s-touch-probe`: S2DOS05 (EN=0x19); s6sy761 (devid=0x79a1, axes X 0..1439, Y 0..3087 configured, "axis have not been set" warning gone).
  - Input device: `/dev/input/event0` (`s6sy761`).
  - Interrupt count: boot=2; IRQ before armed capture=3; IRQ after armed capture=4 (gpa1 0 Level s6sy761_irq).
  - Driver state machine: `suspended` when idle; switches to `s6sy761 1-0048: input_open: sensing ON (ret=0)` when `/dev/input/event0` is opened; switches to `s6sy761 1-0048: input_close: sensing OFF` when closed.
  - Live capture: `/dev/input/event0` held open exclusively during armed capture windows (20s baseline and 40s live window). 0 raw bytes read, 0 events decoded, no X/Y coordinates received. IRQ count remained steady during armed windows and only transitioned upon SMBus sense toggling.
  - Hardware status: I2C bus (HSI2C @ 108d0000), power rails (tsp_io 1.8V, tsp_avdd 3.0V via S2DOS05), Y79A devid (0x79a1), axes scaling, and interrupt line connectivity to the AP GIC are confirmed operational. Physical finger contact on glass did not trigger touch packets in rescue mode.

## Candidate diag20 (Package 4, Issue #8): Debian arm64 rootfs + switch_root initramfs path

### Summary
Package 4 preparation:
1. `c2s-rescue/scripts/build-rootfs.sh`: reproducible Debian arm64 rootfs builder with Phosh, phoc, squeekboard, Mesa, NetworkManager, openssh-server, passwordless sudo for user `rescue` (uid 1000), key-only sshd, auto-login into Phosh, stable host keys, ext4 labeled `c2s-root` <= 8 GB.
2. Kernel config additions: `CONFIG_EXT4_FS=y`, `CONFIG_EXT4_FS_POSIX_ACL=y`, `CONFIG_CGROUPS=y`, `CONFIG_CGROUP_PIDS=y`, `CONFIG_CGROUP_DEVICE=y`, `CONFIG_CGROUP_CPUACCT=y`, `CONFIG_CGROUP_SCHED=y`, `CONFIG_AUTOFS_FS=y`, `CONFIG_SECCOMP=y`.
3. Initramfs `/init` switch_root path: detects `/dev/block/by-name/userdata` with label `c2s-root` and `/sbin/init`, brings up USB gadget (NCM/RNDIS) + SSH rescue first, then mounts rootfs and invokes `switch_root`. Boot menu defaults to rootfs after 20s timeout; volume-down selects rescue.

### Verification
* `verify.sh`: **409 passed, 0 failed**.
* Negative control `CONFIG_EXT4_FS`: unset symbol rejected.
* Negative control `CONFIG_CGROUPS`: unset symbol rejected.
* Negative control `switch_root`: missing switch_root in init rejected.
* Negative control `build-rootfs.sh`: missing builder rejected.

---

## Candidate diag21 (Issue #20): UFS SYSTEM_BUS_FATAL_ERROR (0x20000) Fix

### Problem
During sustained heavy writes (~6.4 GiB `c2s-root.img` write to `/dev/block/by-name/userdata` / `sda32`), the write hung in final fsync with `blk_mq_get_tag` starved in D-state.
Kernel log reported:
`ufshcd_check_errors saved_err 0x20000` (= `SYSTEM_BUS_FATAL_ERROR`, bit 17 of `REG_INTERRUPT_STATUS`), followed by `eh_fatal`. The error handler never completed.

### Analysis against Reference Driver (`ref/z3s-mainline-linux` & upstream Exynos)
1. **Write Booster Flush Quirk**:
   Samsung UFS 3.0 devices (`KLUEG8UHDB-C2D1` rev 0090) engage Write Booster buffer flush by default unless `UFSHCI_QUIRK_SKIP_MANUAL_WB_FLUSH_CTRL` is set. During massive raw writes (~6.4 GiB stream), the WB buffer saturates and the host controller attempts manual buffer flush concurrently with continuous DMA write bursts, resulting in `SYSTEM_BUS_FATAL_ERROR` on the AXI bus.
2. **Clear Request List Quirk**:
   When the fatal error occurs, `ufshcd_err_handler` attempts `ufshcd_utrl_clear()` to abort pending requests. On Exynos controllers, register polarity is inverted, requiring `UFSHCI_QUIRK_BROKEN_REQ_LIST_CLR`. Without this quirk, slot clear operations fail, freezing the error recovery thread and starving all blk-mq tags.
3. Upstream Exynos drivers (`exynos_ufs_drvs`, `gs101_ufs_drvs`, and `exynos9820_ufs_drvs`) all include both `UFSHCI_QUIRK_SKIP_MANUAL_WB_FLUSH_CTRL` and `UFSHCI_QUIRK_BROKEN_REQ_LIST_CLR`.

### Implementation
Updated `drivers/ufs/host/ufs-exynos.c` (`exynos990_ufs_drvs.quirks`):
* Added `UFSHCI_QUIRK_SKIP_MANUAL_WB_FLUSH_CTRL`
* Added `UFSHCI_QUIRK_BROKEN_REQ_LIST_CLR`

### Artifacts (build host, `/tmp/opencode/c2s-diag21-out`)

| Artifact | Size | sha256 |
|---|---|---|
| `boot.img` (diag21, signed) | 61,865,984 B | `3de2fe94bc66e2c58d5d586e376e9cbf249bcff001b0618289a4b7a30f38d39f` |
| `Image` (diag21) | 15,092,224 B | `6dc32888364f349e83d8e8612dee730aa8dfdfb77a3a60d6792037968d53c69f` |
| `DTB` | 149,113 B | `d960900a96ed64b86fdc01efae65a8c42cfdf0b753dca46aa132696697d31f89` |
| `initramfs` | 3,374,131 B | `d12fb0499363bb9f5c262b5f14380deedc52c8f0f7f804b8fbd8bfdd6e1e90c8` |

AVB: `SHA256_RSA4096`, rollback index **13**, Samsung DT table `d7b7ab1e` ok, FDT 149,113 B == kbuild DTB.

### Verification
* `verify.sh`: **411 passed, 0 failed**.
* Gate: `UFSHCI_QUIRK_SKIP_MANUAL_WB_FLUSH_CTRL` present in `exynos990_ufs_drvs`.
* Negative control: missing `UFSHCI_QUIRK_SKIP_MANUAL_WB_FLUSH_CTRL` rejected.
* Gate: `UFSHCI_QUIRK_BROKEN_REQ_LIST_CLR` present in `exynos990_ufs_drvs`.
* Negative control: missing `UFSHCI_QUIRK_BROKEN_REQ_LIST_CLR` rejected.

