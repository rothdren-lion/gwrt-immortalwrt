'use strict';
'require baseclass';

var reasons = {
	wired_verified: '已确认主 AP 的有线网络',
	wired_priority: '检测到主 AP 的网线，优先切到有线',
	cable_lost: '有线断开',
	wired_unavailable: '有线回传未就绪或租约失效',
	wired_unreachable: '连续探测无法到达主 AP',
	wireless_verified: '已连上主 AP 的无线回传',
	wireless_lost: '无线回传断开后重新搜索',
	search_timeout: '搜索超时，曾恢复路由模式',
	reconfigure_failed: '回传配置失败后重新搜索'
};

function managementIp(role, ap) {
	if (role !== 'cap' || !ap || ap.role !== 'sap' || ap.authed !== true || !ap.backhaul)
		return null;
	var ip = ap.backhaul.management_ip;
	if (typeof ip !== 'string')
		return null;
	var parts = ip.split('.');
	return parts.length === 4 && parts.every(function(part) {
		return /^(0|[1-9][0-9]{0,2})$/.test(part) && Number(part) <= 255;
	}) ? ip : null;
}

function address(role, ap) {
	return managementIp(role, ap) || ap.ip;
}

function transport(ap) {
	var mode = ap.backhaul && ap.backhaul.mode;
	if (mode === 'wired' || mode === 'wireless')
		return mode;
	return ap.uplink && ap.uplink.type;
}

function details(row, ap, role) {
	var satellite = role === 'cap' && ap.role === 'sap';
	var ipText = document.createTextNode('');
	var open = E('a', { target: '_blank', rel: 'noopener noreferrer' }, '打开管理页');
	var link = E('span');
	var reason = E('span');
	row(_('IP Address'), E('span', {}, [ ipText, ' ', open ]));
	row(_('Backhaul'), link);
	if (satellite)
		row('最近切换原因', reason);

	return function(topo) {
		var nodes = topo && topo.nodes || [];
		var current = nodes.find(function(n) { return n.id === ap.id && n.type === 'ap'; });
		var ip = managementIp(topo && topo.role, current);
		ipText.data = ip || (current && current.ip) || '-';
		open.hidden = !ip;
		if (ip) {
			var scheme = window.location.protocol === 'https:' ? 'https://' : 'http://';
			var url = scheme + ip + '/cgi-bin/luci/';
			if (open.getAttribute('href') !== url)
				open.href = url;
		} else {
			open.removeAttribute('href');
		}

		var mode = current && transport(current);
		var info = current && current.backhaul;
		var port = current && current.uplink && current.uplink.port;
		var band = info && (info.band === '2g' ? '2.4 GHz' : info.band === '5g' ? '5 GHz' : '');
		if (satellite && (!current || current.authed === false || current.backhaul === null))
			link.textContent = '未连接';
		else if (mode === 'wired' || mode === 'wireless')
			link.textContent = (mode === 'wired' ? _('Wired') : _('Wireless')) +
				(mode === 'wireless' && band ? ' · ' + band : !info && port ? ' (' + port + ')' : '');
		else
			link.textContent = '-';
		var reasonText = info && reasons[info.reason];
		reason.textContent = ip && typeof reasonText === 'string' ? reasonText : '-';
	};
}

return baseclass.extend({
    address: address,
    transport: transport,
    details: details
});
