const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const theme = path.resolve(process.env.GWRT_TEST_THEME || path.join(root, 'gwrt-theme-V3/theme/luci-theme-gwrt'));
const template = fs.readFileSync(path.join(theme, 'root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut'), 'utf8');
const start = template.indexOf("var GWRT_DEVICE_ALIAS_KEY='gwrt_device_alias_v1';");
const end = template.indexOf('function devDisplayName(', start);
assert(start >= 0 && end > start, 'device label persistence helpers must remain available');

const config = {};
let sectionId = 0;
const storage = {};
const context = {
  cleanHost: s => String(s || '').replace(/\\.lan$/i, '').trim(),
  normMac: s => {
    const raw = String(s || '').toLowerCase();
    const hex = raw.replace(/[^0-9a-f]/g, '');
    return hex.length === 12 ? hex.match(/.{2}/g).join(':') : raw;
  },
  localStorage: {
    getItem: key => storage[key] || null,
    setItem: (key, value) => { storage[key] = value; }
  },
  gwrtRerenderDeviceViews: () => {},
  rpcD: (object, method, args) => {
    assert.equal(object, 'uci');
    if (method === 'get') return Promise.resolve(context.readFail ? {__rpcError:'denied'} : {values: JSON.parse(JSON.stringify(config))});
    throw new Error('unexpected read RPC: ' + method);
  },
  rpcMust: (object, method, args) => {
    assert.equal(object, 'uci');
    if (method === 'add') {
      const section = 'cfg' + (++sectionId);
      config[section] = Object.assign({'.type': args.type}, args.values);
      return Promise.resolve({section});
    }
    if (method === 'set') {
      config[args.section] = Object.assign({}, config[args.section], args.values);
      return Promise.resolve({});
    }
    if (method === 'delete') {
      delete config[args.section];
      return Promise.resolve({});
    }
    if (method === 'commit') return Promise.resolve({});
    throw new Error('unexpected write RPC: ' + method);
  }
};

vm.runInNewContext(template.slice(start, end) + `
globalThis.api = {
  load: gwrtLoadDeviceLabels,
  set: gwrtSetDeviceLabel,
  aliases: gwrtDeviceAliases,
  identity: gwrtDeviceLabelIdentity,
  apply: gwrtApplyDeviceAlias,
  reset: function(){gwrtDeviceAliasCache=null;gwrtDeviceLabelLoading=null;}
};`, context);

(async () => {
  const mac = '02:00:00:00:00:11';
  assert.equal(context.api.identity('ip:123.123.123.123').id,'ip:123.123.123.123','IPv4 keys must not be mistaken for hex MAC addresses');
  await context.api.load();
  await context.api.set(mac, {name:'NAS', brand:'synology', type:'pc'});
  assert.equal(Object.keys(config).length, 1, 'the first MAC label creates one UCI device section');
  assert.equal(Object.values(config)[0].name, 'NAS');
  assert.equal(Object.values(config)[0].brand, 'synology');
  assert.equal(Object.values(config)[0].type, 'pc');

  context.api.reset();
  await context.api.load();
  assert.equal(context.api.aliases()[mac].name, 'NAS', 'manual names reload from router UCI');
  assert.equal(context.api.aliases()[mac].brand, 'synology', 'manual brand reloads from router UCI');
  assert.equal(context.api.aliases()[mac].type, 'pc', 'manual device type reloads from router UCI');

  await context.api.set(mac, {name:'NAS', brand:'', type:'pc'});
  context.api.reset();
  await context.api.load();
  assert.equal(context.api.aliases()[mac].brand, '', 'clearing one field removes the stale saved value');
  assert.equal(context.api.aliases()[mac].type, 'pc');

  await context.api.set(mac, {name:'', brand:'', type:''});
  assert.equal(Object.keys(config).length, 0, 'resetting a MAC label deletes its router UCI section');

  await context.api.set('ip:192.0.2.8', {name:'IP labeled device', brand:'', type:'iot'});
  assert.equal(Object.keys(config).length, 1, 'an IPv4-only device label is also stored in router UCI');
  context.api.reset();
  await context.api.load();
  assert.equal(context.api.aliases()['ip:192.0.2.8'].name, 'IP labeled device', 'IPv4-only labels reload from router UCI');
  assert.equal(context.api.aliases()['ip:192.0.2.8'].type, 'iot');
  const device={ip:'192.0.2.8',name:'router-auto-name'};
  context.api.apply(device);
  assert.equal(device.name,'IP labeled device','IPv4-only custom name overrides refreshed automatic detection');
  assert.equal(device.label_type,'iot','IPv4-only manual type survives refresh');
  await context.api.set('ip:192.0.2.8', {name:'', brand:'', type:''});
  assert.equal(Object.keys(config).length, 0, 'resetting an IPv4 label deletes its router UCI section');

  await context.api.set('name:temporary-device', {name:'Temporary device', brand:'', type:''});
  assert.equal(Object.keys(config).length, 0, 'labels with no MAC or IPv4 remain browser-local');
  assert.match(storage.gwrt_device_alias_v1, /Temporary device/);

  const aliases=JSON.parse(storage.gwrt_device_alias_v1);
  aliases['ip:198.51.100.6']={name:'Migrated browser label',brand:'',type:'phone'};
  storage.gwrt_device_alias_v1=JSON.stringify(aliases);
  context.api.reset();
  await context.api.load();
  assert.equal(Object.values(config).some(section=>section.ip==='198.51.100.6'&&section.name==='Migrated browser label'),true,'legacy browser labels with IPv4 migrate to router UCI');

  context.readFail=true;
  await assert.rejects(context.api.set(mac,{name:'Cannot fake-save',brand:'',type:'pc'}),/读取路由器设备标注失败/,'router read failures must not be reported as saved');
  console.log('PASS GWRT device labels persist by MAC or IPv4, reload from UCI, clear stale fields, and keep name-only labels local');
})().catch(error => { console.error(error); process.exit(1); });
