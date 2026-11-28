/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_SOC_REALTEK_TAURUS_LEDS_H
#define _LINUX_SOC_REALTEK_TAURUS_LEDS_H

#define TAURUS_LED_TRIGGER_HW_RX	0
#define TAURUS_LED_TRIGGER_HW_TX	1
#define TAURUS_LED_TRIGGER_SW		2
#define TAURUS_LED_TRIGGER_NONE		3

#define TAURUS_LED_BLINK_RATE1		0
#define TAURUS_LED_BLINK_RATE2		1

void taurus_led_set_all(int control);
int taurus_led_get_all(void);
int taurus_led_test_mode(int enable);
int taurus_led_config(int idx, int active_low, int off_event, int blink_event,
		      int on_event, int port, int blink);
int taurus_led_enable(int idx, int enable);
int taurus_led_sw_on(int idx, int on);

#endif
