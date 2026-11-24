// SPDX-License-Identifier: GPL-2.0-or-later
/* MPCP state and LLID table formatting; the protocol engine lives in mpcp.c and
 * keeps the same text for sysfs and debugfs. */
#include <linux/device.h>
#include <linux/seq_file.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/epon/epon.h"

ssize_t rtl_pon_mpcp_state(struct rtl9617c_pon *pon, char *buf)
{
	unsigned int channel;
	ssize_t length = sysfs_emit(buf,
		"configured=%u enabled=%u mac=%pM llids=%u registered=%08x waiting=%08x attempts=%u events=%u irq_count=%u frames=%u cfg0=%08x cfg=%08x sync=%08x timers=%08x register_timeout=%08x laser_time=%08x mapping=%08x init=%08x start=%08x register_flag=%u nacks=%u silence_scope=shared-engine silence_ms=%u epochs=",
		pon->mpcp_configured, pon->mpcp_enabled, pon->onu_mac, pon->llid_count,
		pon->registered, pon->waiting, pon->registration_attempts, pon->registration_events,
		pon->mpcp_irq_count, pon->register_frames, readl(pon->mac + MPCP_CFG0),
		readl(pon->mac + MPCP_CFG), readl(pon->mac + SYNC_TIME),
		readl(pon->mac + TIMEOUT_THRESHOLD), readl(pon->mac + REGISTER_TIMEOUT),
		readl(pon->mac + LASER_TIME), readl(pon->mac + LLID_MAPPING),
		readl(pon->mac + MPCP_INIT), readl(pon->mac + MPCP_START),
		pon->backoff.register_flag, pon->backoff.nacks,
		pon->backoff.active && time_before(jiffies, pon->backoff.until) ?
		jiffies_to_msecs(pon->backoff.until - jiffies) : 0);
	for (channel = 0; channel < 32; channel++)
		length += sysfs_emit_at(buf, length, "%s%016llx", channel ? "," : "", pon->epon_llid_epoch[channel]);
	return length + sysfs_emit_at(buf, length,
		" holdover=%08x holdover_error=%d llid_cleanup=%08x llid_cleanup_error=%d\n",
		pon->epon_holdover_active, pon->epon_holdover_error,
		pon->epon_llid_cleanup, pon->epon_llid_cleanup_error);
}

ssize_t rtl_pon_llid_table(struct rtl9617c_pon *pon, char *buf)
{
	ssize_t length = 0;
	unsigned int i;
	for (i = 0; i < 64; i++) {
		u32 value = readl(pon->mac + LLID_TABLE + i * 4);
		if (!(value & BIT(23)))
			continue;
		length += scnprintf(buf + length, PAGE_SIZE - length,
			"entry=%u index=%u mac=%u llid=%04x multicast=%u\n", i,
			(unsigned int)FIELD_GET(GENMASK(21, 16), value),
			(unsigned int)FIELD_GET(GENMASK(28, 24), value), value & 0xffff, !!(value & BIT(22)));
	}
	return length;
}

static ssize_t mpcp_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	ssize_t size;
	mutex_lock(&pon->lock);
	size = rtl_pon_mode_is_epon(pon->mode) ? rtl_pon_mpcp_state(pon, buf) : -EOPNOTSUPP;
	mutex_unlock(&pon->lock);
	return size;
}

static ssize_t mpcp_store(struct device *dev, struct device_attribute *attr,
			 const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	bool enabled;
	int ret = kstrtobool(buf, &enabled);
	if (ret)
		return ret;
	if (enabled)
		ret = rtl_pon_mpcp_configure(pon);
	else
		ret = rtl_pon_mpcp_stop(pon);
	return ret ? ret : count;
}
DEVICE_ATTR_RW(mpcp);
