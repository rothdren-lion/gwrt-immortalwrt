// SPDX-License-Identifier: GPL-2.0-or-later
/* Native MPCP control, backoff and registration; GPL aal_mpcp.c reference. */
#include <linux/bitfield.h>
#include <linux/delay.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/unaligned.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "pon/epon/epon.h"

static int rtl_mpcp_backoff_event(struct rtl_mpcp_backoff *state,
	const struct rtl_mpcp_io *io, unsigned int irq, unsigned long now,
	unsigned long period)
{
	if (!(irq & (1U << 1)))
		return 0;
	state->register_flag = (io->read(io->context, RTL_MPCP_PACKET_FLAG) >> 16) & 255;
	if (state->register_flag == 4) {
		io->write(io->context, RTL_MPCP_START,
			  io->read(io->context, RTL_MPCP_START) & ~1U);
		state->active = 1;
		state->until = now + period;
		state->nacks++;
		pon_event(io->context, PON_EV_MPCP_NACK, state->nacks,
			 state->register_flag, state->active);
		return 1;
	}
	if (state->register_flag == 3)
		state->active = 0;
	return 0;
}

static int rtl_mpcp_backoff_active(struct rtl_mpcp_backoff *state, unsigned long now)
{
	if (state->active && (long)(now - state->until) >= 0)
		state->active = 0;
	return state->active;
}

static void rtl_epon_link_events(struct rtl9617c_pon *pon)
{
	u32 pending = readl(pon->mac + GLB_IRQ) & readl(pon->mac + GLB_IE);

	if (pending & BIT(0)) {
		u32 flags = readl(pon->mac + RTL_EPON_01A0) & readl(pon->mac + RTL_EPON_01A4);

		if (flags & BIT(6)) {
			pon->epon_link_events++;
		}
		writel(flags, pon->mac + RTL_EPON_01A0);
	}
	if (pending & BIT(1)) {
		u32 summary = readl(pon->mac + RTL_EPON_01C0) & readl(pon->mac + RTL_EPON_01C4);

		if (summary & BIT(9)) {
			u32 flags = readl(pon->mac + RTL_EPON_1370) & readl(pon->mac + RTL_EPON_1374);

			if (flags & GENMASK(18, 17)) {
				pon->epon_link_events++;
				/* Actual stock link-down handler pulses CORESEC RX reset. */
				if ((flags & BIT(17)) && !(readl(pon->mac + RTL_EPON_13D0) & 1)) {
					rtl_pon_update(pon->mac + RTL_EPON_14C0, BIT(7), BIT(7));
					usleep_range(1000, 2000);
					rtl_pon_update(pon->mac + RTL_EPON_14C0, BIT(7), 0);
				}
			}
			writel(flags, pon->mac + RTL_EPON_1370);
		}
		writel(summary, pon->mac + RTL_EPON_01C0);
	}
	pon_event(pon, PON_EV_IRQ, 4, pending, pon->epon_link_events);
	writel(pending & (BIT(0) | BIT(1)), pon->mac + GLB_IRQ);
}

static u32 rtl_pon_llid_mask(struct rtl9617c_pon *pon)
{
	return GENMASK(pon->llid_count - 1, 0);
}

static int rtl_mpcp_remove_mac(struct rtl9617c_pon *pon, unsigned int mac)
{
	unsigned int i;
	int ret;

	for (i = 0; i < 64; i++) {
		u32 entry = readl(pon->mac + LLID_TABLE + i * 4);
		if ((entry & BIT(23)) && !(entry & BIT(22)) &&
		    FIELD_GET(GENMASK(28, 24), entry) == mac) {
			ret = rtl_pon_llid_update(pon, false, FIELD_GET(GENMASK(21, 16), entry),
				mac, entry & 0xffff, false);
			if (ret)
				return ret;
		}
	}
	return 0;
}

static void rtl_mpcp_registration_event(struct rtl9617c_pon *pon, u32 registered)
{
	char value[48];
	char *env[] = {"PON_EVENT=registration", value, NULL};
	unsigned int channel;

	pon->epon_epoch++;
	for (channel = 0; channel < 32; channel++)
		if ((registered ^ pon->registered) & BIT(channel))
			pon->epon_llid_epoch[channel] = pon->epon_epoch;
	snprintf(value, sizeof(value), "PON_REGISTERED=%08x", registered);
	pon->registration_events++;
	pon_event(pon, PON_EV_MPCP_REGISTER, registered, pon->registered, pon->waiting);
	kobject_uevent_env(&pon->dev->kobj, KOBJ_CHANGE, env);
	dev_info(pon->dev, "MPCP registered LLIDs: %08x -> %08x\n", pon->registered, registered);
}

static unsigned int rtl_mpcp_read(void *context, unsigned int reg)
{
	struct rtl9617c_pon *pon = context;

	return readl(pon->mac + reg);
}

static void rtl_mpcp_write(void *context, unsigned int reg, unsigned int value)
{
	struct rtl9617c_pon *pon = context;

	writel(value, pon->mac + reg);
}

void rtl_mpcp_refresh(struct rtl9617c_pon *pon)
{
	u32 flags = readl(pon->mac + MPCP_IRQ) & MPCP_EVENT_MASK;
	u32 registered;
	unsigned int i;
	const struct rtl_mpcp_io io = {pon, rtl_mpcp_read, rtl_mpcp_write};

	pon->last_mpcp_irq = flags;
	if ((flags & BIT(3)) && pon->mode != RTL_PON_EPON_1G && pon->epon_crypto_llids) {
		/* aal_epon_mpcp_gate_timeout_handler resets the active RX core. */
		rtl_pon_update(pon->mac + RTL_EPON_14C0, BIT(7), BIT(7));
		rtl_pon_update(pon->mac + RTL_EPON_14C0, BIT(7), 0);
	}
	if (rtl_mpcp_backoff_event(&pon->backoff, &io, flags, jiffies,
				   msecs_to_jiffies(60000)) && pon->llid_count == 1)
		pon->epon_llid_cleanup |= BIT(0);
	if (flags & BIT(1)) {
		for (i = 0; i < 64; i++) {
			u32 frame = readl(pon->mac + REGISTER_FRAME);
			if (!(frame & BIT(25)))
				break;
			pon->register_frames++;
		}
	}
	if (flags)
		writel(flags, pon->mac + MPCP_IRQ);
	registered = readl(pon->mac + REGISTER_STATUS) & rtl_pon_llid_mask(pon);
	registered = rtl_mpcp_holdover(pon, registered);
	pon->epon_llid_cleanup |= pon->registered & ~registered;
	pon->epon_llid_cleanup_error = 0;
	for (i = 0; i < pon->llid_count; i++) {
		int ret;

		if (!(pon->epon_llid_cleanup & BIT(i)))
			continue;
		ret = rtl_mpcp_remove_mac(pon, i);
		if (ret) {
			pon->epon_llid_cleanup_error = ret;
			dev_err_ratelimited(pon->dev, "EPON LLID%u table cleanup failed: %d\n", i, ret);
		} else {
			pon->epon_llid_cleanup &= ~BIT(i);
		}
	}
	if ((pon->epon_crypto_llids & ~registered) &&
	    rtl_pon_epon_crypto_forget(pon, pon->epon_crypto_llids & ~registered))
		dev_err_ratelimited(pon->dev, "EPON decryption cleanup failed: %d\n", pon->epon_crypto_error);
	if (registered != pon->registered)
		rtl_mpcp_registration_event(pon, registered);
	pon->registered = registered;
	pon->waiting = rtl_pon_llid_mask(pon) & ~registered;
	rtl_pon_pdc_refresh(pon);
	rtl_pon_oam_carrier(pon);
}

/* PKT_FLAG has no MAC index. Silence the shared registration engine; the
 * Stock driver only establishes NACK ownership for LLID0. Event gating avoids
 * extending the deadline every time a sticky register_flag is polled. */

static void rtl_mpcp_work(struct work_struct *work)
{
	struct rtl9617c_pon *pon = container_of(to_delayed_work(work), struct rtl9617c_pon, mpcp_work);
	u32 status;
	bool synced;
	unsigned int mac;
	unsigned long long counters[37];
	int mib_error;

	mutex_lock(&pon->lock);
	if (!pon->mpcp_enabled)
		goto unlock;
	rtl_mpcp_refresh(pon);
	mib_error = rtl_pon_epon_pm(pon, counters);
	if (mib_error)
		dev_err_ratelimited(pon->dev, "EPON MIB read failed: %d\n", mib_error);
	if (time_after_eq(jiffies, pon->epon_health_at)) {
		u32 epon = readl(pon->mac + RTL_EPON_0010);
		bool failure = pon->mode != RTL_PON_EPON_1G &&
			!(readl(pon->mac + RTL_SERDES_A060) & BIT(0)) &&
			FIELD_GET(GENMASK(5, 4), epon) > 1 && (epon & BIT(1)) &&
			!(readl(pon->mac + RTL_EPON_2120) & 0xffff);

		pon->epon_sync_failures = failure ? pon->epon_sync_failures + 1 : 0;
		if (pon->epon_sync_failures == 5) {
			rtl_pon_update(pon->mac + RTL_EPON_137C, BIT(15), BIT(15));
			usleep_range(1000, 2000);
			rtl_pon_update(pon->mac + RTL_EPON_137C, BIT(15), 0);
			pon->epon_sync_failures = 0;
			pon->epon_rx_resets++;
		}
		pon->epon_health_at = jiffies + msecs_to_jiffies(3000);
	}
	status = readl(pon->mac + RTL_EPON_0010);
	synced = !(status & BIT(0)) &&
		 !!(status & (pon->mode == RTL_PON_EPON_1G ? BIT(2) : BIT(1)));
	if (pon->mpcp_enabled && synced && !rtl_mpcp_backoff_active(&pon->backoff, jiffies)) {
		pon_event(pon, PON_EV_MPCP_SYNC, synced, pon->registered, pon->waiting);
		for (mac = 0; mac < pon->llid_count; mac++) {
			if (!(pon->waiting & BIT(mac)))
				continue;
			if ((pon->epon_llid_cleanup | pon->epon_crypto_llids) & BIT(mac))
				continue;
			rtl_pon_update(pon->mac + OFFLINE, BIT(mac), 0);
			rtl_pon_update(pon->mac + MPCP_INIT, GENMASK(13, 8) | GENMASK(4, 0),
					   (mac << 8) | mac);
			rtl_pon_update(pon->mac + MPCP_START, BIT(0), BIT(0));
			pon->registration_attempts++;
			break;
		}
	}
	if (pon->mpcp_enabled)
		schedule_delayed_work(&pon->mpcp_work, HZ);
unlock:
	mutex_unlock(&pon->lock);
}

static irqreturn_t rtl_mpcp_irq_thread(int irq, void *data)
{
	struct rtl9617c_pon *pon = data;
	u32 pending = readl(pon->top_irq) & readl(pon->top_irq + 4);

	if (!(pending & PON_TOP_EVENTS))
		return IRQ_NONE;
	pon_event(pon, PON_EV_IRQ, 5, pending, pon->mpcp_irq_count);
	mutex_lock(&pon->lock);
	if (pending & BIT(3)) {
		u32 optical = readl(pon->optical_irq) & readl(pon->optical_irq + 4);

		pon->last_optical_irq = optical;
		pon->optical_irq_count++;
		writel(optical, pon->optical_irq);
		if (rtl_pon_mode_is_epon(pon->mode))
			rtl_mpcp_refresh(pon);
		else if (pon->mode == RTL_PON_XGPON || pon->mode == RTL_PON_XGSPON)
			rtl_pon_xgpon_optical_irq(pon, optical);
	}
	if (pending & BIT(0)) {
		if (rtl_pon_mode_is_epon(pon->mode)) {
			pon->mpcp_irq_count++;
			rtl_epon_link_events(pon);
			rtl_mpcp_refresh(pon);
			writel(BIT(3), pon->mac + GLB_IRQ);
		} else if (pon->mode == RTL_PON_GPON) {
			rtl_pon_gpon_irq(pon);
		} else {
			rtl_pon_xgpon_irq(pon);
		}
	}
	writel(pending & PON_TOP_EVENTS, pon->top_irq);
	mutex_unlock(&pon->lock);
	return IRQ_HANDLED;
}

int rtl_pon_mpcp_init(struct rtl9617c_pon *pon, int irq)
{
	pon->mpcp_irq = irq;
	pon->llid_count = 1;
	pon->epon_holdover_enabled = U32_MAX;
	for (unsigned int channel = 0; channel < 32; channel++)
		pon->epon_holdover_ms[channel] = 200;
	INIT_DELAYED_WORK(&pon->mpcp_work, rtl_mpcp_work);
	INIT_DELAYED_WORK(&pon->epon_holdover_work, rtl_mpcp_holdover_work);
	rtl_pon_epon_tx_init(pon);
	/* This controller owns the PON bank. Remove inherited optical enables and
	 * acknowledge their leaf events before request_irq unmasks its parent. */
	writel(0, pon->top_irq + 4);
	writel(0, pon->optical_irq + 4);
	writel(readl(pon->optical_irq) & OPT_EVENT_MASK, pon->optical_irq);
	writel(PON_TOP_EVENTS, pon->top_irq);
	writel(OPT_EVENT_MASK, pon->optical_irq + 4);
	writel(BIT(3), pon->top_irq + 4);
	writel(0, pon->mac + MPCP_IE);
	return devm_request_threaded_irq(pon->dev, irq, NULL, rtl_mpcp_irq_thread,
					 IRQF_ONESHOT, "rtl9617c-mpcp", pon);
}

int rtl_pon_mpcp_stop_locked(struct rtl9617c_pon *pon)
{
	unsigned int channel;
	int ret;

	lockdep_assert_held(&pon->control_lock);
	cancel_delayed_work_sync(&pon->mpcp_work);
	cancel_delayed_work_sync(&pon->epon_tx_work);
	mutex_lock(&pon->lock);
	pon->epon_tx_action = 0;
	if (pon->mpcp_enabled) {
		pon->epon_epoch++;
		for (channel = 0; channel < 32; channel++)
			pon->epon_llid_epoch[channel] = pon->epon_epoch;
	}
	pon->mpcp_enabled = false;
	pon->epon_holdover_active = 0;
	pon->epon_holdover_pending = 0;
	pon->backoff.active = 0;
	if (!rtl_pon_mode_is_epon(pon->mode)) {
		mutex_unlock(&pon->lock);
		cancel_delayed_work_sync(&pon->epon_holdover_work);
		return 0;
	}
	rtl_pon_update(pon->top_irq + 4, BIT(0), 0);
	writel(0, pon->mac + MPCP_IE);
	writel(0, pon->mac + RTL_EPON_01A4);
	writel(0, pon->mac + RTL_EPON_01C4);
	writel(0, pon->mac + RTL_EPON_1374);
	rtl_pon_update(pon->mac + GLB_IE, EPON_GLOBAL_EVENTS, 0);
	rtl_pon_update(pon->mac + MPCP_CFG, BIT(31), 0);
	rtl_pon_update(pon->mac + MPCP_START, BIT(0), 0);
	writel(rtl_pon_llid_mask(pon), pon->mac + OFFLINE);
	pon->waiting = 0;
	pon->registered = readl(pon->mac + REGISTER_STATUS) & rtl_pon_llid_mask(pon);
	pon->mpcp_configured = false;
	ret = rtl_pon_epon_crypto_forget(pon, pon->epon_crypto_llids);
	rtl_pon_oam_carrier(pon);
	mutex_unlock(&pon->lock);
	cancel_delayed_work_sync(&pon->epon_holdover_work);
	/* Finish queued IRQ threads before changing modes or freeing the OAM netdev. */
	synchronize_irq(pon->mpcp_irq);
	return ret;
}

int rtl_pon_mpcp_configure_locked(struct rtl9617c_pon *pon)
{
	u32 sync;
	unsigned int channel;
	int ret = 0;

	lockdep_assert_held(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode)) {
		ret = -EOPNOTSUPP;
		goto unlock;
	}
	if (!pon->mac_prepared || !is_valid_ether_addr(pon->onu_mac)) {
		ret = -EAGAIN;
		goto unlock;
	}
	if (pon->mpcp_enabled)
		goto unlock;
	ret = rtl_pon_epon_crypto_forget(pon, pon->epon_crypto_llids);
	if (ret)
		goto unlock;
	pon->epon_epoch++;
	for (channel = 0; channel < 32; channel++)
		pon->epon_llid_epoch[channel] = pon->epon_epoch;
	/* MPCP identity is the LLID0 MAC stored in this board's original MIB. */
	rtl_pon_update(pon->mac + MAC_HIGH, GENMASK(15, 0), get_unaligned_be16(pon->onu_mac));
	writel(get_unaligned_be32(pon->onu_mac + 2), pon->mac + MAC_LOW);
	rtl_pon_update(pon->mac + LLID_MAPPING,
		GENMASK(5, 0) | BIT(7) | GENMASK(21, 16), 63 | BIT(7) | (63 << 16));
	sync = pon->llid_count == 1 ? 0xf800 : pon->llid_count <= 2 ? 0xf000 :
	       pon->llid_count <= 4 ? 0xe000 : pon->llid_count <= 8 ? 0xc000 :
	       pon->llid_count <= 16 ? 0x8000 : 0;
	rtl_pon_update(pon->mac + SYNC_TIME, GENMASK(15, 11), sync);
	rtl_pon_update(pon->mac + MPCP_CFG0,
		GENMASK(3, 0) | BIT(5) | BIT(7) | GENMASK(10, 8) | GENMASK(18, 13) |
		BIT(23) | BIT(29) | BIT(30),
		4 | BIT(7) | (8 << 13) | (pon->llid_count > 1 ? BIT(29) : 0));
	rtl_pon_update(pon->mac + MPCP_1G, GENMASK(15, 0), (0xf << 8) | 0x2a);
	/* Reference-unit live value: MPCP_10G = 0x10000c06. Bit 28 belongs to
	 * the 2.5G grant configuration the stock driver programs; the upstream
	 * driver only covered the 0xc00 field. */
	rtl_pon_update(pon->mac + MPCP_10G, RTL_MPCP_10G_REFERENCE_MASK,
		       RTL_MPCP_10G_REFERENCE_VALUE);
	rtl_pon_update(pon->mac + TIMEOUT_THRESHOLD, GENMASK(13, 0) | GENMASK(29, 16),
		5000 | (500 << 16));
	rtl_pon_update(pon->mac + MPCP_CFG, BIT(1) | GENMASK(18, 16) | BIT(31),
		GENMASK(18, 16) | BIT(31));
	/* 0x2050 is MPCP_DIS_PEND_TIME_THRED. It is separate from the MPCP/GATE
	 * timeout and the timestamp-drift auto-deregistration selected above. */
	rtl_pon_update(pon->mac + REGISTER_TIMEOUT, GENMASK(19, 0) | BIT(31),
		       0xffff | BIT(31));
	rtl_pon_update(pon->mac + LASER_TIME, GENMASK(7, 0) | GENMASK(23, 16), 32 | (32 << 16));
	writel(0, pon->mac + OFFLINE);
	pon->backoff.active = 0;
	pon->registered = readl(pon->mac + REGISTER_STATUS) & rtl_pon_llid_mask(pon);
	pon->waiting = rtl_pon_llid_mask(pon) & ~pon->registered;
	pon->mpcp_configured = true;
	pon->mpcp_enabled = true;
	pon->epon_health_at = jiffies + msecs_to_jiffies(3000);
	pon->epon_sync_failures = 0;
	writel(MPCP_EVENT_MASK, pon->mac + MPCP_IRQ);
	writel(MPCP_EVENT_MASK, pon->mac + MPCP_IE);
	writel(BIT(6), pon->mac + RTL_EPON_01A0);
	writel(BIT(9), pon->mac + RTL_EPON_01C0);
	writel(GENMASK(18, 17), pon->mac + RTL_EPON_1370);
	writel(BIT(6), pon->mac + RTL_EPON_01A4);
	writel(BIT(9), pon->mac + RTL_EPON_01C4);
	writel(GENMASK(18, 17), pon->mac + RTL_EPON_1374);
	rtl_pon_update(pon->mac + GLB_IE, EPON_GLOBAL_EVENTS, EPON_GLOBAL_EVENTS);
	rtl_pon_update(pon->top_irq + 4, PON_TOP_EVENTS, PON_TOP_EVENTS);
	schedule_delayed_work(&pon->mpcp_work, HZ);
	dev_info(pon->dev, "native MPCP configured: ONU %pM, %u LLIDs\n", pon->onu_mac, pon->llid_count);
	pon_dbg("mpcp configure: llids=%u registered=%08x waiting=%08x\n",
		pon->llid_count, pon->registered, pon->waiting);
unlock:
	mutex_unlock(&pon->lock);
	return ret;
}
