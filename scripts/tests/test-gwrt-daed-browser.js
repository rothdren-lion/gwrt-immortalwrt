const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { chromium } = require('playwright');

const binary = process.env.DAED_TEST_BINARY;
if (!binary) throw new Error('Set DAED_TEST_BINARY to the verified official daed v2.1.1 binary');

(async () => {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'gwrt-daed-test-'));
  const daemon = spawn(binary, ['run', '--api-only', '--listen', '127.0.0.1:19240', '--config', work], { stdio: 'ignore' });
  let browser, server;
  try {
    let ready = false;
    for (let n = 0; n < 100; n++) {
      try {
        await fetch('http://127.0.0.1:19240/graphql');
        ready = true;
        break;
      } catch (_) {
        await new Promise(resolve => setTimeout(resolve, 100));
      }
    }
    assert(ready, 'isolated official DAED API starts');
    const username = 'gwrt-browser-test';
    const password = 'Isolated123-' + Math.random().toString(36).slice(2);
    const created = await fetch('http://127.0.0.1:19240/graphql', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: 'mutation Create($username:String!,$password:String!){createUser(username:$username,password:$password)}', variables: { username, password } })
    }).then(r => r.json());
    assert(!created.errors, JSON.stringify(created));

    let source = fs.readFileSync(path.resolve(__dirname, '../../gwrt-overlays/feeds/luci/applications/luci-app-daed/htdocs/luci-static/resources/view/daed/config.js'), 'utf8');
    source = source.replace('return view.extend({', 'return {createTrafficPanel,startTrafficPolling,getServiceStatus,formatTrafficValue};\nreturn view.extend({');
    server = http.createServer((req, res) => {
      res.setHeader('Content-Type', 'text/html');
      res.end('<!doctype html><meta charset="utf-8"><style>body{margin:12px;font:14px sans-serif}input{box-sizing:border-box}canvas{max-width:100%}</style><div id="main"></div>');
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME_BIN || '/usr/bin/google-chrome', args: ['--no-sandbox'] });
    const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.goto('http://127.0.0.1:' + server.address().port);
    await page.evaluate(script => {
      window._ = text => text;
      window.E = (tag, attrs, children) => {
        const node = document.createElement(tag);
        Object.entries(attrs || {}).forEach(([key, value]) => node.setAttribute(key, value));
        const add = child => {
          if (Array.isArray(child)) child.forEach(add);
          else if (child != null) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
        };
        add(children);
        return node;
      };
      String.prototype.format = function(...args) { let i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); };
      window.polls = [];
      const rpc = { declare: () => () => Promise.resolve({daed:{instances:{custom_name:{running:true}}}}) };
      const L = { resolveDefault: (promise, fallback) => Promise.resolve(promise).catch(() => fallback) };
      window.daedTest = new Function('rpc', 'L', 'poll', '_', 'E', script)(rpc, L, {add: (fn, interval) => window.polls.push({fn, interval})}, window._, window.E);
      document.getElementById('main').append(window.daedTest.createTrafficPanel(19240));
      window.daedTest.startTrafficPolling(19240);
    }, source);
    assert(await page.evaluate(() => window.daedTest.getServiceStatus()), 'any running procd instance is recognized');
    await page.getByLabel('DAED username', { exact: true }).fill(username);
    await page.getByLabel('DAED password', { exact: true }).fill(password);
    await page.getByRole('button', { name: 'Connect', exact: true }).click();
    try {
      await page.locator('#daed_traffic_metrics strong').first().waitFor({ timeout: 10000 });
    } catch (error) {
      throw new Error((await page.locator('#daed_traffic_status').innerText()) + '; page errors: ' + JSON.stringify(errors), { cause: error });
    }
    assert.equal(await page.locator('#daed_traffic_metrics strong').count(), 6);
    assert.equal(await page.getByLabel('DAED password', { exact: true }).inputValue(), '');
    assert.equal(await page.evaluate(() => localStorage.length + sessionStorage.length), 0, 'credentials and tokens are not persisted');
    assert.equal(await page.evaluate(() => window.polls[0].interval), 5);
    await page.evaluate(() => window.polls[0].fn());
    assert.match(await page.locator('#daed_traffic_status').innerText(), /^Updated /);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 390);
    assert.deepEqual(errors, []);
    console.log('ok: real DAED login/CORS/GraphQL, six traffic values, 5-second polling, custom instance, mobile layout and ephemeral credentials');
  } finally {
    if (browser) await browser.close();
    if (server) await new Promise(resolve => server.close(resolve));
    daemon.kill('SIGTERM');
    await new Promise(resolve => daemon.once('exit', resolve));
    fs.rmSync(work, { recursive: true, force: true });
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
