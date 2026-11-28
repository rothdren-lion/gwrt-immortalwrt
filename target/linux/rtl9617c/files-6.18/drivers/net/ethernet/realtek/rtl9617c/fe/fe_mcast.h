/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef RTL9617C_FE_MCAST_H
#define RTL9617C_FE_MCAST_H

#include <linux/bitmap.h>
#include <linux/if_ether.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/types.h>

struct rtl_fe;

/* Software MCGID pool.  ca-ne.ko aal_sw_mcgid_alloc() linearly scans all
 * 1024 entries and has no reserved range (spec phase0-re3-dualhdr-mc-napt6
 * §4.2/§4.9, UNKNOWN U6), so this pool mirrors the hardware index space.
 */
#define RTL_FE_MCAST_MCGIDS		1024
#define RTL_FE_MCAST_MCES		256
#define RTL_FE_MCAST_FIBS		64
#define RTL_FE_MCAST_PORTS		64
#define RTL_FE_MCAST_BITS_PER_BYTE	8
#define RTL_FE_MCAST_MASK_BYTES		(RTL_FE_MCAST_PORTS / RTL_FE_MCAST_BITS_PER_BYTE)
#define RTL_FE_MCAST_NONE		0xffff
#define RTL_FE_MCAST_PORT_NONE		0xff
#define RTL_FE_MCAST_MCE_WORDS		2
#define RTL_FE_MCAST_FIB_WORDS		3
#define RTL_FE_MCAST_LAST_LEN		512

/* Software MCGID entry, modelled on the 14-byte swMcgid record at
 * ca-ne.ko .bss+0x2098: in_use, cur_hw_mcgid, prev_hw_mcgid.  "users" is
 * the driver-side reference count; the last reference performs the
 * reverse-order teardown (FIB actions -> MCE entry -> cur/prev = 0xffff).
 * RTL_FE_MCAST_NONE in "hw_index" means "no MCE slot bound yet".
 */
struct rtl_fe_mcgid {
	u16 users;
	u16 hw_index;
	u16 prev_index;
};

/* MCE index table slot (ni_mce_indx_table: 256 x 2 words, table id 14).
 * The two words carry the 64-bit bitmap of ARB MC FIB member indices.
 */
struct rtl_fe_mce {
	u16 mcgid;
	u8 used;
};

/* ARB MC FIB slot (l2fe_arb_fib_table: 64 x 3 words, table id 15).
 * "port" is the driver-side port source id used to rebuild a group; 0xff
 * marks a raw entry written through debugfs, whose port is not known.
 */
struct rtl_fe_fib {
	u16 mcgid;
	u8 port;
	u8 used;
	u32 words[RTL_FE_MCAST_FIB_WORDS];
};

/* ARB MC FIB VLAN edit commands (2-bit c_vlan_cmd / s_vlan_cmd). */
enum rtl_fe_mcast_vlan_cmd {
	RTL_FE_MCAST_VLAN_NOP = 0,
	RTL_FE_MCAST_VLAN_PUSH = 1,
	RTL_FE_MCAST_VLAN_POP = 2,
	RTL_FE_MCAST_VLAN_SWAP = 3,
};

/*
 * Complete 76-bit ARB MC FIB member action layout decoded from ca-ne.ko
 * aal_arb_mc_fib_set (@0x3ff80), _aal_arb_mc_fib_action_add (@0x4f020) and
 * cli-drv.ko __cli_aal_arb_mc_fib_cfg_*_set:
 *
 *   word0 (0x1640): [1:0] c_vlan_cmd, [13:2] c_vid, [14] c_tpid_cmd,
 *                   [15] c_tpid_sel, [17:16] c_dot1p_cmd, [20:18] c_dot1p,
 *                   [21] c_dei_cmd, [22] c_dei, [31:23] pol_id
 *   word1 (0x163c): [1:0] s_vlan_cmd, [13:2] s_vid, [14] s_tpid_cmd,
 *                   [16:15] s_tpid_sel, [18:17] dot1p_cmd, [21:19] dot1p,
 *                   [22] dei_cmd, [23] dei, [29:24] ldpid, [30] cos_cmd,
 *                   [31] wan_dst
 *   word2 (0x1638): [0] permit_spid_en, [1] mac_sa_cmd, [4:2] mac_sa_sel,
 *                   [7:5] cos, [9:8] ip_ttl_zero_fwd_ctrl,
 *                   [10] ip_ttl_dec_cmd, [11] keep_o_lspid
 */
struct rtl_fe_mcast_fib_cfg {
	u8 c_vlan_cmd;
	u16 c_vid;
	u8 c_tpid_cmd;
	u8 c_tpid_sel;
	u8 c_dot1p_cmd;
	u8 c_dot1p;
	u8 c_dei_cmd;
	u8 c_dei;
	u16 pol_id;

	u8 s_vlan_cmd;
	u16 s_vid;
	u8 s_tpid_cmd;
	u8 s_tpid_sel;
	u8 dot1p_cmd;
	u8 dot1p;
	u8 dei_cmd;
	u8 dei;
	u8 ldpid;
	u8 cos_cmd;
	u8 wan_dst;

	u8 permit_spid_en;
	u8 mac_sa_cmd;
	u8 mac_sa_sel;
	u8 cos;
	u8 ip_ttl_zero_fwd_ctrl;
	u8 ip_ttl_dec_cmd;
	u8 keep_o_lspid;
};

/* One multicast group keyed by (MAC, VID), maintained from switchdev
 * PORT_MDB / HOST_MDB notifications and programmed into MCE + ARB MC FIB
 * when mcast_hw=1.
 */
struct rtl_fe_mcast_group {
	struct list_head list;
	u8 addr[ETH_ALEN];
	u16 vid;
	u16 mcgid;
	bool host_member;
	u8 ports[RTL_FE_MCAST_MASK_BYTES];
};

struct rtl_fe_mcast {
	DECLARE_BITMAP(mcgids, RTL_FE_MCAST_MCGIDS);
	struct rtl_fe_mcgid mcgid[RTL_FE_MCAST_MCGIDS];
	struct rtl_fe_mce mce[RTL_FE_MCAST_MCES];
	struct rtl_fe_fib fib[RTL_FE_MCAST_FIBS];
	struct list_head groups;
	/* serialises every pool, table and group mutation */
	struct mutex lock;
	bool ready;
	char last[RTL_FE_MCAST_LAST_LEN];
};

int rtl_fe_mcast_init(struct rtl_fe *fe);
int rtl_fe_mcast_prepare(struct rtl_fe *fe);
void rtl_fe_mcast_exit(struct rtl_fe *fe);
int rtl_fe_mcast_alloc(struct rtl_fe *fe, u16 *mcgid);
int rtl_fe_mcast_free(struct rtl_fe *fe, u16 mcgid);
int rtl_fe_mcast_program(struct rtl_fe *fe, u16 mcgid,
			 const u8 ports[RTL_FE_MCAST_MASK_BYTES],
			 const u32 *words);
int rtl_fe_mcast_member_set(struct rtl_fe *fe, u16 mcgid, int index,
			    const u32 words[RTL_FE_MCAST_FIB_WORDS]);
void rtl_fe_mcast_fib_pack(const struct rtl_fe_mcast_fib_cfg *cfg,
			   u32 words[RTL_FE_MCAST_FIB_WORDS]);
void rtl_fe_mcast_fib_unpack(const u32 words[RTL_FE_MCAST_FIB_WORDS],
			     struct rtl_fe_mcast_fib_cfg *cfg);
bool rtl_fe_mcast_is_data_mac(const u8 *mac);
bool rtl_fe_mcast_hw_enabled(void);
bool rtl_fe_mcast_lookup_hw(struct rtl_fe *fe, const u8 *addr, u16 vid,
			    u16 *hw_index, u8 *port_count);
void rtl_fe_mcast_mdb_event(struct rtl_fe *fe, unsigned long event, void *ptr);
void rtl_fe_mcast_port_gone(struct rtl_fe *fe, struct net_device *dev);
void rtl_fe_mcast_debugfs_init(struct rtl_fe *fe);

#endif /* RTL9617C_FE_MCAST_H */
