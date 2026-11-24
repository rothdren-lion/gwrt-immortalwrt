// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PON link state: activation, MAC preparation entry points, carrier and the
 * per-LLID registration observation exposed through sysfs.
 */
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/etherdevice.h>
#include <linux/rtnetlink.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/epon/epon.h"
/* Stock aal_epon_fec_cfg_set and RTL8277C usFecState_set keep the
 * 1G encoder, payload scheduler and REPORT accounting consistent. */
static void rtl_pon_fec_set(const struct rtl_dq_io *io, enum rtl_pon_mode mode, int enable)
{
	unsigned int value;

	if (mode == RTL_PON_EPON_BI10G) {
		value = io->read(io->context, 0x24);
		io->write(io->context, 0x24, (value & ~1U) | !enable);
		return;
	}
	value = io->read(io->context, 0x810);
	io->write(io->context, 0x810, (value & ~2U) | (enable ? 2 : 0));
	value = io->read(io->context, 0x8050);
	io->write(io->context, 0x8050, (value & ~(1U << 20)) | (enable ? 1U << 20 : 0));
	value = io->read(io->context, 0x8054);
	io->write(io->context, 0x8054, (value & ~(1U << 20)) | (enable ? 1U << 20 : 0));
}

#define PON_EPON_MODE BIT(0)
#define EPON_STATUS 0x0010
#define MPCP_REGISTERED 0x2014

int rtl_pon_stop_locked(struct rtl9617c_pon *pon)
{
	int ret;

	lockdep_assert_held(&pon->control_lock);
	if (rtl_pon_mode_is_epon(pon->mode)) {
		int stopped;

		ret = rtl_pon_epon_traffic_locked(pon, false);
		stopped = rtl_pon_mpcp_stop_locked(pon);
		if (!ret)
			ret = stopped;
	} else {
		gpiod_set_value_cansleep(pon->tx_disable, 1);
		ret = 0;
		if (pon->mode == RTL_PON_GPON)
			rtl_pon_gpon_stop_locked(pon);
		else
			rtl_pon_xgpon_stop_locked(pon);
	}
	return ret;
}


static ssize_t state_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	u32 control = readl(pon->control);
	u32 status = 0, registered = 0;

	if (!(control & PON_EPON_MODE))
		return sysfs_emit(buf, "family=gpon control=%08x serdes_reset_n=%u register_reset_n=%u\n",
			control, !!(control & BIT(1)), !!(control & BIT(2)));
	status = readl(pon->mac + EPON_STATUS);
	registered = readl(pon->mac + MPCP_REGISTERED);
	return sysfs_emit(buf,
		"family=%s control=%08x serdes_reset_n=%u register_reset_n=%u epon_status=%08x signal_loss=%u pcs10g_sync=%u pcs1g_sync=%u registered_llids=%08x\n",
		control & PON_EPON_MODE ? "epon" : "gpon",
		control, !!(control & BIT(1)), !!(control & BIT(2)), status,
		!!(status & BIT(0)), !!(status & BIT(1)), !!(status & BIT(2)), registered);
}
DEVICE_ATTR_RO(state);

static ssize_t led_state_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	unsigned int enabled, state = 0;
	ssize_t size;

	mutex_lock(&pon->lock);
	if (rtl_pon_mode_is_epon(pon->mode)) {
		enabled = pon->mpcp_enabled;
	} else if (pon->mode == RTL_PON_GPON) {
		enabled = pon->gpon_enabled;
		state = (readl(pon->mac + RTL_GPON_60BC) >> 16) & 7;
	} else {
		enabled = pon->xgpon_enabled;
		state = readl(pon->mac + RTL_XGTC_4D30) & 7;
	}
	/* One snapshot prevents a mode switch from mixing EPON and ITU registers. */
	size = sysfs_emit(buf, "mode=%s enabled=%u los=%u state=%u registered=%u session=%llu\n",
		rtl_pon_mode_name(pon->mode), enabled, !!(readl(pon->optical_status) & BIT(3)),
		state, !!(pon->registered & 1), pon->itu_line_epoch);
	mutex_unlock(&pon->lock);
	return size;
}
DEVICE_ATTR_RO(led_state);


static ssize_t mac_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	ssize_t size;
	mutex_lock(&pon->lock);
	size = rtl_pon_mode_is_epon(pon->mode) ? rtl_pon_epon_state(pon, buf) : rtl_pon_itu_state(pon, buf);
	mutex_unlock(&pon->lock);
	return size;
}

static ssize_t mac_store(struct device *dev, struct device_attribute *attr,
			const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	bool prepare;
	int ret = kstrtobool(buf, &prepare);
	if (ret)
		return ret;
	if (!prepare)
		return -EINVAL;
	mutex_lock(&pon->control_lock);
	if (rtl_pon_mode_is_epon(pon->mode))
		ret = rtl_pon_epon_prepare_locked(pon);
	else if (pon->mode == RTL_PON_GPON)
		ret = rtl_pon_gpon_prepare_locked(pon);
	else
		ret = rtl_pon_xgpon_prepare_locked(pon);
	mutex_unlock(&pon->control_lock);
	return ret ? ret : count;
}
DEVICE_ATTR_RW(mac);

static ssize_t activation_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	ssize_t size;

	mutex_lock(&pon->lock);
	if (rtl_pon_mode_is_epon(pon->mode)) {
		mutex_unlock(&pon->lock);
		return -EOPNOTSUPP;
	}
	if (pon->mode == RTL_PON_XGPON || pon->mode == RTL_PON_XGSPON) {
		/* XG-PON keys OMCC to XGEM 1..7 by ONU-ID: there is no single gem
		 * id, so the column reports n/a instead of repeating omcc_onu_id. */
		size = sysfs_emit(buf, "enabled=%u omcc=%u omcc_onu_id=%u omcc_gem=%s error=%d irq_count=%llu last_irq=%08x key_ready=%u key_state=%u active_key=%u key_reports=%llu tk4=%llu tk5=%llu recovering=%u last_events=%08x deactivations=%llu mac_resets=%llu reset_reason=%u health_matches=%u restore_pending=%u dying_gasp_ready=%u dying_gasp_tx=%llu dying_gasp_error=%d\n",
			pon->xgpon_enabled, pon->xgpon_omcc_ready, pon->xgpon_omcc_id,
			"n/a", pon->xgpon_activation_error, pon->xgpon_irq_count,
			pon->xgpon_last_irq, pon->xgpon_key_ready, pon->xgpon_key_state,
			pon->xgpon_active_key + 1, pon->xgpon_key_reports, pon->xgpon_key_tk4,
			pon->xgpon_key_tk5, pon->xgpon_recover, pon->xgpon_last_transitions,
			pon->xgpon_deactivations, pon->xgpon_mac_resets, pon->xgpon_reset_reason,
			pon->xgpon_health_matches, pon->xgpon_restore_pending,
			!!READ_ONCE(pon->dying_gasp_packet), READ_ONCE(pon->dying_gasp_tx),
			READ_ONCE(pon->dying_gasp_error));
		mutex_unlock(&pon->lock);
		return size;
	}
	size = sysfs_emit(buf,
		"enabled=%u omcc=%u omcc_onu_id=%u omcc_gem=%u ds_fec=%u error=%d irq_count=%llu last_irq=%08x key_switches=%llu recovering=%u\n",
		pon->gpon_enabled, pon->gpon_omcc_ready, pon->gpon_omcc_onu_id,
		pon->gpon_omcc_gem, pon->gpon_ds_fec, pon->gpon_activation_error,
		pon->gpon_irq_count, pon->gpon_last_irq, pon->gpon_key_switches, pon->gpon_recover);
	mutex_unlock(&pon->lock);
	return size;
}

static ssize_t activation_store(struct device *dev, struct device_attribute *attr,
				const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	bool enable;
	int ret = kstrtobool(buf, &enable);

	if (ret)
		return ret;
	mutex_lock(&pon->control_lock);
	if (rtl_pon_mode_is_epon(pon->mode))
		ret = -EOPNOTSUPP;
	else
		ret = pon->mode == RTL_PON_GPON ? rtl_pon_gpon_activation_locked(pon, enable) :
			rtl_pon_xgpon_activation_locked(pon, enable);
	mutex_unlock(&pon->control_lock);
	return ret ? ret : count;
}
DEVICE_ATTR_RW(activation);

static unsigned int rtl_fec_read(void *context, unsigned int reg)
{
	struct rtl9617c_pon *pon = context;

	return readl(pon->mac + reg);
}

static void rtl_fec_write(void *context, unsigned int reg, unsigned int value)
{
	struct rtl9617c_pon *pon = context;

	writel(value, pon->mac + reg);
}

static ssize_t fec_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	ssize_t size;

	mutex_lock(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode))
		size = -EOPNOTSUPP;
	else
		size = sysfs_emit(buf, "supported=1 upstream=%u encoder=%08x btc=%08x report=%08x\n",
			pon->mode == RTL_PON_EPON_BI10G ? !(readl(pon->mac + RTL_EPON_0024) & BIT(0)) :
			!!(readl(pon->mac + RTL_EPON_0810) & BIT(1)), readl(pon->mac + RTL_EPON_0810),
			readl(pon->mac + BTC), readl(pon->mac + REPORT));
	mutex_unlock(&pon->lock);
	return size;
}

static ssize_t fec_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	const struct rtl_dq_io io = {pon, rtl_fec_read, rtl_fec_write, NULL};
	bool enable;
	int ret = kstrtobool(buf, &enable);

	if (ret)
		return ret;
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode) || !pon->mac_prepared)
		ret = -EOPNOTSUPP;
	else {
		rtl_pon_fec_set(&io, pon->mode, enable);
		if (!enable && pon->mode != RTL_PON_EPON_BI10G)
			msleep(5);
	}
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	return ret ? ret : count;
}
DEVICE_ATTR_RW(fec);


static ssize_t onu_mac_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	return sysfs_emit(buf, "%pM\n", pon->onu_mac);
}

static ssize_t onu_mac_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	u8 mac[ETH_ALEN];
	if (!mac_pton(buf, mac) || !is_valid_ether_addr(mac))
		return -EINVAL;
	mutex_lock(&pon->control_lock);
	rtnl_lock();
	mutex_lock(&pon->lock);
	if (pon->mpcp_enabled) {
		mutex_unlock(&pon->lock);
		rtnl_unlock();
		mutex_unlock(&pon->control_lock);
		return -EBUSY;
	}
	ether_addr_copy(pon->onu_mac, mac);
	mutex_unlock(&pon->lock);
	rtl_pon_oam_address(pon);
	rtl_pon_data_address(pon);
	rtnl_unlock();
	mutex_unlock(&pon->control_lock);
	return count;
}
DEVICE_ATTR_RW(onu_mac);

static ssize_t factory_onu_mac_show(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	return sysfs_emit(buf, "%pM\n", pon->factory_mac);
}
DEVICE_ATTR_RO(factory_onu_mac);


static ssize_t traffic_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	struct net_device *oam = pon->oam_endpoint.netdev;
	unsigned long received = 0, transmitted = 0, receive_drops = 0, transmit_drops = 0;
	unsigned int i;

	if (!rtl_pon_mode_is_epon(READ_ONCE(pon->mode)))
		return -EOPNOTSUPP;
	rcu_read_lock();
	for (i = 0; i < 32; i++) {
		struct net_device *port = rcu_dereference(pon->oam_devices[i]);

		if (port) {
			received += port->stats.rx_packets;
			transmitted += port->stats.tx_packets;
			receive_drops += port->stats.rx_dropped;
			transmit_drops += port->stats.tx_dropped;
		}
	}
	rcu_read_unlock();

	return sysfs_emit(buf, "enabled=%u oam_device=%s carrier=%u last_llid=%u last_source=%u rx=%lu tx=%lu rx_dropped=%lu tx_dropped=%lu\n",
		pon->traffic_enabled, oam->name, netif_carrier_ok(oam),
		READ_ONCE(pon->last_oam_llid), READ_ONCE(pon->last_oam_source),
		received, transmitted, receive_drops, transmit_drops);
}

static ssize_t traffic_store(struct device *dev, struct device_attribute *attr,
			    const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	bool enable;
	int ret = kstrtobool(buf, &enable);

	if (ret)
		return ret;
	ret = rtl_pon_epon_traffic(pon, enable);
	return ret ? ret : count;
}
DEVICE_ATTR_RW(traffic);