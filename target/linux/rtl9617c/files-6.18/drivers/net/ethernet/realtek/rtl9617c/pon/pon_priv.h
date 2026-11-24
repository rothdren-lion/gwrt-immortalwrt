/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Internal to drivers/net/ethernet/realtek/rtl9617c/pon/: register access
 * shorthands plus the few entry points that are not part of pon.h. Nothing in
 * here is used from fe/ or ni/.
 */
#ifndef RTL9617C_PON_PRIV_H
#define RTL9617C_PON_PRIV_H
#include <linux/io.h>
#include "pon/pon.h"

/* The PON MAC register window is the base every submodule works on. */
static inline u32 rtl_pon_rd(struct rtl9617c_pon *pon, u32 reg)
{
	return readl(pon->mac + reg);
}

static inline void rtl_pon_wr(struct rtl9617c_pon *pon, u32 reg, u32 value)
{
	writel(value, pon->mac + reg);
}

/* PUC register map: one definition, shared by the EPON scheduler and the
 * ITU carrier/queue programming. */
#define PVT_ACCESS 0x8000
#define PVT_DATA0 0x8014
#define BTC 0x8050
#define REPORT 0x8054
#define REPORT_Q12 0x8078
#define REPORT_Q34 0x807c
#define BM_STATUS 0x8088
#define PUC_CONFIG 0x808c
#define LIMIT_SELECT 0x8090
#define LIMIT_A 0x80d0
#define BACKPRESSURE 0x80e4
#define PUC_IE 0x80f4
#define CONTROL 0x813c
#define CONTROL1 0x8140
#define CONTROL2 0x8144
#define PUC_STATUS 0x8148
#define VALID_VOQ0 0x81bc
#define CIR_ACCESS 0x81c4
#define CIR_DATA1 0x81c8
#define CIR_DATA0 0x81cc
#define PIR_ACCESS 0x81ec
#define PIR_DATA1 0x81f0
#define PIR_DATA0 0x81f4
#define AGGREGATE1 0x81f8
#define AGGREGATE0 0x81fc
/* PDC downstream map, shared with the ITU path programmer. */
#define PDC_COUNTER 0x9000
#define PDC_CTRL 0x9014
#define PDC_ACCESS 0x9020
#define PDC_DATA1 0x9024
#define PDC_DATA0 0x9028

/* The backpressure table shares the VOQ mode window at 0x804c. */
#define VOQ_MODE 0x804c

/* rtl_dq_io callbacks: the context is the struct rtl9617c_pon. */
unsigned int rtl_puc_bp_read(void *context, unsigned int index);
void rtl_puc_bp_write(void *context, unsigned int index, unsigned int value);
int rtl_puc_bp_access(void *context, unsigned int index, unsigned int value);
int rtl_puc_token_buckets(struct rtl9617c_pon *pon, unsigned int first);
void rtl_omci_prefix(unsigned char prefix[16], unsigned int wire_length,
		     unsigned char priority);
int rtl_omci_mic(struct rtl9617c_pon *pon, u8 direction, const u8 *data,
		 unsigned int bytes, u8 mic[4]);

/*
 * Register window map. Each name is "<window>_<offset>": the offset is
 * relative to that block and centralised here on purpose, so a datasheet
 * mnemonic can be substituted in one place once the manual is available.
 * The driver-visible base of every window is documented with the field
 * decoder that reads it (see rtl_pon_mode_name() callers in the headers).
 */
#define RTL_EPON_0010	0x0010
#define RTL_EPON_0024	0x0024
#define RTL_EPON_0064	0x0064
#define RTL_EPON_01A0	0x01a0
#define RTL_EPON_01A4	0x01a4
#define RTL_EPON_01C0	0x01c0
#define RTL_EPON_01C4	0x01c4
#define RTL_EPON_01C8	0x01c8
#define RTL_EPON_0810	0x0810
#define RTL_EPON_10B8	0x10b8
#define RTL_EPON_1370	0x1370
#define RTL_EPON_1374	0x1374
#define RTL_EPON_137C	0x137c
#define RTL_EPON_13D0	0x13d0
#define RTL_EPON_14C0	0x14c0
#define RTL_EPON_2120	0x2120
#define RTL_XGTC_4004	0x4004
#define RTL_XGTC_4008	0x4008
#define RTL_XGTC_400C	0x400c
#define RTL_XGTC_402C	0x402c
#define RTL_XGTC_4118	0x4118
#define RTL_XGTC_411C	0x411c
#define RTL_XGTC_4124	0x4124
#define RTL_XGTC_4128	0x4128
#define RTL_XGTC_412C	0x412c
#define RTL_XGTC_452C	0x452c
#define RTL_XGTC_4600	0x4600
#define RTL_XGTC_4860	0x4860
#define RTL_XGTC_4AA4	0x4aa4
#define RTL_XGTC_4AA8	0x4aa8
#define RTL_XGTC_4AB8	0x4ab8
#define RTL_XGTC_4AFC	0x4afc
#define RTL_XGTC_4B28	0x4b28
#define RTL_XGTC_4B2C	0x4b2c
#define RTL_XGTC_4C50	0x4c50
#define RTL_XGTC_4D00	0x4d00
#define RTL_XGTC_4D0C	0x4d0c
#define RTL_XGTC_4D10	0x4d10
#define RTL_XGTC_4D1C	0x4d1c
#define RTL_XGTC_4D20	0x4d20
#define RTL_XGTC_4D28	0x4d28
#define RTL_XGTC_4D2C	0x4d2c
#define RTL_XGTC_4D30	0x4d30
#define RTL_XGTC_4D98	0x4d98
#define RTL_XGTC_4E00	0x4e00
#define RTL_XGTC_4E04	0x4e04
#define RTL_GPON_6030	0x6030
#define RTL_GPON_6088	0x6088
#define RTL_GPON_608C	0x608c
#define RTL_GPON_6090	0x6090
#define RTL_GPON_60BC	0x60bc
#define RTL_GPON_60C8	0x60c8
#define RTL_GPON_60E0	0x60e0
#define RTL_GPON_6114	0x6114
#define RTL_GPON_6118	0x6118
#define RTL_GPON_612C	0x612c
#define RTL_GPON_6130	0x6130
#define RTL_GPON_6138	0x6138
#define RTL_GPON_6170	0x6170
#define RTL_GPON_6174	0x6174
#define RTL_GPON_61C4	0x61c4
#define RTL_PUC_8030	0x8030
#define RTL_PUC_8034	0x8034
#define RTL_PUC_80DC	0x80dc
#define RTL_PUC_80E0	0x80e0
#define RTL_PUC_80EC	0x80ec
#define RTL_PUC_80F8	0x80f8
#define RTL_PUC_80FC	0x80fc
#define RTL_PUC_814C	0x814c
#define RTL_PUC_8150	0x8150
#define RTL_PUC_8154	0x8154
#define RTL_PUC_8158	0x8158
#define RTL_PUC_815C	0x815c
#define RTL_PUC_81B0	0x81b0
#define RTL_PUC_81B4	0x81b4
#define RTL_PUC_81B8	0x81b8
#define RTL_PUC_8230	0x8230
#define RTL_PUC_8234	0x8234
#define RTL_SERDES_A060	0xa060
#define RTL_SERDES_A064	0xa064
#define RTL_SERDES_A084	0xa084

#endif
