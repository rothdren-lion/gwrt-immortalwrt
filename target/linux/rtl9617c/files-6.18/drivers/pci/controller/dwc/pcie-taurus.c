// SPDX-License-Identifier: GPL-2.0
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/platform_device.h>
#include <linux/resource.h>
#include <linux/reboot.h>
#include <linux/signal.h>
#include <linux/types.h>
#include <linux/reset.h>
#include <linux/of_irq.h>
#include <linux/of_address.h>
#include <linux/phy/phy.h>
#include <linux/gpio.h>
#include <linux/of_gpio.h>
#include <linux/soc/realtek/taurus-soc.h>

#include "pcie-designware.h"

#define CA_PCIE_SERDES_CFG_VER_UNKNOWN "unknown"

#define MAX_INTR_PINS       4

#define SERDES_PHY_INIT		0
#define SERDES_PHY_AUTO_CAL	1

#define MAX_INTX_HOST_IRQS	4

#define MAX_BER_POLL_COUNT	50
#define MAX_LINKUP_POLL_COUNT	500

#define MAX_LANE_NUM		2
#define MAX_NAME_LEN		16

#define to_cortina_pcie(x)	dev_get_drvdata((x)->dev)
#define CONFIG_RTK_PCIE_AFFINITY 1

struct serdes_cfg {
	u32 addr;
	u32 val;
};

struct irq_lut {
	void *pcie;
	u32 reg;
	u32 mask;
	int irq;
};

struct cortina_pcie {
	struct dw_pcie *pci;
	void __iomem *reg_base; 
	void __iomem *serdes_base; 
	phys_addr_t dbi_start;
	phys_addr_t dbi_end;

	phys_addr_t iatu_unroll_start;
	void __iomem *iatu_unroll_base;

	struct clk *bus_clk;

	struct reset_control *core_reset;
	struct reset_control *phy_reset;
	struct reset_control *device_reset;
	struct reset_control *device_power;

	struct phy *phy[MAX_LANE_NUM];
	phys_addr_t serdes_addr;
	resource_size_t serdes_size;
	const char *serdes_cfg_ver;
	struct serdes_cfg *cfg[MAX_LANE_NUM];
	int cfg_cnt[MAX_LANE_NUM];

	u32 idx;
	u8 lanes;

	bool auto_calibration;
	bool init;
	u32 cur_irq_sts;
	unsigned long msi_pages;

	u16 device_ready_time;

	struct notifier_block reboot_nb;

#ifdef CONFIG_RTK_PCIE_AFFINITY
	int         irq_affinity;
#endif
#ifdef CONFIG_EXTD_INTR_PIN
	DECLARE_BITMAP(intr_en_bitmap, MAX_INTR_PINS);
#endif
	struct irq_lut luts[MAX_INTR_PINS];
};

#define PCIE_GLBL_INTERRUPT_0					0x00
#define INT_RADM_INTA_ASSERTED					0x00000001
#define INT_RADM_INTA_DEASSERTED				0x00000002
#define INT_RADM_INTB_ASSERTED					0x00000004
#define INT_RADM_INTB_DEASSERTED				0x00000008
#define INT_RADM_INTC_ASSERTED					0x00000010
#define INT_RADM_INTC_DEASSERTED				0x00000020
#define INT_RADM_INTD_ASSERTED					0x00000040
#define INT_RADM_INTD_DEASSERTED				0x00000080
#define INT_MSI_CTR_INT							0x00000100
#define INT_SMLH_LINK_UP						0x00000200
#define INT_HP_INT								0x00000400
#define INT_RADM_CORRECTABLE_ERR				0x00000800
#define INT_RADM_NONFATAL_ERR					0x00001000
#define INT_RADM_FATAL_ERR						0x00002000
#define INT_RADM_PM_TO_ACK						0x00004000
#define INT_RADM_PM_PME							0x00008000
#define INT_RADM_QOVERFLOW						0x00010000
#define INT_LINK_DOWN							0x00400000
#define INT_CFG_AER_RC_ERR_MSI					0x00800000
#define INT_CFG_PME_MSI							0x01000000
#define INT_HP_PME								0x02000000
#define INT_HP_MSI								0x04000000
#define INT_CFG_UR_RESP							0x08000000
#define PCIE_GLBL_INTERRUPT_ENABLE_0			0x04
#define PCIE_GLBL_INTERRUPT_1					0x08
#define PCIE_GLBL_INTERRUPT_ENABLE_1				0x0C
#ifdef CONFIG_EXTD_INTR_PIN
#define PCIE_GLBL_INTERRUPT_2					0x180
#define PCIE_GLBL_INTERRUPT_ENABLE_2				0x184
#define PCIE_GLBL_INTERRUPT_3					0x188
#define PCIE_GLBL_INTERRUPT_ENABLE_3				0x18C
#define PCIE_GLBL_INTERRUPT_4					0x190
#define PCIE_GLBL_INTERRUPT_ENABLE_4				0x194
#define PCIE_GLBL_INTERRUPT_5					0x198
#define PCIE_GLBL_INTERRUPT_ENABLE_5				0x19C
#endif
#define PCIE_GLBL_AXI_MASTER_RESP_MISC_INFO			0x10
#define PCIE_GLBL_AXI_MSTR_SLV_RESP_ERR_LOW_PW_MAP	0x14
#define PCIE_GLBL_CORE_CONFIG_REG					0x18
#define PCIE_LTSSM_ENABLE							BIT(0)
#define PCIE_LINK_DOWN_RST							BIT(6)
#define PCIE_GLBL_PM_INFO_RESET_VOLT_LOW_PWR_STATUS	0x1C
#define PWR_STATUS_SMLH_LTSSM_STATE_OFFSET			0x4
#define PWR_STATUS_SMLH_LTSSM_STATE_MASK			0x000003F0
#define PWR_STATUS_RDLH_LINK_UP						BIT(18)
#define PCIE_GLBL_RTLH_INFO							0x20
#define PCIE_GLBL_AXI_MASTER_WR_MISC_INFO			0x24
#define PCIE_GLBL_AXI_MASTER_RD_MISC_INFO			0x28
#define PCIE_GLBL_AXI_SLAVE_BRESP_MISC_INFO			0x2C
#define PCIE_GLBL_AXI_SLAVE_RD_RESP_MISC_INFO_COMP_TIMEOUT	0x30
#define PCIE_GLBL_CORE_DEBUG_0						0x34
#define PCIE_GLBL_CORE_DEBUG_1						0x38
#define PCIE_GLBL_CORE_DEBUG_E1						0x3C
#define PCIE_GLBL_PCIE_CONTR_CFG_START_ADDR			0x40
#define PCIE_GLBL_PCIE_CONTR_CFG_END_ADDR			0x44
#define PCIE_GLBL_PCIE_CONTR_IATU_BASE_ADDR			0x48
#if 0
#define RMLH_RCVD_ERR                 			0x124
#endif
#define RC_IATU_BASE_ADDR_MASK					0xFFF80000
#if 1
#define PCIE_MSI_INTERRUPT_STATUS_0				0x1a0
#define PCIE_MSI_INTERRUPT_ENABLE_0				0x1a4
#define PCIE_MSI_INTERRUPT_STATUS_1				0x1a8
#define PCIE_MSI_INTERRUPT_ENABLE_1				0x1ac
#ifdef CONFIG_EXTD_INTR_PIN
#define PCIE_MSI_INTERRUPT_STATUS_2				0x1b0
#define PCIE_MSI_INTERRUPT_ENABLE_2				0x1b4
#define PCIE_MSI_INTERRUPT_STATUS_3				0x1b8
#define PCIE_MSI_INTERRUPT_ENABLE_3				0x1bc
#define PCIE_MSI_INTERRUPT_STATUS_4				0x1c0
#define PCIE_MSI_INTERRUPT_ENABLE_4				0x1c4
#define PCIE_MSI_INTERRUPT_STATUS_5				0x1c8
#define PCIE_MSI_INTERRUPT_ENABLE_5				0x1cc
#endif
#endif

#define LTSSM_DETECT_QUIET		0x00
#define LTSSM_DETECT_ACT		0x01
#define LTSSM_POLL_ACTIVE		0x02
#define LTSSM_POLL_COMPLIANCE	0x03
#define LTSSM_POLL_CONFIG		0x04
#define LTSSM_PRE_DETECT_QUIET	0x05
#define LTSSM_DETECT_WAIT		0x06
#define LTSSM_CFG_LINKWD_START	0x07
#define LTSSM_CFG_LINKWD_ACEPT	0x08
#define LTSSM_CFG_LANENUM_WAI	0x09
#define LTSSM_CFG_LANENUM_ACEPT	0x0A
#define LTSSM_CFG_COMPLETE		0x0B
#define LTSSM_CFG_IDLE			0x0C
#define LTSSM_RCVRY_LOCK		0x0D
#define LTSSM_RCVRY_SPEED		0x0E
#define LTSSM_RCVRY_RCVRCFG		0x0F
#define LTSSM_RCVRY_IDLE		0x10
#define LTSSM_L0				0x11
#define LTSSM_L0S				0x12
#define LTSSM_L123_SEND_EIDLE	0x13
#define LTSSM_L1_IDLE			0x14
#define LTSSM_L2_IDLE			0x15
#define LTSSM_L2_WAKE			0x16
#define LTSSM_DISABLED_ENTRY	0x17
#define LTSSM_DISABLED_IDLE		0x18
#define LTSSM_DISABLED			0x19
#define LTSSM_ENTRY				0x1A
#define LTSSM_LPBK_ACTIVE		0x1B
#define LTSSM_LPBK_EXIT			0x1C
#define LTSSM_LPBK_EXIT_TIMEOUT	0x1D
#define LTSSM_HOT_RESET_ENTRY	0X1E
#define LTSSM_HOT_RESET			0x1F
#define LTSSM_RCVRY_EQ0			0x20
#define LTSSM_RCVRY_EQ1			0x21
#define LTSSM_RCVRY_EQ2			0x22
#define LTSSM_RCVRY_EQ3			0x23

static const char *__ltssm_str[] = {
	"DETECT_QUIET",
	"DETECT_ACT",
	"POLL_ACTIVE",
	"POLL_COMPLIANCE",
	"POLL_CONFIG",
	"PRE_DETECT_QUIET",
	"DETECT_WAIT",
	"CFG_LINKWD_START",
	"CFG_LINKWD_ACEPT",
	"CFG_LANENUM_WAI",
	"CFG_LANENUM_ACEPT",
	"CFG_COMPLETE",
	"CFG_IDLE",
	"RCVRY_LOCK",
	"RCVRY_SPEED",
	"RCVRY_RCVRCFG",
	"RCVRY_IDLE",
	"L0",
	"L0S",
	"L123_SEND_EIDLE",
	"L1_IDLE",
	"L2_IDLE",
	"L2_WAKE",
	"DISABLED_ENTRY",
	"DISABLED_IDLE",
	"DISABLED",
	"LPBK_ENTRY",
	"LPBK_ACTIVE",
	"LPBK_EXIT",
	"LPBK_EXIT_TIMEOUT",
	"HOT_RESET_ENTRY",
	"HOT_RESET",
	"RCVRY_EQ0",
	"RCVRY_EQ1",
	"RCVRY_EQ2",
	"RCVRY_EQ3"
};

static const char *ltssm_str(int state) {
	if ((state >=0) && (state < ARRAY_SIZE(__ltssm_str)))
		return __ltssm_str[state];
	else
		return "";
}

static inline u32 cortina_pcie_readl(struct cortina_pcie *pcie, u32 reg);
static inline void cortina_pcie_writel(struct cortina_pcie *pcie, u32 val,
                                       u32 reg);

static int cortina_pcie_device_reset(struct cortina_pcie *pcie);
static int cortina_pcie_ltssm(struct cortina_pcie *pcie);


static ssize_t cortina_pcie_device_reset_store(struct device *dev,
        struct device_attribute *attr,
        const char *buf, size_t count)
{
	struct cortina_pcie *pcie = dev_get_drvdata(dev);
	int result;

	result = cortina_pcie_device_reset(pcie);
	if (result < 0)
		return result;

	return count;
}

static int cortina_pcie_serdes_phy_switch_oobs(void __iomem *phy_base)
{

        writel(0xf75a, phy_base + 0x0034);
        usleep_range(10, 20);
        writel(0xf75a, phy_base + 0x0134);
        usleep_range(10, 20);
        writel(0x4500, phy_base + 0x00bc);
        usleep_range(10, 20);
        writel(0x3d00, phy_base + 0x01bc);
        usleep_range(10, 20);
        writel(0x0011, phy_base + 0x006c);
        usleep_range(10, 20);
        writel(0x0011, phy_base + 0x016c);
        usleep_range(10, 20);
        writel(0x01a4, phy_base + 0x0040);
        usleep_range(10, 20);
        writel(0x01a4, phy_base + 0x0140);
        usleep_range(10, 20);

        return 0;
}

static DEVICE_ATTR(device_reset, 0200, NULL,
                   cortina_pcie_device_reset_store);

static ssize_t cortina_pcie_serdes_phy_show(struct device *dev,
        struct device_attribute *attr,
        char *buf)
{
	struct cortina_pcie *cortina_pcie = dev_get_drvdata(dev);
	ssize_t ret = 0;
	void __iomem *phy_base;
	int lane, addr;
	u16 val;

	ret += sprintf(buf, "PCIe PHY ver: %s\n", cortina_pcie->serdes_cfg_ver);

	for (lane = 0; lane < cortina_pcie->lanes; lane++) {
		ret += sprintf(buf + ret, "lane [%d]\n", lane);
		ret += sprintf(buf + ret, "Gen 1:  \tGen 2:\n");

		phy_base = cortina_pcie->serdes_base + lane*0x1000;
		cortina_pcie_serdes_phy_switch_oobs(phy_base);
		ret += sprintf(buf + ret, "Page 0  \tPage 0\n");
		for (addr = 0x0; addr <= 0x1f; addr++) {
			val = readl(phy_base + addr*0x4) & 0xffff;
			ret += sprintf(buf + ret, "%02x: %04x\t", addr, val);
			val = readl(phy_base + (addr+0x40)*0x4) & 0xffff;
			ret += sprintf(buf + ret, "%02x: %04x\n", addr, val);
		}
		ret += sprintf(buf + ret, "Page 1  \tPage 1\n");
		for (addr = 0x20; addr <= 0x34; addr++) {
			val = readl(phy_base + addr*0x4) & 0xffff;
			ret += sprintf(buf + ret, "%02x: %04x\t", addr-0x20, val);
			val = readl(phy_base + (addr+0x40)*0x4) & 0xffff;
			ret += sprintf(buf + ret, "%02x: %04x\n", addr-0x20, val);
		}
		ret += sprintf(buf + ret, "\n");
	}

	return ret;
}

static ssize_t cortina_pcie_serdes_phy_store(struct device *dev,
        struct device_attribute *attr,
        const char *buf, size_t count)
{
	pr_info("Use \"devmem 0xf433[serdes phy id]000 + addr*0x4 32 [value]\" to write PHY parameter\n");
	pr_info("ex: devmem 0xf4333004 32 0x1852\n");
	return count;
}

static DEVICE_ATTR(serdes_phy, S_IRUSR|S_IWUSR, cortina_pcie_serdes_phy_show, cortina_pcie_serdes_phy_store);

static struct attribute *cortina_pcie_attributes[] = {
	&dev_attr_device_reset.attr,
	&dev_attr_serdes_phy.attr,
	NULL
};

static const struct attribute_group cortina_pcie_attr_group = {
	.attrs = cortina_pcie_attributes,
};

static struct attribute *cortina_pcie_dbg_attributes[] = {
	&dev_attr_serdes_phy.attr,
	NULL
};

static const struct attribute_group cortina_pcie_dbg_attr_group = {
	.attrs = cortina_pcie_dbg_attributes,
};

















static void ca_pcie_intx_enable(struct cortina_pcie *pcie)
{
	u32 val;

	val = cortina_pcie_readl(pcie, PCIE_GLBL_INTERRUPT_ENABLE_0);

	val |= (INT_RADM_INTA_ASSERTED | INT_RADM_INTB_ASSERTED |
	        INT_RADM_INTC_ASSERTED | INT_RADM_INTD_ASSERTED);

	cortina_pcie_writel(pcie, val, PCIE_GLBL_INTERRUPT_ENABLE_0);

#if defined(CONFIG_EXTD_INTR_PIN) && defined(INTx_IN_EXTD_INTR)

	int i;
	u32 reg;

	for (i = 1; i < MAX_INTR_PINS; i++) {
		if (test_bit(i, pcie->intr_en_bitmap)) {
			reg = PCIE_GLBL_INTERRUPT_ENABLE_2 + 8*(i-1);

			val = cortina_pcie_readl(pcie, reg);

			val |= (INT_RADM_INTA_ASSERTED | INT_RADM_INTB_ASSERTED |
			        INT_RADM_INTC_ASSERTED | INT_RADM_INTD_ASSERTED);

			cortina_pcie_writel(pcie, val, reg);
		}
	}
#endif
}

static void ca_pcie_mask_intx_irq(struct irq_data *irqd)
{
	struct dw_pcie_rp *pp = irq_data_get_irq_chip_data(irqd);
	struct dw_pcie *pci = to_dw_pcie_from_pp(pp);
	struct cortina_pcie *pcie = to_cortina_pcie(pci);
	u32 val;

	val = cortina_pcie_readl(pcie, PCIE_GLBL_INTERRUPT_ENABLE_0);

	val &= ~(INT_RADM_INTA_ASSERTED | INT_RADM_INTB_ASSERTED |
	         INT_RADM_INTC_ASSERTED | INT_RADM_INTD_ASSERTED);

	cortina_pcie_writel(pcie, val, PCIE_GLBL_INTERRUPT_ENABLE_0);

#if defined(CONFIG_EXTD_INTR_PIN) && defined(INTx_IN_EXTD_INTR)

	int i;
	u32 reg;

	for (i = 1; i < MAX_INTR_PINS; i++) {
		if (test_bit(i, pcie->intr_en_bitmap)) {
			reg = PCIE_GLBL_INTERRUPT_ENABLE_2 + 8*(i-1);

			val = cortina_pcie_readl(pcie, reg);

			val &= ~(INT_RADM_INTA_ASSERTED | INT_RADM_INTB_ASSERTED |
			         INT_RADM_INTC_ASSERTED | INT_RADM_INTD_ASSERTED);

			cortina_pcie_writel(pcie, val, reg);
		}
	}
#endif
}

static void ca_pcie_unmask_intx_irq(struct irq_data *irqd)
{
	struct dw_pcie_rp *pp = irq_data_get_irq_chip_data(irqd);
	struct dw_pcie *pci = to_dw_pcie_from_pp(pp);
	struct cortina_pcie *pcie = to_cortina_pcie(pci);

	ca_pcie_intx_enable(pcie);
}

static struct irq_chip ca_pcie_intx_irq_chip = {
	.name = "PCI-INTx",
	.irq_enable = ca_pcie_unmask_intx_irq,
	.irq_disable = ca_pcie_mask_intx_irq,
	.irq_mask = ca_pcie_mask_intx_irq,
	.irq_unmask = ca_pcie_unmask_intx_irq,
};

static int ca_pcie_intx_map(struct irq_domain *domain, unsigned int irq,
                            irq_hw_number_t hwirq)
{
	irq_set_chip_and_handler(irq, &ca_pcie_intx_irq_chip,
	                         handle_simple_irq);
	irq_set_chip_data(irq, domain->host_data);

	return 0;
}

static const struct irq_domain_ops intx_domain_ops = {
	.map = ca_pcie_intx_map,
};

static int cortina_pcie_serdes_phy_init(struct cortina_pcie *ca_pcie)
{
	u32 off, val;
	int i, lane;
	struct dw_pcie *pci = ca_pcie->pci;
	struct device *dev = pci->dev;

	dev_info(dev, "PCIe Serdes CFG version: %s\n",
	         ca_pcie->serdes_cfg_ver);

	for (lane = 0; lane < ca_pcie->lanes; lane++) {
		if (ca_pcie->cfg_cnt[lane] <= 0 ||
		        !ca_pcie->cfg[lane]) {
			dev_warn(dev, "lane %d no serdes cfg!\n",
			         lane);
			continue;
		}

		for (i = 0; i < ca_pcie->cfg_cnt[lane]; i++) {
			off = (phys_addr_t)ca_pcie->cfg[lane][i].addr - ca_pcie->serdes_addr;
			val = ca_pcie->cfg[lane][i].val;

			if (off < ca_pcie->serdes_size)
				writel(val, ca_pcie->serdes_base + off);
		}
	}

	return 0;
}

static int cortina_pcie_serdes_ber_notify(struct cortina_pcie *ca_pcie)
{
	int cnt = 0;
	int reg;

	do {
		reg = 1;
		reg &= readl(ca_pcie->serdes_base + 0x007c);
		reg &= readl(ca_pcie->serdes_base + 0x017c);

		if (ca_pcie->lanes == 2) {
			reg &= readl(ca_pcie->serdes_base + 0x107c);
			reg &= readl(ca_pcie->serdes_base + 0x117c);
		}

		if (reg)
			return reg;

		usleep_range(1000, 2000);
	} while (cnt++ < MAX_BER_POLL_COUNT);

	return reg;
}

static inline u32 cortina_pcie_readl(struct cortina_pcie *pcie, u32 reg)
{
	return readl(pcie->reg_base + reg);
}

static inline void cortina_pcie_writel(struct cortina_pcie *pcie, u32 val,
                                       u32 reg)
{
	writel(val, pcie->reg_base + reg);
}

static int cortina_pcie_device_reset(struct cortina_pcie *pcie)
{
	return reset_control_reset(pcie->device_reset);
}

static void serdes_phy_toggle(struct cortina_pcie *pcie)
{

	writel(0x500c, pcie->serdes_base + 0x0024);
	usleep_range(10, 20);
	writel(0x520c, pcie->serdes_base + 0x0024);
	usleep_range(10, 20);
	writel(0x500c, pcie->serdes_base + 0x0124);
	usleep_range(10, 20);
	writel(0x520c, pcie->serdes_base + 0x0124);
	usleep_range(10, 20);

	if (pcie->lanes == 2) {
		writel(0x500c, pcie->serdes_base + 0x1024);
		usleep_range(10, 20);
		writel(0x520c, pcie->serdes_base + 0x1024);
		usleep_range(10, 20);
		writel(0x500c, pcie->serdes_base + 0x1124);
		usleep_range(10, 20);
		writel(0x520c, pcie->serdes_base + 0x1124);
		usleep_range(10, 20);
	}
}

static void serdes_phy_calibration(struct cortina_pcie *pcie)
{
	int i;
	unsigned long vall;
	u32 val, reg;
	unsigned int lane, addr;

	if (pcie->idx != 0)
		return;

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		writel(0x500c, pcie->serdes_base + addr + 0x0024);
		usleep_range(10, 20);
		writel(0x520c, pcie->serdes_base + addr + 0x0024);
		usleep_range(10, 20);
		writel(0x500c, pcie->serdes_base + addr + 0x0124);
		usleep_range(10, 20);
		writel(0x520c, pcie->serdes_base + addr + 0x0124);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x0034);
		val |= BIT(6);
		writel(val, pcie->serdes_base + addr + 0x0034);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x0134);
		val |= BIT(6);
		writel(val, pcie->serdes_base + addr + 0x0134);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x0008);
		val |= BIT(9);
		writel(val, pcie->serdes_base + addr + 0x0008);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x0108);
		val |= BIT(9);
		writel(val, pcie->serdes_base + addr + 0x0108);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		writel(0x194, pcie->serdes_base + addr + 0x0040);
		usleep_range(10, 20);
		writel(0x194, pcie->serdes_base + addr + 0x0140);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x00bc);
		val |= BIT(10);
		writel(val, pcie->serdes_base + addr + 0x00bc);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x01bc);
		val |= BIT(10);
		writel(val, pcie->serdes_base + addr + 0x01bc);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x006c);
		val &= ~GENMASK(6, 5);
		writel(val, pcie->serdes_base + addr + 0x006c);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x016c);
		val &= ~GENMASK(6, 5);
		writel(val, pcie->serdes_base + addr + 0x016c);
		usleep_range(10, 20);
	}

	do {
		vall = readl(pcie->serdes_base + 0x007c);
		usleep_range(10, 20);
	} while (test_bit(4, &vall) != 1);

	if (pcie->lanes == 2) {

		for (lane = 0; lane < pcie->lanes; lane++) {
			addr = lane * 0x1000;
			val = readl(pcie->serdes_base + addr + 0x006c);
			val &= ~GENMASK(6, 5);
			val |= BIT(5);
			writel(val, pcie->serdes_base + addr + 0x006c);
			usleep_range(10, 20);
			val = readl(pcie->serdes_base + addr + 0x016c);
			val &= ~GENMASK(6, 5);
			val |= BIT(5);
			writel(val, pcie->serdes_base + addr + 0x016c);
			usleep_range(10, 20);
		}

		do {
			vall = readl(pcie->serdes_base + 0x007c);
			usleep_range(10, 20);
		} while (test_bit(4, &vall) != 1);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x0008);
		val &= ~BIT(9);
		writel(val, pcie->serdes_base + addr + 0x0008);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x0108);
		val &= ~BIT(9);
		writel(val, pcie->serdes_base + addr + 0x0108);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x006c); 
		val &= ~GENMASK(6, 5);
		writel(val, pcie->serdes_base + addr + 0x006c);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x016c); 
		val &= ~GENMASK(6, 5);
		writel(val, pcie->serdes_base + addr + 0x016c);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		writel(0x1a4, pcie->serdes_base + addr + 0x0040);
		usleep_range(10, 20);
		writel(0x1a4, pcie->serdes_base + addr + 0x0140);
		usleep_range(10, 20);
	}

	reg = readl(pcie->serdes_base + 0x007c);
	val = FIELD_GET(GENMASK(4, 0), reg);
	reg = readl(pcie->serdes_base + 0x0c);
	reg &= ~GENMASK(5, 1);
	reg |= FIELD_PREP(GENMASK(5, 1), val);

	writel(reg, pcie->serdes_base + 0x0c);
	usleep_range(10, 20);
	reg = readl(pcie->serdes_base + 0x10c);
	reg &= ~GENMASK(5, 1);
	reg |= FIELD_PREP(GENMASK(5, 1), val);
	writel(reg, pcie->serdes_base + 0x10c);
	usleep_range(10, 20);

	if (pcie->lanes == 2) {
		for (lane = 0; lane < pcie->lanes; lane++) {
			addr = lane * 0x1000;
			val = readl(pcie->serdes_base + addr + 0x006c);
			val &= ~GENMASK(6, 5);
			val |= BIT(5);
			writel(val, pcie->serdes_base + addr + 0x006c);
			usleep_range(10, 20);
			val = readl(pcie->serdes_base + addr + 0x016c);
			val &= ~GENMASK(6, 5);
			val |= BIT(5);
			writel(val, pcie->serdes_base + addr + 0x016c);
			usleep_range(10, 20);
		}

		reg = readl(pcie->serdes_base + 0x007c);
		val = FIELD_GET(GENMASK(4, 0), reg);
		reg = readl(pcie->serdes_base + 0x100c);
		reg &= ~GENMASK(5, 1);
		reg |= FIELD_PREP(GENMASK(5, 1), val);

		writel(reg, pcie->serdes_base + 0x100c);
		usleep_range(10, 20);
		reg = readl(pcie->serdes_base +  0x110c);
		reg &= ~GENMASK(5, 1);
		reg |= FIELD_PREP(GENMASK(5, 1), val);
		writel(reg, pcie->serdes_base + 0x110c);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		writel(0x501c, pcie->serdes_base + addr + 0x0024);
		usleep_range(10, 20);
		writel(0x521c, pcie->serdes_base + addr + 0x0024);
		usleep_range(10, 20);
		writel(0x501c, pcie->serdes_base + addr + 0x0124);
		usleep_range(10, 20);
		writel(0x521c, pcie->serdes_base + addr + 0x0124);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x0034);
		val &= ~BIT(6);
		writel(val, pcie->serdes_base + addr + 0x0034);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x0134);
		val &= ~BIT(6);
		writel(val, pcie->serdes_base + addr + 0x0134);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x00bc);
		val &= ~BIT(10);
		writel(val, pcie->serdes_base + addr + 0x00bc);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x01bc);
		val &= ~BIT(10);
		writel(val, pcie->serdes_base + addr + 0x01bc);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x006c);
		val &= ~GENMASK(6, 5);
		writel(val, pcie->serdes_base + addr + 0x006c);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x016c);
		val &= ~GENMASK(6, 5);
		writel(val, pcie->serdes_base + addr + 0x016c);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		writel(0xc, pcie->serdes_base + addr + 0x0040);
		usleep_range(10, 20);
		writel(0xc, pcie->serdes_base + addr + 0x0140);
		usleep_range(10, 20);
	}

	reg = readl(pcie->serdes_base + 0x007c);
	val = FIELD_GET(GENMASK(4, 1), reg);

	reg = readl(pcie->serdes_base + 0x2c);
	reg &= ~GENMASK(8, 5);
	reg |= FIELD_PREP(GENMASK(8, 5), val);
	writel(reg, pcie->serdes_base + 0x2c);
	usleep_range(10, 20);
	reg = readl(pcie->serdes_base + 0x12c);
	reg &= ~GENMASK(8, 5);
	reg |= FIELD_PREP(GENMASK(8, 5), val);
	writel(reg, pcie->serdes_base + 0x12c);
	usleep_range(10, 20);

	if (pcie->lanes == 2) {
		reg = readl(pcie->serdes_base + 0x107c);
		val = FIELD_GET(GENMASK(4, 1), reg);

		reg = readl(pcie->serdes_base + 0x102c);
		reg &= ~GENMASK(8, 5);
		reg |= FIELD_PREP(GENMASK(8, 5), val);
		writel(reg, pcie->serdes_base + 0x102c);
		usleep_range(10, 20);
		reg = readl(pcie->serdes_base + 0x112c);
		reg &= ~GENMASK(8, 5);
		reg |= FIELD_PREP(GENMASK(8, 5), val);
		writel(reg, pcie->serdes_base + 0x112c);
		usleep_range(10, 20);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		addr = lane * 0x1000;
		val = readl(pcie->serdes_base + addr + 0x0034);
		val &= ~BIT(13);
		writel(val, pcie->serdes_base + addr + 0x0034);
		usleep_range(10, 20);
		val = readl(pcie->serdes_base + addr + 0x0134);
		val &= ~BIT(13);
		writel(val, pcie->serdes_base + addr + 0x0134);
		usleep_range(10, 20);
	}

	for (i = 0; i < pcie->lanes; i++)
		phy_power_off(pcie->phy[i]);
	usleep_range(1000, 2000);

	reset_control_assert(pcie->phy_reset);
	usleep_range(1000, 2000);

	reset_control_assert(pcie->core_reset);
	usleep_range(1000, 2000);

	for (i = 0; i < pcie->lanes; i++)
		phy_power_on(pcie->phy[i]);
	usleep_range(1000, 2000);

	reset_control_deassert(pcie->phy_reset);
	usleep_range(1000, 2000);

	reset_control_deassert(pcie->core_reset);
	usleep_range(1000, 2000);
}

static int cortina_pcie_host_reset(struct cortina_pcie *pcie, int serdes_phase)
{
	int i, ret;
	struct dw_pcie *pci = pcie->pci;
	struct taurus_soc_data soc;

	memset(&soc, 0, sizeof(soc));
	ret = taurus_soc_data_get(&soc);
	if (ret != 0)
		dev_err(pci->dev, "Cannot get chip revision\n");

	reset_control_assert(pcie->device_reset);

	reset_control_assert(pcie->core_reset);
	usleep_range(1000, 2000);

	reset_control_assert(pcie->phy_reset);
	usleep_range(1000, 2000);

	cortina_pcie_serdes_phy_init(pcie);

	for (i = 0; i < pcie->lanes; i++)
		phy_power_on(pcie->phy[i]);
	usleep_range(1000, 2000);

	reset_control_deassert(pcie->phy_reset);
	usleep_range(1000, 2000);

	reset_control_deassert(pcie->core_reset);
	usleep_range(1000, 2000);

	switch (soc.chip_revision) {
	case 'A':
		serdes_phy_toggle(pcie);
		break;
	case 'B':
	default:
		serdes_phy_calibration(pcie);
		break;
	}
	if (!cortina_pcie_serdes_ber_notify(pcie))
		dev_err(pci->dev, "No BER Notify!\n");

	reset_control_deassert(pcie->device_reset);

	return 0;
}

static int cortina_pcie_host_setup(struct cortina_pcie *pcie)
{
	cortina_pcie_writel(pcie, pcie->dbi_start,
	                    PCIE_GLBL_PCIE_CONTR_CFG_START_ADDR);
	cortina_pcie_writel(pcie, pcie->dbi_end,
	                    PCIE_GLBL_PCIE_CONTR_CFG_END_ADDR);

	if (pcie->iatu_unroll_start) {
		u32 base_addr = (u32)pcie->iatu_unroll_start &
		                RC_IATU_BASE_ADDR_MASK;
		cortina_pcie_writel(pcie, base_addr,
		                    PCIE_GLBL_PCIE_CONTR_IATU_BASE_ADDR);
	}

	return 0;
}

static void cortina_pcie_stop_link(struct dw_pcie *pci)
{
	struct cortina_pcie *pcie = to_cortina_pcie(pci);

	cortina_pcie_writel(pcie, 0x40, PCIE_GLBL_CORE_CONFIG_REG);
	usleep_range(100, 200);
	cortina_pcie_writel(pcie, 0x0,  PCIE_GLBL_CORE_CONFIG_REG);
	usleep_range(100, 200);
	printk("stop link\n");
}

static int cortina_pcie_establish_link(struct dw_pcie *pci)
{
	struct cortina_pcie *pcie = to_cortina_pcie(pci);

	if (dw_pcie_link_up(pci))
		return 0;

	cortina_pcie_writel(pcie, PCIE_LTSSM_ENABLE,
	                    PCIE_GLBL_CORE_CONFIG_REG);

	usleep_range(1000, 2000);

	return 0;
}

static void cortina_pcie_misc_enable(struct cortina_pcie *pcie)
{
	u32 val;
#ifdef CONFIG_EXTD_INTR_PIN

	int i;
	u32 reg;
#endif

	val = cortina_pcie_readl(pcie, PCIE_GLBL_INTERRUPT_ENABLE_0);

	val |= (
	           INT_HP_INT |
	           INT_RADM_CORRECTABLE_ERR |
	           INT_RADM_NONFATAL_ERR |
	           INT_RADM_FATAL_ERR |
	           INT_RADM_PM_TO_ACK |
	           INT_RADM_PM_PME |
	           INT_RADM_QOVERFLOW |
	           INT_LINK_DOWN |
	           INT_CFG_AER_RC_ERR_MSI |
	           INT_CFG_PME_MSI	|
	           INT_HP_PME |
	           INT_HP_MSI |
	           INT_CFG_UR_RESP
	       );

	cortina_pcie_writel(pcie, val, PCIE_GLBL_INTERRUPT_ENABLE_0);

#ifdef CONFIG_EXTD_INTR_PIN

	for (i = 1; i < MAX_INTR_PINS; i++) {
		if (test_bit(i, pcie->intr_en_bitmap)) {
			reg = PCIE_GLBL_INTERRUPT_ENABLE_2 + 8*(i-1);

			cortina_pcie_writel(pcie, 0, reg);
		}
	}
#endif
}

static void cortina_pcie_msi_enable(struct cortina_pcie *pcie)
{
	u32 val;
#ifdef CONFIG_EXTD_INTR_PIN

	int i;
	u32 reg;
#endif

#if CONFIG_ARCH_REALTEK_TAURUS

	val = pcie->luts[0].mask;
	cortina_pcie_writel(pcie, val, PCIE_MSI_INTERRUPT_ENABLE_0);
#endif

	val = cortina_pcie_readl(pcie, PCIE_GLBL_INTERRUPT_ENABLE_0);
	val |= INT_MSI_CTR_INT;
	cortina_pcie_writel(pcie, val, PCIE_GLBL_INTERRUPT_ENABLE_0);

#ifdef CONFIG_EXTD_INTR_PIN

	for (i = 1; i < MAX_INTR_PINS; i++) {
		if (test_bit(i, pcie->intr_en_bitmap)) {

			reg = PCIE_MSI_INTERRUPT_ENABLE_2 + 8*(i-1);
			val = pcie->luts[i].mask;
			cortina_pcie_writel(pcie, val, reg);

			reg = PCIE_GLBL_INTERRUPT_ENABLE_2 + 8*(i-1);
			val = cortina_pcie_readl(pcie, reg);
			val |= INT_MSI_CTR_INT;
			cortina_pcie_writel(pcie, val, reg);
		}
	}
#endif
}

static void cortina_pcie_enable_interrupts(struct cortina_pcie *pcie)
{

	cortina_pcie_misc_enable(pcie);
	cortina_pcie_msi_enable(pcie);
}

static irqreturn_t cortina_pcie_irq_handler(int irq, void *arg)
{
	struct irq_lut *lut = arg;
	struct cortina_pcie *pcie = (struct cortina_pcie *)lut->pcie;
	struct dw_pcie *pci = pcie->pci;
	struct dw_pcie_rp *pp = &pci->pp;
	u32 val;
#ifdef CONFIG_EXTD_INTR_PIN
	val = cortina_pcie_readl(pcie, lut->reg);
#else
	val = cortina_pcie_readl(pcie, PCIE_GLBL_INTERRUPT_0);
#endif

	if (val & INT_RADM_INTA_ASSERTED)
		generic_handle_irq(irq_find_mapping(pp->irq_domain, 0));
	if (val & INT_RADM_INTB_ASSERTED)
		generic_handle_irq(irq_find_mapping(pp->irq_domain, 1));
	if (val & INT_RADM_INTC_ASSERTED)
		generic_handle_irq(irq_find_mapping(pp->irq_domain, 2));
	if (val & INT_RADM_INTD_ASSERTED)
		generic_handle_irq(irq_find_mapping(pp->irq_domain, 3));
	if (val & INT_LINK_DOWN) {
		int ltssm = cortina_pcie_ltssm(pcie);
		dev_err(pci->dev,
		        "Link Down!!!(ltssm = 0x%x - %s)\n",
		        ltssm, ltssm_str(ltssm));
		cortina_pcie_writel(pcie, PCIE_LINK_DOWN_RST,
		                    PCIE_GLBL_CORE_CONFIG_REG);
	}

#ifdef CONFIG_EXTD_INTR_PIN
	cortina_pcie_writel(pcie, val, lut->reg);
#else
	cortina_pcie_writel(pcie, val, PCIE_GLBL_INTERRUPT_0);
#endif

	return IRQ_HANDLED;
}

static int cortina_pcie_ltssm(struct cortina_pcie *pcie)
{
	u32 reg, val;

	reg = PCIE_GLBL_PM_INFO_RESET_VOLT_LOW_PWR_STATUS;
	val = cortina_pcie_readl(pcie, reg);
	val = (val & PWR_STATUS_SMLH_LTSSM_STATE_MASK) >>
	      PWR_STATUS_SMLH_LTSSM_STATE_OFFSET;

	return val;
}


static void dw_pcie_link_check(struct dw_pcie *pci, u8 *speed, u8 *lanes)
{
	u32 val;

	val = readb(pci->dbi_base + 0x82);
	if (speed)
		*speed = val & PCI_EXP_LNKSTA_CLS;
	if (lanes)
		*lanes = (val & PCI_EXP_LNKSTA_NLW) >> 4;
}

static int cortina_pcie_host_init(struct dw_pcie_rp *pp)
{
	struct dw_pcie *pci = to_dw_pcie_from_pp(pp);
	struct cortina_pcie *pcie = to_cortina_pcie(pci);
	int ret;

	cortina_pcie_writel(pcie, 0, PCIE_GLBL_INTERRUPT_ENABLE_0);

	cortina_pcie_host_reset(pcie, SERDES_PHY_INIT);
	cortina_pcie_host_setup(pcie);

	dw_pcie_setup_rc(pp);

	cortina_pcie_establish_link(pci);

	ret = dw_pcie_wait_for_link(pci);
	if (ret) {
		int ltssm = cortina_pcie_ltssm(pcie);

		dev_err(pci->dev,
		        "Link Fail!!!(ltssm = 0x%x - %s)\n",
		        ltssm, ltssm_str(ltssm));
		return (ltssm == LTSSM_DETECT_QUIET ?
		        -ENODEV : -EIO);
	}

	{
		u8 speed, lanes;

		dw_pcie_link_check(pci, &speed, &lanes);
		dev_info(pci->dev, "Speed Gen%d Lanes x%d", speed, lanes);
	}

	cortina_pcie_enable_interrupts(pcie);

	return 0;
}

static void cortina_pcie_intx_host_init(struct dw_pcie_rp *pp)
{
	struct dw_pcie *pci = to_dw_pcie_from_pp(pp);
	struct device *dev = pci->dev;
	struct device_node *node = dev->of_node;
	struct device_node *pcie_intc_node = of_get_next_child(node, NULL);

	if (IS_ERR(pcie_intc_node)) {
		dev_err(dev, "No PCIe Intc node found(%ld)\n",
			PTR_ERR(pcie_intc_node));
		return;
	}

	pp->irq_domain = irq_domain_add_linear(pcie_intc_node,
					       MAX_INTX_HOST_IRQS,
					       &intx_domain_ops, pp);
	if (IS_ERR(pp->irq_domain)) {
		dev_err(dev, "Failed to get a INTx IRQ domain(%ld)\n",
			PTR_ERR(pp->irq_domain));
		return;
	}

	of_node_put(pcie_intc_node);
}

static int taurus_pcie_msi_host_init(struct dw_pcie_rp *pp)
{
	return dw_pcie_msi_host_init(pp);
}

static const struct dw_pcie_host_ops cortina_pcie_host_ops = {
	.init = cortina_pcie_host_init,
	.post_init = cortina_pcie_intx_host_init,
	.msi_init = taurus_pcie_msi_host_init,
};

static bool cortina_pcie_link_up(struct dw_pcie *pci)
{
	struct cortina_pcie *pcie = to_cortina_pcie(pci);
	u32 reg, val;

	reg = PCIE_GLBL_PM_INFO_RESET_VOLT_LOW_PWR_STATUS;
	val = cortina_pcie_readl(pcie, reg);
	val &= PWR_STATUS_RDLH_LINK_UP;

	return val ? true : false;
}

#if 0
static u32 cortina_pcie_read_dbi(struct dw_pcie *pci, void __iomem *base,
                                 u32 reg, size_t size)
{
	struct cortina_pcie *pcie = to_cortina_pcie(pci);
	u32 val;
	u32 offset;
	int ret;

	if (reg >= DEFAULT_DBI_ATU_OFFSET) {
		if (!pcie->iatu_unroll_start) {
			dev_err(pci->dev, "iatu_unroll_base is missed\n");
			return 0;
		}

		offset = reg - DEFAULT_DBI_ATU_OFFSET;

		if (size == 4)
			val = readl(pcie->iatu_unroll_base + offset);
		else if (size == 2)
			val = readw(pcie->iatu_unroll_base + offset);
		else if (size == 1)
			val = readb(pcie->iatu_unroll_base + offset);
		else
			return 0;
	} else {
		ret = dw_pcie_read(base + reg, size, &val);
		if (ret)
			dev_err(pci->dev, "%s read DBI failed\n", __func__);
	}

	return val;
}

static void cortina_pcie_write_dbi(struct dw_pcie *pci, void __iomem *base,
                                   u32 reg, size_t size, u32 val)
{
	struct cortina_pcie *pcie = to_cortina_pcie(pci);
	u32 offset;
	int ret;

	if (reg >= DEFAULT_DBI_ATU_OFFSET) {
		if (!pcie->iatu_unroll_start) {
			dev_err(pci->dev, "iatu_unroll_base is missed\n");
			return;
		}

		offset = reg - DEFAULT_DBI_ATU_OFFSET;

		if (size == 4)
			writel(val, pcie->iatu_unroll_base + offset);
		else if (size == 2)
			writew(val, pcie->iatu_unroll_base + offset);
		else if (size == 1)
			writeb(val, pcie->iatu_unroll_base + offset);
		else
			return;
	} else {
		ret = dw_pcie_write(base + reg, size, val);
		if (ret)
			dev_err(pci->dev, "%s write DBI failed\n", __func__);
	}
}
#endif

static const struct dw_pcie_ops ca_pcie_ops = {
	.link_up = cortina_pcie_link_up,
	.start_link = cortina_pcie_establish_link,
	.stop_link = cortina_pcie_stop_link,

};

#ifdef CONFIG_EXTD_INTR_PIN
static int rtk_pcie_request_extended_irqs(struct platform_device *pd, struct cortina_pcie *pcie)
{
	struct device *dev = &pd->dev;
	int i, ret, irq, bound, nr_cpus;
	char *name;

	nr_cpus = num_online_cpus();
	bound = min(MAX_INTR_PINS, nr_cpus);
	for (i = 1; i < bound; i++) {
		if (test_bit(i, pcie->intr_en_bitmap)) {
			irq = platform_get_irq(pd, i); 
			if (irq < 0)
				return irq;
			#define NAME_LEN 32
			name = kmalloc(NAME_LEN, GFP_KERNEL);
			snprintf(name, NAME_LEN, "taurus-pcie%dintr%d", pcie->idx, i);

			pcie->luts[i].pcie = (void*)pcie;
			pcie->luts[i].reg  = PCIE_GLBL_INTERRUPT_2 + ((i-1)*8);
			pcie->luts[i].irq  = irq;

			ret = devm_request_irq(dev, irq, cortina_pcie_irq_handler,
			                       IRQF_NO_THREAD, name, &pcie->luts[i]);
			if (ret) {
				dev_err(dev, "Failed to request irq for pin[%d] (%d)\n", i, ret);
				return ret;
			}

			dev_info(dev, "pcie extended interrupt pin[%d] irq is %d\n", i, irq);

			irq_set_affinity(irq, cpumask_of(i));
		}
	}

	return 0;
}
#endif

static int __init cortina_add_pcie_port(struct cortina_pcie *pcie,
                                        struct platform_device *pdev)
{
	struct dw_pcie *pci = pcie->pci;
	struct dw_pcie_rp *pp = &pci->pp;
	struct device *dev = pci->dev;
	struct resource *res;
	int ret;

	pp->irq = platform_get_irq(pdev, 0);
	if (pp->irq < 0)
		return pp->irq;

	pcie->luts[0].pcie = (void*)pcie;
	pcie->luts[0].reg  = PCIE_GLBL_INTERRUPT_0;
	pcie->luts[0].irq  = pp->irq;

	ret = devm_request_irq(dev, pp->irq, cortina_pcie_irq_handler,
	                       IRQF_SHARED | IRQF_PROBE_SHARED, dev_name(dev), &pcie->luts[0]);
	if (ret) {
		dev_err(dev, "fail to request irq\n");
		return ret;
	}

#ifdef CONFIG_EXTD_INTR_PIN
	rtk_pcie_request_extended_irqs(pdev, pcie);
#endif

	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "rc_dbi");
	pci->dbi_base = devm_ioremap_resource(dev, res);
	if (!pci->dbi_base)
		return -ENOMEM;

	dev_info(dev, "resource - %pr mapped at 0x%llx\n", res,
	         (u64)pci->dbi_base);

	pcie->dbi_start = res->start;
	pcie->dbi_end = res->end;

	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "iatu");
	pcie->iatu_unroll_base = devm_ioremap_resource(dev, res);
	if (IS_ERR(pcie->iatu_unroll_base)) {
		ret = PTR_ERR(pcie->iatu_unroll_base);
		return ret;
	}

	pci->atu_base = pcie->iatu_unroll_base;
	if (!pcie->iatu_unroll_base) {
		dev_info(dev, "outbound iATU not used\n");
		pcie->iatu_unroll_start = 0;
	} else {
		dev_info(dev, "outbound iATU enable\n");
		pcie->iatu_unroll_start = res->start;
	}

	pp->ops = &cortina_pcie_host_ops;

	ret = dw_pcie_host_init(pp);
	if (ret) {
		dev_err(dev, "Failed to initialize host(%d)\n", ret);
		return ret;
	}

#if defined(CONFIG_RTK_PCIE_AFFINITY) && !defined(CONFIG_EXTD_INTR_PIN)
	if (pcie->irq_affinity >= 0) {
		if (irq_set_affinity(pp->irq, cpumask_of(pcie->irq_affinity))) {
			dev_info(dev, "unable to set irq affinity (irq=%d, cpu=%u)\n",
			         pp->irq,  pcie->irq_affinity);
		}
	}
#endif

	return 0;
}

enum chip_rev {
	REV_A = 0,
	REV_B,
	REV_CNT,
};

const char *cfg_ver_str[] = {
	"serdes-cfg-verA",
	"serdes-cfg-verB",
};

const char *cfg_data_str[] = {
	"serdes-cfg-dataA",
	"serdes-cfg-dataB",
};

static void __serdes_probe_chip_rev_aware(struct device *dev, struct device_node *np,
                                          struct cortina_pcie *pcie)
{
	int rev, lane, i, size, cnt, ret;
	struct taurus_soc_data soc;

	memset(&soc, 0, sizeof(soc));
	ret = taurus_soc_data_get(&soc);

	switch (soc.chip_revision) {
	case 'A':
		rev = REV_A;
		break;
	case 'B':
	default:
		rev = REV_B;
		break;
	}
	dev_info(dev, "Chip revision is %d using params %s\n", soc.chip_revision, cfg_ver_str[rev]);

	ret = of_property_read_string(np, cfg_ver_str[rev], &pcie->serdes_cfg_ver);
	if (ret) {
		pcie->serdes_cfg_ver = CA_PCIE_SERDES_CFG_VER_UNKNOWN;
	}

	size = sizeof(struct serdes_cfg);

	for (lane = 0; lane < pcie->lanes; lane++) {
		pcie->cfg_cnt[lane] = of_property_count_elems_of_size(np, cfg_data_str[rev],
		                   size);
		if (pcie->cfg_cnt[lane] < 1) {
			pcie->cfg_cnt[lane] = 0;
			continue;
		}

		pcie->cfg[lane] = devm_kmalloc_array(dev, pcie->cfg_cnt[lane], size,
		                                  GFP_KERNEL);
		cnt = pcie->cfg_cnt[lane] * size / sizeof(u32);
		of_property_read_u32_array(np, cfg_data_str[rev], (u32 *)pcie->cfg[lane], cnt);
	}

	for (lane = 0; lane < pcie->lanes; lane++) {
		if (pcie->cfg_cnt[lane] <= 0 || !pcie->cfg[lane])
			continue;

		for (i = 0; i < pcie->cfg_cnt[lane]; i++) {
			pcie->cfg[lane][i].addr += pcie->serdes_addr + 0x1000*lane;

		}
	}
}

static void cortina_serdes_probe(struct device *dev, struct device_node *np,
                                 struct cortina_pcie *pcie)
{
	int i, size, cnt, ret;
	char name[MAX_NAME_LEN];

	ret = of_property_read_string(np, "serdes-cfg-ver", &pcie->serdes_cfg_ver);
	if (ret) {

		return __serdes_probe_chip_rev_aware(dev, np, pcie);
	}

	size = sizeof(struct serdes_cfg);

	for (i = 0; i < pcie->lanes; i++) {
		snprintf(name, MAX_NAME_LEN, "serdes-cfg%d", i);
		pcie->cfg_cnt[i] = of_property_count_elems_of_size(np, name,
		                   size);
		if (pcie->cfg_cnt[i] < 1) {
			pcie->cfg_cnt[i] = 0;
			continue;
		}

		pcie->cfg[i] = devm_kmalloc_array(dev, pcie->cfg_cnt[i], size,
		                                  GFP_KERNEL);
		cnt = pcie->cfg_cnt[i] * size / sizeof(u32);
		of_property_read_u32_array(np, name, (u32 *)pcie->cfg[i], cnt);
	}
}

#ifdef CONFIG_RTK_PCIE_AFFINITY
static void __init rtk_pcie_get_affinity(struct device *dev, struct cortina_pcie *pcie)
{
	u32 affinity_cpu = 0;
	struct device_node *np = dev->of_node;

	if (of_property_read_u32(np, "irq-affinity", &affinity_cpu)) {
		pcie->irq_affinity = -1;
		dev_info(dev, "irq-affinity is not assigned\n");
	} else {
		if (affinity_cpu < nr_cpu_ids) {
			pcie->irq_affinity = affinity_cpu;
			dev_info(dev, "irq-affinity cpu: %d, nr_cpu_ids(%d)\n", pcie->irq_affinity, nr_cpu_ids);
		} else {
			dev_info(dev, "irq-affinity cpu: %d >= nr_cpu_ids(%d)\n", pcie->irq_affinity, nr_cpu_ids);
		}
	}
}
#endif

static void __maybe_unused rtk_pcie_set_default_msi_intr_mask(struct cortina_pcie *pcie)
{
	int i;
	pcie->luts[0].mask = 0xffffffff;
	for (i = 1; i < MAX_INTR_PINS; i++) {
		pcie->luts[i].mask = 0x0;
	}
}

static void __maybe_unused rtk_pcie_show_msi_intr_mask(struct cortina_pcie *pcie)
{
	int i;

	printk("MSI mask for each interrupt pin:\n");
	for (i = 0; i < MAX_INTR_PINS; i++) {
		printk("INTR[%d]: 0x%08x\n", i, pcie->luts[i].mask);
	}
}

static int cortina_pcie_reboot_notifier(struct notifier_block *nb,
				    unsigned long code, void *data)
{
#if 0 
	struct cortina_pcie *pcie;

	pcie = container_of(nb, struct cortina_pcie, reboot_nb);
	if (code == SYS_DOWN || code == SYS_HALT) {

		reset_control_assert(pcie->device_reset);
	}
#endif

	return NOTIFY_DONE;
}

static int cortina_pcie_probe(struct platform_device *pdev)
{
	struct dw_pcie *pci;
	struct cortina_pcie *pcie;
	struct device *dev = &pdev->dev;
	struct device_node *np = dev->of_node;
	struct resource *reg_res;
	int lanes, i, ret;
	char name[MAX_NAME_LEN];
	char *pcie_name = NULL;

	pcie = devm_kzalloc(dev, sizeof(*pcie), GFP_KERNEL);
	if (!pcie)
		return -ENOMEM;

	pci = devm_kzalloc(dev, sizeof(*pci), GFP_KERNEL);
	if (!pci)
		return -ENOMEM;

	pci->dev = dev;
	pci->ops = &ca_pcie_ops;

	pcie->pci = pci;

	pcie->bus_clk = devm_clk_get(dev, NULL);
	if (IS_ERR(pcie->bus_clk)) {
		dev_err(dev, "Failed to get pcie bus clk\n");
		return PTR_ERR(pcie->bus_clk);
	}

	ret = clk_prepare_enable(pcie->bus_clk);
	if (ret)
		return ret;

	reg_res = platform_get_resource_byname(pdev, IORESOURCE_MEM,
	                                       "glbl_regs");
	pcie->reg_base = devm_ioremap_resource(dev, reg_res);
	if (IS_ERR(pcie->reg_base)) {
		ret = PTR_ERR(pcie->reg_base);
		goto fail_bus_clk;
	}
	dev_info(dev, "resource - %pr mapped at 0x%llx\n", reg_res,
	         (u64)pcie->reg_base);

	if (of_property_read_u32(np, "id", &pcie->idx)) {
		dev_err(dev, "missing id property\n");
		goto fail_bus_clk;
	}
	dev_info(dev, "id %d\n", pcie->idx);

	ret = of_property_read_u32(np, "num-lanes", &lanes);
	if (ret || lanes < 1 || lanes > MAX_LANE_NUM)
		pcie->lanes = 1;
	else
		pcie->lanes = lanes;
	dev_info(dev, "num-lanes %d\n", pcie->lanes);

	reg_res = platform_get_resource_byname(pdev, IORESOURCE_MEM,
	                                       "serdes_phy");
	pcie->serdes_base = devm_ioremap_resource(dev, reg_res);
	if (IS_ERR(pcie->serdes_base)) {
		ret = PTR_ERR(pcie->serdes_base);
		goto fail_bus_clk;
	}
	dev_info(dev, "resource - %pr mapped at 0x%llx\n", reg_res,
	         (u64)pcie->serdes_base);

	pcie->serdes_addr = reg_res->start;
	pcie->serdes_size = resource_size(reg_res);

	for (i = 0; i < MAX_LANE_NUM; i++)
		pcie->cfg[i] = NULL;

	cortina_serdes_probe(dev, np, pcie);

#if 0
	if (of_property_read_bool(np, "auto-calibration"))
		pcie->auto_calibration = true;
	else
		pcie->auto_calibration = false;
#endif

	pcie->core_reset = of_reset_control_get(np, "core_reset");
	if (IS_ERR(pcie->core_reset)) {
		dev_err(dev, "failed to get core_reset\n");
		ret = PTR_ERR(pcie->core_reset);
		goto fail_bus_clk;
	}

	pcie->phy_reset = of_reset_control_get(np, "phy_reset");
	if (IS_ERR(pcie->phy_reset)) {
		dev_err(dev, "failed to get phy_reset\n");
		ret = PTR_ERR(pcie->phy_reset);
		goto fail_bus_clk;
	}

	pcie->device_reset = of_reset_control_get(np, "device_reset");
	if (IS_ERR(pcie->device_reset)) {
		dev_err(dev, "failed to get device_reset\n");
		ret = PTR_ERR(pcie->device_reset);
		goto fail_bus_clk;
	}

	pcie->device_power = of_reset_control_get(np, "device_power");
	if (!IS_ERR_OR_NULL(pcie->device_power)) {
		reset_control_reset(pcie->device_power);
	}

	for (i = 0; i < MAX_LANE_NUM; i++) {
		snprintf(name, MAX_NAME_LEN, "pcie-phy%d", i);
		pcie->phy[i] = devm_phy_get(&pdev->dev, name);
		if (IS_ERR(pcie->phy[i])) {
			ret = PTR_ERR(pcie->phy[i]);
			pcie->phy[i] = NULL;
		}
	}

	for (i = 0; i < pcie->lanes; i++) {
		if (!pcie->phy[i]) {
			dev_err(dev, "failed to get phy %d\n", i);
			goto fail_bus_clk;
		}
	}

#if 0
	ret = of_property_read_u16(np, "ready-time",
	                           &pcie->device_ready_time);
	if (ret)
		pcie->device_ready_time = 0;
#endif

#ifdef CONFIG_RTK_PCIE_AFFINITY
	rtk_pcie_get_affinity(dev, pcie);
#endif

	rtk_pcie_set_default_msi_intr_mask(pcie);

#ifdef CONFIG_EXTD_INTR_PIN
	set_bit(0, pcie->intr_en_bitmap); 

	do {
		u32 intr_mask[MAX_INTR_PINS];
		int sz;
		#define MSI_INTR_MASK_STR "msi-intr-mask"
		sz = of_property_count_elems_of_size(np, MSI_INTR_MASK_STR, sizeof(u32));
		if (sz < 0)
			sz = MAX_INTR_PINS;
		sz = min(sz, MAX_INTR_PINS);
		ret = of_property_read_u32_array(np, MSI_INTR_MASK_STR, intr_mask, sz);
		if (ret == 0) {
			int i;
			for (i=0; i<sz; i++)
				pcie->luts[i].mask = intr_mask[i];
		} else if (ret < 0) {
			dev_warn(dev, "MSI mask for extended interrupt pin is not set\n");
		}

		for (i=0; i<sz; i++) {
			if (pcie->luts[i].mask)
				set_bit(i, pcie->intr_en_bitmap);
		}
	} while (0);
	rtk_pcie_show_msi_intr_mask(pcie);
#endif

	pcie->reboot_nb.notifier_call = cortina_pcie_reboot_notifier;
	ret = register_reboot_notifier(&pcie->reboot_nb);
	if (ret) {
		dev_warn(dev, "Cannot register reboot notifier (%d)\n", ret);
	}

	platform_set_drvdata(pdev, pcie);

	if (of_property_read_bool(np, "forced-gen1")) {
		pci->max_link_speed = 1;
	}

	if (of_property_read_string(np, "pdev-name",
				    (const char **)&pcie_name) == 0) {
		kobject_set_name(&pci->dev->kobj, "%s", pcie_name);
	}

	ret = cortina_add_pcie_port(pcie, pdev);
	if (ret < 0)
		goto fail_bus_clk;

	ret = sysfs_create_group(&pci->dev->kobj,
	                         &cortina_pcie_attr_group);
	if (ret) {
		dev_err(dev, "failed to register sysfs\n");
		goto fail_bus_clk;
	}

	return 0;

fail_bus_clk:

	ret = sysfs_create_group(&pci->dev->kobj,
				 &cortina_pcie_dbg_attr_group);
	if (ret)
		dev_err(dev, "failed to register sysfs for debug\n");

	if (pcie->reboot_nb.notifier_call)
		unregister_reboot_notifier(&pcie->reboot_nb);

	if (pcie->device_reset)
		reset_control_put(pcie->device_reset);
	if (pcie->phy_reset)
		reset_control_put(pcie->phy_reset);
	if (pcie->core_reset)
		reset_control_put(pcie->core_reset);
	for (i = 0; i < pcie->lanes; i++)
		phy_power_off(pcie->phy[i]);

	clk_disable_unprepare(pcie->bus_clk);

	return ret;
}

static void __exit cortina_pcie_remove(struct platform_device *pdev)
{
	struct cortina_pcie *pcie = platform_get_drvdata(pdev);
	struct dw_pcie *pci = pcie->pci;
	struct dw_pcie_rp *pp = &pci->pp;

	sysfs_remove_group(&pdev->dev.kobj, &cortina_pcie_attr_group);

	dw_pcie_host_deinit(pp);

#if 0
	int i;

	for (i = 0; i < pcie->lanes; i++)
		phy_power_off(pcie->phy[i]);
#endif
	if (pcie->reboot_nb.notifier_call)
		unregister_reboot_notifier(&pcie->reboot_nb);

	if (pcie->device_reset)
		reset_control_put(pcie->device_reset);
#if 0
	clk_disable_unprepare(pcie->bus_clk);

	if (pcie->device_reset)
		reset_control_put(pcie->device_reset);
	if (pcie->phy_reset)
		reset_control_put(pcie->phy_reset);
	if (pcie->core_reset)
		reset_control_put(pcie->core_reset);
#endif
}

static const struct of_device_id cortina_pcie_of_match[] = {
	{
		.compatible = "realtek,taurus-pcie",
	},
	{},
};
MODULE_DEVICE_TABLE(of, cortina_pcie_of_match);

static struct platform_driver cortina_pcie_driver = {
	.probe		= cortina_pcie_probe,
	.remove		= cortina_pcie_remove,
	.driver = {
		.name = "taurus-pcie",
		.of_match_table = of_match_ptr(cortina_pcie_of_match),
	},
};

static int __init cortina_pcie_init(void)
{
	return platform_driver_register(&cortina_pcie_driver);
}
late_initcall(cortina_pcie_init);

static void __exit cortina_pcie_exit(void)
{
	platform_driver_unregister(&cortina_pcie_driver);
}
module_exit(cortina_pcie_exit);

MODULE_DESCRIPTION("Realtek Taurus PCIe host controller driver");
MODULE_LICENSE("GPL v2");
