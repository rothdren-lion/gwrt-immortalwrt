// SPDX-License-Identifier: GPL-2.0-or-later
/* XGTC health watchdog: grant/FEC/serial-number observation and restart. */
#include <linux/io.h>
#include <linux/jiffies.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/itu/xgpon_hw.h"


/* Original one-second O1/O23/O5 checks; a reset reason is retained for diagnosis. */
static unsigned int rtl_xgpon_health_check(struct rtl9617c_pon *pon, u32 state)
{
	u32 grants, sn, fec, delta, optical;

	if (pon->xgpon_health_state != state) {
		pon->xgpon_health_state = state;
		pon->xgpon_health_grants = 0;
		pon->xgpon_health_matches = 0;
		pon->xgpon_health_no_grants = 0;
		return 0;
	}
	if (!state) {
		optical = readl(pon->optical_status);
		if (optical & (BIT(3) | BIT(2))) {
			pon->xgpon_health_matches = 0;
			return 0;
		}
		fec = readl(pon->mac + RTL_XGTC_4D98);
		pon->xgpon_health_fec += fec;
		if (fec > 0x2000 &&
		    (readl(pon->mac + RTL_XGTC_452C) & 7) != 3) {
			if (++pon->xgpon_health_matches >= 3)
				return 1;
		} else {
			pon->xgpon_health_matches = 0;
		}
	} else if (state == 1) {
		grants = readl(pon->mac + RTL_XGTC_4860);
		sn = readl(pon->mac + RTL_XGTC_4C50);
		pon->xgpon_health_sn += sn;
		if (grants == pon->xgpon_health_grants) {
			if (++pon->xgpon_health_no_grants >= 20)
				return 2;
		} else {
			pon->xgpon_health_no_grants = 0;
			if (!sn && pon->xgpon_health_grants)
				pon->xgpon_health_matches++;
			else
				pon->xgpon_health_matches = 0;
			pon->xgpon_health_grants = grants;
		}
		if (pon->xgpon_health_matches >= 2)
			return 3;
	} else if (state == 3) {
		grants = readl(pon->mac + RTL_XGTC_4860);
		delta = grants > pon->xgpon_health_grants ? grants - pon->xgpon_health_grants :
			pon->xgpon_health_grants - grants;
		pon->xgpon_health_grants = grants;
		if (delta > 32)
			pon->xgpon_health_matches = 0;
		else if (++pon->xgpon_health_matches >= 5)
			return 4;
	} else {
		pon->xgpon_health_matches = 0;
		pon->xgpon_health_no_grants = 0;
	}
	return 0;
}

void rtl_pon_xgpon_health(struct work_struct *work)
{
	struct rtl9617c_pon *pon = container_of(to_delayed_work(work), struct rtl9617c_pon, xgpon_health_work);
	const struct rtl_dq_io io = {pon, rtl_xgpon_read, rtl_xgpon_write, rtl_xgpon_indirect};
	u32 state, ready, reason = 0;
	int ret;

	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (!pon->xgpon_enabled)
		goto unlock;
	if (pon->xgpon_rogue_pending) {
		pon->xgpon_rogue_pending = false;
		rtl_pon_dying_gasp_stop(pon);
		netif_carrier_off(pon->omci_device);
		msleep(1);
		rtl_pon_update(pon->serdes_init, BIT(4), BIT(4));
		ret = rtl_pon_serdes_restart_locked(pon);
		pon->serdes_error = ret;
		if (ret)
			goto stop;
		rtl_xgpon_active(&io, true, pon->mode == RTL_PON_XGSPON);
		rtl_pon_update(pon->mac + RTL_XGTC_4D00, BIT(0), BIT(0));
		rtl_pon_update(pon->mac + RTL_XGTC_4D30, 7, 5);
		rtl_pon_update(pon->mac + RTL_XGTC_4D00, BIT(0), 0);
		rtl_pon_itu_carrier(pon);
	}
	if (pon->xgpon_recover)
		goto reschedule;
	state = readl(pon->mac + RTL_XGTC_4D30) & 7;
	if (pon->xgpon_restore_pending) {
		if (state < 3) {
			pon->xgpon_restore_at = 0;
		} else if (!pon->xgpon_restore_at && state == 3) {
			for (unsigned int i = 1; i < 32; i++) {
				u32 word = pon->xgpon_restore_tcont[i];

				if (!(word & BIT(24)))
					continue;
				ret = rtl_xgpon_tcont_set(&io, i, word & 0x3fff, false, true);
				if (ret) {
					dev_err(pon->dev, "XGTC T-CONT restore failed index=%u: %d\n", i, ret);
					goto stop;
				}
			}
			pon->xgpon_restore_at = jiffies + msecs_to_jiffies(3000);
		} else if (pon->xgpon_restore_at && time_after_eq(jiffies, pon->xgpon_restore_at)) {
			for (unsigned int i = 0; i < 8; i++)
				writel(pon->xgpon_puc_saved.valid[i], pon->mac + VALID_VOQ0 - i * 4);
			pon->xgpon_restore_pending = false;
			rtl_pon_itu_carrier(pon);
		}
	}
	if (pon->xgpon_watchdog_armed) {
		for (unsigned int i = 0; i < 20; i++) {
			ready = readl(pon->mac + RTL_XGTC_4AFC);
			if (!(ready & BIT(31)))
				break;
		}
		if (ready & BIT(31))
			reason = 5;
	}
	if (!reason && time_after_eq(jiffies, pon->xgpon_health_at)) {
		pon->xgpon_health_at = jiffies + HZ;
		reason = rtl_xgpon_health_check(pon, state);
	}
	if (reason) {
		pon->xgpon_reset_reason = reason;
		dev_err(pon->dev, "XGTC hardware stalled reason=%u ACTP=%08x grants=%08x PLOAM_TX=%08x\n",
			reason, readl(pon->mac + RTL_XGTC_4D30), readl(pon->mac + RTL_XGTC_4860), readl(pon->mac + RTL_XGTC_4AFC));
		ret = rtl_xgpon_mac_restart_locked(pon, reason != 5);
		pon->xgpon_activation_error = ret;
		if (ret)
			goto stop;
	}
reschedule:
	schedule_delayed_work(&pon->xgpon_health_work, msecs_to_jiffies(100));
	goto unlock;
stop:
	pon->xgpon_activation_error = ret;
	pon->xgpon_enabled = false;
	rtl_pon_dying_gasp_stop(pon);
	pon->mac_prepared = false;
	rtl_xgpon_active(&io, false, pon->mode == RTL_PON_XGSPON);
	rtl_pon_update(pon->serdes_init, BIT(4), 0);
	gpiod_set_value_cansleep(pon->tx_disable, 1);
	netif_carrier_off(pon->omci_device);
	rtl_pon_itu_carrier(pon);
unlock:
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
}
