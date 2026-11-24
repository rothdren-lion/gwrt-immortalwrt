/* SPDX-License-Identifier: GPL-2.0-or-later */

/* EVTO VLAN tag rewrite helpers used by the ITU data path. */

#ifndef RTL9617C_PON_DATA_VLAN_H
#define RTL9617C_PON_DATA_VLAN_H
#include <linux/skbuff.h>
#include "rtl9617c_itu.h"

int rtl_evto_skb_read(const struct rtl_itu_paths *paths, struct sk_buff *skb,

		      struct rtl_evto_packet *packet, unsigned int *wire_tags);

int rtl_evto_skb_write(struct sk_buff *skb, const struct rtl_evto_packet *before,

		       const struct rtl_evto_packet *after, unsigned int wire_tags);

#endif
