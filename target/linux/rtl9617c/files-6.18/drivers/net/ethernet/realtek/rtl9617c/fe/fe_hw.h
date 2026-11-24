/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef RTL9617C_FE_HW_H
#define RTL9617C_FE_HW_H

#include <linux/types.h>

#define RTL_FE_ACTION_WORDS		8
#define RTL_FE_ACTION_MAX_WORDS		12
#define RTL_FE_KEY_WORDS		23
#define RTL_FE_MASK_WORDS		8
#define RTL_FE_CLASSIFIER_WORDS		7
#define RTL_FE_LPB_WORDS		3
#define RTL_FE_CLS_KEY_WORDS		11
#define RTL_FE_CLS_KEY_ENTRIES		256
#define RTL_FE_CLS_KEY_PROFILE_ENTRIES	128
#define RTL_FE_CLS_KEY_CMD		0x3380
#define RTL_FE_CLS_KEY_DATA		0x33ac
#define RTL_FE_L3PP_L2TP_SPORT		0x3330
#define RTL_FE_PP_DUAL_DOS_EN		0x3348

#define RTL_FE_L3PP_L2TP_SPORT0_MASK	GENMASK(15, 0)
#define RTL_FE_L3PP_L2TP_SPORT1_MASK	GENMASK(31, 16)
#define RTL_FE_L3PP_L2TP_SPORT_DFT	1701

#define RTL_FE_L3PE_GRE_ACK(n)		(0x35fc + (n) * 4)
#define RTL_FE_L3PE_GRE_SEQ(n)		(0x363c + (n) * 4)
#define RTL_FE_L3PE_IPV4_ID(n)		(0x367c + (n) * 4)

#define RTL_FE_CLS_MDATA_PKT_TYPE_L2TP	0x6
#define RTL_FE_CLS_MDATA_PKT_TYPE_PPTP	0x8
#define RTL_FE_CLS_MDATA_L2TP_MASK	0xe00f
#define RTL_FE_CLS_MDATA_PPTP_MASK	0xef0f
#define RTL_FE_PP_DUAL_DOS_EN_ALL	0xffffU
#define RTL_FE_LPB_CLS_INDEX		2
#define RTL_FE_LPB_CLS_PROFILE_BIT	42
#define RTL_FE_LPB_CLS_PROFILE_WIDTH	4
#define RTL_FE_CLS_KEY_TYPE_6RD		6
#define RTL_FE_CLS_KEY_TYPE_DSLITE	7
#define RTL_FE_CLS_PRI_TUNNEL		14
#define RTL_FE_CLS_MCGID_L3FE		16
#define RTL_FE_FDB_WORDS		4
#define RTL_FE_SMAC_WORDS		5
#define RTL_FE_COUNTER_WORDS		7
#define RTL_FE_CAM_WORDS		5

#define RTL_FE_HASH_ENTRIES		65536
#define RTL_FE_HASH_BUCKET		32
#define RTL_FE_ACTION_BYTES		48
#define RTL_FE_DEFAULT_ENTRIES		32
#define RTL_FE_OVERFLOW_ENTRIES		64
#define RTL_FE_HASH_BYTES		(RTL_FE_HASH_ENTRIES * 4)
#define RTL_FE_ACTION_OFFSET		RTL_FE_HASH_BYTES
#define RTL_FE_OVERFLOW_OFFSET		(RTL_FE_ACTION_OFFSET + \
					 RTL_FE_HASH_ENTRIES * RTL_FE_ACTION_BYTES)
#define RTL_FE_DEFAULT_OFFSET		(RTL_FE_OVERFLOW_OFFSET + \
					 RTL_FE_OVERFLOW_ENTRIES * RTL_FE_ACTION_BYTES)
#define RTL_FE_MEMORY_BYTES		ALIGN(RTL_FE_DEFAULT_OFFSET + \
					      RTL_FE_DEFAULT_ENTRIES * 16, 4096)

/* L3PE egress flow-mirror block, offsets inside the NE (L3FE) register
 * window that this driver maps through fe->regs.  These two registers are
 * not described in rtl9617c_regs.h (outside this change's scope), so the
 * layout is recorded here from the shipped OEM driver:
 *
 *   aal_l3pe_mirror_set()     ca-ne.ko @0x6b010  -> NE+0x3540
 *       bits[24:19] = arg0, 6 bits
 *       bits[18:16] = arg1, 3 bits
 *       bits[ 7: 0] = arg2, 8 bits
 *     The OEM code builds the word in a stack temporary that it never
 *     initialises, so bits[31:25] and bits[15:8] carry stack garbage and are
 *     not fields the OEM intended to program; only the three fields above
 *     are meaningful.  This driver writes the whole word instead, which
 *     leaves the undocumented bits at their reset value.
 *
 *   aal_l3pe_mirror_len_set() ca-ne.ko @0x6b060  -> NE+0x3544 bits[11:0]
 *
 * Neither setter has a caller anywhere in ca-ne.ko, no getter exists, and
 * aal_l3pe_init() does not program the pair, so the *meaning* of arg0/arg1/
 * arg2 cannot be recovered from the artifact: the API is orphaned.  The
 * working hypothesis (see specs/phase0-re2-policer-wred-dos.md U1) is
 *
 *   arg0 (6 bit)  mirror destination LDPID   -- same width as LSPID/LDPID
 *   arg1 (3 bit)  mirror mode / enable class
 *   arg2 (8 bit)  mirror instance or group id
 *
 * This driver therefore exposes the three fields verbatim through debugfs
 * instead of hard-coding a port meaning, and the convenience "port <ldpid>"
 * command only ever writes arg0.  Nothing here claims arg1/arg2 semantics.
 */
#define RTL_FE_MIRROR_CTRL		0x3540
#define RTL_FE_MIRROR_LEN		0x3544
#define RTL_FE_MIRROR_ARG0_SHIFT	19
#define RTL_FE_MIRROR_ARG0_MAX		0x3f
#define RTL_FE_MIRROR_ARG1_SHIFT	16
#define RTL_FE_MIRROR_ARG1_MAX		0x7
#define RTL_FE_MIRROR_ARG2_SHIFT	0
#define RTL_FE_MIRROR_ARG2_MAX		0xff
#define RTL_FE_MIRROR_LEN_MAX		0xfff

#define RTL_FE_MASK_L3			63
#define RTL_FE_MASK_BRIDGE		61
#define RTL_FE_MASK_LEARN		59
#define RTL_FE_MASK_LEARN_PPPOE		57

/* TYPE0_ACTION (0x3724) and CACHE_CTRL (0x38a0) mode encoding from
 * aal_hash_actionGrpBitmask_get (@0x996e0) and aal_hash_*_size_set:
 * normal mode packs 224 active bits in a 256-bit (code 3) container, while
 * NAPTV6 mode packs 371 active bits (+50 offset + Group 24) in a 384-bit
 * (code 4) container.
 */
#define RTL_FE_ACTION_GROUPS		0x00140000U
#define RTL_FE_ACTION_GROUPS_NAPT6	0x0114000aU
#define RTL_FE_ACTION_WIDTH_256		3U
#define RTL_FE_ACTION_WIDTH_384		4U
#define RTL_FE_ACTION_WIDTH_SHIFT	25
#define RTL_FE_CACHE_WIDTH_SHIFT	8
#define RTL_FE_HASH_CACHE_HALF		BIT(17)
#define RTL_FE_ACTION_NAPT6_SHIFT	50
#define RTL_FE_IP_ADDR_H_96_VLD_BIT	274
#define RTL_FE_IP_ADDR_H_96_1_BIT	275
#define RTL_FE_IP_ADDR_H_96_2_BIT	307
#define RTL_FE_IP_ADDR_H_96_3_BIT	339
#define RTL_FE_IP_ADDR_H_96_WIDTH	32

#define RTL_FE_KEY_IP_WORD_BITS		32
#define RTL_FE_KEY_MAC_SA_BIT		497
#define RTL_FE_KEY_MAC_DA_BIT		552

enum rtl_fe_rule_kind {
	RTL_FE_RULE_IPV4,
	RTL_FE_RULE_IPV6,
	RTL_FE_RULE_BRIDGE,
};

enum rtl_fe_action_field {
	RTL_FE_MRR_VLD,
	RTL_FE_MRR_EN,
	RTL_FE_NO_DROP_VLD,
	RTL_FE_NO_DROP,
	RTL_FE_DPID_VLD,
	RTL_FE_DPID_PRI,
	RTL_FE_PERMIT,
	RTL_FE_DEEPQ,
	RTL_FE_MCGID,
	RTL_FE_MC,
	RTL_FE_MDATA_BYTE_VLD,
	RTL_FE_MDATA_BYTE,
	RTL_FE_L3_IF_VLD,
	RTL_FE_SMAC_TRANS,
	RTL_FE_IGR_L3_IF_IDX,
	RTL_FE_EGR_L3_IF_IDX,
	RTL_FE_L3_IF_COUNTER_EN,
	RTL_FE_IP_TTL_DEC,
	RTL_FE_IP_TTL_ZERO_DISCARD_EN,
	RTL_FE_IP_ADDR_VLD,
	RTL_FE_IP_TYPE,
	RTL_FE_IP_ADDR,
	RTL_FE_IP_ADDR_NAPT6,
	RTL_FE_MAC_DA_IDX_VLD,
	RTL_FE_MAC_DA_IDX,
	RTL_FE_CHK_MSK_PTR,
	RTL_FE_CACHE_CTRL,
	RTL_FE_POP_L3_VLD,
	RTL_FE_POP_L3_CHK_ECN_EN,
	RTL_FE_POP_L3_EN,
	RTL_FE_T2_CTRL_VLD,
	RTL_FE_T2_CTRL,
	RTL_FE_LDPID_OFFSET_MSB,
	RTL_FE_IP_DSCP_UPDATE_EN,
	RTL_FE_IP_DSCP,
	RTL_FE_COS_UPDATE_EN,
	RTL_FE_COS,
	RTL_FE_INNER_8021P_UPDATE_EN,
	RTL_FE_INNER_8021P,
	RTL_FE_TOP_8021P_UPDATE_EN,
	RTL_FE_TOP_8021P,
	RTL_FE_INNER_DEI,
	RTL_FE_INNER_VID,
	RTL_FE_INNER_TPID_ENC,
	RTL_FE_TOP_DEI,
	RTL_FE_TOP_VID,
	RTL_FE_TOP_TPID_ENC,
	RTL_FE_VLAN_CNT,
	RTL_FE_VLAN_VLD,
	RTL_FE_POL_VLD,
	RTL_FE_POL_EN,
	RTL_FE_POL_ID,
	RTL_FE_POL2_ID_EN,
	RTL_FE_POL2_ID,
	RTL_FE_POL3_ID_EN,
	RTL_FE_POL3_ID,
	RTL_FE_PPPOE_VLD,
	RTL_FE_PPPOE_SET,
	RTL_FE_L4_PORT,
	RTL_FE_IP_MTU_ENC_VLD,
	RTL_FE_IP_MTU_ENC,
	RTL_FE_MODIFY_VLAN_ONLY_VLD,
	RTL_FE_MODIFY_VLAN_ONLY,
	RTL_FE_DIP_REMAP_VLD,
	RTL_FE_DIP_REMAP,
	RTL_FE_VXLAN_SPORT_MSB,
	RTL_FE_VXLAN_SPORT_UPDATE_EN,
	RTL_FE_ACTION_FIELDS,
};

enum rtl_fe_key_field {
	RTL_FE_KEY_L4_CHKSUM_ZERO,
	RTL_FE_KEY_TCP_RDP_CTRL,
	RTL_FE_KEY_L4_DP,
	RTL_FE_KEY_L4_SP,
	RTL_FE_KEY_L3_CHKSUM_ERR,
	RTL_FE_KEY_IP_FRAGMENT,
	RTL_FE_KEY_IP_OPTIONS,
	RTL_FE_KEY_IP_DA,
	RTL_FE_KEY_IP_SA,
	RTL_FE_KEY_IP_PROTOCOL,
	RTL_FE_KEY_IP_VER,
	RTL_FE_KEY_IP_VLD,
	RTL_FE_KEY_PPP_PROTOCOL,
	RTL_FE_KEY_PPPOE_SESSION,
	RTL_FE_KEY_PPPOE_TYPE,
	RTL_FE_KEY_INNER_DEI,
	RTL_FE_KEY_INNER_PCP,
	RTL_FE_KEY_INNER_VID,
	RTL_FE_KEY_INNER_TPID_ENC,
	RTL_FE_KEY_TOP_DEI,
	RTL_FE_KEY_TOP_PCP,
	RTL_FE_KEY_TOP_VID,
	RTL_FE_KEY_TOP_TPID_ENC,
	RTL_FE_KEY_VLAN_CNT,
	RTL_FE_KEY_ETHERTYPE,
	RTL_FE_KEY_MDATA_BYTE,
	RTL_FE_KEY_POL_ID,
	RTL_FE_KEY_ORIG_LSPID,
	RTL_FE_KEY_LSPID,
	RTL_FE_KEY_HKEY_ID,
	RTL_FE_KEY_CTRL_SET_ID,
	RTL_FE_KEY_TABLE_ID,
	RTL_FE_KEY_FIELDS,
};

struct rtl_fe_field_layout {
	u16 bit;
	u8 width;
};

struct rtl_fe_vlan {
	u16 vid;
	u8 tpid;
	u8 priority;
	u8 dei;
};

struct rtl_fe_action {
	u32 address;
	u32 address6[4];	/* host-order words [0]=MSB .. [3]=LSB */
	u16 port;
	u16 destination;
	u16 mac_da_index;
	u8 ingress_interface;
	u8 egress_interface;
	u8 cos;
	u8 check_mask;
	u8 translate;
	u8 translate_destination;
	bool translate_ipv6;
	u8 deep_queue;
	u8 vlan_set;
	u8 vlan_count;
	u8 pppoe_pop;
	u8 mtu_set;
	u8 mtu_index;
	u8 gem_set;
	u8 gem_index;
	u8 bridge;
	u8 dscp;
	bool dscp_set;
	bool mirror;
	struct rtl_fe_vlan vlan[2];
};

struct rtl_fe_key {
	u32 source[4];
	u32 destination[4];
	u16 source_port;
	u16 destination_port;
	u16 llid;
	u8 protocol;
	u8 ingress;
	u8 profile;
	u8 mask;
};

struct rtl_fe;
struct rtl_fe_cam_protocol;

void rtl_fe_bits_set(u32 *words, unsigned int bit, unsigned int width, u32 val);
void rtl_fe_action_set_mode(u32 *words, enum rtl_fe_action_field field,
			    u32 val, bool napt6);
void rtl_fe_action_set(u32 words[RTL_FE_ACTION_WORDS],
		       enum rtl_fe_action_field field, u32 val);
void rtl_fe_action_build_mode(u32 words[RTL_FE_ACTION_MAX_WORDS],
			      const struct rtl_fe_action *action, bool napt6);
void rtl_fe_action_build(u32 words[RTL_FE_ACTION_WORDS],
			 const struct rtl_fe_action *action);
void rtl_fe_mirror_apply(struct rtl_fe *fe, bool enable,
			 unsigned int arg0, unsigned int arg1,
			 unsigned int arg2, unsigned int len);
void rtl_fe_key_set(u32 words[RTL_FE_KEY_WORDS], enum rtl_fe_key_field field,
		    u32 val);
void rtl_fe_key_vlan(u32 words[RTL_FE_KEY_WORDS],
		     const struct rtl_fe_vlan vlan[2], unsigned int count);
void rtl_fe_key_ip(u32 words[RTL_FE_KEY_WORDS], const struct rtl_fe_key *key,
		   bool ipv6);
void rtl_fe_key_bridge(u32 words[RTL_FE_KEY_WORDS], const u8 *source,
		       const u8 *destination, u16 protocol,
		       const struct rtl_fe_key *key);
void rtl_fe_key_crc(const u32 words[RTL_FE_KEY_WORDS], u32 *crc32, u16 *crc16);
void rtl_fe_mask_l3(u32 words[RTL_FE_MASK_WORDS]);
void rtl_fe_mask_bridge(u32 words[RTL_FE_MASK_WORDS]);
unsigned int rtl_fe_hash_bucket(u16 crc16);
void rtl_fe_cpu_miss(u32 words[4]);
void rtl_fe_classify_hash(u32 words[RTL_FE_CLASSIFIER_WORDS],
			  unsigned int profile, unsigned int source);
void rtl_fe_ingress_lpb(u32 words[RTL_FE_LPB_WORDS], unsigned int source,
			unsigned int destination);
void rtl_fe_fdb_key(u32 words[RTL_FE_FDB_WORDS], const u8 *mac);

int rtl_fe_indirect(struct rtl_fe *fe, unsigned int reg, u32 cmd);
int rtl_fe_mask_write(struct rtl_fe *fe, unsigned int index,
		      const u32 words[RTL_FE_MASK_WORDS]);
int rtl_fe_mask_read(struct rtl_fe *fe, unsigned int index,
		     u32 words[RTL_FE_MASK_WORDS]);
void rtl_fe_dma_tables(struct rtl_fe *fe, u32 address, u32 address_high);
void rtl_fe_cache_start(struct rtl_fe *fe);
int rtl_fe_age_write(struct rtl_fe *fe, unsigned int index, unsigned int age);
int rtl_fe_age_read(struct rtl_fe *fe, unsigned int index, unsigned int *age);
int rtl_fe_cache_command(struct rtl_fe *fe, unsigned int index, u16 crc16,
			 unsigned int command);
int rtl_fe_cam_protocol_get(struct rtl_fe *fe, struct rtl_fe_cam_protocol *cam,
			    unsigned int bank, unsigned int protocol);
int rtl_fe_cam_protocol_put(struct rtl_fe *fe, struct rtl_fe_cam_protocol *cam);
int rtl_fe_classifier_read(struct rtl_fe *fe, unsigned int index,
			   u32 words[RTL_FE_CLASSIFIER_WORDS]);
int rtl_fe_classifier_write(struct rtl_fe *fe, unsigned int index,
			    const u32 words[RTL_FE_CLASSIFIER_WORDS]);
int rtl_fe_cls_key_read(struct rtl_fe *fe, unsigned int index,
			u32 words[RTL_FE_CLS_KEY_WORDS]);
int rtl_fe_cls_key_write(struct rtl_fe *fe, unsigned int index,
			 const u32 words[RTL_FE_CLS_KEY_WORDS]);
unsigned int rtl_fe_cls_dual_fib_index(unsigned int key_index);
void rtl_fe_cls_pack_6rd(u32 even[RTL_FE_CLS_KEY_WORDS],
			 u32 odd[RTL_FE_CLS_KEY_WORDS],
			 const u8 outer_sa[4], const u8 outer_da[4]);
void rtl_fe_cls_pack_dslite(u32 even[RTL_FE_CLS_KEY_WORDS],
			    u32 odd[RTL_FE_CLS_KEY_WORDS],
			    const u8 outer_sa[16]);
void rtl_fe_cls_pack_dual_fib(u32 fib0[RTL_FE_CLASSIFIER_WORDS],
			      u32 fib1[RTL_FE_CLASSIFIER_WORDS],
			      unsigned int igr_l3_if_idx);
int rtl_fe_cls_write_6rd(struct rtl_fe *fe, unsigned int key_index,
			 const u8 outer_sa[4], const u8 outer_da[4],
			 unsigned int igr_l3_if_idx);
int rtl_fe_cls_write_dslite(struct rtl_fe *fe, unsigned int key_index,
			    const u8 outer_sa[16], unsigned int igr_l3_if_idx);
int rtl_fe_cls_write_l2tp(struct rtl_fe *fe, unsigned int key_index,
			  bool is_ipv6, const u8 outer_da[16],
			  u16 tid, u16 sid, unsigned int igr_l3_if_idx);
int rtl_fe_cls_write_pptp(struct rtl_fe *fe, unsigned int key_index,
			  bool is_ipv6, const u8 outer_da[16],
			  u16 call_id, unsigned int igr_l3_if_idx);
int rtl_fe_cls_clear_pair(struct rtl_fe *fe, unsigned int key_index);
int rtl_fe_smac_read(struct rtl_fe *fe, unsigned int index,
		     u32 words[RTL_FE_SMAC_WORDS]);
int rtl_fe_smac_write(struct rtl_fe *fe, unsigned int index,
		      const u32 words[RTL_FE_SMAC_WORDS]);
int rtl_fe_counter_read(struct rtl_fe *fe, unsigned int index,
			u32 words[RTL_FE_COUNTER_WORDS]);
int rtl_fe_fdb_command(struct rtl_fe *fe, unsigned int command,
		       u32 words[RTL_FE_FDB_WORDS], u32 *result);

/* Hardware multicast tables (spec phase0-re3-dualhdr-mc-napt6 §4.4/§4.5).
 *
 *   MCE index table : table id 14, 256 entries x 2 words, base NE+0xaa64
 *   ARB MC FIB      : table id 15,  64 entries x 3 words, base NE+0x1634
 *
 * Command word: bit31 starts an access and clears when the table is done,
 * bit30 selects a write (aal_arb_mc_fib_set @ ca-ne.ko .text+0x3ff80 polls
 * bit31 10000 times before timing out).
 *
 * The generic table register block places the data words below the command
 * register in descending order, the same layout every other indirect table
 * in this driver uses (RTL_L2FE_PP_ILPB_DATA(n) = 0x11f8 - 4 * n).  The ARB
 * MC FIB words are the OEM addresses; the MCE data registers are derived
 * from that layout and must be confirmed by read-back on the device
 * (TODO(probe)).
 *
 * The MCE entry payload is the 64-bit bitmap of ARB MC FIB member indices
 * belonging to the group (aal_hw_mcgid_free iterates 1 << i, i < 0x40).
 */
#define RTL_FE_MCE_ENTRIES		256
#define RTL_FE_MCE_CMD			0xaa64
#define RTL_FE_MCE_DATA0		0xaa6c
#define RTL_FE_MCE_DATA1		0xaa68
#define RTL_FE_ARB_MC_FIB_ENTRIES	64
#define RTL_FE_ARB_MC_FIB_CMD		0x1634
#define RTL_FE_ARB_MC_FIB_DATA0		0x1640
#define RTL_FE_ARB_MC_FIB_DATA1		0x163c
#define RTL_FE_ARB_MC_FIB_DATA2		0x1638
#define RTL_FE_MCAST_POLL_COUNT		10000

/* L3PE dual-header tables (spec phase0-re3-dualhdr-mc-napt6 §1.1/§1.2).
 *
 *   Content (DUAL HEADER TABLE) : table id 31, 16 entries x 16 words
 *   Control (DUAL CONTROL TABLE): table id 32, 16 entries x 16 words
 *   FMR     (DUAL FMR TABLE)    : table id 33,  3 entries x 16 words
 *
 * All three share one 64-byte data window: word N is read/written at
 * NE+0x3548+(16-N)*4, i.e. word0 lives at 0x3588 and word15 at 0x354c.
 * The command register sits at 0x3548.  __l3pe_dual_hw_entry_set()
 * (ca-ne.ko .text+0x6a390) writes buf[0]..buf[15] in that descending
 * address order and only then writes the command word; that ordering is
 * preserved here.  bit31 is the start/busy flag, bit30 selects a write,
 * bit5 selects FMR, bit4 selects Control (both clear selects Content) and
 * bits3:0 are the entry index (FMR uses bits2:0).  The OEM polls bit31
 * 1000 times with a 1 us delay before returning -ETIMEDOUT.
 */
#define RTL_FE_DUAL_CONTENT_TABLE_ID	31
#define RTL_FE_DUAL_CONTROL_TABLE_ID	32
#define RTL_FE_DUAL_FMR_TABLE_ID		33
#define RTL_FE_DUAL_CONTENT_ENTRIES	16
#define RTL_FE_DUAL_CONTROL_ENTRIES	16
#define RTL_FE_DUAL_FMR_ENTRIES		3
#define RTL_FE_DUAL_WORDS		16
#define RTL_FE_DUAL_BYTES		(RTL_FE_DUAL_WORDS * 4)
#define RTL_FE_DUAL_CMD			0x3548
#define RTL_FE_DUAL_DATA(word)		(0x3588 - (word) * 4)
#define RTL_FE_DUAL_POLL_COUNT		1000
#define RTL_FE_DUAL_BUSY		BIT(31)
#define RTL_FE_DUAL_WRITE		BIT(30)
#define RTL_FE_DUAL_CMD_READ		0x80000000U
#define RTL_FE_DUAL_CMD_WRITE		0xc0000000U
#define RTL_FE_DUAL_SEL_CONTENT		0x00000000U
#define RTL_FE_DUAL_SEL_CONTROL		0x00000010U
#define RTL_FE_DUAL_SEL_FMR		0x00000020U
#define RTL_FE_DUAL_INDEX_MASK		0x0000000fU
#define RTL_FE_DUAL_FMR_INDEX_MASK	0x00000007U

/* NPTv6 prefix table (RE-6 §4.3).  __npt6_prefix_addr_hw_entry_set() /
 * __npt6_prefix_addr_hw_entry_get() (ca-ne .text+0x94570 / 0x99780) address
 * 16 entries x 2 words as a plain data window at NE+0x3A24; the descriptor's
 * "NE+0x3AA4" is the end of that 128-byte block.  The observed set/get paths
 * do not write a command word and do not poll a busy bit.
 */
#define RTL_FE_NPT6_PREFIX_ENTRIES	16
#define RTL_FE_NPT6_PREFIX_WORDS	2
#define RTL_FE_NPT6_PREFIX_DATA		0x3a24
#define RTL_FE_NPT6_PREFIX_END		0x3aa4

#endif
