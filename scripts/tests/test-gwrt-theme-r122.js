const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const theme = path.resolve(
  process.env.GWRT_TEST_THEME || path.join(root, 'gwrt-theme-V3/theme/luci-theme-gwrt'),
);
const read = relative => fs.readFileSync(path.join(theme, relative), 'utf8');
const template = read('root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut');
const css = read('htdocs/luci-static/gwrt/css/cascade.css');
const header = read('root/usr/share/ucode/luci/template/themes/gwrt/header.ut');
const headerLogin = read('root/usr/share/ucode/luci/template/themes/gwrt/header_login.ut');
const footer = read('root/usr/share/ucode/luci/template/themes/gwrt/footer.ut');
const footerLogin = read('root/usr/share/ucode/luci/template/themes/gwrt/footer_login.ut');
const socinfo = read('root/usr/libexec/gwrt-socinfo');

for (const id of [
  'gwrtWanTrend', 'gwrtWan4Down', 'gwrtWan4Up',
  'gwrtWan6Down', 'gwrtWan6Up', 'gwrtWan4Total', 'gwrtWan6Total',
  'gwrtWanSampleState',
]) {
  assert.match(template, new RegExp(`id=["']${id}["']`), `missing dashboard node ${id}`);
}
assert.match(header, /id="gwrtWanPeriods"/, 'traffic periods belong in the upper bar');
assert.doesNotMatch(template, /id="gwrtWanPeriods"/, 'traffic periods must leave the traffic card');

for (const fn of ['nssFamilyRate', 'nssTrafficRate', 'updateWanTraffic', 'renderWanTraffic', 'renderWanTrend']) {
  assert.match(template, new RegExp(`function ${fn}\\(`), `missing ${fn}`);
}
assert.match(template, /rpcD\('file','read',\{path:'\/sys\/kernel\/debug\/qca-nss-drv\/stats\/ipv4'\}\)/);
assert.match(template, /rpcD\('file','read',\{path:'\/sys\/kernel\/debug\/qca-nss-drv\/stats\/ipv6'\}\)/);
assert.match(template, /nssTrafficRate\(nss4,nss6\)/);
assert.doesNotMatch(template, /gwrt-wan-family-grid|id="gwrtWanFamily[46]"/);
assert.match(template, /gwrt-traffic-daily',params:\['read'\]/);

const storageStart = template.indexOf('/* Memory / Swap / Disk');
const storageEnd = template.indexOf('/* WAN status and real-time speed', storageStart);
assert(storageStart >= 0 && storageEnd > storageStart, 'storage refresh block is missing');
const storage = template.slice(storageStart, storageEnd);
for (const id of ['gwrtMemVal', 'gwrtSwapVal', 'gwrtRootfsVal', 'gwrtDiskVal']) {
  assert.match(storage, new RegExp(`S\\(["']${id}["'],[\\s\\S]*?已用[\\s\\S]*?\\/`), `${id} must use used/total format`);
}
assert.match(storage, /gwrtMemVal[^\n]*已用[^\n]*F\(mt\)/);
assert.match(storage, /gwrtSwapVal[^\n]*已用[^\n]*F\(st\)/);
assert.match(storage, /gwrtRootfsVal[^\n]*已用[^\n]*F\(rfsTotal\)/);
assert.match(storage, /gwrtDiskVal[^\n]*已用[^\n]*F\(best\.t\)/);

assert.match(css, /\.stat-card\[data-gwrt="netspeed"\],\.stat-card\[data-gwrt="devices"\]\{height:196px;/);
assert.match(css, /\.gwrt-wan-line-ipv4\{stroke:#22b8cf\}/);
assert.match(css, /\.gwrt-wan-line-ipv6\{stroke:#a78bfa\}/);
assert.match(header, /id="gwrtNavbarUptime"/);
for (const asset of [header, headerLogin]) {
  assert.match(asset, /20261120r127/, 'dashboard CSS must invalidate the r126 cache');
}
assert.match(footer, /gwrt-navbar\.js\?v=20261118r124/, 'navbar monitor must invalidate its r123 cache');
assert.match(footerLogin, /gwrt\.js\?v=20261118r123/, 'login page invalidates its updated runtime asset');

assert.match(socinfo, /machine_file=.*device/);
assert.match(socinfo, /compatible_file=.*device/);
assert.match(socinfo, /mt\[0-9\]\*\|ipq\[0-9\]\*/);
assert.match(socinfo, /printf '%s\\n%s\\n%s\\n'/);

// Exercise the real NSS family parser with deterministic samples.  The
// aggregate must remain available per family and must not copy IPv4 into IPv6.
const nssStart = template.indexOf('function nssStatValue(');
const nssEnd = template.indexOf('var connTrendHist', nssStart);
assert(nssStart >= 0 && nssEnd > nssStart, 'NSS parser block is missing');
let now = 0;
const nssSandbox = { Date: { now: () => now } };
vm.runInNewContext(`${template.slice(nssStart, nssEnd)}\n` +
  'globalThis.nssApi={nssStatValue,nssFamilyRate,nssTrafficRate};', nssSandbox);
const nss = nssSandbox.nssApi;
const stats = (family, rx, tx) =>
  `${family}_rx_byts = ${rx} common\n${family}_tx_byts = ${tx} common\n`;

const first = nss.nssTrafficRate({ data: stats('ipv4', 1000, 2000) },
  { data: stats('ipv6', 4000, 8000) });
assert.equal(first.available, true);
assert.equal(first.families.ipv4.available, true);
assert.equal(first.families.ipv6.available, true);
assert.equal(first.families.ipv4.rxRate, null, 'first sample waits for a delta');

now = 1000;
const second = nss.nssTrafficRate({ data: stats('ipv4', 2000, 3000) },
  { data: stats('ipv6', 7000, 10000) });
assert.equal(second.families.ipv4.rxRate, 1000);
assert.equal(second.families.ipv4.txRate, 1000);
assert.equal(second.families.ipv6.rxRate, 3000);
assert.equal(second.families.ipv6.txRate, 2000);

const noIpv6 = nss.nssTrafficRate({ data: stats('ipv4', 3000, 4000) }, { data: '' });
assert.equal(noIpv6.families.ipv4.available, true);
assert.equal(noIpv6.families.ipv6.available, false, 'missing IPv6 counters stay unknown');
assert.equal(noIpv6.families.ipv6.rxBytes, 0);

// Reload and probe failure retain counters and both paths in the real UI code.
const uiStart = template.indexOf('var gwrtWanTraffic=null;');
const uiEnd = template.indexOf('var gwrtOtaChecked=', uiStart);
const values = new Map();
function sandbox() {
  const nodes = new Map();
  function node() { return { textContent: '', innerHTML: '', title: '', clientWidth: 340, clientHeight: 55, appendChild() {}, querySelector() { return null; } }; }
  const document = { getElementById(id) { if (!nodes.has(id)) nodes.set(id, node()); return nodes.get(id); }, createElement: node, createTextNode(text) { return { textContent: text }; } };
  const context = { Date, document, window: {}, localStorage: { getItem: k => values.get(k), setItem: (k,v) => values.set(k,v) }, F: n => n + ' B', fmtSpeed: n => n + ' B/s', S: (id,t) => { document.getElementById(id).textContent = t; } };
  vm.runInNewContext(template.slice(uiStart, uiEnd), context);
  return { context, nodes };
}
const data = { version: 3, ok: true, sampled: Date.now()/1000, first: Date.now()/1000, total: 300, families: { ipv4: { available:true, up:10, down:20, total:100 }, ipv6: { available:true, up:30, down:40, total:200 } }, history: [{ t:Date.now(), ipv4:{up:10,down:20},ipv6:{up:30,down:40} }], periods: [] };
let ui = sandbox();
ui.context.updateWanTraffic({stdout:JSON.stringify(data)});
assert.equal(ui.nodes.get('gwrtWan4Total').textContent, '100 B');
assert.equal(ui.nodes.get('gwrtWan6Total').textContent, '200 B');
assert.equal(ui.nodes.get('gwrtWan4Up').textContent, '10 B/s');
assert.equal(ui.nodes.get('gwrtWan6Down').textContent, '40 B/s');
assert.match(ui.nodes.get('gwrtWanTrend').innerHTML, /data-family="ipv4"/);
assert.match(ui.nodes.get('gwrtWanTrend').innerHTML, /data-family="ipv6"/);
ui.context.updateWanTraffic({__rpcError:'network'});
assert.equal(ui.nodes.get('gwrtWan4Total').textContent, '100 B');
assert.equal(ui.nodes.get('gwrtWan6Total').textContent, '200 B');
assert.equal(ui.nodes.get('gwrtWanSampleState').textContent, '稍早数据');
ui = sandbox();
ui.context.gwrtWanTrafficLoad();
assert.equal(ui.nodes.get('gwrtWan4Total').textContent, '100 B', 'page reload preserves counters');
assert.match(ui.nodes.get('gwrtWanTrend').innerHTML, /data-family="ipv6"/, 'page reload preserves shared curve');
ui.context.updateWanTraffic(null);
assert.equal(ui.nodes.get('gwrtWan6Total').textContent, '200 B', 'transient startup failure keeps cache');
const js = template.slice(template.indexOf('<script>')+8,template.lastIndexOf('</script>'));
new vm.Script(js);
console.log(`PASS GWRT theme r122/r123 (${theme}): storage used/total, shared dual-stack graph, cache/reload/failure, NSS parser, SoC and compact layout`);
