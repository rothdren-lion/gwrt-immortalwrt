// SPDX-License-Identifier: GPL-2.0-or-later

/* Native PON downstream map: PDC table programming and the decoded
 * readback used by sysfs/debugfs. */

#include <linux/bitfield.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"

/* Downstream map entry (0x9028): [2:0] cos, [8:3] destination LDPID,
 * [14:9] source, [15] bypass, [31] valid. POL_ID sits in 0x9024[12:4]. */
#define RTL_PDC_DEST_FE		24	/* NI-owned business receive path */
#define RTL_PDC_DEST_CPU	16	/* CPU/OMCC container */
#define RTL_PDC_COS		7	/* business/control container cos */
#define RTL_PDC_COS_OMCC	6	/* OMCC slot cos in the ITU map */
#define RTL_PDC_DEST_MASK	0x3f
#define RTL_PDC_SOURCE_MASK	0x3f
#define RTL_PDC_COS_MASK	0x7
#define RTL_PDC_BYPASS		BIT(15)
#define RTL_PDC_VALID		BIT(31)
#define RTL_PDC_SOURCE_NI	7
#define RTL_PDC_DEST_SHIFT	3
#define RTL_PDC_SOURCE_SHIFT	9
#define RTL_PDC_POL_ID_SHIFT	4
#define RTL_PDC_OMCC_SLOTS	8
#define RTL_PDC_OMCC_POL_ID_BASE	128
#define RTL_PDC_ENTRIES		256
#define RTL_PDC_LOW_ENTRIES	64

/* LLID table entry used as the PDC source selector. */
#define RTL_PDC_SOURCE_TABLE	0x0064

static inline u32 rtl_pdc_source_reg(unsigned int entry)
{
	return RTL_PDC_SOURCE_TABLE + entry * 4;
}

/* Build one 0x9028 word; every call site then only passes semantics. */
static inline u32 rtl_pdc_word(unsigned int dest, unsigned int source,
			       bool bypass, unsigned int cos)
{
	return ((dest & RTL_PDC_DEST_MASK) << RTL_PDC_DEST_SHIFT) |
	       ((source & RTL_PDC_SOURCE_MASK) << RTL_PDC_SOURCE_SHIFT) |
	       (cos & RTL_PDC_COS_MASK) |
	       (bypass ? RTL_PDC_BYPASS : 0);
}

static unsigned int rtl_pon_data_source(unsigned int index, unsigned int entry)
{
	if ((entry & (1U << 23)) && !(entry & (1U << 22)))
		return 32 + ((entry >> 24) & 31);
	if (entry & (1U << 22))
		return 32;
	return 32 + (index < 32 ? index : 0);
}

static int rtl_pdc_access(struct rtl9617c_pon *pon, unsigned int index, bool write)
{
	u32 status;
	writel(BIT(31) | (write ? BIT(30) : 0) | index, pon->mac + PDC_ACCESS);
	return readl_poll_timeout(pon->mac + PDC_ACCESS, status, !(status & BIT(31)), 1, 100000);
}

int rtl_pon_pdc_refresh(struct rtl9617c_pon *pon)
{
	unsigned int index, bank;
	int ret;

	lockdep_assert_held(&pon->lock);
	if (!pon->pdc_configured || !rtl_pon_mode_is_epon(pon->mode))
		return 0;
	for (index = 0; index < 64; index++) {
		u32 source = rtl_pon_data_source(index,
						 readl(pon->mac + rtl_pdc_source_reg(index)));

		if (pon->pdc_source[index] == source)
			continue;
		for (bank = 0; bank < 2; bank++) {
			writel(rtl_pdc_word(RTL_PDC_DEST_FE, RTL_PDC_SOURCE_NI,
					    false, 0), pon->mac + PDC_DATA0);
			writel((source - RTL_NI_HDR_DATA_LDPID_BASE) << RTL_PDC_POL_ID_SHIFT,
			       pon->mac + PDC_DATA1);
			ret = rtl_pdc_access(pon, index | (bank << 7), true);
			if (ret) {
				pon->pdc_error = ret;
				pon->pdc_configured = false;
				return ret;
			}
		}
		pon->pdc_source[index] = source;
	}
	return 0;
}

static int rtl_pdc_itu_configure(struct rtl9617c_pon *pon)
{
	unsigned int index;
	int ret;

	/* ITU slots0..7 are OMCC; all remaining selectors are internal GEM indices. */
	for (index = 0; index < RTL_PDC_ENTRIES; index++) {
		u32 word = rtl_pdc_word(RTL_PDC_DEST_FE, RTL_PDC_SOURCE_NI, false, 0);
		u32 pol_id = index < RTL_PDC_OMCC_SLOTS ?
			     index + RTL_PDC_OMCC_POL_ID_BASE : index - RTL_PDC_OMCC_SLOTS;

		/* Slots 0..7 carry OMCC: keep the CPU16 container plus bypass,
		 * the valid bit and cos 6 selected by the reference driver. */
		if (index < RTL_PDC_OMCC_SLOTS)
			word = rtl_pdc_word(RTL_PDC_DEST_CPU, RTL_PDC_SOURCE_NI, true,
				     RTL_PDC_COS_OMCC) |
			       RTL_PDC_VALID;
		writel(word, pon->mac + PDC_DATA0);
		writel(pol_id << 4, pon->mac + PDC_DATA1);
		ret = rtl_pdc_access(pon, index, true);
		if (ret)
			return ret;
	}
	rtl_pon_update(pon->mac + PDC_CTRL, GENMASK(25, 16) | GENMASK(2, 0),
		BIT(1) | (7 << 16) | (16 << 19) | BIT(25));
	rtl_pon_update(pon->mac + PDC_COUNTER, GENMASK(2, 0), 0);
	return 0;
}

int __rtl_pon_pdc_configure(struct rtl9617c_pon *pon)
{
	unsigned int index;
	int ret = 0;

	lockdep_assert_held(&pon->control_lock);
	lockdep_assert_held(&pon->lock);
	if (!pon->mac_prepared) {
		ret = -EAGAIN;
		goto unlock;
	}
	pon->pdc_configured = false;
	if (!rtl_pon_mode_is_epon(pon->mode)) {
		ret = rtl_pdc_itu_configure(pon);
		pon->pdc_configured = !ret;
		goto unlock;
	}
	/* Business selectors use the NI-owned FE receive path (LDPID 24, bypass 0),
	 * matching aal_pdc_init in ca-ne.ko; existing control entries retain
	 * CPU16/bypass1 and the original header container. */
	rtl_pon_update(pon->mac + PDC_CTRL, GENMASK(2, 0) | GENMASK(25, 16), 7);
	for (index = 0; index < RTL_PDC_ENTRIES; index++) {
		unsigned int entry = index & (RTL_PDC_LOW_ENTRIES - 1);
		unsigned int source = index & RTL_PDC_LOW_ENTRIES ? RTL_PDC_SOURCE_NI :
			rtl_pon_data_source(entry,
					    readl(pon->mac + rtl_pdc_source_reg(entry)));
		u32 data0 = rtl_pdc_word(RTL_PDC_DEST_FE, RTL_PDC_SOURCE_NI, false, 0);

		if (index & RTL_PDC_LOW_ENTRIES)
			data0 = rtl_pdc_word(RTL_PDC_DEST_CPU, RTL_PDC_SOURCE_NI, true,
				    RTL_PDC_COS);
		else
			pon->pdc_source[entry] = source;
		writel(data0, pon->mac + PDC_DATA0);
		/* Keep the physical PON source; POL_ID carries the LLID without
		 * enabling either hardware policer. Upper CPU source IDs are
		 * normalized by the NI receive fabric on this board. */
		writel(index & RTL_PDC_LOW_ENTRIES ? 0 :
		       (source - RTL_NI_HDR_DATA_LDPID_BASE) << RTL_PDC_POL_ID_SHIFT,
		       pon->mac + PDC_DATA1);
		ret = rtl_pdc_access(pon, index, true);
		if (ret)
			goto unlock;
	}
	rtl_pon_update(pon->mac + PDC_COUNTER, GENMASK(2, 0), 0);
	pon->pdc_configured = true;
	dev_info(pon->dev, "PDC: 256 downstream map entries; business LDPID24, control CPU16\n");
unlock:
	pon->pdc_error = ret;
	pon_dbg("pdc configure: ret=%d configured=%u\n", ret, pon->pdc_configured);
	return ret;
}

int rtl_pon_pdc_configure_locked(struct rtl9617c_pon *pon)
{
	int ret;

	mutex_lock(&pon->lock);
	ret = __rtl_pon_pdc_configure(pon);
	mutex_unlock(&pon->lock);
	return ret;
}

ssize_t rtl_pon_pdc_state(struct rtl9617c_pon *pon, char *buf)
{
	static const unsigned int sample[] = {0, 31, 63, 64, 127, 192, 255};
	ssize_t length;
	unsigned int i;
	int ret;

	length = sysfs_emit(buf, "configured=%u error=%d control=%08x counter_cfg=%08x\n",
		pon->pdc_configured, pon->pdc_error, readl(pon->mac + PDC_CTRL), readl(pon->mac + PDC_COUNTER));
	for (i = 0; i < ARRAY_SIZE(sample); i++) {
		ret = rtl_pdc_access(pon, sample[i], false);
		if (ret)
			return ret;
		length += scnprintf(buf + length, PAGE_SIZE - length,
			"index=%u data=%08x/%08x destination=%u source=%u bypass=%u cos=%u pol_id=%u\n",
			sample[i], readl(pon->mac + PDC_DATA0), readl(pon->mac + PDC_DATA1),
			(unsigned int)FIELD_GET(GENMASK(8, 3), readl(pon->mac + PDC_DATA0)),
			(unsigned int)FIELD_GET(GENMASK(14, 9), readl(pon->mac + PDC_DATA0)),
			!!(readl(pon->mac + PDC_DATA0) & BIT(15)), readl(pon->mac + PDC_DATA0) & 7, (readl(pon->mac + PDC_DATA1) >> 4) & 511);
	}
	return length;
}


static ssize_t pdc_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	ssize_t size;
	mutex_lock(&pon->lock);
	size = rtl_pon_pdc_state(pon, buf);
	mutex_unlock(&pon->lock);
	return size;
}

static ssize_t pdc_store(struct device *dev, struct device_attribute *attr,
			const char *buf, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(dev);
	bool enabled;
	int ret = kstrtobool(buf, &enabled);
	if (ret)
		return ret;
	if (!enabled)
		return -EINVAL;
	ret = rtl_pon_pdc_configure(pon);
	return ret ? ret : count;
}
DEVICE_ATTR_RW(pdc);
