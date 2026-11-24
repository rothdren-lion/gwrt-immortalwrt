// SPDX-License-Identifier: GPL-2.0
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/thermal.h>

#define TAURUS_TMS_REG_A		0x0
#define TAURUS_TMS_REG_B		0x4
#define TAURUS_TMS_REG_C		0x8
#define TAURUS_TMS_REG_DATA		0xc
#define TAURUS_TMS_REG_RANGE		0x10

#define TAURUS_TEMP_NEGATIVE_FLAG	BIT(18)
#define TAURUS_TEMP_MASK		0x0003fc00
#define TAURUS_TEMP_FRACT_MASK		0x000003ff
#define TAURUS_TEMP_SHIFT		10

struct taurus_thermal_priv {
	void __iomem *sensor;
	int deviation;
};

static int taurus_read_temp(struct taurus_thermal_priv *priv, int *temp)
{
	unsigned long reg;
	int t, fra, negative;

	reg = readl_relaxed(priv->sensor + TAURUS_TMS_REG_DATA);

	negative = (reg & TAURUS_TEMP_NEGATIVE_FLAG) ? 1 : 0;

	t = (reg & TAURUS_TEMP_MASK) >> TAURUS_TEMP_SHIFT;
	fra = (reg & TAURUS_TEMP_FRACT_MASK);
	if (negative) {
		t |= 0xffffff00;
		fra = -fra;
	}
	t *= 1000;
	t += fra;

	*temp = t - priv->deviation;
	return 0;
}

static int taurus_get_temp(struct thermal_zone_device *tz, int *temp)
{
	struct taurus_thermal_priv *priv = thermal_zone_device_priv(tz);

	return taurus_read_temp(priv, temp);
}

static const struct thermal_zone_device_ops taurus_thermal_ops = {
	.get_temp = taurus_get_temp,
};

static const struct of_device_id taurus_thermal_id_table[] = {
	{ .compatible = "realtek,taurus-thermal" },
	{ }
};
MODULE_DEVICE_TABLE(of, taurus_thermal_id_table);

static int taurus_thermal_probe(struct platform_device *pdev)
{
	struct thermal_zone_device *thermal;
	struct taurus_thermal_priv *priv;
	struct device_node *np = pdev->dev.of_node;
	struct resource *res;
	unsigned int reg_v;
	int temp = 0;

	priv = devm_kzalloc(&pdev->dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	priv->sensor = devm_ioremap_resource(&pdev->dev, res);
	if (IS_ERR(priv->sensor))
		return PTR_ERR(priv->sensor);

	if (of_property_read_u32(np, "tms-reg-a", &reg_v))
		writel_relaxed(0x07f80000, priv->sensor + TAURUS_TMS_REG_A);
	else
		writel_relaxed(reg_v, priv->sensor + TAURUS_TMS_REG_A);

	if (of_property_read_u32(np, "tms-reg-b", &reg_v))
		writel_relaxed(0x00374000, priv->sensor + TAURUS_TMS_REG_B);
	else
		writel_relaxed(reg_v, priv->sensor + TAURUS_TMS_REG_B);

	writel_relaxed(0x2102011e, priv->sensor + TAURUS_TMS_REG_C);
	writel_relaxed(0x2102011f, priv->sensor + TAURUS_TMS_REG_C);

	if (of_property_read_u32(np, "deviation", &reg_v))
		priv->deviation = 0;
	else
		priv->deviation = reg_v;

	mdelay(300);
	readl_relaxed(priv->sensor + TAURUS_TMS_REG_C);
	readl_relaxed(priv->sensor + TAURUS_TMS_REG_DATA);
	readl_relaxed(priv->sensor + TAURUS_TMS_REG_DATA);

	taurus_read_temp(priv, &temp);

	thermal = devm_thermal_of_zone_register(&pdev->dev, 0, priv,
						&taurus_thermal_ops);
	if (IS_ERR(thermal)) {
		dev_err(&pdev->dev, "failed to register thermal zone\n");
		return PTR_ERR(thermal);
	}

	platform_set_drvdata(pdev, thermal);

	return 0;
}

static struct platform_driver taurus_thermal_driver = {
	.probe = taurus_thermal_probe,
	.driver = {
		   .name = "taurus_thermal",
		   .of_match_table = taurus_thermal_id_table,
		   },
};
builtin_platform_driver(taurus_thermal_driver);

MODULE_DESCRIPTION("Realtek Taurus thermal driver");
MODULE_LICENSE("GPL");
