const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const theme = path.resolve(process.env.GWRT_TEST_THEME || path.join(root, 'gwrt-theme-V3/theme/luci-theme-gwrt'));
const acl = JSON.parse(fs.readFileSync(path.join(theme, 'root/usr/share/rpcd/acl.d/luci-theme-gwrt.json'), 'utf8'))['luci-theme-gwrt'];
const readFile = acl.read.file;
const writeFile = acl.write.file;
const template = fs.readFileSync(path.join(theme, 'root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut'), 'utf8');
const css = fs.readFileSync(path.join(theme, 'htdocs/luci-static/gwrt/css/cascade.css'), 'utf8');
const dhcpHook = fs.readFileSync(path.join(theme, 'root/etc/hotplug.d/dhcp/30-gwrt-dhcp-fp'), 'utf8');
const wan6Helper = fs.readFileSync(path.join(theme, 'root/usr/libexec/gwrt-wan6-address'), 'utf8');

assert.equal(readFile['/bin/cat'], undefined, 'read access must not expose arbitrary root file reads');
assert.equal(readFile['/usr/libexec/gwrt-ota'], undefined, 'read access must not expose OTA apply');
assert.equal(readFile['/usr/libexec/gwrt-lan-alias'], undefined, 'read access must not alter LAN addresses');
assert.equal(readFile['/usr/sbin/conntrack'], undefined, 'read access must not mutate conntrack');
assert.deepEqual(readFile['/usr/libexec/gwrt-ota status'], ['exec']);
assert.deepEqual(readFile['/usr/libexec/gwrt-ota check'], ['exec']);
assert.deepEqual(readFile['/usr/libexec/gwrt-coremark status'], ['exec']);
assert.deepEqual(readFile['/usr/sbin/ponctl --device pon0 status --json'], ['exec']);
assert.equal(readFile['/usr/sbin/ponctl'], undefined, 'PON telemetry grants only the fixed read command');
assert.deepEqual(writeFile['/usr/libexec/pon-wan-apply apply'], ['exec']);
assert.deepEqual(readFile['/bin/cat /proc/stat'], ['exec']);
assert.deepEqual(readFile['/bin/cat /sys/kernel/debug/clk/clk_summary'], ['exec']);
assert.deepEqual(readFile['/bin/cat /sys/class/thermal/thermal_zone0/temp'], ['exec']);
assert.equal(writeFile['/usr/libexec/gwrt-ota'], undefined, 'write access must be limited to OTA apply');
assert.deepEqual(writeFile['/usr/libexec/gwrt-ota apply'], ['exec']);
assert.deepEqual(writeFile['/usr/libexec/gwrt-coremark start'], ['exec']);
assert.deepEqual(writeFile['/etc/init.d/eqos reload'], ['exec']);
assert.deepEqual(writeFile['/etc/init.d/eqos stop'], ['exec']);
assert.deepEqual(writeFile['/etc/init.d/firewall reload'], ['exec']);
assert.deepEqual(writeFile['/usr/sbin/conntrack -D -s *'], ['exec']);
assert.deepEqual(writeFile['/usr/sbin/conntrack -D -d *'], ['exec']);
assert.deepEqual(writeFile['/etc/init.d/sysntpd restart'], ['exec']);
assert.match(dhcpHook, /\[0-9a-f\]\[0-9a-f\]:\[0-9a-f\]/, 'DHCP hook must validate MAC syntax before sed');
assert.match(wan6Helper, /case \"\$gwrt_dev\" in/, 'WAN6 helper must validate device names');

const escapeMatch = template.match(/^function esc\(s\)\{[^\n]*\}/m);
const letterMatch = template.match(/^function gwrtContLetter\(name,up\)\{[^\n]*\n(?:[^\n]*\n)*?\}/m);
assert(escapeMatch && letterMatch, 'container letter renderer and HTML escaping helper must remain available');
const letterSandbox = {};
vm.runInNewContext(`${escapeMatch[0]}\n${letterMatch[0]}\nglobalThis.renderLetter=gwrtContLetter;`, letterSandbox);
const injectedName = letterSandbox.renderLetter('<script>alert(1)</script>', true);
assert.match(injectedName, /&lt;/, 'container names must be escaped before entering SVG text markup');
assert.doesNotMatch(injectedName, /<script>/, 'container names must not create executable SVG/HTML markup');

const start = template.indexOf('function ethPortEntries(');
const end = template.indexOf('function wifiPortEntries(', start);
assert(start >= 0 && end > start, 'network port helpers must remain available');
const sandbox = {};
vm.runInNewContext(template.slice(start, end) + `
globalThis.portHelpers = {
  ethPortEntries, gwrtResolveWanDevice, gwrtApplyWanPort, bridgeLanPortEntries
};`, sandbox);

const { ethPortEntries, gwrtResolveWanDevice, gwrtApplyWanPort, bridgeLanPortEntries } = sandbox.portHelpers;
const ports = ethPortEntries([
  { role: 'unknown', device: 'wan' },
  { role: 'wan', device: 'eth0' },
  { role: 'lan', device: 'eth1' }
]);
assert.equal(ports[0].role, 'wan', 'unknown-role device named wan must remain WAN');
const liveWan = gwrtResolveWanDevice(ports, ['pppoe-wan', 'eth1.100', 'eth0']);
assert.equal(liveWan, 'eth1', 'VLAN WAN device must resolve to its physical port');
gwrtApplyWanPort(ports, liveWan);
assert.deepEqual(Array.from(ports.filter(p => p.role === 'wan'), p => p.name), ['eth1']);
assert.equal(ports.find(p => p.name === 'eth0').role, 'lan', 'stale board WAN mapping must not override live netifd state');

const ponPorts = ethPortEntries([{role:'wan',device:'pon0'},{role:'lan',device:'lan1'}]);
assert.equal(ponPorts[0].pon, true, 'AN758x optical ports keep their PON identity');
gwrtApplyWanPort(ponPorts, 'pon0');
assert.equal(ponPorts[0].label, 'PON', 'live WAN detection keeps the optical card label');
assert.equal(ponPorts[0].role, 'wan');
const dynamicPon = [];
gwrtApplyWanPort(dynamicPon, 'pon0');
assert.equal(dynamicPon[0].pon, true, 'a runtime-only optical uplink receives its PON card');

const an7581LanPorts = bridgeLanPortEntries({ 'bridge-members': ['lan1', 'lan2', 'lan3', 'lan4'] }, []);
assert.deepEqual(Array.from(an7581LanPorts, p => p.name), ['lan1', 'lan2', 'lan3', 'lan4']);

const maxRateMatch=template.match(/function portMaxRateTag\(st\)\{[\s\S]*?\n  \}/);
assert(maxRateMatch,'DTS/PHY interface capability classifier must remain available');
const rateSandbox={};
vm.runInNewContext(maxRateMatch[0]+'\nglobalThis.rateTag=portMaxRateTag;',rateSandbox);
assert.equal(rateSandbox.rateTag({'link-supported':['1000baseT/Full','2500base-X/Full']}),'2.5G');
assert.equal(rateSandbox.rateTag({'link-supported':['5000baseT/Full']}),'5G');
assert.equal(rateSandbox.rateTag({'link-supported':['10000baseT/Full']}),'10G');
assert.equal(rateSandbox.rateTag({'link-supported':['1000baseT/Full']}),'');
assert.match(template,/window\._gwrtRateClasses\[p\.name\]='rate-'\+tag\.toLowerCase\(\)\.replace\('\.',''\)/,'port capability is mapped to the visual ring class');

const staStart = template.indexOf('function gwrtStaInfo(');
const staEnd = template.indexOf('function gwrtSigLevel(', staStart);
assert(staStart >= 0 && staEnd > staStart, 'wireless station rate normalizer must remain available');
const staSandbox = {};
vm.runInNewContext(template.slice(staStart, staEnd) + '\nglobalThis.readStation=gwrtStaInfo;', staSandbox);
const station = staSandbox.readStation({rx:{bitrate:'1200.0',bitrate_raw:12000},tx:{bitrate:'866.7',bitrate_raw:8667}});
assert.equal(station.rx_rate, 1200000, 'iwinfo raw receive bitrate converts to kbps');
assert.equal(station.tx_rate, 866700, 'iwinfo raw transmit bitrate converts to kbps');
assert(template.includes("Math.round(Number(p.maxRateKbps)/1000)+' Mbps"), 'Wi-Fi cards show the highest associated PHY rate in Mbps');
assert.match(template, /p\.maxRateKbps=Math\.max\(p\.maxRateKbps,Number\(info\.rx_rate\)\|\|0,Number\(info\.tx_rate\)\|\|0\)/, 'Wi-Fi cards aggregate the fastest associated client per radio');
assert.match(template, /data-gwrt-menu-target="service"/, 'dashboard cards expose menu shortcuts');
assert.match(template, /gwrtSetupMenuCardLinks\(\)/, 'dashboard card shortcuts are wired');
assert.match(template, /portGroup\('lan',lanOnly,1\)/, 'physical LAN ports stay in one group');
assert.match(template, /portGroup\('wifi',wifiOnly,1\)/, 'wireless radios stay in their own group');
assert.match(css, /\.gwrt-port\.rate-25g::before\{inset:8px;border-color:#3b82f6\}/, '2.5G ports get an inset blue ring');
assert.match(css, /\.gwrt-port\.rate-5g::before\{inset:8px;border-color:#ef4444\}/, '5G ports get an inset red ring');
assert.match(css, /\.gwrt-port\.rate-10g::after\{inset:12px;border-color:#ef4444\}/, '10G ports get two separated red rings');

const meshMetricStart = template.indexOf('function gwrtMeshUplinkMetric(');
const meshMetricEnd = template.indexOf('function gwrtRedrawMeshTopology(', meshMetricStart);
assert(meshMetricStart >= 0 && meshMetricEnd > meshMetricStart, 'wireless Mesh link metric formatter must remain available');
const meshMetricSandbox = {};
vm.runInNewContext(template.slice(meshMetricStart, meshMetricEnd) + '\nglobalThis.meshMetric=gwrtMeshUplinkMetric;', meshMetricSandbox);
assert.equal(meshMetricSandbox.meshMetric({tx_rate_mbps:1200,rx_rate_mbps:866,rssi:-53}, 'wireless'), 'TX 1.2 Gbps · RX 866 Mbps · 信号 -53 dBm');
assert.equal(meshMetricSandbox.meshMetric({tx_rate_mbps:1200,rssi:-53}, 'wired'), '');

console.log('PASS GWRT theme ACL boundaries and runtime WAN/LAN port mapping');
