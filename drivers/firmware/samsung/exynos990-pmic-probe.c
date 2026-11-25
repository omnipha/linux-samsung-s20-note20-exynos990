// SPDX-License-Identifier: GPL-2.0-only
/*
 * exynos990 ACPM/PMIC smoke test.
 *
 * READ-ONLY. Proves the AP -> mailbox -> APM(ACPM firmware) -> SPEEDY -> S2MPS19
 * path works end to end.
 */

#include <linux/delay.h>
#include <linux/firmware/samsung/exynos-acpm-protocol.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>

#define S2MPS19_ACPM_CHAN	2	/* acpm-ipc-channel */
#define S2MPS19_TYPE_PMIC	0x01	/* PMIC sub-block */
#define S2MPS19_SPEEDY_CHAN	0	/* main PMIC */

#define S2MPS19_REG_PMICID	0x00
#define S2MPS19_REG_LDO2CTRL	0x47	/* vqmmc */
#define S2MPS19_REG_LDO15CTRL	0x54	/* vmmc */

static int exynos990_pmic_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct acpm_handle *acpm;
	u8 id = 0, ldo2 = 0, ldo15 = 0;
	int ret;

	acpm = devm_acpm_get_by_node(dev, dev->parent->of_node);
	if (IS_ERR(acpm))
		return dev_err_probe(dev, PTR_ERR(acpm), "ACPMTEST: no acpm handle\n");

	ret = acpm->ops.pmic_ops.read_reg(acpm, S2MPS19_ACPM_CHAN, S2MPS19_TYPE_PMIC,
					  S2MPS19_REG_PMICID, S2MPS19_SPEEDY_CHAN, &id);
	if (ret) {
		dev_err(dev, "ACPMTEST: FAIL chipid read ret=%d\n", ret);
		return 0;	/* don't fail probe; non-fatal diagnostic */
	}

	dev_info(dev, "ACPMTEST: OK chipid=0x%02x\n", id);

	ret = acpm->ops.pmic_ops.read_reg(acpm, S2MPS19_ACPM_CHAN, S2MPS19_TYPE_PMIC,
					  S2MPS19_REG_LDO2CTRL, S2MPS19_SPEEDY_CHAN, &ldo2);
	if (ret)
		dev_err(dev, "ACPMTEST: FAIL ldo2 read ret=%d\n", ret);

	ret = acpm->ops.pmic_ops.read_reg(acpm, S2MPS19_ACPM_CHAN, S2MPS19_TYPE_PMIC,
					  S2MPS19_REG_LDO15CTRL, S2MPS19_SPEEDY_CHAN, &ldo15);
	if (ret)
		dev_err(dev, "ACPMTEST: FAIL ldo15 read ret=%d\n", ret);

	dev_info(dev, "ACPMTEST: LDO2(vqmmc)=0x%02x LDO15(vmmc)=0x%02x (en=bits7:6, 0xC0=on)\n",
		 ldo2, ldo15);

	return 0;
}

static const struct of_device_id exynos990_pmic_probe_match[] = {
	{ .compatible = "samsung,exynos990-pmic-probe" },
	{}
};
MODULE_DEVICE_TABLE(of, exynos990_pmic_probe_match);

static struct platform_driver exynos990_pmic_probe_driver = {
	.probe	= exynos990_pmic_probe,
	.driver	= {
		.name		= "exynos990-pmic-probe",
		.of_match_table	= exynos990_pmic_probe_match,
	},
};
module_platform_driver(exynos990_pmic_probe_driver);

MODULE_DESCRIPTION("exynos990 ACPM PMIC smoke test");
MODULE_LICENSE("GPL");
