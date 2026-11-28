/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_SOC_REALTEK_TAURUS_SOC_H
#define _LINUX_SOC_REALTEK_TAURUS_SOC_H

struct taurus_soc_data {
	u32 vendor_id;
	u32 chip_id;
	u8 chip_revision;
	u32 chipmode;
};

int taurus_soc_data_get(struct taurus_soc_data *data);
unsigned int taurus_soc_refclk_khz(void);

#endif
