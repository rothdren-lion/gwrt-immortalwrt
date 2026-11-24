// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause

#include <linux/nvmem-consumer.h>

#include "core.h"
#include "debug.h"
#include "rtw89_factory.h"

#define RTW89_FACTORY_CELL_NAME		"wifi-calibration"
#define RTW89_FACTORY_MAGIC		"TYFC0003"
#define RTW89_FACTORY_MIN_LEN		0x11c

#define RTW89_FACTORY_CAL_OFF_GAIN	0x08
#define RTW89_FACTORY_CAL_OFF_THERM	0x0d
#define RTW89_FACTORY_CAL_OFF_XTAL	0x0f
#define RTW89_FACTORY_CAL_OFF_TSSI	0x10
#define RTW89_FACTORY_CAL_OFF_MAC	0x42
#define RTW89_FACTORY_CAL_OFF_DIFF	0x48

static struct rtw89_factory_cal rtw89_factory_cals[RTW89_FACTORY_RADIO_NUM];
static bool rtw89_factory_loaded[RTW89_FACTORY_RADIO_NUM];

static int rtw89_factory_nvmem_read(struct rtw89_dev *rtwdev, const char *name,
				    u8 **buf, size_t *len)
{
	struct nvmem_cell *cell;
	void *data;

	cell = nvmem_cell_get(rtwdev->dev, name);
	if (IS_ERR(cell))
		return PTR_ERR(cell);

	data = nvmem_cell_read(cell, len);
	nvmem_cell_put(cell);
	if (IS_ERR(data))
		return PTR_ERR(data);

	*buf = data;

	return 0;
}

static void rtw89_factory_parse_radio(struct rtw89_factory_cal *cal,
				      const u8 *blk, size_t len)
{
	u32 i, j, ofst;

	if (len < RTW89_FACTORY_MIN_LEN ||
	    memcmp(blk, RTW89_FACTORY_MAGIC, 8) != 0)
		return;

	cal->valid = true;

	cal->gain_valid = false;
	for (i = 0; i < 5; i++) {
		u8 data = blk[RTW89_FACTORY_CAL_OFF_GAIN + i];

		if (data == 0xff)
			continue;

		cal->gain_valid = true;
		cal->gain_offset[RF_PATH_A][i] =
			sign_extend32(u8_get_bits(data, GENMASK(7, 4)), 3);
		cal->gain_offset[RF_PATH_B][i] =
			sign_extend32(u8_get_bits(data, GENMASK(3, 0)), 3);
	}

	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		cal->thermal[i] = blk[RTW89_FACTORY_CAL_OFF_THERM + i];

	cal->xtal = blk[RTW89_FACTORY_CAL_OFF_XTAL];

	cal->tssi_valid = false;
	ofst = RTW89_FACTORY_CAL_OFF_TSSI;
	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		for (j = 0; j < RTW89_FACTORY_TSSI_CCK_NUM; j++) {
			cal->tssi_cck[i][j] = (s8)blk[ofst++];
			if (cal->tssi_cck[i][j] != (s8)0xff)
				cal->tssi_valid = true;
		}

	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		for (j = 0; j < RTW89_FACTORY_TSSI_MCS_2G_NUM; j++)
			cal->tssi_mcs_2g[i][j] = (s8)blk[ofst++];

	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		for (j = 0; j < RTW89_FACTORY_TSSI_MCS_5G_NUM; j++)
			cal->tssi_mcs_5g[i][j] = (s8)blk[ofst++];

	ether_addr_copy(cal->mac, blk + RTW89_FACTORY_CAL_OFF_MAC);

	ofst = RTW89_FACTORY_CAL_OFF_DIFF;
	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++)
		for (j = 0; j < RTW89_FACTORY_TSSI_DIFF_NUM; j++) {
			cal->tssi_gain_diff[i][j] =
				(s8)blk[ofst + i * RTW89_FACTORY_TSSI_DIFF_NUM + j];
			cal->tssi_cw_diff[i][j] =
				(s8)blk[ofst + (RTW89_FACTORY_PATH_NUM + i) * RTW89_FACTORY_TSSI_DIFF_NUM + j];
		}

}

struct rtw89_factory_cal *rtw89_factory_cal_get(struct rtw89_dev *rtwdev,
						enum rtw89_factory_radio radio)
{
	struct rtw89_factory_cal *cal;
	u8 *buf;
	size_t len;
	int ret;

	if (radio >= RTW89_FACTORY_RADIO_NUM)
		return NULL;

	cal = &rtw89_factory_cals[radio];
	if (rtw89_factory_loaded[radio])
		return cal->valid ? cal : NULL;

	ret = rtw89_factory_nvmem_read(rtwdev, RTW89_FACTORY_CELL_NAME,
				       &buf, &len);
	if (!ret) {
		rtw89_factory_parse_radio(cal, buf, len);
		kfree(buf);
	}

	if (cal->valid)
		rtw89_debug(rtwdev, RTW89_DBG_FW,
			    "factory radio%d valid=%d mac=%pM xtal=0x%x thermal=%d/%d gain=%d tssi=%d\n",
			    radio, cal->valid, cal->mac, cal->xtal,
			    cal->thermal[RF_PATH_A], cal->thermal[RF_PATH_B],
			    cal->gain_valid, cal->tssi_valid);
	else
		rtw89_debug(rtwdev, RTW89_DBG_FW,
			    "factory radio%d not available ret=%d\n",
			    radio, ret);

	if (!cal->valid)
		memset(cal, 0, sizeof(*cal));

	rtw89_factory_loaded[radio] = true;

	return cal->valid ? cal : NULL;
}

void rtw89_factory_fill_efuse(struct rtw89_efuse *efuse,
			      struct rtw89_factory_cal *cal)
{
	if (is_valid_ether_addr(cal->mac)) {
		ether_addr_copy(efuse->addr, cal->mac);
		efuse->valid = true;
	}

	if (cal->xtal != 0xff)
		efuse->xtal_cap = cal->xtal;
}

void rtw89_factory_fill_gain(struct rtw89_dev *rtwdev,
			     struct rtw89_factory_cal *cal)
{
	struct rtw89_phy_efuse_gain *gain = &rtwdev->efuse_gain;
	u8 path, i;

	if (!cal->gain_valid)
		return;

	for (path = 0; path < RTW89_FACTORY_PATH_NUM; path++)
		for (i = 0; i < RTW89_GAIN_OFFSET_NR; i++)
			gain->offset[path][i] = cal->gain_offset[path][i];
	gain->offset_valid = true;
}

void rtw89_factory_fill_tssi(struct rtw89_dev *rtwdev,
			     struct rtw89_factory_cal *cal)
{
	struct rtw89_tssi_info *tssi = &rtwdev->tssi;
	u8 i;

	if (!cal->tssi_valid)
		return;

	for (i = 0; i < RTW89_FACTORY_PATH_NUM; i++) {
		if (cal->thermal[i] != 0xff)
			tssi->thermal[i] = cal->thermal[i];
		memcpy(tssi->tssi_cck[i], cal->tssi_cck[i],
		       RTW89_FACTORY_TSSI_CCK_NUM);
		memcpy(tssi->tssi_mcs[i], cal->tssi_mcs_2g[i],
		       RTW89_FACTORY_TSSI_MCS_2G_NUM);
		memcpy(tssi->tssi_mcs[i] + RTW89_FACTORY_TSSI_MCS_2G_NUM,
		       cal->tssi_mcs_5g[i], RTW89_FACTORY_TSSI_MCS_5G_NUM);
	}
}
