// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/bitrev.h>
#include <linux/crc32poly.h>
#include <linux/kernel.h>

#include "fe_priv.h"

#define FE_FDB_KEY_INIT		(BIT(9) | (255U << 11) | BIT(19) | BIT(20) | BIT(21))
#define FE_FDB_MAC_BIT		51
#define FE_CACHE_VALID		(3U << 26)
#define FE_AGE_SLOTS		32
#define FE_AGE_PER_REG		8
#define FE_AGE_BITS		4

static const struct rtl_fe_field_layout rtl_fe_action_fields[RTL_FE_ACTION_FIELDS] = {
	[RTL_FE_MRR_VLD] = { 0, 1 },
	[RTL_FE_MRR_EN] = { 1, 1 },
	[RTL_FE_NO_DROP_VLD] = { 2, 1 },
	[RTL_FE_NO_DROP] = { 3, 1 },
	[RTL_FE_DPID_VLD] = { 4, 1 },
	[RTL_FE_DPID_PRI] = { 5, 1 },
	[RTL_FE_PERMIT] = { 6, 1 },
	[RTL_FE_DEEPQ] = { 7, 1 },
	[RTL_FE_MCGID] = { 8, 10 },
	[RTL_FE_MC] = { 18, 1 },
	[RTL_FE_MDATA_BYTE_VLD] = { 19, 1 },
	[RTL_FE_MDATA_BYTE] = { 20, 8 },
	[RTL_FE_L3_IF_VLD] = { 28, 1 },
	[RTL_FE_SMAC_TRANS] = { 29, 1 },
	[RTL_FE_IGR_L3_IF_IDX] = { 30, 6 },
	[RTL_FE_EGR_L3_IF_IDX] = { 36, 6 },
	[RTL_FE_L3_IF_COUNTER_EN] = { 42, 1 },
	[RTL_FE_IP_TTL_DEC] = { 43, 1 },
	[RTL_FE_IP_TTL_ZERO_DISCARD_EN] = { 44, 1 },
	[RTL_FE_IP_ADDR_VLD] = { 45, 1 },
	[RTL_FE_IP_TYPE] = { 46, 1 },
	[RTL_FE_IP_ADDR] = { 47, 32 },
	[RTL_FE_IP_ADDR_NAPT6] = { 79, 1 },
	[RTL_FE_MAC_DA_IDX_VLD] = { 80, 1 },
	[RTL_FE_MAC_DA_IDX] = { 81, 13 },
	[RTL_FE_CHK_MSK_PTR] = { 94, 6 },
	[RTL_FE_CACHE_CTRL] = { 100, 2 },
	[RTL_FE_POP_L3_VLD] = { 102, 1 },
	[RTL_FE_POP_L3_CHK_ECN_EN] = { 103, 1 },
	[RTL_FE_POP_L3_EN] = { 104, 1 },
	[RTL_FE_T2_CTRL_VLD] = { 105, 1 },
	[RTL_FE_T2_CTRL] = { 106, 4 },
	[RTL_FE_LDPID_OFFSET_MSB] = { 110, 1 },
	[RTL_FE_IP_DSCP_UPDATE_EN] = { 111, 1 },
	[RTL_FE_IP_DSCP] = { 112, 6 },
	[RTL_FE_COS_UPDATE_EN] = { 118, 1 },
	[RTL_FE_COS] = { 119, 3 },
	[RTL_FE_INNER_8021P_UPDATE_EN] = { 122, 1 },
	[RTL_FE_INNER_8021P] = { 123, 3 },
	[RTL_FE_TOP_8021P_UPDATE_EN] = { 126, 1 },
	[RTL_FE_TOP_8021P] = { 127, 3 },
	[RTL_FE_INNER_DEI] = { 130, 1 },
	[RTL_FE_INNER_VID] = { 131, 12 },
	[RTL_FE_INNER_TPID_ENC] = { 143, 3 },
	[RTL_FE_TOP_DEI] = { 146, 1 },
	[RTL_FE_TOP_VID] = { 147, 12 },
	[RTL_FE_TOP_TPID_ENC] = { 159, 3 },
	[RTL_FE_VLAN_CNT] = { 162, 2 },
	[RTL_FE_VLAN_VLD] = { 164, 1 },
	[RTL_FE_POL_VLD] = { 165, 1 },
	[RTL_FE_POL_EN] = { 166, 1 },
	[RTL_FE_POL_ID] = { 167, 8 },
	[RTL_FE_POL2_ID_EN] = { 175, 1 },
	[RTL_FE_POL2_ID] = { 176, 6 },
	[RTL_FE_POL3_ID_EN] = { 182, 1 },
	[RTL_FE_POL3_ID] = { 183, 6 },
	[RTL_FE_PPPOE_VLD] = { 189, 1 },
	[RTL_FE_PPPOE_SET] = { 190, 1 },
	[RTL_FE_L4_PORT] = { 191, 16 },
	[RTL_FE_IP_MTU_ENC_VLD] = { 207, 1 },
	[RTL_FE_IP_MTU_ENC] = { 208, 4 },
	[RTL_FE_MODIFY_VLAN_ONLY_VLD] = { 212, 1 },
	[RTL_FE_MODIFY_VLAN_ONLY] = { 213, 1 },
	[RTL_FE_DIP_REMAP_VLD] = { 214, 1 },
	[RTL_FE_DIP_REMAP] = { 215, 2 },
	[RTL_FE_VXLAN_SPORT_MSB] = { 217, 6 },
	[RTL_FE_VXLAN_SPORT_UPDATE_EN] = { 223, 1 },
};

static const struct rtl_fe_field_layout rtl_fe_key_fields[RTL_FE_KEY_FIELDS] = {
	[RTL_FE_KEY_L4_CHKSUM_ZERO] = { 0, 1 },
	[RTL_FE_KEY_TCP_RDP_CTRL] = { 1, 9 },
	[RTL_FE_KEY_L4_DP] = { 10, 16 },
	[RTL_FE_KEY_L4_SP] = { 26, 16 },
	[RTL_FE_KEY_L3_CHKSUM_ERR] = { 42, 1 },
	[RTL_FE_KEY_IP_FRAGMENT] = { 92, 1 },
	[RTL_FE_KEY_IP_OPTIONS] = { 94, 1 },
	[RTL_FE_KEY_IP_DA] = { 123, 32 },
	[RTL_FE_KEY_IP_SA] = { 251, 32 },
	[RTL_FE_KEY_IP_PROTOCOL] = { 382, 8 },
	[RTL_FE_KEY_IP_VER] = { 398, 1 },
	[RTL_FE_KEY_IP_VLD] = { 399, 1 },
	[RTL_FE_KEY_PPP_PROTOCOL] = { 400, 4 },
	[RTL_FE_KEY_PPPOE_SESSION] = { 404, 16 },
	[RTL_FE_KEY_PPPOE_TYPE] = { 424, 2 },
	[RTL_FE_KEY_INNER_DEI] = { 426, 1 },
	[RTL_FE_KEY_INNER_PCP] = { 427, 3 },
	[RTL_FE_KEY_INNER_VID] = { 430, 12 },
	[RTL_FE_KEY_INNER_TPID_ENC] = { 442, 3 },
	[RTL_FE_KEY_TOP_DEI] = { 445, 1 },
	[RTL_FE_KEY_TOP_PCP] = { 446, 3 },
	[RTL_FE_KEY_TOP_VID] = { 449, 12 },
	[RTL_FE_KEY_TOP_TPID_ENC] = { 461, 3 },
	[RTL_FE_KEY_VLAN_CNT] = { 464, 2 },
	[RTL_FE_KEY_ETHERTYPE] = { 481, 16 },
	[RTL_FE_KEY_MDATA_BYTE] = { 614, 8 },
	[RTL_FE_KEY_POL_ID] = { 682, 9 },
	[RTL_FE_KEY_ORIG_LSPID] = { 706, 6 },
	[RTL_FE_KEY_LSPID] = { 712, 6 },
	[RTL_FE_KEY_HKEY_ID] = { 718, 6 },
	[RTL_FE_KEY_CTRL_SET_ID] = { 724, 4 },
	[RTL_FE_KEY_TABLE_ID] = { 728, 4 },
};

void rtl_fe_bits_set(u32 *words, unsigned int bit, unsigned int width, u32 val)
{
	unsigned int word = bit / 32, shift = bit % 32;
	u32 mask = width == 32 ? ~0U : BIT(width) - 1;

	val &= mask;
	words[word] = (words[word] & ~(mask << shift)) | (val << shift);
	if (shift + width > 32)
		words[word + 1] = (words[word + 1] & ~(mask >> (32 - shift))) |
				  (val >> (32 - shift));
}

void rtl_fe_action_set_mode(u32 *words, enum rtl_fe_action_field field,
			    u32 val, bool napt6)
{
	const struct rtl_fe_field_layout *f = &rtl_fe_action_fields[field];

	rtl_fe_bits_set(words, f->bit + (napt6 ? RTL_FE_ACTION_NAPT6_SHIFT : 0),
			f->width, val);
}

void rtl_fe_action_set(u32 words[RTL_FE_ACTION_WORDS],
		       enum rtl_fe_action_field field, u32 val)
{
	rtl_fe_action_set_mode(words, field, val, false);
}

static void rtl_fe_action_pack(u32 *words, unsigned int word_count,
			       const struct rtl_fe_action *action, bool napt6)
{
	bool l3 = !action->bridge;
	unsigned int i;

	memset(words, 0, word_count * sizeof(*words));
	rtl_fe_action_set_mode(words, RTL_FE_DPID_VLD, 1, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_DPID_PRI, 1, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_PERMIT, 1, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_DEEPQ, action->deep_queue, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_MCGID, action->destination, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_L3_IF_VLD, l3, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_SMAC_TRANS, action->bridge, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_IGR_L3_IF_IDX,
			       action->ingress_interface, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_EGR_L3_IF_IDX,
			       action->egress_interface, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_IP_TTL_DEC, l3, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_IP_TTL_ZERO_DISCARD_EN, l3, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_MAC_DA_IDX_VLD, l3, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_MAC_DA_IDX, action->mac_da_index,
			       napt6);
	rtl_fe_action_set_mode(words, RTL_FE_CHK_MSK_PTR, action->check_mask,
			       napt6);
	rtl_fe_action_set_mode(words, RTL_FE_CACHE_CTRL, 1, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_COS_UPDATE_EN, 1, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_COS, action->cos, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_IP_ADDR_VLD, action->translate,
			       napt6);
	rtl_fe_action_set_mode(words, RTL_FE_IP_TYPE,
			       action->translate_destination, napt6);
	if (napt6 && action->translate && action->translate_ipv6) {
		rtl_fe_action_set_mode(words, RTL_FE_IP_ADDR,
				       action->address6[3], true);
		rtl_fe_action_set_mode(words, RTL_FE_IP_ADDR_NAPT6, 1, true);
		rtl_fe_bits_set(words, RTL_FE_IP_ADDR_H_96_VLD_BIT, 1, 1);
		rtl_fe_bits_set(words, RTL_FE_IP_ADDR_H_96_1_BIT,
				RTL_FE_IP_ADDR_H_96_WIDTH, action->address6[2]);
		rtl_fe_bits_set(words, RTL_FE_IP_ADDR_H_96_2_BIT,
				RTL_FE_IP_ADDR_H_96_WIDTH, action->address6[1]);
		rtl_fe_bits_set(words, RTL_FE_IP_ADDR_H_96_3_BIT,
				RTL_FE_IP_ADDR_H_96_WIDTH, action->address6[0]);
	} else {
		rtl_fe_action_set_mode(words, RTL_FE_IP_ADDR, action->address,
				       napt6);
	}
	rtl_fe_action_set_mode(words, RTL_FE_L4_PORT, action->port, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_PPPOE_SET, action->pppoe_pop,
			       napt6);
	rtl_fe_action_set_mode(words, RTL_FE_PPPOE_VLD, 0, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_IP_MTU_ENC_VLD, action->mtu_set,
			       napt6);
	rtl_fe_action_set_mode(words, RTL_FE_IP_MTU_ENC, action->mtu_index,
			       napt6);

	if (action->gem_set) {
		rtl_fe_action_set_mode(words, RTL_FE_MCGID, action->gem_index,
				       napt6);
		rtl_fe_action_set_mode(words, RTL_FE_MC, 1, napt6);
		rtl_fe_action_set_mode(words, RTL_FE_DEEPQ, 1, napt6);
		rtl_fe_action_set_mode(words, RTL_FE_POP_L3_VLD, 1, napt6);
		rtl_fe_action_set_mode(words, RTL_FE_T2_CTRL,
				       action->destination & 15, napt6);
		rtl_fe_action_set_mode(words, RTL_FE_LDPID_OFFSET_MSB,
				       (action->destination >> 4) & 1, napt6);
	}

	if (action->dscp_set) {
		rtl_fe_action_set_mode(words, RTL_FE_IP_DSCP_UPDATE_EN, 1,
				       napt6);
		rtl_fe_action_set_mode(words, RTL_FE_IP_DSCP, action->dscp,
				       napt6);
	}

	/*
	 * MRR_VLD/MRR_EN only mark the entry as mirror-eligible; the mirror
	 * destination and the copy length live in the global L3PE mirror
	 * registers programmed by rtl_fe_mirror_apply().
	 */
	if (action->mirror) {
		rtl_fe_action_set_mode(words, RTL_FE_MRR_VLD, 1, napt6);
		rtl_fe_action_set_mode(words, RTL_FE_MRR_EN, 1, napt6);
	}

	if (!action->vlan_set)
		return;

	rtl_fe_action_set_mode(words, RTL_FE_VLAN_VLD, 1, napt6);
	rtl_fe_action_set_mode(words, RTL_FE_VLAN_CNT, action->vlan_count,
			       napt6);
	for (i = 0; i < action->vlan_count; i++) {
		const struct rtl_fe_vlan *vlan = &action->vlan[i];

		rtl_fe_action_set_mode(words,
				       i ? RTL_FE_INNER_VID : RTL_FE_TOP_VID,
				       vlan->vid, napt6);
		rtl_fe_action_set_mode(words, i ? RTL_FE_INNER_TPID_ENC :
				       RTL_FE_TOP_TPID_ENC, vlan->tpid, napt6);
		rtl_fe_action_set_mode(words, i ? RTL_FE_INNER_8021P :
				       RTL_FE_TOP_8021P, vlan->priority, napt6);
		rtl_fe_action_set_mode(words, i ? RTL_FE_INNER_8021P_UPDATE_EN :
				       RTL_FE_TOP_8021P_UPDATE_EN, 1, napt6);
		rtl_fe_action_set_mode(words,
				       i ? RTL_FE_INNER_DEI : RTL_FE_TOP_DEI,
				       vlan->dei, napt6);
	}
}

void rtl_fe_action_build_mode(u32 words[RTL_FE_ACTION_MAX_WORDS],
			      const struct rtl_fe_action *action, bool napt6)
{
	rtl_fe_action_pack(words, RTL_FE_ACTION_MAX_WORDS, action, napt6);
}

void rtl_fe_action_build(u32 words[RTL_FE_ACTION_WORDS],
			 const struct rtl_fe_action *action)
{
	rtl_fe_action_pack(words, RTL_FE_ACTION_WORDS, action, false);
}

/* Program the global L3PE flow-mirror register pair.
 *
 * The OEM setter keeps the three bit fields in one word and the copy length
 * in a second one (see fe_hw.h).  Both are always written together so that a
 * disabled mirror leaves no stale destination or length behind; the field
 * meanings are still the open question recorded in fe_hw.h, so the caller
 * passes them verbatim.
 */
void rtl_fe_mirror_apply(struct rtl_fe *fe, bool enable,
			 unsigned int arg0, unsigned int arg1,
			 unsigned int arg2, unsigned int len)
{
	u32 ctrl = 0;

	if (enable)
		ctrl = ((arg0 & RTL_FE_MIRROR_ARG0_MAX) <<
			RTL_FE_MIRROR_ARG0_SHIFT) |
		       ((arg1 & RTL_FE_MIRROR_ARG1_MAX) <<
			RTL_FE_MIRROR_ARG1_SHIFT) |
		       ((arg2 & RTL_FE_MIRROR_ARG2_MAX) <<
			RTL_FE_MIRROR_ARG2_SHIFT);

	rtl_fe_write(fe, RTL_FE_MIRROR_LEN,
		     enable ? len & RTL_FE_MIRROR_LEN_MAX : 0);
	rtl_fe_write(fe, RTL_FE_MIRROR_CTRL, ctrl);
}

void rtl_fe_key_set(u32 words[RTL_FE_KEY_WORDS], enum rtl_fe_key_field field,
		    u32 val)
{
	const struct rtl_fe_field_layout *f = &rtl_fe_key_fields[field];

	rtl_fe_bits_set(words, f->bit, f->width, val);
}

void rtl_fe_key_vlan(u32 words[RTL_FE_KEY_WORDS],
		     const struct rtl_fe_vlan vlan[2], unsigned int count)
{
	unsigned int i;

	rtl_fe_key_set(words, RTL_FE_KEY_VLAN_CNT, count);
	for (i = 0; i < count; i++) {
		rtl_fe_key_set(words, i ? RTL_FE_KEY_INNER_VID : RTL_FE_KEY_TOP_VID,
			       vlan[i].vid);
		rtl_fe_key_set(words, i ? RTL_FE_KEY_INNER_TPID_ENC :
			       RTL_FE_KEY_TOP_TPID_ENC, vlan[i].tpid);
	}
}

static void rtl_fe_key_common(u32 words[RTL_FE_KEY_WORDS],
			      const struct rtl_fe_key *key)
{
	rtl_fe_key_set(words, RTL_FE_KEY_POL_ID, key->llid);
	rtl_fe_key_set(words, RTL_FE_KEY_LSPID, key->ingress);
	rtl_fe_key_set(words, RTL_FE_KEY_HKEY_ID, key->mask);
	rtl_fe_key_set(words, RTL_FE_KEY_TABLE_ID, 1);
}

void rtl_fe_key_ip(u32 words[RTL_FE_KEY_WORDS], const struct rtl_fe_key *key,
		   bool ipv6)
{
	const struct rtl_fe_field_layout *da = &rtl_fe_key_fields[RTL_FE_KEY_IP_DA];
	const struct rtl_fe_field_layout *sa = &rtl_fe_key_fields[RTL_FE_KEY_IP_SA];
	unsigned int i;

	memset(words, 0, RTL_FE_KEY_WORDS * sizeof(*words));
	rtl_fe_key_set(words, RTL_FE_KEY_L4_SP, key->source_port);
	rtl_fe_key_set(words, RTL_FE_KEY_L4_DP, key->destination_port);
	rtl_fe_key_set(words, RTL_FE_KEY_IP_SA, key->source[3]);
	rtl_fe_key_set(words, RTL_FE_KEY_IP_DA, key->destination[3]);
	rtl_fe_key_set(words, RTL_FE_KEY_IP_PROTOCOL, key->protocol);
	rtl_fe_key_set(words, RTL_FE_KEY_IP_VLD, 1);
	rtl_fe_key_set(words, RTL_FE_KEY_ORIG_LSPID, key->ingress);
	rtl_fe_key_set(words, RTL_FE_KEY_CTRL_SET_ID, key->profile);
	rtl_fe_key_common(words, key);

	if (!ipv6)
		return;

	rtl_fe_key_set(words, RTL_FE_KEY_IP_VER, 1);
	for (i = 1; i < 4; i++) {
		rtl_fe_bits_set(words, da->bit + i * RTL_FE_KEY_IP_WORD_BITS,
				RTL_FE_KEY_IP_WORD_BITS, key->destination[3 - i]);
		rtl_fe_bits_set(words, sa->bit + i * RTL_FE_KEY_IP_WORD_BITS,
				RTL_FE_KEY_IP_WORD_BITS, key->source[3 - i]);
	}
}

void rtl_fe_key_bridge(u32 words[RTL_FE_KEY_WORDS], const u8 *source,
		       const u8 *destination, u16 protocol,
		       const struct rtl_fe_key *key)
{
	unsigned int i;

	memset(words, 0, RTL_FE_KEY_WORDS * sizeof(*words));
	for (i = 0; i < ETH_ALEN; i++) {
		rtl_fe_bits_set(words, RTL_FE_KEY_MAC_SA_BIT + (ETH_ALEN - 1 - i) * 8,
				8, source[i]);
		rtl_fe_bits_set(words, RTL_FE_KEY_MAC_DA_BIT + (ETH_ALEN - 1 - i) * 8,
				8, destination[i]);
	}
	rtl_fe_key_set(words, RTL_FE_KEY_ETHERTYPE, protocol);
	rtl_fe_key_common(words, key);
}

void rtl_fe_key_crc(const u32 words[RTL_FE_KEY_WORDS], u32 *crc32, u16 *crc16)
{
	u32 c32 = ~0U, c16 = 0xffff;
	unsigned int byte, bit;

	for (byte = RTL_FE_KEY_WORDS * 4; byte; byte--) {
		unsigned int index = byte - 1;
		u8 val = bitrev8((words[index / 4] >> ((index % 4) * 8)) & 0xff);

		c32 ^= val;
		c16 ^= val;
		for (bit = 0; bit < 8; bit++) {
			c32 = (c32 >> 1) ^ ((c32 & 1) ? CRC32_POLY_LE : 0);
			c16 = (c16 >> 1) ^ ((c16 & 1) ? 0x8408 : 0);
		}
	}
	*crc32 = bitrev32(c32);
	*crc16 = bitrev16(c16);
}

void rtl_fe_mask_l3(u32 words[RTL_FE_MASK_WORDS])
{
	unsigned int i;

	for (i = 0; i < 7; i++)
		words[i] = ~0U;
	words[7] = 0;

	words[0] &= ~(GENMASK(26, 10) | GENMASK(31, 27));
	words[1] &= ~(GENMASK(24, 23) | GENMASK(11, 0) | BIT(12) | BIT(20) |
		      BIT(22));
	words[2] = (words[2] & ~GENMASK(11, 3)) | BIT(8);
	words[1] = (words[1] & ~GENMASK(31, 26)) | BIT(31);
	words[2] &= ~(GENMASK(2, 0) | BIT(13) | BIT(23) | BIT(22));
	words[6] &= ~(BIT(23) | BIT(24) | BIT(9) | BIT(26));
	rtl_fe_bits_set(words, 217, 1, 0);

	rtl_fe_bits_set(words, 58, 9, 128);
	rtl_fe_bits_set(words, 67, 9, 128);
}

void rtl_fe_mask_bridge(u32 words[RTL_FE_MASK_WORDS])
{
	static const struct rtl_fe_field_layout clear[] = {
		{ 55, 2 }, { 58, 9 }, { 67, 9 }, { 89, 1 }, { 91, 1 }, { 94, 2 },
		{ 98, 3 }, { 109, 7 }, { 120, 6 }, { 201, 1 }, { 216, 1 },
		{ 217, 1 },
	};
	unsigned int i;

	for (i = 0; i < 7; i++)
		words[i] = ~0U;
	words[7] = 0;
	for (i = 0; i < ARRAY_SIZE(clear); i++)
		rtl_fe_bits_set(words, clear[i].bit, clear[i].width, 0);
}

unsigned int rtl_fe_hash_bucket(u16 crc16)
{
	return crc16 & 0xffe0;
}

void rtl_fe_cpu_miss(u32 words[4])
{
	memset(words, 0, 4 * sizeof(*words));
	rtl_fe_bits_set(words, 54, 1, 1);
	rtl_fe_bits_set(words, 55, 1, 1);
}

void rtl_fe_classify_hash(u32 words[RTL_FE_CLASSIFIER_WORDS],
			  unsigned int profile, unsigned int source)
{
	memset(words, 0, RTL_FE_CLASSIFIER_WORDS * sizeof(*words));
	rtl_fe_bits_set(words, 203, 1, 1);
	rtl_fe_bits_set(words, 204, 4, profile);
	rtl_fe_bits_set(words, 186, 1, 1);
	rtl_fe_bits_set(words, 187, 1, 0);
	rtl_fe_bits_set(words, 154, 1, 1);
	rtl_fe_bits_set(words, 155, 1, 1);
	rtl_fe_bits_set(words, 156, 1, 1);
	rtl_fe_bits_set(words, 158, 10, 16);
	rtl_fe_bits_set(words, 208, 1, 1);
	rtl_fe_bits_set(words, 209, 6, source);
}

void rtl_fe_ingress_lpb(u32 words[RTL_FE_LPB_WORDS], unsigned int source,
			unsigned int destination)
{
	memset(words, 0, RTL_FE_LPB_WORDS * sizeof(*words));
	rtl_fe_bits_set(words, 24, 14, 1700);
	rtl_fe_bits_set(words, 38, 4, 15);
	rtl_fe_bits_set(words, 42, 4, 0);
	rtl_fe_bits_set(words, 68, 6, destination);
	rtl_fe_bits_set(words, 88, 6, source);
}

void rtl_fe_fdb_key(u32 words[RTL_FE_FDB_WORDS], const u8 *mac)
{
	unsigned int i;

	memset(words, 0, RTL_FE_FDB_WORDS * sizeof(*words));
	for (i = 0; i < ETH_ALEN; i++)
		rtl_fe_bits_set(words, FE_FDB_MAC_BIT + (ETH_ALEN - 1 - i) * 8, 8,
				mac[i]);
	words[0] = FE_FDB_KEY_INIT;
}

int rtl_fe_indirect(struct rtl_fe *fe, unsigned int reg, u32 cmd)
{
	u32 busy = (reg == RTL_FE_CACHE_CMD || reg == RTL_FE_SYNC_CMD) ?
		   RTL_NI_INDIRECT_BUSY_LOW : RTL_NI_INDIRECT_BUSY;

	return rtl_ne_indirect(fe->regs, reg, cmd, busy);
}

static int rtl_fe_table_read(struct rtl_fe *fe, unsigned int cmd_reg, u32 cmd,
			     unsigned int data_reg, u32 *words, unsigned int count)
{
	unsigned int i;
	int ret;

	ret = rtl_fe_indirect(fe, cmd_reg, RTL_NI_INDIRECT_ACCESS | cmd);
	if (ret)
		return ret;
	for (i = 0; i < count; i++)
		words[i] = rtl_fe_read(fe, data_reg - i * 4);
	return 0;
}

static int rtl_fe_table_write(struct rtl_fe *fe, unsigned int cmd_reg, u32 cmd,
			      unsigned int data_reg, const u32 *words,
			      unsigned int count)
{
	unsigned int i;

	for (i = 0; i < count; i++)
		rtl_fe_write(fe, data_reg - i * 4, words[i]);
	return rtl_fe_indirect(fe, cmd_reg, RTL_NI_INDIRECT_ACCESS |
			       RTL_NI_INDIRECT_WRITE | cmd);
}

int rtl_fe_mask_write(struct rtl_fe *fe, unsigned int index,
		      const u32 words[RTL_FE_MASK_WORDS])
{
	unsigned int bank;
	int ret;

	for (bank = 0; bank < 2; bank++) {
		ret = rtl_fe_table_write(fe, RTL_FE_MASK_CMD, (bank << 6) | index,
					 RTL_FE_MASK_DATA, words + bank * 4, 4);
		if (ret)
			return ret;
	}
	return 0;
}

int rtl_fe_mask_read(struct rtl_fe *fe, unsigned int index,
		     u32 words[RTL_FE_MASK_WORDS])
{
	unsigned int bank;
	int ret;

	for (bank = 0; bank < 2; bank++) {
		ret = rtl_fe_table_read(fe, RTL_FE_MASK_CMD, (bank << 6) | index,
					RTL_FE_MASK_DATA, words + bank * 4, 4);
		if (ret)
			return ret;
	}
	return 0;
}

void rtl_fe_dma_tables(struct rtl_fe *fe, u32 address, u32 address_high)
{
	rtl_fe_write(fe, RTL_FE_HASH_ENABLE, 0);
	rtl_fe_write(fe, RTL_FE_HASH_BASE_HIGH, address_high);
	rtl_fe_write(fe, RTL_FE_HASH_BASE_LOW, address);
	rtl_fe_write(fe, RTL_FE_ACTION_BASE_HIGH, address_high);
	rtl_fe_write(fe, RTL_FE_ACTION_BASE_LOW, address + RTL_FE_ACTION_OFFSET);
	rtl_fe_write(fe, RTL_FE_OVERFLOW_BASE_HIGH, address_high);
	rtl_fe_write(fe, RTL_FE_OVERFLOW_BASE_LOW, address + RTL_FE_OVERFLOW_OFFSET);
	rtl_fe_write(fe, RTL_FE_DEFAULT_BASE_HIGH, address_high);
	rtl_fe_write(fe, RTL_FE_DEFAULT_BASE_LOW, address + RTL_FE_DEFAULT_OFFSET);
	rtl_fe_rmw(fe, RTL_FE_BUCKET_CFG, 0x300ff, 3 | (7 << 2) | (4 << 5));
	rtl_fe_write(fe, RTL_FE_ACTION_SLOT_CFG, RTL_FE_ACTION_WIDTH_384);
	rtl_fe_write(fe, RTL_FE_DEFAULT_SLOT_CFG, 1);
	rtl_fe_write(fe, RTL_FE_HASH_CFG,
		     BIT(18) | BIT(16) |
		     (fe->napt6_active ? RTL_FE_HASH_CACHE_HALF : 0) |
		     ((fe->napt6_active ? RTL_FE_ACTION_WIDTH_384 :
		       RTL_FE_ACTION_WIDTH_256) << RTL_FE_CACHE_WIDTH_SHIFT) | 4);
}

void rtl_fe_cache_start(struct rtl_fe *fe)
{
	rtl_fe_rmw(fe, RTL_FE_AXI_PATCH, 0, 0x80000001);
	rtl_fe_rmw(fe, RTL_FE_AXI_ID1_LIMIT, 0, 1);
	rtl_fe_rmw(fe, RTL_FE_AXI_OUTSTANDING, 0, 255);
	rtl_fe_rmw(fe, RTL_FE_MISS_TEMPLATE, GENMASK(15, 0), 0xd0d0);
	rtl_fe_write(fe, RTL_FE_CACHE_CFG, 0);
	rtl_fe_write(fe, RTL_FE_KEY_MASK_0, ~0U);
	rtl_fe_write(fe, RTL_FE_KEY_MASK_1, ~0U);
	rtl_fe_write(fe, RTL_FE_HASH_ENABLE, 0xa0000000);
}

static unsigned int rtl_fe_age_reg(unsigned int index)
{
	return RTL_FE_AGE_DATA - ((index % FE_AGE_SLOTS) / FE_AGE_PER_REG) * 4;
}

static unsigned int rtl_fe_age_shift(unsigned int index)
{
	return (index % FE_AGE_PER_REG) * FE_AGE_BITS;
}

int rtl_fe_age_write(struct rtl_fe *fe, unsigned int index, unsigned int age)
{
	unsigned int row = index / FE_AGE_SLOTS;
	int ret;

	ret = rtl_fe_indirect(fe, RTL_FE_AGE_CMD, RTL_NI_INDIRECT_ACCESS | row);
	if (ret)
		return ret;
	rtl_fe_rmw(fe, rtl_fe_age_reg(index), GENMASK(3, 0) << rtl_fe_age_shift(index),
		   (age & GENMASK(3, 0)) << rtl_fe_age_shift(index));
	return rtl_fe_indirect(fe, RTL_FE_AGE_CMD, RTL_NI_INDIRECT_ACCESS |
			       RTL_NI_INDIRECT_WRITE | row);
}

int rtl_fe_age_read(struct rtl_fe *fe, unsigned int index, unsigned int *age)
{
	int ret;

	ret = rtl_fe_indirect(fe, RTL_FE_AGE_CMD, RTL_NI_INDIRECT_ACCESS |
			      index / FE_AGE_SLOTS);
	if (ret)
		return ret;
	*age = (rtl_fe_read(fe, rtl_fe_age_reg(index)) >> rtl_fe_age_shift(index)) &
	       GENMASK(3, 0);
	return 0;
}

int rtl_fe_cache_command(struct rtl_fe *fe, unsigned int index, u16 crc16,
			 unsigned int command)
{
	rtl_fe_write(fe, RTL_FE_CACHE_DATA, (index % FE_AGE_SLOTS) |
		     ((u32)crc16 << 5) | FE_CACHE_VALID | (command << 30));
	return rtl_fe_indirect(fe, RTL_FE_CACHE_CMD, 1);
}

int rtl_fe_cam_protocol_get(struct rtl_fe *fe, struct rtl_fe_cam_protocol *cam,
			    unsigned int bank, unsigned int protocol)
{
	unsigned int count = bank == 2 ? 63 : 15;
	unsigned int width = bank == 2 ? 5 : 3;
	unsigned int index, free = count, i;
	u32 words[RTL_FE_CAM_WORDS];
	int ret;

	cam->bank = bank;
	cam->created = false;
	for (index = 0; index < count; index++) {
		ret = rtl_fe_table_read(fe, RTL_FE_CAM_CMD, (bank << 16) | index,
					RTL_FE_CAM_DATA, words, width);
		if (ret)
			return ret;
		if (words[0] & BIT(16)) {
			if ((words[0] & 0xffff) == protocol) {
				cam->index = index;
				return index + 1;
			}
		} else if (free == count) {
			free = index;
			memcpy(cam->saved, words, width * sizeof(*words));
		}
	}
	if (free == count)
		return -ENOSPC;

	cam->index = free;
	cam->created = true;
	memset(words, 0, sizeof(words));
	words[0] = protocol | BIT(16);
	for (i = 0; i < width; i++)
		rtl_fe_write(fe, RTL_FE_CAM_DATA - i * 4, words[i]);
	ret = rtl_fe_indirect(fe, RTL_FE_CAM_CMD, RTL_NI_INDIRECT_ACCESS |
			      RTL_NI_INDIRECT_WRITE | (bank << 16) | free);
	if (ret)
		return ret;
	return free + 1;
}

int rtl_fe_cam_protocol_put(struct rtl_fe *fe, struct rtl_fe_cam_protocol *cam)
{
	int ret;

	if (!cam->created)
		return 0;
	ret = rtl_fe_table_write(fe, RTL_FE_CAM_CMD, (cam->bank << 16) | cam->index,
				 RTL_FE_CAM_DATA, cam->saved,
				 cam->bank == 2 ? 5 : 3);
	if (!ret)
		cam->created = false;
	return ret;
}

#define RTL_FE_CLS_LOW_MASK(bits)		((u32)(~0ULL >> (64 - (bits))))

#define RTL_FE_CLS_DUAL_FIB_BASE		4
#define RTL_FE_CLS_KEY_PRI_BIT			338
#define RTL_FE_CLS_KEY_PRI_WIDTH		4
#define RTL_FE_CLS_KEY_RSLT_BIT			342
#define RTL_FE_CLS_KEY_RSLT_WIDTH		2
#define RTL_FE_CLS_KEY_TYPE_BIT			344
#define RTL_FE_CLS_KEY_TYPE_WIDTH		3
#define RTL_FE_CLS_KEY_VALID_BIT		347
#define RTL_FE_CLS_KEY_VALID_WIDTH		4
#define RTL_FE_CLS_RSLT_DEFAULT			0

#define RTL_FE_CLS_MDATA_PKT_TYPE_MASK		0xefffU
#define RTL_FE_CLS_MDATA_PKT_TYPE_SHIFT		16
#define RTL_FE_CLS_MDATA_PKT_TYPE_DSLITE	0x9U
#define RTL_FE_CLS_MDATA_PKT_TYPE_6RD		0xaU

#define RTL_FE_CLS_IPV4_BITS			32
#define RTL_FE_CLS_IPV6_BITS			128

/* KEY6 (ip_v4_6rd) bit positions inside 352-bit EVEN / ODD CAM words. */
#define RTL_FE_CLS_K6_FRAG_MSK_BIT		53
#define RTL_FE_CLS_K6_FRAG_VAL_BIT		54
#define RTL_FE_CLS_K6_OPT_MSK_BIT		55
#define RTL_FE_CLS_K6_OPT_VAL_BIT		56
#define RTL_FE_CLS_K6_IP_DA_MSK_BIT		61
#define RTL_FE_CLS_K6_IP_DA_BIT			70
#define RTL_FE_CLS_K6_IP_SA_MSK_BIT		198
#define RTL_FE_CLS_K6_IP_SA_BIT			207
#define RTL_FE_CLS_K6_IP_MASK_WIDTH		9
#define RTL_FE_CLS_K6_IP_ADDR_CTRL_BIT		335
#define RTL_FE_CLS_K6_IP_ADDR_CTRL_WIDTH	2
#define RTL_FE_CLS_K6_ADDR_CTRL_DIP_SIP		0
#define RTL_FE_CLS_K6_EVEN_W1_MASK_BITS		20
#define RTL_FE_CLS_K6_EVEN_W1_HIGH_SHIFT	25
#define RTL_FE_CLS_K6_EVEN_W1_HIGH_MASK		0xfU
#define RTL_FE_CLS_K6_ODD_W8_BITS		27
#define RTL_FE_CLS_K6_ODD_MDATA_MSK_BIT		178
#define RTL_FE_CLS_K6_ODD_MDATA_BIT		226

/* KEY7 (dslite) bit positions inside 352-bit EVEN / ODD CAM words. */
#define RTL_FE_CLS_K7_FRAG_MSK_BIT		93
#define RTL_FE_CLS_K7_FRAG_VAL_BIT		94
#define RTL_FE_CLS_K7_OPT_MSK_BIT		95
#define RTL_FE_CLS_K7_OPT_VAL_BIT		96
#define RTL_FE_CLS_K7_IP_ADDR_TYPE_BIT		118
#define RTL_FE_CLS_K7_IP_ADDR_DIP		0
#define RTL_FE_CLS_K7_IP_ADDR_SIP		1
#define RTL_FE_CLS_K7_IP_ADDR_MSK_BIT		119
#define RTL_FE_CLS_K7_IP_ADDR_MSK_WIDTH		9
#define RTL_FE_CLS_K7_IP_VER_MSK_BIT		279
#define RTL_FE_CLS_K7_IP_VER_BIT		280
#define RTL_FE_CLS_K7_EVEN_W2_CLR_MASK		(0xfU << 4)
#define RTL_FE_CLS_K7_EVEN_W3_BITS		22
#define RTL_FE_CLS_K7_EVEN_W9_BITS		17
#define RTL_FE_CLS_K7_ODD_W8_BITS		21
#define RTL_FE_CLS_K7_ODD_MDATA_MSK_BIT		183
#define RTL_FE_CLS_K7_ODD_MDATA_ID1_BIT		215
#define RTL_FE_CLS_K7_ODD_MDATA_BIT		231

#define RTL_FE_CLS_FIB_IGR_IF_VLD_BIT		189
#define RTL_FE_CLS_FIB_IGR_IF_BIT		190
#define RTL_FE_CLS_FIB_IGR_IF_WIDTH		6
#define RTL_FE_CLS_FIB_LSPID_VLD_BIT		208

static u32 rtl_fe_be32_read(const u8 bytes[4])
{
	return ((u32)bytes[0] << 24) | ((u32)bytes[1] << 16) |
	       ((u32)bytes[2] << 8) | bytes[3];
}

int rtl_fe_classifier_read(struct rtl_fe *fe, unsigned int index,
			   u32 words[RTL_FE_CLASSIFIER_WORDS])
{
	return rtl_fe_table_read(fe, RTL_FE_CLASSIFIER_CMD, index,
				 RTL_FE_CLASSIFIER_DATA, words,
				 RTL_FE_CLASSIFIER_WORDS);
}

int rtl_fe_classifier_write(struct rtl_fe *fe, unsigned int index,
			    const u32 words[RTL_FE_CLASSIFIER_WORDS])
{
	return rtl_fe_table_write(fe, RTL_FE_CLASSIFIER_CMD, index,
				  RTL_FE_CLASSIFIER_DATA, words,
				  RTL_FE_CLASSIFIER_WORDS);
}

int rtl_fe_cls_key_read(struct rtl_fe *fe, unsigned int index,
			u32 words[RTL_FE_CLS_KEY_WORDS])
{
	if (index >= RTL_FE_CLS_KEY_ENTRIES)
		return -EINVAL;

	return rtl_fe_table_read(fe, RTL_FE_CLS_KEY_CMD, index,
				 RTL_FE_CLS_KEY_DATA, words,
				 RTL_FE_CLS_KEY_WORDS);
}

int rtl_fe_cls_key_write(struct rtl_fe *fe, unsigned int index,
			 const u32 words[RTL_FE_CLS_KEY_WORDS])
{
	if (index >= RTL_FE_CLS_KEY_ENTRIES)
		return -EINVAL;

	return rtl_fe_table_write(fe, RTL_FE_CLS_KEY_CMD, index,
				  RTL_FE_CLS_KEY_DATA, words,
				  RTL_FE_CLS_KEY_WORDS);
}

/*
 * KEY6 (6RD) and KEY7 (DS-Lite) occupy an even/odd key row pair and map to
 * FIB0/FIB1 at ((key_index >> 1) << 3) | 4 per ca-ne.ko __l3_cls_fib_idx_get.
 */
unsigned int rtl_fe_cls_dual_fib_index(unsigned int key_index)
{
	return ((key_index >> 1) << 3) | RTL_FE_CLS_DUAL_FIB_BASE;
}

static void rtl_fe_cls_pack_header(u32 even[RTL_FE_CLS_KEY_WORDS],
				   unsigned int key_type)
{
	rtl_fe_bits_set(even, RTL_FE_CLS_KEY_PRI_BIT,
			RTL_FE_CLS_KEY_PRI_WIDTH, RTL_FE_CLS_PRI_TUNNEL);
	rtl_fe_bits_set(even, RTL_FE_CLS_KEY_RSLT_BIT,
			RTL_FE_CLS_KEY_RSLT_WIDTH, RTL_FE_CLS_RSLT_DEFAULT);
	rtl_fe_bits_set(even, RTL_FE_CLS_KEY_TYPE_BIT,
			RTL_FE_CLS_KEY_TYPE_WIDTH, key_type);
	rtl_fe_bits_set(even, RTL_FE_CLS_KEY_VALID_BIT,
			RTL_FE_CLS_KEY_VALID_WIDTH, BIT(0));
}

void rtl_fe_cls_pack_6rd(u32 even[RTL_FE_CLS_KEY_WORDS],
			 u32 odd[RTL_FE_CLS_KEY_WORDS],
			 const u8 outer_sa[4], const u8 outer_da[4])
{
	unsigned int i;

	memset(even, 0, RTL_FE_CLS_KEY_WORDS * sizeof(*even));
	memset(odd, 0, RTL_FE_CLS_KEY_WORDS * sizeof(*odd));

	/* Initialize KEY6 wildcard masks ("don't-care" = 1) per ca-ne.ko. */
	even[0] = ~0U;
	even[1] = RTL_FE_CLS_LOW_MASK(RTL_FE_CLS_K6_EVEN_W1_MASK_BITS) |
		  (RTL_FE_CLS_K6_EVEN_W1_HIGH_MASK <<
		   RTL_FE_CLS_K6_EVEN_W1_HIGH_SHIFT);
	for (i = 0; i < 8; i++)
		odd[i] = ~0U;
	odd[8] = RTL_FE_CLS_LOW_MASK(RTL_FE_CLS_K6_ODD_W8_BITS);

	/* Require non-fragmented, non-option outer IPv4 packets. */
	rtl_fe_bits_set(even, RTL_FE_CLS_K6_FRAG_MSK_BIT, 1, 0);
	rtl_fe_bits_set(even, RTL_FE_CLS_K6_FRAG_VAL_BIT, 1, 0);
	rtl_fe_bits_set(even, RTL_FE_CLS_K6_OPT_MSK_BIT, 1, 0);
	rtl_fe_bits_set(even, RTL_FE_CLS_K6_OPT_VAL_BIT, 1, 0);

	rtl_fe_bits_set(even, RTL_FE_CLS_K6_IP_DA_MSK_BIT,
			RTL_FE_CLS_K6_IP_MASK_WIDTH, RTL_FE_CLS_IPV4_BITS);
	rtl_fe_bits_set(even, RTL_FE_CLS_K6_IP_DA_BIT, RTL_FE_CLS_IPV4_BITS,
			rtl_fe_be32_read(outer_da));
	rtl_fe_bits_set(even, RTL_FE_CLS_K6_IP_SA_MSK_BIT,
			RTL_FE_CLS_K6_IP_MASK_WIDTH, RTL_FE_CLS_IPV4_BITS);
	rtl_fe_bits_set(even, RTL_FE_CLS_K6_IP_SA_BIT, RTL_FE_CLS_IPV4_BITS,
			rtl_fe_be32_read(outer_sa));
	rtl_fe_bits_set(even, RTL_FE_CLS_K6_IP_ADDR_CTRL_BIT,
			RTL_FE_CLS_K6_IP_ADDR_CTRL_WIDTH,
			RTL_FE_CLS_K6_ADDR_CTRL_DIP_SIP);
	rtl_fe_cls_pack_header(even, RTL_FE_CLS_KEY_TYPE_6RD);

	rtl_fe_bits_set(odd, RTL_FE_CLS_K6_ODD_MDATA_MSK_BIT, 16,
			RTL_FE_CLS_MDATA_PKT_TYPE_MASK);
	rtl_fe_bits_set(odd, RTL_FE_CLS_K6_ODD_MDATA_BIT, 32,
			RTL_FE_CLS_MDATA_PKT_TYPE_6RD <<
			RTL_FE_CLS_MDATA_PKT_TYPE_SHIFT);
}

static void rtl_fe_cls_pack_key7_tunnel(u32 even[RTL_FE_CLS_KEY_WORDS],
					u32 odd[RTL_FE_CLS_KEY_WORDS],
					bool is_dip, bool is_ipv6,
					const u8 *addr, u16 mdata_mask,
					u16 id1, u16 id2, u8 pkt_type)
{
	unsigned int i;

	memset(even, 0, RTL_FE_CLS_KEY_WORDS * sizeof(*even));
	memset(odd, 0, RTL_FE_CLS_KEY_WORDS * sizeof(*odd));

	/* Initialize KEY7 wildcard masks ("don't-care" = 1) per ca-ne.ko. */
	even[0] = ~0U;
	even[1] = ~0U;
	even[2] = ~RTL_FE_CLS_K7_EVEN_W2_CLR_MASK;
	even[3] = RTL_FE_CLS_LOW_MASK(RTL_FE_CLS_K7_EVEN_W3_BITS);
	even[8] = ~0U;
	even[9] = RTL_FE_CLS_LOW_MASK(RTL_FE_CLS_K7_EVEN_W9_BITS);
	for (i = 0; i < 8; i++)
		odd[i] = ~0U;
	odd[8] = RTL_FE_CLS_LOW_MASK(RTL_FE_CLS_K7_ODD_W8_BITS);

	/* Require non-fragmented, non-option outer IP packets. */
	rtl_fe_bits_set(even, RTL_FE_CLS_K7_FRAG_MSK_BIT, 1, 0);
	rtl_fe_bits_set(even, RTL_FE_CLS_K7_FRAG_VAL_BIT, 1, 0);
	rtl_fe_bits_set(even, RTL_FE_CLS_K7_OPT_MSK_BIT, 1, 0);
	rtl_fe_bits_set(even, RTL_FE_CLS_K7_OPT_VAL_BIT, 1, 0);
	rtl_fe_bits_set(even, RTL_FE_CLS_K7_IP_ADDR_TYPE_BIT, 1,
			is_dip ? RTL_FE_CLS_K7_IP_ADDR_DIP :
				 RTL_FE_CLS_K7_IP_ADDR_SIP);
	rtl_fe_bits_set(even, RTL_FE_CLS_K7_IP_ADDR_MSK_BIT,
			RTL_FE_CLS_K7_IP_ADDR_MSK_WIDTH,
			is_ipv6 ? RTL_FE_CLS_IPV6_BITS : RTL_FE_CLS_IPV4_BITS);

	if (is_ipv6) {
		even[4] = rtl_fe_be32_read(addr + 12);
		even[5] = rtl_fe_be32_read(addr + 8);
		even[6] = rtl_fe_be32_read(addr + 4);
		even[7] = rtl_fe_be32_read(addr);
	} else {
		even[4] = rtl_fe_be32_read(addr);
		rtl_fe_bits_set(even, RTL_FE_CLS_K7_IP_VER_MSK_BIT, 1, 0);
		rtl_fe_bits_set(even, RTL_FE_CLS_K7_IP_VER_BIT, 1, 0);
	}
	rtl_fe_cls_pack_header(even, RTL_FE_CLS_KEY_TYPE_DSLITE);

	rtl_fe_bits_set(odd, RTL_FE_CLS_K7_ODD_MDATA_MSK_BIT, 16, mdata_mask);
	if ((mdata_mask & 0x00f0U) != 0x00f0U)
		rtl_fe_bits_set(odd, RTL_FE_CLS_K7_ODD_MDATA_ID1_BIT, 16, id1);
	rtl_fe_bits_set(odd, RTL_FE_CLS_K7_ODD_MDATA_BIT, 32,
			((u32)pkt_type << RTL_FE_CLS_MDATA_PKT_TYPE_SHIFT) |
			id2);
}

void rtl_fe_cls_pack_dslite(u32 even[RTL_FE_CLS_KEY_WORDS],
			    u32 odd[RTL_FE_CLS_KEY_WORDS],
			    const u8 outer_sa[16])
{
	rtl_fe_cls_pack_key7_tunnel(even, odd, false, true, outer_sa,
				    RTL_FE_CLS_MDATA_PKT_TYPE_MASK, 0, 0,
				    RTL_FE_CLS_MDATA_PKT_TYPE_DSLITE);
}

void rtl_fe_cls_pack_dual_fib(u32 fib0[RTL_FE_CLASSIFIER_WORDS],
			      u32 fib1[RTL_FE_CLASSIFIER_WORDS],
			      unsigned int igr_l3_if_idx)
{
	rtl_fe_classify_hash(fib0, 0, 0);
	/* Keep incoming lspid intact while binding the dual-header IGR EIF. */
	rtl_fe_bits_set(fib0, RTL_FE_CLS_FIB_LSPID_VLD_BIT, 1, 0);
	rtl_fe_bits_set(fib0, RTL_FE_CLS_FIB_IGR_IF_VLD_BIT, 1, 1);
	rtl_fe_bits_set(fib0, RTL_FE_CLS_FIB_IGR_IF_BIT,
			RTL_FE_CLS_FIB_IGR_IF_WIDTH, igr_l3_if_idx);
	memset(fib1, 0, RTL_FE_CLASSIFIER_WORDS * sizeof(*fib1));
}

static int rtl_fe_cls_write_pair(struct rtl_fe *fe, unsigned int key_index,
				 const u32 even[RTL_FE_CLS_KEY_WORDS],
				 const u32 odd[RTL_FE_CLS_KEY_WORDS],
				 const u32 fib0[RTL_FE_CLASSIFIER_WORDS],
				 const u32 fib1[RTL_FE_CLASSIFIER_WORDS])
{
	unsigned int fib_index;
	u32 zero_key[RTL_FE_CLS_KEY_WORDS] = { 0 };
	int ret;

	if ((key_index & 1U) || key_index + 1 >= RTL_FE_CLS_KEY_ENTRIES)
		return -EINVAL;

	fib_index = rtl_fe_cls_dual_fib_index(key_index);

	/* Write FIB rows before arming key_valid so traffic never sees stale FIB0. */
	ret = rtl_fe_classifier_write(fe, fib_index, fib0);
	if (ret)
		return ret;
	ret = rtl_fe_classifier_write(fe, fib_index + 1, fib1);
	if (ret)
		return ret;
	ret = rtl_fe_cls_key_write(fe, key_index + 1, odd);
	if (ret)
		return ret;
	ret = rtl_fe_cls_key_write(fe, key_index, even);
	if (ret) {
		rtl_fe_cls_key_write(fe, key_index + 1, zero_key);
		return ret;
	}
	return 0;
}

int rtl_fe_cls_write_6rd(struct rtl_fe *fe, unsigned int key_index,
			 const u8 outer_sa[4], const u8 outer_da[4],
			 unsigned int igr_l3_if_idx)
{
	u32 even[RTL_FE_CLS_KEY_WORDS];
	u32 odd[RTL_FE_CLS_KEY_WORDS];
	u32 fib0[RTL_FE_CLASSIFIER_WORDS];
	u32 fib1[RTL_FE_CLASSIFIER_WORDS];

	rtl_fe_cls_pack_6rd(even, odd, outer_sa, outer_da);
	rtl_fe_cls_pack_dual_fib(fib0, fib1, igr_l3_if_idx);
	return rtl_fe_cls_write_pair(fe, key_index, even, odd, fib0, fib1);
}

static int rtl_fe_cls_write_key7_tunnel(struct rtl_fe *fe,
					unsigned int key_index,
					bool is_dip, bool is_ipv6,
					const u8 *addr, u16 mdata_mask,
					u16 id1, u16 id2, u8 pkt_type,
					unsigned int igr_l3_if_idx)
{
	u32 even[RTL_FE_CLS_KEY_WORDS];
	u32 odd[RTL_FE_CLS_KEY_WORDS];
	u32 fib0[RTL_FE_CLASSIFIER_WORDS];
	u32 fib1[RTL_FE_CLASSIFIER_WORDS];

	rtl_fe_cls_pack_key7_tunnel(even, odd, is_dip, is_ipv6, addr,
				    mdata_mask, id1, id2, pkt_type);
	rtl_fe_cls_pack_dual_fib(fib0, fib1, igr_l3_if_idx);
	return rtl_fe_cls_write_pair(fe, key_index, even, odd, fib0, fib1);
}

int rtl_fe_cls_write_dslite(struct rtl_fe *fe, unsigned int key_index,
			    const u8 outer_sa[16], unsigned int igr_l3_if_idx)
{
	return rtl_fe_cls_write_key7_tunnel(fe, key_index, false, true,
					    outer_sa,
					    RTL_FE_CLS_MDATA_PKT_TYPE_MASK,
					    0, 0,
					    RTL_FE_CLS_MDATA_PKT_TYPE_DSLITE,
					    igr_l3_if_idx);
}

int rtl_fe_cls_write_l2tp(struct rtl_fe *fe, unsigned int key_index,
			  bool is_ipv6, const u8 outer_da[16],
			  u16 tid, u16 sid, unsigned int igr_l3_if_idx)
{
	return rtl_fe_cls_write_key7_tunnel(fe, key_index, true, is_ipv6,
					    outer_da,
					    RTL_FE_CLS_MDATA_L2TP_MASK,
					    tid, sid,
					    RTL_FE_CLS_MDATA_PKT_TYPE_L2TP,
					    igr_l3_if_idx);
}

int rtl_fe_cls_write_pptp(struct rtl_fe *fe, unsigned int key_index,
			  bool is_ipv6, const u8 outer_da[16],
			  u16 call_id, unsigned int igr_l3_if_idx)
{
	return rtl_fe_cls_write_key7_tunnel(fe, key_index, true, is_ipv6,
					    outer_da,
					    RTL_FE_CLS_MDATA_PPTP_MASK,
					    call_id, 0,
					    RTL_FE_CLS_MDATA_PKT_TYPE_PPTP,
					    igr_l3_if_idx);
}

int rtl_fe_cls_clear_pair(struct rtl_fe *fe, unsigned int key_index)
{
	u32 zero_key[RTL_FE_CLS_KEY_WORDS] = { 0 };
	u32 zero_fib[RTL_FE_CLASSIFIER_WORDS] = { 0 };
	unsigned int fib_index;
	int ret;

	if ((key_index & 1U) || key_index + 1 >= RTL_FE_CLS_KEY_ENTRIES)
		return -EINVAL;

	/* Disarm the active EVEN CAM word first before zeroing ODD and FIB rows. */
	ret = rtl_fe_cls_key_write(fe, key_index, zero_key);
	if (ret)
		return ret;
	ret = rtl_fe_cls_key_write(fe, key_index + 1, zero_key);
	if (ret)
		return ret;

	fib_index = rtl_fe_cls_dual_fib_index(key_index);
	ret = rtl_fe_classifier_write(fe, fib_index, zero_fib);
	if (ret)
		return ret;
	return rtl_fe_classifier_write(fe, fib_index + 1, zero_fib);
}

int rtl_fe_smac_read(struct rtl_fe *fe, unsigned int index,
		     u32 words[RTL_FE_SMAC_WORDS])
{
	return rtl_fe_table_read(fe, RTL_FE_CAM_CMD, (3 << 16) | index,
				 RTL_FE_CAM_DATA, words, RTL_FE_SMAC_WORDS);
}

int rtl_fe_smac_write(struct rtl_fe *fe, unsigned int index,
		      const u32 words[RTL_FE_SMAC_WORDS])
{
	return rtl_fe_table_write(fe, RTL_FE_CAM_CMD, (3 << 16) | index,
				  RTL_FE_CAM_DATA, words, RTL_FE_SMAC_WORDS);
}

int rtl_fe_counter_read(struct rtl_fe *fe, unsigned int index,
			u32 words[RTL_FE_COUNTER_WORDS])
{
	return rtl_fe_table_read(fe, RTL_FE_COUNTER_CMD, index,
				 RTL_FE_COUNTER_DATA, words, RTL_FE_COUNTER_WORDS);
}

int rtl_fe_fdb_command(struct rtl_fe *fe, unsigned int command,
		       u32 words[RTL_FE_FDB_WORDS], u32 *result)
{
	u32 control = rtl_fe_read(fe, RTL_L2FE_L2E_CTRL);
	unsigned int i;
	int ret;

	rtl_fe_write(fe, RTL_L2FE_L2E_CTRL, control | BIT(31));
	for (i = 0; i < RTL_FE_FDB_WORDS; i++)
		rtl_fe_write(fe, RTL_L2FE_L2E_FDB_DATA0 - i * 4, words[i]);
	rtl_fe_write(fe, RTL_L2FE_L2E_FDB_CMD_RET, 0);
	ret = rtl_fe_indirect(fe, RTL_L2FE_L2E_FDB_ACCESS,
			      RTL_NI_INDIRECT_ACCESS | command);
	rtl_fe_write(fe, RTL_L2FE_L2E_CTRL, control);
	if (ret)
		return ret;

	*result = rtl_fe_read(fe, RTL_L2FE_L2E_FDB_CMD_RET);
	for (i = 0; i < RTL_FE_FDB_WORDS; i++)
		words[i] = rtl_fe_read(fe, RTL_L2FE_L2E_FDB_DATA0 - i * 4);
	return 0;
}
