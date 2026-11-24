// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * debugfs front end for the PON block.
 *
 * Design rules:
 *  - every text entry reuses the existing rtl_pon_*_state() formatter, so
 *    sysfs and debugfs can never disagree about a field name or a decode;
 *  - entries that only exist for one mode print "n/a (mode=...)" instead of
 *    touching registers the current mode never mapped;
 *  - reading never modifies a mapping and never clears a status bit; the
 *    PDC/PUC snapshots do issue the indirect-read trigger their access
 *    registers require, which only latches data for readback.
 *
 * Knobs: debug=N raises pr_debug output, debug_poke=1 enables reg_write.
 * Both default to 0 and are read-only after load.
 */
#define pr_fmt(fmt) "rtl9617c-pon: " fmt
#include <linux/debugfs.h>
#include <linux/gpio/consumer.h>
#include <linux/io.h>
#include <linux/math64.h>
#include <linux/minmax.h>
#include <linux/netdevice.h>
#include <linux/seq_file.h>
#include <linux/string.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "rtl9617c_bosa.h"

unsigned int rtl9617c_pon_debug;
module_param_named(debug, rtl9617c_pon_debug, uint, 0644);
MODULE_PARM_DESC(debug, "Enable pr_debug tracing for the PON block (0=off)");

bool pon_debug_poke;
module_param_named(debug_poke, pon_debug_poke, bool, 0644);
MODULE_PARM_DESC(debug_poke, "Enable the experimental reg_write debugfs channel");

static struct rtl9617c_pon *pon_debug_dev;
static struct dentry *pon_debug_dir;

struct rtl9617c_pon *pon_debug_pon(void)
{
	return READ_ONCE(pon_debug_dev);
}

/*
 * Reuse one of the sysfs state formatters. They all write into a PAGE_SIZE
 * buffer with sysfs_emit_at(), which requires a page-aligned base.
 */
static void pon_debug_dump(struct seq_file *m,
			   ssize_t (*fmt)(struct rtl9617c_pon *pon, char *buf))
{
	struct rtl9617c_pon *pon = pon_debug_pon();
	char *buf;
	ssize_t length;

	if (!pon) {
		seq_puts(m, "device gone\n");
		return;
	}
	buf = (char *)__get_free_page(GFP_KERNEL);
	if (!buf) {
		seq_puts(m, "out of memory\n");
		return;
	}
	mutex_lock(&pon->lock);
	length = fmt(pon, buf);
	mutex_unlock(&pon->lock);
	if (length > 0)
		seq_write(m, buf, min_t(size_t, length, PAGE_SIZE));
	else if (length < 0)
		seq_printf(m, "n/a (%d)\n", (int)length);
	free_page((unsigned long)buf);
}

static void pon_debug_na(struct seq_file *m, struct rtl9617c_pon *pon, const char *what)
{
	seq_printf(m, "%s: n/a (mode=%s)\n", what, rtl_pon_mode_name(pon->mode));
}

static int pon_state_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();
	struct net_device *oam;
	bool carrier = false, up = false;

	if (!pon) {
		seq_puts(m, "device gone\n");
		return 0;
	}
	oam = READ_ONCE(pon->oam_endpoint.netdev);
	if (oam) {
		carrier = netif_carrier_ok(oam);
		up = netif_running(oam);
	}
	seq_printf(m, "mode=%s ", rtl_pon_mode_name(pon->mode));
	if (rtl_pon_mode_is_epon(pon->mode)) {
		seq_printf(m, "mpcp_registered=%08x mpcp_enabled=%u register_frames=%u ",
			   pon->registered, pon->mpcp_enabled, pon->register_frames);
	} else if (pon->mode == RTL_PON_GPON) {
		seq_printf(m, "ploam_state=%u onu_id=%u omcc_ready=%u omcc_gem=%u ",
			   pon->gpon_last_state, pon->gpon_omcc_onu_id,
			   pon->gpon_omcc_ready, pon->gpon_omcc_gem);
	} else {
		/*
		 * XG-PON maps OMCC onto XGEM 1..7 keyed by ONU-ID, so a single gem
		 * id does not exist; report n/a rather than printing onu_id twice.
		 */
		seq_printf(m, "ploam_state=%u onu_id=%u omcc_ready=%u omcc_gem=%s ",
			   pon->xgpon_last_state, pon->xgpon_omcc_id,
			   pon->xgpon_omcc_ready, "n/a");
	}
	seq_printf(m,
		   "traffic_enabled=%u pdc_configured=%u puc_configured=%u oam_endpoint_up=%u carrier=%u ",
		   pon->traffic_enabled, pon->pdc_configured, pon->puc_configured,
		   up, carrier);
	/* llid_count only means something for EPON; say n/a instead of 0. */
	if (rtl_pon_mode_is_epon(pon->mode))
		seq_printf(m, "llids=%u\n", pon->llid_count);
	else
		seq_puts(m, "llids=n/a\n");
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_state);

static int pon_pdc_show(struct seq_file *m, void *unused)
{
	pon_debug_dump(m, rtl_pon_pdc_state);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_pdc);

static int pon_puc_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();

	pon_debug_dump(m, rtl_pon_puc_state);
	if (pon && !rtl_pon_mode_is_epon(pon->mode)) {
		/*
		 * GPON/XG-PON use one flat queue space; the EPON slots 0..7 are
		 * the OMCC T-CONT carriers here too, everything above is GEM.
		 */
		seq_puts(m, "legend: port0..1=pvt, cir/pir/bp index 0..7=omcc, 8..255=gem\n");
	}
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_puc);

static int pon_mpcp_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();

	if (!pon) {
		seq_puts(m, "device gone\n");
		return 0;
	}
	if (!rtl_pon_mode_is_epon(pon->mode)) {
		pon_debug_na(m, pon, "mpcp");
		return 0;
	}
	pon_debug_dump(m, rtl_pon_mpcp_state);
	pon_debug_dump(m, rtl_pon_llid_table);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_mpcp);

static int pon_ploam_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();
	struct pon_event ev;

	if (!pon) {
		seq_puts(m, "device gone\n");
		return 0;
	}
	if (rtl_pon_mode_is_epon(pon->mode)) {
		pon_debug_na(m, pon, "ploam");
		return 0;
	}
	pon_debug_dump(m, rtl_pon_itu_state);
	seq_printf(m, "ploam_rx=%llu ploam_tx=%llu ploam_mic_errors=%llu\n",
		   pon->ploam_rx, pon->ploam_tx, pon->ploam_mic_errors);
	seq_printf(m, "ploam_identity_configured=%u omcc_ready=%u\n",
		   pon->mode == RTL_PON_GPON ? pon->gpon_identity_configured :
		   pon->xgpon_identity_configured,
		   pon->mode == RTL_PON_GPON ? pon->gpon_omcc_ready : pon->xgpon_omcc_ready);
	if (pon_event_last(PON_EV_PLOAM_RX, &ev))
		seq_printf(m, "last_rx type=%u seq=%u len=%u t_ms=%llu\n",
			   ev.a, ev.b, ev.c, div_u64(ev.ns, NSEC_PER_MSEC));
	if (pon_event_last(PON_EV_PLOAM_TX, &ev))
		seq_printf(m, "last_tx type=%u seq=%u len=%u t_ms=%llu\n",
			   ev.a, ev.b, ev.c, div_u64(ev.ns, NSEC_PER_MSEC));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_ploam);

static int pon_itu_paths_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();

	if (!pon) {
		seq_puts(m, "device gone\n");
		return 0;
	}
	if (rtl_pon_mode_is_epon(pon->mode)) {
		pon_debug_na(m, pon, "itu_paths");
		return 0;
	}
	pon_debug_dump(m, rtl_pon_itu_paths_state);
	seq_printf(m, "queue_map_81bc=%08x/%08x/%08x/%08x/\n",
		   readl(pon->mac + VALID_VOQ0), readl(pon->mac + RTL_PUC_81B8),
		   readl(pon->mac + RTL_PUC_81B4), readl(pon->mac + RTL_PUC_81B0));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_itu_paths);

static int pon_xgpon_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();

	if (!pon) {
		seq_puts(m, "device gone\n");
		return 0;
	}
	if (pon->mode != RTL_PON_XGPON && pon->mode != RTL_PON_XGSPON) {
		pon_debug_na(m, pon, "xgpon");
		return 0;
	}
	seq_printf(m,
		   "profile=%u burst_polarity=%u recovery_phase=%u restore_pending=%u watchdog=%u rogue_pending=%u\n",
		   pon->xgpon_last_state, pon->burst_polarity, pon->xgpon_recovery_phase,
		   pon->xgpon_restore_pending, pon->xgpon_watchdog_armed,
		   pon->xgpon_rogue_pending);
	seq_printf(m,
		   "health_state=%u grants=%u matches=%u no_grants=%u fec=%llu sn=%llu mac_resets=%llu reset_reason=%u\n",
		   pon->xgpon_health_state, pon->xgpon_health_grants,
		   pon->xgpon_health_matches, pon->xgpon_health_no_grants,
		   pon->xgpon_health_fec, pon->xgpon_health_sn,
		   pon->xgpon_mac_resets, pon->xgpon_reset_reason);
	seq_printf(m, "key_ready=%u key_state=%u active_key=%u key_reports=%llu deactivations=%llu\n",
		   pon->xgpon_key_ready, pon->xgpon_key_state, pon->xgpon_active_key + 1,
		   pon->xgpon_key_reports, pon->xgpon_deactivations);
	seq_printf(m, "gem_upstream_en=%08x gem_downstream_en=%08x alloc_valid=%08x\n",
		   readl(pon->mac + RTL_GPON_6174), readl(pon->mac + RTL_GPON_6138),
		   pon->itu_alloc_valid);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_xgpon);

static int pon_oam_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();
	struct net_device *oam;
	struct pon_event ev;
	unsigned long rx = 0, tx = 0;
	unsigned int i;

	if (!pon) {
		seq_puts(m, "device gone\n");
		return 0;
	}
	if (!rtl_pon_mode_is_epon(pon->mode)) {
		pon_debug_na(m, pon, "oam");
		return 0;
	}
	oam = READ_ONCE(pon->oam_endpoint.netdev);
	rcu_read_lock();
	for (i = 0; i < 32; i++) {
		struct net_device *dev = rcu_dereference(pon->oam_devices[i]);

		if (!dev)
			continue;
		rx += dev->stats.rx_packets;
		tx += dev->stats.tx_packets;
	}
	rcu_read_unlock();
	seq_printf(m, "traffic_enabled=%u endpoint=%s up=%u carrier=%u rx=%lu tx=%lu\n",
		   pon->traffic_enabled, oam ? oam->name : "none",
		   oam ? netif_running(oam) : 0, oam ? netif_carrier_ok(oam) : 0, rx, tx);
	seq_printf(m, "last_llid=%u last_source=%u registered=%08x waiting=%08x\n",
		   READ_ONCE(pon->last_oam_llid), READ_ONCE(pon->last_oam_source),
		   pon->registered, pon->waiting);
	if (pon_event_last(PON_EV_OAM_TX, &ev))
		seq_printf(m, "last_tx llid=%u len=%u queue=%u t_ms=%llu\n",
			   ev.a, ev.b, ev.c, div_u64(ev.ns, NSEC_PER_MSEC));
	if (pon_event_last(PON_EV_OAM_RX, &ev))
		seq_printf(m, "last_rx llid=%u len=%u source=%u t_ms=%llu\n",
			   ev.a, ev.b, ev.c, div_u64(ev.ns, NSEC_PER_MSEC));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_oam);

static int pon_omci_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();
	struct net_device *dev;
	struct pon_event ev;

	if (!pon) {
		seq_puts(m, "device gone\n");
		return 0;
	}
	if (rtl_pon_mode_is_epon(pon->mode)) {
		pon_debug_na(m, pon, "omci");
		return 0;
	}
	dev = READ_ONCE(pon->omci_device);
	seq_printf(m, "channel=%s up=%u qualified=%u cmac=%u kdf=%u\n",
		   dev ? dev->name : "none", dev ? netif_running(dev) : 0,
		   pon->gpon_omcc_ready || pon->xgpon_omcc_ready,
		   !!pon->omci_cmac, !!pon->omci_kdf);
	seq_printf(m, "master_key_valid=%u key_ready=%u key_state=%u active_key=%u key_reports=%llu\n",
		   pon->omci_master_key_valid, pon->xgpon_key_ready,
		   pon->xgpon_key_state, pon->xgpon_active_key + 1, pon->xgpon_key_reports);
	if (pon_event_last(PON_EV_OMCI_RX, &ev))
		seq_printf(m, "last_rx type=%u tid=%u len=%u t_ms=%llu\n",
			   ev.a, ev.b, ev.c, div_u64(ev.ns, NSEC_PER_MSEC));
	if (pon_event_last(PON_EV_OMCI_TX, &ev))
		seq_printf(m, "last_tx type=%u tid=%u len=%u t_ms=%llu\n",
			   ev.a, ev.b, ev.c, div_u64(ev.ns, NSEC_PER_MSEC));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_omci);

static int pon_optical_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();

	if (!pon) {
		seq_puts(m, "device gone\n");
		return 0;
	}
	seq_printf(m, "mode=%s control=%08x status=%08x rx_los=%u module_absent=%u tx_signal_detect=%u tx_fault=%u tx_disabled=%u\n",
		   rtl_pon_mode_name(pon->mode), readl(pon->optical_control),
		   readl(pon->optical_status), !!(readl(pon->optical_status) & BIT(3)),
		   !!(readl(pon->optical_status) & BIT(2)),
		   !!(readl(pon->optical_status) & BIT(1)),
		   !!(readl(pon->optical_status) & BIT(0)),
		   gpiod_get_value_cansleep(pon->tx_disable));
	/*
	 * Calibration state and the module's own diagnostics are the BOSA
	 * driver's job; reuse its formatters instead of re-decoding I2C here.
	 */
	if (pon->bosa_dev) {
		char *buf = (char *)__get_free_page(GFP_KERNEL);

		if (!buf)
			return 0;
		if (rtl9617c_bosa_state(pon->bosa_dev, buf) > 0)
			seq_write(m, buf, strlen(buf));
		if (rtl9617c_bosa_diagnostics(pon->bosa_dev, buf) > 0)
			seq_write(m, buf, strlen(buf));
		free_page((unsigned long)buf);
	}
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_optical);

static int pon_serdes_show(struct seq_file *m, void *unused)
{
	pon_debug_dump(m, rtl_pon_serdes_state);
	pon_debug_dump(m, rtl_pon_serdes_registers);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_serdes);

static int pon_irq_show(struct seq_file *m, void *unused)
{
	struct rtl9617c_pon *pon = pon_debug_pon();
	struct pon_event ev;

	if (!pon) {
		seq_puts(m, "device gone\n");
		return 0;
	}
	seq_printf(m, "mpcp_irq=%d count=%u last=%08x\n", pon->mpcp_irq,
		   pon->mpcp_irq_count, pon->last_mpcp_irq);
	seq_printf(m, "optical count=%u last=%08x\n", pon->optical_irq_count,
		   pon->last_optical_irq);
	seq_printf(m, "gpon count=%llu last=%08x\n", pon->gpon_irq_count,
		   pon->gpon_last_irq);
	seq_printf(m, "xgpon count=%llu last=%08x transitions=%08x\n",
		   pon->xgpon_irq_count, pon->xgpon_last_irq, pon->xgpon_last_transitions);
	if (pon_event_last(PON_EV_IRQ, &ev))
		seq_printf(m, "last block=%u status=%08x count=%u t_ms=%llu\n",
			   ev.a, ev.b, ev.c, div_u64(ev.ns, NSEC_PER_MSEC));
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(pon_irq);

int pon_debug_init(struct rtl9617c_pon *pon)
{
	WRITE_ONCE(pon_debug_dev, pon);
	pon_debug_dir = debugfs_create_dir("rtl9617c-pon", NULL);
	if (IS_ERR_OR_NULL(pon_debug_dir)) {
		/* debugfs is optional; a missing mount must not fail probe. */
		pon_debug_dir = NULL;
		return 0;
	}
	debugfs_create_file("state", 0400, pon_debug_dir, NULL, &pon_state_fops);
	debugfs_create_file("pdc", 0400, pon_debug_dir, NULL, &pon_pdc_fops);
	debugfs_create_file("puc", 0400, pon_debug_dir, NULL, &pon_puc_fops);
	debugfs_create_file("mpcp", 0400, pon_debug_dir, NULL, &pon_mpcp_fops);
	debugfs_create_file("ploam", 0400, pon_debug_dir, NULL, &pon_ploam_fops);
	debugfs_create_file("itu_paths", 0400, pon_debug_dir, NULL, &pon_itu_paths_fops);
	debugfs_create_file("xgpon", 0400, pon_debug_dir, NULL, &pon_xgpon_fops);
	debugfs_create_file("oam", 0400, pon_debug_dir, NULL, &pon_oam_fops);
	debugfs_create_file("omci", 0400, pon_debug_dir, NULL, &pon_omci_fops);
	debugfs_create_file("optical", 0400, pon_debug_dir, NULL, &pon_optical_fops);
	debugfs_create_file("serdes", 0400, pon_debug_dir, NULL, &pon_serdes_fops);
	debugfs_create_file("irq", 0400, pon_debug_dir, NULL, &pon_irq_fops);
	pon_debug_events_init(pon_debug_dir);
	pon_debug_regs_init(pon_debug_dir);
	return 0;
}

void pon_debug_remove(struct rtl9617c_pon *pon)
{
	debugfs_remove_recursive(pon_debug_dir);
	pon_debug_dir = NULL;
	WRITE_ONCE(pon_debug_dev, NULL);
}
