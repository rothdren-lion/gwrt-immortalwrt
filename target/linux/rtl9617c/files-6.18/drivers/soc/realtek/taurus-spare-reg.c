// SPDX-License-Identifier: GPL-2.0
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/spinlock.h>

#include <linux/soc/realtek/taurus-spare-reg.h>

#define TAURUS_SPARE_MAX_COUNT	16

#define TAURUS_SPARE_GPIO	0
#define TAURUS_SPARE_PARALLEL_LED	1

struct taurus_spare_reg_ctrl {
	void __iomem *mem;
	spinlock_t *lock;
	struct device *dev;
};

static int taurus_spare_reg_probed;
static struct taurus_spare_reg_ctrl *glb_spare_ctrl;

static void taurus_spare_reg_set_bit(unsigned int bit)
{
	u32 val;
	unsigned long flags;

	spin_lock_irqsave(glb_spare_ctrl->lock, flags);
	val = ioread32(glb_spare_ctrl->mem);
	val |= BIT(bit);
	iowrite32(val, glb_spare_ctrl->mem);
	spin_unlock_irqrestore(glb_spare_ctrl->lock, flags);
}

static void taurus_spare_reg_clear_bit(unsigned int bit)
{
	u32 val;
	unsigned long flags;

	spin_lock_irqsave(glb_spare_ctrl->lock, flags);
	val = ioread32(glb_spare_ctrl->mem);
	val &= ~BIT(bit);
	iowrite32(val, glb_spare_ctrl->mem);
	spin_unlock_irqrestore(glb_spare_ctrl->lock, flags);
}

int taurus_spare_reg_mode_set(unsigned int bit, int mode)
{
	if (!taurus_spare_reg_probed) {
		WARN(1, "taurus-spare-reg: calling before probed\n");
		return -ENODEV;
	}

	if (bit > TAURUS_SPARE_MAX_COUNT) {
		dev_err(glb_spare_ctrl->dev, "invalid bit(%d) for PER_SPARE\n",
			bit);
		return -EINVAL;
	}

	if (mode == TAURUS_SPARE_GPIO)
		taurus_spare_reg_clear_bit(bit);
	else if (mode == TAURUS_SPARE_PARALLEL_LED)
		taurus_spare_reg_set_bit(bit);
	else
		return -EINVAL;

	return 0;
}
EXPORT_SYMBOL(taurus_spare_reg_mode_set);

static int taurus_spare_reg_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct resource *reg_res;
	spinlock_t *lock;

	glb_spare_ctrl = devm_kzalloc(dev, sizeof(*glb_spare_ctrl), GFP_KERNEL);
	if (!glb_spare_ctrl)
		return -ENOMEM;

	glb_spare_ctrl->dev = dev;

	reg_res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!reg_res)
		return -EINVAL;

	glb_spare_ctrl->mem = devm_ioremap_resource(dev, reg_res);
	if (IS_ERR(glb_spare_ctrl->mem))
		return PTR_ERR(glb_spare_ctrl->mem);

	lock = devm_kzalloc(dev, sizeof(*lock), GFP_KERNEL);
	if (!lock)
		return -ENOMEM;

	spin_lock_init(lock);
	glb_spare_ctrl->lock = lock;

	dev_set_drvdata(dev, glb_spare_ctrl);

	taurus_spare_reg_probed = 1;

	return 0;
}

static void taurus_spare_reg_remove(struct platform_device *pdev)
{
	int i;

	for (i = 0; i < TAURUS_SPARE_MAX_COUNT; i++)
		taurus_spare_reg_clear_bit(i);

	glb_spare_ctrl = NULL;
	taurus_spare_reg_probed = 0;
}

static const struct of_device_id taurus_spare_reg_of_match[] = {
	{ .compatible = "realtek,taurus-spare-reg", },
	{ },
};
MODULE_DEVICE_TABLE(of, taurus_spare_reg_of_match);

static struct platform_driver taurus_spare_reg_driver = {
	.probe = taurus_spare_reg_probe,
	.remove = taurus_spare_reg_remove,
	.driver = {
		.name = "taurus-spare-reg",
		.of_match_table = taurus_spare_reg_of_match,
	},
};

static int __init taurus_spare_reg_init(void)
{
	return platform_driver_register(&taurus_spare_reg_driver);
}
arch_initcall(taurus_spare_reg_init);

MODULE_DESCRIPTION("Realtek Taurus PER_SPARE register driver");
MODULE_LICENSE("GPL");
