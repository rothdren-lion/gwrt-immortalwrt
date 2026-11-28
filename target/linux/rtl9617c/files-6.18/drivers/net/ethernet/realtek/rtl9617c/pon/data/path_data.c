// SPDX-License-Identifier: GPL-2.0-or-later

/* ITU business data path: frame tagging, transmit/receive and teardown. */

#include <linux/delay.h>
#include <linux/etherdevice.h>
#include <linux/if_vlan.h>
#include <linux/io.h>
#include <linux/rcupdate.h>
#include <linux/slab.h>
#include <linux/unaligned.h>
#include <linux/soc/realtek/rtl9617c-bridge.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "pon/data/vlan.h"

static bool rtl_pon_itu_service_entry(struct net_device *dev, const struct rtl_evto_packet *packet)
{
	if (!packet->count || netif_is_bridge_port(dev)) return false;
	for (unsigned int i = 0; i < packet->count; i++) {
		dev = __vlan_find_dev_deep_rcu(dev, htons(packet->tag[i].tpid), packet->tag[i].tci & 4095);
		/* A VLAN bridge member still selects an explicit local service. */
		if (!dev) return false;
	}
	return true;
}

netdev_tx_t rtl_pon_itu_data_transmit(struct rtl9617c_pon *pon, struct sk_buff *skb, struct net_device *dev)
{
	struct rtl_itu_path_state *state;
	const struct rtl_itu_path *path;
	struct rtl9617c_ni_frame frame = {.header_high = BIT(30), .header_low = (16 << 9) | BIT(29)};
	struct rtl_evto_packet input, output;
	struct sk_buff *wire = skb;
	unsigned int wire_tags;
	netdev_tx_t ret;
	bool found = false;

	if (!netif_carrier_ok(dev)) goto drop;
	rcu_read_lock();
	state = rcu_dereference(pon->itu_paths);
	if (!state || !READ_ONCE(pon->itu_paths_ready) || rtl_evto_skb_read(&state->paths, skb, &input, &wire_tags))
		goto unlock;
	input.service_entry = rtl_pon_itu_service_entry(dev, &input);
	path = rtl_itu_path_transmit_vlan(&state->paths, &input, &output);
	if (!path) goto unlock;
	/* DMA BUSY leaves the original packet queued for a fresh GEM lookup. */
	if (skb_vlan_tag_present(skb) || input.count != output.count ||
	    skb->priority != output.priority ||
	    memcmp(input.tag, output.tag, input.count * sizeof(input.tag[0]))) {
		wire = skb_clone(skb, GFP_ATOMIC);
		if (!wire) goto unlock;
	}
	/* Normal frames are bounded at 2000 B; GSO frames segment in DMA LSO. */
	if (!rtl_evto_skb_write(wire, &input, &output, wire_tags) &&
	    wire->len <= (skb_is_gso(wire) ? rtl9617c_ni_tx_gso_max() : 2000U)) {
		frame.header_high |= (u32)path->index << 18;
		frame.header_low |= path->queue | ((32 + path->tcont) << 3);
		found = true;
	}
unlock:
	rcu_read_unlock();
	if (!found) {
		if (wire && wire != skb) dev_kfree_skb_any(wire);
		goto drop;
	}
	ret = rtl9617c_ni_transmit(pon->ni_dev, dev, wire, &frame);
	if (wire != skb) {
		if (ret == NETDEV_TX_BUSY) dev_kfree_skb_any(wire);
		else dev_consume_skb_any(skb);
	}
	return ret;
drop:
	dev->stats.tx_dropped++;
	dev_kfree_skb_any(skb);
	return NETDEV_TX_OK;
}

void rtl_pon_itu_data_receive(struct rtl9617c_pon *pon, struct napi_struct *napi,
	struct sk_buff *skb, unsigned int source)
{
	struct net_device *dev = rcu_dereference(pon->data_devices[0]);
	struct rtl_itu_path_state *state = rcu_dereference(pon->itu_paths);
	const struct rtl_itu_path *path;
	unsigned int index = source >> 8, wire_tags;
	struct rtl_evto_packet input, output;

	if ((source & 255) != 7 || !state || !READ_ONCE(pon->itu_paths_ready) ||
	    !netif_running(dev) || !netif_carrier_ok(dev) || skb->len < ETH_HLEN) goto drop;
	if (rtl_evto_skb_read(&state->paths, skb, &input, &wire_tags)) goto drop;
	input.service_entry = 1;
	path = rtl_itu_path_receive_vlan(&state->paths, index, &input, &output);
	if (!path || !rtl_pon_itu_service_entry(dev, &output)) {
		input.service_entry = 0;
		path = rtl_itu_path_receive_vlan(&state->paths, index, &input, &output);
	}
	if (!path || rtl_evto_skb_write(skb, &input, &output, wire_tags)) goto drop;
	{
		struct rtl9617c_bridge_frame *wire = skb_ext_add(skb, SKB_EXT_RTL9617C_BRIDGE);
		if (wire) {
			memset(wire, 0, sizeof(*wire));
			wire->pon_gem = index; wire->pon_generation = state->paths.generation;
			wire->tags = input.count;
			for (unsigned int i = 0; i < input.count && i < 2; i++)
				wire->tag[i] = (struct rtl9617c_bridge_tag){input.tag[i].tci, input.tag[i].tpid};
		}
	}
	dev->stats.rx_packets++;
	dev->stats.rx_bytes += skb->len;
	skb->protocol = eth_type_trans(skb, dev);
	napi_gro_receive(napi, skb);
	return;
drop:
	if (dev) dev->stats.rx_dropped++;
	dev_kfree_skb_any(skb);
}

void rtl_pon_itu_paths_remove(struct rtl9617c_pon *pon)
{
	struct rtl_itu_path_state *state = rcu_access_pointer(pon->itu_paths);

	RCU_INIT_POINTER(pon->itu_paths, NULL);
	if (state) kvfree_rcu(state, rcu);
	kvfree(pon->itu_upload);
}
