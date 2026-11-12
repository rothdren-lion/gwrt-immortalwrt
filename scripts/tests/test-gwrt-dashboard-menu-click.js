const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {chromium} = require(process.env.GWRT_PLAYWRIGHT || '/home/godsun/node_modules/playwright');

const root = path.resolve(__dirname, '../..');
const theme = path.resolve(process.env.GWRT_TEST_THEME || path.join(root, 'gwrt-theme-V3/theme/luci-theme-gwrt'));
const template = fs.readFileSync(path.join(theme, 'root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut'), 'utf8');
function extractFunction(name) {
  const start = template.indexOf('function ' + name + '(');
  assert(start >= 0, 'missing function ' + name);
  const brace = template.indexOf('{', start);
  let depth = 0;
  for (let i = brace; i < template.length; i++) {
    if (template[i] === '{') depth++;
    if (template[i] === '}' && --depth === 0) return template.slice(start, i + 1);
  }
  throw new Error('unterminated function ' + name);
}
const script = [
  "var gwrtHomeMenuActive='overview';",
  extractFunction('gwrtSelectHomeMenu'),
  extractFunction('gwrtSetOverviewMenuOpen'),
  extractFunction('gwrtSetupMenuCardLinks')
].join('\n');

(async () => {
  const browser = await chromium.launch({headless:true, executablePath:process.env.GWRT_CHROME || '/usr/bin/google-chrome', args:['--no-sandbox']});
  try {
    const page = await browser.newPage({viewport:{width:1024,height:768}});
    await page.setContent(`
      <div id="gwrtSecOverviewHead" aria-expanded="false"></div>
      <div id="gwrtHomeMenus" hidden>
        <section id="overview-panel"></section><section id="service-panel" hidden></section>
        <section id="net-panel" hidden></section><section id="store-panel" hidden></section>
        <nav id="gwrtHomeMenuTabs">
          <button data-gwrt-menu="overview" aria-controls="overview-panel"></button>
          <button data-gwrt-menu="service" aria-controls="service-panel"></button>
          <button data-gwrt-menu="net" aria-controls="net-panel"></button>
          <button data-gwrt-menu="store" aria-controls="store-panel"></button>
        </nav>
      </div>
      <div class="dashboard-grid">
        <div id="device-card" data-gwrt-menu-target="net" tabindex="0"><span>Devices</span></div>
        <div id="storage-card" data-gwrt-menu-target="store" tabindex="0"><span>Storage</span></div>
        <div id="cpu-card" data-gwrt-menu-target="overview" tabindex="0"><button id="coremark" class="gwrt-coremark-run">Run</button></div>
        <div id="service-card" data-gwrt-menu-target="service" tabindex="0"><a id="existing-link" href="#">Existing action</a></div>
      </div>`);
    await page.evaluate(() => {
      window.scrollCount=0;
      document.getElementById('gwrtHomeMenus').scrollIntoView=()=>window.scrollCount++;
    });
    await page.addScriptTag({content:script});
    await page.evaluate(() => gwrtSetupMenuCardLinks());
    await page.locator('#device-card span').click();
    assert.equal(await page.locator('#gwrtHomeMenus').evaluate(el => el.hidden), false, 'a click on card content opens its menu');
    assert.equal(await page.locator('[data-gwrt-menu="net"]').getAttribute('aria-selected'), 'true');
    assert.equal(await page.locator('#net-panel').evaluate(el => el.hidden), false);
    await page.evaluate(() => gwrtSelectHomeMenu('net'));
    await page.locator('#coremark').click();
    assert.equal(await page.locator('[data-gwrt-menu="net"]').getAttribute('aria-selected'), 'true', 'nested controls keep their existing action');
    await page.locator('#storage-card').focus();
    await page.keyboard.press('Enter');
    assert.equal(await page.locator('[data-gwrt-menu="store"]').getAttribute('aria-selected'), 'true', 'keyboard activation opens the matching menu');
    await page.locator('#existing-link').click();
    assert.equal(await page.locator('[data-gwrt-menu="store"]').getAttribute('aria-selected'), 'true', 'links keep their existing action');
    assert.equal(await page.evaluate(() => scrollCount), 2, 'menu opening brings the selected menu into view');
    console.log('PASS dashboard card menu shortcuts, keyboard access and nested control preservation');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exit(1); });
