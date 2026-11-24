// SPDX-License-Identifier: GPL-2.0
#include <linux/err.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/reset-controller.h>
#include <linux/spinlock.h>
#include <linux/types.h>

#define TAURUS_RESET_BANKS	1
#define TAURUS_RESET_BANK_SZ	32
#define TAURUS_RESET_REG_OFF	0x0

struct taurus_reset_data {
	spinlock_t lock;
	void __iomem *iobase;
	struct reset_controller_dev rcdev;
};

static int taurus_reset_assert(struct reset_controller_dev *rcdev,
			       unsigned long id)
{
	struct taurus_reset_data *data = container_of(rcdev,
						       struct taurus_reset_data,
						       rcdev);
	int bank = id / TAURUS_RESET_BANK_SZ;
	int offset = id % TAURUS_RESET_BANK_SZ;
	unsigned long flags;
	u32 reg;
	void __iomem *addr = data->iobase + TAURUS_RESET_REG_OFF + bank;

	spin_lock_irqsave(&data->lock, flags);
	reg = readl(addr);
	writel(reg | BIT(offset), addr);
	spin_unlock_irqrestore(&data->lock, flags);

	return 0;
}

static int taurus_reset_deassert(struct reset_controller_dev *rcdev,
				 unsigned long id)
{
	struct taurus_reset_data *data = container_of(rcdev,
						       struct taurus_reset_data,
						       rcdev);
	int bank = id / TAURUS_RESET_BANK_SZ;
	int offset = id % TAURUS_RESET_BANK_SZ;
	unsigned long flags;
	u32 reg;
	void __iomem *addr = data->iobase + TAURUS_RESET_REG_OFF + bank;

	spin_lock_irqsave(&data->lock, flags);
	reg = readl(addr);
	writel(reg & ~BIT(offset), addr);
	spin_unlock_irqrestore(&data->lock, flags);

	return 0;
}

static int taurus_reset_status(struct reset_controller_dev *rcdev,
			       unsigned long id)
{
	struct taurus_reset_data *data = container_of(rcdev,
						       struct taurus_reset_data,
						       rcdev);
	int bank = id / TAURUS_RESET_BANK_SZ;
	int offset = id % TAURUS_RESET_BANK_SZ;
	u32 reg;

	reg = readl(data->iobase + TAURUS_RESET_REG_OFF + bank);
	return (reg & BIT(offset));
}

static const struct reset_control_ops taurus_reset_ops = {
	.assert		= taurus_reset_assert,
	.deassert	= taurus_reset_deassert,
	.status		= taurus_reset_status,
};

static int taurus_reset_probe(struct platform_device *pdev)
{
	struct taurus_reset_data *data;
	struct resource *res;

	if (!of_find_property(pdev->dev.of_node, "#reset-cells", NULL))
		return -EINVAL;

	data = devm_kzalloc(&pdev->dev, sizeof(*data), GFP_KERNEL);
	if (!data)
		return -ENOMEM;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	data->iobase = devm_ioremap_resource(&pdev->dev, res);
	if (IS_ERR(data->iobase))
		return PTR_ERR(data->iobase);

	spin_lock_init(&data->lock);

	data->rcdev.owner = THIS_MODULE;
	data->rcdev.nr_resets = TAURUS_RESET_BANKS * TAURUS_RESET_BANK_SZ;
	data->rcdev.ops = &taurus_reset_ops;
	data->rcdev.of_node = pdev->dev.of_node;
	return devm_reset_controller_register(&pdev->dev, &data->rcdev);
}

static const struct of_device_id taurus_reset_dt_ids[] = {
	{ .compatible = "realtek,taurus-reset", },
	{ /* sentinel */ },
};
MODULE_DEVICE_TABLE(of, taurus_reset_dt_ids);

static struct platform_driver taurus_reset_driver = {
	.probe	= taurus_reset_probe,
	.driver = {
		.name		= "taurus-reset",
		.of_match_table	= taurus_reset_dt_ids,
	},
};
module_platform_driver(taurus_reset_driver);

MODULE_DESCRIPTION("Realtek Taurus Reset Controller Driver");
MODULE_LICENSE("GPL");
