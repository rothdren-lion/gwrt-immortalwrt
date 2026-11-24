// SPDX-License-Identifier: GPL-2.0-or-later
#include <linux/bitfield.h>
#include <linux/bits.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/skbuff.h>
#include <linux/string.h>
#include <linux/unaligned.h>

#include "ni.h"

#define DMA_CTRL			0x000
#define DMA_CTRL_ENABLE			BIT(0)
#define DMA_CTRL_RUN			(BIT(0) | GENMASK(3, 2) | BIT(4))
#define DMA_CTRL_RESET			BIT(8)
#define DMA_AXI_USER_SELECT		0x014
#define DMA_AXI_USER_SEL_SHIFT(vp)	((vp) * 2)
#define DMA_AXI_USER_SEL_MASK(vp)	(GENMASK(1, 0) << \
					 DMA_AXI_USER_SEL_SHIFT(vp))
#define DMA_AXI_USER_SEL_PAT1(vp)	(1U << DMA_AXI_USER_SEL_SHIFT(vp))
#define DMA_AXI_USER_PATTERN0		0x018
#define DMA_AXI_USER_PATTERN1		0x01c
#define DMA_AXI_USER_PATTERN2		0x020
#define DMA_AXI_USER_PATTERN3		0x024
#define DMA_AXI_USER_PATTERN1_INIT	0x02008080
#define DMA_VP(n)			(0x100 + (n) * 0xa0)
#define DMA_VP_ENABLE			0x00
#define DMA_VP_ENABLE_EN		BIT(0)
#define DMA_VP_BASE_ACCESS		0x04
#define DMA_VP_BASE_ACCESS_BUSY		BIT(31)
#define DMA_VP_BASE_ACCESS_WRITE	BIT(30)
#define DMA_VP_BASE_HIGH		0x08
#define DMA_VP_BASE_HIGH_INIT		2
#define DMA_VP_BASE_LOW			0x0c
#define DMA_VP_WRITE			0x18
#define DMA_VP_READ			0x1c
#define DMA_VP_IRQ_ENABLE		0x64
#define DMA_VP_MISC_IRQ			0x68
#define DMA_VP_MISC_IRQ_TX		BIT(0)
#define DMA_VP_HEADER_A			0x78
#define DMA_VP_HEADER_A_LDPID		GENMASK(8, 3)
#define DMA_VP_HEADER_A_INIT		BIT(9)
#define DMA_SS_CTRL			0x900
#define DMA_SS_CTRL_EN			BIT(31)
#define DMA_AXI_CONFIG			0xd80
#define DMA_AXI_CONFIG_MASK		GENMASK(14, 0)
#define DMA_AXI_CONFIG_INIT		0x7aff
#define DMA_AFT_CTRL			0xf00
#define DMA_AFT_CTRL_LIMIT_MASK		GENMASK(15, 4)
#define DMA_AFT_CTRL_LIMIT		64
#define DMA_AFT_CTRL_INIT		(FIELD_PREP(DMA_AFT_CTRL_LIMIT_MASK, \
						    DMA_AFT_CTRL_LIMIT) | \
					 BIT(0))

#define DMA_DESC_CTRL			0x61000002
#define DMA_DESC_CTRL_OAM		0x61000000
#define DMA_DESC_LEN_SHIFT		8
#define DMA_MIN_FRAME			60U

#define DMA_MEM_SIZE			(RTL_NI_DMA_ENTRIES * \
					 (sizeof(struct rtl_ni_dma_desc) + \
					  RTL_NI_DMA_BUF_SIZE))

/*
 * Descriptor shape switches (RE-1 section 6, steps S1/S2) and the TX offload
 * switches (S4/S5).  Every one of them defaults to the pre-offload behaviour:
 *
 *   /sys/module/rtl9617c_ni/parameters/hdr_layout_oem  (default 1)
 *   /sys/module/rtl9617c_ni/parameters/hdr_a_full      (default 0)
 *   /sys/module/rtl9617c_ni/parameters/tx_csum         (default 0)
 *   /sys/module/rtl9617c_ni/parameters/tso             (default 0)
 *   /sys/module/rtl9617c_ni/parameters/tso_v6          (default 0)
 *
 * S1 is a structure change only: the OEM and pre-S1 encoders emit identical
 * bytes (asserted by tests/tx-dma-layout.py).  S2 turns header_a into an
 * explicitly packed OEM word.  hdr_a_full defaults to 0 so the pre-S2 rule
 * still applies (pkt_size is filled only when the caller left the field empty)
 * until a board has validated the padded-OMCI pkt_size change; an offloaded
 * frame always gets an authoritative pkt_size.
 *
 * lso_para0 is zero unless rtl_ni_tx_offload_prepare() sets it, so by default
 * the hardware keeps sending one plain descriptor per frame.  lso_para1 is the
 * frame length without the 16-byte buffer header; that matches the OEM, which
 * writes the payload length to lso_para1 and adds hdr_len only to the
 * descriptor length field:
 *
 *   ca_ni_start_xmit_buf.constprop.0 @0x1aabf0 (re-checked with REA):
 *     uVar17 = param_2 & 0xffff;  puVar28[0] = lso_para0;  puVar28[1] = uVar17;
 *     ctrl = local_50 | ((param_2 + iVar22) & 0xffff) << 8;   iVar22 = 0x10
 *
 * so no len+16 correction belongs in lso_para1.
 */
static bool hdr_layout_oem = true;
module_param(hdr_layout_oem, bool, 0644);
MODULE_PARM_DESC(hdr_layout_oem,
		 "1 = OEM layout (lso_para0@+0, lso_para1@+4, header_a@+8), 0 = pre-S1");

static bool hdr_a_full;
module_param(hdr_a_full, bool, 0644);
MODULE_PARM_DESC(hdr_a_full,
		 "Fill every header_a field (pkt/cos/ldpid/lspid/type/fe); 0 = pre-S2");

/*
 * TX offload switches.  Writing to /sys/module/rtl9617c_ni/parameters/{tx_csum,
 * tso,tso_v6} also triggers netdev_update_features() on every registered NI
 * port so the offloads can be toggled at runtime without a reboot.
 */
static int rtl_ni_offload_param_set(const char *val,
				    const struct kernel_param *kp)
{
	int ret = param_set_bool(val, kp);

	if (!ret)
		rtl_ni_ports_update_features();
	return ret;
}

static const struct kernel_param_ops rtl_ni_offload_param_ops = {
	.set = rtl_ni_offload_param_set,
	.get = param_get_bool,
};

bool rtl_ni_tx_csum;
module_param_cb(tx_csum, &rtl_ni_offload_param_ops, &rtl_ni_tx_csum, 0644);
MODULE_PARM_DESC(tx_csum,
		 "Advertise and use TX TCP/UDP checksum offload (default 0)");

bool rtl_ni_tso;
module_param_cb(tso, &rtl_ni_offload_param_ops, &rtl_ni_tso, 0644);
MODULE_PARM_DESC(tso,
		 "Advertise and use IPv4/TCP segmentation offload (default 0)");

bool rtl_ni_tso_v6;
module_param_cb(tso_v6, &rtl_ni_offload_param_ops, &rtl_ni_tso_v6, 0644);
MODULE_PARM_DESC(tso_v6,
		 "Also allow IPv6/TCP segmentation offload (default 0)");

/* BEGIN rtl-ni-tx-hdr (tests/tx-dma-layout.py extracts this region verbatim) */

#define RTL_NI_ETH_HLEN			14
#define RTL_NI_VLAN_HLEN		4
#define RTL_NI_PPPOE_HLEN		8
#define RTL_NI_IPV4_MIN_HLEN		20
#define RTL_NI_IPV6_HLEN		40
#define RTL_NI_TCP_MIN_HLEN		20
#define RTL_NI_UDP_HLEN			8
#define RTL_NI_IPV6_EXT_MAX		4

#define RTL_NI_ETH_P_IP			0x0800
#define RTL_NI_ETH_P_IPV6		0x86dd
#define RTL_NI_ETH_P_PPP_SES		0x8864
#define RTL_NI_ETH_P_8021Q		0x8100
#define RTL_NI_ETH_P_8021AD		0x88a8
#define RTL_NI_ETH_P_QINQ_OLD		0x9100
#define RTL_NI_PPP_IP			0x0021
#define RTL_NI_PPP_IPV6			0x0057
#define RTL_NI_IPPROTO_TCP		6
#define RTL_NI_IPPROTO_UDP		17
#define RTL_NI_IPPROTO_FRAG		44
#define RTL_NI_IPV6_EXT_HOP		0
#define RTL_NI_IPV6_EXT_ROUTE		43
#define RTL_NI_IPV6_EXT_AH		51
#define RTL_NI_IPV6_EXT_DST		60

/* IPv4 fragment flags (frag_off): MF plus the 13-bit offset. */
#define RTL_NI_IPV4_FRAG_MASK		0x3fff
/* PPPoE session version/type byte (RFC 2516). */
#define RTL_NI_PPPOE_VT			0x11

#define RTL_NI_LSO_PARA1_LEN_MASK	GENMASK(15, 0)
#define RTL_NI_HDR_A_LOW_COS_MASK	0x7u
#define RTL_NI_HDR_A_LOW_LDPID_SHIFT	3
#define RTL_NI_HDR_A_LOW_LDPID_MASK	0x3fu
#define RTL_NI_HDR_A_LOW_LSPID_SHIFT	9
#define RTL_NI_HDR_A_LOW_LSPID_MASK	0x3fu
#define RTL_NI_HDR_A_LOW_FE_BYPASS_SHIFT 29
#define RTL_NI_HDR_A_LOW_FE_BYPASS_MASK	0x1u
#define RTL_NI_HDR_A_LOW_HDR_TYPE_SHIFT 30
#define RTL_NI_HDR_A_LOW_HDR_TYPE_MASK	0x3u

#define RTL_NI_CSUM_FOLD_MASK		0xffffu
#define RTL_NI_UDP_CSUM_ZERO		0xffffu

static u16 rtl_ni_be16(const u8 *p)
{
	return (u16)((p[0] << 8) | p[1]);
}

/*
 * Pack the OEM TX buffer header for one frame.
 *
 * header_high is the word the ring buffer carries at +8 and header_low the one
 * at +12, so in the OEM 64-bit view header_high is the low half and header_low
 * the high half.  S1 keeps that mapping because it is exactly what places cos,
 * ldpid, lspid, pkt_size and fe_bypass on the OEM bit positions (RE-1 2.5):
 * the high half's [2:0] is cos[34:32], [8:3] is ldpid[40:35], [14:9] is
 * lspid[46:41], [28:15] is pkt_size[60:47], bit 29 is fe_bypass[61] and bits
 * [31:30] are hdr_type[63:62].
 *
 * pkt_size is the number of bytes the DMA engine moves for this frame: the
 * prefix plus the payload, padding included, and excluding the 16-byte buffer
 * header and the FCS.  That is the value the descriptor length field carries.
 */
void rtl_ni_tx_hdr_build(struct rtl_ni_tx_hdr *hdr,
			 const struct rtl9617c_ni_frame *frame,
			 unsigned int len, bool full_header)
{
	u64 header_a = ((u64)frame->header_low << 32) | frame->header_high;
	u32 pkt_size = len & RTL_NI_HDR_A_PKT_SIZE_MAX;
	u32 low = frame->header_low;

	if (full_header) {
		header_a &= ~(RTL_NI_HDR_A_COS | RTL_NI_HDR_A_LDPID |
			      RTL_NI_HDR_A_LSPID | RTL_NI_HDR_A_PKT_SIZE |
			      RTL_NI_HDR_A_FE_BYPASS | RTL_NI_HDR_A_HDR_TYPE);
		header_a |= FIELD_PREP(RTL_NI_HDR_A_COS,
				       low & RTL_NI_HDR_A_LOW_COS_MASK);
		header_a |= FIELD_PREP(RTL_NI_HDR_A_LDPID,
				       (low >> RTL_NI_HDR_A_LOW_LDPID_SHIFT) &
				       RTL_NI_HDR_A_LOW_LDPID_MASK);
		header_a |= FIELD_PREP(RTL_NI_HDR_A_LSPID,
				       (low >> RTL_NI_HDR_A_LOW_LSPID_SHIFT) &
				       RTL_NI_HDR_A_LOW_LSPID_MASK);
		header_a |= FIELD_PREP(RTL_NI_HDR_A_PKT_SIZE, pkt_size);
		header_a |= FIELD_PREP(RTL_NI_HDR_A_FE_BYPASS,
				       (low >> RTL_NI_HDR_A_LOW_FE_BYPASS_SHIFT) &
				       RTL_NI_HDR_A_LOW_FE_BYPASS_MASK);
		header_a |= FIELD_PREP(RTL_NI_HDR_A_HDR_TYPE,
				       (low >> RTL_NI_HDR_A_LOW_HDR_TYPE_SHIFT) &
				       RTL_NI_HDR_A_LOW_HDR_TYPE_MASK);
	} else if (!(header_a & RTL_NI_HDR_A_PKT_SIZE)) {
		header_a |= FIELD_PREP(RTL_NI_HDR_A_PKT_SIZE, pkt_size);
	}

	hdr->lso_para0 = 0;
	hdr->lso_para1 = len & RTL_NI_LSO_PARA1_LEN_MASK;
	hdr->header_a = header_a;
}

/*
 * Emit the 16-byte buffer header.  oem_layout selects the OEM single 64-bit
 * header_a word at +8; the fallback writes the same bytes as the pre-S1 pairs
 * (low half at +8, high half at +12), which is why S1 is behaviour neutral.
 * Callers memset the header area first, so the fallback need not touch +0.
 */
void rtl_ni_tx_hdr_write(u8 *buf, const struct rtl_ni_tx_hdr *hdr,
			 bool oem_layout)
{
	if (oem_layout) {
		put_unaligned_le32(hdr->lso_para0, buf + 0);
		put_unaligned_le32(hdr->lso_para1, buf + 4);
		put_unaligned_le64(hdr->header_a, buf + 8);
		return;
	}

	put_unaligned_le32(hdr->lso_para1, buf + 4);
	put_unaligned_le32((u32)hdr->header_a, buf + 8);
	put_unaligned_le32((u32)(hdr->header_a >> 32), buf + 12);
}

/*
 * Classify a frame for the LSO/checksum path.  This is the logic OEM hides
 * behind the misleadingly named rtk_dma_lso_checksum_select @0x1a6470, which
 * touches no register at all (RE-1 1.6): walk the L2 ethertype, PPPoE and
 * IPv6 extension headers, then require an unfragmented TCP or UDP header whose
 * length fields stay inside the frame.
 *
 * Returns 0 when info describes an offloadable TCP/UDP frame, -EOPNOTSUPP
 * when the frame is well formed but must not be offloaded (non-IP, non-TCP/UDP,
 * fragmented), and -EINVAL when a header is malformed or truncated.
 *
 * Not wired into the TX path yet: S4 will consume it.
 */
int rtl_ni_tx_l4_parse(const u8 *data, unsigned int len,
		       struct rtl_ni_tx_l4info *info)
{
	unsigned int off = RTL_NI_ETH_HLEN;
	unsigned int l4_off, l4_len, ihl, ip_end, ext, hdrs = 0, tags = 0;
	u16 proto, frag, plen;
	u8 next;

	memset(info, 0, sizeof(*info));
	if (len < RTL_NI_ETH_HLEN)
		return -EINVAL;

	proto = rtl_ni_be16(data + 12);
	while (proto == RTL_NI_ETH_P_8021Q || proto == RTL_NI_ETH_P_8021AD ||
	       proto == RTL_NI_ETH_P_QINQ_OLD) {
		/* At most one outer and one inner tag, as QinQ allows. */
		if (len < off + RTL_NI_VLAN_HLEN || tags++ >= 2)
			return -EINVAL;
		proto = rtl_ni_be16(data + off + 2);
		off += RTL_NI_VLAN_HLEN;
	}

	if (proto == RTL_NI_ETH_P_PPP_SES) {
		u16 ppp;

		if (len < off + RTL_NI_PPPOE_HLEN)
			return -EINVAL;
		if (data[off] != RTL_NI_PPPOE_VT)
			return -EOPNOTSUPP;
		ppp = rtl_ni_be16(data + off + 6);
		/* PPPoE length counts the 2-byte PPP protocol field too. */
		plen = rtl_ni_be16(data + off + 4);
		if (plen < 2 ||
		    (unsigned int)(plen - 2) > len - (off + RTL_NI_PPPOE_HLEN))
			return -EINVAL;
		info->pppoe = true;
		len = off + RTL_NI_PPPOE_HLEN + (plen - 2);
		off += RTL_NI_PPPOE_HLEN;
		if (ppp == RTL_NI_PPP_IP)
			proto = RTL_NI_ETH_P_IP;
		else if (ppp == RTL_NI_PPP_IPV6)
			proto = RTL_NI_ETH_P_IPV6;
		else
			return -EOPNOTSUPP;
	}

	switch (proto) {
	case RTL_NI_ETH_P_IP:
		if (len < off + RTL_NI_IPV4_MIN_HLEN)
			return -EINVAL;
		if ((data[off] >> 4) != 4)
			return -EINVAL;
		ihl = (data[off] & 0xf) * 4;
		if (ihl < RTL_NI_IPV4_MIN_HLEN || len < off + ihl)
			return -EINVAL;
		plen = rtl_ni_be16(data + off + 2);
		if (plen < ihl || plen > len - off)
			return -EINVAL;
		frag = rtl_ni_be16(data + off + 6);
		if (frag & RTL_NI_IPV4_FRAG_MASK)
			return -EOPNOTSUPP;
		info->ipv4 = true;
		info->l3_off = off;
		info->ip_len = plen;
		info->ip_proto = data[off + 9];
		l4_off = off + ihl;
		l4_len = plen - ihl;
		break;

	case RTL_NI_ETH_P_IPV6:
		if (len < off + RTL_NI_IPV6_HLEN)
			return -EINVAL;
		if ((data[off] >> 4) != 6)
			return -EINVAL;
		plen = rtl_ni_be16(data + off + 4);
		ip_end = off + RTL_NI_IPV6_HLEN;
		if (plen > len - ip_end)
			return -EINVAL;
		ip_end += plen;
		next = data[off + 6];
		l4_off = off + RTL_NI_IPV6_HLEN;

		while (next == RTL_NI_IPV6_EXT_HOP ||
		       next == RTL_NI_IPV6_EXT_ROUTE ||
		       next == RTL_NI_IPV6_EXT_DST ||
		       next == RTL_NI_IPV6_EXT_AH) {
			if (hdrs++ >= RTL_NI_IPV6_EXT_MAX || l4_off + 2 > ip_end)
				return -EINVAL;
			if (next == RTL_NI_IPV6_EXT_AH)
				ext = (data[l4_off + 1] + 2) * 4;
			else
				ext = (data[l4_off + 1] + 1) * 8;
			if (l4_off + ext > ip_end)
				return -EINVAL;
			next = data[l4_off];
			l4_off += ext;
		}

		if (next == RTL_NI_IPPROTO_FRAG)
			return -EOPNOTSUPP;
		info->ipv6 = true;
		info->l3_off = off;
		info->ip_len = ip_end - off;
		info->ip_proto = next;
		l4_len = ip_end - l4_off;
		break;

	default:
		return -EOPNOTSUPP;
	}

	switch (info->ip_proto) {
	case RTL_NI_IPPROTO_TCP:
		if (l4_len < RTL_NI_TCP_MIN_HLEN)
			return -EINVAL;
		ihl = (data[l4_off + 12] >> 4) * 4;
		if (ihl < RTL_NI_TCP_MIN_HLEN || ihl > l4_len)
			return -EINVAL;
		info->tcp = true;
		l4_len -= ihl;
		break;

	case RTL_NI_IPPROTO_UDP:
		if (l4_len < RTL_NI_UDP_HLEN)
			return -EINVAL;
		plen = rtl_ni_be16(data + l4_off + 4);
		if (plen < RTL_NI_UDP_HLEN || plen > l4_len)
			return -EINVAL;
		info->udp = true;
		/* OEM leaves UDP alone when the checksum field is zero. */
		info->udp_csum_present = rtl_ni_be16(data + l4_off + 6) != 0;
		l4_len = plen - RTL_NI_UDP_HLEN;
		break;

	default:
		return -EOPNOTSUPP;
	}

	info->l4_off = l4_off;
	info->l4_len = l4_len;
	return 0;
}

/*
 * Internet checksum helpers for the UDP precompute the OEM performs before it
 * sets udp_en (RE-1 2.3).  The checksum is byte-order neutral, so this works
 * straight on the frame the DMA engine will read.
 */
static u32 rtl_ni_csum_add(const u8 *p, unsigned int len, u32 sum)
{
	while (len > 1) {
		sum += rtl_ni_be16(p);
		p += 2;
		len -= 2;
	}
	if (len)
		sum += (u32)p[0] << 8;
	return sum;
}

static u16 rtl_ni_csum_fold(u32 sum)
{
	while (sum >> 16)
		sum = (sum & RTL_NI_CSUM_FOLD_MASK) + (sum >> 16);
	return (u16)~sum;
}

/*
 * Complete the UDP checksum in the frame buffer.  The hardware parser has no
 * checksum-offset field, so the value written here is what goes on the wire;
 * the OEM does the same in ca_ni_get_lso_para0 before setting udp_en.
 */
static void rtl_ni_tx_udp_csum_fixup(u8 *frame,
				     const struct rtl_ni_tx_l4info *info)
{
	unsigned int udp_len = info->l4_len + RTL_NI_UDP_HLEN;
	u32 sum;
	u16 csum;

	if (info->ipv4) {
		/* src + dst, then proto and length as 16-bit words */
		sum = rtl_ni_csum_add(frame + info->l3_off + 12, 8, 0);
	} else {
		sum = rtl_ni_csum_add(frame + info->l3_off + 8, 32, 0);
		sum += (udp_len >> 16) & RTL_NI_CSUM_FOLD_MASK;
	}
	sum += udp_len & RTL_NI_CSUM_FOLD_MASK;
	sum += RTL_NI_IPPROTO_UDP;

	frame[info->l4_off + 6] = 0;
	frame[info->l4_off + 7] = 0;
	sum = rtl_ni_csum_add(frame + info->l4_off, udp_len, sum);
	csum = rtl_ni_csum_fold(sum);
	if (!csum)
		csum = RTL_NI_UDP_CSUM_ZERO; /* a computed zero is sent as all ones */
	frame[info->l4_off + 6] = (u8)(csum >> 8);
	frame[info->l4_off + 7] = (u8)csum;
}

/*
 * Decide lso_para0 for one frame and, for UDP, complete the checksum in place.
 * Mirrors the OEM order (RE-1 section 6, S4 before S5): segmentation first,
 * then plain checksum offload.
 *
 * Returns 0 with *para0 set, -EOPNOTSUPP when this frame must not be offloaded
 * (the caller then completes the checksum in software or drops a GSO frame),
 * and -EINVAL when the request itself is inconsistent.
 */
int rtl_ni_tx_offload_prepare(u8 *frame, unsigned int len,
			      const struct rtl_ni_tx_offload *req, u32 *para0)
{
	struct rtl_ni_tx_l4info info;
	unsigned int seg_mtu, seg_size;
	u32 bits, lenfix = 0;
	int ret;

	*para0 = 0;
	ret = rtl_ni_tx_l4_parse(frame, len, &info);
	if (ret)
		return ret;

	/*
	 * OEM ca_ni_get_lso_para0 (ca-ne.ko @0xa58b0):
	 *  - set lenfix_en (bit 31) whenever the Ethernet frame carries tail
	 *    padding beyond L3 (such as 60-byte padded TCP ACK/FIN frames);
	 *  - always set segment_en (bit 25) with segment_size equal to the
	 *    total L2 frame length (l3_off + seg_mtu), not bare TCP MSS.
	 */
	if (len > info.l3_off + info.ip_len)
		lenfix = RTL_NI_LSO_PARA0_LENFIX_EN;

	if (req->segment) {
		unsigned int tcp_hlen;

		/* S5: IPv4/TCP first; IPv6 needs tso_v6. */
		if (!info.tcp)
			return -EOPNOTSUPP;
		if (!info.ipv4 && !(info.ipv6 && req->segment_ipv6))
			return -EOPNOTSUPP;
		if (!req->gso_size ||
		    req->gso_size > RTL_NI_HDR_A_PKT_SIZE_MAX)
			return -EINVAL;

		tcp_hlen = (frame[info.l4_off + 12] >> 4) * 4;
		seg_mtu = (info.l4_off - info.l3_off) + tcp_hlen + req->gso_size;
		if (req->mtu && seg_mtu > req->mtu)
			seg_mtu = req->mtu;
		seg_size = info.l3_off + seg_mtu;
		if (seg_size > RTL_NI_HDR_A_PKT_SIZE_MAX)
			return -EINVAL;

		*para0 = FIELD_PREP(RTL_NI_LSO_PARA0_SEGMENT_SIZE, seg_size) |
			 RTL_NI_LSO_PARA0_SEGMENT_EN |
			 RTL_NI_LSO_PARA0_TCP_EN |
			 (info.ipv4 ? RTL_NI_LSO_PARA0_IPV4_EN :
				      RTL_NI_LSO_PARA0_IPV6_EN) |
			 lenfix;
		return 0;
	}

	if (!req->csum)
		return -EOPNOTSUPP;

	seg_mtu = req->mtu ? req->mtu : 1500U;
	if (info.ip_len > seg_mtu)
		seg_mtu = info.ip_len;
	seg_size = info.l3_off + seg_mtu;
	if (seg_size > RTL_NI_HDR_A_PKT_SIZE_MAX)
		seg_size = RTL_NI_HDR_A_PKT_SIZE_MAX;

	bits = FIELD_PREP(RTL_NI_LSO_PARA0_SEGMENT_SIZE, seg_size) |
	       RTL_NI_LSO_PARA0_SEGMENT_EN |
	       (info.ipv4 ? RTL_NI_LSO_PARA0_IPV4_EN :
			    RTL_NI_LSO_PARA0_IPV6_EN) |
	       lenfix;
	if (info.tcp) {
		*para0 = bits | RTL_NI_LSO_PARA0_TCP_EN;
		return 0;
	}
	if (!info.udp)
		return -EOPNOTSUPP;
	/* OEM leaves UDP alone when the checksum field is zero. */
	if (!info.udp_csum_present)
		return -EOPNOTSUPP;
	rtl_ni_tx_udp_csum_fixup(frame, &info);
	*para0 = bits | RTL_NI_LSO_PARA0_UDP_EN;
	return 0;
}

/* END rtl-ni-tx-hdr */

static void __iomem *rtl_ni_dma_vp(struct rtl_ni_dma *dma)
{
	return dma->base + DMA_VP(RTL_NI_DMA_VP);
}

static unsigned int rtl_ni_dma_buf_offset(unsigned int index)
{
	return RTL_NI_DMA_ENTRIES * sizeof(struct rtl_ni_dma_desc) +
	       index * RTL_NI_DMA_BUF_SIZE;
}

int rtl_ni_dma_alloc(struct rtl9617c_ni *ni)
{
	struct rtl_ni_dma *dma = &ni->dma;

	dma->mem = dmam_alloc_coherent(ni->dev, DMA_MEM_SIZE, &dma->mem_dma,
				       GFP_KERNEL);
	if (!dma->mem)
		return -ENOMEM;
	dma->desc = dma->mem;
	return 0;
}

int rtl_ni_dma_start(struct rtl_ni_dma *dma)
{
	void __iomem *vp = rtl_ni_dma_vp(dma);
	void __iomem *base = dma->base;
	u32 val;
	int ret;

	writel(readl(base + DMA_CTRL) | DMA_CTRL_RESET, base + DMA_CTRL);
	udelay(10);
	writel(readl(base + DMA_CTRL) & ~(DMA_CTRL_RESET | DMA_CTRL_ENABLE),
	       base + DMA_CTRL);
	writel(0, vp + DMA_VP_ENABLE);
	writel(0, vp + DMA_VP_IRQ_ENABLE);
	writel(0, vp + DMA_VP_WRITE);

	memset(dma->mem, 0, DMA_MEM_SIZE);
	dma->head = 0;
	dma->tail = 0;

	writel(lower_32_bits(dma->mem_dma) | RTL_NI_DMA_ORDER, vp + DMA_VP_BASE_LOW);
	writel(DMA_VP_BASE_HIGH_INIT, vp + DMA_VP_BASE_HIGH);
	writel(DMA_VP_BASE_ACCESS_BUSY | DMA_VP_BASE_ACCESS_WRITE,
	       vp + DMA_VP_BASE_ACCESS);
	ret = readl_poll_timeout_atomic(vp + DMA_VP_BASE_ACCESS, val,
					!(val & DMA_VP_BASE_ACCESS_BUSY), 1,
					100000);
	if (ret)
		return ret;
	writel(FIELD_PREP(DMA_VP_HEADER_A_LDPID, RTL_NI_CPU_PORT) |
	       DMA_VP_HEADER_A_INIT, vp + DMA_VP_HEADER_A);

	val = readl(base + DMA_AXI_USER_SELECT);
	val &= ~DMA_AXI_USER_SEL_MASK(RTL_NI_DMA_VP);
	val |= DMA_AXI_USER_SEL_PAT1(RTL_NI_DMA_VP);
	writel(val, base + DMA_AXI_USER_SELECT);
	writel(DMA_AXI_USER_PATTERN1_INIT, base + DMA_AXI_USER_PATTERN0);
	writel(DMA_AXI_USER_PATTERN1_INIT, base + DMA_AXI_USER_PATTERN1);
	writel(DMA_AXI_USER_PATTERN1_INIT, base + DMA_AXI_USER_PATTERN2);
	writel(DMA_AXI_USER_PATTERN1_INIT, base + DMA_AXI_USER_PATTERN3);
	val = readl(base + DMA_AXI_CONFIG);
	writel((val & ~DMA_AXI_CONFIG_MASK) | DMA_AXI_CONFIG_INIT,
	       base + DMA_AXI_CONFIG);
	writel(readl(base + DMA_SS_CTRL) | DMA_SS_CTRL_EN | BIT(RTL_NI_DMA_VP),
	       base + DMA_SS_CTRL);

	writel(DMA_AFT_CTRL_INIT, base + DMA_AFT_CTRL);
	writel(DMA_VP_ENABLE_EN, vp + DMA_VP_ENABLE);
	writel(DMA_CTRL_RUN, base + DMA_CTRL);
	return 0;
}

void rtl_ni_dma_stop(struct rtl_ni_dma *dma)
{
	void __iomem *base = dma->base;

	writel(0, rtl_ni_dma_vp(dma) + DMA_VP_ENABLE);
	writel(readl(base + DMA_CTRL) & ~DMA_CTRL_ENABLE, base + DMA_CTRL);
	writel(readl(base + DMA_CTRL) | DMA_CTRL_RESET, base + DMA_CTRL);
	udelay(10);
	writel(readl(base + DMA_CTRL) & ~DMA_CTRL_RESET, base + DMA_CTRL);
}

void rtl_ni_dma_reclaim(struct rtl_ni_dma *dma)
{
	unsigned int hw = readl(rtl_ni_dma_vp(dma) + DMA_VP_READ) &
			  (RTL_NI_DMA_ENTRIES - 1);

	while (((hw - dma->tail) & (RTL_NI_DMA_ENTRIES - 1)) > RTL_NI_DMA_GUARD)
		dma->tail = (dma->tail + 1) & (RTL_NI_DMA_ENTRIES - 1);
}

bool rtl_ni_dma_avail(struct rtl_ni_dma *dma)
{
	return ((dma->tail - dma->head - 1) & (RTL_NI_DMA_ENTRIES - 1)) >
	       RTL_NI_DMA_GUARD;
}

int rtl_ni_dma_xmit(struct rtl_ni_dma *dma, struct sk_buff *skb,
		    const struct rtl9617c_ni_frame *frame, unsigned int mtu)
{
	unsigned int offset = rtl_ni_dma_buf_offset(dma->head);
	unsigned int prefix = frame->prefix_length;
	struct rtl_ni_tx_hdr hdr;
	unsigned int len;
	u32 lso_para0 = 0;
	void *buf;

	len = frame->raw_payload ? skb->len : max(skb->len, DMA_MIN_FRAME);
	len += prefix;
	if (len + RTL_NI_DMA_HDR_LEN > RTL_NI_DMA_BUF_SIZE)
		return -EMSGSIZE;

	rtl_ni_dma_reclaim(dma);
	if (!rtl_ni_dma_avail(dma))
		return -ENOSPC;

	buf = dma->mem + offset;
	memset(buf, 0, RTL_NI_DMA_HDR_LEN);
	if (prefix)
		memcpy(buf + RTL_NI_DMA_HDR_LEN, frame->prefix, prefix);
	skb_copy_bits(skb, 0, buf + RTL_NI_DMA_HDR_LEN + prefix, skb->len);
	if (unlikely(len > prefix + skb->len))
		memset(buf + RTL_NI_DMA_HDR_LEN + prefix + skb->len, 0,
		       len - prefix - skb->len);

	/*
	 * Checksum/LSO offload (RE-1 steps S4/S5).  Only frames the stack marks
	 * CHECKSUM_PARTIAL or GSO are candidates, and only the plain Ethernet
	 * frames of this driver: PON frames carry a private prefix and are
	 * never marked for offload.  A declining frame gets its checksum
	 * completed in software, so an offload can never corrupt a frame.
	 */
	if (unlikely(!frame->raw_payload &&
		     (skb->ip_summed == CHECKSUM_PARTIAL || skb_is_gso(skb)))) {
		bool gso = skb_is_gso(skb);
		const struct rtl_ni_tx_offload req = {
			.csum = rtl_ni_tx_csum || rtl_ni_tso,
			.segment = gso,
			.segment_ipv6 = rtl_ni_tso_v6,
			.gso_size = gso ? skb_shinfo(skb)->gso_size : 0,
			.mtu = mtu,
		};

		if (rtl_ni_tx_offload_prepare(buf + RTL_NI_DMA_HDR_LEN, len,
					      &req, &lso_para0)) {
			/*
			 * A GSO frame cannot be checksum-helped: dropping it is
			 * better than sending unsegmented garbage.  Unreachable
			 * while the advertised limits hold.
			 */
			if (gso)
				return -EOPNOTSUPP;
			if (skb_checksum_help(skb))
				return -EFAULT;
			/* The software checksum went into the skb, not the buffer. */
			skb_copy_bits(skb, 0,
				      buf + RTL_NI_DMA_HDR_LEN + prefix,
				      skb->len);
		}
	}

	/* An offloaded frame always carries an authoritative pkt_size. */
	rtl_ni_tx_hdr_build(&hdr, frame, len, hdr_a_full || lso_para0 != 0);
	hdr.lso_para0 = lso_para0;
	rtl_ni_tx_hdr_write(buf, &hdr, hdr_layout_oem);

	dma->desc[dma->head].addr = cpu_to_le32(dma->mem_dma + offset);
	dma->desc[dma->head].ctrl = cpu_to_le32((frame->oam ? DMA_DESC_CTRL_OAM :
						 DMA_DESC_CTRL) |
						((len + RTL_NI_DMA_HDR_LEN) <<
						 DMA_DESC_LEN_SHIFT));
	dma_wmb();
	dma->head = (dma->head + 1) & (RTL_NI_DMA_ENTRIES - 1);
	writel(dma->head, rtl_ni_dma_vp(dma) + DMA_VP_WRITE);
	writel(DMA_VP_MISC_IRQ_TX, rtl_ni_dma_vp(dma) + DMA_VP_MISC_IRQ);
	return 0;
}
