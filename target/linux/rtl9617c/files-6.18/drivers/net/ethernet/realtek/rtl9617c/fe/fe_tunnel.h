/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef RTL9617C_FE_TUNNEL_H
#define RTL9617C_FE_TUNNEL_H

#include <linux/bitmap.h>
#include <linux/bits.h>
#include <linux/mutex.h>
#include <linux/types.h>

#include "fe_hw.h"

struct rtl_fe;

/* L3PE dual-header hash interface indices.  The hardware has 32 physical EIF
 * rows, but fc_mgr.ko hashIntfIdx2HwIntfIdx_mapping (spec phase0-re3-
 * dualhdr-mc-napt6 §2.2) maps hash indices 32..63 onto physical rows 16..31:
 * row 16+x is shared by hash indices 16+x, 32+x and 48+x.  Those aliases are
 * not additional physical resources and the three users of one row must agree
 * on the EIF parameters.  The open driver only allocates hash indices 0..31.
 */
#define RTL_FE_EIF_HASH_INDICES		64
#define RTL_FE_EIF_PHYS_ROWS		32
#define RTL_FE_EIF_EXCLUSIVE_ROWS	16
#define RTL_FE_EIF_ALIAS_BASE		16
#define RTL_FE_EIF_ALIAS_MASK		0xf

/* 0x7f is the N/A sentinel the OEM setup functions write into every unused
 * 7-bit offset field of the Control table (spec §1.4).
 */
#define RTL_FE_DUAL_OST_NONE		0x7f
#define RTL_FE_DUAL_LAST_LEN		1024
#define RTL_FE_DUAL_DSLITE_ADDR_LEN	16
#define RTL_FE_DUAL_FMR_W2_VALID_MASK	0x1ffffU
/* HDR_I.FMR_IDX sentinel (2-bit value 3 = "un-matched(DMR)") that suppresses
 * MAP-E FMR IPv6-DA synthesis during IP4-in-IP6 (DS-Lite) encap so L3PE emits
 * the static outer IPv6 destination address from DUAL Content verbatim.
 */
#define RTL_FE_DUAL_FMR_NONE		3

/* DS-Lite Content template (fc_8277c.ko _rtk_fc_flow_setupDSLITE_by_egrPktHdr).
 * word0 (60 00 00 00) and word1 (00 00 04 ff) are the constant outer IPv6
 * header prefix in little-endian memory order (payload_len=0, next_hdr=4
 * IPPROTO_IPIP, hop_limit=0xff); the two 16-byte IPv6 addresses follow at
 * words 2..5 (source) and 6..9 (destination).
 */
#define RTL_FE_DUAL_DSLITE_WORD0	0x00000060U
#define RTL_FE_DUAL_DSLITE_WORD1	0xff040000U

/* 6RD outer IPv4 header template words (be32 host memory order on ARM64 LE). */
#define RTL_FE_DUAL_HASH_EIF_BASE	32
#define RTL_FE_DUAL_6RD_ADDR_LEN	4
#define RTL_FE_DUAL_6RD_WORD0		0x00000045U
#define RTL_FE_DUAL_6RD_WORD2		0x000029ffU
#define RTL_FE_DUAL_CLS_PROFILES	2
#define RTL_FE_DUAL_CLS_PAIR_SLOTS	(RTL_FE_CLS_KEY_PROFILE_ENTRIES / 2)

/* OEM dualHdrType long-name enum (spec §3.1).  Only the three profiles with
 * measured Control-table literals (RE-7 §3.2-§3.4 for DS-Lite/6RD/MAP-T) are
 * programmable here; VXLAN is listed for completeness but its Content/Control
 * template was not captured, so rtl_fe_dual_control_set_type() refuses it.
 */
enum rtl_fe_dual_type {
	RTL_FE_DUAL_TYPE_NONE = 0,
	RTL_FE_DUAL_TYPE_IP4INIP6 = 1,
	RTL_FE_DUAL_TYPE_VXLAN = 6,
	RTL_FE_DUAL_TYPE_6RD = 7,
	RTL_FE_DUAL_TYPE_MAPT = 8,
	RTL_FE_DUAL_TYPE_L2TP = 9,
	RTL_FE_DUAL_TYPE_PPTP = 10,
};

/* Who owns a table slot.  Milestone 1 only hands slots out to debugfs; the
 * flow-action integration (W8b) will allocate with RTL_FE_DUAL_OWNER_FLOW so
 * the dump can tell the two users apart.
 */
enum rtl_fe_dual_owner {
	RTL_FE_DUAL_OWNER_NONE = 0,
	RTL_FE_DUAL_OWNER_DEBUGFS = 1,
	RTL_FE_DUAL_OWNER_FLOW = 2,
};

struct rtl_fe_dual_slot {
	u8 owner;
	u8 type;
};

/* Control table entry (spec §1.4).  The 34 fields fill bits 0..127 without
 * gaps; only word0..word3 are decoded by the OEM print helper, word4..word15
 * stay reserved.  Every field is a u32 here so the pack/unpack helpers can
 * treat the bit layout uniformly; the bit/width macros below carry the real
 * hardware widths.
 */
struct rtl_fe_dual_control {
	u32 rep_ip_len_diff_pad_ctrl;
	u32 rep_len_diff1_pad_ctrl;
	u32 rep_len_diff2_pad_ctrl;
	u32 hdr_fmt;
	u32 hdr_len;
	u32 mtu_diff;
	u32 ppp_ip_ver_ost;
	u32 rep_ip_en;
	u32 rep_ip_ver;
	u32 rep_len_ost1;
	u32 rep_len_diff1;
	u32 rep_len_ost2;
	u32 rep_len_diff2;
	u32 ip4_ost;
	u32 gre_seq_ack_ost;
	u32 gre_mod_fld;
	u32 ip6_oft;
	u32 rep_ip_dscp_en;
	u32 rep_ip_ecn_en;
	u32 rep_ip_len;
	u32 rep_ip_len_diff;
	u32 rep_ip_ptc;
	u32 rep_ip_ttl;
	u32 mapt_pre_len;
	u32 map_drf_ver;
	u32 sixrd_dip_pre_len;
	u32 sixrd_dip_suf_str_bit;
	u32 dsl_uc_chk;
	u32 dsl_mc_chk;
	u32 l4sum_rec;
	u32 vxlan_sp_ost;
	u32 inr_to_out_fld;
	u32 tos_hsh_sel;
	u32 mc_mac_map;
};

/* Control table bit positions and widths (spec §1.4).  The OEM field names
 * that start with a digit are spelled SIXRD_/sixrd_ in C.
 */
#define RTL_FE_DUAL_CTRL_REP_IP_LEN_DIFF_PAD_CTRL_BIT	127
#define RTL_FE_DUAL_CTRL_REP_IP_LEN_DIFF_PAD_CTRL_WIDTH	1
#define RTL_FE_DUAL_CTRL_REP_LEN_DIFF1_PAD_CTRL_BIT	126
#define RTL_FE_DUAL_CTRL_REP_LEN_DIFF1_PAD_CTRL_WIDTH	1
#define RTL_FE_DUAL_CTRL_REP_LEN_DIFF2_PAD_CTRL_BIT	125
#define RTL_FE_DUAL_CTRL_REP_LEN_DIFF2_PAD_CTRL_WIDTH	1
#define RTL_FE_DUAL_CTRL_HDR_FMT_BIT			123
#define RTL_FE_DUAL_CTRL_HDR_FMT_WIDTH			2
#define RTL_FE_DUAL_CTRL_HDR_LEN_BIT			116
#define RTL_FE_DUAL_CTRL_HDR_LEN_WIDTH			7
#define RTL_FE_DUAL_CTRL_MTU_DIFF_BIT			109
#define RTL_FE_DUAL_CTRL_MTU_DIFF_WIDTH			7
#define RTL_FE_DUAL_CTRL_PPP_IP_VER_OST_BIT		102
#define RTL_FE_DUAL_CTRL_PPP_IP_VER_OST_WIDTH		7
#define RTL_FE_DUAL_CTRL_REP_IP_EN_BIT			101
#define RTL_FE_DUAL_CTRL_REP_IP_EN_WIDTH		1
#define RTL_FE_DUAL_CTRL_REP_IP_VER_BIT			100
#define RTL_FE_DUAL_CTRL_REP_IP_VER_WIDTH		1
#define RTL_FE_DUAL_CTRL_REP_LEN_OST1_BIT		93
#define RTL_FE_DUAL_CTRL_REP_LEN_OST1_WIDTH		7
#define RTL_FE_DUAL_CTRL_REP_LEN_DIFF1_BIT		86
#define RTL_FE_DUAL_CTRL_REP_LEN_DIFF1_WIDTH		7
#define RTL_FE_DUAL_CTRL_REP_LEN_OST2_BIT		79
#define RTL_FE_DUAL_CTRL_REP_LEN_OST2_WIDTH		7
#define RTL_FE_DUAL_CTRL_REP_LEN_DIFF2_BIT		72
#define RTL_FE_DUAL_CTRL_REP_LEN_DIFF2_WIDTH		7
#define RTL_FE_DUAL_CTRL_IP4_OST_BIT			65
#define RTL_FE_DUAL_CTRL_IP4_OST_WIDTH			7
#define RTL_FE_DUAL_CTRL_GRE_SEQ_ACK_OST_BIT		58
#define RTL_FE_DUAL_CTRL_GRE_SEQ_ACK_OST_WIDTH		7
#define RTL_FE_DUAL_CTRL_GRE_MOD_FLD_BIT		56
#define RTL_FE_DUAL_CTRL_GRE_MOD_FLD_WIDTH		2
#define RTL_FE_DUAL_CTRL_IP6_OFT_BIT			49
#define RTL_FE_DUAL_CTRL_IP6_OFT_WIDTH			7
#define RTL_FE_DUAL_CTRL_REP_IP_DSCP_EN_BIT		48
#define RTL_FE_DUAL_CTRL_REP_IP_DSCP_EN_WIDTH		1
#define RTL_FE_DUAL_CTRL_REP_IP_ECN_EN_BIT		47
#define RTL_FE_DUAL_CTRL_REP_IP_ECN_EN_WIDTH		1
#define RTL_FE_DUAL_CTRL_REP_IP_LEN_BIT			46
#define RTL_FE_DUAL_CTRL_REP_IP_LEN_WIDTH		1
#define RTL_FE_DUAL_CTRL_REP_IP_LEN_DIFF_BIT		39
#define RTL_FE_DUAL_CTRL_REP_IP_LEN_DIFF_WIDTH		7
#define RTL_FE_DUAL_CTRL_REP_IP_PTC_BIT			38
#define RTL_FE_DUAL_CTRL_REP_IP_PTC_WIDTH		1
#define RTL_FE_DUAL_CTRL_REP_IP_TTL_BIT			37
#define RTL_FE_DUAL_CTRL_REP_IP_TTL_WIDTH		1
#define RTL_FE_DUAL_CTRL_MAPT_PRE_LEN_BIT		34
#define RTL_FE_DUAL_CTRL_MAPT_PRE_LEN_WIDTH		3
#define RTL_FE_DUAL_CTRL_MAP_DRF_VER_BIT		33
#define RTL_FE_DUAL_CTRL_MAP_DRF_VER_WIDTH		1
#define RTL_FE_DUAL_CTRL_SIXRD_DIP_PRE_LEN_BIT		28
#define RTL_FE_DUAL_CTRL_SIXRD_DIP_PRE_LEN_WIDTH	5
#define RTL_FE_DUAL_CTRL_SIXRD_DIP_SUF_STR_BIT_BIT	22
#define RTL_FE_DUAL_CTRL_SIXRD_DIP_SUF_STR_BIT_WIDTH	6
#define RTL_FE_DUAL_CTRL_DSL_UC_CHK_BIT			19
#define RTL_FE_DUAL_CTRL_DSL_UC_CHK_WIDTH		3
#define RTL_FE_DUAL_CTRL_DSL_MC_CHK_BIT			18
#define RTL_FE_DUAL_CTRL_DSL_MC_CHK_WIDTH		1
#define RTL_FE_DUAL_CTRL_L4SUM_REC_BIT			17
#define RTL_FE_DUAL_CTRL_L4SUM_REC_WIDTH		1
#define RTL_FE_DUAL_CTRL_VXLAN_SP_OST_BIT		10
#define RTL_FE_DUAL_CTRL_VXLAN_SP_OST_WIDTH		7
#define RTL_FE_DUAL_CTRL_INR_TO_OUT_FLD_BIT		2
#define RTL_FE_DUAL_CTRL_INR_TO_OUT_FLD_WIDTH		8
#define RTL_FE_DUAL_CTRL_TOS_HSH_SEL_BIT		1
#define RTL_FE_DUAL_CTRL_TOS_HSH_SEL_WIDTH		1
#define RTL_FE_DUAL_CTRL_MC_MAC_MAP_BIT			0
#define RTL_FE_DUAL_CTRL_MC_MAC_MAP_WIDTH		1

/* FMR table entry (spec §1.5): a MAP-T forwarding mapping rule.  word0 and
 * word1 hold the 64-bit IPv6 prefix in little-endian word order, word2 holds
 * the PSID / prefix-length fields; word3..word15 are reserved.
 */
struct rtl_fe_dual_fmr {
	u64 prefix;
	u32 psid_str_ost;
	u32 psid_end_ost;
	u32 psid_refill;
	u32 pref_len;
	u32 drf_ver;
};

/* Software arbitration for the 64 hash-interface indices.  Physical rows
 * 0..15 have one hash index each; rows 16..31 are shared by 16+x, 32+x and
 * 48+x.  "refs" is the number of used hash indices on this physical row and is
 * mirrored into every used slot of the group so the debugfs dump is coherent.
 * This is a pure software table: no register is written.
 */
struct rtl_fe_eif_slot {
	u32 param_hash;
	u8 hash;
	u8 phys;
	u8 refs;
	bool used;
};

#define RTL_FE_PPP_TUN_F_SEQ	BIT(0)
#define RTL_FE_PPP_TUN_F_ACK	BIT(1)

struct rtl_fe_tunnel_session {
	bool active;
	bool decap;
	enum rtl_fe_dual_type type;
	u8 af;
	u8 ppp_len;
	u8 flags;
	u16 sport;
	u16 dport;
	u16 tid;
	u16 sid;
	u16 peer_tid;
	u16 peer_sid;
	unsigned int refs;
	unsigned int cls_profile;
	unsigned int cls_index;
	bool cls_active;
	u32 param_hash;
	u8 src[RTL_FE_DUAL_DSLITE_ADDR_LEN];
	u8 dst[RTL_FE_DUAL_DSLITE_ADDR_LEN];
};

struct rtl_fe_tunnel_key {
	enum rtl_fe_dual_type type;
	bool decap;
	u8 af;
	u8 ppp_len;
	u8 flags;
	u16 sport;
	u16 dport;
	u16 tid;
	u16 sid;
	u16 peer_tid;
	u16 peer_sid;
	u32 gre_seq;
	u32 gre_ack;
	unsigned int cls_profile;
	u32 param_hash;
	u8 src[RTL_FE_DUAL_DSLITE_ADDR_LEN];
	u8 dst[RTL_FE_DUAL_DSLITE_ADDR_LEN];
};

struct rtl_fe_tunnel_binding {
	unsigned int dual_index;
	unsigned int hash_eif;
	unsigned int phys_eif;
	unsigned int cls_index;
	bool need_cls_program;
};

struct rtl_fe_tunnel {
	struct rtl_fe *fe;
	/* serialises allocation state and every register access */
	struct mutex lock;
	DECLARE_BITMAP(content, RTL_FE_DUAL_CONTENT_ENTRIES);
	DECLARE_BITMAP(control, RTL_FE_DUAL_CONTROL_ENTRIES);
	DECLARE_BITMAP(fmr, RTL_FE_DUAL_FMR_ENTRIES);
	DECLARE_BITMAP(cls_pairs[RTL_FE_DUAL_CLS_PROFILES],
		       RTL_FE_DUAL_CLS_PAIR_SLOTS);
	struct rtl_fe_dual_slot content_slot[RTL_FE_DUAL_CONTENT_ENTRIES];
	struct rtl_fe_dual_slot control_slot[RTL_FE_DUAL_CONTROL_ENTRIES];
	struct rtl_fe_dual_slot fmr_slot[RTL_FE_DUAL_FMR_ENTRIES];
	struct rtl_fe_eif_slot eif[RTL_FE_EIF_HASH_INDICES];
	struct rtl_fe_tunnel_session sessions[RTL_FE_DUAL_CONTROL_ENTRIES];
	bool ready;
	/* result of the last debugfs command, shown by the read side */
	char last[RTL_FE_DUAL_LAST_LEN];
};

int rtl_fe_tunnel_init(struct rtl_fe *fe);
void rtl_fe_tunnel_exit(struct rtl_fe *fe);
void rtl_fe_tunnel_debugfs_init(struct rtl_fe *fe);

int rtl_fe_dual_content_alloc(struct rtl_fe *fe, unsigned int *index,
			      unsigned int owner);
int rtl_fe_dual_content_free(struct rtl_fe *fe, unsigned int index);
int rtl_fe_dual_content_write(struct rtl_fe *fe, unsigned int index,
			      const u32 words[RTL_FE_DUAL_WORDS]);
int rtl_fe_dual_content_read(struct rtl_fe *fe, unsigned int index,
			     u32 words[RTL_FE_DUAL_WORDS]);

int rtl_fe_dual_control_alloc(struct rtl_fe *fe, unsigned int *index,
			      unsigned int owner);
int rtl_fe_dual_control_free(struct rtl_fe *fe, unsigned int index);
int rtl_fe_dual_control_write(struct rtl_fe *fe, unsigned int index,
			      const u32 words[RTL_FE_DUAL_WORDS]);
int rtl_fe_dual_control_read(struct rtl_fe *fe, unsigned int index,
			     u32 words[RTL_FE_DUAL_WORDS]);
/* Fill one allocated Control slot with the measured DS-Lite (IP4INIP6),
 * corrected 6RD (RE-7 §3.3) or MAP-T (RE-7 §3.4, inr_to_out_fld=0x80) literal
 * set.  Returns -EOPNOTSUPP for every other dual-header type.
 */
int rtl_fe_dual_control_set_type(struct rtl_fe *fe, unsigned int index,
				 unsigned int type);

/* Flow-facing table programming (RE-7 §8.2 steps 1/2).  Both helpers allocate
 * one Control slot and one Content slot with RTL_FE_DUAL_OWNER_FLOW, program
 * the measured profile and verify the read-back; on any failure everything
 * allocated by the call is released again.  The flow path itself is gated by
 * the "dual_hdr" module parameter, which defaults to off.
 *
 * DS-Lite Content carries the two outer IPv6 addresses in network byte order
 * (16 bytes each).  6RD encap Content carries the 20-byte outer IPv4 header
 * template (words 0, 2, 3, 4).  For decapsulation rules Content is all zero.
 */
int rtl_fe_tunnel_program_dslite(struct rtl_fe *fe, bool decap,
				 const u8 src[RTL_FE_DUAL_DSLITE_ADDR_LEN],
				 const u8 dst[RTL_FE_DUAL_DSLITE_ADDR_LEN],
				 unsigned int *control, unsigned int *content);
int rtl_fe_tunnel_program_6rd(struct rtl_fe *fe, bool decap,
			      const u8 src[RTL_FE_DUAL_6RD_ADDR_LEN],
			      const u8 dst[RTL_FE_DUAL_6RD_ADDR_LEN],
			      unsigned int *control, unsigned int *content);

/* Release one programmed Control+Content pair in the mandatory order:
 * Control first, then Content (RE-7 §7.2/§7.3).  Already-released slots are
 * tolerated so a retried flow teardown can make progress.
 */
int rtl_fe_tunnel_release(struct rtl_fe *fe, unsigned int control,
			  unsigned int content);

/* Unified refcounted flow session management locking dual_index == control ==
 * content == (phys_eif - 16) == (hash_eif - 32).  Caller must hold fe->lock.
 */
bool rtl_fe_tunnel_phys_busy(struct rtl_fe *fe, unsigned int phys);
int rtl_fe_tunnel_flow_get(struct rtl_fe *fe,
			   const struct rtl_fe_tunnel_key *key,
			   u16 busy_phys_mask,
			   struct rtl_fe_tunnel_binding *binding);
int rtl_fe_tunnel_flow_mark_cls(struct rtl_fe *fe, unsigned int dual_index);
int rtl_fe_tunnel_flow_cls_info(struct rtl_fe *fe, unsigned int dual_index,
				bool *is_last, bool *cls_active,
				unsigned int *cls_index);
void rtl_fe_tunnel_flow_cls_cleared(struct rtl_fe *fe, unsigned int dual_index);
int rtl_fe_tunnel_flow_put(struct rtl_fe *fe, unsigned int dual_index);

/* True when the opt-in flow-key/TUNNEL_ENCAP/DECAP parser is enabled. */
bool rtl_fe_tunnel_flow_enabled(void);

/* True when hardware L2TPv2/PPTP cleartext PPP flow offload is enabled. */
bool rtl_fe_vpn_offload_enabled(void);

int rtl_fe_dual_fmr_alloc(struct rtl_fe *fe, unsigned int *index,
			  unsigned int owner);
int rtl_fe_dual_fmr_free(struct rtl_fe *fe, unsigned int index);
int rtl_fe_dual_fmr_write(struct rtl_fe *fe, unsigned int index,
			  const u32 words[RTL_FE_DUAL_WORDS]);
int rtl_fe_dual_fmr_read(struct rtl_fe *fe, unsigned int index,
			 u32 words[RTL_FE_DUAL_WORDS]);

void rtl_fe_dual_control_pack(u32 words[RTL_FE_DUAL_WORDS],
			      const struct rtl_fe_dual_control *control);
void rtl_fe_dual_control_unpack(const u32 words[RTL_FE_DUAL_WORDS],
				struct rtl_fe_dual_control *control);
void rtl_fe_dual_fmr_pack(u32 words[RTL_FE_DUAL_WORDS],
			  const struct rtl_fe_dual_fmr *fmr);
void rtl_fe_dual_fmr_unpack(const u32 words[RTL_FE_DUAL_WORDS],
			    struct rtl_fe_dual_fmr *fmr);

/* hash EIF index -> physical L3E interface row (spec §2.2).  Returns
 * -EINVAL when the index is outside 0..63; aliases 32..63 are not additional
 * physical rows.
 */
int rtl_fe_eif_phys(unsigned int hash);

/* Allocate one hash-interface index and return its physical row.  hash 0..15
 * is exclusive (rows 0..15 have no aliases).  hash 16..63 may share physical
 * row 16+(hash&0xF), but only when every already-used member of that row has
 * exactly the same param_hash; otherwise -EBUSY.  No register is touched.
 */
int rtl_fe_eif_alloc(struct rtl_fe *fe, unsigned int hash, u32 param_hash,
		     unsigned int *phys);
int rtl_fe_eif_free(struct rtl_fe *fe, unsigned int hash);

#endif /* RTL9617C_FE_TUNNEL_H */
