// SPDX-License-Identifier: Apache-2.0

'use strict';
'require form';
'require poll';
'require rpc';
'require uci';
'require view';

const callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: ['name'],
	expect: { '': {} }
});

const trafficTokenQuery = `query DaedToken($username: String!, $password: String!) {
	token(username: $username, password: $password)
}`;
const trafficOverviewQuery = `query TrafficOverview($windowSec: Int!, $maxPoints: Int!) {
	general {
		runtimeOverview(windowSec: $windowSec, maxPoints: $maxPoints) {
			updatedAt uploadRate downloadRate uploadTotal downloadTotal activeConnections udpSessions
			samples { timestamp uploadRate downloadRate }
		}
	}
}`;
let trafficToken = null;
let trafficPollStarted = false;

function requestDaedGraphql(port, query, variables, token) {
	if (window.location.protocol === 'https:')
		return Promise.reject(new Error(_('Open LuCI over HTTP to use the DAED traffic API.')));

	let headers = { 'Content-Type': 'application/json' };
	if (token)
		headers.Authorization = 'Bearer ' + token;

	let controller = new AbortController();
	let timeout = window.setTimeout(function() { controller.abort(); }, 4000);
	return fetch('http://' + window.location.hostname + ':' + port + '/graphql', {
		method: 'POST',
		mode: 'cors',
		credentials: 'omit', signal: controller.signal,
		headers: headers,
		body: JSON.stringify({ query: query, variables: variables })
	}).then(function(response) {
		if (!response.ok)
			throw new Error(_('DAED returned HTTP %d').format(response.status));
		return response.json();
	}).then(function(result) {
		if (result.errors && result.errors.length)
			throw new Error(result.errors[0].message || _('DAED request failed.'));
		return result.data;
	}).finally(function() { window.clearTimeout(timeout); });
}

function formatTrafficValue(value, rate) {
	let units = rate ? ['B/s', 'KiB/s', 'MiB/s', 'GiB/s'] : ['B', 'KiB', 'MiB', 'GiB'];
	let n = Math.max(0, Number(value) || 0);
	let unit = 0;
	while (n >= 1024 && unit < units.length - 1) {
		n /= 1024;
		unit++;
	}
	return (unit ? n.toFixed(1) : Math.round(n)) + ' ' + units[unit];
}

function renderTrafficOverview(overview) {
	let metrics = document.getElementById('daed_traffic_metrics');
	if (!metrics)
		return;

	let values = [
		[_('Download rate'), formatTrafficValue(overview.downloadRate, true)],
		[_('Upload rate'), formatTrafficValue(overview.uploadRate, true)],
		[_('Downloaded'), formatTrafficValue(overview.downloadTotal, false)],
		[_('Uploaded'), formatTrafficValue(overview.uploadTotal, false)],
		[_('Connections'), String(Math.max(0, Number(overview.activeConnections) || 0))],
		[_('UDP sessions'), String(Math.max(0, Number(overview.udpSessions) || 0))]
	];

	metrics.replaceChildren(E('div', {
		style: 'display:grid;grid-template-columns:repeat(auto-fit,minmax(135px,1fr));gap:8px'
	}, values.map(function(item) {
		return E('div', {
			style: 'border:1px solid var(--border-color-medium,#bbb);border-radius:6px;padding:8px;min-height:54px'
		}, [
			E('div', { style: 'font-size:0.85em;opacity:0.75' }, item[0]),
			E('strong', { style: 'display:block;margin-top:4px' }, item[1])
		]);
	})));

	let canvas = document.getElementById('daed_traffic_chart');
	if (!canvas || !canvas.getContext)
		return;

	let width = Math.max(280, canvas.clientWidth || 600);
	let height = 140;
	let scale = window.devicePixelRatio || 1;
	canvas.width = width * scale;
	canvas.height = height * scale;
	let ctx = canvas.getContext('2d');
	ctx.scale(scale, scale);
	ctx.clearRect(0, 0, width, height);
	let samples = Array.isArray(overview.samples) ? overview.samples : [];
	let peak = Math.max(1, ...samples.map(function(sample) {
		return Math.max(Number(sample.downloadRate) || 0, Number(sample.uploadRate) || 0);
	}));
	[
		{ key: 'downloadRate', color: '#248b68' },
		{ key: 'uploadRate', color: '#d45d48' }
	].forEach(function(series) {
		if (samples.length < 2)
			return;
		ctx.beginPath();
		samples.forEach(function(sample, index) {
			let x = index * width / (samples.length - 1);
			let y = height - (Math.max(0, Number(sample[series.key]) || 0) / peak) * (height - 8) - 4;
			if (index === 0)
				ctx.moveTo(x, y);
			else
				ctx.lineTo(x, y);
		});
		ctx.lineWidth = 2;
		ctx.strokeStyle = series.color;
		ctx.stroke();
	});
}

function createTrafficPanel(port) {
	let username = E('input', {
		class: 'cbi-input-text', type: 'text', autocomplete: 'username',
		placeholder: _('DAED username'), 'aria-label': _('DAED username'),
		style: 'min-width:180px;max-width:100%'
	});
	let password = E('input', {
		class: 'cbi-input-text', type: 'password', autocomplete: 'current-password',
		placeholder: _('DAED password'), 'aria-label': _('DAED password'),
		style: 'min-width:180px;max-width:100%'
	});
	let connect = E('button', { class: 'cbi-button cbi-button-action', type: 'button' }, _('Connect'));
	let status = E('p', { id: 'daed_traffic_status', role: 'status' }, _('Enter the DAED account to view traffic. Credentials stay in this page session.'));
	let metrics = E('div', { id: 'daed_traffic_metrics', style: 'margin-top:10px' });
	let chart = E('canvas', {
		id: 'daed_traffic_chart',
		style: 'display:block;width:100%;height:140px;margin-top:12px'
	});

	connect.addEventListener('click', function(event) {
		event.preventDefault();
		let user = username.value.trim();
		let pass = password.value;
		if (!user || !pass) {
			status.textContent = _('Enter both DAED username and password.');
			return;
		}

		connect.disabled = true;
		status.textContent = _('Connecting to DAED…');
		requestDaedGraphql(port, trafficTokenQuery, { username: user, password: pass })
			.then(function(data) {
				if (!data || !data.token)
					throw new Error(_('DAED did not return an access token.'));
				trafficToken = data.token;
				password.value = '';
				username.value = '';
				status.textContent = _('Traffic statistics connected.');
				return requestDaedGraphql(port, trafficOverviewQuery, { windowSec: 60, maxPoints: 60 }, trafficToken);
			}).then(function(data) {
				if (data)
					renderTrafficOverview(data.general.runtimeOverview);
			}).catch(function(error) {
				trafficToken = null;
				status.textContent = error.message || _('Unable to read DAED traffic statistics.');
			}).finally(function() {
				connect.disabled = false;
			});
	});

	return E('section', { class: 'cbi-section', id: 'daed_traffic_panel' }, [
		E('h3', {}, _('DAED traffic')),
		E('p', { class: 'cbi-description' }, _('Sign in with the DAED dashboard account; the password is not saved.')),
		E('div', { style: 'display:flex;flex-wrap:wrap;align-items:center;gap:8px' }, [username, password, connect]),
		status,
		metrics,
		chart
	]);
}

function startTrafficPolling(port) {
	if (trafficPollStarted)
		return;
	trafficPollStarted = true;
	poll.add(function() {
		if (!trafficToken)
			return Promise.resolve();
		return requestDaedGraphql(port, trafficOverviewQuery, { windowSec: 60, maxPoints: 60 }, trafficToken)
			.then(function(data) {
				let overview = data.general.runtimeOverview;
				renderTrafficOverview(overview);
				let status = document.getElementById('daed_traffic_status');
				if (status)
					status.textContent = _('Updated %s').format(overview.updatedAt || _('now'));
			}).catch(function(error) {
				let status = document.getElementById('daed_traffic_status');
				if (status)
					status.textContent = error.message || _('Unable to read DAED traffic statistics.');
				trafficToken = null;
			});
	}, 5);
}

function getServiceStatus() {
	return L.resolveDefault(callServiceList('daed'), {}).then(function(res) {
		let isRunning = false;
		try {
			isRunning = Object.values(res.daed.instances).some(function(instance) { return instance.running === true; });
		} catch (e) { }
		return isRunning;
	});
}

function renderStatus(isRunning, port) {
	let spanTemp = '<span style="color:%s"><strong>%s %s</strong></span>';
	let renderHTML;
	if (isRunning) {
		let button = String.format('&#160;<a class="btn cbi-button" href="http://%s:%s" target="_blank" rel="noreferrer noopener">%s</a>',
			window.location.hostname, port, _('Open Web Interface'));
		renderHTML = spanTemp.format('green', _('daed'), _('RUNNING')) + button;
	} else {
		renderHTML = spanTemp.format('red', _('daed'), _('NOT RUNNING'));
	}

	return renderHTML;
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('daed')
		]);
	},

	render(data) {
		let m, s, o;
		let address = uci.get('daed', 'config', 'listen_addr') || '0.0.0.0:2023';
		let webport = Number(address.split(':').pop());
		if (!Number.isInteger(webport) || webport < 1 || webport > 65535)
			webport = 2023;

		m = new form.Map('daed', _('daed'),
			_('A modern dashboard for dae.'));

		s = m.section(form.TypedSection);
		s.anonymous = true;
		s.render = function() {
			startTrafficPolling(webport);
			poll.add(function() {
				return L.resolveDefault(getServiceStatus()).then(function(res) {
					let view = document.getElementById('service_status');
					if (view)
						view.innerHTML = renderStatus(res, webport);
				});
			}, 5);

			return E('div', { class: 'cbi-section', id: 'status_bar' }, [
				E('p', { id: 'service_status' }, _('Collecting data…')),
				createTrafficPanel(webport)
			]);
		}

		s = m.section(form.NamedSection, 'config', 'daed');

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default = o.disabled;
		o.rmempty = false;

		o = s.option(form.Value, 'listen_addr', _('Listening address'));
		o.datatype = 'ipaddrport(1)';
		o.default = '0.0.0.0:2023';
		o.rmempty = false;

		o = s.option(form.Value, 'log_maxbackups', _('Max log backups'),
			_('The maximum number of old log files to retain.'));
		o.datatype = 'uinteger';
		o.default = '1';

		o = s.option(form.Value, 'log_maxsize', _('Max log size'),
			_('The maximum size in megabytes of the log file before it gets rotated.'));
		o.datatype = 'uinteger';
		o.default = '5';

		return m.render();
	}
});
