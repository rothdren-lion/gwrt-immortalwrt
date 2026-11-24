// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause

#ifndef __RTW89_FACTORY_H__
#define __RTW89_FACTORY_H__

#include "core.h"

enum rtw89_factory_radio {
	RTW89_FACTORY_RADIO_5G,
	RTW89_FACTORY_RADIO_2G,
	RTW89_FACTORY_RADIO_NUM,
};

#define RTW89_FACTORY_PATH_NUM		2
#define RTW89_FACTORY_TSSI_CCK_NUM	6
#define RTW89_FACTORY_TSSI_MCS_2G_NUM	5
#define RTW89_FACTORY_TSSI_MCS_5G_NUM	14
#define RTW89_FACTORY_TSSI_DIFF_NUM	(RTW89_FACTORY_TSSI_CCK_NUM + \
					 RTW89_FACTORY_TSSI_MCS_2G_NUM + \
					 RTW89_FACTORY_TSSI_MCS_5G_NUM)

struct rtw89_factory_cal {
	bool valid;
	bool gain_valid;
	bool tssi_valid;
	u8 mac[ETH_ALEN];
	u8 xtal;
	u8 thermal[RTW89_FACTORY_PATH_NUM];
	s8 gain_offset[RTW89_FACTORY_PATH_NUM][RTW89_GAIN_OFFSET_NR];
	s8 tssi_cck[RTW89_FACTORY_PATH_NUM][RTW89_FACTORY_TSSI_CCK_NUM];
	s8 tssi_mcs_2g[RTW89_FACTORY_PATH_NUM][RTW89_FACTORY_TSSI_MCS_2G_NUM];
	s8 tssi_mcs_5g[RTW89_FACTORY_PATH_NUM][RTW89_FACTORY_TSSI_MCS_5G_NUM];
	s8 tssi_gain_diff[RTW89_FACTORY_PATH_NUM][RTW89_FACTORY_TSSI_DIFF_NUM];
	s8 tssi_cw_diff[RTW89_FACTORY_PATH_NUM][RTW89_FACTORY_TSSI_DIFF_NUM];
};

struct rtw89_factory_cal *rtw89_factory_cal_get(struct rtw89_dev *rtwdev,
						enum rtw89_factory_radio radio);
void rtw89_factory_fill_efuse(struct rtw89_efuse *efuse,
			      struct rtw89_factory_cal *cal);
void rtw89_factory_fill_gain(struct rtw89_dev *rtwdev,
			     struct rtw89_factory_cal *cal);
void rtw89_factory_fill_tssi(struct rtw89_dev *rtwdev,
			     struct rtw89_factory_cal *cal);

#endif
