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

Without it the archive ships **without** any `authorized_keys` file and
dropbear is never started by `/init` (it logs
"no authorized_keys for rescue or root: dropbear NOT started"). The key
can also be added later by mounting the rescue system from an already
running rescue instance.

**The deliverable must be built WITH the key.** A packaged image
without an `authorized_keys` file cannot provide SSH even if USB works -
that is the blocker that disqualified candidate `4b823391…`.
`verify.sh` now proves the key from the packaged `boot.img` itself
(section "packaged boot.img: root/.ssh/authorized_keys"): the ramdisk
slot is sliced out of the image, the cpio entry is read directly, and
its OpenSSH fingerprint must equal the source key's fingerprint with
mode 0600. Use
`c2s-rescue/scripts/prove-authorized-keys.sh boot.img ~/.ssh/id_ed25519.pub`
to check an artifact by hand.

The same key is installed for **two** accounts, because dropbear is
started without `-D` and therefore resolves `~/.ssh/authorized_keys`
per login account:

* `/root/.ssh/authorized_keys` (uid 0, mode 0600) - the root login.
* `/home/rescue/.ssh/authorized_keys` (uid 1000, mode 0600) - the
  unprivileged login account.

The `rescue` account exists so an SSH session is not root. It has
passwordless sudo, so the documented acceptance command works from
either account:

```sh
ssh rescue@192.168.42.2    # or .62
sudo -n id                  # -> uid=0(root) gid=0(root) groups=0(root)
```

`sudo -n` is sudo-rs 0.2.15 (not the original sudo) and is unusually
strict: `/usr/bin/sudo` must be setuid root, `/etc/sudoers` and
`/etc/sudoers.d/90-rescue` must be root-owned mode 0440, the
`@includedir` in `/etc/sudoers` must be active (not commented), and
`/etc/pam.d/sudo` must exist or sudo-rs aborts with a PAM error. All of
these are shipped in the image and re-proven inside the **signed**
`boot.img` by `verify.sh` (section "packaged boot.img: sudo payload").
`Defaults !authenticate` must not be used: sudo-rs rejects it as an
unknown setting.

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

AVB form of the current candidate (see `build-record.md`): the footer is
`Algorithm: SHA256_RSA4096`, rollback index 13, signed with the
authorized host key (`C2S_AVB_KEY`, never part of the repository) and
verified on the build host with
`avbtool verify_image --image boot.img --key $C2S_AVB_KEY`. The earlier
candidate `69702078…` had `Algorithm: NONE` - structure and hash only,
no signature - and is superseded. Host AVB verification proves the
image's cryptographic self-consistency and its match to the recorded
policy; it does **not** prove the device accepts the image (hardware
test, coordinator).
```

**No boot or flash attempt was made as part of this issue.** This is
deliberate: device I/O (ADB fastboot, Heimdall, flashing, rebooting)
belongs to the coordinator. A boot attempt therefore requires a
separate, explicit task with its own risk assessment, including a
recovery path (download mode / Odin).

## Rescue system behaviour at boot

1. `/init` mounts proc, sysfs, devtmpfs, devpts, configfs, tmpfs.
2. It creates the configfs gadget `c2s` (state machine in
   `/usr/lib/c2s-gadget.sh`): the ACM function `acm.usb2` first and
   mandatory (its creation registers the `ttyGS` console), then the
   optional network functions `ncm.usb0` / `rndis.usb1` (each pinned to
   a fixed interface name, `ncm%d` / `rndis%d`, so host-side naming is
   predictable). A network function that cannot be set up is skipped
   only - it never removes ACM. The gadget is then bound to the single
   DWC3 UDC (`10e00000.dwc3`); if the full bind fails, the network
   functions are dropped and an ACM-only bind is retried on the same
   UDC. There is exactly one UDC and one gadget - ACM is *not* a second
   independent UDC, it is an independent *function* that enumerates
   within the same device.

   Stage reporting (kernel log, also on the USB console):

   | Status | Stage | Meaning |
   |---|---|---|
   | 0 | `bound` / `bound-acm-fallback` | gadget bound; USB enumerates (ACM always, network if linked) |
   | 1 | `acm-instance-fail`, `acm-link-fail`, `cfgfs-fail` | setup failed before bind - nothing enumerated, no console |
   | 2 | `udc-absent` | no UDC present - nothing enumerated (ACM function exists, waiting for a UDC) |
   | 3 | `bind-failed-all` | UDC present but every bind attempt failed - nothing enumerated |

   "Stage reached" and "no USB" are therefore distinguishable in the
   log: statuses 2 and 3 mean no USB device appears at all.
3. Static addresses (only for interfaces that exist; both up
   simultaneously when both functions linked):

   | Link | Rescue side | Host side |
   |---|---|---|
   | NCM (Linux/macOS) | 192.168.42.1/24 | 192.168.42.2 |
   | RNDIS (Windows) | 192.168.62.1/24 | 192.168.62.2 |

4. If `/home/rescue/.ssh/authorized_keys` or
   `/root/.ssh/authorized_keys` is non-empty **and** at least one USB
   network interface exists, dropbear starts on `192.168.42.1:22` and
   `192.168.62.1:22` (pubkey only, per-user `~/.ssh/authorized_keys`).
   With no network interface (console-only stage) dropbear is
   deliberately not started - it would have nothing to bind to.
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
  so neither account is usable for password login even if the build
  option were ever flipped.
- The image ships an unprivileged login account (`rescue`, uid 1000) in
  addition to `root`, and both have `NOPASSWD: ALL` in
  `/etc/sudoers.d/90-rescue`. Passwordless sudo is a deliberate
  property of a *rescue* image: the only credential is the SSH public
  key and the operator is expected to need root to fix the device. It
  is not a general-purpose multi-user system.
- sudo-rs is configured with a `pam_permit` stack because sudo-rs
  aborts if `/etc/pam.d/sudo` is missing; `pam_permit` never
  authenticates anything, which is consistent with the NOPASSWD rules
  and with dropbear having no password auth at all.
- The sudo binary is setuid root, which is what sudo-rs requires in
  order to load. `verify.sh` proves the setuid bit in the packed
  archive and has a negative control showing sudo-rs refuses to run
  without it.
- Telnet has no authentication; it is doubly gated (config flag +
  marker file) and defaults off.
- `/etc/rescue.conf` and `/init` keep both subnets and ports in one
  place so a reviewer can audit the exposure surface at a glance.
- The initramfs ships no private keys, no device serial and no
  serial-bearing cmdline tokens (enforced by the verify secret scan).

## Hardware test checklist (coordinator; not performed on this host)

Host verification cannot substitute for a device run. To capture what
the host-side evidence cannot show:

1. Console first, cable only: run
   `c2s-rescue/scripts/capture-usb-console.sh console.log /dev/ttyACM0`
   on the host *before* the device is powered so the `CON_PRINTBUFFER`
   replay of the ring buffer is not missed. Expect (in order): kernel
   boot log, then init lines with the `c2s-rescue:` prefix, including
   `gadget stage=0:acm-linked`, `ncm-linked`/`rndis-linked` (or
   `ncm-skipped`/`rndis-skipped`), `gadget stage=0:bound udc=10e00000.dwc3`.
   Remember the console buffer is 8 KiB and drops overflow, so a late
   open loses early lines - `dmesg` over SSH is the full buffer.
2. Stage vs absence of USB: if the host sees **no** USB device at all,
   the log must contain `stage=2:udc-absent` or `stage=3:bind-failed-all`
   (neither enumerates); if it sees a device, status 0 was reached.
   Without any capture at all, "no USB" is indistinguishable from
   "did not boot" - that gap can only be closed on the device.
3. Networking + SSH (only when the network functions linked):
   host NCM 192.168.42.2, RNDIS 192.168.62.2; then key-only SSH to
   192.168.42.1 / 192.168.62.1. Confirm telnet is NOT listening (needs
   config flag + marker + menu selection).
4. Fallback cases to reproduce on hardware if the coordinator injects
   faults (e.g. a gadget config with NCM/RNDIS removed): ACM must still
   enumerate and the console must still stream - that is the claim the
   host fault-injection tests support but cannot prove.
5. Close issue #4 only after these device observations; host
   verification (170 gates + 5 fault cases) is necessary evidence, not
   sufficient.

## Current candidate (diag15 UFS storage bring-up & safe boot flasher)

| Artifact | Size | sha256 |
|---|---|---|
| `boot.img` (diag15) | 61,865,984 B | `025ab1e8adde443fb5ba46029f6cd38f3ee55f2626618f1d0f99599c3a7bfa51` |
| `Image` (diag15) | 13,285,888 B | `fb9bd8b27e9ab9d7500b2116f1deef3887692a07cd4245b2cf9dfa1a185393ea` |
| `boot.img` (baseline) | 61,865,984 B | `472206dbfbd7dd7cf44c879fb2bb8fa016c3281fb1db794c650ca9c1fdd85571` |
| `Image` (baseline) | 13,154,816 B | `289af0434ae3c880903f9e223848500a2d60ae0c78092118bcff60cf286f476d` |
| `initramfs.cpio.gz` | 3,371,888 B | `8ec27e4575cac1f7d5cb6206c73807ba964740dadaea47bd2432fe08020d4e63` |

Packaged with the operator's public key (fingerprint
`SHA256:kX1/T8o7ReIa9OJgX0ADSD03lf/XvAFw5lqbAAUonAE`, mode 0600 inside
the initramfs, proven from the image) for **both** `root` and the
unprivileged `rescue` login account, plus a `SHA256_RSA4096` /
rollback 13 AVB footer signed with the authorized host key.

Host verification: **306 passed, 0 failed** on diag15; **306 passed, 0 failed**
on baseline (`verify.sh`), plus 10/10 host fault-injection checks for the ACM-independent
fallback, 14/14 checks in test-flash-boot.sh covering negative controls, 34/34 paint path / console checks, negative control platform device collision check, negative control CONFIG_SCSI check, and negative control CONFIG_UNIX check. Nothing here demonstrates a boot, USB enumeration, serial
console output, SSH login or physical UFS probing on the device - those need
the coordinator's hardware run.

Stage A (diag17, issues #13, #12): ACPM mailbox + S2MPS19 PMIC regulators and S2DOS05 + s6sy761 touch ported; 337/337 host gates passed.
Stage B (diag18, issues #9, #10): DRM/KMS simpledrm (card0) and Panfrost Mali-G77 GPU ported; 351/351 host gates passed.
Stage C (diag19, issues #17, #18, #19, #16): Flashed and booted on hardware over SSH via c2s-flash-boot; panfrost dummy supply resolved, mali-supply linked to s_vdd_buck1 (devfreq 156-832 MHz), s6sy761 touch axes configured (1440x3088), sensing enabled, ACPM chipid=0x00 verified; 380/380 host gates passed.
