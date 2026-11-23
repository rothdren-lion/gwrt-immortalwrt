'use strict';
'require view';
'require ui';
'require rpc';

var callStatus = rpc.declare({ object: 'luci.pon-info', method: 'status' });
var callHistory = rpc.declare({ object: 'luci.pon-info', method: 'history' });
var callRecord = rpc.declare({ object: 'luci.pon-info', method: 'record' });
var callClear = rpc.declare({ object: 'luci.pon-info', method: 'clear' });

function num(value) {
	return (value == null || value === '') ? null : Number(value);
}

function fmt(value) {
	return (value == null || value === '') ? '—' : String(value);
}

function fmtTime(ts) {
	if (!ts)
		return '—';
	var d = new Date(ts * 1000);
	var pad = function(n) { return (n < 10 ? '0' : '') + n; };
	return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
		pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

/* 按 SFF-8472 的口径换算，原始值同时保留，避免把换算当成设备读数。 */
function dbm(raw) {
	var value = num(raw);
	if (value == null || value <= 0)
		return '无光';
	return (10 * Math.log10(value / 10000)).toFixed(2) + ' dBm';
}

function celsius(raw) {
	var value = num(raw);
	return (value == null || value === 0) ? '—' : (value / 256).toFixed(1) + ' °C';
}

function volts(raw) {
	var value = num(raw);
	return (value == null || value === 0) ? '—' : (value / 10000).toFixed(3) + ' V';
}

function milliamp(raw) {
	var value = num(raw);
	return (value == null || value === 0) ? '—' : (value / 500).toFixed(3) + ' mA';
}

function bytes(value) {
	var n = num(value);
	if (n == null)
		return '—';
	var units = [ 'B', 'KiB', 'MiB', 'GiB', 'TiB' ];
	var i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	return (i === 0 ? n : n.toFixed(2)) + ' ' + units[i];
}

function yes(value) {
	return value ? '是' : '否';
}

function row(label, value, note) {
	return E('tr', { class: 'tr' }, [
		E('td', { class: 'td', style: 'width:34%' }, label),
		E('td', { class: 'td' }, [ fmt(value), note ? E('span', { class: 'ifacebadge' }, ' ' + note) : '' ])
	]);
}

function table(rows) {
	return E('table', { class: 'table' }, E('tbody', {}, rows));
}

function card(title, body) {
	return E('div', { class: 'cbi-section', style: 'margin-bottom:16px' }, [
		E('h3', {}, title),
		body
	]);
}

function identityCard(data) {
	var id = data.identity || {};
	var auth = id.auth || {};
	var cfg = data.config || {};
	return card('身份与认证', table([
		row('线路协议', id.mode, cfg.pon_enabled === false ? '光链路已禁用' : null),
		row('SN（配置）', id.serial_number),
		row('SN（生效）', id.serial_number_active),
		row('SN（十六进制）', id.serial_number_hex),
		row('设备型号 equipment_id', id.equipment_id),
		row('硬件版本', id.hardware_version),
		row('软件版本', id.software_version),
		row('运营商 ID', id.operator_id),
		row('OMCC 版本', id.omcc_version),
		row('厂商 ID / OAM 型号', [ fmt(id.vendor_id), fmt(id.oam_model) ].join(' / ')),
		row('ONU MAC', id.onu_mac),
		row('数据 MAC', id.data_mac),
		row('LOID', auth.loid ? '已配置' : '未配置'),
		row('LOID 密码', auth.loid_password ? '已配置' : '未配置'),
		row('PLoAM 密码', auth.ploam_password ? '已配置' : '未配置'),
		row('Registration ID', auth.registration_id ? '已配置' : '未配置'),
		row('OMCI PSK', auth.omci_psk ? '已配置' : '未配置'),
		row('OMCI 增强认证', auth.enhanced_security_disabled ? '已禁用' : '启用')
	]));
}

function opticalCard(data) {
	var o = data.link.optical || {};
	var t = data.link.transceiver || {};
	var los = num(o.rx_los) === 1;
	return card('光口与 BOSA', [
		los ? E('div', { class: 'alert-message warning' }, 'rx_los=1：光口无收光信号，未接光纤或线路中断。') : '',
		table([
			row('接收光功率（换算）', dbm(t.rx_power_raw), 'raw ' + fmt(t.rx_power_raw)),
			row('发射光功率（换算）', dbm(t.tx_power_raw), 'raw ' + fmt(t.tx_power_raw)),
			row('模块温度（换算）', celsius(t.temperature_raw), 'raw ' + fmt(t.temperature_raw)),
			row('模块电压（换算）', volts(t.voltage_raw), 'raw ' + fmt(t.voltage_raw)),
			row('偏置电流（换算）', milliamp(t.bias_raw), 'raw ' + fmt(t.bias_raw)),
			row('rx_los', num(o.rx_los)),
			row('tx_fault', num(o.tx_fault)),
			row('tx_signal_detect', num(o.tx_signal_detect)),
			row('module_absent', num(o.module_absent)),
			row('xgpon_rogue 标记', [ fmt(o.xgpon_rogue_at0), fmt(o.xgpon_rogue_at1) ].join(' / ')),
			row('optical control/status', [ fmt(o.control), fmt(o.status) ].join(' / '))
		])
	]);
}

function omciCard(data) {
	var om = (data.omci || {}).runtime || {};
	var service = (data.omci || {}).service || {};
	return card('OMCI 会话', [
		(data.omci || {}).service_error ? E('div', { class: 'alert-message warning' }, data.omci.service_error) : '',
		table([
			row('omcid PID', om.pid),
			row('会话 session', om.session),
			row('认证 auth', om.auth),
			row('MIB 路径 paths', om.paths),
			row('错误 error', om.error),
			row('OMCI 收 / 发', [ fmt(om.rx), fmt(om.tx) ].join(' / ')),
			row('无效帧 invalid', om.invalid),
			row('总线/端口配置 data_path', [
				(om.paths == null ? '—' : om.paths), '；' +
				'configured=' + fmt((data.link.data_path || {}).configured),
				'session=' + fmt((data.link.data_path || {}).session),
				'epoch=' + fmt((data.link.data_path || {}).epoch)
			].join(' ')),
			row('pon-service', 'enabled=' + fmt(service.enabled) + ' error=' + fmt(service.error))
		])
	]);
}

function trafficCard(data) {
	var pon0 = (data.net || {}).pon0 || {};
	var omci = (data.net || {}).pon_omci || {};
	var s = pon0.statistics || {};
	return card('接口统计', table([
		row('pon0 状态', (fmt(pon0.operstate) + ' / carrier=' + fmt(pon0.carrier))),
		row('pon0 收 / 发', [ bytes(s.rx_bytes), bytes(s.tx_bytes) ].join(' / ')),
		row('pon0 报文 收 / 发', [ fmt(s.rx_packets), fmt(s.tx_packets) ].join(' / ')),
		row('pon0 错误 收 / 发', [ fmt(s.rx_errors), fmt(s.tx_errors) ].join(' / ')),
		row('pon0 丢弃 收 / 发', [ fmt(s.rx_dropped), fmt(s.tx_dropped) ].join(' / ')),
		row('pon-omci 状态', fmt(omci.operstate)),
		row('pon-omci 收 / 发', [ bytes((omci.statistics || {}).rx_bytes), bytes((omci.statistics || {}).tx_bytes) ].join(' / '))
	]));
}

function configCard(data) {
	var wan = ((data.config || {}).pon_wan) || {};
	var pon = ((data.config || {}).pon) || {};
	var rows = [];
	Object.keys(pon).sort().forEach(function(k) {
		rows.push(row('pon.' + k, pon[k]));
	});
	Object.keys(wan).sort().forEach(function(k) {
		rows.push(row('pon_wan.' + k, k.indexOf('password') >= 0 ? (wan[k] ? '已配置' : '未配置') : wan[k]));
	});
	return card('当前配置（UCI）', table(rows));
}

function rawCard(data) {
	var link = data.link || {};
	var rows = [];
	[ 'state', 'serdes', 'ploam', 'fec', 'pm_counters', 'data_path' ].forEach(function(key) {
		var value = link[key];
		rows.push(row(key, value == null ? '不可读' : JSON.stringify(value)));
	});
	[ 'ploam_default', 'itu_paths', 'omci_msk', 'omci_broadcast', 'position', 'llid_table', 'epon_sla', 'epon_key' ]
		.forEach(function(key) {
			if (link[key] != null)
				rows.push(row(key, String(link[key]).substr(0, 200)));
		});
	rows.push(row('device', JSON.stringify(data.device || {})));
	return card('原始参数与设备', table(rows));
}

function logCard(data) {
	var lines = String((data.log || '')).split('\n').filter(function(l) { return l.trim() !== ''; });
	return card('最近的 PON / OMCI 日志', lines.length
		? E('pre', { style: 'max-height:280px;overflow:auto;font-size:12px' }, lines.join('\n'))
		: E('em', {}, '暂无日志'));
}

function historyTable(records, container) {
	var head = [ '时间', 'SN', '协议', 'LOS', 'RX', 'TX', '温度',
		'OMCI 会话', 'auth', 'paths', '省略', 'pon0', '收', '发' ];
	var thead = E('tr', { class: 'tr table-titles' }, head.map(function(title) {
		return E('th', { class: 'th' }, title);
	}));
	var rows = records.slice().reverse().map(function(r) {
		return E('tr', { class: 'tr' }, [
			E('td', { class: 'td' }, fmtTime(r.ts)),
			E('td', { class: 'td' }, fmt(r.sn)),
			E('td', { class: 'td' }, fmt(r.mode)),
			E('td', { class: 'td' }, num(r.los) === 1 ? '无光' : '有光'),
			E('td', { class: 'td' }, dbm(r.rx_raw)),
			E('td', { class: 'td' }, dbm(r.tx_raw)),
			E('td', { class: 'td' }, celsius(r.temp_raw)),
			E('td', { class: 'td' }, fmt(r.omci_session)),
			E('td', { class: 'td' }, fmt(r.omci_auth)),
			E('td', { class: 'td' }, fmt(r.omci_paths)),
			E('td', { class: 'td' }, fmt(r.omci_error)),
			E('td', { class: 'td' }, fmt(r.pon_operstate)),
			E('td', { class: 'td' }, bytes(r.pon_rx_bytes)),
			E('td', { class: 'td' }, bytes(r.pon_tx_bytes))
		]);
	});
	if (!rows.length)
		rows.push(E('tr', { class: 'tr' }, E('td', { class: 'td', colspan: head.length },
			E('em', {}, '还没有记录。服务每 60 秒采样一次，状态变化时才落盘。'))));
	container.innerHTML = '';
	container.appendChild(E('table', { class: 'table' }, [ E('thead', {}, thead), E('tbody', {}, rows) ]));
}

function download(content, name) {
	var blob = new Blob([ content ], { type: 'application/json' });
	var link = E('a', { href: URL.createObjectURL(blob), download: name });
	document.body.appendChild(link);
	link.click();
	setTimeout(function() { URL.revokeObjectURL(link.href); link.remove(); }, 1000);
}

return view.extend({
	load: function() {
		return Promise.all([ callStatus(), callHistory() ]);
	},

	handleRecord: function() {
		return callRecord().then(function() {
			location.reload();
		});
	},

	handleClear: function() {
		if (!confirm('清空全部 PON 历史记录？'))
			return;
		return callClear().then(function() {
			location.reload();
		});
	},

	handleExport: function(records) {
		download(JSON.stringify(records, null, 2), 'pon-history-' + Math.floor(Date.now() / 1000) + '.json');
	},

	render: function(data) {
		var status = data[0] || {};
		var history = data[1] || {};
		var records = Array.isArray(history.records) ? history.records : (Array.isArray(history) ? history : []);

		if (status.error) {
			return E('div', { class: 'cbi-section' }, [
				E('h3', {}, 'PON 信息记录'),
				E('div', { class: 'alert-message error' }, '采集失败：' + status.error),
				E('p', {}, '确认 /usr/sbin/pon-info 存在且可执行，并在 SSH 中运行 pon-info show 检查。')
			]);
		}

		var historyBox = E('div', {});

		var view = E('div', { class: 'cbi-map' }, [
			E('h2', {}, 'PON 信息记录'),
			E('div', { class: 'cbi-map-descr' },
				'只读采集光猫的全部可读 PON 参数，并记录状态变化。采样间隔与保留条数在 /etc/config/poninfo 中调整。'),
			E('div', { class: 'cbi-page-actions', style: 'margin-bottom:16px' }, [
				E('button', { class: 'btn cbi-button cbi-button-action', click: ui.createHandlerFn(this, 'handleRecord') }, '立即采样'),
				E('button', { class: 'btn cbi-button', click: ui.createHandlerFn(this, 'handleExport', records) }, '导出 JSON'),
				E('button', { class: 'btn cbi-button cbi-button-reset', click: ui.createHandlerFn(this, 'handleClear') }, '清空历史')
			]),
			card('概览', table([
				row('设备', fmt((status.device || {}).model) + ' / ' + fmt((status.device || {}).board)),
				row('CPU', (function() {
					var cpu = (status.device || {}).cpu || {};
					var name = cpu.soc ? cpu.soc + '*' + (cpu.threads || '?') : '?';
					var mhz = cpu.freq_khz ? (cpu.freq_khz >= 1000000
						? (cpu.freq_khz / 1000000).toFixed(2).replace(/\.?0+$/, '') + ' GHz'
						: Math.round(cpu.freq_khz / 1000) + ' MHz') : '?';
					return name + '  ' + mhz;
				})()),
				row('固件', String((status.device || {}).release || '').split('\n').filter(function(l) {
					return l.indexOf('DISTRIB_DESCRIPTION') === 0 || l.indexOf('DISTRIB_REVISION') === 0;
				}).join('  ')),
				row('运行时长', fmt((status.device || {}).uptime)),
				row('采集条数', records.length + ' 条')
			])),
			identityCard(status),
			opticalCard(status),
			omciCard(status),
			trafficCard(status),
			card('历史（变化记录，最新在前）', historyBox),
			configCard(status),
			rawCard(status),
			logCard(status)
		]);

		historyTable(records, historyBox);

		return view;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
