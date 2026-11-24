// SPDX-License-Identifier: GPL-2.0-or-later
/* EPON/NI MIB collection and the CTC PM counter projection. */
#include <linux/device.h>
#include <linux/io.h>
#include <linux/unaligned.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/pon_debug.h"
#include "rtl9617c_ni.h"
#include "pon/epon/epon.h"
#define RTL_CTC_PM_COUNTERS 37
#define RTL_EPON_MIB_COUNTERS 42

static int rtl_epon_mib_read(const struct rtl_dq_io *io, unsigned int raw[RTL_EPON_MIB_COUNTERS])
{
	unsigned int index;
	int ret;

	io->write(io->context, 0x604, io->read(io->context, 0x604) & ~1U);
	for (index = 0; index < RTL_EPON_MIB_COUNTERS; index++) {
		unsigned int access = index < 21 ? 0x618 : 0x630;

		ret = io->indirect(io->context, access, (1U << 31) | (index % 21));
		if (ret)
			return ret;
		raw[index] = io->read(io->context, access + 4);
	}
	return 0;
}

static void rtl_mib_extend(unsigned long long *total, unsigned long long raw, int wide)
{
	if (wide)
		*total = raw;
	else
		*total += (unsigned int)((unsigned int)raw - (unsigned int)*total);
}

static void rtl_ni_mib_pm(const u64 total[RTL9617C_NI_MIB_COUNTERS],
	unsigned long long pm[RTL_CTC_PM_COUNTERS])
{
	unsigned int index;
	const u64 *rx = total, *tx = total + RTL9617C_NI_MIB_RX;

	for (index = 0; index < RTL_CTC_PM_COUNTERS; index++)
		pm[index] = 0;
	pm[1] = rx[13];
	pm[2] = tx[25];
	pm[3] = rx[25];
	pm[4] = tx[0] + tx[1] + tx[2];
	pm[5] = rx[0] + rx[1] + rx[2];
	pm[6] = tx[2];
	pm[7] = rx[2];
	pm[8] = tx[1];
	pm[9] = rx[1];
	pm[10] = tx[7];
	pm[11] = rx[8];
	pm[13] = rx[9];
	pm[14] = tx[8];
	pm[15] = rx[11];
	pm[17] = rx[10];
	pm[19] = rx[12];
	for (index = 0; index < 6; index++) {
		pm[20 + index] = tx[13 + index];
		pm[26 + index] = rx[15 + index];
	}
	pm[33] = rx[13];
	pm[34] = tx[7];
	pm[35] = rx[8];
}

static int rtl_ni_pm_read(struct device *ni, unsigned int port,
	unsigned long long pm[RTL_CTC_PM_COUNTERS])
{
	u64 total[RTL9617C_NI_MIB_COUNTERS];
	int ret = rtl9617c_ni_mib_read(ni, port, total);

	if (!ret)
		rtl_ni_mib_pm(total, pm);
	return ret;
}

static void rtl_epon_mib_pm(unsigned long long total[RTL_EPON_MIB_COUNTERS],
	const unsigned int raw[RTL_EPON_MIB_COUNTERS], unsigned long long pm[RTL_CTC_PM_COUNTERS])
{
	unsigned int index;
	const unsigned long long *rx = total, *tx = total + 21;

	for (index = 0; index < RTL_EPON_MIB_COUNTERS; index++) {
		if (index % 21 < 2)
			continue;
		rtl_mib_extend(total + index, raw[index], 0);
	}
	total[0] = (unsigned long long)raw[1] << 32 | raw[0];
	total[21] = (unsigned long long)raw[22] << 32 | raw[21];
	for (index = 0; index < RTL_CTC_PM_COUNTERS; index++)
		pm[index] = 0;
	pm[2] = rx[0];
	pm[3] = tx[0];
	pm[4] = rx[3] + rx[4] + rx[5];
	pm[5] = tx[3] + tx[4] + tx[5];
	pm[6] = rx[5];
	pm[7] = tx[5];
	pm[8] = rx[4];
	pm[9] = tx[4];
	pm[10] = rx[2];
	pm[11] = tx[2];
	pm[12] = rx[9];
	pm[13] = tx[9];
	pm[14] = rx[10];
	pm[15] = tx[10];
	for (index = 0; index < 6; index++) {
		pm[20 + index] = rx[11 + index];
		pm[26 + index] = tx[11 + index];
	}
	pm[34] = rx[2];
	pm[35] = tx[2];
}


int rtl_pon_epon_pm(struct rtl9617c_pon *pon, unsigned long long counters[37])
{
	const struct rtl_dq_io io = {pon, rtl_crypto_read, rtl_crypto_write, rtl_crypto_indirect};
	unsigned int raw[RTL_EPON_MIB_COUNTERS];
	int ret;

	lockdep_assert_held(&pon->lock);
	if (!rtl_pon_mode_is_epon(pon->mode))
		return -EOPNOTSUPP;
	if (!pon->mac_prepared)
		return -EAGAIN;
	ret = rtl_epon_mib_read(&io, raw);
	if (!ret)
		rtl_epon_mib_pm(pon->epon_mib_total, raw, counters);
	return ret;
}

#define RTL_PON_PM_RECORD_BYTES (8 + 37 * 8)
static ssize_t pm_counters_read(struct file *file, struct kobject *kobj,
	const struct bin_attribute *attr, char *buf, loff_t offset, size_t count)
{
	struct rtl9617c_pon *pon = dev_get_drvdata(kobj_to_dev(kobj));
	unsigned long long counters[37];
	unsigned int port = offset / RTL_PON_PM_RECORD_BYTES;
	int ret;

	if (port >= 5 || offset % RTL_PON_PM_RECORD_BYTES || count < RTL_PON_PM_RECORD_BYTES)
		return -EINVAL;
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	ret = port ? rtl_ni_pm_read(pon->ni_dev, pon->uni_ports[port - 1],
		counters) : rtl_pon_epon_pm(pon, counters);
	if (!ret) {
		put_unaligned_be64(port ? 0 : pon->epon_mib_generation, buf);
		for (unsigned int i = 0; i < 37; i++)
			put_unaligned_be64(counters[i], buf + 8 + i * 8);
	}
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	return ret ?: RTL_PON_PM_RECORD_BYTES;
}
BIN_ATTR(pm_counters, 0400, pm_counters_read, NULL, 5 * RTL_PON_PM_RECORD_BYTES);
