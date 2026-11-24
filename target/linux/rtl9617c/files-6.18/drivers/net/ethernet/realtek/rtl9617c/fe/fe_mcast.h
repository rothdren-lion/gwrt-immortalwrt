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

/* One multicast group keyed by (MAC, VID), maintained from the switchdev
 * MDB notifications.  Only the L2 port mask is tracked here: the ARB MC
 * FIB field semantics are UNKNOWN (U5), so no hardware entry is synthesised
 * from this state yet.
 */
struct rtl_fe_mcast_group {
	struct list_head list;
	u8 addr[ETH_ALEN];
	u16 vid;
	u16 mcgid;
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
void rtl_fe_mcast_exit(struct rtl_fe *fe);
int rtl_fe_mcast_alloc(struct rtl_fe *fe, u16 *mcgid);
int rtl_fe_mcast_free(struct rtl_fe *fe, u16 mcgid);
int rtl_fe_mcast_program(struct rtl_fe *fe, u16 mcgid,
			 const u8 ports[RTL_FE_MCAST_MASK_BYTES],
			 const u32 *words);
int rtl_fe_mcast_member_set(struct rtl_fe *fe, u16 mcgid, int index,
			    const u32 words[RTL_FE_MCAST_FIB_WORDS]);
void rtl_fe_mcast_mdb_event(struct rtl_fe *fe, unsigned long event, void *ptr);
void rtl_fe_mcast_port_gone(struct rtl_fe *fe, struct net_device *dev);
void rtl_fe_mcast_debugfs_init(struct rtl_fe *fe);

#endif /* RTL9617C_FE_MCAST_H */
