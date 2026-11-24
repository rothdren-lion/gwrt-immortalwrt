// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/spi/spi.h>
#include <linux/spi/spi-mem.h>

#define TAURUS_QSPI_TYPE		0x0c
#define TAURUS_QSPI_ACCESS_START	0x10
#define TAURUS_QSPI_SF_ACCESS		0x30
#define TAURUS_QSPI_SF_EXT_ACCESS	0x34
#define TAURUS_QSPI_SF_ADDRESS		0x38
#define TAURUS_QSPI_SF_DATA		0x3c

#define TAURUS_QSPI_TYPE_SIZE_MASK	GENMASK(10, 9)
#define TAURUS_QSPI_TYPE_SIZE_4B	(2 << 9)

#define TAURUS_QSPI_START		BIT(1)
#define TAURUS_QSPI_WRITE		BIT(9)
#define TAURUS_QSPI_BUSY		BIT(16)
#define TAURUS_QSPI_BUSY_MASK		(TAURUS_QSPI_BUSY | TAURUS_QSPI_START)

#define TAURUS_QSPI_ACC_CMD		0x0
#define TAURUS_QSPI_ACC_ADDR		(5 << 8)
#define TAURUS_QSPI_ACC_EXTEND		(15 << 8)
#define TAURUS_QSPI_ACC_TERM		BIT(12)
#define TAURUS_QSPI_ACC_BURST		BIT(13)

#define TAURUS_QSPI_ACC_MIO		GENMASK(31, 30)
#define TAURUS_QSPI_ACC_MIO_DATA	BIT(24)
#define TAURUS_QSPI_ACC_MIO_DUAL	1
#define TAURUS_QSPI_ACC_MIO_QUAD	2

#define TAURUS_QSPI_EXT_OPCODE		GENMASK(7, 0)
#define TAURUS_QSPI_EXT_DATA_CNT	GENMASK(20, 8)
#define TAURUS_QSPI_EXT_ADDR_CNT	GENMASK(23, 21)
#define TAURUS_QSPI_EXT_DUMMY_CNT	GENMASK(29, 24)
#define TAURUS_QSPI_EXT_RD_CMD_EN	BIT(31)

#define TAURUS_QSPI_MAX_DATA		2048
#define TAURUS_QSPI_TIMEOUT_US		100000

struct taurus_qspi {
	void __iomem *base;
};

static int taurus_qspi_wait(struct taurus_qspi *qspi)
{
	u32 val;

	return readl_poll_timeout_atomic(qspi->base + TAURUS_QSPI_ACCESS_START,
					 val, !(val & TAURUS_QSPI_BUSY_MASK),
					 0, TAURUS_QSPI_TIMEOUT_US);
}

static int taurus_qspi_kick(struct taurus_qspi *qspi, bool write)
{
	writel(TAURUS_QSPI_START | (write ? TAURUS_QSPI_WRITE : 0),
	       qspi->base + TAURUS_QSPI_ACCESS_START);
	return taurus_qspi_wait(qspi);
}

static unsigned int taurus_qspi_dummy_cycles(const struct spi_mem_op *op)
{
	if (!op->dummy.nbytes)
		return 0;

	return op->dummy.nbytes * 8 / op->dummy.buswidth;
}

static u32 taurus_qspi_access(const struct spi_mem_op *op)
{
	u32 access = TAURUS_QSPI_ACC_EXTEND;

	if (op->data.nbytes > 4)
		access |= TAURUS_QSPI_ACC_BURST;

	switch (op->data.buswidth) {
	case 4:
		access |= TAURUS_QSPI_ACC_MIO_DATA |
			  FIELD_PREP(TAURUS_QSPI_ACC_MIO,
				     TAURUS_QSPI_ACC_MIO_QUAD);
		break;
	case 2:
		access |= TAURUS_QSPI_ACC_MIO_DATA |
			  FIELD_PREP(TAURUS_QSPI_ACC_MIO,
				     TAURUS_QSPI_ACC_MIO_DUAL);
		break;
	}

	return access;
}

static u32 taurus_qspi_ext_access(const struct spi_mem_op *op)
{
	unsigned int dummy = taurus_qspi_dummy_cycles(op);
	u32 addr_cnt = op->addr.nbytes ? op->addr.nbytes - 1 : 0x7;
	u32 dummy_cnt = dummy ? dummy - 1 : 0x3f;

	return FIELD_PREP(TAURUS_QSPI_EXT_OPCODE, op->cmd.opcode) |
	       FIELD_PREP(TAURUS_QSPI_EXT_DATA_CNT, op->data.nbytes - 1) |
	       FIELD_PREP(TAURUS_QSPI_EXT_ADDR_CNT, addr_cnt) |
	       FIELD_PREP(TAURUS_QSPI_EXT_DUMMY_CNT, dummy_cnt) |
	       TAURUS_QSPI_EXT_RD_CMD_EN;
}

static int taurus_qspi_data(struct taurus_qspi *qspi,
			    const struct spi_mem_op *op)
{
	bool out = op->data.dir == SPI_MEM_DATA_OUT;
	bool burst = op->data.nbytes > 4;
	unsigned int offset = 0;
	int ret = 0;

	writel(taurus_qspi_access(op), qspi->base + TAURUS_QSPI_SF_ACCESS);
	writel(0, qspi->base + TAURUS_QSPI_SF_EXT_ACCESS);
	writel(taurus_qspi_ext_access(op),
	       qspi->base + TAURUS_QSPI_SF_EXT_ACCESS);
	if (op->addr.nbytes)
		writel(op->addr.val, qspi->base + TAURUS_QSPI_SF_ADDRESS);

	while (offset < op->data.nbytes) {
		unsigned int n = min_t(unsigned int, op->data.nbytes - offset, 4);
		unsigned int i;

		if (out) {
			const u8 *buf = op->data.buf.out;
			u32 word = 0;

			for (i = 0; i < n; i++)
				word |= (u32)buf[offset + i] << (8 * i);
			writel(word, qspi->base + TAURUS_QSPI_SF_DATA);
		}

		ret = taurus_qspi_kick(qspi, out);
		if (ret)
			break;

		if (!out) {
			u8 *buf = op->data.buf.in;
			u32 word = readl(qspi->base + TAURUS_QSPI_SF_DATA);

			for (i = 0; i < n; i++)
				buf[offset + i] = word >> (8 * i);
		}

		offset += n;
	}

	if (burst) {
		u32 access = readl(qspi->base + TAURUS_QSPI_SF_ACCESS);

		access &= ~TAURUS_QSPI_ACC_BURST;
		access |= TAURUS_QSPI_ACC_TERM;
		writel(access, qspi->base + TAURUS_QSPI_SF_ACCESS);
	}
	writel(0, qspi->base + TAURUS_QSPI_SF_ACCESS);
	writel(0, qspi->base + TAURUS_QSPI_SF_EXT_ACCESS);

	return ret;
}

static int taurus_qspi_exec_op(struct spi_mem *mem,
			       const struct spi_mem_op *op)
{
	struct taurus_qspi *qspi =
		spi_controller_get_devdata(mem->spi->controller);
	u32 type;
	int ret;

	if (op->data.nbytes)
		return taurus_qspi_data(qspi, op);

	type = readl(qspi->base + TAURUS_QSPI_TYPE) &
	       ~TAURUS_QSPI_TYPE_SIZE_MASK;
	if (op->addr.nbytes == 4)
		type |= TAURUS_QSPI_TYPE_SIZE_4B;
	writel(type, qspi->base + TAURUS_QSPI_TYPE);
	writel(op->cmd.opcode |
	       (op->addr.nbytes ? TAURUS_QSPI_ACC_ADDR :
				  TAURUS_QSPI_ACC_CMD),
	       qspi->base + TAURUS_QSPI_SF_ACCESS);
	if (op->addr.nbytes)
		writel(op->addr.val, qspi->base + TAURUS_QSPI_SF_ADDRESS);

	ret = taurus_qspi_kick(qspi, false);
	if (!ret)
		usleep_range(10, 20);
	writel(0, qspi->base + TAURUS_QSPI_SF_ACCESS);
	writel(0, qspi->base + TAURUS_QSPI_SF_EXT_ACCESS);

	return ret;
}

static bool taurus_qspi_supports_op(struct spi_mem *mem,
				    const struct spi_mem_op *op)
{
	if (op->cmd.nbytes != 1 || op->cmd.buswidth != 1)
		return false;
	if (op->addr.nbytes > 4 ||
	    (op->addr.nbytes && op->addr.buswidth != 1))
		return false;
	if (op->dummy.nbytes > 8 ||
	    (op->dummy.nbytes && op->dummy.buswidth != 1))
		return false;
	if (op->cmd.dtr || op->addr.dtr || op->dummy.dtr || op->data.dtr)
		return false;
	if (op->data.dir != SPI_MEM_NO_DATA &&
	    op->data.buswidth != 1 && op->data.buswidth != 2 &&
	    op->data.buswidth != 4)
		return false;
	if (op->data.dir == SPI_MEM_NO_DATA) {
		if (op->dummy.nbytes)
			return false;
		if (op->addr.nbytes && op->addr.nbytes != 3 &&
		    op->addr.nbytes != 4)
			return false;
	}

	return spi_mem_default_supports_op(mem, op);
}

static int taurus_qspi_adjust_op_size(struct spi_mem *mem,
				      struct spi_mem_op *op)
{
	op->data.nbytes = min_t(unsigned int, op->data.nbytes,
				TAURUS_QSPI_MAX_DATA);
	return 0;
}

static const struct spi_controller_mem_ops taurus_qspi_mem_ops = {
	.supports_op = taurus_qspi_supports_op,
	.adjust_op_size = taurus_qspi_adjust_op_size,
	.exec_op = taurus_qspi_exec_op,
};

static int taurus_qspi_probe(struct platform_device *pdev)
{
	struct spi_controller *ctlr;
	struct taurus_qspi *qspi;

	ctlr = devm_spi_alloc_host(&pdev->dev, sizeof(*qspi));
	if (!ctlr)
		return -ENOMEM;

	qspi = spi_controller_get_devdata(ctlr);
	qspi->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(qspi->base))
		return PTR_ERR(qspi->base);

	ctlr->num_chipselect = 1;
	ctlr->mode_bits = SPI_RX_DUAL | SPI_RX_QUAD |
			  SPI_TX_DUAL | SPI_TX_QUAD;
	ctlr->bits_per_word_mask = SPI_BPW_MASK(8);
	ctlr->mem_ops = &taurus_qspi_mem_ops;
	ctlr->dev.of_node = pdev->dev.of_node;
	platform_set_drvdata(pdev, ctlr);

	return devm_spi_register_controller(&pdev->dev, ctlr);
}

static void taurus_qspi_shutdown(struct platform_device *pdev)
{
	struct spi_controller *ctlr = platform_get_drvdata(pdev);
	struct taurus_qspi *qspi;
	u32 type;

	if (!ctlr)
		return;

	spi_controller_suspend(ctlr);
	qspi = spi_controller_get_devdata(ctlr);
	taurus_qspi_wait(qspi);
	writel(0, qspi->base + TAURUS_QSPI_SF_ACCESS);
	writel(0, qspi->base + TAURUS_QSPI_SF_EXT_ACCESS);

	/* Restore default 3-byte addressing and reset SPI-NAND (0xff) so
	 * BootROM/U-Boot always sees the flash in its power-on state.
	 */
	type = readl(qspi->base + TAURUS_QSPI_TYPE) &
	       ~TAURUS_QSPI_TYPE_SIZE_MASK;
	writel(type, qspi->base + TAURUS_QSPI_TYPE);
	writel(0xff | TAURUS_QSPI_ACC_CMD, qspi->base + TAURUS_QSPI_SF_ACCESS);
	taurus_qspi_kick(qspi, false);
	writel(0, qspi->base + TAURUS_QSPI_SF_ACCESS);
	writel(0, qspi->base + TAURUS_QSPI_SF_EXT_ACCESS);
	udelay(1000);
}

static const struct of_device_id taurus_qspi_of_match[] = {
	{ .compatible = "realtek,taurus-qspi" },
	{ }
};
MODULE_DEVICE_TABLE(of, taurus_qspi_of_match);

static struct platform_driver taurus_qspi_driver = {
	.probe = taurus_qspi_probe,
	.shutdown = taurus_qspi_shutdown,
	.driver = {
		.name = "taurus-qspi",
		.of_match_table = taurus_qspi_of_match,
	},
};
module_platform_driver(taurus_qspi_driver);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Realtek Taurus QSPI controller");
