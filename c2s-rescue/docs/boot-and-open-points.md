# c2s rescue: boot instructions and open points (issue #1)

## What this branch delivers

- `arch/arm64/configs/c2s_rescue_defconfig` - minimal ARM64 config
  for the c2s board (Exynos990). No modules, no distro baggage; USB
  gadget (configfs NCM/RNDIS/ACM), DWC3 + exynos990 PHY glue, simple
  framebuffer console, gpio-keys, devtmpfs, IKCONFIG.
- `arch/arm64/boot/dts/exynos/exynos990-c2s.dts` - the c2s board DT.
  Fixed in this branch: the last memory block now matches the measured
  RAM end at `0xb00000000`, and the root uses the stock cell format
  (`#address-cells = <2>`, `#size-cells = <1>`; every root-level
  `reg` is 3-cell) so lk3rd's 3-cell `/memory` surgery is accepted
  (see `evidence.md`, "lk3rd RAM-boot failure root cause").
- `c2s-rescue/initramfs/` - PID 1 (`/init`) plus its `/etc` config and
  `rescue-telnet` helper.
- `c2s-rescue/dropbear/localoptions.h` - build options that compile
  out password/PAM auth (public key only).
- `c2s-rescue/scripts/build.sh` - builds `Image`, `exynos990-c2s.dtb`
  and the initramfs archive outside the repo.
- `c2s-rescue/scripts/verify.sh` - 140 host-side verification gates.
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

The build produces the artifacts the vendor bootloader consumes. Since
issue #4 they are packaged into a flashable candidate by
`c2s-rescue/scripts/package-bootimg.sh` (Android boot image v2 with the
Samsung DT table in the dt slot - format documented in
`build-record.md`):

```
Image                     -> boot image kernel slot
exynos990-c2s.dtb         -> dt slot, wrapped in the Samsung DT table
initramfs                 -> boot image ramdisk slot
boot.img                  -> partition-sized, AVB hash footer
```

**No boot or flash attempt was made as part of this issue.** This is
deliberate: device I/O (ADB fastboot, Heimdall, flashing, rebooting)
belongs to the coordinator. A boot attempt therefore requires a
separate, explicit task with its own risk assessment, including a
recovery path (download mode / Odin).

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
6. At boot, a menu on the framebuffer console + USB ACM serial (via
   `/usr/bin/rescue-menu` and its input helper `rescue-menu-keys`) asks
   for the mode: volume-up/power/Enter or timeout -> rescue (SSH only,
   telnet off); volume-down or serial line `telnet` -> rescue + USB
   telnet (explicit opt-in only). Telnet stays off unless *both* `RESCUE_ENABLE_TELNET="1"` in
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
rejected, password auth refused), plus the issue #4 gates: shipped
applet symlinks, the TER16x32 console font, the boot-menu input helper
(qemu-user regressions over representative event streams), the
Samsung DT table in the packaged boot.img, and a host replay of sboot's
DTBO merge (`fdtoverlay` of all 9 stock entries onto the built DTB,
with positive/negative controls; the anchor nodes this requires come
from `arch/arm64/boot/dts/exynos/c2s-overlay-anchors.dtsi`, generated
by `c2s-rescue/scripts/gen-overlay-anchors.py`).

## Open points (out of scope for issue #1)

These are known and documented rather than solved:

1. **Bootloader packaging (resolved for issue #4, not yet proven on
   hardware).** The stock bootloader reads the dt slot of an Android
   boot image v2 and expects a Samsung DT table (magic `0xd7b7ab1e`);
   `c2s-rescue/scripts/package-bootimg.sh` produces it and documents
   the exact template and sboot offset formula (see
   `build-record.md`). The overlay merge itself is now replayed on the
   host for all 9 stock dtbo entries (`fdtoverlay` gate in
   `verify.sh`); what remains unverified until a coordinator
   flash/boot test: which entry sboot selects for this board's
   hw_rev, the DTB-partition side of sboot's overlay step,
   probe behaviour of the disabled anchor nodes the overlay re-enables,
   and the font rendering on the real framebuffer.
   Further open hardware questions from the lk3rd analysis (see
   `evidence.md`): which lk3rd path actually ran for the previous
   candidates (quirks flag default in the `lk3rd` partition at
   offset 0x175000 is unknown from the host; `fastboot oem
   enable-mainline-quirks` / `disable-kaslr` read it out), and
   whether the kernel ever started (no pstore/ramoops: `CONFIG_PSTORE`
   is unset and non-destructive post-reset DRAM retrieval is
   unproven — next observable signals are the lk3rd LCD text,
   `enter_reason` and the USB re-enumeration ladder lk3rd
   18d1:4d00 vs. kernel gadget).
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
