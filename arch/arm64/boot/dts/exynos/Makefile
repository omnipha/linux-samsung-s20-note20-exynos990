# SPDX-License-Identifier: GPL-2.0
subdir-y += axis
subdir-y += google

dtb-$(CONFIG_ARCH_EXYNOS) += \
	exynos2200-g0s.dtb		\
	exynos5433-tm2.dtb		\
	exynos5433-tm2e.dtb		\
	exynos7-espresso.dtb		\
	exynos7870-a2corelte.dtb	\
	exynos7870-j5y17lte.dtb		\
	exynos7870-j6lte.dtb		\
	exynos7870-j7xelte.dtb		\
	exynos7870-on7xelte.dtb		\
	exynos7885-jackpotlte.dtb	\
	exynos850-e850-96.dtb		\
	exynos8895-dreamlte.dtb		\
	exynos9810-starlte.dtb		\
	exynos990-c1s.dtb		\
	exynos990-c2s.dtb		\
	exynos990-r8s.dtb               \
	exynos990-x1s.dtb		\
	exynos990-x1slte.dtb		\
	exynosautov9-sadk.dtb		\
	exynosautov920-sadk.dtb

# The c2s rescue image is loaded by the stock Samsung bootloader (sboot),
# which applies a DTBO overlay to the main DTB with libufdt. libufdt
# requires the *main* DTB to carry a /__symbols__ node, otherwise the
# overlay step fails with
#   "No node __symbols__ in main dtb." / "failed to perform fixups in overlay"
# and the device ends up in "ODIN MODE (DT Load Fail)".
#
# "dtc -@" is what generates /__symbols__ (and /__fixups__) - the same
# flag the vendor DTBs are built with, and the same flag the upstream
# kernel uses for every base DTB that overlays are applied to
# (scripts/Makefile.dtbs: "Set -@ if the target is a base DTB that
# overlay is applied onto").
#
# This is applied to the c2s DTB only - no other board and no other DT
# logic is touched.
DTC_FLAGS_exynos990-c2s := -@
