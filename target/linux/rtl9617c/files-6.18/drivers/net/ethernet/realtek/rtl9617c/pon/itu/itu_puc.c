// SPDX-License-Identifier: GPL-2.0-or-later
/* ITU PUC carrier and queue programming shared by GPON and XG-PON. */
#include <linux/errno.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"

int rtl_itu_puc_tcont_weights(const struct rtl_dq_io *io,
		unsigned int index, unsigned int enabled, const unsigned char weights[8])
{
	unsigned int data[5] = {0}, cos;
	unsigned long long field;

	for (cos = 0; cos < 8; cos++) {
		unsigned int bit = cos * 9;

		field = (index * 8 + cos) | ((enabled >> cos & 1U) << 8);
		data[bit / 32] |= field << (bit % 32);
		if (bit % 32 > 23)
			data[bit / 32 + 1] |= field >> (32 - bit % 32);
	}
	if (weights) {
		data[2] |= (unsigned int)weights[0] << 16 | (unsigned int)weights[1] << 24;
		for (cos = 2; cos < 6; cos++)
			data[3] |= (unsigned int)weights[cos] << ((cos - 2) * 8);
		data[4] = weights[6] | (unsigned int)weights[7] << 8;
	}
	/* A valid T-CONT entry can contain disabled business queues. */
	data[2] |= 1U << 12;
	for (cos = 0; cos < 5; cos++)
		io->write(io->context, 0x8014 - cos * 4, data[cos]);
	return io->indirect(io->context, 0x8000, 0xc0000000U | index);
}

static int rtl_itu_puc_tcont(const struct rtl_dq_io *io,
				  unsigned int index, unsigned int enabled)
{
	return rtl_itu_puc_tcont_weights(io, index, enabled, 0);
}

int rtl_itu_puc_schedule(const struct rtl_dq_io *io,
		unsigned int index, unsigned int enabled, const unsigned char weights[8])
{
	unsigned int data[5] = {0}, cos, shift = 7 + (io->read(io->context, 0x8048) & 3);
	int ret = rtl_itu_puc_tcont_weights(io, index, enabled, weights);

	if (ret)
		return ret;
	for (cos = 0; cos < 8; cos++) {
		unsigned int bit = cos * 20;
		unsigned long long credit = (unsigned int)weights[cos] << shift;

		data[bit / 32] |= credit << (bit % 32);
		if (bit % 32 > 12)
			data[bit / 32 + 1] |= credit >> (32 - bit % 32);
	}
	for (cos = 0; cos < 5; cos++)
		io->write(io->context, 0x8074 - cos * 4, data[cos]);
	return io->indirect(io->context, 0x8060, 0xc0000000U | index);
}

static void rtl_gpon_puc_profile(const struct rtl_dq_io *io)
{
	unsigned int mask = 0xfb01193fU;

	/* GEM fragmentation, five-byte header, no word alignment. */
	io->write(io->context, 0x8050,
		  (io->read(io->context, 0x8050) & ~mask) | 0x2b010005U);
	io->write(io->context, 0x8230, 0x00c80000);
	io->write(io->context, 0x8234, 0x05c201b8);
}

static void rtl_xgpon_puc_profile(const struct rtl_dq_io *io)
{
	unsigned int mask = 0xfb01193fU;

	/* XGEM fragmentation, eight-byte header and word alignment. */
	io->write(io->context, 0x8050,
		  (io->read(io->context, 0x8050) & ~mask) | 0x7b001008U);
	io->write(io->context, 0x8230, 0x00800000);
	io->write(io->context, 0x8234, 0x10000200);
}

static int rtl_itu_puc_queues(const struct rtl_dq_io *io)
{
	unsigned int index;
	int ret;

	io->write(io->context, 0x804c, 0);
	for (index = 0; index < 32; index++) {
		/* Only T-CONT0 serves OMCC before OMCI assigns business queues. */
		ret = rtl_itu_puc_tcont(io, index, index ? 0 : 255);
		if (ret)
			return ret;
	}
	for (index = 0; index < 8; index++)
		io->write(io->context, 0x81bc - index * 4, index ? 0 : 255);
	io->write(io->context, 0x8160,
		  (io->read(io->context, 0x8160) & ~0xc00007ffU) | 0x80000606U);
	io->write(io->context, 0x8164,
		  (io->read(io->context, 0x8164) & ~0x7ffU) | 0x707U);
	io->write(io->context, 0x8168,
		  (io->read(io->context, 0x8168) & ~0x803f0000U) | 0x801e0000U);
	return rtl_pon_queue_backpressure(io);
}

int rtl_pon_queue_backpressure(const struct rtl_dq_io *io)
{
	unsigned int queue;
	int ret;

	for (queue = 0; queue < 256; queue++) {
		ret = io->indirect(io->context, 0x80e8, 0x80000000U | queue);
		if (ret)
			return ret;
		io->write(io->context, 0x80ec,
			(io->read(io->context, 0x80ec) & ~255U) | (queue < 128 ? queue + 64 : 255));
		ret = io->indirect(io->context, 0x80e8, 0xc0000000U | queue);
		if (ret)
			return ret;
	}
	return 0;
}


int rtl_puc_itu_configure(struct rtl9617c_pon *pon, const struct rtl_dq_io *io)
{
	u32 status;
	unsigned int index;
	int ret;

	ret = rtl9617c_ni_report_configure(pon->ni_dev, 100,
		pon->mode == RTL_PON_GPON ? 220 : 1024);
	if (ret)
		return ret;
	rtl_pon_update(pon->control, BIT(8), BIT(8));
	udelay(500);
	ret = readl_poll_timeout(pon->mac + BM_STATUS, status, status & BIT(0), 1, 100000);
	if (ret)
		return ret;
	ret = readl_poll_timeout(pon->mac + PUC_STATUS, status, status & BIT(31), 1, 100000);
	if (ret)
		return ret;
	writel(0, pon->mac + PUC_IE);
	rtl_pon_update(pon->mac + PUC_CONFIG, GENMASK(1, 0) | GENMASK(18, 16) | BIT(30),
		2 | BIT(30));
	writel(0x7a0, pon->mac + LIMIT_A);
	writel(0x3b0, pon->mac + LIMIT_A + 4);
	writel(0x200, pon->mac + LIMIT_A + 8);
	for (index = 0; index < 16; index++)
		writel(0x55555555, pon->mac + LIMIT_SELECT + index * 4);
	ret = rtl_itu_puc_queues(io);
	if (ret)
		return ret;
	if (pon->mode == RTL_PON_GPON)
		rtl_gpon_puc_profile(io);
	else
		rtl_xgpon_puc_profile(io);
	rtl_pon_update(pon->mac + BACKPRESSURE, BIT(0) | BIT(4) | GENMASK(30, 16),
		BIT(0) | (0x100 << 16));
	rtl_pon_update(pon->mac + CONTROL, BIT(30) | BIT(26), BIT(30));
	rtl_pon_update(pon->mac + CONTROL1, GENMASK(14, 0), 20 | (20 << 5) | (20 << 10));
	rtl_pon_update(pon->mac + CONTROL2, BIT(26) | GENMASK(4, 0), BIT(26) | 20);
	/* Hardware initialization owns OMCC queues0..7; leave their buckets intact. */
	ret = rtl_puc_token_buckets(pon, 8);
	if (ret)
		return ret;
	rtl_pon_update(pon->mac + AGGREGATE0, GENMASK(25, 0), 0);
	rtl_pon_update(pon->mac + AGGREGATE1, GENMASK(11, 0), 0);
	return 0;
}
