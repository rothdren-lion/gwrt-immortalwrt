// SPDX-License-Identifier: GPL-2.0-only

'use strict';
'require fs';
'require form';
'require network';
'require uci';
'require view';

function validateIfname(sectionId, value) {
	if (!/^[A-Za-z0-9_.:-]{1,15}$/.test(value || ''))
		return _('Use a Linux network device name containing at most 15 characters.');

	return true;
}

function validateVlan(sectionId, value) {
	if (!/^[0-9]{1,4}$/.test(value || ''))
		return _('The service VLAN ID must be a number.');

	var vid = parseInt(value, 10);

	if (vid < 1 || vid > 4094)
		return _('The service VLAN ID must be between 1 and 4094.');

	return true;
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('pon_wan'),
			network.getDevices()
		]);
	},

	render: function(data) {
		var devices = data[1] || [];
		var ponDevices = devices.filter(function(device) {
			return /^pon[0-9]+$/.test(device.getName());
		}).map(function(device) {
			return device.getName();
		}).sort();

		var m, s, o;

		m = new form.Map('pon_wan', _('PON WAN service'),
			_('Binds the operator service VLAN to the PON device. The VLAN device is created as pon0.<VID> and the interface is attached to the wan firewall zone.'));

		m.readonly = !L.hasViewPermission();

		s = m.section(form.NamedSection, 'settings', 'pon_wan');
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'uplink', _('PON device'),
			_('The PON device that carries the service traffic.'));
		o.default = 'pon0';
		o.rmempty = false;
		ponDevices.forEach(function(name) {
			o.value(name);
		});
		if (ponDevices.indexOf('pon0') < 0)
			o.value('pon0');
		o.depends('enabled', '1');

		o = s.option(form.Value, 'vlan', _('Service VLAN ID'),
			_('Operator LAN ID carried over the PON device.'));
		o.placeholder = '41';
		o.rmempty = false;
		o.validate = validateVlan;
		o.depends('enabled', '1');

		o = s.option(form.Value, 'iface', _('Network interface'),
			_('Interface bound to the VLAN device. It stays in the wan firewall zone.'));
		o.default = 'wan';
		o.rmempty = false;
		o.validate = validateIfname;
		o.depends('enabled', '1');

		o = s.option(form.ListValue, 'proto', _('Protocol'));
		o.default = 'dhcp';
		o.rmempty = false;
		o.value('dhcp', _('DHCP client'));
		o.value('pppoe', _('PPPoE'));
		o.value('static', _('Static address'));
		o.value('none', _('No protocol'));
		o.depends('enabled', '1');

		o = s.option(form.Value, 'ipaddr', _('IPv4 address'));
		o.rmempty = true;
		o.depends('enabled', '1');
		o.depends('proto', 'static');

		o = s.option(form.Value, 'netmask', _('IPv4 netmask'));
		o.default = '255.255.255.0';
		o.rmempty = false;
		o.depends('enabled', '1');
		o.depends('proto', 'static');

		o = s.option(form.Value, 'gateway', _('IPv4 gateway'));
		o.rmempty = true;
		o.depends('enabled', '1');
		o.depends('proto', 'static');

		o = s.option(form.Value, 'dns', _('DNS servers'));
		o.placeholder = _('223.5.5.5');
		o.rmempty = true;
		o.depends('enabled', '1');
		o.depends('proto', 'static');

		o = s.option(form.Value, 'pppoe_username', _('PPPoE username'));
		o.rmempty = true;
		o.depends('enabled', '1');
		o.depends('proto', 'pppoe');

		o = s.option(form.Value, 'pppoe_password', _('PPPoE password'));
		o.password = true;
		o.rmempty = true;
		o.depends('enabled', '1');
		o.depends('proto', 'pppoe');

		return m.render();
	}
});
