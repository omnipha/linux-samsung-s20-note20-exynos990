// SPDX-License-Identifier: GPL-2.0
/*
 * S2MPS19 PMIC regulators on Exynos 990, driven over the ACPM firmware channel.
 *
 * Copyright (c) 2026 Bashir Hassan
 */

#include <linux/firmware/samsung/exynos-acpm-protocol.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regulator/driver.h>
#include <linux/regulator/machine.h>
#include <linux/regulator/of_regulator.h>

#define S2MPS19_TYPE_PMIC		0x01
#define S2MPS19_SPEEDY_CHAN		0

/* Enable field is bits [7:6]; opmode 0x3 = on. */
#define S2MPS19_ENABLE_SHIFT		6
#define S2MPS19_ENABLE_MASK		(0x03 << S2MPS19_ENABLE_SHIFT)
#define S2MPS19_ENABLE_ON		(0x03 << S2MPS19_ENABLE_SHIFT)

/* Control registers */
#define S2MPS19_REG_B4M_CTRL		0x26
#define S2MPS19_REG_LDO2CTRL		0x47
#define S2MPS19_REG_LDO15CTRL		0x54
#define S2MPS19_REG_LDO27CTRL		0x60

struct s2mps19_acpm {
	struct acpm_handle *acpm;
	unsigned int chan_id;
	struct device *dev;
};

static int s2mps19_acpm_enable(struct regulator_dev *rdev)
{
	struct s2mps19_acpm *pmic = rdev_get_drvdata(rdev);
	int ret;
	u8 val = 0;

	ret = pmic->acpm->ops.pmic_ops.update_reg(pmic->acpm, pmic->chan_id,
						  S2MPS19_TYPE_PMIC,
						  rdev->desc->enable_reg,
						  S2MPS19_SPEEDY_CHAN,
						  S2MPS19_ENABLE_ON,
						  S2MPS19_ENABLE_MASK);
	pmic->acpm->ops.pmic_ops.read_reg(pmic->acpm, pmic->chan_id,
					  S2MPS19_TYPE_PMIC, rdev->desc->enable_reg,
					  S2MPS19_SPEEDY_CHAN, &val);
	dev_info(pmic->dev, "enable %s: reg 0x%02x update ret=%d readback=0x%02x\n",
		 rdev->desc->name, rdev->desc->enable_reg, ret, val);
	return ret;
}

static int s2mps19_acpm_disable(struct regulator_dev *rdev)
{
	struct s2mps19_acpm *pmic = rdev_get_drvdata(rdev);

	return pmic->acpm->ops.pmic_ops.update_reg(pmic->acpm, pmic->chan_id,
						   S2MPS19_TYPE_PMIC,
						   rdev->desc->enable_reg,
						   S2MPS19_SPEEDY_CHAN,
						   0, S2MPS19_ENABLE_MASK);
}

static int s2mps19_acpm_is_enabled(struct regulator_dev *rdev)
{
	struct s2mps19_acpm *pmic = rdev_get_drvdata(rdev);
	u8 val = 0;
	int ret;

	ret = pmic->acpm->ops.pmic_ops.read_reg(pmic->acpm, pmic->chan_id,
					        S2MPS19_TYPE_PMIC,
					        rdev->desc->enable_reg,
					        S2MPS19_SPEEDY_CHAN, &val);
	if (ret) {
		dev_warn_ratelimited(pmic->dev, "is_enabled read failed: %d\n", ret);
		return ret;
	}

	return (val & S2MPS19_ENABLE_MASK) ? 1 : 0;
}

static const struct regulator_ops s2mps19_acpm_ops = {
	.enable		= s2mps19_acpm_enable,
	.disable	= s2mps19_acpm_disable,
	.is_enabled	= s2mps19_acpm_is_enabled,
};

#define S2MPS19_ACPM_DESC(_name, _of, _reg, _uv)			\
	{								\
		.name		= _name,				\
		.of_match	= of_match_ptr(_of),			\
		.regulators_node = of_match_ptr("regulators"),		\
		.id		= 0,					\
		.ops		= &s2mps19_acpm_ops,			\
		.type		= REGULATOR_VOLTAGE,			\
		.owner		= THIS_MODULE,				\
		.enable_reg	= _reg,					\
		.enable_mask	= S2MPS19_ENABLE_MASK,			\
		.n_voltages	= 1,					\
		.fixed_uV	= _uv,					\
		.enable_time	= 130,					\
	}

static const struct regulator_desc s2mps19_acpm_regulators[] = {
	/* BUCK4M = VDD_WIFI_0P95, the QCA6390 core supply. */
	S2MPS19_ACPM_DESC("BUCK4M", "buck4m", S2MPS19_REG_B4M_CTRL, 950000),
	/* LDO2 = vqmmc */
	S2MPS19_ACPM_DESC("LDO2", "ldo2", S2MPS19_REG_LDO2CTRL, 1800000),
	/* LDO15 = vmmc */
	S2MPS19_ACPM_DESC("LDO15", "ldo15", S2MPS19_REG_LDO15CTRL, 2950000),
	/* LDO27 = wacom_avdd */
	S2MPS19_ACPM_DESC("LDO27", "ldo27", S2MPS19_REG_LDO27CTRL, 3200000),
};

static int s2mps19_acpm_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct regulator_config config = { };
	struct s2mps19_acpm *pmic;
	struct device_node *acpm_np;
	u32 chan_id;
	int i;

	pmic = devm_kzalloc(dev, sizeof(*pmic), GFP_KERNEL);
	if (!pmic)
		return -ENOMEM;

	acpm_np = of_get_parent(dev->of_node);
	if (!acpm_np)
		return -ENODEV;

	pmic->acpm = devm_acpm_get_by_node(dev, acpm_np);
	of_node_put(acpm_np);
	if (IS_ERR(pmic->acpm))
		return dev_err_probe(dev, PTR_ERR(pmic->acpm),
				     "failed to get ACPM handle\n");

	if (of_property_read_u32(dev->of_node, "acpm-ipc-channel", &chan_id))
		return dev_err_probe(dev, -EINVAL, "missing acpm-ipc-channel\n");
	pmic->chan_id = chan_id;
	pmic->dev = dev;

	config.dev = dev;
	config.driver_data = pmic;

	for (i = 0; i < ARRAY_SIZE(s2mps19_acpm_regulators); i++) {
		struct regulator_dev *rdev;

		rdev = devm_regulator_register(dev,
					       &s2mps19_acpm_regulators[i],
					       &config);
		if (IS_ERR(rdev))
			return dev_err_probe(dev, PTR_ERR(rdev),
					     "failed to register %s\n",
					     s2mps19_acpm_regulators[i].name);
	}

	dev_info(dev, "S2MPS19 regulators over ACPM channel %u\n", pmic->chan_id);

	return 0;
}

static const struct of_device_id s2mps19_acpm_match[] = {
	{ .compatible = "samsung,s2mps19-acpm-regulator" },
	{ }
};
MODULE_DEVICE_TABLE(of, s2mps19_acpm_match);

static struct platform_driver s2mps19_acpm_driver = {
	.driver = {
		.name = "s2mps19-acpm-regulator",
		.of_match_table = s2mps19_acpm_match,
	},
	.probe = s2mps19_acpm_probe,
};
module_platform_driver(s2mps19_acpm_driver);

MODULE_DESCRIPTION("S2MPS19 regulators over Exynos ACPM");
MODULE_LICENSE("GPL");
