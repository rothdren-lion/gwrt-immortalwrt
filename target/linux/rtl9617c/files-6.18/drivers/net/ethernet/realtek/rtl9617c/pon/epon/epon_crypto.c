// SPDX-License-Identifier: GPL-2.0-or-later
/* EPON LLID/key programming, from the RTL8277C GPL EPON DAL crypto path. */
#include <linux/errno.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/unaligned.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "pon/epon/epon.h"

static void rtl_epon_crypto_update(const struct rtl_dq_io *io,
	unsigned int reg, unsigned int mask, unsigned int value)
{
	io->write(io->context, reg, (io->read(io->context, reg) & ~mask) | value);
}

/* Actual aal_epon_crypto_init defaults: 1G churning, XG triple churning. */

void rtl_epon_crypto_profile(const struct rtl_dq_io *io, enum rtl_pon_mode mode)
{
	if (mode == RTL_PON_EPON_1G) {
		rtl_epon_crypto_update(io, 0x8b4, 7U << 29, 0);
		rtl_epon_crypto_update(io, 0x93c, 1U | (1U << 7), 1);
		rtl_epon_crypto_update(io, 0x8a8, 4, 0);
		rtl_epon_crypto_update(io, 0x940, 8, 8);
	} else {
		rtl_epon_crypto_update(io, 0x20, 15, 10);
		rtl_epon_crypto_update(io, 0x1250, 1U << 28, 0);
		rtl_epon_crypto_update(io, 0x1600, 2, 0);
		rtl_epon_crypto_update(io, 0x14c0, 2, 0);
	}
}

static int rtl_epon_crypto_llid(const struct rtl_dq_io *io, enum rtl_pon_mode mode,
	unsigned int channel, unsigned int llid, int enable)
{
	unsigned int value, direction;
	int ret;

	if (mode == RTL_PON_EPON_1G) {
		/* Valid is bit19. A disabled entry must not retain a key index that
		 * overlaps that bit, as the original setter does for channels4..7. */
		value = enable ? llid | (((channel * 2) & 7) << 16) | (1U << 19) : 0;
		io->write(io->context, 0x95c + channel * 4, value);
		return 0;
	}
	for (direction = 0; direction < 2; direction++) {
		unsigned int access = direction ? 0x14dc : 0x161c;
		unsigned int data = direction ? 0x14e0 : 0x1620;

		ret = io->indirect(io->context, access, (1U << 31) | channel);
		if (ret)
			return ret;
		value = io->read(io->context, data) & ~0x7fffffU;
		value |= llid | (channel << 17) | (direction && enable ? 1U << 16 : 0);
		io->write(io->context, data, value);
		ret = io->indirect(io->context, access, (3U << 30) | channel);
		if (ret)
			return ret;
	}
	return 0;
}

/* Key packing established by executing the board's actual DAL for both slots.
 * SA reads preserve all other keys and fields; a write completes before ACK. */

static int rtl_epon_crypto_key(const struct rtl_dq_io *io, enum rtl_pon_mode mode,
	unsigned int channel, unsigned int slot, const unsigned char *key)
{
	unsigned char packed[16] = {};
	unsigned int base, direction, word, byte, value;
	int ret;

	if (mode == RTL_PON_EPON_1G) {
		base = 0x8b8 + slot * 16;
		io->write(io->context, base, (unsigned int)key[0] << 24 |
			(unsigned int)key[1] << 16 | (unsigned int)key[2] << 8);
		for (word = 1; word < 4; word++)
			io->write(io->context, base + word * 4, 0);
		return 0;
	}
	if (!(io->read(io->context, 0x1434) & 1))
		return -EAGAIN;
	/* aal_epon_crypto_xg_enable_set(TX,0) also removes MACsec overhead
	 * from payload and REPORT accounting, not just the TX LLID valid bit. */
	rtl_epon_crypto_update(io, 0x1010, 1U << channel, 0);
	rtl_epon_crypto_update(io, 0x8054, 0x3f0, 0x80);
	rtl_epon_crypto_update(io, 0x8050, 0x3f, 0x14);
	for (byte = 0; byte < 9; byte++)
		packed[byte] = key[(byte / 3) * 3 + 2 - byte % 3];
	for (direction = 0; direction < 2; direction++) {
		/* Stock DAL updates TX first, then RX; upstream encryption stays off. */
		unsigned int access = direction ? 0x1438 : 0x1578;
		unsigned int control = direction ? 0x1488 : 0x15c8;

		ret = io->indirect(io->context, access, (channel << 2) | 1);
		if (ret)
			return ret;
		base = (direction ? 0x1448 : 0x1588) + slot * 32;
		for (word = 0; word < 4; word++) {
			value = 0;
			for (byte = 0; byte < 4; byte++)
				value |= (unsigned int)packed[word * 4 + byte] << (byte * 8);
			io->write(io->context, base - word * 4, value);
		}
		rtl_epon_crypto_update(io, control, 0, 1U << (slot * 2));
		ret = io->indirect(io->context, access, (channel << 2) | 3);
		if (ret)
			return ret;
	}
	/* Original DAL: gate threshold100, deregistration disabled after exchange. */
	rtl_epon_crypto_update(io, 0x204c, 0x3fffU << 16, 100U << 16);
	rtl_epon_crypto_update(io, 0x2024, 1U << 17, 0);
	return 0;
}


unsigned int rtl_crypto_read(void *context, unsigned int reg)
{
	struct rtl9617c_pon *pon = context;

	return readl(pon->mac + reg);
}

void rtl_crypto_write(void *context, unsigned int reg, unsigned int value)
{
	struct rtl9617c_pon *pon = context;

	writel(value, pon->mac + reg);
}

int rtl_crypto_indirect(void *context, unsigned int reg, unsigned int value)
{
	struct rtl9617c_pon *pon = context;
	u32 status, busy = reg == 0x1438 || reg == 0x1578 ? BIT(0) : BIT(31);

	writel(value, pon->mac + reg);
	return readl_poll_timeout(pon->mac + reg, status, !(status & busy), 1, 100000);
}


int rtl_pon_epon_crypto_forget(struct rtl9617c_pon *pon, u32 lost)
{
	const struct rtl_dq_io io = {pon, rtl_crypto_read, rtl_crypto_write, rtl_crypto_indirect};
	unsigned int channel;
	int ret;

	lockdep_assert_held(&pon->lock);
	for (channel = 0; channel < 8; channel++) {
		if (!(lost & BIT(channel)))
			continue;
		ret = rtl_epon_crypto_llid(&io, pon->mode, channel, 0, false);
		if (ret) {
			pon->epon_crypto_error = ret;
			return ret;
		}
		pon->epon_crypto_llids &= ~BIT(channel);
	}
	if (pon->mode != RTL_PON_EPON_1G && !pon->epon_crypto_llids)
		rtl_pon_update(pon->mac + RTL_EPON_10B8, BIT(3), BIT(3));
	pon->epon_crypto_error = 0;
	return 0;
}

int rtl_pon_epon_key(struct rtl9617c_pon *pon, const u8 *data, size_t count)
{
	const struct rtl_dq_io io = {pon, rtl_crypto_read, rtl_crypto_write, rtl_crypto_indirect};
	const u8 zero_key[9] = {};
	u32 entry;
	unsigned int channel, slot, row;
	int ret;

	if (count < 10)
		return -EINVAL;
	channel = data[0];
	slot = data[1];
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode)) {
		ret = -EOPNOTSUPP;
		goto unlock;
	}
	if (channel >= 8 || channel >= pon->llid_count || slot > 1 ||
	    count != (pon->mode == RTL_PON_EPON_1G ? 13 : 19)) {
		ret = -EINVAL;
		goto unlock;
	}
	if (!pon->mac_prepared || !pon->mpcp_enabled || !(pon->registered & BIT(channel))) {
		ret = -EAGAIN;
		goto unlock;
	}
	if (get_unaligned_be64(data + 2) != pon->epon_llid_epoch[channel]) {
		ret = -ESTALE;
		goto unlock;
	}
	for (row = 0; row < 64; row++) {
		entry = readl(pon->mac + RTL_EPON_0064 + row * 4);
		if ((entry & BIT(23)) && !(entry & BIT(22)) &&
		    FIELD_GET(GENMASK(28, 24), entry) == channel)
			break;
	}
	if (row == 64) {
		ret = -ENOENT;
		goto unlock;
	}
	/* A new line must not re-enable an old session's other key slot. The
	 * 1G common key pool is shared by registered LLIDs. */
	if (!(pon->epon_crypto_llids & BIT(channel)) &&
	    (pon->mode != RTL_PON_EPON_1G || !pon->epon_crypto_llids)) {
		ret = rtl_epon_crypto_key(&io, pon->mode, channel, slot ^ 1, zero_key);
		if (ret)
			goto unlock;
	}
	ret = rtl_epon_crypto_key(&io, pon->mode, channel, slot, data + 10);
	if (ret)
		goto unlock;
	ret = rtl_epon_crypto_llid(&io, pon->mode, channel, entry & 0xffff, true);
	if (ret)
		goto unlock;
	pon->epon_crypto_llids |= BIT(channel);
	if (pon->mode != RTL_PON_EPON_1G)
		rtl_pon_update(pon->mac + RTL_EPON_10B8, BIT(3), 0);
unlock:
	pon->epon_crypto_error = ret;
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	return ret;
}


static ssize_t epon_key_write(struct file *file, struct kobject *kobj,
	const struct bin_attribute *attr, char *buf, loff_t offset, size_t count)
{
	if (offset)
		return -EINVAL;
	return rtl_pon_epon_key(dev_get_drvdata(kobj_to_dev(kobj)), buf, count) ?: count;
}
BIN_ATTR(epon_key, 0200, NULL, epon_key_write, 0);
