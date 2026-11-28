// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/mdio.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_mdio.h>
#include <linux/phy.h>
#include <linux/platform_device.h>
#include <linux/property.h>

#define TAURUS_MDIO_ADDR		0x04
#define TAURUS_MDIO_ADDR_PHY		GENMASK(4, 0)
#define TAURUS_MDIO_ADDR_REG		GENMASK(12, 8)
#define TAURUS_MDIO_ADDR_READ		BIT(15)
#define TAURUS_MDIO_ADDR_C45		BIT(16)
#define TAURUS_MDIO_ADDR_OP		GENMASK(19, 18)
#define TAURUS_MDIO_OP_C45_ADDR		0
#define TAURUS_MDIO_OP_C45_WRITE	1
#define TAURUS_MDIO_OP_C45_READ		3
#define TAURUS_MDIO_WRDATA		0x08
#define TAURUS_MDIO_RDDATA		0x0c
#define TAURUS_MDIO_CTRL		0x10
#define TAURUS_MDIO_CTRL_DONE		BIT(0)
#define TAURUS_MDIO_CTRL_START		BIT(7)
/*
 * Clause 45 MDIO frames on Taurus take ~200-300 us. Polling at 1 us forces
 * usleep_range(1, 1) to fire hundreds of hrtimer wakeups per transfer (~10k+
 * arch_timer IRQs/s during 1 Hz PHY state-machine polls). 100 us yields
 * usleep_range(26, 100), cutting timer wakeups by ~50x with negligible delay.
 */
#define TAURUS_MDIO_POLL_US		100
#define TAURUS_MDIO_TIMEOUT_US		50000

#define TAURUS_GPHY_PHY_SHIFT		7
#define TAURUS_GPHY_REG_SHIFT		2

struct taurus_mdio_data {
	u32 gphy_mask;
};

struct taurus_mdio {
	void __iomem *base;
	void __iomem *gphy;
	u32 gphy_mask;
};

static bool taurus_mdio_is_gphy(struct taurus_mdio *mdio, int addr)
{
	return mdio->gphy_mask & BIT(addr);
}

static void __iomem *taurus_mdio_gphy_reg(struct taurus_mdio *mdio, int addr,
					  int regnum)
{
	return mdio->gphy + (addr << TAURUS_GPHY_PHY_SHIFT) +
	       (regnum << TAURUS_GPHY_REG_SHIFT);
}

static int taurus_mdio_xfer(struct taurus_mdio *mdio, u32 cmd, u16 data,
			    bool read)
{
	u32 status;
	int ret;

	writel(TAURUS_MDIO_CTRL_DONE, mdio->base + TAURUS_MDIO_CTRL);
	writel(cmd, mdio->base + TAURUS_MDIO_ADDR);
	if (!read)
		writel(data, mdio->base + TAURUS_MDIO_WRDATA);
	writel(TAURUS_MDIO_CTRL_START, mdio->base + TAURUS_MDIO_CTRL);
	ret = readl_poll_timeout(mdio->base + TAURUS_MDIO_CTRL, status,
				 status & TAURUS_MDIO_CTRL_DONE,
				 TAURUS_MDIO_POLL_US, TAURUS_MDIO_TIMEOUT_US);
	if (ret)
		return ret;
	ret = read ? readl(mdio->base + TAURUS_MDIO_RDDATA) & 0xffff : 0;
	writel(TAURUS_MDIO_CTRL_DONE, mdio->base + TAURUS_MDIO_CTRL);
	return ret;
}

static int taurus_mdio_read(struct mii_bus *bus, int addr, int regnum)
{
	struct taurus_mdio *mdio = bus->priv;

	if (taurus_mdio_is_gphy(mdio, addr))
		return readl(taurus_mdio_gphy_reg(mdio, addr, regnum)) & 0xffff;

	return taurus_mdio_xfer(mdio, FIELD_PREP(TAURUS_MDIO_ADDR_PHY, addr) |
				FIELD_PREP(TAURUS_MDIO_ADDR_REG, regnum) |
				TAURUS_MDIO_ADDR_READ, 0, true);
}

static int taurus_mdio_write(struct mii_bus *bus, int addr, int regnum, u16 val)
{
	struct taurus_mdio *mdio = bus->priv;

	if (taurus_mdio_is_gphy(mdio, addr)) {
		writel(val, taurus_mdio_gphy_reg(mdio, addr, regnum));
		usleep_range(1000, 2000);
		return 0;
	}

	return taurus_mdio_xfer(mdio, FIELD_PREP(TAURUS_MDIO_ADDR_PHY, addr) |
				FIELD_PREP(TAURUS_MDIO_ADDR_REG, regnum), val,
				false);
}

static int taurus_mdio_c45(struct taurus_mdio *mdio, int addr, int devad,
			   int regnum, u16 val, bool read)
{
	u32 cmd;
	int ret;

	if (taurus_mdio_is_gphy(mdio, addr))
		return -EOPNOTSUPP;

	cmd = FIELD_PREP(TAURUS_MDIO_ADDR_PHY, addr) |
	      FIELD_PREP(TAURUS_MDIO_ADDR_REG, devad) | TAURUS_MDIO_ADDR_C45;
	ret = taurus_mdio_xfer(mdio, cmd |
			       FIELD_PREP(TAURUS_MDIO_ADDR_OP,
					  TAURUS_MDIO_OP_C45_ADDR),
			       regnum, false);
	if (ret)
		return ret;

	if (read)
		cmd |= FIELD_PREP(TAURUS_MDIO_ADDR_OP, TAURUS_MDIO_OP_C45_READ) |
		       TAURUS_MDIO_ADDR_READ;
	else
		cmd |= FIELD_PREP(TAURUS_MDIO_ADDR_OP, TAURUS_MDIO_OP_C45_WRITE);
	return taurus_mdio_xfer(mdio, cmd, val, read);
}

static int taurus_mdio_read_c45(struct mii_bus *bus, int addr, int devad,
				int regnum)
{
	return taurus_mdio_c45(bus->priv, addr, devad, regnum, 0, true);
}

static int taurus_mdio_write_c45(struct mii_bus *bus, int addr, int devad,
				 int regnum, u16 val)
{
	return taurus_mdio_c45(bus->priv, addr, devad, regnum, val, false);
}

static int taurus_mdio_probe(struct platform_device *pdev)
{
	const struct taurus_mdio_data *data;
	struct device *dev = &pdev->dev;
	struct taurus_mdio *mdio;
	struct mii_bus *bus;

	data = device_get_match_data(dev);
	if (!data)
		return -EINVAL;

	bus = devm_mdiobus_alloc_size(dev, sizeof(*mdio));
	if (!bus)
		return -ENOMEM;

	mdio = bus->priv;
	mdio->gphy_mask = data->gphy_mask;
	mdio->base = devm_platform_ioremap_resource_byname(pdev, "mdio");
	if (IS_ERR(mdio->base))
		return PTR_ERR(mdio->base);
	mdio->gphy = devm_platform_ioremap_resource_byname(pdev, "gphy");
	if (IS_ERR(mdio->gphy))
		return PTR_ERR(mdio->gphy);

	bus->name = "taurus-mdio";
	bus->parent = dev;
	bus->read = taurus_mdio_read;
	bus->write = taurus_mdio_write;
	bus->read_c45 = taurus_mdio_read_c45;
	bus->write_c45 = taurus_mdio_write_c45;
	snprintf(bus->id, MII_BUS_ID_SIZE, "%s", dev_name(dev));

	return devm_of_mdiobus_register(dev, bus, dev->of_node);
}

static const struct taurus_mdio_data taurus_mdio_data = {
	.gphy_mask = GENMASK(4, 1),
};

static const struct of_device_id taurus_mdio_of_match[] = {
	{ .compatible = "realtek,taurus-mdio", .data = &taurus_mdio_data },
	{ }
};
MODULE_DEVICE_TABLE(of, taurus_mdio_of_match);

static struct platform_driver taurus_mdio_driver = {
	.probe = taurus_mdio_probe,
	.driver = {
		.name = "taurus-mdio",
		.of_match_table = taurus_mdio_of_match,
	},
};
module_platform_driver(taurus_mdio_driver);

MODULE_DESCRIPTION("Realtek Taurus MDIO bus driver");
MODULE_LICENSE("GPL");
