const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.GWRT_PLAYWRIGHT || '/home/godsun/node_modules/playwright');

const root = path.resolve(__dirname, '../..');
const theme = path.resolve(process.env.GWRT_TEST_THEME || path.join(root, 'gwrt-theme-V3/theme/luci-theme-gwrt'));
const css = fs.readFileSync(path.join(theme, 'htdocs/luci-static/gwrt/css/cascade.css'), 'utf8');

(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.GWRT_CHROME || '/usr/bin/google-chrome', args:['--no-sandbox']});
  try {
    const page = await browser.newPage({viewport:{width:390,height:844}});
    await page.setContent(`<div class="gwrt-net-section" style="width:100%;padding:8px"><div id="gwrtPortStripWrap" class="gwrt-port-strip-wrap"><div id="gwrtPortStrip" class="gwrt-port-strip">
      <div class="gwrt-port wan up">WAN</div><div class="gwrt-port lan up rate-25g">LAN 2.5G</div><div class="gwrt-port lan up rate-5g">LAN 5G</div><div class="gwrt-port lan up rate-10g">LAN 10G</div><div class="gwrt-port wifi up">WiFi 2.4G</div><div class="gwrt-port wifi up">WiFi 5G</div>
    </div></div></div>`);
    await page.addStyleTag({content:css});
    const layout = await page.evaluate(() => {
      const strip=document.getElementById('gwrtPortStrip'),cards=[...strip.querySelectorAll('.gwrt-port')];
      return {
        display:getComputedStyle(strip).display,
        columns:getComputedStyle(strip).gridTemplateColumns.split(' ').length,
        widths:cards.map(card=>Math.round(card.getBoundingClientRect().width)),
        wanHeight:Math.round(cards[0].getBoundingClientRect().height),
        lanHeight:Math.round(cards[1].getBoundingClientRect().height),
        ring25:getComputedStyle(cards[1],'::before').borderTopColor,
        ring5:getComputedStyle(cards[2],'::before').borderTopColor,
        ring10a:getComputedStyle(cards[3],'::before').borderTopColor,
        ring10b:getComputedStyle(cards[3],'::after').borderTopColor,
        ringInsets:[getComputedStyle(cards[3],'::before').top,getComputedStyle(cards[3],'::after').top],
        viewportWidth:document.documentElement.clientWidth,
        pageWidth:document.documentElement.scrollWidth
      };
    });
    assert.equal(layout.display,'grid','port cards use a responsive grid');
    assert(layout.columns>=2,'mobile page lays out available ports in multiple balanced columns');
    assert(layout.widths.every(w=>Math.abs(w-layout.widths[1])<12),'port cards have near-equal widths, with WAN only modestly larger');
    assert(layout.wanHeight>layout.lanHeight,'WAN card is slightly larger');
    assert.equal(layout.ring25,'rgb(59, 130, 246)','2.5G ring is blue');
    assert.equal(layout.ring5,'rgb(239, 68, 68)','5G ring is red');
    assert.equal(layout.ring10a,'rgb(239, 68, 68)','10G outer inner-ring is red');
    assert.equal(layout.ring10b,'rgb(239, 68, 68)','10G second inner-ring is red');
    assert.notEqual(layout.ringInsets[0],layout.ringInsets[1],'10G rings are inset from each other');
    assert(layout.pageWidth<=layout.viewportWidth,'port layout does not force mobile page overflow');
    await page.setViewportSize({width:1280,height:844});
    assert.equal(await page.locator('#gwrtPortStrip').evaluate(el=>getComputedStyle(el).display),'grid','desktop layout stays fluid');
    console.log('PASS responsive Ethernet/Wi-Fi port grid and inset capability rings');
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exit(1);});
