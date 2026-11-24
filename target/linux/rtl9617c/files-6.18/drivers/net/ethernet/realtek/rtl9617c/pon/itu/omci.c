// SPDX-License-Identifier: GPL-2.0-or-later

/* OMCI key derivation and the dying-gasp trap; the raw transport lives

 * in omci_channel.c. */

#include <linux/if_arp.h>
#include <linux/netdevice.h>
#include <linux/unaligned.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/interrupt.h>
#include <linux/platform_device.h>
#include <linux/random.h>
#include <crypto/aes.h>
#include <crypto/hash.h>
#include "pon/pon.h"
#include "pon/pon_priv.h"
#include "pon/itu/xgpon_hw.h"
#define RTL_OMCI_PREFIX_BYTES 16

/* Original ca_generate_msk -> ca_generate_sk, with Class332 MSK replacement. */

static int rtl_omci_session_key(void *context,
	int (*cmac)(void *, const unsigned char *, const unsigned char *, unsigned int, unsigned char *),
	const unsigned char serial[8], const unsigned char registration[36],
	const unsigned char tag[8], const unsigned char *supplied_msk, unsigned char result[16])
{
	unsigned char root[16], msk[16], message[24];
	unsigned int i;
	int ret = 0;

	for (i = 0; i < 16; i++) root[i] = 0x55;
	if (supplied_msk)
		for (i = 0; i < 16; i++) msk[i] = supplied_msk[i];
	else
		ret = cmac(context, root, registration, 36, msk);
	if (ret) return ret;
	for (i = 0; i < 8; i++) { message[i] = serial[i]; message[i + 8] = tag[i]; }
	for (i = 0; i < 8; i++) message[i + 16] = "SessionK"[i];
	ret = cmac(context, msk, message, 24, result);
	for (i = 0; i < 16; i++) msk[i] = 0;
	return ret;
}

static unsigned int key_read(void *context, unsigned int address)
{
	return readl(((struct rtl9617c_pon *)context)->mac + address);
}

static void key_write(void *context, unsigned int address, unsigned int value)
{
	writel(value, ((struct rtl9617c_pon *)context)->mac + address);
}

static int rtl_omci_cmac(void *context, const u8 *key, const u8 *data, unsigned int bytes, u8 *result)
{
	struct crypto_shash *tfm = context;
	SHASH_DESC_ON_STACK(desc, tfm);
	int ret = crypto_shash_setkey(tfm, key, 16);

	desc->tfm = tfm;
	if (!ret) ret = crypto_shash_digest(desc, data, bytes, result);
	shash_desc_zero(desc);
	return ret;
}

static int rtl_xgpon_generate_data_key(struct rtl9617c_pon *pon, unsigned int index)
{
	const struct rtl_dq_io io = {pon, key_read, key_write, NULL};
	static const u8 name_suffix[16] = "3141592653589793";
	struct crypto_aes_ctx aes;
	u8 key[16], name[32];
	int ret;

	get_random_bytes(key, 16);
	ret = aes_expandkey(&aes, pon->xgpon_kek, 16);
	if (ret) goto out;
	aes_encrypt(&aes, pon->xgpon_encrypted_key[index], key);
	memcpy(name, key, 16);
	memcpy(name + 16, name_suffix, 16);
	ret = rtl_omci_cmac(pon->omci_kdf, pon->xgpon_kek, name, 32, pon->xgpon_key_name[index]);
	if (!ret) {
		rtl_xgpon_data_key(&io, index, key);
		pon->xgpon_key_valid |= BIT(index);
	}
out:
	memzero_explicit(key, sizeof(key));
	memzero_explicit(name, sizeof(name));
	memzero_explicit(&aes, sizeof(aes));
	return ret;
}

int rtl_pon_xgpon_ack_update(struct rtl9617c_pon *pon)
{
	const struct rtl_dq_io io = {pon, key_read, key_write, NULL};

	lockdep_assert_held(&pon->lock);
	return rtl_xgpon_ack_no_message(&io, pon->omci_kdf, rtl_omci_cmac,
		pon->xgpon_ploam_ik, readl(pon->mac + RTL_XGTC_412C) & 0xffff);
}

int rtl_pon_xgpon_omci_key(struct rtl9617c_pon *pon, const u8 tag[8])
{
	const struct rtl_dq_io io = {pon, key_read, key_write, NULL};
	static const u8 omci_label[16] = "OMCIIntegrityKey";
	static const u8 kek_label[16] = "KeyEncryptionKey";
	/* Exact16-byte label used by this board's ca_generate_ploam_ik. */
	static const u8 ploam_label[16] = "PLOAMIntegrtyKey";
	u8 key[16], session[16], integrity[16];
	int ret;

	lockdep_assert_held(&pon->lock);
	if (pon->xgpon_key_ready && !memcmp(pon->xgpon_tag, tag, 8)) return 0;
	rtl_pon_dying_gasp_stop(pon);
	spin_lock_bh(&pon->omci_key_lock);
	pon->xgpon_key_ready = false;
	spin_unlock_bh(&pon->omci_key_lock);
	ret = rtl_omci_session_key(pon->omci_kdf, rtl_omci_cmac, pon->xgpon_serial,
		pon->xgpon_registration, tag, pon->omci_master_key_valid ? pon->omci_master_key : NULL, session);
	if (!ret) ret = rtl_omci_cmac(pon->omci_kdf, session, omci_label, 16, key);
	if (!ret) ret = rtl_omci_cmac(pon->omci_kdf, session, kek_label, 16, pon->xgpon_kek);
	if (!ret) ret = rtl_omci_cmac(pon->omci_kdf, session, ploam_label, 16, integrity);
	if (!ret && pon->omci_master_key_valid) {
		rtl_pon_update(pon->mac + RTL_XGTC_4E00, BIT(6), 0);
		rtl_xgpon_key_words(&io, 0x4e14, pon->omci_master_key);
		rtl_xgpon_key_words(&io, 0x4e24, session);
		rtl_pon_update(pon->mac + RTL_XGTC_4E04, BIT(2), BIT(2));
		rtl_xgpon_key_words(&io, 0x4e34, integrity);
		rtl_pon_update(pon->mac + RTL_XGTC_4E04, BIT(3), BIT(3));
	}
	if (!ret) {
		memcpy(pon->xgpon_ploam_ik, integrity, 16);
		if (pon->xgpon_omcc_ready)
			ret = rtl_pon_xgpon_ack_update(pon);
	}
	if (!ret) {
		/* Stock session derivation installs both slots under the new KEK. */
		pon->xgpon_key_valid = 0;
		ret = rtl_xgpon_generate_data_key(pon, 0);
		if (!ret) ret = rtl_xgpon_generate_data_key(pon, 1);
	}
	if (!ret) {
		spin_lock_bh(&pon->omci_key_lock);
		ret = crypto_shash_setkey(pon->omci_cmac, key, 16);
		pon->xgpon_key_ready = !ret;
		if (!ret) memcpy(pon->xgpon_tag, tag, 8);
		spin_unlock_bh(&pon->omci_key_lock);
	}
	memzero_explicit(key, sizeof(key));
	memzero_explicit(session, sizeof(session));
	memzero_explicit(integrity, sizeof(integrity));
	if (!ret)
		rtl_pon_dying_gasp_prepare(pon);
	return ret;
}

ssize_t rtl_pon_omci_master_key(struct rtl9617c_pon *pon, const char *buf, size_t count)
{
	u8 master[16], tag[8];
	int ret;

	if (count != 32) return -EMSGSIZE;
	ret = hex2bin(master, buf, 16);
	if (ret) return ret;
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	memcpy(pon->omci_master_key, master, 16);
	pon->omci_master_key_valid = true;
	ret = 0;
	if (pon->mode == RTL_PON_XGPON || pon->mode == RTL_PON_XGSPON) {
		memcpy(tag, pon->xgpon_tag, 8);
		spin_lock_bh(&pon->omci_key_lock);
		pon->xgpon_key_ready = false;
		spin_unlock_bh(&pon->omci_key_lock);
		ret = rtl_pon_xgpon_omci_key(pon, tag);
	}
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	memzero_explicit(master, sizeof(master));
	return ret ? ret : count;
}

void rtl_pon_xgpon_key_irq(struct rtl9617c_pon *pon, u32 interrupts, u32 control)
{
	const struct rtl_dq_io io = {pon, key_read, key_write, NULL};
	u8 message[40] = {};
	u32 status;
	unsigned int flag = (control >> 8) & 255, index = (control >> 16) & 255;
	int ret = 0;

	lockdep_assert_held(&pon->lock);
	if (interrupts & BIT(7)) {
		if (!pon->xgpon_key_ready || index < 1 || index > 2 || flag > 1) { ret = -EPROTO; goto error; }
		index--;
		if (!flag) {
			ret = rtl_xgpon_generate_data_key(pon, index);
			if (ret) goto error;
			rtl_pon_update(pon->mac + RTL_XGTC_4124, BIT(index), BIT(index));
			if (pon->xgpon_key_state != 4 || pon->xgpon_active_key != index)
				pon->xgpon_key_state = 2;
		} else {
			if (!(pon->xgpon_key_valid & BIT(index))) { ret = -ENOKEY; goto error; }
			rtl_xgpon_key_confirm(&io, index);
			pon->xgpon_active_key = index;
			if (pon->xgpon_key_state == 2) pon->xgpon_key_state = 4;
		}
		rtl_xgpon_key_report(message, pon->xgpon_omcc_id, control,
			flag ? pon->xgpon_key_name[index] : pon->xgpon_encrypted_key[index]);
		ret = readl_poll_timeout(pon->mac + RTL_XGTC_4AFC, status, !(status & BIT(31)), 1, 10000);
		if (!ret) {
			rtl_xgpon_ploam_transmit(&io, message, false);
			pon->xgpon_key_reports++; pon->ploam_tx++;
		}
	}
error:
	if (interrupts & BIT(5)) {
		pon->xgpon_key_tk4++;
		if (pon->xgpon_key_state == 2) pon->xgpon_key_state = 0;
	}
	if (interrupts & BIT(6)) pon->xgpon_key_tk5++;
	if (ret) pon->xgpon_activation_error = ret;
}

ssize_t rtl_pon_omci_broadcast_key(struct rtl9617c_pon *pon, const char *buf, size_t count)
{
	const struct rtl_dq_io io = {pon, key_read, key_write, NULL};
	const u8 *row = (const u8 *)buf;
	struct crypto_aes_ctx aes;
	u8 key[16] = {};
	unsigned int operation, slot;
	int ret = 0;

	if (count != 18) return -EMSGSIZE;
	operation = row[0]; slot = row[1] >> 6;
	if (operation > 2 || (operation != 2 && ((row[1] & 63) || slot < 1 || slot > 2))) return -EINVAL;
	mutex_lock(&pon->control_lock);
	mutex_lock(&pon->lock);
	if (pon->mode != RTL_PON_XGPON && pon->mode != RTL_PON_XGSPON) { ret = -EOPNOTSUPP; goto out; }
	if (!operation) {
		if (!pon->xgpon_key_ready) { ret = -ENOKEY; goto out; }
		ret = aes_expandkey(&aes, pon->xgpon_kek, 16);
		if (ret) goto out;
		aes_decrypt(&aes, key, row + 2);
		rtl_xgpon_multicast_key(&io, slot - 1, key, true);
	} else if (operation == 1) {
		rtl_xgpon_multicast_key(&io, slot - 1, key, false);
	} else {
		rtl_xgpon_multicast_key(&io, 0, key, false);
		rtl_xgpon_multicast_key(&io, 1, key, false);
	}
out:
	mutex_unlock(&pon->lock);
	mutex_unlock(&pon->control_lock);
	memzero_explicit(key, sizeof(key));
	memzero_explicit(&aes, sizeof(aes));
	return ret ? ret : count;
}

int rtl_omci_mic(struct rtl9617c_pon *pon, u8 direction, const u8 *data, unsigned int bytes, u8 mic[4])
{
	SHASH_DESC_ON_STACK(desc, pon->omci_cmac);
	u8 result[16];
	int ret = -ENOKEY;

	desc->tfm = pon->omci_cmac;
	spin_lock_bh(&pon->omci_key_lock);
	if (pon->xgpon_key_ready) {
		ret = crypto_shash_init(desc);
		if (!ret) ret = crypto_shash_update(desc, &direction, 1);
		if (!ret) ret = crypto_shash_finup(desc, data, bytes, result);
		if (!ret) memcpy(mic, result, 4);
	}
	spin_unlock_bh(&pon->omci_key_lock);
	shash_desc_zero(desc);
	return ret;
}

void rtl_pon_dying_gasp_stop(struct rtl9617c_pon *pon)
{
	struct sk_buff *packet;
	unsigned long flags;

	if (!pon->dying_gasp_registered)
		return;
	writel(0, pon->dying_gasp + 4);
	synchronize_irq(pon->dying_gasp_irq);
	spin_lock_irqsave(&pon->dying_gasp_lock, flags);
	packet = pon->dying_gasp_packet;
	pon->dying_gasp_packet = NULL;
	pon->dying_gasp_sent = false;
	spin_unlock_irqrestore(&pon->dying_gasp_lock, flags);
	dev_kfree_skb_any(packet);
}

void rtl_pon_dying_gasp_prepare(struct rtl9617c_pon *pon)
{
	/* Exact aal_gpon_dg_pdu body; the running session supplies its four-byte MIC. */
	static const u8 body[44] = {[2] = 0x10, [3] = 0x0a, [4] = 1,
		[8] = 1, [39] = 1, [43] = 0x28};
	struct sk_buff *packet;
	unsigned long flags;
	int ret;

	lockdep_assert_held(&pon->lock);
	if (!pon->dying_gasp_registered || !netif_running(pon->omci_device) ||
	    !pon->xgpon_omcc_ready || !pon->xgpon_key_ready ||
	    (readl(pon->mac + RTL_XGTC_4D30) & 7) != 3)
		return;
	spin_lock_irqsave(&pon->dying_gasp_lock, flags);
	if (pon->dying_gasp_packet || pon->dying_gasp_sent) {
		spin_unlock_irqrestore(&pon->dying_gasp_lock, flags);
		return;
	}
	spin_unlock_irqrestore(&pon->dying_gasp_lock, flags);
	packet = alloc_skb(48, GFP_KERNEL);
	if (!packet) {
		ret = -ENOMEM;
		goto error;
	}
	skb_put_data(packet, body, sizeof(body));
	ret = rtl_omci_mic(pon, 2, body, sizeof(body), skb_put(packet, 4));
	if (ret) {
		dev_kfree_skb_any(packet);
		goto error;
	}
	packet->dev = pon->omci_device;
	spin_lock_irqsave(&pon->dying_gasp_lock, flags);
	rtl_omci_prefix(pon->dying_gasp_prefix, 48, 0);
	pon->dying_gasp_packet = packet;
	pon->dying_gasp_error = 0;
	writel(0x105, pon->dying_gasp);
	writel(1, pon->dying_gasp + 4);
	spin_unlock_irqrestore(&pon->dying_gasp_lock, flags);
	return;
error:
	pon->dying_gasp_error = ret;
	dev_err(pon->dev, "XGTC Dying Gasp preparation failed: %d\n", ret);
}

static irqreturn_t rtl_pon_dying_gasp_irq(int irq, void *data)
{
	struct rtl9617c_pon *pon = data;
	struct sk_buff *packet;
	unsigned long flags;
	netdev_tx_t ret;
	const struct rtl9617c_ni_frame frame = {
		.header_high = BIT(13),
		.header_low = 7 | (15 << 3) | (17 << 9) | BIT(29) | (64 << 15),
		.prefix = pon->dying_gasp_prefix, .prefix_length = 16, .raw_payload = true,
	};

	writel(0, pon->dying_gasp + 4);
	spin_lock_irqsave(&pon->dying_gasp_lock, flags);
	packet = pon->dying_gasp_packet;
	pon->dying_gasp_packet = NULL;
	pon->dying_gasp_sent = true;
	if (packet) {
		ret = rtl9617c_ni_transmit(pon->ni_dev, pon->omci_device, packet, &frame);
		if (ret == NETDEV_TX_BUSY) {
			dev_kfree_skb_any(packet);
			pon->dying_gasp_error = -EBUSY;
		} else {
			pon->dying_gasp_tx++;
		}
	}
	spin_unlock_irqrestore(&pon->dying_gasp_lock, flags);
	return IRQ_HANDLED;
}

int rtl_pon_dying_gasp_init(struct rtl9617c_pon *pon, struct platform_device *pdev)
{
	int ret;

	spin_lock_init(&pon->dying_gasp_lock);
	pon->dying_gasp = devm_platform_ioremap_resource_byname(pdev, "dying-gasp");
	if (IS_ERR(pon->dying_gasp))
		return PTR_ERR(pon->dying_gasp);
	pon->dying_gasp_irq = platform_get_irq_byname(pdev, "dying-gasp");
	if (pon->dying_gasp_irq < 0)
		return pon->dying_gasp_irq;
	writel(0, pon->dying_gasp + 4);
	ret = devm_request_irq(pon->dev, pon->dying_gasp_irq, rtl_pon_dying_gasp_irq,
		0, "rtl9617c-pon-dying-gasp", pon);
	if (!ret)
		pon->dying_gasp_registered = true;
	return ret;
}

static ssize_t omci_msk_store(struct device *dev, struct device_attribute *attr,
	const char *buf, size_t count)
{
	return rtl_pon_omci_master_key(dev_get_drvdata(dev), buf, count);
}
DEVICE_ATTR_WO(omci_msk);
