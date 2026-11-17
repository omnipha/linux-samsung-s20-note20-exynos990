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

`c2s-rescue/scripts/verify.sh` - 79 checks, all passing:

| Group | Checks |
|---|---|
| artifacts | Image, DTB, initramfs, build-record.txt, build.log exist and are non-empty |
| kernel config | ~35 required `=y` symbols, `CMDLINE_FORCE=y`, `MODULES` unset, pinned `LOCALVERSION`, `LOCALVERSION_AUTO` unset, `INITRAMFS_SOURCE` resolves to the staged archive, staged copy identical, embedded copy identical |
| image hygiene | no build-host path inside the `Image`, release string pinned without `git describe` suffix |
| initramfs | cpio listing has `dev/console` as char 5:1, `/init` executable, busybox/dropbear present, passwd/shells/rescue.conf content, `/init` parses under busybox ash and dash |
| secret scan | no serial/private-key patterns in tracked rescue sources or in the archive |
| DTB | framebuffer node, `usb@10e00000`, exynos990 usbdrd-phy compatible, memory up to 0xb00000000, dummy regulators |
| kernel image | ARM64 magic `41 52 4d 64` at offset 0x38, `file(1)` agrees |
| static binaries | busybox and dropbear are static aarch64 ELF, dropbear has no `NEEDED` |
| smoke test | dropbear starts, pubkey login works, unlisted key rejected, password auth refused, telnet gate enforced |

The smoke test runs the exact dropbear binary that is shipped, on the
build host, via qemu-user/binfmt. It uses passwordless sudo when
available (login user `root`, device-faithful) and otherwise falls back
to the invoking user; both paths exercise the same authentication
code.

## Reproduce

```sh
git checkout feature/issue-1-c2s-minimal-kernel-rescue
./c2s-rescue/scripts/build.sh --outdir /tmp/opencode/c2s-out
./c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-out
```
