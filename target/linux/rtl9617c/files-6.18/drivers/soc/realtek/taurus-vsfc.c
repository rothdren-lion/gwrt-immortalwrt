// SPDX-License-Identifier: GPL-2.0
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/file.h>
#include <linux/io.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>

#define TAURUS_VSFC_REG_GAINN		0x00
#define TAURUS_VSFC_REG_GAINP		0x04
#define TAURUS_VSFC_REG_CONTROL		0x08
#define TAURUS_VSFC_REG_TRIG_CONTROL	0x0c
#define TAURUS_VSFC_REG_RECV_CTRL0	0x10
#define TAURUS_VSFC_REG_RECV_CTRL1	0x14
#define TAURUS_VSFC_REG_RECV_CTRL2	0x18
#define TAURUS_VSFC_REG_RECV_CTRL3	0x1c
#define TAURUS_VSFC_REG_RECV_CTRL4	0x20
#define TAURUS_VSFC_REG_STATUS		0x2c

#define TAURUS_VSFC_CTRL_GLB_EN		BIT(0)
#define TAURUS_VSFC_CTRL_DIV_SEL	BIT(4)
#define TAURUS_VSFC_CTRL_TRIG_SEL	GENMASK(10, 8)

#define TAURUS_VSFC_TRIG_UVLO_MIN	GENMASK(2, 0)
#define TAURUS_VSFC_TRIG_FSS_MIN	GENMASK(6, 4)
#define TAURUS_VSFC_TRIG_CORE_MIN	GENMASK(9, 8)
#define TAURUS_VSFC_TRIG_CORE_IDLE_DIV_EN	BIT(16)

#define TAURUS_VSFC_RECV0_DET_RECV_SEL	GENMASK(1, 0)

#define TAURUS_VSFC_GAINP_POW		GENMASK(29, 25)

#define TAURUS_VSFC_STATUS_IDLE_ST	BIT(0)

#define TAURUS_VSFC_TRIG_SEL_CPU_INTERNAL	BIT(0)
#define TAURUS_VSFC_TRIG_SEL_UVLO		BIT(1)
#define TAURUS_VSFC_TRIG_SEL_SPEED_SENESOR	BIT(2)

struct realtek_vsfc {
	struct platform_device *pdev;
	void __iomem *regs;
	u32 gainn;
	u32 gainp;
	u32 ctrl;
	u32 trig_ctrl;
	u32 recv_ctrl0;
	u32 recv_ctrl1;
	u32 recv_ctrl2;
	u32 recv_ctrl3;
	u32 recv_ctrl4;
};

static void taurus_vsfc_writel_2t(struct realtek_vsfc *vsfc, u32 off, u32 val)
{
	writel(val, vsfc->regs + off);
	writel(val, vsfc->regs + off);
}

static int taurus_vsfc_init(struct realtek_vsfc *vsfc)
{
	ktime_t timeout;
	u32 ctrl, trig_ctrl, status;

	ctrl = readl(vsfc->regs + TAURUS_VSFC_REG_CONTROL);
	ctrl &= ~TAURUS_VSFC_CTRL_GLB_EN;
	taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_CONTROL, ctrl);

	timeout = ktime_add_ms(ktime_get(), 100);
	do {
		status = readl(vsfc->regs + TAURUS_VSFC_REG_STATUS);
		rmb();
	} while (!(status & TAURUS_VSFC_STATUS_IDLE_ST) &&
		 ktime_before(ktime_get(), timeout));

	switch (FIELD_GET(TAURUS_VSFC_CTRL_TRIG_SEL, vsfc->ctrl)) {
	case TAURUS_VSFC_TRIG_SEL_CPU_INTERNAL:
		ctrl &= ~TAURUS_VSFC_CTRL_TRIG_SEL;
		ctrl |= vsfc->ctrl & TAURUS_VSFC_CTRL_TRIG_SEL;
		ctrl &= ~TAURUS_VSFC_CTRL_DIV_SEL;
		ctrl |= vsfc->ctrl & TAURUS_VSFC_CTRL_DIV_SEL;

		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_CONTROL, ctrl);

		trig_ctrl = readl(vsfc->regs + TAURUS_VSFC_REG_TRIG_CONTROL);
		trig_ctrl &= ~(TAURUS_VSFC_TRIG_CORE_MIN |
			       TAURUS_VSFC_TRIG_CORE_IDLE_DIV_EN);
		trig_ctrl |= vsfc->trig_ctrl & (TAURUS_VSFC_TRIG_CORE_MIN |
						TAURUS_VSFC_TRIG_CORE_IDLE_DIV_EN);
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_TRIG_CONTROL,
				      trig_ctrl);

		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_RECV_CTRL0,
				      vsfc->recv_ctrl0);
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_RECV_CTRL1,
				      vsfc->recv_ctrl1);
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_RECV_CTRL2,
				      vsfc->recv_ctrl2);
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_RECV_CTRL3,
				      vsfc->recv_ctrl3);
		wmb();

		ctrl |= TAURUS_VSFC_CTRL_GLB_EN;
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_CONTROL, ctrl);
		break;
	case TAURUS_VSFC_TRIG_SEL_UVLO:
	case TAURUS_VSFC_TRIG_SEL_SPEED_SENESOR:
		if (vsfc->gainn & GENMASK(24, 0))
			taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_GAINN,
					      vsfc->gainn);
		if (vsfc->gainp & GENMASK(24, 0)) {
			vsfc->gainp &= ~TAURUS_VSFC_GAINP_POW;
			vsfc->gainp |= 0x1f << 25;
			taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_GAINP,
					      vsfc->gainp);
		}
		ctrl &= ~TAURUS_VSFC_CTRL_TRIG_SEL;
		ctrl |= vsfc->ctrl & TAURUS_VSFC_CTRL_TRIG_SEL;
		ctrl &= ~TAURUS_VSFC_CTRL_DIV_SEL;
		ctrl |= vsfc->ctrl & TAURUS_VSFC_CTRL_DIV_SEL;

		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_CONTROL, ctrl);
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_TRIG_CONTROL,
				      vsfc->trig_ctrl);
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_RECV_CTRL0,
				      vsfc->recv_ctrl0);
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_RECV_CTRL1,
				      vsfc->recv_ctrl1);
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_RECV_CTRL2,
				      vsfc->recv_ctrl2);
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_RECV_CTRL3,
				      vsfc->recv_ctrl3);
		wmb();
		ctrl |= TAURUS_VSFC_CTRL_GLB_EN;
		taurus_vsfc_writel_2t(vsfc, TAURUS_VSFC_REG_CONTROL, ctrl);
		break;
	default:
		break;
	}
	return 0;
}

static int taurus_vsfc_probe(struct platform_device *pdev)
{
	struct realtek_vsfc *vsfc;
	struct resource *res;
	int ret;
	u32 value;

	vsfc = devm_kzalloc(&pdev->dev, sizeof(*vsfc), GFP_KERNEL);
	if (!vsfc)
		return -ENOMEM;

	vsfc->pdev = pdev;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	vsfc->regs = devm_ioremap(&pdev->dev, res->start, resource_size(res));
	if (IS_ERR(vsfc->regs))
		return PTR_ERR(vsfc->regs);

	if (of_property_read_u32(pdev->dev.of_node, "trig_sel", &value))
		vsfc->ctrl = 0;
	else
		vsfc->ctrl = (value << 8) & TAURUS_VSFC_CTRL_TRIG_SEL;

	if (of_property_read_u32(pdev->dev.of_node, "div_sel", &value))
		vsfc->ctrl &= ~TAURUS_VSFC_CTRL_DIV_SEL;
	else if (value)
		vsfc->ctrl |= TAURUS_VSFC_CTRL_DIV_SEL;

	if (of_property_read_u32(pdev->dev.of_node, "core_idle_div_en", &value))
		vsfc->trig_ctrl = 0;
	else if (value)
		vsfc->trig_ctrl |= TAURUS_VSFC_TRIG_CORE_IDLE_DIV_EN;

	if (of_property_read_u32(pdev->dev.of_node, "core_min", &value) ||
	    value == 0)
		vsfc->trig_ctrl &= ~TAURUS_VSFC_TRIG_CORE_MIN;
	else
		vsfc->trig_ctrl |= FIELD_PREP(TAURUS_VSFC_TRIG_CORE_MIN,
					      value - 1);

	if (of_property_read_u32(pdev->dev.of_node, "fss_min", &value) ||
	    value == 0)
		vsfc->trig_ctrl &= ~TAURUS_VSFC_TRIG_FSS_MIN;
	else
		vsfc->trig_ctrl |= FIELD_PREP(TAURUS_VSFC_TRIG_FSS_MIN,
					      value - 1);

	if (of_property_read_u32(pdev->dev.of_node, "uvlo_min", &value) ||
	    value == 0)
		vsfc->trig_ctrl &= ~TAURUS_VSFC_TRIG_UVLO_MIN;
	else
		vsfc->trig_ctrl |= FIELD_PREP(TAURUS_VSFC_TRIG_UVLO_MIN,
					      value - 1);

	if (of_property_read_u32(pdev->dev.of_node, "det_recv_sel", &value))
		vsfc->recv_ctrl0 = 1 << 0;
	else if (value >= 1 && value <= 2)
		vsfc->recv_ctrl0 = value & TAURUS_VSFC_RECV0_DET_RECV_SEL;

	if (of_property_read_u32(pdev->dev.of_node, "recv_ctrl1", &value))
		vsfc->recv_ctrl1 = 0x00000010;
	else
		vsfc->recv_ctrl1 = value;
	if (of_property_read_u32(pdev->dev.of_node, "recv_ctrl2", &value))
		vsfc->recv_ctrl2 = 0x00000010;
	else
		vsfc->recv_ctrl2 = value;
	if (of_property_read_u32(pdev->dev.of_node, "recv_ctrl3", &value))
		vsfc->recv_ctrl3 = 0x00000010;
	else
		vsfc->recv_ctrl3 = value;
	if (of_property_read_u32(pdev->dev.of_node, "recv_ctrl4", &value))
		vsfc->recv_ctrl4 = 0;
	else
		vsfc->recv_ctrl4 = value;

	if (of_property_read_u32(pdev->dev.of_node, "control_gainn", &value))
		vsfc->gainn = 0;
	else
		vsfc->gainn = value;

	if (of_property_read_u32(pdev->dev.of_node, "control_gainp", &value))
		vsfc->gainp = 0;
	else
		vsfc->gainp = value;

	ret = taurus_vsfc_init(vsfc);

	dev_info(&pdev->dev, "RTK VSFC driver init\n");

	return ret;
}

static const struct of_device_id taurus_vsfc_of_match[] = {
	{ .compatible = "realtek,taurus-vsfc", },
	{ }
};
MODULE_DEVICE_TABLE(of, taurus_vsfc_of_match);

static struct platform_driver taurus_vsfc_driver = {
	.probe = taurus_vsfc_probe,
	.driver = {
		.name = "taurus-vsfc",
		.of_match_table = taurus_vsfc_of_match,
	},
};
module_platform_driver(taurus_vsfc_driver);

MODULE_DESCRIPTION("Realtek Taurus VSFC driver");
MODULE_LICENSE("GPL");
