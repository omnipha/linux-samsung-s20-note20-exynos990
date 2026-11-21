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
