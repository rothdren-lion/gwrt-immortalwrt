// SPDX-License-Identifier: GPL-2.0-or-later

/* Native EPON PUC scheduler and queues, from GPL aal_puc.c. */

#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/unaligned.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "rtl9617c_ni.h"

static int rtl_puc_access(struct rtl9617c_pon *pon, unsigned int reg,
			  unsigned int index, bool write)
{
	u32 status;
	writel(BIT(31) | (write ? BIT(30) : 0) | index, pon->mac + reg);
	return readl_poll_timeout(pon->mac + reg, status, !(status & BIT(31)), 1, 100000);
}

static int rtl_puc_port(struct rtl9617c_pon *pon, unsigned int port,
			unsigned int queues, bool enabled)
{
	u32 data[5] = {};
	unsigned int cos;

	/* Eight nine-bit queue fields span DATA0..2; zero weights select SP. */
	for (cos = 0; cos < 8; cos++) {
		unsigned int bit = cos * 9;
		u32 queue = enabled && cos < queues ? port * queues + cos : 0;
		u64 field = queue | (enabled && cos < queues ? BIT(8) : 0);

		data[bit / 32] |= field << (bit % 32);
		if (bit % 32 > 23)
			data[bit / 32 + 1] |= field >> (32 - bit % 32);
	}
	if (enabled)
		data[2] |= BIT(12);
	for (cos = 0; cos < 5; cos++)
		writel(data[cos], pon->mac + PVT_DATA0 - cos * 4);
	return rtl_puc_access(pon, PVT_ACCESS, port, true);
}

int rtl_puc_token_buckets(struct rtl9617c_pon *pon, unsigned int first)
{
	unsigned int queue;
	int ret;

	for (queue = first; queue < 256; queue++) {
		/* Stock EPON queue_add uses CIR=0, PIR=32767999. */
		writel(0, pon->mac + CIR_DATA0);
		writel(2 << 6, pon->mac + CIR_DATA1);
		ret = rtl_puc_access(pon, CIR_ACCESS, queue, true);
		if (ret)
			return ret;
		/* ca-ne.ko aal_puc_init @0x1af080 and ca-rtk.ko
		 * dal_rtl8277c_ponmac_queue_add @0x3c8 encode maximum PIR as
		 * rate_k=1023, rate_m=65535, burst=4095, enable=2.
		 * The API sentinel 32767999 is not a packed register word. */
		writel(~0U, pon->mac + PIR_DATA0);
		writel((2 << 6) | 0x3f, pon->mac + PIR_DATA1);
		ret = rtl_puc_access(pon, PIR_ACCESS, queue, true);
		if (ret)
			return ret;
	}
	return 0;
}

unsigned int rtl_puc_bp_read(void *context, unsigned int reg)
{
	struct rtl9617c_pon *pon = context;

	return readl(pon->mac + reg);
}

void rtl_puc_bp_write(void *context, unsigned int reg, unsigned int value)
{
	struct rtl9617c_pon *pon = context;

	writel(value, pon->mac + reg);
}

int rtl_puc_bp_access(void *context, unsigned int reg, unsigned int value)
{
	struct rtl9617c_pon *pon = context;
	u32 status;

	writel(value, pon->mac + reg);
	return readl_poll_timeout(pon->mac + reg, status, !(status & BIT(31)), 1,
		reg == 0x80dc ? 1000000 : 100000);
}


int __rtl_pon_puc_configure(struct rtl9617c_pon *pon)
{
	u32 status;
	unsigned int i, ports = pon->llid_count;
	unsigned int queues = ports > 16 ? 4 : 8;
	int ret;
	const struct rtl_dq_io bp = {pon, rtl_puc_bp_read, rtl_puc_bp_write, rtl_puc_bp_access};

	lockdep_assert_held(&pon->control_lock);
	lockdep_assert_held(&pon->lock);
	if (!pon->mac_prepared) {
		ret = -EAGAIN;
		goto unlock;
	}
	pon->puc_configured = false;
	memset(pon->epon_sla_length, 0, sizeof(pon->epon_sla_length));
	if (!rtl_pon_mode_is_epon(pon->mode)) {
		ret = rtl_puc_itu_configure(pon, &bp);
		pon->puc_configured = !ret;
		goto unlock;
	}
	ret = rtl9617c_ni_report_configure(pon->ni_dev,
		pon->mode == RTL_PON_EPON_BI10G ? 100 : 82, 220);
	if (ret)
		goto unlock;
	rtl_pon_update(pon->control, BIT(8), BIT(8));
	udelay(500);
	ret = readl_poll_timeout(pon->mac + BM_STATUS, status, status & BIT(0), 1, 100000);
	if (ret)
		goto unlock;
	ret = readl_poll_timeout(pon->mac + PUC_STATUS, status, status & BIT(31), 1, 100000);
	if (ret)
		goto unlock;
	writel(0, pon->mac + PUC_IE);
	/* Explicit RTL8277C OAM container addresses and EtherTypes. */
	writel(0x25000001, pon->mac + RTL_PUC_8154);
	writel(0x00000013, pon->mac + RTL_PUC_8150);
	writel(0x00132500, pon->mac + RTL_PUC_814C);
	writel(0xfff00000, pon->mac + RTL_PUC_8158);
	writel(0xfff10000, pon->mac + RTL_PUC_815C);
	rtl_pon_update(pon->mac + PUC_CONFIG, GENMASK(1, 0) | GENMASK(18, 16) | BIT(30),
		2 | BIT(30)); /* CRC regenerate, counters retained, invalid queue drop. */
	/* Reference-unit queue limits.  The MPCP REPORT engine reports these byte
	 * budgets to the OLT's DBA; with the smaller defaults the reported
	 * occupancy never matches what the OLT expects and it reclaims the LLID
	 * roughly every 97 s. */
	writel(0xc00, pon->mac + LIMIT_A);
	writel(0x700, pon->mac + LIMIT_A + 4);
	writel(0x200, pon->mac + LIMIT_A + 8);
	for (i = 0; i < 16; i++)
		writel(0x55555555, pon->mac + LIMIT_SELECT + i * 4);
	writel(queues == 4 ? 1 : 0, pon->mac + VOQ_MODE);
	for (i = 0; i < 64; i++) {
		/* Port 0 is the LLID data port, port 7 is stock nas0 business
		 * egress and port 12 is the OAM physical port (NI7 queue 9). */
		ret = rtl_puc_port(pon, i, queues, i < ports || i == 7 || i == 12);
		if (ret)
			goto unlock;
	}
	for (i = 0; i < 8; i++) {
		unsigned int active = ports * queues;
		unsigned int data_first = 7 * queues;
		unsigned int oam_first = 12 * queues;
		u32 valid = 0;
		unsigned int q;

		for (q = 0; q < 256; q++) {
			bool enabled = q < active ||
				(q >= data_first && q < data_first + queues) ||
				(q >= oam_first && q < oam_first + queues);

			if (enabled && q / 32 == i)
				valid |= BIT(q % 32);
		}
		/* Queue127 is the stock special control queue. */
		if (i == 3)
			valid |= BIT(31);
		writel(valid, pon->mac + VALID_VOQ0 - i * 4);
	}
	rtl_pon_update(pon->mac + REPORT,
		GENMASK(1, 0) | BIT(24) | BIT(28) | BIT(30) | BIT(31), 1 | BIT(24));
	writel(0xffff8000, pon->mac + REPORT_Q12);
	writel(0x80008000, pon->mac + REPORT_Q34);
	if (pon->mode == RTL_PON_EPON_BI10G) {
		rtl_pon_update(pon->mac + RTL_PUC_80FC, GENMASK(14, 0), 0x100);
		rtl_pon_update(pon->mac + RTL_PUC_80F8, BIT(28) | GENMASK(14, 12),
			(pon->llid_count == 1 ? BIT(28) : 0) | (2 << 12));
	}
	rtl_pon_update(pon->mac + BACKPRESSURE, BIT(0) | BIT(4) | GENMASK(30, 16),
		BIT(0) | (0x100 << 16));
	rtl_pon_update(pon->mac + BTC,
		GENMASK(5, 0) | BIT(8) | BIT(12) | BIT(25) | GENMASK(31, 27), 20 | BIT(8));
	writel(pon->mode == RTL_PON_EPON_BI10G ? 0x0a000000 : 0x55550000, pon->mac + RTL_PUC_8230);
	writel(pon->mode == RTL_PON_EPON_BI10G ? 0xf0001400 : 0xffffaaaa, pon->mac + RTL_PUC_8234);
	/* Reference PUC scheduling: the stock enables the 29/28/24 selects and
	 * the 0x7c sub-field set; without them the queue scheduler behaviour the
	 * OLT expects on this port is not reproduced. */
	rtl_pon_update(pon->mac + CONTROL, GENMASK(30, 24) | GENMASK(6, 2),
		       BIT(30) | BIT(29) | BIT(28) | BIT(24) | 0x7c);
	rtl_pon_update(pon->mac + CONTROL1, GENMASK(14, 0), 20 | (20 << 5) | (20 << 10));
	rtl_pon_update(pon->mac + CONTROL2, GENMASK(26, 24) | GENMASK(4, 0),
		       BIT(26) | BIT(25) | BIT(24) | 20);
	/* Stock dal_rtl8277c_ponmac_queue_add() ends with
	 * aal_puc_voq_drop_set(0, 3, cfg): cfg[0] is the physical VOQ index
	 * and cfg[1] is 0. The last queue added by stock is queue 0, so the
	 * resulting 0x80e0 state has low byte 0 and bit31 clear. Reproduce
	 * that state; the register is the PUC VOQ drop selector. */
	rtl_pon_update(pon->mac + RTL_PUC_80E0, GENMASK(7, 0) | BIT(31), 0);
	ret = rtl_puc_token_buckets(pon, 0);
	if (ret)
		goto unlock;
	ret = rtl_pon_queue_backpressure(&bp);
	if (ret)
		goto unlock;
	/* The final RTL8277C DAL stage enables both schedulers after AAL setup. */
	rtl_pon_update(pon->mac + BTC, BIT(24) | BIT(25), BIT(24) | BIT(25));
	rtl_pon_update(pon->mac + AGGREGATE0, GENMASK(25, 0), 0);
	rtl_pon_update(pon->mac + AGGREGATE1, GENMASK(11, 0), 0);
	pon->puc_configured = true;
	for (i = 0; i < 8; i++) {
		pon->epon_sla_length[i] = 1;
		pon->epon_sla[i][0] = 0;
	}
	dev_info(pon->dev, "PUC: %u LLID ports, %u queues each, 256 CIR/PIR entries\n", ports, queues);
unlock:
	pon->puc_error = ret;
	pon_dbg("puc configure: ret=%d configured=%u\n", ret, pon->puc_configured);
	return ret;
}

int rtl_pon_puc_configure_locked(struct rtl9617c_pon *pon)
{
	int ret;

	mutex_lock(&pon->lock);
	ret = __rtl_pon_puc_configure(pon);
	mutex_unlock(&pon->lock);
	return ret;
}

ssize_t rtl_pon_puc_state(struct rtl9617c_pon *pon, char *buf)
{
	static const unsigned int sample[] = {0, 7, 127, 255};
	ssize_t length;
	unsigned int i;
	int ret;

	length = sysfs_emit(buf,
		"configured=%u error=%d bm=%08x status=%08x config=%08x mode=%08x btc=%08x report=%08x thresholds=%08x/%08x limits=%08x/%08x/%08x backpressure=%08x valid=%08x/%08x/%08x/%08x ni_report=%08x\n",
		pon->puc_configured, pon->puc_error, readl(pon->mac + BM_STATUS), readl(pon->mac + PUC_STATUS),
		readl(pon->mac + PUC_CONFIG), readl(pon->mac + VOQ_MODE), readl(pon->mac + BTC),
		readl(pon->mac + REPORT), readl(pon->mac + REPORT_Q12), readl(pon->mac + REPORT_Q34),
		readl(pon->mac + LIMIT_A), readl(pon->mac + LIMIT_A + 4), readl(pon->mac + LIMIT_A + 8),
		readl(pon->mac + BACKPRESSURE), readl(pon->mac + VALID_VOQ0),
		readl(pon->mac + VALID_VOQ0 - 4), readl(pon->mac + VALID_VOQ0 - 8),
		readl(pon->mac + VALID_VOQ0 - 12), rtl9617c_ni_report_state(pon->ni_dev));
	for (i = 0; i < 2; i++) {
		ret = rtl_puc_access(pon, PVT_ACCESS, i, false);
		if (ret)
			return ret;
		length += scnprintf(buf + length, PAGE_SIZE - length, "port%u=%08x/%08x/%08x/%08x/%08x\n",
			i, readl(pon->mac + PVT_DATA0), readl(pon->mac + PVT_DATA0 - 4),
			readl(pon->mac + PVT_DATA0 - 8), readl(pon->mac + PVT_DATA0 - 12),
			readl(pon->mac + PVT_DATA0 - 16));
	}
	for (i = 0; i < ARRAY_SIZE(sample); i++) {
		ret = rtl_puc_access(pon, CIR_ACCESS, sample[i], false);
		if (ret)
			return ret;
		length += scnprintf(buf + length, PAGE_SIZE - length, "cir%u=%08x/%08x ",
			sample[i], readl(pon->mac + CIR_DATA0), readl(pon->mac + CIR_DATA1));
		ret = rtl_puc_access(pon, PIR_ACCESS, sample[i], false);
		if (ret)
			return ret;
		length += scnprintf(buf + length, PAGE_SIZE - length, "pir%u=%08x/%08x\n",
			sample[i], readl(pon->mac + PIR_DATA0), readl(pon->mac + PIR_DATA1));
	}
	for (i = 0; i < ARRAY_SIZE(sample); i++) {
		ret = rtl_puc_access(pon, 0x80e8, sample[i], false);
		if (ret)
			return ret;
		length += scnprintf(buf + length, PAGE_SIZE - length, "bp%u=%u\n",
			sample[i], readl(pon->mac + RTL_PUC_80EC) & 255);
	}
	return length;
}


static ssize_t puc_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	ssize_t size;
	mutex_lock(&pon->lock);
	size = rtl_pon_puc_state(pon, buf);
	mutex_unlock(&pon->lock);
	return size;
}

static ssize_t puc_store(struct device *dev, struct device_attribute *attr,
			const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	bool enabled;
	int ret = kstrtobool(buf, &enabled);
	if (ret)
		return ret;
	if (!enabled)
		return -EINVAL;
	ret = rtl_pon_puc_configure(pon);
	return ret ? ret : count;
}
DEVICE_ATTR_RW(puc);
