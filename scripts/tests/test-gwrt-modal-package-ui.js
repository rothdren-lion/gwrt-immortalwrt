const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const {chromium}=require(process.env.GWRT_PLAYWRIGHT||'/home/godsun/node_modules/playwright');
const root=path.resolve(__dirname,'../..');
const theme=process.env.GWRT_TEST_THEME||path.join(root,'gwrt-theme-V3/theme/luci-theme-gwrt');
const css=fs.readFileSync(path.join(theme,'htdocs/luci-static/gwrt/css/cascade.css'),'utf8');
const template=fs.readFileSync(path.join(theme,'root/usr/share/ucode/luci/template/admin_status/index_gwrt.ut'),'utf8');
const modal=template.slice(template.indexOf('var gwrtModalEl=null;'),template.indexOf("var gwrtHomeMenuActive='overview';"));
const controls=fs.readFileSync(path.join(__dirname,'fixtures/gwrt-package-controls.html'),'utf8');
// The page injects these styles after the theme, as LuCI does on the router.
const packageCss='.controls{display:flex;margin:.5em 0 1em;flex-wrap:wrap;justify-content:space-around}.controls>*{padding:.25em;white-space:nowrap;flex:1 1 33%;box-sizing:border-box;display:flex;flex-wrap:wrap}.controls>*:first-child,.controls>*>label{flex-basis:100%;min-width:250px}.controls>*:nth-child(2),.controls>*:nth-child(3){flex-basis:20%}.controls>*>*{flex-grow:1;align-self:center}';
const fixture=`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>${css}</style><style>${packageCss}</style><body data-page="admin-system-package-manager"><div class="main"><aside id="mainmenu" class="main-left">menu</aside><div class="main-right"><div id="maincontent"><div class="container"><h2>软件包</h2>${controls}<div style="height:800px">Content</div><div class="cbi-page-actions"><button class="cbi-button cbi-button-save">保存</button><button class="cbi-button cbi-button-apply">保存并应用</button><button class="cbi-button cbi-button-reset">重置</button></div></div></div></div></div><script>window.actionCounts={clear:0,reset:0,apply:0};document.querySelector('.control-group button').onclick=()=>{document.querySelector('[name=filter]').value='';actionCounts.clear++};document.querySelector('.cbi-button-reset').onclick=()=>actionCounts.reset++;document.querySelector('.cbi-button-apply').onclick=()=>actionCounts.apply++;</script>`;
(async()=>{
 const server=http.createServer((req,res)=>{res.setHeader('Content-Type','text/html; charset=utf-8');res.end(req.url.startsWith('/inner')?fixture:`<!doctype html><style>${css}</style><body></body>`)});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const base='http://127.0.0.1:'+server.address().port;
 const browser=await chromium.launch({headless:true,executablePath:process.env.GWRT_CHROME||'/usr/bin/google-chrome',args:['--no-sandbox']});
 try{
  const page=await browser.newPage();
  for(const [width,height] of [[1440,900],[1280,600],[768,540],[390,640],[844,390],[320,480]]){
   await page.setViewportSize({width,height});
   await page.goto(base);
   await page.addScriptTag({content:modal});
   await page.evaluate(()=>gwrtOpenModal('/inner','软件包'));
   await page.waitForSelector('.gwrt-modal-body:not([aria-busy]) iframe');
   const frame=page.frames().find(f=>f.url().includes('/inner'));
   await frame.waitForSelector('body.gwrt-embedded');
   const layout=await frame.evaluate(()=>{
    const box=e=>{const r=e.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width}};
    return {windowWidth:innerWidth,pageWidth:document.documentElement.scrollWidth,main:box(document.querySelector('.main-right')),
     groups:[...document.querySelectorAll('.control-group')].map(e=>({box:box(e),scroll:e.scrollWidth,client:e.clientWidth,items:[...e.children].map(box)}))};
   });
   assert(layout.pageWidth<=layout.windowWidth+1,`${width}x${height}: frame has no horizontal overflow`);
   assert(layout.main.left<1,`${width}: removed sidebar leaves no blank margin`);
   assert(layout.main.width>layout.windowWidth*.95,`${width}: iframe uses available width`);
   for(const group of layout.groups){
    assert(group.scroll<=group.client+1,`${width}: controls fit in their group`);
    for(const item of group.items)assert(item.right<=group.box.right+1,`${width}: controls stay inside their group`);
    for(let i=0;i<group.items.length;i++)for(let j=i+1;j<group.items.length;j++){
     const a=group.items[i],b=group.items[j];
     assert(a.right<=b.left+1||b.right<=a.left+1||a.bottom<=b.top+1||b.bottom<=a.top+1,`${width}: buttons do not cover fields`);
    }
   }
   await frame.locator('[name=filter]').fill('luci');
   await frame.locator('.control-group button').first().click();
   assert.equal(await frame.locator('[name=filter]').inputValue(),'','clear button remains clickable');
   const nativeApply=frame.locator('.cbi-button-apply');
   await nativeApply.scrollIntoViewIfNeeded();
   await nativeApply.click();
   assert.equal(await frame.evaluate(()=>actionCounts.apply),1,'native footer actions remain visible and clickable');
   await page.locator('.gwrt-modal-reset').click();
   assert.equal(await frame.evaluate(()=>actionCounts.reset),1,'parent reset action still reaches the frame');
   const box=await page.locator('.gwrt-modal-box').boundingBox();
   assert(box.x>=0&&box.y>=0&&box.x+box.width<=width+1&&box.y+box.height<=height+1,'window controls fit in short viewports');
   await page.locator('.gwrt-modal-close').click();
   console.log(`PASS package inputs, compact modal and action buttons ${width}x${height}`);
  }
 }finally{await browser.close();await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exit(1)});
