// Real browser check for both LuCI views with a controlled topology RPC.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require(process.env.GWRT_PLAYWRIGHT || 'playwright-core');
const root = path.join(__dirname, '../..');
const shared = path.join(root, 'package/gwrt-device-defaults/files/wifiroam');
const v5 = path.join(root, 'package/gwrt-wifiroam-v5/files/usr/share/gwrt/wifiroam-v5');
const helperPath = path.join(shared, 'topologyBackhaul.js');
const helper = fs.existsSync(helperPath) ? fs.readFileSync(helperPath, 'utf8') : '';

async function render(page, base, code, css) {
	await page.goto(base + '/topology');
	await page.addStyleTag({ content: css });
	await page.evaluate(async ({ code, helper }) => {
		function append(el, children) {
			for (const item of [children].flat(Infinity))
				if (item != null) el.append(item);
		}
		function E(tag, attrs, children) {
			const el = document.createElement(tag);
			for (const [name, value] of Object.entries(attrs || {})) {
				if (typeof value === 'function') el.addEventListener(name, value);
				else el.setAttribute(name, value);
			}
			append(el, children);
			return el;
		}
		window.node = {
			type: 'ap', role: 'sap', name: 'Satellite', id: 'satellite',
			mac: '02:00:00:00:00:02', ip: '203.0.113.77', authed: true,
			uplink: { type: 'wired' },
			backhaul: { management_ip: '198.51.100.42', mode: 'wireless', band: '5g', reason: 'cable_lost' }
		};
		window.topology = { role: 'cap', nodes: [
			{ type: 'ap', role: 'cap', id: 'main', name: 'Main', ip: '192.0.2.100' }, window.node
		] };
		const wr = {
			call: async method => method === 'topology' ? JSON.parse(JSON.stringify(window.topology)) : {},
			useOui() {}, useVendorLogos() {}, useDevices() {},
			css: () => null, statusBar: () => null, fmtTime: String, fmtUptime: () => '-',
			roleBadge: role => role
		};
		const ui = {
			showModal(title, body) { document.body.append(E('section', { class: 'modal' }, body)); },
			hideModal() {
				const modal = document.querySelector('.modal');
				modal.dispatchEvent(new Event('hide'));
				modal.remove();
			}
		};
		const modules = {
			_: text => text, E, L: { bind: (fn, self) => fn.bind(self), resource: String },
			wr, ui, poll: { add: fn => { window.refresh = fn; } },
			view: { extend: obj => obj },
			dom: { content: (el, contents) => { el.replaceChildren(); append(el, contents); } },
			oui: {}, logos: {}, devices: {}, modelart: { map: {}, tokens: [] },
			mb: new Function('E', '_', helper)(E, text => text)
		};
		const view = new Function(...Object.keys(modules), code)(...Object.values(modules));
		document.querySelector('main').append(view.render(await view.load()));
		await window.refresh();
	}, { code, helper });
}

(async () => {
	const browser = await chromium.launch({
		executablePath: process.env.GWRT_CHROME || '/usr/bin/google-chrome',
		headless: true, args: ['--no-sandbox']
	});
	try {
		for (const [label, topology, style] of [
			['legacy', path.join(shared, 'topology.js'), path.join(shared, 'wifiroam.css')],
			['v5', path.join(v5, 'views/topology.js'), path.join(v5, 'res/wifiroam.css')]
		]) {
			for (const width of [390, 1280]) {
				const protocol = width === 390 ? 'https:' : 'http:';
				const context = await browser.newContext({ viewport: { width, height: 800 } });
				// Requests are intercepted at the browser; test addresses are never contacted.
				await context.route('**/*', route => route.fulfill({
					contentType: 'text/html', body: '<main></main>'
				}));
				const page = await context.newPage();
				await render(page, protocol + '//192.0.2.100', fs.readFileSync(topology, 'utf8'),
					fs.readFileSync(style, 'utf8'));
				const satellite = page.locator('.wr-ap[data-id="satellite"]');
				const detail = page.locator('.modal');
				const manage = detail.getByRole('link', { name: '打开管理页' });
				await satellite.locator('.wr-label').click();
				assert.equal(await manage.getAttribute('href', { timeout: 2500 }),
					protocol + '//198.51.100.42/cgi-bin/luci/');
				assert.match(await detail.textContent(), /5 GHz/);
				assert.match(await detail.textContent(), /有线断开/);
				assert.equal(await page.locator('.wr-aplink.wr-wireless').count(), 1);
				assert.match(await satellite.textContent(), /198\.51\.100\.42/);

				await page.evaluate(() => {
					window.node.backhaul = { management_ip: '198.51.100.32', mode: 'wired', reason: 'wired_priority' };
					window.node.uplink.type = 'wireless';
					return window.refresh();
				});
				const newUrl = protocol + '//198.51.100.32/cgi-bin/luci/';
				assert.equal(await manage.getAttribute('href'), newUrl);
				assert.match(await detail.textContent(), /优先切到有线/);
				assert.doesNotMatch(await detail.textContent(), /5 GHz/);
				const [popup] = await Promise.all([page.waitForEvent('popup'), manage.click()]);
				await popup.waitForURL(newUrl);
				assert.equal(await popup.evaluate(() => window.opener), null);
				await popup.close();

				await page.evaluate(() => {
					window.node.backhaul.management_ip = '198.51.100.32@203.0.113.77';
					return window.refresh();
				});
				assert.equal(await manage.count(), 0, 'reject non-IPv4 management destinations');
				await page.evaluate(() => {
					window.node.backhaul = null;
					return window.refresh();
				});
				assert.equal(await manage.count(), 0, 'expired TCP status hides the open dialog link');
				await page.evaluate(() => {
					window.node.authed = false;
					window.node.backhaul = { management_ip: '198.51.100.32' };
					return window.refresh();
				});
				assert.equal(await manage.count(), 0, 'offline node cannot use a stale address');

				await page.evaluate(() => {
					window.prevTopology = window.topology;
					window.topology = null;
					return window.refresh();
				});
				assert.equal(await manage.count(), 0, 'no link while topology is unavailable');
				await detail.getByRole('button', { name: 'Close' }).click();
				await satellite.locator('.wr-label').click();
				await detail.waitFor({ timeout: 2500 });
				assert.equal(await manage.count(), 0, 'no link when an old node is clicked after RPC loss');
				await detail.getByRole('button', { name: 'Close' }).click();
				await page.evaluate(() => {
					window.topology = window.prevTopology;
					return window.refresh();
				});
				await page.locator('.wr-ap[data-id="main"] .wr-label').click();
				assert.equal(await manage.count(), 0, 'no satellite management action for the main AP');
				await context.close();
				console.log('PASS', label, width, 'live management link, transport, reason and offline state');
			}
		}
	} finally {
		await browser.close();
	}
})().catch(err => { console.error(err); process.exitCode = 1; });
