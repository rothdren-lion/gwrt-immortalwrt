// Defaults for newly detected radios only. Existing UCI radios are never edited.
import { readfile } from 'fs';

function valid_mac(value) {
	value = trim(value ?? '');
	return match(value, /^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$/) &&
		value != '00:00:00:00:00:00' && lc(value) != 'ff:ff:ff:ff:ff:ff' &&
		!(hex(substr(value, 0, 2)) & 1);
}

function mac_suffix(board, macaddr) {
	// Prefer the same Ethernet MAC for all radios, regardless of probe order.
	let label = board.network?.lan?.macaddr;
	for (let value in [readfile('/sys/class/net/eth0/address'), label,
		readfile('/sys/class/net/lan1/address'), readfile('/sys/class/net/wan/address'),
		readfile('/sys/class/net/br-lan/address'), macaddr]) {
		if (valid_mac(value))
			return uc(substr(replace(trim(value), ':', ''), -4));
	}
	return null;
}

export function load_policy() {
	let data = readfile('/usr/share/gwrt/wifi-defaults.json');
	if (!data)
		return null;
	try {
		let policy = json(data);
		if (type(policy) == 'object' && policy.ssid_prefix == 'GWRT' &&
			type(policy.country) == 'string' && match(policy.country, /^([A-Z]{2}|00)$/) &&
			type(policy.key) == 'string' && length(policy.key) >= 8 && length(policy.key) <= 63 &&
			!match(policy.key, /['\r\n\\]/))
			return policy;
	} catch (e) { /* An invalid optional policy must not break wifi detection. */ }
	return null;
}

function width_supported(channel, width, channels) {
	if (width == 20)
		return true;
	if (type(channels) != 'array')
		return false;
	channel = int(channel);
	let first = channel >= 36 && channel <= 64 ? 36 :
		channel >= 100 && channel <= 144 ? 100 :
		channel >= 149 && channel <= 177 ? 149 : null;
	if (first == null)
		return false;
	let step = width / 5;
	let start = first + int((channel - first) / step) * step;
	for (let offset = 0; offset < step; offset += 4)
		if (index(channels, start + offset) < 0)
			return false;
	return true;
}

export function radio_defaults(policy, board, path, band_name, band, rband, channel, htmode, macaddr) {
	if (!policy)
		return null;

	if (band_name == '2g') {
		let channels = rband.channels ?? band.channels;
		let ch = int(channel);
		if (ch < 1 || ch > 14 ||
		    (type(channels) == 'array' && index(channels, ch) < 0))
			channel = rband.default_channel ?? 1;
		// EHT/MLO on 2.4 GHz does not associate reliably on the QCN9274
		// WSI group; keep the default BSS at HE20 (or the best HT/VHT mode).
		for (let mode in ['HE20', 'VHT20', 'HT20', 'NOHT']) {
			if (mode == 'NOHT' ||
			    (type(band.modes) == 'array' && index(band.modes, mode) >= 0)) {
				htmode = mode;
				break;
			}
		}
	}

	if (band_name == '5g') {
		let channels = rband.channels ?? band.channels;
		let high = match(board.model?.id ?? '', /^jdcloud,re-(ss-01|cs-02(-gwrt2)?)$/) &&
			match(path, /(^|\/)c000000\.wifi(\+[0-9]+)?$/);
		let preferred = high ? [149, 36] : [36, 149];
		// Do not impose the policy's channel preference on a different board
		// country. Keep the detector's supported default in that case.
		let country = board.wlan?.defaults?.country;
		if (!country || country == policy.country) {
			for (let candidate in preferred) {
				if (type(channels) == 'array' && index(channels, candidate) >= 0) {
					channel = candidate;
					break;
				}
			}
		}
		// Preserve capability mode/width. HE devices default to HE80 or less;
		// VHT/HT-only devices must never receive an unsupported HE mode.
		if (band.he) {
			for (let width in [80, 40, 20]) {
				let mode = 'HE' + width;
				if (width <= band.max_width && index(band.modes, mode) >= 0 &&
					width_supported(channel, width, channels)) {
					htmode = mode;
					break;
				}
			}
		}
	}

	let label = band_name == '2g' ? '2.4G' :
		band_name == '5g' ? (int(channel) >= 149 ? '5.8G' : '5.2G') :
		band_name == '6g' ? '6G' : band_name == '60g' ? '60G' : 'W';
	let suffix = mac_suffix(board, macaddr);
	return {
		channel, htmode,
		ssid: suffix ? policy.ssid_prefix + '_' + label + '_' + suffix : policy.ssid_prefix + '_' + label,
		country: band_name == '2g' || band_name == '5g' ? policy.country : null,
		encryption: band_name == '2g' || band_name == '5g' ? 'psk2+ccmp' : null,
		key: band_name == '2g' || band_name == '5g' ? policy.key : null,
		disabled: band_name == '6g' && policy.country == 'CN' ? 1 : 0,
	};
}
