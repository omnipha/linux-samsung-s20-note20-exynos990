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

Consequence for the DTS: the last `memory@80000000` block must be
`<0x8 0x80000000 0x2 0x80000000>` (size 0x280000000 = 10 GiB,
top = 0xb00000000). The shipped `exynos990-c2s.dts` had
`0x2 0x7e800000`; fixed in this branch (see
`arch/arm64/boot/dts/exynos/exynos990-c2s.dts`).

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

## Kernel / initramfs build evidence

Environment (also in `build-record.txt` / `build.log`, produced by
`c2s-rescue/scripts/build.sh`):

| Item | Value |
|---|---|
| git rev | `13e4b531bcc17f85f3de3b75da1cc16569a0f2a4` |
| host | Linux 7.0.0-42-generic x86_64 |
| cross gcc | aarch64-linux-gnu-gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| make / gzip / cpio / dtc | 4.4.1 / 1.14 / GNU 2.15 / DTC 1.7.2 |
| SOURCE_DATE_EPOCH | 1794605179 (git commit timestamp, pinned) |

External dependencies (verified by sha256 in `build.sh`, never
committed to the repo):

| File | sha256 |
|---|---|
| dropbear-2026.94.tar.bz2 | `e098034a843699200c8c977a991fff73159735bf795d5f72ef672c41a6b1ae81` |
| busybox-static 1.37.0-7ubuntu1 arm64 .deb | `fcf50794faf920455895d7ef103d1c54b9ebf7f18d2e52982dbf3903b7769592` |
| extracted `/usr/bin/busybox` | `c2f279d1d5640a0f327890d41cad594c0f059f3fed3f96dd72fdcc4f5e18ec02` |

Artifacts (byte-identical across two consecutive builds):

| Artifact | Size | sha256 |
|---|---|---|
| `Image` | 11,432,448 B | `63d6b45dcc60fb56c958e9c7158110081f22189690b578c00e8e650d9fd78307` |
| `exynos990-c2s.dtb` | 38,288 B | `4e4e5702ce715ff4d8c0bc066a0c8d66a039473fdea49c423bc4d4cc8ad79b0f` |
| `initramfs.cpio.gz` | 2,211,972 B | `c84d00ec2981bc47b649a212d6d47c8d26ed13f0e082e24536fdc87fd8f581ff` |
| unpacked `initramfs.cpio` | | `df3e43d6fff5b0fc337a82704e7290c574b9c9fb225dc1a68e0500c24d5611fb` |

Reproducibility measures (all proven by a second full build producing
the same hashes):

- `SOURCE_DATE_EPOCH` = commit timestamp feeds `gen_initramfs.sh -d`
  (pinned cpio mtimes) and `KBUILD_BUILD_TIMESTAMP` (pinned
  `UTS_VERSION` in the Image).
- `KBUILD_BUILD_VERSION=1` pins the `#N` build counter.
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

`c2s-rescue/scripts/verify.sh` runs 75 checks, all passing on the
artifacts above:

- kernel config: ~35 required `=y` symbols, `CONFIG_MODULES` unset,
  `CONFIG_INITRAMFS_SOURCE` pointing at the staged archive.
- initramfs: cpio listing contains `dev/console` as char 5:1,
  `/init` + busybox + dropbear + rescue config present, `/init`
  parses under busybox ash and dash.
- secrets: tracked rescue sources and the built archive contain no
  serials and no private key material.
- DTB: framebuffer node, `usb@10e00000`, exynos990 usbdrd-phy
  compatible, full memory coverage up to 0xb00000000, dummy
  regulators present.
- Image: ARM64 magic (`41 52 4d 64` at offset 0x38), no build-host
  paths inside the binary, embedded initramfs byte-identical to the
  standalone archive.
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
