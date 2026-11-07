const fs = require('fs');
const path = require('path');
const assert = require('assert/strict');
const { chromium } = require(process.env.GWRT_PLAYWRIGHT || '/home/godsun/node_modules/playwright');
const root = path.resolve(__dirname, '..');
(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.GWRT_CHROME || '/usr/bin/google-chrome', args:['--no-sandbox']});
  try {
    const page = await browser.newPage({viewport:{width:390,height:844}});
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    const now = new Date();
    await page.clock.install({time:now});
    await page.addInitScript(() => {
      window.testIntervals = [];
      const original = window.setInterval;
      window.setInterval = (fn, ms, ...args) => { testIntervals.push(ms); return original(fn, ms, ...args); };
    });
    const mesh = {available:true,role:'cap',peers_online:1,members:[{mac:'02:00:00:00:00:03',name:'Joined',online:true}],discovered_devices:[
      {mac:'02:00:00:00:00:02',name:'AP <img src=x onerror=alert(1)>',ip:'192.0.2.2',pairable:true},
      {mac:'020000000002',name:'duplicate'}, {mac:'02:00:00:00:00:01',name:'self'}, {mac:'02:00:00:00:00:03',name:'member'}]};
    const device = {device_id:'GWRT-release-test',name:'Release Test AP',mac:'02:00:00:00:00:01',model:'Test AP',online:true,can_manage:true,bound:true,agent_version:1712,last_seen:Math.floor(now.getTime()/1000),telemetry:{},clients:[],packages:{},containers:{},oaf:{},topology:{},mesh};
    let deviceRequests = 0, commandStatus = 'failed', commands = [], hold = false, release = null;
    const payload = body => ({status:200,contentType:'application/json',body:JSON.stringify(body)});
    await page.route('http://gwrt.test/**', async route => {
      const request = route.request(), url = new URL(request.url());
      if (url.pathname === '/api/devices') {
        deviceRequests++;
        if (hold) await new Promise(resolve => { release = resolve; });
        return route.fulfill(payload({ok:true,devices:[device]}));
      }
      if (url.pathname.endsWith('/commands') && request.method() === 'POST') {
        commands.push({body:request.postDataJSON(),csrf:request.headers()['x-gwrt-csrf']});
        return route.fulfill({...payload({ok:true,command_id:'test-command'}),status:202});
      }
      if (url.pathname === '/api/commands/test-command') {
        if (commandStatus === 'success') { mesh.discovered_devices=[]; mesh.members.push({mac:'02:00:00:00:00:02',name:'Added',online:true}); }
        return route.fulfill(payload({ok:true,command:{status:commandStatus,result:commandStatus==='failed'?'not_found':'joined'}}));
      }
      if (url.pathname === '/api/me') return route.fulfill(payload({ok:true,user:{username:'release-test',is_admin:false},csrf:'test-csrf'}));
      if (url.pathname === '/api/healthz') return route.fulfill(payload({ok:true,version:'17.17',build_time:'test'}));
      if (url.pathname.startsWith('/api/')) return route.fulfill(payload({ok:true,settings:{}}));
      const name = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
      if (!['index.html','app.js','style.css'].includes(name)) return route.fulfill({status:404,body:''});
      return route.fulfill({status:200,contentType:name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html',body:fs.readFileSync(path.join(root,'static',name),'utf8')});
    });
    await page.goto('http://gwrt.test/');
    await page.waitForFunction(() => window.testIntervals.includes(5000));
    assert.equal(deviceRequests,1);
    await page.clock.runFor(4999);
    assert.equal(deviceRequests,1,'overview waits for the five-second boundary');
    await page.clock.runFor(1);
    await page.waitForFunction(() => document.querySelector('.fleet-card'));
    assert.equal(deviceRequests,2,'overview refreshes at five seconds');
    await page.locator('.fleet-card').click();
    await page.locator('[data-dtab="mesh"]').click();
    assert.equal(await page.locator('[data-mesh-add]').count(),1,'self, member and duplicate are excluded');
    assert.equal(await page.locator('.mesh-panel img').count(),0,'candidate names are escaped');
    await page.locator('[data-mesh-add]').click();
    assert.equal(await page.locator('[data-mesh-add]:disabled').count(),1);
    await page.clock.runFor(701);
    await page.waitForFunction(() => document.querySelector('#toast').textContent.includes('失败'));
    assert.equal(await page.locator('[data-mesh-add]:disabled').count(),0,'failure permits retry');
    assert.equal(commands.length,1);
    assert.deepEqual(commands[0],{body:{kind:'mesh.pair',payload:{mac:'02:00:00:00:00:02'}},csrf:'test-csrf'});
    commandStatus='success';
    await page.locator('[data-mesh-add]').click();
    await page.clock.runFor(701);
    await page.waitForFunction(() => document.querySelector('#toast').textContent.includes('完成'));
    assert.equal(await page.locator('[data-mesh-add]').count(),0,'successful AP is removed from discovery');
    mesh.discovered_devices=[{mac:'02:00:00:00:00:04',name:'New candidate'}];
    device.can_manage=false;
    await page.clock.runFor(5000);
    await page.waitForSelector('[data-mesh-add]:disabled');
    assert.equal(await page.locator('[data-mesh-add]:disabled').count(),1,'readonly device cannot be paired');
    device.can_manage=true; device.last_seen=0;
    await page.clock.runFor(5000);
    await page.waitForFunction(() => document.querySelector('.mesh-panel').textContent.includes('数据已过期'));
    assert.equal(await page.locator('[data-mesh-add]:disabled').count(),1,'stale discovery cannot be paired');
    device.last_seen=Math.floor(now.getTime()/1000);
    hold=true;
    await page.clock.runFor(5000);
    await page.waitForTimeout(10);
    const during = deviceRequests;
    await page.clock.runFor(10000);
    assert.equal(deviceRequests,during,'slow refresh requests do not overlap');
    hold=false; if (release) release();
    await page.waitForTimeout(20);
    for (const width of [390,1440]) {
      await page.setViewportSize({width,height:900});
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth),width,'layout fits '+width);
      assert(!(await page.locator('#device-info-card').innerText()).includes('undefined'),'missing weather fields have a fallback');
      if (process.env.GWRT_CONTROL_SCREENSHOT_DIR) await page.screenshot({path:path.join(process.env.GWRT_CONTROL_SCREENSHOT_DIR,'control-'+width+'.png'),fullPage:true});
    }
    assert.deepEqual(errors,[]);
    console.log('PASS Control: five-second refresh, no overlap, Mesh discovery/dedup/escaping, authenticated add, failure/retry, success, readonly/stale guards, mobile/desktop and no page errors');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });
