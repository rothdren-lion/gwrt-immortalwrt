// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * RTL9617C L3FE hardware multicast table manager.
 *
 * Three-level indirection recovered from ca-ne.ko (spec
 * phase0-re3-dualhdr-mc-napt6 §4):
 *
 *   software MCGID 0..1023          aal_sw_mcgid_alloc @ .text+0x4ee70
 *     -> MCE index table            256 x 2 words, table id 14, NE+0xaa64
 *                                  aal_hw_mcgid_new  @ .text+0x4fcc0
 *        -> ARB MC FIB              64 x 3 words, table id 15, NE+0x1634
 *                                  aal_arb_mc_fib_set @ .text+0x3ff80
 *
 * The MCE entry payload is the 64-bit bitmap of ARB MC FIB indices that
 * belong to the group: aal_hw_mcgid_free @ .text+0x4fb10 reads the entry,
 * walks 1 << i for i < 0x40, deletes every member entry and only then
 * deletes the MCE index.  The reverse order is mandatory; deleting the
 * MCE first would leave dangling member entries behind.
 *
 * The ARB MC FIB field layout is known bit for bit (§4.6, 75 used bits in
 * three words) but the semantic name of every field is UNKNOWN (U5).  This
 * driver therefore never synthesises port/VLAN fields: programming takes
 * raw words from the caller, the manager only keeps the membership bitmap,
 * and the debugfs "set"/"member" commands let an operator verify all three
 * words on the device bit by bit.
 *
 * Register block layout: the command/status register sits at the table
 * base and the data words follow below it in descending order, exactly as
 * every other generic table in this driver (RTL_L2FE_PP_ILPB_DATA(n) =
 * 0x11f8 - 4 * n).  The ARB MC FIB addresses are confirmed by the OEM
 * code; the MCE data addresses are derived from the same layout and are
 * marked TODO(probe) in fe_hw.h.
 */
#include <linux/bitmap.h>
#include <linux/debugfs.h>
#include <linux/delay.h>
#include <linux/etherdevice.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <net/switchdev.h>

#include "fe_priv.h"
#include "fe_mcast.h"

static bool mcast_hw;
module_param(mcast_hw, bool, 0644);
MODULE_PARM_DESC(mcast_hw,
		 "Program hardware MCE and ARB MC FIB entries on switchdev MDB events (default 0)");

/* --- mcast-pool-core: begin (tests/mcast-pool.py extracts this block) --- */

#ifndef RTL_FE_MCAST_PORT_NONE
#define RTL_FE_MCAST_PORT_NONE		0xff
#endif
#ifndef RTL_FE_MCAST_MCE_WORDS
#define RTL_FE_MCAST_MCE_WORDS		2
#endif
#ifndef RTL_FE_MCAST_FIB_WORDS
#define RTL_FE_MCAST_FIB_WORDS		3
#endif
#ifndef RTL_FE_MCAST_BITS_PER_BYTE
#define RTL_FE_MCAST_BITS_PER_BYTE	8
#endif
#define RTL_FE_MCAST_WORD_BYTES		4
#define RTL_FE_MCAST_WORD_BITS		32

static bool rtl_fe_mcast_port_test(const u8 ports[RTL_FE_MCAST_MASK_BYTES],
				   unsigned int port)
{
	return !!(ports[port / RTL_FE_MCAST_BITS_PER_BYTE] &
		  BIT(port % RTL_FE_MCAST_BITS_PER_BYTE));
}

static int rtl_fe_mcast_wait(struct rtl_fe *fe, unsigned int reg)
{
	unsigned int retry;

	/* aal_arb_mc_fib_set() polls bit31 of the command register up to
	 * 10000 times before it gives up.
	 */
	for (retry = 0; retry < RTL_FE_MCAST_POLL_COUNT; retry++) {
		if (!(rtl_fe_read(fe, reg) & RTL_NI_INDIRECT_BUSY))
			return 0;
		udelay(1);
	}
	return -ETIMEDOUT;
}

static int rtl_fe_mcast_table_read(struct rtl_fe *fe, unsigned int cmd_reg,
				   unsigned int data_reg, unsigned int index,
				   unsigned int index_mask, u32 *words,
				   unsigned int count)
{
	unsigned int i;
	int ret;

	if (index & ~index_mask)
		return -EINVAL;
	rtl_fe_write(fe, cmd_reg, RTL_NI_INDIRECT_ACCESS | index);
	ret = rtl_fe_mcast_wait(fe, cmd_reg);
	if (ret)
		return ret;
	for (i = 0; i < count; i++)
		words[i] = rtl_fe_read(fe,
				       data_reg - RTL_FE_MCAST_WORD_BYTES * i);
	return 0;
}

static int rtl_fe_mcast_table_write(struct rtl_fe *fe, unsigned int cmd_reg,
				    unsigned int data_reg, unsigned int index,
				    unsigned int index_mask, const u32 *words,
				    unsigned int count)
{
	unsigned int i;

	if (index & ~index_mask)
		return -EINVAL;
	for (i = 0; i < count; i++)
		rtl_fe_write(fe, data_reg - RTL_FE_MCAST_WORD_BYTES * i,
			     words[i]);
	rtl_fe_write(fe, cmd_reg, RTL_NI_INDIRECT_ACCESS |
		     RTL_NI_INDIRECT_WRITE | index);
	return rtl_fe_mcast_wait(fe, cmd_reg);
}

/* Every table write is followed by a read-back and a bit-for-bit compare.
 * A mismatch means the hardware did not store what was written; the caller
 * gets -EIO and must treat the entry as not programmed.
 */
static int rtl_fe_mcast_write_verify(struct rtl_fe *fe, unsigned int cmd_reg,
				     unsigned int data_reg,
				     unsigned int index,
				     unsigned int index_mask,
				     const u32 *words, unsigned int count)
{
	u32 readback[RTL_FE_MCAST_FIB_WORDS];
	unsigned int i;
	int ret;

	ret = rtl_fe_mcast_table_write(fe, cmd_reg, data_reg, index,
				       index_mask, words, count);
	if (ret)
		return ret;
	ret = rtl_fe_mcast_table_read(fe, cmd_reg, data_reg, index,
				      index_mask, readback, count);
	if (ret)
		return ret;
	for (i = 0; i < count; i++)
		if (readback[i] != words[i])
			return -EIO;
	return 0;
}

static int rtl_fe_mcast_mce_read(struct rtl_fe *fe, unsigned int index,
				 u32 words[RTL_FE_MCAST_MCE_WORDS])
{
	return rtl_fe_mcast_table_read(fe, RTL_FE_MCE_CMD, RTL_FE_MCE_DATA0,
				       index, RTL_FE_MCE_ENTRIES - 1, words,
				       RTL_FE_MCAST_MCE_WORDS);
}

static int rtl_fe_mcast_mce_write(struct rtl_fe *fe, unsigned int index,
				  const u32 words[RTL_FE_MCAST_MCE_WORDS])
{
	return rtl_fe_mcast_write_verify(fe, RTL_FE_MCE_CMD,
					 RTL_FE_MCE_DATA0, index,
					 RTL_FE_MCE_ENTRIES - 1, words,
					 RTL_FE_MCAST_MCE_WORDS);
}

static int rtl_fe_mcast_fib_write(struct rtl_fe *fe, unsigned int index,
				  const u32 words[RTL_FE_MCAST_FIB_WORDS])
{
	unsigned int i;
	int ret;

	ret = rtl_fe_mcast_write_verify(fe, RTL_FE_ARB_MC_FIB_CMD,
					RTL_FE_ARB_MC_FIB_DATA0, index,
					RTL_FE_ARB_MC_FIB_ENTRIES - 1,
					words, RTL_FE_MCAST_FIB_WORDS);
	if (ret)
		return ret;
	for (i = 0; i < RTL_FE_MCAST_FIB_WORDS; i++)
		fe->mcast->fib[index].words[i] = words[i];
	return 0;
}

/* Deleting an ARB MC FIB member clears all three words, then the slot is
 * released.  TODO(U5): ca-ne.ko has no field-name printer for this table,
 * so which bit marks a live entry is not recoverable from the artifact;
 * clearing the whole entry is the conservative equivalent and is verified
 * by read-back.
 */
static int rtl_fe_mcast_fib_delete(struct rtl_fe *fe, unsigned int index)
{
	static const u32 zero[RTL_FE_MCAST_FIB_WORDS];
	struct rtl_fe_fib *fib = &fe->mcast->fib[index];
	unsigned int i;
	int ret;

	ret = rtl_fe_mcast_write_verify(fe, RTL_FE_ARB_MC_FIB_CMD,
					RTL_FE_ARB_MC_FIB_DATA0, index,
					RTL_FE_ARB_MC_FIB_ENTRIES - 1,
					zero, RTL_FE_MCAST_FIB_WORDS);
	if (ret)
		return ret;
	fib->used = false;
	fib->mcgid = RTL_FE_MCAST_NONE;
	fib->port = RTL_FE_MCAST_PORT_NONE;
	for (i = 0; i < RTL_FE_MCAST_FIB_WORDS; i++)
		fib->words[i] = 0;
	return 0;
}

static int rtl_fe_mcast_mce_delete(struct rtl_fe *fe, unsigned int index)
{
	static const u32 zero[RTL_FE_MCAST_MCE_WORDS];
	struct rtl_fe_mce *mce = &fe->mcast->mce[index];
	int ret;

	ret = rtl_fe_mcast_write_verify(fe, RTL_FE_MCE_CMD, RTL_FE_MCE_DATA0,
					index, RTL_FE_MCE_ENTRIES - 1,
					zero, RTL_FE_MCAST_MCE_WORDS);
	if (ret)
		return ret;
	mce->used = false;
	mce->mcgid = RTL_FE_MCAST_NONE;
	return 0;
}

static u64 rtl_fe_mcast_members(const struct rtl_fe_mcast *m, u16 mcgid)
{
	u64 members = 0;
	unsigned int i;

	for (i = 0; i < RTL_FE_MCAST_FIBS; i++)
		if (m->fib[i].used && m->fib[i].mcgid == mcgid)
			members |= BIT_ULL(i);
	return members;
}

static int rtl_fe_mcast_mce_write_members(struct rtl_fe *fe,
					  unsigned int index, u64 members)
{
	u32 words[RTL_FE_MCAST_MCE_WORDS];

	words[0] = lower_32_bits(members);
	words[1] = upper_32_bits(members);
	return rtl_fe_mcast_mce_write(fe, index, words);
}

static int rtl_fe_mcast_mce_slot_alloc(struct rtl_fe *fe, u16 mcgid,
				       unsigned int *index)
{
	struct rtl_fe_mcast *m = fe->mcast;
	unsigned int i;

	for (i = 0; i < RTL_FE_MCAST_MCES; i++) {
		if (m->mce[i].used)
			continue;
		m->mce[i].used = true;
		m->mce[i].mcgid = mcgid;
		*index = i;
		return 0;
	}
	return -ENOSPC;
}

static int rtl_fe_mcast_fib_slot_alloc(struct rtl_fe *fe, u16 mcgid,
				       unsigned int port, unsigned int *index)
{
	struct rtl_fe_mcast *m = fe->mcast;
	unsigned int i;

	for (i = 0; i < RTL_FE_MCAST_FIBS; i++) {
		if (m->fib[i].used)
			continue;
		m->fib[i].used = true;
		m->fib[i].mcgid = mcgid;
		m->fib[i].port = port;
		*index = i;
		return 0;
	}
	return -ENOSPC;
}

static int rtl_fe_mcast_alloc_locked(struct rtl_fe *fe, u16 *mcgid)
{
	struct rtl_fe_mcast *m = fe->mcast;
	unsigned int index;

	index = find_first_zero_bit(m->mcgids, RTL_FE_MCAST_MCGIDS);
	if (index >= RTL_FE_MCAST_MCGIDS)
		return -ENOSPC;
	__set_bit(index, m->mcgids);
	m->mcgid[index].users = 1;
	m->mcgid[index].hw_index = RTL_FE_MCAST_NONE;
	m->mcgid[index].prev_index = RTL_FE_MCAST_NONE;
	*mcgid = index;
	return 0;
}

/* Reverse-order teardown of one hardware binding: every ARB MC FIB member
 * first, then the MCE index, then cur/prev = 0xffff.  The member list is
 * read back from the hardware MCE entry instead of trusting software state,
 * exactly like the OEM free path.  A partially completed teardown is
 * idempotent: slots that were already released are skipped.
 */
static int rtl_fe_mcast_binding_free(struct rtl_fe *fe, u16 mcgid,
				     unsigned int index)
{
	u32 entry[RTL_FE_MCAST_MCE_WORDS];
	u64 members;
	unsigned int i;
	int ret, err = 0;

	ret = rtl_fe_mcast_mce_read(fe, index, entry);
	if (ret)
		return ret;
	members = (u64)entry[0] | ((u64)entry[1] << RTL_FE_MCAST_WORD_BITS);

	for (i = 0; i < RTL_FE_MCAST_FIBS; i++) {
		bool owned = fe->mcast->fib[i].used &&
			     fe->mcast->fib[i].mcgid == mcgid;
		bool listed = !!(members & BIT_ULL(i));

		if (!owned) {
			/* A listed bit whose slot is still allocated belongs to
			 * another group: the software and hardware views have
			 * diverged.  A listed bit whose slot is already free was
			 * cleaned up by an earlier interrupted free().
			 */
			if (listed && fe->mcast->fib[i].used)
				err = -EIO;
			continue;
		}
		ret = rtl_fe_mcast_fib_delete(fe, i);
		if (ret && !err)
			err = ret;
	}
	ret = rtl_fe_mcast_mce_delete(fe, index);
	if (ret && !err)
		err = ret;
	if (!err) {
		fe->mcast->mcgid[mcgid].prev_index = RTL_FE_MCAST_NONE;
		fe->mcast->mcgid[mcgid].hw_index = RTL_FE_MCAST_NONE;
	}
	return err;
}

static int rtl_fe_mcast_free_locked(struct rtl_fe *fe, u16 mcgid)
{
	struct rtl_fe_mcgid *entry;
	int ret;

	if (mcgid >= RTL_FE_MCAST_MCGIDS || !test_bit(mcgid, fe->mcast->mcgids))
		return -EINVAL;
	entry = &fe->mcast->mcgid[mcgid];
	if (!entry->users)
		return -EINVAL;
	if (--entry->users)
		return 0;
	if (entry->hw_index != RTL_FE_MCAST_NONE) {
		ret = rtl_fe_mcast_binding_free(fe, mcgid, entry->hw_index);
		if (ret) {
			/* Keep the reference so the caller can retry. */
			entry->users = 1;
			return ret;
		}
	}
	__clear_bit(mcgid, fe->mcast->mcgids);
	return 0;
}

static unsigned int
rtl_fe_mcast_mask_weight(const u8 ports[RTL_FE_MCAST_MASK_BYTES])
{
	unsigned int port, weight = 0;

	for (port = 0; port < RTL_FE_MCAST_PORTS; port++)
		if (rtl_fe_mcast_port_test(ports, port))
			weight++;
	return weight;
}

/* Abort path for a failed program: the MCE entry is detached and every
 * member slot owned by the group is released.  The binding itself stays
 * allocated so the caller can retry.
 */
static void rtl_fe_mcast_group_clear(struct rtl_fe *fe, u16 mcgid)
{
	struct rtl_fe_mcast *m = fe->mcast;
	unsigned int i;

	if (m->mcgid[mcgid].hw_index != RTL_FE_MCAST_NONE)
		rtl_fe_mcast_mce_write_members(fe, m->mcgid[mcgid].hw_index, 0);
	for (i = 0; i < RTL_FE_MCAST_FIBS; i++) {
		if (!m->fib[i].used || m->fib[i].mcgid != mcgid)
			continue;
		if (rtl_fe_mcast_fib_delete(fe, i)) {
			m->fib[i].used = false;
			m->fib[i].mcgid = RTL_FE_MCAST_NONE;
			m->fib[i].port = RTL_FE_MCAST_PORT_NONE;
		}
	}
}

/* Rebuild one group: bind an MCE slot on first use, detach the old member
 * bitmap, release the old member entries, write the new member entries and
 * finally publish the new bitmap.  The live MCE entry never references an
 * entry that has already been cleared.
 */
static int rtl_fe_mcast_program_locked(struct rtl_fe *fe, u16 mcgid,
				       const u8 ports[RTL_FE_MCAST_MASK_BYTES],
				       const u32 *words)
{
	static const u32 zero[RTL_FE_MCAST_FIB_WORDS];
	struct rtl_fe_mcast *m = fe->mcast;
	struct rtl_fe_mcgid *entry;
	unsigned int i, index, used_by_others = 0;
	u64 members;
	int ret;

	if (mcgid >= RTL_FE_MCAST_MCGIDS || !test_bit(mcgid, m->mcgids))
		return -EINVAL;
	entry = &m->mcgid[mcgid];
	if (!entry->users)
		return -EINVAL;

	/* Capacity check before anything is disturbed: a group that cannot
	 * fit must leave the live members untouched.
	 */
	for (i = 0; i < RTL_FE_MCAST_FIBS; i++)
		if (m->fib[i].used && m->fib[i].mcgid != mcgid)
			used_by_others++;
	if (used_by_others + rtl_fe_mcast_mask_weight(ports) >
	    RTL_FE_MCAST_FIBS)
		return -ENOSPC;

	if (entry->hw_index == RTL_FE_MCAST_NONE) {
		ret = rtl_fe_mcast_mce_slot_alloc(fe, mcgid, &index);
		if (ret)
			return ret;
		entry->hw_index = index;
	}

	members = rtl_fe_mcast_members(m, mcgid);
	if (members) {
		ret = rtl_fe_mcast_mce_write_members(fe, entry->hw_index, 0);
		if (ret)
			return ret;
	}
	for (i = 0; i < RTL_FE_MCAST_FIBS; i++) {
		if (!m->fib[i].used || m->fib[i].mcgid != mcgid)
			continue;
		ret = rtl_fe_mcast_fib_delete(fe, i);
		if (ret)
			return ret;
	}
	for (i = 0; i < RTL_FE_MCAST_PORTS; i++) {
		if (!rtl_fe_mcast_port_test(ports, i))
			continue;
		ret = rtl_fe_mcast_fib_slot_alloc(fe, mcgid, i, &index);
		if (ret)
			goto abort;
		ret = rtl_fe_mcast_fib_write(fe, index, words ? words : zero);
		if (ret)
			goto abort;
	}
	ret = rtl_fe_mcast_mce_write_members(fe, entry->hw_index,
					     rtl_fe_mcast_members(m, mcgid));
	if (ret)
		goto abort;
	return 0;

abort:
	rtl_fe_mcast_group_clear(fe, mcgid);
	return ret;
}

static int rtl_fe_mcast_member_set_locked(struct rtl_fe *fe, u16 mcgid,
					  int index,
					  const u32 words[RTL_FE_MCAST_FIB_WORDS])
{
	struct rtl_fe_mcast *m = fe->mcast;
	struct rtl_fe_mcgid *entry;
	unsigned int i;
	bool fresh;
	int ret;

	if (mcgid >= RTL_FE_MCAST_MCGIDS || !test_bit(mcgid, m->mcgids))
		return -EINVAL;
	entry = &m->mcgid[mcgid];
	if (!entry->users)
		return -EINVAL;

	if (index < 0) {
		/* "set" without an explicit slot: the group must own either no
		 * member (a free slot is picked) or exactly one member.
		 */
		int found = -1;

		for (i = 0; i < RTL_FE_MCAST_FIBS; i++) {
			if (!m->fib[i].used || m->fib[i].mcgid != mcgid)
				continue;
			if (found >= 0)
				return -EINVAL;
			found = i;
		}
		if (found >= 0) {
			index = found;
		} else {
			for (i = 0; i < RTL_FE_MCAST_FIBS; i++) {
				if (!m->fib[i].used) {
					index = i;
					break;
				}
			}
			if (i == RTL_FE_MCAST_FIBS)
				return -ENOSPC;
		}
	} else if ((unsigned int)index >= RTL_FE_MCAST_FIBS) {
		return -EINVAL;
	}

	if (m->fib[index].used && m->fib[index].mcgid != mcgid)
		return -EBUSY;

	if (entry->hw_index == RTL_FE_MCAST_NONE) {
		ret = rtl_fe_mcast_mce_slot_alloc(fe, mcgid, &i);
		if (ret)
			return ret;
		entry->hw_index = i;
	}

	fresh = !m->fib[index].used;
	if (fresh) {
		m->fib[index].used = true;
		m->fib[index].mcgid = mcgid;
		m->fib[index].port = RTL_FE_MCAST_PORT_NONE;
	}
	ret = rtl_fe_mcast_fib_write(fe, index, words);
	if (ret) {
		if (fresh) {
			m->fib[index].used = false;
			m->fib[index].mcgid = RTL_FE_MCAST_NONE;
		}
		return ret;
	}
	return rtl_fe_mcast_mce_write_members(fe, entry->hw_index,
					      rtl_fe_mcast_members(m, mcgid));
}

/* --- mcast-pool-core: end --- */

#define RTL_FE_MCAST_CMD_BUF_LEN	128
#define RTL_FE_ARB_FIB_W1_LDPID_SHIFT	24
#define RTL_FE_ARB_FIB_W1_LDPID_MASK	0x3fu
#define RTL_FE_ARB_FIB_W1_KEEP_TPID	BIT(30)

/*
 * Synthesise the 3-word ARB MC FIB entry for an unmodified L2 egress port
 * forward action, recovered from ca-ne.ko _aal_arb_mc_fib_action_add @ 0x4f020:
 *   word0 = 0
 *   word1 = BIT(30) (action[+10].bit0 == 0, keep outer TPID) | (ldpid << 24)
 *   word2 = 0
 */
static void rtl_fe_mcast_fib_encode_port(unsigned int port,
					 u32 words[RTL_FE_MCAST_FIB_WORDS])
{
	words[0] = 0;
	words[1] = RTL_FE_ARB_FIB_W1_KEEP_TPID |
		   ((port & RTL_FE_ARB_FIB_W1_LDPID_MASK) <<
		    RTL_FE_ARB_FIB_W1_LDPID_SHIFT);
	words[2] = 0;
}

static int rtl_fe_mcast_program_ports_locked(struct rtl_fe *fe, u16 mcgid,
					     const u8 ports[RTL_FE_MCAST_MASK_BYTES])
{
	struct rtl_fe_mcast *m = fe->mcast;
	u32 words[RTL_FE_MCAST_FIB_WORDS];
	unsigned int i;
	int ret;

	ret = rtl_fe_mcast_program_locked(fe, mcgid, ports, NULL);
	if (ret)
		return ret;

	for (i = 0; i < RTL_FE_MCAST_FIBS; i++) {
		if (!m->fib[i].used || m->fib[i].mcgid != mcgid)
			continue;
		rtl_fe_mcast_fib_encode_port(m->fib[i].port, words);
		ret = rtl_fe_mcast_fib_write(fe, i, words);
		if (ret) {
			rtl_fe_mcast_group_clear(fe, mcgid);
			return ret;
		}
	}
	return 0;
}

static int rtl_fe_mcast_fib_read(struct rtl_fe *fe, unsigned int index,
				 u32 words[RTL_FE_MCAST_FIB_WORDS])
{
	return rtl_fe_mcast_table_read(fe, RTL_FE_ARB_MC_FIB_CMD,
				       RTL_FE_ARB_MC_FIB_DATA0, index,
				       RTL_FE_ARB_MC_FIB_ENTRIES - 1, words,
				       RTL_FE_MCAST_FIB_WORDS);
}

static int rtl_fe_mcast_probe(struct rtl_fe *fe)
{
	u32 words[RTL_FE_MCAST_FIB_WORDS];
	int ret;

	/* Read-only probe of both tables.  A timeout here means the L3PE
	 * tables are not clocked yet; init keeps the software manager and the
	 * first program attempt retries.
	 */
	ret = rtl_fe_mcast_mce_read(fe, 0, words);
	if (ret)
		return ret;
	return rtl_fe_mcast_fib_read(fe, 0, words);
}

static int rtl_fe_mcast_ready_locked(struct rtl_fe *fe)
{
	struct rtl_fe_mcast *m = fe->mcast;
	int ret;

	if (m->ready)
		return 0;
	ret = rtl_fe_mcast_probe(fe);
	if (ret)
		return ret;
	m->ready = true;
	return 0;
}

int rtl_fe_mcast_alloc(struct rtl_fe *fe, u16 *mcgid)
{
	struct rtl_fe_mcast *m;
	int ret;

	if (!fe || !fe->mcast || !mcgid)
		return -ENODEV;
	m = fe->mcast;
	mutex_lock(&m->lock);
	ret = rtl_fe_mcast_alloc_locked(fe, mcgid);
	mutex_unlock(&m->lock);
	return ret;
}

int rtl_fe_mcast_free(struct rtl_fe *fe, u16 mcgid)
{
	struct rtl_fe_mcast *m;
	int ret;

	if (!fe || !fe->mcast)
		return -ENODEV;
	m = fe->mcast;
	mutex_lock(&m->lock);
	ret = rtl_fe_mcast_free_locked(fe, mcgid);
	mutex_unlock(&m->lock);
	return ret;
}

int rtl_fe_mcast_program(struct rtl_fe *fe, u16 mcgid,
			 const u8 ports[RTL_FE_MCAST_MASK_BYTES],
			 const u32 *words)
{
	struct rtl_fe_mcast *m;
	int ret;

	if (!fe || !fe->mcast)
		return -ENODEV;
	if (!ports)
		return -EINVAL;
	m = fe->mcast;
	mutex_lock(&m->lock);
	ret = rtl_fe_mcast_ready_locked(fe);
	if (!ret)
		ret = rtl_fe_mcast_program_locked(fe, mcgid, ports, words);
	mutex_unlock(&m->lock);
	return ret;
}

int rtl_fe_mcast_member_set(struct rtl_fe *fe, u16 mcgid, int index,
			    const u32 words[RTL_FE_MCAST_FIB_WORDS])
{
	struct rtl_fe_mcast *m;
	int ret;

	if (!fe || !fe->mcast)
		return -ENODEV;
	if (!words)
		return -EINVAL;
	m = fe->mcast;
	mutex_lock(&m->lock);
	ret = rtl_fe_mcast_ready_locked(fe);
	if (!ret)
		ret = rtl_fe_mcast_member_set_locked(fe, mcgid, index, words);
	mutex_unlock(&m->lock);
	return ret;
}

int rtl_fe_mcast_init(struct rtl_fe *fe)
{
	struct rtl_fe_mcast *m;
	unsigned int i;

	m = kzalloc(sizeof(*m), GFP_KERNEL);
	if (!m)
		return -ENOMEM;
	mutex_init(&m->lock);
	INIT_LIST_HEAD(&m->groups);
	for (i = 0; i < RTL_FE_MCAST_MCGIDS; i++) {
		m->mcgid[i].hw_index = RTL_FE_MCAST_NONE;
		m->mcgid[i].prev_index = RTL_FE_MCAST_NONE;
	}
	strscpy(m->last, "init", sizeof(m->last));

	m->ready = rtl_fe_mcast_probe(fe) == 0;
	fe->mcast = m;
	if (!m->ready)
		dev_warn(fe->dev,
			 "mcast: L3PE multicast tables not ready; programming deferred\n");
	return 0;
}

void rtl_fe_mcast_exit(struct rtl_fe *fe)
{
	struct rtl_fe_mcast *m;
	struct rtl_fe_mcast_group *group, *next;
	unsigned int i;
	int ret;

	if (!fe || !fe->mcast)
		return;
	m = fe->mcast;

	mutex_lock(&m->lock);
	list_for_each_entry_safe(group, next, &m->groups, list) {
		list_del(&group->list);
		kfree(group);
	}
	/* Release every remaining MCGID through the normal free path, in
	 * reverse index order, after the flows have been stopped by
	 * rtl_fe_destroy().
	 */
	for (i = RTL_FE_MCAST_MCGIDS; i-- > 0;) {
		if (!test_bit(i, m->mcgids))
			continue;
		m->mcgid[i].users = 1;
		ret = rtl_fe_mcast_free_locked(fe, i);
		if (ret)
			dev_warn(fe->dev, "mcast: failed to release MCGID %u: %d\n",
				 i, ret);
	}
	mutex_unlock(&m->lock);
	fe->mcast = NULL;
	kfree(m);
}

static void rtl_fe_mcast_port_set(u8 ports[RTL_FE_MCAST_MASK_BYTES],
				  unsigned int port)
{
	ports[port / RTL_FE_MCAST_BITS_PER_BYTE] |=
		BIT(port % RTL_FE_MCAST_BITS_PER_BYTE);
}

static void rtl_fe_mcast_port_clear(u8 ports[RTL_FE_MCAST_MASK_BYTES],
				    unsigned int port)
{
	ports[port / RTL_FE_MCAST_BITS_PER_BYTE] &=
		~BIT(port % RTL_FE_MCAST_BITS_PER_BYTE);
}

static bool rtl_fe_mcast_mask_empty(const u8 ports[RTL_FE_MCAST_MASK_BYTES])
{
	unsigned int i;

	for (i = 0; i < RTL_FE_MCAST_MASK_BYTES; i++)
		if (ports[i])
			return false;
	return true;
}

/*
 * Switchdev MDB hook.  The bridge defers MDB objects (SWITCHDEV_F_DEFER),
 * so this runs from switchdev's deferred workqueue, i.e. in process
 * context and under rtnl_lock().  Only the software group state is updated:
 * the ARB MC FIB fields needed to turn a port into hardware member words
 * are still UNKNOWN (U5), so nothing is claimed to the bridge and no
 * hardware entry is written here.  The caller keeps returning NOTIFY_DONE,
 * which leaves the group in software flooding.
 */
void rtl_fe_mcast_mdb_event(struct rtl_fe *fe, unsigned long event, void *ptr)
{
	struct switchdev_notifier_port_obj_info *info = ptr;
	const struct switchdev_obj_port_mdb *mdb;
	struct rtl_fe_mcast_group *group, *found;
	struct net_device *dev;
	struct rtl_fe_port *port;
	struct rtl_fe_mcast *m;
	unsigned int source;
	u16 mcgid;
	int ret;

	if (!fe || !fe->mcast || !info || !info->obj)
		return;
	if (info->obj->id != SWITCHDEV_OBJ_ID_PORT_MDB)
		return;
	if (event != SWITCHDEV_PORT_OBJ_ADD && event != SWITCHDEV_PORT_OBJ_DEL)
		return;

	mdb = SWITCHDEV_OBJ_PORT_MDB(info->obj);
	if (!is_multicast_ether_addr(mdb->addr))
		return;
	dev = switchdev_notifier_info_to_dev(&info->info);
	if (!dev)
		return;

	/* Resolve the bridge port before taking the manager lock; the FE port
	 * list is protected by fe->lock.  Port source ids are the hardware
	 * port numbers used by the ingress tables (0..7 today).
	 */
	mutex_lock(&fe->lock);
	port = rtl_fe_port_find(fe, dev);
	source = port ? port->source : RTL_FE_MCAST_PORTS;
	mutex_unlock(&fe->lock);
	if (source >= RTL_FE_MCAST_PORTS)
		return;

	/* Groups are keyed by (MAC, VID) only.  The L2 multicast table is
	 * global to the switch, so the same group/VLAN seen through two
	 * bridges maps onto one hardware entry anyway.
	 */
	m = fe->mcast;
	mutex_lock(&m->lock);
	found = NULL;
	list_for_each_entry(group, &m->groups, list) {
		if (group->vid == mdb->vid &&
		    ether_addr_equal(group->addr, mdb->addr)) {
			found = group;
			break;
		}
	}

	if (event == SWITCHDEV_PORT_OBJ_ADD) {
		if (!found) {
			found = kzalloc(sizeof(*found), GFP_KERNEL);
			if (!found)
				goto unlock;
			ret = rtl_fe_mcast_alloc_locked(fe, &mcgid);
			if (ret) {
				kfree(found);
				goto unlock;
			}
			ether_addr_copy(found->addr, mdb->addr);
			found->vid = mdb->vid;
			found->mcgid = mcgid;
			list_add_tail(&found->list, &m->groups);
			dev_dbg(fe->dev, "mcast: MDB %pM vid %u -> MCGID %u\n",
				mdb->addr, mdb->vid, mcgid);
		}
		rtl_fe_mcast_port_set(found->ports, source);
		if (mcast_hw && !rtl_fe_mcast_ready_locked(fe))
			rtl_fe_mcast_program_ports_locked(fe, found->mcgid,
							  found->ports);
	} else {
		if (!found)
			goto unlock;
		rtl_fe_mcast_port_clear(found->ports, source);
		if (rtl_fe_mcast_mask_empty(found->ports)) {
			ret = rtl_fe_mcast_free_locked(fe, found->mcgid);
			if (ret)
				dev_warn(fe->dev,
					 "mcast: MDB %pM vid %u release failed: %d\n",
					 mdb->addr, mdb->vid, ret);
			dev_dbg(fe->dev, "mcast: MDB %pM vid %u -> MCGID %u released\n",
				mdb->addr, mdb->vid, found->mcgid);
			list_del(&found->list);
			kfree(found);
		} else if (mcast_hw && !rtl_fe_mcast_ready_locked(fe)) {
			rtl_fe_mcast_program_ports_locked(fe, found->mcgid,
							  found->ports);
		}
	}
unlock:
	mutex_unlock(&m->lock);
}

/*
 * Drop a port from every software group.  Called from the netdev notifier
 * when the device is unregistered: a stale port bit would otherwise keep a
 * group reference alive and, worse, make a future port that reuses the same
 * source id a member of an old group.
 */
void rtl_fe_mcast_port_gone(struct rtl_fe *fe, struct net_device *dev)
{
	struct rtl_fe_mcast_group *group, *next;
	struct rtl_fe_port *port;
	struct rtl_fe_mcast *m;
	unsigned int source;

	if (!fe || !fe->mcast || !dev)
		return;
	mutex_lock(&fe->lock);
	port = rtl_fe_port_find(fe, dev);
	source = port ? port->source : RTL_FE_MCAST_PORTS;
	mutex_unlock(&fe->lock);
	if (source >= RTL_FE_MCAST_PORTS)
		return;

	m = fe->mcast;
	mutex_lock(&m->lock);
	list_for_each_entry_safe(group, next, &m->groups, list) {
		if (!rtl_fe_mcast_port_test(group->ports, source))
			continue;
		rtl_fe_mcast_port_clear(group->ports, source);
		if (!rtl_fe_mcast_mask_empty(group->ports)) {
			if (mcast_hw && !rtl_fe_mcast_ready_locked(fe))
				rtl_fe_mcast_program_ports_locked(fe,
								  group->mcgid,
								  group->ports);
			continue;
		}
		if (rtl_fe_mcast_free_locked(fe, group->mcgid))
			dev_warn(fe->dev,
				 "mcast: port %u group %pM vid %u release failed\n",
				 source, group->addr, group->vid);
		list_del(&group->list);
		kfree(group);
	}
	mutex_unlock(&m->lock);
}

static int rtl_fe_mcast_snapshot(struct rtl_fe *fe, u16 mcgid)
{
	struct rtl_fe_mcast *m = fe->mcast;
	struct rtl_fe_mcgid *entry;
	u32 mce[RTL_FE_MCAST_MCE_WORDS], words[RTL_FE_MCAST_FIB_WORDS];
	u64 members;
	unsigned int i;
	int len, ret;

	if (mcgid >= RTL_FE_MCAST_MCGIDS || !test_bit(mcgid, m->mcgids))
		return -EINVAL;
	entry = &m->mcgid[mcgid];
	if (entry->hw_index == RTL_FE_MCAST_NONE) {
		snprintf(m->last, sizeof(m->last), "mcgid %u: no MCE slot bound",
			 mcgid);
		return 0;
	}
	ret = rtl_fe_mcast_mce_read(fe, entry->hw_index, mce);
	if (ret)
		return ret;
	members = (u64)mce[0] | ((u64)mce[1] << RTL_FE_MCAST_WORD_BITS);
	len = scnprintf(m->last, sizeof(m->last),
			"mcgid %u mce %u mce_words %08x %08x members 0x%016llx",
			mcgid, entry->hw_index, mce[0], mce[1],
			(unsigned long long)members);
	for (i = 0; i < RTL_FE_MCAST_FIBS; i++) {
		if (!(members & BIT_ULL(i)))
			continue;
		ret = rtl_fe_mcast_fib_read(fe, i, words);
		if (ret)
			return ret;
		if (len >= (int)sizeof(m->last))
			break;
		len += scnprintf(m->last + len, sizeof(m->last) - len,
				 " fib[%u]=%08x,%08x,%08x",
				 i, words[0], words[1], words[2]);
	}
	return 0;
}

static int rtl_fe_mcast_show(struct seq_file *s, void *unused)
{
	struct rtl_fe *fe = s->private;
	struct rtl_fe_mcast *m = fe->mcast;
	struct rtl_fe_mcast_group *group;
	u64 members;
	unsigned int i;

	if (!m)
		return -ENODEV;
	mutex_lock(&m->lock);
	seq_printf(s, "ready=%u last: %s\n", m->ready, m->last);
	seq_puts(s, "mcgid bitmap:");
	for (i = 0; i < BITS_TO_LONGS(RTL_FE_MCAST_MCGIDS); i++)
		seq_printf(s, " %016lx", m->mcgids[i]);
	seq_putc(s, '\n');
	seq_puts(s, "allocated:");
	for (i = 0; i < RTL_FE_MCAST_MCGIDS; i++)
		if (test_bit(i, m->mcgids))
			seq_printf(s, " %u", i);
	seq_putc(s, '\n');
	for (i = 0; i < RTL_FE_MCAST_MCES; i++) {
		if (!m->mce[i].used)
			continue;
		members = rtl_fe_mcast_members(m, m->mce[i].mcgid);
		seq_printf(s, "mce %u: mcgid=%u members=0x%016llx\n",
			   i, m->mce[i].mcgid, (unsigned long long)members);
	}
	for (i = 0; i < RTL_FE_MCAST_FIBS; i++) {
		if (!m->fib[i].used)
			continue;
		seq_printf(s, "fib %u: mcgid=%u port=%u words=%08x,%08x,%08x\n",
			   i, m->fib[i].mcgid, m->fib[i].port,
			   m->fib[i].words[0], m->fib[i].words[1],
			   m->fib[i].words[2]);
	}
	list_for_each_entry(group, &m->groups, list) {
		seq_printf(s, "group %pM vid=%u mcgid=%u ports=",
			   group->addr, group->vid, group->mcgid);
		for (i = 0; i < RTL_FE_MCAST_MASK_BYTES; i++)
			seq_printf(s, "%02x", group->ports[i]);
		seq_putc(s, '\n');
	}
	mutex_unlock(&m->lock);
	return 0;
}

static char *rtl_fe_mcast_token(char **cursor)
{
	char *token, *p = *cursor;

	while (*p == ' ' || *p == '\t')
		p++;
	if (!*p) {
		*cursor = p;
		return NULL;
	}
	token = p;
	while (*p && *p != ' ' && *p != '\t')
		p++;
	if (*p)
		*p++ = '\0';
	*cursor = p;
	return token;
}

static int rtl_fe_mcast_parse_words(char **cursor,
				    u32 words[RTL_FE_MCAST_FIB_WORDS])
{
	char *a;
	unsigned int i;

	for (i = 0; i < RTL_FE_MCAST_FIB_WORDS; i++) {
		a = rtl_fe_mcast_token(cursor);
		if (!a || kstrtou32(a, 0, &words[i]))
			return -EINVAL;
	}
	return rtl_fe_mcast_token(cursor) ? -EINVAL : 0;
}

/* Usage, one command per write (reading the file prints the dump):
 *   alloc                                  allocate one software MCGID
 *   free <mcgid>                           drop one reference
 *   dump                                   no-op; the read side dumps state
 *   set <mcgid> <w0> <w1> <w2>             raw ARB MC FIB words for the
 *                                          group's only member, or for a
 *                                          new member when it has none
 *   member <mcgid> <idx> <w0> <w1> <w2>    raw words for one explicit slot
 *   program <mcgid> <mask> <w0> <w1> <w2>  rebuild the port mask; the 64-bit
 *                                          mask is little-endian, bit N is
 *                                          port source N
 *   get <mcgid>                            read MCE + member words back
 * The raw ARB MC FIB fields are the OEM bit order; their meaning is still
 * UNKNOWN (U5), so no value written here claims a semantic.
 */
static ssize_t rtl_fe_mcast_write(struct file *file, const char __user *ubuf,
				  size_t count, loff_t *ppos)
{
	struct seq_file *s = file->private_data;
	struct rtl_fe *fe = s->private;
	struct rtl_fe_mcast *m = fe->mcast;
	char buf[RTL_FE_MCAST_CMD_BUF_LEN], *cursor, *cmd, *a;
	u32 words[RTL_FE_MCAST_FIB_WORDS];
	unsigned int slot;
	u64 mask;
	u16 mcgid;
	int ret;

	if (!m)
		return -ENODEV;
	if (!count || count >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;
	buf[count] = '\0';

	cursor = buf;
	cmd = rtl_fe_mcast_token(&cursor);
	if (!cmd)
		return -EINVAL;

	if (sysfs_streq(cmd, "dump")) {
		if (rtl_fe_mcast_token(&cursor))
			return -EINVAL;
		return count;
	}

	if (sysfs_streq(cmd, "alloc")) {
		if (rtl_fe_mcast_token(&cursor))
			return -EINVAL;
		ret = rtl_fe_mcast_alloc(fe, &mcgid);
		if (!ret) {
			snprintf(m->last, sizeof(m->last), "allocated MCGID %u",
				 mcgid);
			dev_info(fe->dev, "mcast: allocated MCGID %u\n", mcgid);
		} else {
			snprintf(m->last, sizeof(m->last), "alloc failed: %d",
				 ret);
		}
		return ret ? ret : count;
	}

	a = rtl_fe_mcast_token(&cursor);
	if (!a || kstrtou16(a, 0, &mcgid))
		return -EINVAL;

	if (sysfs_streq(cmd, "free")) {
		if (rtl_fe_mcast_token(&cursor))
			return -EINVAL;
		ret = rtl_fe_mcast_free(fe, mcgid);
	} else if (sysfs_streq(cmd, "get")) {
		if (rtl_fe_mcast_token(&cursor))
			return -EINVAL;
		mutex_lock(&m->lock);
		ret = rtl_fe_mcast_ready_locked(fe);
		if (!ret)
			ret = rtl_fe_mcast_snapshot(fe, mcgid);
		mutex_unlock(&m->lock);
	} else if (sysfs_streq(cmd, "set")) {
		ret = rtl_fe_mcast_parse_words(&cursor, words);
		if (!ret)
			ret = rtl_fe_mcast_member_set(fe, mcgid, -1, words);
	} else if (sysfs_streq(cmd, "member")) {
		a = rtl_fe_mcast_token(&cursor);
		if (!a || kstrtouint(a, 0, &slot) || slot >= RTL_FE_MCAST_FIBS)
			return -EINVAL;
		ret = rtl_fe_mcast_parse_words(&cursor, words);
		if (!ret)
			ret = rtl_fe_mcast_member_set(fe, mcgid, slot, words);
	} else if (sysfs_streq(cmd, "program")) {
		u8 ports[RTL_FE_MCAST_MASK_BYTES];

		a = rtl_fe_mcast_token(&cursor);
		if (!a || kstrtou64(a, 0, &mask))
			return -EINVAL;
		ret = rtl_fe_mcast_parse_words(&cursor, words);
		if (ret)
			return ret;
		memcpy(ports, &mask, sizeof(ports));
		ret = rtl_fe_mcast_program(fe, mcgid, ports, words);
	} else if (sysfs_streq(cmd, "program-ports")) {
		u8 ports[RTL_FE_MCAST_MASK_BYTES];

		a = rtl_fe_mcast_token(&cursor);
		if (!a || kstrtou64(a, 0, &mask) ||
		    rtl_fe_mcast_token(&cursor))
			return -EINVAL;
		memcpy(ports, &mask, sizeof(ports));
		mutex_lock(&m->lock);
		ret = rtl_fe_mcast_ready_locked(fe);
		if (!ret)
			ret = rtl_fe_mcast_program_ports_locked(fe, mcgid,
								ports);
		mutex_unlock(&m->lock);
	} else {
		return -EINVAL;
	}

	if (ret)
		snprintf(m->last, sizeof(m->last), "%s %u failed: %d", cmd,
			 mcgid, ret);
	else
		snprintf(m->last, sizeof(m->last), "%s %u ok", cmd, mcgid);
	return ret ? ret : count;
}

static int rtl_fe_mcast_open(struct inode *inode, struct file *file)
{
	return single_open(file, rtl_fe_mcast_show, inode->i_private);
}

static const struct file_operations rtl_fe_mcast_fops = {
	.owner = THIS_MODULE,
	.open = rtl_fe_mcast_open,
	.read = seq_read,
	.write = rtl_fe_mcast_write,
	.llseek = seq_lseek,
	.release = single_release,
};

void rtl_fe_mcast_debugfs_init(struct rtl_fe *fe)
{
	if (!fe || !fe->mcast || !fe->debugfs)
		return;
	debugfs_create_file("mcast", 0600, fe->debugfs, fe, &rtl_fe_mcast_fops);
}
