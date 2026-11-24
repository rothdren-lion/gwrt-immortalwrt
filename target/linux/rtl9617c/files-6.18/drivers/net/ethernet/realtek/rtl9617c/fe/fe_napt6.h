/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef RTL9617C_FE_NAPT6_H
#define RTL9617C_FE_NAPT6_H

#include <linux/mutex.h>
#include <linux/types.h>

#include "fe_hw.h"

struct rtl_fe;

/* NAPTV6 hash-action layout: ACTGRP 0x0114000a = G1|G3|G18|G20|G24,
 * 17 + 33 + 19 + 205 + 97 = 371 bits.  The table entry is 48 bytes; bits
 * 371..383 are not written by convert_act_flow_naptv6_mode().
 */
#define RTL_FE_NAPT6_ACTION_WORDS	12
#define RTL_FE_NAPT6_WORD_BYTES		4
#define RTL_FE_NAPT6_ACTION_BYTES	(RTL_FE_NAPT6_ACTION_WORDS * RTL_FE_NAPT6_WORD_BYTES)
#define RTL_FE_NAPT6_ACTION_BITS	371
#define RTL_FE_NAPT6_LAST_LEN		1024

/* One 48-byte NAPTV6 hash action.  All fields are u32 so the pack/unpack
 * helpers can use one offset table; each field is truncated to its hardware
 * width.  Field order and widths are RE-6 §3.1-§3.10.
 */
struct rtl_fe_naptv6_action {
	u32 l4_dp_vld;
	u32 l4_dp;
	u32 ip_da_l_vld;
	u32 ip_da_l_32;
	u32 mrr_vld;
	u32 mrr_en;
	u32 no_drop_vld;
	u32 no_drop;
	u32 dpid_vld;
	u32 dpid_pri;
	u32 permit;
	u32 deepq;
	u32 mcgid_ldpid;
	u32 mc;
	u32 mdata_byte_vld;
	u32 mdata_byte;
	u32 l3_if_vld;
	u32 smac_trans;
	u32 igr_l3_if_idx;
	u32 egr_l3_if_idx;
	u32 l3_if_counter_en;
	u32 ip_ttl_dec;
	u32 ip_ttl_zero_discard_en;
	u32 ip_addr_vld;
	u32 ip_type;
	u32 ip_addr;
	u32 ip_addr_napt6;
	u32 mac_da_idx_vld;
	u32 mac_da_idx;
	u32 chk_msk_ptr;
	u32 cache_ctrl;
	u32 pop_l3_vld;
	u32 pop_l3_chk_ecn_en;
	u32 pop_l3_en;
	u32 t2_ctrl_vld;
	u32 t2_ctrl;
	u32 ldpid_offset_msb;
	u32 ip_dscp_update_en;
	u32 ip_dscp;
	u32 cos_update_en;
	u32 cos;
	u32 inner_8021p_update_en;
	u32 inner_8021p;
	u32 top_8021p_update_en;
	u32 top_8021p;
	u32 inner_dei;
	u32 inner_vid;
	u32 inner_tpid_enc;
	u32 top_dei;
	u32 top_vid;
	u32 top_tpid_enc;
	u32 vlan_cnt;
	u32 vlan_vld;
	u32 pol_vld;
	u32 pol_en;
	u32 pol_id;
	u32 pol2_id_enable;
	u32 pol2_id;
	u32 pol3_id_enable;
	u32 pol3_id;
	u32 pppoe_vld;
	u32 pppoe_set;
	u32 l4_port;
	u32 ip_mtu_enc_vld;
	u32 ip_mtu_enc;
	u32 modify_vlan_only_vld;
	u32 modify_vlan_only;
	u32 six_rd_dip_remap_or_fmr_idx_vld;
	u32 six_rd_dip_remap_or_fmr_idx;
	u32 vxlan_sport_msb15;
	u32 vxlan_sport_update_en;
	u32 ip_addr_h_96_vld;
	u32 ip_addr_h_96_1;
	u32 ip_addr_h_96_2;
	u32 ip_addr_h_96_3;
};

struct rtl_fe_npt6_prefix {
	u64 prefix;
	u16 refs;
};

struct rtl_fe_napt6 {
	struct rtl_fe *fe;
	struct mutex lock;
	struct rtl_fe_npt6_prefix prefixes[RTL_FE_NPT6_PREFIX_ENTRIES];
	/* last action-raw/pack image; debugfs-only, never installed */
	u32 action_words[RTL_FE_NAPT6_ACTION_WORDS];
	struct rtl_fe_naptv6_action action;
	bool action_valid;
	char last[RTL_FE_NAPT6_LAST_LEN];
};

int rtl_fe_napt6_init(struct rtl_fe *fe);
void rtl_fe_napt6_exit(struct rtl_fe *fe);
void rtl_fe_napt6_debugfs_init(struct rtl_fe *fe);
bool rtl_fe_napt6_mode_enabled(void);

void rtl_fe_napt6_pack(u32 words[RTL_FE_NAPT6_ACTION_WORDS],
		       const struct rtl_fe_naptv6_action *action);
void rtl_fe_napt6_unpack(const u32 words[RTL_FE_NAPT6_ACTION_WORDS],
			 struct rtl_fe_naptv6_action *action);

/* NPTv6 prefix table: linear first-free allocation with software refcounts.
 * Adding an already-present prefix increments its refcount; deleting the last
 * reference writes a zero 64-bit prefix back.  The prefix length/attribute
 * semantics are not decoded, so the 64-bit value is treated as opaque.
 */
int rtl_fe_napt6_prefix_add(struct rtl_fe *fe, u64 prefix,
			    unsigned int *index);
int rtl_fe_napt6_prefix_del(struct rtl_fe *fe, unsigned int index);
int rtl_fe_napt6_prefix_get(struct rtl_fe *fe, unsigned int index,
			    u64 *prefix, unsigned int *refs);

#endif /* RTL9617C_FE_NAPT6_H */
