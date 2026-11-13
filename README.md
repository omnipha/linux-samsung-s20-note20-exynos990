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

Work in progress:
- `arch/arm64/boot/dts/exynos/exynos990-c2s.dts`: draft, derived from c1s. Memory map, framebuffer address/size, key pins and power supplies require device validation.
- Kernel config and initramfs with USB networking and SSH: pending.
- Bootloader, image packaging and recovery: pending; do not use S10 images or partition layouts.

No keys, firmware blobs, serials or other private data belong in this public repository.
