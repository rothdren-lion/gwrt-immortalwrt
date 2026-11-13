const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const theme = path.resolve(process.env.GWRT_TEST_THEME || path.join(root, 'gwrt-theme-V3/theme/luci-theme-gwrt'));
const template = fs.readFileSync(path.join(theme, 'root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut'), 'utf8');
function fn(name) {
  const match = template.match(new RegExp('^function ' + name + '\\([^\\n]*\\)(?:\\{[^\\n]*\\}|\\{[\\s\\S]*?^\\})', 'm'));
  assert(match, 'missing function ' + name);
  return match[0];
}
const mac = '02:00:00:00:00:01', other = '02:00:00:00:00:02';
const context = {
  window: {},
  gwrtClientsCache: {map:{}},
  gwrtClientTrackerFresh: () => true,
};
const functions = ['normMac', 'esc', 'devViaKind', 'gwrtClientDetail', 'gwrtClientPortName',
  'devViaLabel', 'gwrtStaInfo', 'gwrtWifiSta', 'gwrtLinkRateMbps', 'signalCellHtml',
  'radioBand', 'radioIsPcie', 'wifiInterfaceIsLanAp', 'wifiConfigDisabled',
  'wifiRadioHasEnabledAp', 'primaryWifiInterface', 'isSs01Board', 'wifiPortEntries'];
vm.runInNewContext(functions.map(fn).join('\n') + '\nglobalThis.api={devViaLabel,signalCellHtml,gwrtStaInfo};', context);
const api = context.api, d = {mac,online:true,conn:'wired'};
const text = html => html.replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim();
function reset() {
  context.window = {_gwrtWifiMacMap:{},_gwrtWifiStaMap:{},_gwrtPortStates:{},_gwrtPorts:[]};
  context.gwrtClientsCache.map = {};
}
function detail(values) { context.gwrtClientsCache.map[mac] = Object.assign({online:true}, values); }

reset();
for (const [port,speed] of [['lan1','1000F'],['lan2','100H'],['lan3',2500],['lan4','10000F']]) {
  detail({via:'wired',port});
  context.window._gwrtPortStates = {[port]:{carrier:true,speed}};
  assert.equal(api.devViaLabel(d),port.toUpperCase());
  assert.equal(text(api.signalCellHtml(d)), parseInt(speed,10)+' Mbps');
}
detail({via:'wired',port:'lan2'});
context.window._gwrtPortStates = {lan1:{carrier:true,speed:'1000F'},lan2:{carrier:false,speed:'2500F'}};
assert.equal(text(api.signalCellHtml(d)), '—', 'unplugged ports have no current negotiated rate');
context.window._gwrtPortStates.lan2={carrier:true,speed:0,'link-supported':['10000baseT/Full']};
assert.equal(text(api.signalCellHtml(d)), '—', 'supported capacity must not become a current rate');
detail({via:'wired',port:''});
context.window._gwrtTopoBridgePorts = {[mac]:'lan1'};
assert.equal(api.devViaLabel(d),'LAN','no current port must not guess LAN1 or use old topology');
assert.equal(text(api.signalCellHtml(d)),'—');

for (const [via,band] of [['wifi24g','2.4G'],['wifi5gl','5.2G'],['wifi5gh','5.8G'],['wifi6g','6G']]) {
  reset();
  detail({via,port:'phy0-ap0',signal:'-72'});
  assert.equal(api.devViaLabel(d),'WiFi '+band,'collector frequency band overrides wired plugin data');
  context.window._gwrtWifiStaMap[mac]=api.gwrtStaInfo({rx:{rate:2401000},tx:{rate:1201000},signal:-48});
  assert.equal(text(api.signalCellHtml(d)),'2401 Mbps -48 dBm');
  assert(api.signalCellHtml(d).includes('发送 1201 Mbps'),'directional negotiated rates remain in tooltip');
}

reset();
detail({via:'wifi5gl',port:'phy-old',signal:'-80'});
context.window._gwrtWifiMacMap[mac]='phy1-ap0';
context.window._gwrtPorts=[{name:'phy1-ap0',ifnames:['phy1-ap0','phy1-ap1'],role:'wifi',band:'2.4G'}];
context.window._gwrtWifiStaMap[mac]=api.gwrtStaInfo({rx:{bitrate_raw:5735},tx:{bitrate:286.8},signal:-51});
context.window._gwrtWifiStaMap[other]=api.gwrtStaInfo({rx:{rate:2401000},signal:-30});
assert.equal(api.devViaLabel(d),'WiFi 2.4G','current radio wins over previous tracker band');
assert.equal(text(api.signalCellHtml(d)),'573.5 Mbps -51 dBm','each device uses its own station rates');
context.window._gwrtWifiStaMap[mac]=api.gwrtStaInfo({rx:{rate:6000},tx:{rate:1201000},signal:-64});
assert.equal(text(api.signalCellHtml(d)),'1201 Mbps -64 dBm','negotiation changes refresh immediately');
assert.equal(text(api.signalCellHtml({...d,online:false})),'—','offline clients do not display stale rates');
context.window._gwrtWifiStaMap[mac]=api.gwrtStaInfo({signal:-64});
assert.equal(text(api.signalCellHtml({...d,rate:999999999,rate_rx:999999999})),'— -64 dBm','traffic is not a PHY rate');
delete context.window._gwrtWifiStaMap[mac];
assert.equal(text(api.signalCellHtml(d)),'— -80 dBm','missing station rate stays unknown');

reset();
detail({via:'wired',port:'usb0'});
context.window._gwrtPorts=[{name:'usb0',role:'lan',label:'<img src=x onerror=alert(1)>'}];
const label = api.devViaLabel(d);
assert.equal(context.esc(label),'&lt;img src=x onerror=alert(1)&gt;');
assert.match(fn('renderDhcp'),/esc\(vl\)/,'connection labels must be escaped when rendered');

context.window._gwrtBoardModel='JDCloud RE-SS-01';
for (const [frequency,channel,band] of [[2412,1,'2.4G'],[5180,36,'5.2G'],[5745,149,'5.8G'],[6115,33,'6G']]) {
  const radios={radio0:{config:{band:frequency<3000?'2g':frequency>5925?'6g':'5g'},
    iwinfo:{frequency,channel},interfaces:[{ifname:'phy0-ap0',config:{mode:'ap',network:['lan']}}]}};
  const port=context.wifiPortEntries(radios)[0];
  assert.equal(port.band,band,'runtime frequency takes priority over a board default');
  context.window._gwrtPorts=[port];
  context.window._gwrtWifiMacMap={[mac]:'phy0-ap0'};
  assert.equal(api.devViaLabel(d),'WiFi '+band);
}
console.log('PASS client LAN/radio labels, per-device negotiated rates, signal, offline and missing-data behavior');
