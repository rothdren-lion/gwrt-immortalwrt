// SPDX-License-Identifier: GPL-2.0-or-later
/* Native EPON MAC/PCS/FEC setup and the LLID table; GPL aal_epon_mac.c. */
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/unaligned.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "pon/epon/epon.h"

int rtl_pon_llid_update(struct rtl9617c_pon *pon, bool add, unsigned int index,
			 unsigned int mac, u16 llid, bool multicast)
{
	u32 status;
	int ret;

	writel(llid | (index << 16) | ((u32)multicast << 22) |
	       ((u32)add << 23) | (mac << 24), pon->mac + LLID_DATA);
	writel(BIT(0), pon->mac + LLID_ACCESS);
	ret = readl_poll_timeout(pon->mac + LLID_ACCESS, status, !(status & BIT(0)), 1, 100000);
	if (ret)
		return ret;
	status = readl(pon->mac + LLID_RESULT) & 7;
	if (add && (status == 6 || status == 7))
		return 0;
	if (!add && status == 5)
		return 0;
	if (status == 1)
		return -ENOSPC;
	if (status == 2)
		return -ENOENT;
	return -EIO;
}

static int rtl_epon_tx_apply(struct rtl9617c_pon *pon)
{
	bool disabled = pon->epon_tx_action || !pon->traffic_enabled;
	int state;

	gpiod_set_value_cansleep(pon->tx_disable, disabled);
	state = gpiod_get_value_cansleep(pon->tx_disable);
	pon->epon_tx_error = state < 0 ? state : state == disabled ? 0 : -EIO;
	return pon->epon_tx_error;
}

static void rtl_epon_tx_work(struct work_struct *work)
{
	struct rtl9617c_pon *pon = container_of(to_delayed_work(work), struct rtl9617c_pon, epon_tx_work);

	mutex_lock(&pon->lock);
	if (pon->epon_tx_action && pon->epon_tx_action != 0xffff) {
		unsigned long now = jiffies;

		if (time_before(now, pon->epon_tx_until)) {
			mod_delayed_work(system_wq, &pon->epon_tx_work, pon->epon_tx_until - now);
		} else {
			pon->epon_tx_action = 0;
			if (rtl_epon_tx_apply(pon))
				dev_err(pon->dev, "EPON timed TX restore failed: %d\n", pon->epon_tx_error);
		}
	}
	mutex_unlock(&pon->lock);
}

void rtl_pon_epon_tx_init(struct rtl9617c_pon *pon)
{
	INIT_DELAYED_WORK(&pon->epon_tx_work, rtl_epon_tx_work);
}

int rtl_pon_epon_tx_control(struct rtl9617c_pon *pon, const u8 *data, size_t count)
{
	unsigned int channel, action;
	int ret;

	if (count != 11)
		return -EINVAL;
	channel = data[0];
	action = get_unaligned_be16(data + 9);
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode))
		ret = -EOPNOTSUPP;
	else if (channel >= pon->llid_count)
		ret = -EINVAL;
	else if (!pon->mpcp_enabled || !(pon->registered & BIT(channel)))
		ret = -EAGAIN;
	else if (get_unaligned_be64(data + 1) != pon->epon_llid_epoch[channel])
		ret = -ESTALE;
	else {
		/* Stock actions: 0 resumes, 0xffff inhibits indefinitely, otherwise
		 * inhibit for N seconds. The shared timer always follows the latest
		 * command, including when an older worker is already waiting. */
		pon->epon_tx_action = action;
		ret = rtl_epon_tx_apply(pon);
		if (action && action != 0xffff) {
			pon->epon_tx_until = jiffies + msecs_to_jiffies(action * 1000);
			mod_delayed_work(system_wq, &pon->epon_tx_work, msecs_to_jiffies(action * 1000));
		} else {
			cancel_delayed_work(&pon->epon_tx_work);
		}
	}
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	return ret;
}

static void rtl_epon_csr_reset(struct rtl9617c_pon *pon)
{
	u32 reset = GENMASK(3, 0) | GENMASK(7, 5);

	rtl_pon_update(pon->epon_control, reset, 0);
	msleep(100);
	rtl_pon_update(pon->epon_control, reset | GENMASK(18, 16), reset | (3 << 16));
	msleep(100);
	writel(0x30f, pon->control);
	msleep(100);
}

static void rtl_epon_fec_configure(struct rtl9617c_pon *pon)
{
	/* 1G upstream begins without FEC; the OAM negotiation changes it later. */
	if (pon->mode != RTL_PON_EPON_BI10G) {
		rtl_pon_update(pon->mac + FEC_1G, BIT(1), 0);
		msleep(5);
		rtl_pon_update(pon->mac + PUC_BTC, BIT(20), 0);
		rtl_pon_update(pon->mac + PUC_REPORT, BIT(20), 0);
	}
	if (pon->mode == RTL_PON_EPON_1G) {
		rtl_pon_update(pon->mac + FEC_1G, BIT(0), 0);
		rtl_pon_update(pon->mac + EPON_MISC, BIT(19) | BIT(20), BIT(20));
	} else {
		/* XG RX mode2 selects automatic FEC detection. */
		rtl_pon_update(pon->mac + EPON_FEC_XG, GENMASK(5, 4), 2 << 4);
		if (pon->mode == RTL_PON_EPON_BI10G)
			rtl_pon_update(pon->mac + EPON_FEC_XG, BIT(0), 0);
	}
}

int rtl_pon_epon_prepare_locked(struct rtl9617c_pon *pon)
{
	u32 status, drop_mask = GENMASK(19, 13) | GENMASK(29, 26);
	unsigned int onu_mode;
	int ret;

	lockdep_assert_held(&pon->control_lock);
	if (!rtl_pon_mode_is_epon(pon->mode))
		return -EOPNOTSUPP;
	ret = rtl_pon_stop_locked(pon);
	mutex_lock(&pon->lock);
	pon->mac_prepared = false;
	if (ret)
		goto unlock;
	onu_mode = rtl_pon_modes[pon->mode].epon_onu_mode;
	if (!pon->serdes_configured) {
		ret = -EAGAIN;
		goto unlock;
	}
	pon->mac_prepared = false;
	pon->pdc_configured = false;
	pon->puc_configured = false;
	pon->traffic_enabled = false;
	rtl_epon_csr_reset(pon);
	rtl_pon_update(pon->mac + MIB_CTRL, BIT(0), 0);
	rtl_pon_update(pon->mac + LINK_DETECT, GENMASK(13, 8), 0x3f << 8);
	rtl_pon_update(pon->epon_control, BIT(18), 0);
	writel(0x5000, pon->mac + PCS_RX);
	writel(0x03020000, pon->mac + PCS_TX);
	writel((0x59 << 16) | 0x48, pon->mac + RTT_RX);
	writel((0x18 << 16) | 0x16, pon->mac + RTT_TX);
	rtl_pon_update(pon->mac + RX_LOCALTIME, GENMASK(16, 0), 0x10006);
	/* Normal MPCP-controlled laser bursts, matching aal_epon_mac_init. */
	rtl_pon_update(pon->mac + EPON_STATIC, BIT(1), 0);
	rtl_pon_update(pon->mac + EPON_MISC, GENMASK(1, 0) | BIT(4) | BIT(5), BIT(1));
	rtl_pon_update(pon->mac + PCS_TX, GENMASK(20, 16), 2 << 16);
	/* Match the stock MAC's special/control frame routing and error drops. */
	rtl_pon_update(pon->mac + RX_DROP, drop_mask, drop_mask & ~BIT(28));
	rtl_pon_update(pon->epon_control, GENMASK(17, 16), onu_mode << 16);
	rtl_pon_update(pon->mac + RX_XG, BIT(7) | BIT(9) | GENMASK(30, 17),
		BIT(9) | (EPON_FRAME_LIMIT << 17));
	rtl_pon_update(pon->mac + TX_XG, BIT(3) | GENMASK(18, 12), 12 << 12);
	rtl_pon_update(pon->mac + RX_1G, BIT(0), 0);
	rtl_pon_update(pon->mac + TX_1G,
		BIT(0) | BIT(1) | BIT(3) | GENMASK(23, 20) | BIT(25) | BIT(30), 0);
	rtl_pon_update(pon->mac + MAX_PACKET_1G, GENMASK(13, 0), EPON_FRAME_LIMIT);
	rtl_pon_update(pon->control, BIT(1), 0);
	msleep(1);
	rtl_pon_update(pon->control, BIT(1), BIT(1));
	if (pon->mode == RTL_PON_EPON_1G) {
		status = readl(pon->mac + EPON_STATIC) & BIT(0);
		rtl_pon_update(pon->mac + EPON_STATIC, BIT(0), status ^ BIT(0));
		msleep(1);
		rtl_pon_update(pon->mac + EPON_STATIC, BIT(0), status);
	}
	rtl_pon_update(pon->mac + MIB_CTRL, BIT(1), BIT(1));
	rtl_pon_update(pon->mac + MIB_CTRL, BIT(1), 0);
	ret = readl_poll_timeout(pon->mac + MIB_STATUS, status, status & BIT(0), 1, 100000);
	if (ret)
		goto unlock;
	memset(pon->epon_mib_total, 0, sizeof(pon->epon_mib_total));
	pon->epon_mib_generation++;
	rtl_pon_update(pon->mac + RX_MPCP_MIB, BIT(17), BIT(17));
	rtl_pon_update(pon->mac + TX_MPCP_MIB, BIT(17), BIT(17));
	rtl_epon_fec_configure(pon);
	{
		const struct rtl_dq_io io = {pon, rtl_crypto_read, rtl_crypto_write, rtl_crypto_indirect};

		rtl_epon_crypto_profile(&io, pon->mode);
		ret = rtl_pon_epon_crypto_forget(pon, 0xff);
		if (ret)
			goto unlock;
	}
	/* PCS/FEC configuration precedes enabling the PON burst output. */
	rtl_pon_update(pon->serdes_init, BIT(4), BIT(4));
	pon->mac_prepared = true;
	dev_info(pon->dev, "%s MAC/PCS/FEC prepared; MIB RAM initialized\n", rtl_pon_mode_name(pon->mode));
unlock:
	pon->mac_error = ret;
	mutex_unlock(&pon->lock);
	return ret;
}

int rtl_pon_epon_traffic_locked(struct rtl9617c_pon *pon, bool enable)
{
	int ret = 0;

	lockdep_assert_held(&pon->control_lock);
	if (!enable) {
		mutex_lock(&pon->lock);
		pon->traffic_enabled = false;
		gpiod_set_value_cansleep(pon->tx_disable, 1);
		mutex_unlock(&pon->lock);
	}
	mutex_lock(&pon->lock);
	if (enable && (!pon->puc_configured || !pon->pdc_configured ||
		       !netif_running(pon->oam_endpoint.netdev))) {
		ret = -EAGAIN;
		goto unlock;
	}
	rtl_pon_update(pon->mac + RX_XG, BIT(7),
		enable && pon->mode != RTL_PON_EPON_1G ? BIT(7) : 0);
	rtl_pon_update(pon->mac + TX_XG, BIT(3),
		enable && pon->mode == RTL_PON_EPON_BI10G ? BIT(3) : 0);
	rtl_pon_update(pon->mac + RX_1G, BIT(0),
		enable && pon->mode == RTL_PON_EPON_1G ? BIT(0) : 0);
	rtl_pon_update(pon->mac + TX_1G, BIT(0),
		enable && pon->mode != RTL_PON_EPON_BI10G ? BIT(0) : 0);
	pon->traffic_enabled = enable;
	if (rtl_epon_tx_apply(pon) && !ret)
		ret = pon->epon_tx_error;
	rtl_pon_oam_carrier(pon);
unlock:
	mutex_unlock(&pon->lock);
	return ret;
}

ssize_t rtl_pon_epon_state(struct rtl9617c_pon *pon, char *buf)
{
	return sysfs_emit(buf,
		"prepared=%u error=%d epon_control=%08x rx_xg=%08x tx_xg=%08x rx_1g=%08x tx_1g=%08x pcs_rx=%08x pcs_tx=%08x xg_fec=%08x fec_1g=%08x drop=%08x mib_ctrl=%08x mib_status=%08x rtt_rx=%08x rtt_tx=%08x crypto_llids=%08x crypto_error=%d rx_resets=%llu link_events=%llu tx_control_action=%u tx_control_error=%d\n",
		pon->mac_prepared, pon->mac_error, readl(pon->epon_control),
		readl(pon->mac + RX_XG), readl(pon->mac + TX_XG), readl(pon->mac + RX_1G),
		readl(pon->mac + TX_1G), readl(pon->mac + PCS_RX), readl(pon->mac + PCS_TX),
		readl(pon->mac + EPON_FEC_XG), readl(pon->mac + FEC_1G), readl(pon->mac + RX_DROP),
		readl(pon->mac + MIB_CTRL), readl(pon->mac + MIB_STATUS),
		readl(pon->mac + RTT_RX), readl(pon->mac + RTT_TX),
		pon->epon_crypto_llids, pon->epon_crypto_error, pon->epon_rx_resets, pon->epon_link_events,
		pon->epon_tx_action, pon->epon_tx_error);
}

static ssize_t llid_count_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	if (!rtl_pon_mode_is_epon(READ_ONCE(pon->mode)))
		return -EOPNOTSUPP;
	return sysfs_emit(buf, "%u\n", pon->llid_count);
}

static ssize_t llid_count_store(struct device *dev, struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	unsigned int value;
	int ret = kstrtouint(buf, 0, &value);
	if (ret)
		return ret;
	if (!value || value > 32)
		return -EINVAL;
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode)) {
		mutex_unlock(&pon->lock);
		mutex_unlock(&pon->control_lock);
		return -EOPNOTSUPP;
	}
	if (pon->mpcp_enabled) {
		mutex_unlock(&pon->lock);
		mutex_unlock(&pon->control_lock);
		return -EBUSY;
	}
	mutex_unlock(&pon->lock);
	ret = rtl_pon_oam_resize(pon, value);
	mutex_lock(&pon->lock);
	if (!ret)
		pon->llid_count = value;
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	return ret ? ret : count;
}
DEVICE_ATTR_RW(llid_count);

static ssize_t llid_table_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	ssize_t size;
	mutex_lock(&pon->lock);
	size = rtl_pon_mode_is_epon(pon->mode) ? rtl_pon_llid_table(pon, buf) : -EOPNOTSUPP;
	mutex_unlock(&pon->lock);
	return size;
}

static ssize_t llid_table_store(struct device *dev, struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	char operation[7];
	unsigned int index, mac, llid, multicast;
	bool add;
	int ret;
	if (sscanf(buf, "%6s %u %u %x %u", operation, &index, &mac, &llid, &multicast) != 5 ||
	    index > 63 || mac > 31 || llid > 0xffff || multicast > 1)
		return -EINVAL;
	if (!strcmp(operation, "add"))
		add = true;
	else if (!strcmp(operation, "delete"))
		add = false;
	else
		return -EINVAL;
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	ret = rtl_pon_mode_is_epon(pon->mode) ?
		rtl_pon_llid_update(pon, add, index, mac, llid, multicast) : -EOPNOTSUPP;
	if (!ret)
		ret = rtl_pon_pdc_refresh(pon);
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	return ret ? ret : count;
}
DEVICE_ATTR_RW(llid_table);

static ssize_t epon_tx_control_write(struct file *file, struct kobject *kobj,
	const struct bin_attribute *attr, char *buf, loff_t offset, size_t count)
{
	if (offset)
		return -EINVAL;
	return rtl_pon_epon_tx_control(dev_get_drvdata(kobj_to_dev(kobj)), buf, count) ?: count;
}
BIN_ATTR(epon_tx_control, 0200, NULL, epon_tx_control_write, 0);
