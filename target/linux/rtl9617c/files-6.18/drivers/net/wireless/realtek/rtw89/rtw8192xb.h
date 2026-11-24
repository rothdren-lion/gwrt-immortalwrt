// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause

#ifndef __RTW89_8192XB_H__
#define __RTW89_8192XB_H__

#include "core.h"

#define RF_PATH_NUM_8192XB 2
#define BB_PATH_NUM_8192XB 2

struct rtw8192xb_efuse {
	u8 rsvd[0x38];
	u8 mac_addr[ETH_ALEN];
	u8 rsvd1[0x27a];
	u8 channel_plan;
	u8 xtal_k;
	u8 rsvd2[0x10];
	u8 rfe_type;
	u8 rsvd3[5];
	u8 path_a_therm;
	u8 path_b_therm;
	u8 rsvd4[2];
	u8 rx_gain_2g_ofdm;
	u8 rsvd5;
	u8 rx_gain_2g_cck;
} __packed;

extern const struct rtw89_phy_table rtw89_8192xb_phy_bb_table;
extern const struct rtw89_phy_table rtw89_8192xb_phy_bb_gain_table;
extern const struct rtw89_phy_table rtw89_8192xb_phy_radioa_table;
extern const struct rtw89_phy_table rtw89_8192xb_phy_radiob_table;
extern const struct rtw89_phy_table rtw89_8192xb_phy_nctl_table;
extern const struct rtw89_txpwr_table rtw89_8192xb_byr_table;
extern const struct rtw89_phy_tssi_dbw_table rtw89_8192xb_tssi_dbw_table;
extern const struct rtw89_rfe_parms rtw89_8192xb_dflt_parms;

extern const struct rtw89_chip_info rtw8192xb_chip_info;

#endif
