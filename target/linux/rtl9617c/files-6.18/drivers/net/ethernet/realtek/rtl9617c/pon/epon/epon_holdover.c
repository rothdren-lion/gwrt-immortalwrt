// SPDX-License-Identifier: GPL-2.0-or-later
/* EPON registration holdover timer and its sysfs binary attribute. */
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/unaligned.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "pon/epon/epon.h"


u32 rtl_mpcp_holdover(struct rtl9617c_pon *pon, u32 registered)
{
	u32 status = readl(pon->mac + RTL_EPON_0010);
	bool synced = !(status & BIT(0)) &&
		(status & (pon->mode == RTL_PON_EPON_1G ? BIT(2) : BIT(1)));
	unsigned long delay = MAX_JIFFY_OFFSET;
	unsigned long now = jiffies;
	unsigned int channel;
	int error = 0;

	pon->epon_holdover_active = 0;
	pon->epon_holdover_pending &= registered;
	if (synced || !pon->mpcp_enabled) {
		pon->epon_holdover_pending = 0;
		cancel_delayed_work(&pon->epon_holdover_work);
		return registered;
	}
	for (channel = 0; channel < pon->llid_count; channel++) {
		unsigned long until;
		int ret;

		if (!(registered & BIT(channel)))
			continue;
		if (!(pon->epon_holdover_pending & BIT(channel))) {
			pon->epon_holdover_start[channel] = now;
			pon->epon_holdover_pending |= BIT(channel);
		}
		until = pon->epon_holdover_start[channel];
		if (pon->epon_holdover_enabled & BIT(channel))
			until += msecs_to_jiffies(pon->epon_holdover_ms[channel]);
		if (time_before(now, until)) {
			pon->epon_holdover_active |= BIT(channel);
			delay = min(delay, until - now);
			continue;
		}
		/* Stock Holdover expiry reaches llid_entry_set(enable=0), whose
		 * AAL asserts this per-MAC offline bit before deleting the LLID. */
		rtl_pon_update(pon->mac + OFFLINE, BIT(channel), BIT(channel));
		ret = readl_poll_timeout(pon->mac + REGISTER_STATUS, status,
			!(status & BIT(channel)), 1, 10000);
		if (ret) {
			error = ret;
			dev_err_ratelimited(pon->dev, "EPON holdover LLID%u offline failed: %d\n", channel, ret);
			delay = min(delay, (unsigned long)HZ);
		} else {
			registered &= ~BIT(channel);
			pon->epon_holdover_pending &= ~BIT(channel);
		}
	}
	if (pon->epon_holdover_pending)
		mod_delayed_work(system_wq, &pon->epon_holdover_work, delay);
	pon->epon_holdover_error = error;
	return registered;
}


void rtl_mpcp_holdover_work(struct work_struct *work)
{
	struct rtl9617c_pon *pon = container_of(to_delayed_work(work), struct rtl9617c_pon, epon_holdover_work);

	mutex_lock(&pon->lock);
	if (pon->mpcp_enabled)
		rtl_mpcp_refresh(pon);
	mutex_unlock(&pon->lock);
}

int rtl_pon_epon_holdover_set(struct rtl9617c_pon *pon, const u8 *data, size_t count)
{
	unsigned int channel;
	int ret = 0;

	if (count != 12 || data[9] > 1)
		return -EINVAL;
	channel = data[0];
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
		pon->epon_holdover_enabled &= ~BIT(channel);
		if (data[9])
			pon->epon_holdover_enabled |= BIT(channel);
		pon->epon_holdover_ms[channel] = get_unaligned_be16(data + 10);
		pon->epon_holdover_error = 0;
		rtl_mpcp_refresh(pon);
		ret = pon->epon_holdover_error;
	}
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	return ret;
}


static ssize_t epon_holdover_read(struct file *file, struct kobject *kobj,
	const struct bin_attribute *attr, char *buf, loff_t offset, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(kobj_to_dev(kobj));
	unsigned int channel = offset / 4;
	int ret = 4;

	if (offset % 4 || channel >= 32 || count < 4)
		return -EINVAL;
	mutex_lock(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode))
		ret = -EOPNOTSUPP;
	else if (channel >= pon->llid_count)
		ret = -EINVAL;
	else {
		put_unaligned_be16(!!(pon->epon_holdover_enabled & BIT(channel)), buf);
		put_unaligned_be16(pon->epon_holdover_ms[channel], buf + 2);
	}
	mutex_unlock(&pon->lock);
	return ret;
}

static ssize_t epon_holdover_write(struct file *file, struct kobject *kobj,
	const struct bin_attribute *attr, char *buf, loff_t offset, size_t count)
{
	if (offset)
		return -EINVAL;
	return rtl_pon_epon_holdover_set(dev_get_drvdata(kobj_to_dev(kobj)), buf, count) ?: count;
}
BIN_ATTR(epon_holdover, 0600, epon_holdover_read, epon_holdover_write, 128);
