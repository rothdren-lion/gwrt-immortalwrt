// SPDX-License-Identifier: GPL-2.0-or-later
/* EPON SLA/DBA policy: validation, PUC bucket programming and the sysfs blob. */
#include <linux/errno.h>
#include <linux/io.h>
#include <linux/unaligned.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "pon/epon/epon.h"
#define RTL_EPON_SLA_BYTES 88

static unsigned int rtl_epon_sla_u16(const unsigned char *data)
{
	return (unsigned int)data[0] << 8 | data[1];
}

static int rtl_epon_sla_validate(const unsigned char *data, unsigned int size)
{
	unsigned int row;

	if (size == 1)
		return data[0] ? -EINVAL : 0;
	if (size < 18 || data[0] != 1 || data[1] > 1 ||
	    !data[7] || data[7] > 8 || size != 8U + 10U * data[7])
		return -EINVAL;
	for (row = 0; row < data[7]; row++) {
		const unsigned char *queue = data + 8 + row * 10;

		if (rtl_epon_sla_u16(queue + 5) > rtl_epon_sla_u16(queue + 7) ||
		    queue[9] > 100 || (data[1] == 1 && !queue[9]))
			return -EINVAL;
	}
	return 0;
}

/* rt_epon_ponQueue_set scales the wire rate by eight; the actual DAL splits
 * it into /500 and %500 and selects these four burst sizes. Preserve the
 * hardware bucket mode rather than replacing it with a guessed constant. */

static int rtl_epon_sla_bucket(const struct rtl_dq_io *io,
	unsigned int queue, unsigned int rate, int pir)
{
	unsigned int access = pir ? 0x81ec : 0x81c4;
	unsigned int data0 = access + 8, data1 = access + 4;
	unsigned int burst, low, high;
	int ret = io->indirect(io->context, access, 0x80000000U | queue);

	if (ret)
		return ret;
	high = io->read(io->context, data1) & 0x800000c0U;
	if (rate == 0x1f3ffffU) {
		low = pir ? ~0U : 0;
		if (pir)
			high |= 0x3f;
	} else {
		burst = rate < 25000 ? 5 : rate < 50000 ? 10 : rate < 500000 ? 100 : 1000;
		low = rate % 500 | (rate / 500) << 10 | (burst & 63) << 26;
		high |= burst >> 6;
	}
	io->write(io->context, data0, low);
	io->write(io->context, data1, high);
	return io->indirect(io->context, access, 0xc0000000U | queue);
}

static int rtl_epon_sla_flush(const struct rtl_dq_io *io, unsigned int port,
	unsigned int queue)
{
	unsigned int limit_reg = 0x8090 + queue / 16 * 4;
	unsigned int limit, drop, command;
	int ret = io->indirect(io->context, 0x802c, 0x80000000U | queue);

	if (ret)
		return ret;
	if (!io->read(io->context, 0x8034) && !(io->read(io->context, 0x8030) & 7))
		return 0;
	limit = io->read(io->context, limit_reg);
	drop = io->read(io->context, 0x80e0);
	io->write(io->context, 0x80e0, (drop & ~0x800000ffU) | 0x80000000U | queue);
	io->write(io->context, limit_reg, limit & ~(3U << ((queue % 16) * 2)));
	command = (io->read(io->context, 0x80dc) & ~0x80011fffU) |
		0x80000000U | port << 8 | queue;
	ret = io->indirect(io->context, 0x80dc, command);
	io->write(io->context, limit_reg, limit);
	io->write(io->context, 0x80e0, drop);
	if (ret)
		return ret;
	ret = io->indirect(io->context, 0x802c, 0x80000000U | queue);
	if (ret)
		return ret;
	return io->read(io->context, 0x8034) || (io->read(io->context, 0x8030) & 7) ? -EIO : 0;
}

static int rtl_epon_sla_apply(const struct rtl_dq_io *io, unsigned int port,
	const unsigned char *data)
{
	unsigned char weights[8] = {0};
	unsigned int queues = data[0] ? data[7] : 8;
	unsigned int valid_reg = 0x81bc - port / 4 * 4;
	unsigned int shift = (port % 4) * 8, row;
	int ret;

	/* Stop this LLID's queues while replacing the policy. A failed table
	 * operation must not leave a partially applied policy advertised live. */
	ret = rtl_itu_puc_tcont_weights(io, port, 0, weights);
	if (ret)
		return ret;
	io->write(io->context, valid_reg, io->read(io->context, valid_reg) & ~(255U << shift));
	for (row = 0; row < 8; row++) {
		unsigned int cir = 0, pir = 0x1f3ffffU;

		ret = rtl_epon_sla_flush(io, port, port * 8 + row);
		if (ret)
			return ret;
		if (data[0] && row < queues) {
			const unsigned char *queue = data + 8 + row * 10;

			cir = rtl_epon_sla_u16(queue + 5) * 8;
			pir = rtl_epon_sla_u16(queue + 7) * 8;
			weights[row] = data[1] ? queue[9] : 0;
		}
		ret = rtl_epon_sla_bucket(io, port * 8 + row, pir, 1);
		if (!ret)
			ret = rtl_epon_sla_bucket(io, port * 8 + row, cir, 0);
		if (ret)
			return ret;
	}
	/* Stock AAL couples the first two WRR weights even when queue1 is off. */
	if (queues == 1)
		weights[1] = weights[0];
	ret = rtl_itu_puc_schedule(io, port, 0, weights);
	if (ret)
		return ret;
	io->write(io->context, valid_reg, (io->read(io->context, valid_reg) & ~(255U << shift)) |
		((1U << queues) - 1) << shift);
	return rtl_itu_puc_tcont_weights(io, port, (1U << queues) - 1, weights);
}


int rtl_pon_epon_sla_set(struct rtl9617c_pon *pon, const u8 *data, size_t count)
{
	const struct rtl_dq_io io = {pon, rtl_puc_bp_read, rtl_puc_bp_write, rtl_puc_bp_access};
	unsigned int channel;
	int ret;

	if (count < 10 || count > 9 + RTL_EPON_SLA_BYTES)
		return -EINVAL;
	channel = data[0];
	ret = rtl_epon_sla_validate(data + 9, count - 9);
	if (ret)
		return ret;
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode) || readl(pon->mac + VOQ_MODE) != 0)
		ret = -EOPNOTSUPP;
	else if (channel >= 8 || channel >= pon->llid_count)
		ret = -EINVAL;
	else if (!pon->puc_configured || !pon->mpcp_enabled || !(pon->registered & BIT(channel)))
		ret = -EAGAIN;
	else if (get_unaligned_be64(data + 1) != pon->epon_llid_epoch[channel])
		ret = -ESTALE;
	else {
		pon->epon_sla_length[channel] = 0;
		ret = rtl_epon_sla_apply(&io, channel, data + 9);
		if (!ret) {
			memcpy(pon->epon_sla[channel], data + 9, count - 9);
			pon->epon_sla_length[channel] = count - 9;
		}
	}
	pon->puc_error = ret;
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	return ret;
}


static ssize_t epon_sla_read(struct file *file, struct kobject *kobj,
	const struct bin_attribute *attr, char *buf, loff_t offset, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(kobj_to_dev(kobj));
	unsigned int channel = offset / 89;
	int ret = 89;

	if (offset % 89 || channel >= 8 || count < 89)
		return -EINVAL;
	mutex_lock(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode))
		ret = -EOPNOTSUPP;
	else if (channel >= pon->llid_count)
		ret = -EINVAL;
	else if (!pon->puc_configured || !pon->epon_sla_length[channel])
		ret = -EAGAIN;
	else {
		memset(buf, 0, 89);
		buf[0] = pon->epon_sla_length[channel];
		memcpy(buf + 1, pon->epon_sla[channel], buf[0]);
	}
	mutex_unlock(&pon->lock);
	return ret;
}

static ssize_t epon_sla_write(struct file *file, struct kobject *kobj,
	const struct bin_attribute *attr, char *buf, loff_t offset, size_t count)
{
	if (offset)
		return -EINVAL;
	return rtl_pon_epon_sla_set(dev_get_drvdata(kobj_to_dev(kobj)), buf, count) ?: count;
}
BIN_ATTR(epon_sla, 0600, epon_sla_read, epon_sla_write, 8 * 89);
