# Linux for Samsung Galaxy S20 and Note20 (Exynos 990)

Mainline-based Linux kernel for Exynos 990 Samsung phones. **Experimental.**

## Devices

| Device | Codename | Status |
|---|---|---|
| Galaxy Note20 Ultra 5G | `c2s` | DTS draft builds; not booted |
| Galaxy Note20 5G | `c1s` | upstream DTS; not tested by Omnipha |
| Galaxy S20 5G | `x1s` | upstream DTS; not tested by Omnipha |
| Galaxy S20 FE | `r8s` | upstream DTS; not tested by Omnipha |

Exynos variants only. Snapdragon variants are not covered.

## Base

`main`: Linux 7.1-rc4, started at `4bf5d3da79c4` from [exynos990-mainline/linux](https://github.com/exynos990-mainline/linux) (`master`). The parent is retained for attribution and selective patch review. Other parent branches remain available there, not in this repository.

## First goal

Boot a `c2s` kernel with USB gadget networking and SSH access. USB controller/PHY nodes exist in the SoC tree; hardware operation on `c2s`, its boot path, and the DTS values are **not verified**. No flash or boot attempt has been made.

## Minimal rescue kernel and USB recovery image (issue #1)

Delivered under `c2s-rescue/`:

- `arch/arm64/configs/c2s_rescue_defconfig`: minimal ARM64 config with USB
  gadget (configfs NCM/RNDIS/ACM), DWC3 + Exynos990 PHY glue, simple
  framebuffer console, gpio-keys, no modules.
- `c2s-rescue/initramfs/`: PID 1 that brings up the gadget with static
  addresses, starts pubkey-only dropbear and keeps a console shell alive.
  Telnet exists but is double-gated and off by default.
- `c2s-rescue/dropbear/localoptions.h`: password/PAM auth compiled out.
- `c2s-rescue/scripts/build.sh`: builds `Image`, `exynos990-c2s.dtb` and the
  initramfs archive outside the repository, byte-reproducible.
- `c2s-rescue/scripts/verify.sh`: 79 host-side verification gates.
- `c2s-rescue/docs/`: evidence log, build record, boot instructions and open
  points.

```sh
./c2s-rescue/scripts/build.sh --outdir /tmp/opencode/c2s-out
./c2s-rescue/scripts/verify.sh /tmp/opencode/c2s-out
```

See `c2s-rescue/docs/boot-and-open-points.md` for what is and is not
verified (bootloader image packaging, UART console, USB3 and PMIC support
remain open).

Remaining work:
- `arch/arm64/boot/dts/exynos/exynos990-c2s.dts`: memory map fixed against
  device measurements in issue #1; framebuffer size, key pins and power
  supplies still need device validation.
- Bootloader, image packaging and recovery: pending; do not use S10 images
  or partition layouts.

No keys, firmware blobs, serials or other private data belong in this public repository.

