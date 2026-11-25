// SPDX-License-Identifier: GPL-2.0-only
/*
 * Samsung S2DOS05 display sub-PMIC - touchscreen rail regulators
 *
 * The S2DOS05 sits on its own I2C bus and powers both the AMOLED panel
 * (BUCK1/LDO1/LDO4/ELVSS) and the touchscreen rails
 * (LDO2 = tsp_io 1.8V, LDO3 = tsp_avdd 3.0V).
 *
 * We deliberately expose ONLY the two touch rails. The panel rails are brought
 * up by the bootloader and are what keeps the display alive; registering them
 * here would let the regulator core disable them as "unused" and blank the
 * screen. Enable/disable go through regmap_update_bits() on the single shared
 * enable register, so only our own bits are ever modified.
 */

#include <linux/bits.h>
#include <linux/i2c.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/regmap.h>
#include <linux/regulator/driver.h>

#define S2DOS05_REG_EN		0x03
#define S2DOS05_REG_LDO2_CFG	0x05
#define S2DOS05_REG_LDO3_CFG	0x06
#define S2DOS05_REG_MAX		0x11

#define S2DOS05_EN_LDO2		BIT(1)
#define S2DOS05_EN_LDO3		BIT(2)

#define S2DOS05_LDO_VSEL_MASK	0x7f
#define S2DOS05_LDO_STEP_UV	25000
#define S2DOS05_LDO2_MIN_UV	1500000
#define S2DOS05_LDO3_MIN_UV	2700000
#define S2DOS05_LDO_N_VOLTAGES	(S2DOS05_LDO_VSEL_MASK + 1)

static const struct regulator_ops s2dos05_ldo_ops = {
	.enable			= regulator_enable_regmap,
	.disable		= regulator_disable_regmap,
	.is_enabled		= regulator_is_enabled_regmap,
	.list_voltage		= regulator_list_voltage_linear,
	.map_voltage		= regulator_map_voltage_linear,
	.get_voltage_sel	= regulator_get_voltage_sel_regmap,
	.set_voltage_sel	= regulator_set_voltage_sel_regmap,
};

#define S2DOS05_LDO(_id, _name, _min_uV, _en_mask, _vsel_reg)		\
	{								\
		.name		 = (_name),				\
		.of_match	 = of_match_ptr(_name),			\
		.regulators_node = of_match_ptr("regulators"),		\
		.id		 = (_id),				\
		.ops		 = &s2dos05_ldo_ops,			\
		.type		 = REGULATOR_VOLTAGE,			\
		.owner		 = THIS_MODULE,				\
		.min_uV		 = (_min_uV),				\
		.uV_step	 = S2DOS05_LDO_STEP_UV,			\
		.n_voltages	 = S2DOS05_LDO_N_VOLTAGES,		\
		.vsel_reg	 = (_vsel_reg),				\
		.vsel_mask	 = S2DOS05_LDO_VSEL_MASK,		\
		.enable_reg	 = S2DOS05_REG_EN,			\
		.enable_mask	 = (_en_mask),				\
	}

static const struct regulator_desc s2dos05_regulators[] = {
	S2DOS05_LDO(0, "ldo2", S2DOS05_LDO2_MIN_UV, S2DOS05_EN_LDO2,
		    S2DOS05_REG_LDO2_CFG),
	S2DOS05_LDO(1, "ldo3", S2DOS05_LDO3_MIN_UV, S2DOS05_EN_LDO3,
		    S2DOS05_REG_LDO3_CFG),
};

static const struct regmap_config s2dos05_regmap_config = {
	.reg_bits	= 8,
	.val_bits	= 8,
	.max_register	= S2DOS05_REG_MAX,
};

static int s2dos05_probe(struct i2c_client *client)
{
	struct regulator_config config = { };
	struct regmap *regmap;
	unsigned int val;
	int i, ret;

	regmap = devm_regmap_init_i2c(client, &s2dos05_regmap_config);
	if (IS_ERR(regmap))
		return dev_err_probe(&client->dev, PTR_ERR(regmap),
				     "failed to init regmap\n");

	/* Sanity-check the chip actually answers before registering rails. */
	ret = regmap_read(regmap, S2DOS05_REG_EN, &val);
	if (ret)
		return dev_err_probe(&client->dev, ret,
				     "S2DOS05 not responding\n");

	dev_info(&client->dev, "S2DOS05 display sub-PMIC (EN=0x%02x)\n", val);

	config.dev = &client->dev;
	config.regmap = regmap;

	for (i = 0; i < ARRAY_SIZE(s2dos05_regulators); i++) {
		struct regulator_dev *rdev;

		rdev = devm_regulator_register(&client->dev,
					       &s2dos05_regulators[i], &config);
		if (IS_ERR(rdev))
			return dev_err_probe(&client->dev, PTR_ERR(rdev),
					     "failed to register %s\n",
					     s2dos05_regulators[i].name);
	}

	return 0;
}

static const struct of_device_id s2dos05_of_match[] = {
	{ .compatible = "samsung,s2dos05" },
	{ }
};
MODULE_DEVICE_TABLE(of, s2dos05_of_match);

static struct i2c_driver s2dos05_driver = {
	.driver = {
		.name		= "s2dos05-regulator",
		.of_match_table	= s2dos05_of_match,
	},
	.probe = s2dos05_probe,
};
module_i2c_driver(s2dos05_driver);

MODULE_DESCRIPTION("Samsung S2DOS05 display sub-PMIC regulator driver");
MODULE_LICENSE("GPL");
