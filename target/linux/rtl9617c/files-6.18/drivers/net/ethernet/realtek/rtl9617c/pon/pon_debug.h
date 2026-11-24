/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Runtime observation surface for the RTL9617C PON block.
 *
 * Everything here is compiled into rtl9617c-pon.ko: the debugfs directory is
 * created by pon_main.c at the end of probe and removed again on removal. With
 * debug=0 and debug_poke=0 the only steady-state cost is the fixed-size event
 * ring, which stores raw u32 fields and never formats a string.
 */
#ifndef RTL9617C_PON_DEBUG_H
#define RTL9617C_PON_DEBUG_H
#include <linux/types.h>

struct dentry;
struct rtl9617c_pon;

enum pon_event_code {
	PON_EV_MPCP_CONFIG = 1,
	PON_EV_MPCP_STOP,
	PON_EV_MPCP_REGISTER,
	PON_EV_MPCP_NACK,
	PON_EV_MPCP_SYNC,
	PON_EV_OAM_TX,
	PON_EV_OAM_RX,
	PON_EV_OMCI_TX,
	PON_EV_OMCI_RX,
	PON_EV_PDC_CONFIG,
	PON_EV_PUC_CONFIG,
	PON_EV_PLOAM_TX,
	PON_EV_PLOAM_RX,
	PON_EV_GPON_STATE,
	PON_EV_XGPON_STATE,
	PON_EV_ITU_PATHS,
	PON_EV_IRQ,
	PON_EV_ERROR,
	PON_EV_COUNT
};

/*
 * One ring record. Meaning is per code; the ring only ever stores numbers and
 * never formats or allocates.
 *   MPCP_CONFIG/STOP   a=result  b=llid_count c=registered
 *   MPCP_REGISTER      a=new registered mask b=old mask c=waiting
 *   MPCP_NACK          a=nacks   b=register_flag c=active
 *   MPCP_SYNC          a=synced  b=registered c=waiting (emitted when a
 *                      registration attempt is started)
 *   OAM_TX             a=llid    b=length    c=queue
 *   OAM_RX             a=llid    b=length    c=source
 *   OMCI_RX/OMCI_TX    a=wire byte0 b=wire byte1 c=body length
 *                      (the transport never decodes OMCI type/tid, so the two
 *                       leading wire bytes are stored verbatim, not re-parsed)
 *   PLOAM_RX           a=PLoam byte1 b=PLoam byte2 c=result
 *                      (GPON framing: byte0=ONU-ID, byte1=type, byte2=seq; the
 *                       transmit path indexes buf[1] as type, buf[2] as seq)
 *   PLOAM_TX           a=PLoam byte1 b=requested bytes c=result
 *   PDC_CONFIG/PUC_CONFIG  a=result b=driver error c=configured flag
 *   ITU_PATHS          a=result  b=path count c=session epoch low word
 *   GPON/XGPON_STATE   enter: a=enable/recover, exit: a=result b=onu_id or
 *                      recovery phase c=drain phase / activation error
 *   IRQ                a=block (1 GPON, 2 XGPON, 3 XGPON optical)
 *                      b=status  c=irq counter
 *   ERROR              a=call site id b=offset c=value (reg_write poke only)
 */
struct pon_event {
	u64 ns;
	u16 code;
	u8 mode;
	u8 phase;	/* 0 enter, 1 exit/ok, 2 drop/error */
	u32 a;
	u32 b;
	u32 c;
};

void pon_event(struct rtl9617c_pon *pon, unsigned int code, u32 a, u32 b, u32 c);
void pon_event_at(struct rtl9617c_pon *pon, unsigned int code, u8 phase,
		  u32 a, u32 b, u32 c);
bool pon_event_last(unsigned int code, struct pon_event *out);
struct rtl9617c_pon *pon_debug_pon(void);

int pon_debug_init(struct rtl9617c_pon *pon);
void pon_debug_remove(struct rtl9617c_pon *pon);
int pon_debug_events_init(struct dentry *dir);
int pon_debug_regs_init(struct dentry *dir);

extern unsigned int rtl9617c_pon_debug;
extern bool pon_debug_poke;

#define pon_dbg(fmt, ...)						\
	do {								\
		if (rtl9617c_pon_debug)					\
			pr_debug(fmt, ##__VA_ARGS__);			\
	} while (0)

#endif
