# c2s rescue: boot instructions and open points (issue #1)

## What this branch delivers

- `arch/arm64/configs/c2s_rescue_defconfig` - minimal ARM64 config
  for the c2s board (Exynos990). No modules, no distro baggage; USB
  gadget (configfs NCM/RNDIS/ACM), DWC3 + exynos990 PHY glue, simple
  framebuffer console, gpio-keys, devtmpfs, IKCONFIG.
- `arch/arm64/boot/dts/exynos/exynos990-c2s.dts` - the c2s board DT.
  Fixed in this branch: the last memory block now matches the measured
  RAM end at `0xb00000000`.
- `c2s-rescue/initramfs/` - PID 1 (`/init`) plus its `/etc` config and
  `rescue-telnet` helper.
- `c2s-rescue/dropbear/localoptions.h` - build options that compile
  out password/PAM auth (public key only).
- `c2s-rescue/scripts/build.sh` - builds `Image`, `exynos990-c2s.dtb`
  and the initramfs archive outside the repo.
- `c2s-rescue/scripts/verify.sh` - 75 host-side verification gates.
- `c2s-rescue/docs/evidence.md` - evidence log and artifact hashes.

## Building

```sh
./c2s-rescue/scripts/build.sh --outdir /tmp/opencode/c2s-out
./c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-out
```

Requirements on the build host: `aarch64-linux-gnu-gcc`, GNU make,
gzip, cpio, dtc, plus two external binary inputs whose sha256 are
checked by the script (dropbear tarball and the Ubuntu arm64
busybox-static package; see `evidence.md`). Nothing from those
packages is committed to this repo.

Output (per build):

| Artifact | Notes |
|---|---|
| `$OUT/kbuild/arch/arm64/boot/Image` | kernel with the initramfs built in |
| `$OUT/kbuild/arch/arm64/boot/dts/exynos/exynos990-c2s.dtb` | board DTB |
| `$OUT/work/initramfs.cpio.gz` | same archive that is embedded |
| `$OUT/build-record.txt`, `$OUT/build.log` | sizes, sha256, commands |

Adding an SSH key (before or after the build):

```sh
C2S_AUTHORIZED_KEYS=~/.ssh/id_ed25519.pub \
  ./c2s-rescue/scripts/build.sh --outdir /tmp/opencode/c2s-out
```

Without it the archive ships **without** `/root/.ssh/authorized_keys`
and dropbear is never started by `/init` (it logs
"no /root/.ssh/authorized_keys: dropbear NOT started"). The key can
also be added later by mounting the rescue system from an already
running rescue instance.

## Booting (manual, not performed here)

The build produces the two artefacts the vendor bootloader consumes:

```
Image                     -> the kernel
exynos990-c2s.dtb         -> the DTB for the (yet unknown) container
```

**No boot or flash attempt was made as part of this issue.** This is
deliberate: the packaging format the stock bootloader expects for a
mainline `Image` + DTB pair (and how to place them without touching
the installed vendor system) is unknown - see open points below. A
boot attempt therefore requires a separate, explicit task with its own
risk assessment, including a recovery path (download mode / Odin).

## Rescue system behaviour at boot

1. `/init` mounts proc, sysfs, devtmpfs, devpts, configfs, tmpfs.
2. It creates the configfs gadget `c2s` with three functions -
   `ncm.usb0`, `rndis.usb1`, `acm.usb2` - each pinned to a fixed
   interface name (`ncm%d`, `rndis%d`) so host-side naming is
   predictable, then binds it to the DWC3 UDC (`10e00000.dwc3`).
3. Static addresses (both up simultaneously):

   | Link | Rescue side | Host side |
   |---|---|---|
   | NCM (Linux/macOS) | 192.168.42.1/24 | 192.168.42.2 |
   | RNDIS (Windows) | 192.168.62.1/24 | 192.168.62.2 |

4. If `/root/.ssh/authorized_keys` is non-empty, dropbear starts on
   `192.168.42.1:22` and `192.168.62.1:22` (pubkey only).
5. A shell on the framebuffer console is kept alive and is respawned
   if it dies; dropbear and (if enabled) telnetd are supervised the
   same way.
6. Telnet stays off unless *both* `RESCUE_ENABLE_TELNET="1"` in
   `/etc/rescue.conf` **and** the `/etc/enable-telnet` marker file are
   present. From an SSH session: `rescue-telnet arm` /
   `rescue-telnet disarm`.

All addresses/ports are configurable in `/etc/rescue.conf`
(`RESCUE_NCM_ADDR`, `RESCUE_RNDIS_ADDR`, `RESCUE_PREFIX`,
`RESCUE_SSH_PORT`, `RESCUE_TELNET_PORT`, `RESCUE_ENABLE_TELNET`).

## Host-only evidence and verification

Everything asserted about the device was obtained with read-only ADB;
see `evidence.md`. The verification gates in `verify.sh` cover kernel
config, initramfs content, DTB sanity, image format, static linkage,
secret scanning and a functional smoke test of the exact dropbear
binary that ships in the initramfs (key login works, unlisted key
rejected, password auth refused). Two consecutive builds produce
byte-identical artifacts.

## Open points (out of scope for issue #1)

These are known and documented rather than solved:

1. **Bootloader packaging unknown.** The stock bootloader expects a
   Samsung container image for kernel+DTB; how a mainline `Image` +
   `exynos990-c2s.dtb` must be packaged (or whether a separate
   partition/boot slot can be used) has not been determined. No boot
   attempt was made.
2. **No UART/console binding.** The vendor DT's
   `samsung,exynos-uart` compatible has no mainline driver for
   exynos990, so there is no serial console; rescue relies on the
   framebuffer console (`console=tty0`) and USB.
3. **No exynos990 PMIC driver.** The DTS carries vendor regulator
   nodes that mainline does not drive; USB-related rails are backed
   by placeholder `regulator-dummy` supplies, which is enough for a
   gadget-only rescue but not for a complete power-management story.
4. **USB3/SuperSpeed path.** Vendor DT declares
   `maximum-speed = "super-speed-plus"`; the mainline dwc3-exynos +
   exynos990 usbdrd-phy combination has not been exercised at
   SuperSpeed, so the gadget is expected to enumerate at USB2 speeds
   initially. Also, SS tuning/lane bring-up may need DT work.
5. **Host-side driver support.** NCM/RNDIS work on stock kernels; a
   Windows host may need the RNDIS path first (hence both functions
   are created).
6. **No CI.** The repository has no GitHub workflows; `verify.sh` is
   the local equivalent and must be run manually before merging.
7. **authorized_keys is not baked in by default** (by design - no
   private keys in the repo). The operator must supply a public key at
   build time or inject one into a running rescue system.

## Security notes

- Password and PAM authentication are compiled out of dropbear
  (`DROPBEAR_SVR_PASSWORD_AUTH 0`, `DROPBEAR_SVR_PAM_AUTH 0`,
  `DROPBEAR_SVR_PUBKEY_AUTH 1`); `/etc/shadow` is absent on purpose,
  so the root account is unusable for password login even if the build
  option were ever flipped.
- Telnet has no authentication; it is doubly gated (config flag +
  marker file) and defaults off.
- `/etc/rescue.conf` and `/init` keep both subnets and ports in one
  place so a reviewer can audit the exposure surface at a glance.
- The initramfs ships no private keys, no device serial and no
  serial-bearing cmdline tokens (enforced by the verify secret scan).
