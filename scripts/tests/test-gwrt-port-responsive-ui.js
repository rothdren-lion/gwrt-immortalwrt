const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.GWRT_PLAYWRIGHT || '/home/godsun/node_modules/playwright');
const root = path.resolve(__dirname, '../..');
const theme = process.env.GWRT_TEST_THEME || path.join(root, 'gwrt-theme-V3/theme/luci-theme-gwrt');
const css = fs.readFileSync(path.join(theme, 'htdocs/luci-static/gwrt/css/cascade.css'), 'utf8');
const template = fs.readFileSync(path.join(theme, 'root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut'), 'utf8');
const renderer = template.slice(template.indexOf('function renderPortStrip('), template.indexOf('function refreshPorts('));

(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.GWRT_CHROME || '/usr/bin/google-chrome', args:['--no-sandbox']});
  try {
    const page = await browser.newPage();
    await page.setContent('<div style="padding:16px"><div class="gwrt-port-strip-wrap"><div id="gwrtPortStrip" class="gwrt-port-strip"></div></div></div>');
    await page.addStyleTag({content:css});
    await page.addScriptTag({content:`
      var portPrev={}; window._gwrtBoardModel="JDCloud RE-SS-01";
      function esc(s){return String(s||'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
      function F(){return '1.2 MB';}
      function fmtSpeed(){return '12 KB/s';}
      function portSpeed(s){return s>=1000?'1G':s+'M';}
      function portTrendRef(){return 1000;}
      function portTrendPoints(){return '0,30 50,10 100,20';}
      function showPortSettings(p){window.openedPort=p.name;}
      function showPonPanel(p){window.openedPort=p.name;}
      function ponCardHtml(p){return '<div class="gwrt-port wan pon" data-gwrt-port-name="'+p.name+'" data-gwrt-port-role="wan">PON</div>';}
      ${renderer}
      window.renderFixture=function(lanCount,wifiCount,pon){
        var ports=[{name:pon?'pon0':'wan',label:pon?'PON':'WAN',role:'wan',pon:!!pon}],states={};
        for(var i=1;i<=lanCount;i++)ports.push({name:'lan'+i,label:'LAN'+i,role:'lan'});
        for(var i=0;i<wifiCount;i++)ports.push({name:'radio'+i,label:'WiFi '+(i?'5G':'2.4G'),role:'wifi',wifiUp:true,channel:i?149:1,clients:2,maxRateKbps:i?2401000:573500});
        ports.forEach(function(p,i){states[p.name]={carrier:true,speed:1000,'link-supported':[(i===1?2500:i===2?5000:i===3?10000:1000)+'baseT/Full']};});
        renderPortStrip(states,ports);
      };
    `});
    for (const width of [1440,1024,740,390,320]) {
      await page.setViewportSize({width,height:800});
      for (const [lan,wifi] of [[3,2],[1,2],[0,2],[0,0],[8,3]]) {
        await page.evaluate(([lan,wifi])=>renderFixture(lan,wifi,false),[lan,wifi]);
        const layout=await page.evaluate(()=>{
          const strip=document.getElementById('gwrtPortStrip'),groups=[...strip.children],rect=strip.getBoundingClientRect();
          return {
            groupNames:groups.map(e=>e.getAttribute('aria-label')),
            widths:[...strip.querySelectorAll('.gwrt-port')].map(e=>e.getBoundingClientRect().width),
            lanWidths:[...strip.querySelectorAll('.group-lan .gwrt-port')].map(e=>e.getBoundingClientRect().width),
            overflow:document.documentElement.scrollWidth>document.documentElement.clientWidth,
            centered:Math.abs((rect.left+rect.right)/2-innerWidth/2)<2,
            stripWidth:rect.width,
            groupBorders:groups.map(e=>parseFloat(getComputedStyle(e).borderTopWidth))
          };
        });
        assert.deepEqual(layout.groupNames,['WAN',...(lan?['LAN']:[]),...(wifi?['WIFI']:[])],`${width}: roles remain separate groups`);
        assert(!layout.overflow,`${width}, ${lan+wifi+1} ports: no horizontal page overflow`);
        assert(layout.groupBorders.every(n=>n>=2),'groups retain the original outer outlines');
        if (width>800) {
          if(layout.widths.length>1)assert(layout.widths.every(w=>Math.abs(w-layout.widths[1])<30),`${width}, ${lan+wifi+1} ports: balanced widths ${layout.widths}`);
          if(lan+wifi)assert(layout.widths[0]>layout.widths[1]&&layout.widths[0]<layout.widths[1]*1.25,'WAN has a modest width allowance');
          if(lan+wifi+1<=4)assert(layout.centered&&layout.stripWidth<width*.8,'few-port devices stay compact and centered');
        }
        if(layout.lanWidths.length)assert(Math.max(...layout.lanWidths)-Math.min(...layout.lanWidths)<2,'ports in a LAN group have equal widths');
      }
    }
    await page.setViewportSize({width:1440,height:900});
    await page.evaluate(()=>renderFixture(3,2,false));
    const rings=await page.evaluate(()=>[...document.querySelectorAll('.rate-25g,.rate-5g,.rate-10g')].map(e=>({
      type:e.className,first:getComputedStyle(e,'::before').borderTopColor,second:getComputedStyle(e,'::after').borderTopColor,
      inset1:parseFloat(getComputedStyle(e,'::before').top),inset2:parseFloat(getComputedStyle(e,'::after').top)
    })));
    assert.equal(rings[0].first,'rgb(59, 130, 246)');
    assert.equal(rings[1].first,'rgb(239, 68, 68)');
    assert.equal(rings[2].first,'rgb(239, 68, 68)');
    assert.equal(rings[2].second,'rgb(239, 68, 68)');
    assert(rings.every(r=>r.inset1>=7),'capability lines are inset from outer group borders');
    assert(rings[2].inset2>rings[2].inset1,'10G has two separated lines');
    await page.locator('[data-gwrt-port-name="lan1"]').click();
    assert.equal(await page.evaluate(()=>openedPort),'lan1','grouping preserves port settings clicks');
    assert((await page.locator('.gwrt-port-wifi-rate').allTextContents()).includes('2401 Mbps'));
    await page.evaluate(()=>renderFixture(4,2,true));
    assert.equal(await page.locator('.group-wan .gwrt-port.pon').count(),1,'optical WAN keeps its PON card');
    console.log('PASS WAN/LAN/WIFI groups, equal port widths, compact centering, rings, rates and clicks at 320–1440px');
  }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
