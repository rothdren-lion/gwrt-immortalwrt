// SPDX-License-Identifier: GPL-2.0-or-later
/* XG-PON/XGS-PON preparation and the PLoam state machine. */
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

unsigned int rtl_xgpon_read(void *context, unsigned int reg)
{
	return readl(((struct rtl9617c_pon *)context)->mac + reg);
}

void rtl_xgpon_write(void *context, unsigned int reg, unsigned int value)
{
	writel(value, ((struct rtl9617c_pon *)context)->mac + reg);
}

int rtl_xgpon_indirect(void *context, unsigned int reg, unsigned int value)
{
	struct rtl9617c_pon *pon = context;
	u32 status;
	int ret = readl_poll_timeout(pon->mac + reg, status, !(status & BIT(31)), 1, 100000);

	if (ret) return ret;
	writel(value, pon->mac + reg);
	return readl_poll_timeout(pon->mac + reg, status, !(status & BIT(31)), 1, 100000);
}

ssize_t rtl_pon_xgpon_identity(struct rtl9617c_pon *pon, const char *buf, size_t count)
{
	ssize_t ret = count;

	if (count != 44)
		return -EMSGSIZE;
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (rtl_pon_mode_is_epon(pon->mode) || pon->mode == RTL_PON_GPON)
		ret = -EOPNOTSUPP;
	else {
		memcpy(pon->xgpon_serial, buf, 8);
		memcpy(pon->xgpon_registration, buf + 8, 36);
		pon->xgpon_identity_configured = true;
	}
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	return ret;
}

int rtl_pon_xgpon_prepare_locked(struct rtl9617c_pon *pon)
{
	const struct rtl_dq_io io = {pon, rtl_xgpon_read, rtl_xgpon_write, rtl_xgpon_indirect};
	unsigned int index;
	bool symmetric = pon->mode == RTL_PON_XGSPON;
	int ret = 0;

	lockdep_assert_held(&pon->control_lock);
	if (pon->mode != RTL_PON_XGPON && pon->mode != RTL_PON_XGSPON)
		return -EOPNOTSUPP;
	ret = rtl_pon_stop_locked(pon);
	mutex_lock(&pon->lock);
	pon->mac_prepared = false;
	if (ret)
		goto unlock;
	if (!pon->serdes_configured || !pon->xgpon_identity_configured) {
		ret = -EAGAIN;
		goto unlock;
	}
	pon->puc_configured = false;
	pon->pdc_configured = false;
	pon->traffic_enabled = false;
	pon->xgpon_pending_valid = false;
	memset(pon->xgpon_restore_tcont, 0, sizeof(pon->xgpon_restore_tcont));
	/* Full initialization uses aal_xgpon_init timing, not the warm-reset path. */
	writel(0x00e, pon->control);
	writel(0x300, pon->gpon_control);
	msleep(100);
	writel(0x30e, pon->control);
	writel(0x307, pon->gpon_control);
	msleep(100);
	writel(symmetric ? 0x305 : 0x205, pon->gpon_control);
	msleep(100);
	rtl_xgpon_mac_parameters(&io, symmetric);
	rtl_xgpon_identity(&io, pon->xgpon_serial, pon->xgpon_registration);
	/* Start without mappings from any preceding ONU session. */
	for (index = 0; index < 32; index++) {
		ret = rtl_xgpon_tcont_set(&io, index, RTL_XGPON_ALLOC_ID_INVALID, false, false);
		if (ret)
			goto unlock;
	}
	for (index = 0; index < 256; index++) {
		rtl_xgpon_downstream_gem_set(&io, index, 0, false, false);
		ret = rtl_xgpon_upstream_gem_set(&io, index, 0, false, false, false);
		if (ret)
			goto unlock;
	}
	writel(0x0002ffff, pon->optical_control + 4);
	pon->mac_prepared = true;
	dev_info(pon->dev, "%s MAC identity, ACTP and data blocks prepared\n",
		rtl_pon_mode_name(pon->mode));
unlock:
	pon->mac_error = ret;
	mutex_unlock(&pon->lock);
	return ret;
}

void rtl_pon_xgpon_stop_locked(struct rtl9617c_pon *pon)
{
	const struct rtl_dq_io io = {pon, rtl_xgpon_read, rtl_xgpon_write, rtl_xgpon_indirect};

	lockdep_assert_held(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (pon->mode == RTL_PON_XGPON || pon->mode == RTL_PON_XGSPON) {
		rtl_pon_dying_gasp_stop(pon);
		pon->xgpon_recover = false;
		cancel_delayed_work(&pon->xgpon_recovery_work);
		cancel_delayed_work(&pon->xgpon_health_work);
		pon->xgpon_restore_pending = false;
		pon->xgpon_watchdog_armed = false;
		pon->xgpon_rogue_pending = false;
		rtl_pon_itu_paths_invalidate(pon, pon->mode);
		pon->xgpon_enabled = false;
		pon->itu_line_epoch++;
		pon->xgpon_omcc_ready = false;
		pon->xgpon_key_valid = 0;
		pon->xgpon_key_state = 0;
		pon->omci_master_key_valid = false;
		rtl_pon_update(pon->mac + RTL_XGTC_4124, 3, 0);
		rtl_pon_update(pon->mac + RTL_XGTC_4128, 3, 0);
		spin_lock_bh(&pon->omci_key_lock);
		pon->xgpon_key_ready = false;
		spin_unlock_bh(&pon->omci_key_lock);
		writel(0, pon->mac + RTL_XGTC_400C);
		writel(0, pon->mac + RTL_XGTC_4D20);
		writel(0, pon->mac + RTL_XGTC_4AA8);
		writel(0, pon->mac + RTL_XGTC_411C);
		rtl_xgpon_active(&io, false, pon->mode == RTL_PON_XGSPON);
		rtl_pon_update(pon->top_irq + 4, BIT(0), 0);
		gpiod_set_value_cansleep(pon->tx_disable, 1);
		if (pon->xgpon_recovery_phase) {
			rtl9617c_ni_pon_gate(pon->ni_dev, pon->xgpon_puc_saved.ni_enable);
			pon->xgpon_recovery_phase = 0;
		}
		if (pon->omci_device)
			netif_carrier_off(pon->omci_device);
	}
	mutex_unlock(&pon->lock);
	synchronize_irq(pon->mpcp_irq);
}

int rtl_pon_xgpon_activation_locked(struct rtl9617c_pon *pon, bool enable)
{
	const struct rtl_dq_io io = {pon, rtl_xgpon_read, rtl_xgpon_write, rtl_xgpon_indirect};
	int ret = 0;

	lockdep_assert_held(&pon->control_lock);
	pon_event_at(pon, PON_EV_XGPON_STATE, 0, (u32)enable, 0, 0);
	if (!enable) {
		rtl_pon_xgpon_stop_locked(pon);
		pon_event_at(pon, PON_EV_XGPON_STATE, 1, 0, pon->xgpon_omcc_id, 0);
		return 0;
	}
	mutex_lock(&pon->lock);
	if (pon->mode != RTL_PON_XGPON && pon->mode != RTL_PON_XGSPON) {
		ret = -EOPNOTSUPP;
		goto unlock;
	}
	if (pon->xgpon_recover) {
		ret = -EBUSY;
		goto unlock;
	}
	if (!pon->mac_prepared || !pon->puc_configured || !pon->pdc_configured ||
	    !netif_running(pon->omci_device)) {
		ret = -EAGAIN;
		goto unlock;
	}
	pon->xgpon_enabled = true;
	pon->xgpon_omcc_ready = false;
	pon->xgpon_activation_error = 0;
	pon->xgpon_health_state = ~0U;
	pon->xgpon_health_at = jiffies + HZ;
	pon->xgpon_watchdog_armed = false;
	writel(readl(pon->mac + RTL_XGTC_4D1C), pon->mac + RTL_XGTC_4D1C);
	writel(readl(pon->mac + RTL_XGTC_4AA4), pon->mac + RTL_XGTC_4AA4);
	writel(readl(pon->mac + RTL_XGTC_4118), pon->mac + RTL_XGTC_4118);
	/* ACTP controls activation; capture PLOAMs to maintain OMCC and its key. */
	writel(0x0fffffff, pon->mac + RTL_XGTC_4D2C);
	writel(15, pon->mac + RTL_XGTC_4D20);
	writel(BIT(5) | BIT(6) | BIT(7) | BIT(30) | BIT(31), pon->mac + RTL_XGTC_4AA8);
	writel(BIT(5), pon->mac + RTL_XGTC_411C);
	writel(BIT(0) | BIT(2) | BIT(4), pon->mac + RTL_XGTC_400C);
	rtl_pon_update(pon->top_irq + 4, BIT(0), BIT(0));
	rtl_pon_update(pon->serdes_init, BIT(4), BIT(4));
	ret = rtl_pon_serdes_restart_locked(pon);
	pon->serdes_error = ret;
	if (ret) {
		pon->xgpon_enabled = false;
		pon->xgpon_activation_error = ret;
		rtl_pon_update(pon->serdes_init, BIT(4), 0);
		gpiod_set_value_cansleep(pon->tx_disable, 1);
		netif_carrier_off(pon->omci_device);
		goto unlock;
	}
	pon->xgpon_last_state = readl(pon->mac + RTL_XGTC_4D30) & 7;
	rtl_xgpon_active(&io, true, pon->mode == RTL_PON_XGSPON);
	msleep(1);
	gpiod_set_value_cansleep(pon->tx_disable, 0);
	mod_delayed_work(system_wq, &pon->xgpon_health_work, msecs_to_jiffies(100));
unlock:
	pon_event_at(pon, PON_EV_XGPON_STATE, 1, (u32)ret, pon->xgpon_omcc_id,
		     (u32)pon->xgpon_activation_error);
	pon_dbg("xgpon state exit: ret=%d omcc_id=%u\n", ret,
		pon->xgpon_omcc_id);
	mutex_unlock(&pon->lock);
	return ret;
}

void rtl_pon_xgpon_optical_irq(struct rtl9617c_pon *pon, u32 events)
{
	u32 now, elapsed;

	pon_event_at(pon, PON_EV_IRQ, 0, 3, events, pon->xgpon_irq_count);

	lockdep_assert_held(&pon->lock);
	if (!pon->xgpon_enabled || (events & BIT(0)) || !(events & (BIT(8) | BIT(9)))) {
		pon_event_at(pon, PON_EV_IRQ, 2, 3, events, pon->xgpon_irq_count);
		return;
	}
	now = jiffies_to_msecs(jiffies);
	elapsed = now - pon->xgpon_rogue_last_ms;
	pon->xgpon_rogue_last_ms = now;
	if (elapsed < 1000) {
		pon->xgpon_rogue_count[events & BIT(8) ? 1 : 0]++;
		gpiod_set_value_cansleep(pon->tx_disable, 1);
		pon->xgpon_rogue_pending = true;
		dev_err(pon->dev, "XGTC optical rogue events=%08x interval_ms=%u; forcing O7\n", events, elapsed);
		mod_delayed_work(system_wq, &pon->xgpon_health_work, 0);
	}
	/* Original optical worker rearms detection after either interval outcome. */
	rtl_pon_update(pon->optical_control, BIT(1), 0);
	rtl_pon_update(pon->optical_control, BIT(1), BIT(1));
	pon_event_at(pon, PON_EV_IRQ, 1, 3, events, pon->xgpon_irq_count);
}


void rtl_pon_xgpon_irq(struct rtl9617c_pon *pon)
{
	const struct rtl_dq_io io = {pon, rtl_xgpon_read, rtl_xgpon_write, rtl_xgpon_indirect};
	u32 status[2], global, act, plmp, dsfp, state, key_control, transitions;
	u8 order[2], packets[2][RTL_XGPON_PLOAM_BYTES];
	unsigned int count, i;
	bool was_active;
	int ret = 0;

	lockdep_assert_held(&pon->lock);
	pon_event_at(pon, PON_EV_IRQ, 0, 2, 0, pon->xgpon_irq_count);
	global = readl(pon->mac + RTL_XGTC_4008);
	act = readl(pon->mac + RTL_XGTC_4D1C) & readl(pon->mac + RTL_XGTC_4D20);
	plmp = readl(pon->mac + RTL_XGTC_4AA4) & readl(pon->mac + RTL_XGTC_4AA8);
	dsfp = readl(pon->mac + RTL_XGTC_4118) & readl(pon->mac + RTL_XGTC_411C);
	key_control = readl(pon->mac + RTL_XGTC_4AB8);
	transitions = readl(pon->mac + RTL_XGTC_4D28) & readl(pon->mac + RTL_XGTC_4D2C);
	state = readl(pon->mac + RTL_XGTC_4D30) & 7;
	writel(act, pon->mac + RTL_XGTC_4D1C);
	writel(plmp, pon->mac + RTL_XGTC_4AA4);
	writel(dsfp, pon->mac + RTL_XGTC_4118);
	writel(transitions, pon->mac + RTL_XGTC_4D28);
	pon->xgpon_irq_count++;
	pon->xgpon_last_irq = global;
	if (!pon->xgpon_enabled) {
		pon_event_at(pon, PON_EV_IRQ, 2, 2, global, pon->xgpon_irq_count);
		return;
	}
	/* Original ACTP dispatch gates the laser in O7 and releases it in O23. */
	if (state == 5)
		gpiod_set_value_cansleep(pon->tx_disable, 1);
	else if (state == 1 && !pon->xgpon_rogue_pending)
		gpiod_set_value_cansleep(pon->tx_disable, 0);
	was_active = pon->xgpon_last_state == 3 || pon->xgpon_last_state == 4;
	if (transitions)
		pon->xgpon_last_transitions = transitions;
	if (transitions & BIT(11))
		pon->xgpon_deactivations++;
	if ((was_active && state != 3 && state != 4) ||
	    (transitions & (BIT(1) | BIT(10) | BIT(11)))) {
		rtl_pon_dying_gasp_stop(pon);
		pon->itu_line_epoch++;
		pon->xgpon_omcc_ready = false;
		if (pon->itu_paths_ready)
			rtl_pon_itu_paths_invalidate(pon, pon->mode);
		pon->omci_master_key_valid = false;
		pon->xgpon_key_valid = 0;
		pon->xgpon_key_state = 0;
		spin_lock_bh(&pon->omci_key_lock);
		pon->xgpon_key_ready = false;
		spin_unlock_bh(&pon->omci_key_lock);
		rtl_pon_update(pon->mac + RTL_XGTC_4E00, BIT(6), BIT(6));
		rtl_pon_update(pon->mac + RTL_XGTC_4124, 3, 0);
		rtl_pon_update(pon->mac + RTL_XGTC_4128, 3, 0);
	}
	status[0] = readl(pon->mac + RTL_XGTC_4B28);
	status[1] = readl(pon->mac + RTL_XGTC_4B2C);
	count = rtl_xgpon_ploam_order(status[0], status[1], order);
	/* Copy both old buffers before processing may permit a hardware refill. */
	for (i = 0; i < count; i++)
		rtl_xgpon_ploam_receive(&io, order[i], packets[i]);
	for (i = 0; i < count; i++) {
		const u8 *packet = packets[i];

		if (status[order[i]] & BIT(15)) {
			pon->ploam_mic_errors++;
			continue;
		}
		pon->ploam_rx++;
		/* Original burst-profile processing derives OMCI IK after PON-TAG changes. */
		if (packet[2] == 1)
			ret = rtl_pon_xgpon_omci_key(pon, packet + 25);
		if (packet[2] == 3 && !memcmp(packet + 6, pon->xgpon_serial, 8)) {
			unsigned int index, onu_id = get_unaligned_be16(packet + 4);

			pon->xgpon_omcc_ready = false;
			/* Stock assigns unencrypted OMCC XGEMs1..7 to the actual ONU-ID. */
			for (index = 1; index < 8; index++) {
				ret = rtl_xgpon_upstream_gem_set(&io, index, onu_id, true, false, false);
				if (ret) break;
				rtl_xgpon_downstream_gem_set(&io, index, onu_id, true, false);
			}
			if (!ret) {
				pon->xgpon_omcc_id = onu_id;
				pon->xgpon_omcc_ready = true;
			}
		}
		if (ret)
			pon->xgpon_activation_error = ret;
	}
	if ((transitions & BIT(12)) && pon->xgpon_key_ready) {
		ret = rtl_pon_xgpon_ack_update(pon);
		if (ret) pon->xgpon_activation_error = ret;
	}
	if (plmp & BIT(7))
		pon->xgpon_watchdog_armed = true;
	if (plmp & (BIT(5) | BIT(6) | BIT(7)))
		rtl_pon_xgpon_key_irq(pon, plmp, key_control);
	if (dsfp & BIT(5)) {
		ret = rtl_xgpon_omcc_aes_toggle(&io);
		if (ret) {
			pon->xgpon_activation_error = ret;
			pon->xgpon_omcc_ready = false;
			rtl_pon_dying_gasp_stop(pon);
			dev_err(pon->dev, "XGTC OMCC AES mode update failed: %d\n", ret);
		}
	}
	if (pon->xgpon_omcc_ready && state == 3 && pon->xgpon_key_ready)
		netif_carrier_on(pon->omci_device);
	else
		netif_carrier_off(pon->omci_device);
	if (pon->xgpon_omcc_ready && state == 3 && pon->xgpon_key_ready)
		rtl_pon_dying_gasp_prepare(pon);
	else if (state != 3 && state != 4)
		rtl_pon_dying_gasp_stop(pon);
	/* O6 retains business state together with the OMCC and session keys. */
	if (pon->itu_paths_ready && (!pon->xgpon_omcc_ready || !pon->xgpon_key_ready ||
	    (state != 3 && state != 4)))
		rtl_pon_itu_paths_invalidate(pon, pon->mode);
	rtl_pon_itu_carrier(pon);
	if (was_active && state != 3 && state != 4) {
		/* Outside O6 grace, drain T-CONT/PUC without rebuilding SerDes
		 * or replacing the configured FE policy. */
		netif_carrier_off(pon->omci_device);
		pon->xgpon_recover = true;
		if (transitions & BIT(23)) rtl_xgtc_restart_sync(&io);
		schedule_delayed_work(&pon->xgpon_recovery_work, 0);
	}
	if (state != pon->xgpon_last_state || (transitions & BIT(11))) {
		dev_info(pon->dev, "%s ACTP %u -> %u ONU-ID=%u OMCC=%u error=%d events=%08x ploam_irq=%08x\n",
			rtl_pon_mode_name(pon->mode), pon->xgpon_last_state, state,
			pon->xgpon_omcc_id, pon->xgpon_omcc_ready, pon->xgpon_activation_error,
			transitions, plmp);
		pon->xgpon_last_state = state;
	}
	pon_event_at(pon, PON_EV_IRQ, 1, 2, global, pon->xgpon_irq_count);
}



static ssize_t xgpon_identity_write(struct file *file, struct kobject *kobj,
				    const struct bin_attribute *attr, char *buf,
				    loff_t offset, size_t count)
{
	if (offset)
		return -EINVAL;
	return rtl_pon_xgpon_identity(dev_get_drvdata(kobj_to_dev(kobj)), buf, count);
}
BIN_ATTR(xgpon_identity, 0200, NULL, xgpon_identity_write, 0);
