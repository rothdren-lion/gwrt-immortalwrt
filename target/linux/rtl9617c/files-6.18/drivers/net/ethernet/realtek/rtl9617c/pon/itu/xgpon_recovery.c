// SPDX-License-Identifier: GPL-2.0-or-later
/* XGTC MAC restart, PUC/PDC/GEM restore and the recovery work item. */
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/random.h>
#include <linux/slab.h>
#include <linux/unaligned.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "pon/itu/xgpon_hw.h"

struct rtl_xgpon_mac_saved {
	struct rtl_xgtc_puc_saved puc;
	unsigned int upstream[256], downstream[256], pdc[256][2];
};

static const unsigned int rtl_xgtc_control_regs[5] = {0x813c, 0x8140, 0x8144, 0x8050, 0x808c};

static const unsigned int rtl_xgtc_control_masks[5] = {0x7fe07f7f, 0x7fff, 0x0780001f, 0xfb11193f, 0xce070003};

void rtl_xgtc_restart_sync(const struct rtl_dq_io *io)
{
	unsigned int status = io->read(io->context, 0x4d30), state = status & 7;
	/* Original clock-sequence reset applies only in O1/O8 sub-state1. */
	if ((state == 0 || state == 6) && (status & (1U << 4)))
		io->write(io->context, 0x4d30, (status & ~(3U << 16)) | (1U << 16));
}

static int rtl_xgtc_table_read(const struct rtl_dq_io *io, unsigned int reg,
	unsigned int data0, unsigned int index, unsigned int *words, unsigned int count)
{
	int ret = io->indirect(io->context, reg, 0x80000000U | index);
	if (ret) return ret;
	for (unsigned int i = 0; i < count; i++) words[i] = io->read(io->context, data0 - i * 4);
	return 0;
}

static int rtl_xgtc_table_restore(const struct rtl_dq_io *io, unsigned int reg,
	unsigned int data0, unsigned int index, const unsigned int *saved,
	const unsigned int *mask, unsigned int count)
{
	unsigned int loaded[5];
	int ret = rtl_xgtc_table_read(io, reg, data0, index, loaded, count);
	if (ret) return ret;
	for (unsigned int i = 0; i < count; i++)
		io->write(io->context, data0 - i * 4, (loaded[i] & ~mask[i]) | (saved[i] & mask[i]));
	return io->indirect(io->context, reg, 0xc0000000U | index);
}

static int rtl_xgtc_puc_save(const struct rtl_dq_io *io, struct rtl_xgtc_puc_saved *saved)
{
	int ret;
	for (unsigned int i = 0; i < 5; i++) saved->control[i] = io->read(io->context, rtl_xgtc_control_regs[i]);
	for (unsigned int i = 0; i < 16; i++) saved->limit_select[i] = io->read(io->context, 0x8090 + i * 4);
	for (unsigned int i = 0; i < 3; i++) saved->limit[i] = io->read(io->context, 0x80d0 + i * 4);
	for (unsigned int i = 0; i < 8; i++) saved->valid[i] = io->read(io->context, 0x81bc - i * 4);
	for (unsigned int i = 0; i < 32; i++) {
		ret = rtl_xgtc_table_read(io, 0x8000, 0x8014, i, saved->pvt[i], 5);
		if (ret) return ret;
	}
	for (unsigned int i = 0; i < 256; i++) {
		ret = rtl_xgtc_table_read(io, 0x81c4, 0x81cc, i, saved->cir[i], 2);
		if (!ret) ret = rtl_xgtc_table_read(io, 0x81ec, 0x81f4, i, saved->pir[i], 2);
		if (!ret && i < 192) ret = rtl_xgtc_table_read(io, 0x80e8, 0x80ec, i, &saved->backpressure[i], 1);
		if (ret) return ret;
	}
	return 0;
}

static int rtl_xgtc_puc_restore(const struct rtl_dq_io *io, const struct rtl_xgtc_puc_saved *saved)
{
	static const unsigned int pvt_mask[5] = {~0U, ~0U, 0xffff10ff, ~0U, 0xffff};
	static const unsigned int bucket_mask[2] = {~0U, 0x7fffffff}, bp_mask = 255;
	unsigned int shift = 7 + (io->read(io->context, 0x8048) & 3);
	int ret;

	for (unsigned int i = 0; i < 32; i++) {
		unsigned int credit[5] = {0};
		ret = rtl_xgtc_table_restore(io, 0x8000, 0x8014, i, saved->pvt[i], pvt_mask, 5);
		if (ret) return ret;
		/* Seed fresh scheduler credits from weights, as original restore_puc. */
		for (unsigned int q = 0; q < 8; q++) {
			unsigned int weight = q < 2 ? saved->pvt[i][2] >> (16 + q * 8) :
				q < 6 ? saved->pvt[i][3] >> ((q - 2) * 8) : saved->pvt[i][4] >> ((q - 6) * 8);
			unsigned int bit = q * 20;
			unsigned long long value = (weight & 255U) << shift;
			credit[bit / 32] |= value << (bit % 32);
			if (bit % 32 > 12) credit[bit / 32 + 1] |= value >> (32 - bit % 32);
		}
		for (unsigned int q = 0; q < 5; q++) io->write(io->context, 0x8074 - q * 4, credit[q]);
		ret = io->indirect(io->context, 0x8060, 0xc0000000U | i);
		if (ret) return ret;
	}
	for (unsigned int i = 0; i < 4; i++) {
		unsigned int reg = rtl_xgtc_control_regs[i], mask = rtl_xgtc_control_masks[i];
		io->write(io->context, reg, (io->read(io->context, reg) & ~mask) | (saved->control[i] & mask));
	}
	for (unsigned int i = 0; i < 256; i++) {
		ret = rtl_xgtc_table_restore(io, 0x81c4, 0x81cc, i, saved->cir[i], bucket_mask, 2);
		if (!ret) ret = rtl_xgtc_table_restore(io, 0x81ec, 0x81f4, i, saved->pir[i], bucket_mask, 2);
		if (!ret && i < 192) ret = rtl_xgtc_table_restore(io, 0x80e8, 0x80ec, i, &saved->backpressure[i], &bp_mask, 1);
		if (ret) return ret;
	}
	for (unsigned int i = 0; i < 16; i++) io->write(io->context, 0x8090 + i * 4, saved->limit_select[i]);
	for (unsigned int i = 0; i < 3; i++)
		io->write(io->context, 0x80d0 + i * 4, (io->read(io->context, 0x80d0 + i * 4) & ~0x3fffU) | (saved->limit[i] & 0x3fffU));
	io->write(io->context, 0x808c, (io->read(io->context, 0x808c) & ~rtl_xgtc_control_masks[4]) | (saved->control[4] & rtl_xgtc_control_masks[4]));
	for (unsigned int i = 0; i < 8; i++) io->write(io->context, 0x81bc - i * 4, saved->valid[i]);
	return 0;
}

static int rtl_xgpon_mac_save(const struct rtl_dq_io *io,
		struct rtl_xgpon_mac_saved *saved)
{
	int ret = rtl_xgtc_puc_save(io, &saved->puc);

	if (ret)
		return ret;
	for (unsigned int i = 0; i < 256; i++) {
		ret = rtl_xgtc_table_read(io, 0x4618, 0x461c, i, &saved->upstream[i], 1);
		if (ret)
			return ret;
		saved->downstream[i] = io->read(io->context, 0x412c + i * 4);
		ret = rtl_xgtc_table_read(io, 0x9020, 0x9028, i, saved->pdc[i], 2);
		if (ret)
			return ret;
	}
	return 0;
}

static int rtl_xgpon_mac_restore(const struct rtl_dq_io *io,
		struct rtl_xgpon_mac_saved *saved)
{
	static const unsigned int pdc_mask[2] = {~0U, 0x3ffff};
	unsigned int valid[8];
	int ret;

	/* OMCC is available immediately; business VOQs await the activation handoff. */
	for (unsigned int i = 0; i < 8; i++) {
		valid[i] = saved->puc.valid[i];
		saved->puc.valid[i] &= i ? 0 : 255;
	}
	ret = rtl_xgtc_puc_restore(io, &saved->puc);
	for (unsigned int i = 0; i < 8; i++)
		saved->puc.valid[i] = valid[i];
	if (ret)
		return ret;
	for (unsigned int i = 0; i < 256; i++) {
		unsigned int us = saved->upstream[i], ds = saved->downstream[i];

		if (us & (1U << 16)) {
			ret = rtl_xgpon_upstream_gem_set(io, i, us & 65535, 1,
				(us >> 17) & 1, (us >> 18) & 1);
			if (ret)
				return ret;
		}
		if (ds & (1U << 17))
			rtl_xgpon_downstream_gem_set(io, i, ds & 65535, 1, (ds >> 16) & 1);
		ret = rtl_xgtc_table_restore(io, 0x9020, 0x9028, i,
			saved->pdc[i], pdc_mask, 2);
		if (ret)
			return ret;
	}
	return 0;
}

/* Rev-C random-load pulse in the original aal_xgpon_reset path. */

static void rtl_xgpon_random_load(const struct rtl_dq_io *io, unsigned int seed)
{
	unsigned int word = (io->read(io->context, 0x4a18) & 0x60000000U) |
		(seed & 0x1fffffffU);

	io->write(io->context, 0x4a18, word);
	io->write(io->context, 0x4a18, word | 0x80000000U);
	io->write(io->context, 0x4a18, word);
}


int rtl_xgpon_mac_restart_locked(struct rtl9617c_pon *pon, bool phy)
{
	const struct rtl_dq_io io = {pon, rtl_xgpon_read, rtl_xgpon_write, rtl_xgpon_indirect};
	struct rtl_xgpon_mac_saved *saved;
	const char *stage = "snapshot";
	u32 control, gpon;
	int ret;

	lockdep_assert_held(&pon->control_lock);
	lockdep_assert_held(&pon->lock);
	saved = NULL;
	ret = rtl_pon_itu_paths_invalidate(pon, pon->mode);
	if (ret)
		goto free;
	saved = kvmalloc(sizeof(*saved), GFP_KERNEL);
	if (!saved) {
		ret = -ENOMEM;
		goto free;
	}
	pon->xgpon_enabled = false;
	rtl_pon_dying_gasp_stop(pon);
	pon->itu_line_epoch++;
	pon->xgpon_omcc_ready = false;
	pon->omci_master_key_valid = false;
	pon->xgpon_key_valid = 0;
	pon->xgpon_key_state = 0;
	spin_lock_bh(&pon->omci_key_lock);
	pon->xgpon_key_ready = false;
	spin_unlock_bh(&pon->omci_key_lock);
	netif_carrier_off(pon->omci_device);
	saved->puc.ni_enable = rtl9617c_ni_pon_gate(pon->ni_dev, 0);
	saved->puc.mac = readl(pon->mac + RTL_XGTC_4004);
	saved->puc.burst = readl(pon->serdes_init) & BIT(4);
	saved->puc.laser = readl(pon->mac + RTL_XGTC_4600) & BIT(2);
	saved->puc.to1 = readl(pon->mac + RTL_XGTC_4D0C);
	saved->puc.to2 = readl(pon->mac + RTL_XGTC_4D10);
	if (pon->xgpon_restore_pending) {
		for (unsigned int i = 0; i < 8; i++)
			writel(pon->xgpon_puc_saved.valid[i], pon->mac + VALID_VOQ0 - i * 4);
		pon->xgpon_restore_pending = false;
	}
	if (!(readl(pon->mac + RTL_SERDES_A064) & BIT(15)))
		rtl_pon_update(pon->serdes_init, BIT(4), 0);
	rtl_xgpon_active(&io, false, pon->mode == RTL_PON_XGSPON);
	udelay(500);
	ret = rtl_xgpon_mac_save(&io, saved);
	if (ret)
		goto ungate;
	stage = "reset";
	writel(0, pon->mac + RTL_XGTC_400C);
	rtl_pon_update(pon->top_irq + 4, BIT(0), 0);
	control = readl(pon->control) & ~0x300U;
	gpon = readl(pon->gpon_control) & ~7U;
	writel(gpon, pon->gpon_control);
	writel(control, pon->control);
	msleep(1);
	if (phy) {
		ret = rtl_pon_serdes_restart_locked(pon);
		pon->serdes_error = ret;
		if (ret)
			goto ungate;
	}
	writel(gpon | 5, pon->gpon_control);
	writel(control | 0x300, pon->control);
	msleep(1);
	rtl_xgpon_mac_parameters(&io, pon->mode == RTL_PON_XGSPON);
	rtl_xgpon_identity(&io, pon->xgpon_serial, pon->xgpon_registration);
	pon->mac_prepared = true;
	pon->puc_configured = false;
	pon->pdc_configured = false;
	stage = "datapath initialization";
	ret = __rtl_pon_pdc_configure(pon);
	if (!ret)
		ret = __rtl_pon_puc_configure(pon);
	if (ret)
		goto ungate;
	stage = "configuration restore";
	ret = rtl_xgpon_mac_restore(&io, saved);
	if (ret)
		goto ungate;
	memcpy(pon->xgpon_puc_saved.valid, saved->puc.valid, sizeof(saved->puc.valid));
	pon->xgpon_restore_pending = true;
	pon->xgpon_restore_at = 0;
	writel(0x1007f, pon->mac + RTL_XGTC_402C);
	rtl_xgpon_random_load(&io, get_random_u32());
	writel(0x0fffffff, pon->mac + RTL_XGTC_4D28);
	writel(0x0fffffff, pon->mac + RTL_XGTC_4D2C);
	writel(readl(pon->mac + RTL_XGTC_4D1C), pon->mac + RTL_XGTC_4D1C);
	writel(readl(pon->mac + RTL_XGTC_4AA4), pon->mac + RTL_XGTC_4AA4);
	writel(readl(pon->mac + RTL_XGTC_4118), pon->mac + RTL_XGTC_4118);
	writel(15, pon->mac + RTL_XGTC_4D20);
	writel(BIT(5) | BIT(6) | BIT(7) | BIT(30) | BIT(31), pon->mac + RTL_XGTC_4AA8);
	writel(BIT(5), pon->mac + RTL_XGTC_411C);
	writel(BIT(0) | BIT(2) | BIT(4), pon->mac + RTL_XGTC_400C);
	rtl_pon_update(pon->top_irq + 4, BIT(0), BIT(0));
	rtl_pon_update(pon->mac + RTL_XGTC_4600, BIT(2), saved->puc.laser);
	writel(saved->puc.to1, pon->mac + RTL_XGTC_4D0C);
	writel(saved->puc.to2, pon->mac + RTL_XGTC_4D10);
	writel(saved->puc.mac, pon->mac + RTL_XGTC_4004);
	if (saved->puc.burst)
		udelay(500);
	rtl_pon_update(pon->serdes_init, BIT(4), saved->puc.burst);
	pon->xgpon_enabled = true;
	pon->xgpon_last_state = readl(pon->mac + RTL_XGTC_4D30) & 7;
	pon->xgpon_health_state = ~0U;
	pon->xgpon_pending_valid = false;
	pon->xgpon_mac_resets++;
ungate:
	rtl9617c_ni_pon_gate(pon->ni_dev, saved->puc.ni_enable);
free:
	if (ret)
		dev_err(pon->dev, "XGTC MAC recovery failed at %s: %d\n", stage, ret);
	kvfree(saved);
	return ret;
}


void rtl_pon_xgpon_recovery(struct work_struct *work)
{
	struct rtl9617c_pon *pon = container_of(to_delayed_work(work), struct rtl9617c_pon, xgpon_recovery_work);
	const struct rtl_dq_io io = {pon, rtl_xgpon_read, rtl_xgpon_write, rtl_xgpon_indirect};
	struct rtl_xgtc_puc_saved *saved = &pon->xgpon_puc_saved;
	u32 status;
	int ret = 0;

	pon_event_at(pon, PON_EV_XGPON_STATE, 0, pon->xgpon_recover,
		     (u32)pon->xgpon_recovery_phase, 0);
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (!pon->xgpon_recover) goto unlock;
	if (!pon->xgpon_recovery_phase) {
		status = readl(pon->mac + RTL_XGTC_4D30) & 7;
		if (status == 3 || status == 4) {
			pon->xgpon_recover = false;
			goto unlock;
		}
		if (pon->xgpon_restore_pending) {
			for (unsigned int i = 0; i < 8; i++)
				writel(pon->xgpon_puc_saved.valid[i], pon->mac + VALID_VOQ0 - i * 4);
			pon->xgpon_restore_pending = false;
		}
		saved->ni_enable = rtl9617c_ni_pon_gate(pon->ni_dev, 0);
		saved->mac = readl(pon->mac + RTL_XGTC_4004);
		saved->burst = readl(pon->serdes_init) & BIT(4);
		saved->laser = readl(pon->mac + RTL_XGTC_4600) & BIT(2);
		saved->to1 = readl(pon->mac + RTL_XGTC_4D0C);
		saved->to2 = readl(pon->mac + RTL_XGTC_4D10);
		if (!(readl(pon->mac + RTL_SERDES_A064) & BIT(15)))
			rtl_pon_update(pon->serdes_init, BIT(4), 0);
		rtl_pon_update(pon->mac + RTL_XGTC_4004, 3, 0);
		udelay(500);
		pon->xgpon_recovery_phase = 1;
	}
	if (pon->xgpon_recovery_phase == 1) {
		ret = rtl_pon_itu_paths_invalidate(pon, pon->mode);
		if (ret) goto retry;
		ret = rtl_xgtc_puc_save(&io, saved);
		if (ret) goto retry;
		pon->xgpon_recovery_phase = 2;
	}
	if (pon->xgpon_recovery_phase == 2) {
		for (unsigned int index = 0; index < 32; index++) {
			ret = readl_poll_timeout(pon->mac + RTL_XGTC_4004, status, !(status & BIT(31)), 0, 100000);
			if (ret) goto retry;
			rtl_pon_update(pon->mac + RTL_XGTC_4004, GENMASK(28, 24) | GENMASK(11, 8) | BIT(31),
				(index << 24) | BIT(31));
			ret = readl_poll_timeout(pon->mac + RTL_XGTC_4004, status, !(status & BIT(31)), 0, 100000);
			if (ret) goto retry;
		}
		rtl_pon_update(pon->control, BIT(8), 0);
		msleep(5);
		rtl_pon_update(pon->control, BIT(8), BIT(8));
		msleep(5);
		ret = __rtl_pon_puc_configure(pon);
		if (ret) goto retry;
		pon->xgpon_recovery_phase = 3;
	}
	ret = rtl_xgtc_puc_restore(&io, saved);
	if (ret) goto retry;
	rtl_pon_update(pon->mac + RTL_XGTC_4600, BIT(2), saved->laser);
	writel(saved->to1, pon->mac + RTL_XGTC_4D0C);
	writel(saved->to2, pon->mac + RTL_XGTC_4D10);
	writel(saved->mac, pon->mac + RTL_XGTC_4004);
	if (saved->burst) udelay(500);
	rtl_pon_update(pon->serdes_init, BIT(4), saved->burst);
	rtl9617c_ni_pon_gate(pon->ni_dev, saved->ni_enable);
	pon->xgpon_recovery_phase = 0;
retry:
	pon->xgpon_recover = !!ret;
	pon->xgpon_activation_error = ret;
	if (ret) schedule_delayed_work(&pon->xgpon_recovery_work, HZ);
unlock:
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	pon_event_at(pon, PON_EV_XGPON_STATE, 1, (u32)ret,
		     (u32)pon->xgpon_recovery_phase, (u32)pon->xgpon_activation_error);
	pon_dbg("xgpon recovery: ret=%d phase=%u recover=%u\n", ret,
		pon->xgpon_recovery_phase, pon->xgpon_recover);
}
