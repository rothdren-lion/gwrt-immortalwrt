/* Exercise the real dashboard Mesh renderer in Chrome with isolated RPC data. */
const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const { chromium } = require(process.env.GWRT_PLAYWRIGHT || '/home/godsun/node_modules/playwright');
const root = path.resolve(__dirname, '../..');
const canonical = path.join(root,'gwrt-theme-V3/theme/luci-theme-gwrt');
const theme = process.env.GWRT_TEST_THEME || (fs.existsSync(canonical)?canonical:path.join(root,'package/gwrt-theme/luci-theme-gwrt'));
const source = fs.readFileSync(path.join(theme, 'root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut'), 'utf8');
const normalization = source.match(/^function normMac\(s\)\{[\s\S]*?^\}/m);
const start = source.indexOf('function gwrtMeshNodeKey(');
const end = source.indexOf('function renderPortStrip(', start);
assert(normalization && start >= 0 && end > start, 'Mesh renderer not found in '+theme+'; set GWRT_TEST_THEME to the installed theme package');
const normalize = normalization[0];
const code = source.slice(start, end);
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.GWRT_CHROME || '/usr/bin/google-chrome', args:['--no-sandbox']});
  try {
    const page = await browser.newPage({viewport:{width:390,height:844}});
    await page.setContent('<div id="gwrtMeshInfo"></div>');
    await page.evaluate(() => {
      window.esc = s => String(s || '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
      window.toasts = []; window.calls = []; window.rpcCache = {};
      window.gwrtToast = (text, kind) => toasts.push({text,kind});
      window.gwrtOpenModal = () => {};
      window.fixture = {
        status:{role:'cap',mac:'02:00:00:00:00:01'},
        topology:{self:'020000000001',role:'cap',nodes:[{id:'020000000003',type:'ap',role:'sap',authed:true}]},
        discover:{devices:[{mac:'02:00:00:00:00:02',ip:'192.0.2.2',name:'AP <img src=x>',model:'Test'},
          {mac:'020000000002',ip:'192.0.2.2',name:'Duplicate'},
          {mac:'02:00:00:00:00:03',name:'Member'}, {mac:'02:00:00:00:00:01',name:'Self'}]}
      };
      window.rpc = async (obj, method, args) => {calls.push({method,args}); return method==='pair'?{ok:true}:fixture[method];};
      window.rpcD = window.rpc;
      window.rpcCached = (key, ttl, obj, method) => rpc(obj, method);
    });
    await page.addScriptTag({content:normalize+'\n'+code});
    await page.evaluate(() => renderMeshInfo());
    assert.equal(await page.locator('[data-gwrt-mesh-add]').count(), 1, 'only one valid new AP is offered');
    assert.equal(await page.locator('#gwrtMeshInfo img').count(), 0, 'device names remain text');
    await page.locator('[data-gwrt-mesh-add]').click();
    assert.equal(await page.locator('[data-gwrt-mesh-add]:disabled').count(), 1, 'pending addition stays disabled');
    await page.evaluate(() => {
      fixture.discover.devices=[];
      fixture.topology.nodes.push({id:'020000000002',type:'ap',role:'sap',authed:true,online:true});
      return renderMeshInfo();
    });
    assert.equal(await page.locator('[data-gwrt-mesh-add]').count(), 0, 'joined AP disappears from discovery');
    assert.equal(await page.evaluate(() => toasts.filter(t=>t.kind==='success').length), 1, 'success follows authenticated topology');
    await page.evaluate(() => {
      fixture.discover.devices=[{mac:'02:00:00:00:00:04',ip:'192.0.2.4',name:'Reject'}];
      window.rpc=async (obj,method,args)=>method==='pair'?{ok:false,error:'not_found'}:fixture[method];
      return renderMeshInfo();
    });
    await page.locator('[data-gwrt-mesh-add]').click();
    assert.equal(await page.locator('[data-gwrt-mesh-add]:disabled').count(), 0, 'failure permits retry');
    assert(await page.evaluate(() => toasts.some(t=>t.kind==='error')), 'failure is visible');
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 390, 'mobile width remains bounded');
    console.log('PASS Mesh discovery, deduplication, escaping, add, authenticated completion, failure/retry and mobile width');
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1);});
