// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/export.h>
#include <linux/netdevice.h>
#include <linux/rcupdate.h>

#include "ni.h"
#include "ni_ext.h"
#include "fe/fe.h"

#define NI_OAM_PORT			12
#define NI_OAM_MAP_DEST			12
#define NI_OAM_ES_SPEED_10G		6

static DEFINE_MUTEX(rtl_ni_tx_hook_lock);
static rtl9617c_ni_tx_hook_t __rcu rtl_ni_tx_hook;
static rtl9617c_ni_dma_reset_cb_t __rcu rtl_ni_dma_reset_cb;

int rtl9617c_ni_register_tx_hook(rtl9617c_ni_tx_hook_t fn,
				 rtl9617c_ni_dma_reset_cb_t on_dma_reset)
{
	if (!fn)
		return -EINVAL;
	mutex_lock(&rtl_ni_tx_hook_lock);
	if (rcu_dereference_protected(rtl_ni_tx_hook,
				      lockdep_is_held(&rtl_ni_tx_hook_lock))) {
		mutex_unlock(&rtl_ni_tx_hook_lock);
		return -EBUSY;
	}
	rcu_assign_pointer(rtl_ni_dma_reset_cb, on_dma_reset);
	rcu_assign_pointer(rtl_ni_tx_hook, fn);
	mutex_unlock(&rtl_ni_tx_hook_lock);
	return 0;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_register_tx_hook);

void rtl9617c_ni_unregister_tx_hook(rtl9617c_ni_tx_hook_t fn)
{
	mutex_lock(&rtl_ni_tx_hook_lock);
	if (rcu_dereference_protected(rtl_ni_tx_hook,
				      lockdep_is_held(&rtl_ni_tx_hook_lock)) == fn) {
		RCU_INIT_POINTER(rtl_ni_tx_hook, NULL);
		RCU_INIT_POINTER(rtl_ni_dma_reset_cb, NULL);
	}
	mutex_unlock(&rtl_ni_tx_hook_lock);
	synchronize_net();
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_unregister_tx_hook);

int rtl_ni_try_tx_hook(struct net_device *dev, struct sk_buff *skb,
		       const struct rtl9617c_ni_frame *frame)
{
	rtl9617c_ni_tx_hook_t fn;
	int ret = -ENOENT;

	if (frame->raw_payload)
		return -ENOENT;
	rcu_read_lock();
	fn = rcu_dereference(rtl_ni_tx_hook);
	if (unlikely(fn))
		ret = fn(dev, skb, frame->header_high, frame->header_low,
			 frame->prefix, frame->prefix_length, frame->oam);
	rcu_read_unlock();
	return ret;
}

void rtl_ni_notify_dma_reset(void)
{
	rtl9617c_ni_dma_reset_cb_t cb;

	mutex_lock(&rtl_ni_tx_hook_lock);
	cb = rcu_dereference_protected(rtl_ni_dma_reset_cb,
				       lockdep_is_held(&rtl_ni_tx_hook_lock));
	if (cb)
		cb();
	mutex_unlock(&rtl_ni_tx_hook_lock);
}

static struct rtl9617c_ni *rtl_ni_from_dev(struct device *dev)
{
	return dev_get_drvdata(dev);
}

int rtl9617c_ni_open(struct device *dev)
{
	return rtl_ni_engine_get(rtl_ni_from_dev(dev));
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_open);

void rtl9617c_ni_close(struct device *dev, struct net_device *owner)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);

	rtl_fe_flush_port(ni->fe, owner);
	rtl_ni_engine_put(ni);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_close);

netdev_tx_t rtl9617c_ni_transmit(struct device *dev, struct net_device *owner,
				 struct sk_buff *skb,
				 const struct rtl9617c_ni_frame *frame)
{
	return rtl_ni_xmit_frame(rtl_ni_from_dev(dev), owner, skb, frame);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_transmit);

int rtl9617c_ni_pon_attach(struct device *dev,
			   struct rtl9617c_ni_endpoint *endpoint)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);

	mutex_lock(&ni->lock);
	rcu_assign_pointer(ni->pon, endpoint);
	mutex_unlock(&ni->lock);
	return 0;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_pon_attach);

void rtl9617c_ni_pon_detach(struct device *dev)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);

	mutex_lock(&ni->lock);
	RCU_INIT_POINTER(ni->pon, NULL);
	mutex_unlock(&ni->lock);
	synchronize_net();
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_pon_detach);

void rtl_ni_notify_pon_features(struct rtl9617c_ni *ni)
{
	struct rtl9617c_ni_endpoint *endpoint;

	if (!ni)
		return;
	ASSERT_RTNL();
	mutex_lock(&ni->lock);
	endpoint = rcu_dereference_protected(ni->pon,
					     lockdep_is_held(&ni->lock));
	if (endpoint && endpoint->update_features)
		endpoint->update_features(endpoint);
	mutex_unlock(&ni->lock);
}

u32 rtl9617c_ni_pon_gate(struct device *dev, u32 enabled)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	unsigned long flags;
	u32 saved;

	spin_lock_irqsave(&ni->tx_lock, flags);
	saved = rtl_ni_read(ni, RTL_QM_ES_CTRL1);
	rtl_ni_write(ni, RTL_QM_ES_CTRL1,
		     (saved & ~RTL_QM_ES_CTRL1_PUC_EN) |
		     FIELD_PREP(RTL_QM_ES_CTRL1_PUC_EN, enabled));
	rtl_ni_read(ni, RTL_QM_ES_CTRL1);
	spin_unlock_irqrestore(&ni->tx_lock, flags);
	return FIELD_GET(RTL_QM_ES_CTRL1_PUC_EN, saved);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_pon_gate);

int rtl9617c_ni_report_configure(struct device *dev, unsigned int low,
				 unsigned int high)
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);

	if (!ni)
		return -EPROBE_DEFER;
	rtl_ni_write(ni, RTL_TE_CB_VOQ_REPORT_THRSH,
		     FIELD_PREP(RTL_TE_CB_VOQ_REPORT_LV2, high) |
		     FIELD_PREP(RTL_TE_CB_VOQ_REPORT_LV1, low));
	return 0;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_report_configure);

u32 rtl9617c_ni_report_state(struct device *dev)
{
	return rtl_ni_read(rtl_ni_from_dev(dev), RTL_TE_CB_VOQ_REPORT_THRSH);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_report_state);

int rtl9617c_ni_oam_configure(struct device *dev)
{
	static const unsigned int index[] = {
		15,
		15 | RTL_L2FE_ARB_PDPID_MAP_MY_MAC,
		15 | RTL_L2FE_ARB_PDPID_MAP_POL,
		15 | RTL_L2FE_ARB_PDPID_MAP_POL | RTL_L2FE_ARB_PDPID_MAP_MY_MAC,
	};
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	unsigned int i;
	int ret;

	for (i = 0; i < ARRAY_SIZE(index); i++) {
		rtl_ni_write(ni, RTL_L2FE_ARB_PDPID_MAP_TBL_DATA,
			     FIELD_PREP(RTL_L2FE_ARB_PDPID_MAP_PDPID,
					NI_OAM_MAP_DEST));
		ret = rtl_ne_table_write(ni->regs,
					 RTL_L2FE_ARB_PDPID_MAP_TBL_ACCESS,
					 index[i]);
		if (ret)
			return ret;
	}
	rtl_ni_write(ni, RTL_L2TM_ES_SCH_CFG0(NI_OAM_PORT),
		     FIELD_PREP(RTL_L2TM_ES_SCH_VOQ_EN, 0xff) |
		     FIELD_PREP(RTL_L2TM_ES_SCH_SPEED, NI_OAM_ES_SPEED_10G));
	rtl_ni_rmw(ni, RTL_L2TM_ES_CTRL, BIT(NI_OAM_PORT), BIT(NI_OAM_PORT));
	return 0;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_oam_configure);

int rtl9617c_ni_mib_read(struct device *dev, unsigned int port,
			 u64 counters[RTL9617C_NI_MIB_COUNTERS])
{
	struct rtl9617c_ni *ni = rtl_ni_from_dev(dev);
	int ret;

	if (port >= RTL_NI_GE_PORTS)
		return -EINVAL;

	mutex_lock(&ni->mib_lock);
	ret = rtl_ni_mib_update(ni, port);
	if (!ret)
		memcpy(counters, ni->mib[port], sizeof(ni->mib[port]));
	mutex_unlock(&ni->mib_lock);
	return ret;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_mib_read);

int rtl9617c_ni_fe_add_port(struct device *dev, struct net_device *netdev,
			    unsigned int llid)
{
	return rtl_fe_add_port(rtl_ni_from_dev(dev)->fe, netdev, RTL_NI_PORT_PON,
			       32 + llid, llid);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_add_port);

void rtl9617c_ni_fe_remove_port(struct device *dev, struct net_device *netdev)
{
	rtl_fe_remove_port(rtl_ni_from_dev(dev)->fe, netdev);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_remove_port);

int rtl9617c_ni_ets_to_weights(const struct tc_ets_qopt_offload *qopt,
			       u8 weights[8])
{
	return rtl_ni_qos_ets_to_weights(qopt, weights);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_ets_to_weights);

int rtl9617c_ni_fe_setup_tc(struct device *dev, struct net_device *netdev,
			    enum tc_setup_type type, void *data)
{
	return rtl_fe_setup_tc(rtl_ni_from_dev(dev)->fe, netdev, type, data);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_setup_tc);

int rtl9617c_ni_fe_attach(struct device *dev)
{
	return rtl_fe_pon_attach(rtl_ni_from_dev(dev)->fe, true);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_attach);

int rtl9617c_ni_fe_detach(struct device *dev)
{
	return rtl_fe_pon_attach(rtl_ni_from_dev(dev)->fe, false);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_detach);

ssize_t rtl9617c_ni_fe_state(struct device *dev, char *buffer)
{
	return rtl_fe_state(rtl_ni_from_dev(dev)->fe, buffer);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_fe_state);

int rtl9617c_ni_itu_paths(struct device *dev, struct net_device *netdev,
			  const struct rtl_itu_paths *paths)
{
	return rtl_fe_set_itu_paths(rtl_ni_from_dev(dev)->fe, netdev, paths);
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_itu_paths);

netdev_features_t rtl9617c_ni_tx_offload_features(void)
{
	netdev_features_t features = 0;

	if (READ_ONCE(rtl_ni_tx_csum) || READ_ONCE(rtl_ni_tso))
		features |= NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM;
	if (READ_ONCE(rtl_ni_tx_sg))
		features |= NETIF_F_SG;
	if (READ_ONCE(rtl_ni_tso)) {
		features |= NETIF_F_SG | NETIF_F_TSO;
		if (READ_ONCE(rtl_ni_tso_v6))
			features |= NETIF_F_TSO6;
	}
	return features;
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_tx_offload_features);

unsigned int rtl9617c_ni_tx_gso_max(void)
{
	return rtl_ni_tx_gso_max();
}
EXPORT_SYMBOL_GPL(rtl9617c_ni_tx_gso_max);
