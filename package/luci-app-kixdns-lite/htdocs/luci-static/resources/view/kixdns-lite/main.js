'use strict';
'require dom';
'require fs';
'require poll';
'require rpc';
'require ui';
'require uci';
'require view';

var CFG = '/etc/kixdns/pipeline.json';
var INIT = '/etc/init.d/kixdns';

var DEFAULT_PORT = '5300';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

function readCfg() {
	return fs.read(CFG).then(function(text) {
		try {
			return JSON.parse(text);
		} catch (e) {
			return null;
		}
	}, function() {
		return null;
	});
}

/* "0.0.0.0:5300" / "[::1]:5300" -> { host, port } */
function splitAddr(addr) {
	var s = String(addr == null ? '' : addr);
	var i = s.lastIndexOf(':');

	if (i < 1)
		return { host: '0.0.0.0', port: '' };

	return { host: s.substring(0, i), port: s.substring(i + 1) };
}

function isRunning(data) {
	var instances = data && data['kixdns'] && data['kixdns'].instances;

	if (!instances)
		return false;

	for (var key in instances)
		if (instances[key] && instances[key].running)
			return true;

	return false;
}

return view.extend({
	load: function() {
		return L.resolveDefault(uci.load('kixdns'), null).then(function() {
			return Promise.all([
				readCfg(),
				callServiceList('kixdns')
			]);
		}).then(function(res) {
			return [ res[0], res[1], uci.get('kixdns', 'main', 'enabled') ];
		});
	},

	row: function(title, field) {
		return E('div', { 'class': 'cbi-value' }, [
			E('div', { 'class': 'cbi-value-title' }, title),
			E('div', { 'class': 'cbi-value-field' }, field)
		]);
	},

	render: function(res) {
		var cfg = res[0];
		var enabled = String(res[2] == null ? '1' : res[2]) != '0';
		var settings = (cfg && L.isObject(cfg.settings)) ? cfg.settings : {};
		var udp = splitAddr(settings.bind_udp);
		var tcp = splitAddr(settings.bind_tcp);
		var port = udp.port || tcp.port || DEFAULT_PORT;

		this.statusNode = E('span', {}, _('Unknown'));

		this.bindNode = E('span', {},
			settings.bind_udp
				? (String(settings.bind_udp) + ' / ' + String(settings.bind_tcp || settings.bind_udp))
				: '-');

		this.enableInput = E('input', { 'type': 'checkbox' });
		this.enableInput.checked = enabled;

		this.portInput = E('input', {
			'type': 'number',
			'class': 'cti-input',
			'min': '1',
			'max': '65535',
			'value': port
		});
		this.portInput.style.width = '7em';
		this.portInput.disabled = !cfg;

		var body = [
			E('h2', {}, 'KixDNS'),
			E('div', { 'class': 'cbi-map-descr' },
				_('KixDNS is an asynchronous DNS forwarder. Start or stop the service and change its listen port here. Saving restarts the service.')),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Status')),
				E('div', { 'class': 'cbi-section-node' }, [
					this.row(_('Status'), this.statusNode),
					this.row(_('Listen address'), this.bindNode)
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Settings')),
				E('div', { 'class': 'cbi-section-node' }, [
					this.row(_('Enable at boot'), [
						this.enableInput,
						E('span', { 'class': 'cbi-description' },
							' ' + _('Start KixDNS automatically when the router boots.'))
					]),
					this.row(_('Listen port'), [
						this.portInput,
						E('div', { 'class': 'cbi-description' },
							_('UDP and TCP listen port. Only the port part of bind_udp and bind_tcp is changed, the host part is kept.'))
					])
				]),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, 'handleSave')
					}, _('Save & Apply')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, 'handleService', 'start')
					}, _('Start')),
					' ',
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(this, 'handleService', 'stop')
					}, _('Stop'))
				])
			])
		];

		if (!cfg)
			body.splice(2, 0, E('div', { 'class': 'alert-message warning' },
				_('The configuration file is missing or is not valid JSON, editing is disabled.')));

		this.updateStatus();

		poll.add(L.bind(this.updateStatus, this), 5);
		if (!poll.active())
			poll.start();

		return E('div', { 'class': 'cbi-map' }, body);
	},

	updateStatus: function() {
		var node = this.statusNode;

		return callServiceList('kixdns').then(function(data) {
			var running = isRunning(data);

			dom.content(node, running
				? E('span', { 'style': 'color:var(--success-color-high);font-weight:bold' }, _('Running'))
				: E('span', { 'style': 'color:var(--error-color-high);font-weight:bold' }, _('Not running')));
		}, function() {
			dom.content(node, E('span', {}, _('Unknown')));
		});
	},

	handleService: function(action) {
		var self = this;

		return fs.exec(INIT, [ action ]).then(function() {
			ui.addNotification(null, E('p', {},
				_('Service action executed:') + ' ' + action));
			return self.updateStatus();
		}, function(err) {
			ui.addNotification(null, E('p', {},
				_('Unable to execute service action:') + ' ' + String(err && err.message ? err.message : err)));
		});
	},

	handleSave: function() {
		var self = this;
		var port = parseInt(this.portInput.value, 10);
		var enabled = this.enableInput.checked;

		if (isNaN(port) || port < 1 || port > 65535) {
			ui.addNotification(null, E('p', {},
				_('Invalid listen port, expected a number between 1 and 65535.')));
			return Promise.resolve();
		}

		return readCfg().then(function(cfg) {
			if (!cfg)
				throw new Error(_('Unable to read') + ' ' + CFG);

			if (!L.isObject(cfg.settings))
				cfg.settings = {};

			var u = splitAddr(cfg.settings.bind_udp || ('0.0.0.0:' + DEFAULT_PORT));
			var t = splitAddr(cfg.settings.bind_tcp || cfg.settings.bind_udp || ('0.0.0.0:' + DEFAULT_PORT));

			cfg.settings.bind_udp = u.host + ':' + port;
			cfg.settings.bind_tcp = t.host + ':' + port;

			return fs.write(CFG, JSON.stringify(cfg, null, 2) + '\n', 420);
		}).then(function() {
			uci.set('kixdns', 'main', 'enabled', enabled ? '1' : '0');
			uci.save();
			return uci.apply();
		}).then(function() {
			return fs.exec(INIT, [ 'restart' ]);
		}).then(function() {
			ui.addNotification(null, E('p', {},
				_('Configuration applied, KixDNS has been restarted.')));
			return self.updateStatus();
		}, function(err) {
			ui.addNotification(null, E('p', {},
				_('Unable to apply the configuration:') + ' ' +
				String(err && err.message ? err.message : err)));
		});
	}
});
