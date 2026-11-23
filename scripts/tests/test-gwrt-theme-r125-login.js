const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const themes = [
  path.join(root, 'package/gwrt-theme/luci-theme-gwrt'),
  path.join(root, 'gwrt-theme-V3/theme/luci-theme-gwrt'),
];
const read = (theme, relative) => fs.readFileSync(path.join(theme, relative), 'utf8');

function submitAction(script, location, clickedTarget) {
  let handler;
  let action = '/cgi-bin/luci/admin/status/overview?view=compact';
  const form = {
    addEventListener(name, callback) { if (name === 'submit') handler = callback; },
    getAttribute(name) { return name === 'action' ? action : null; },
    setAttribute(name, value) { if (name === 'action') action = value; },
  };
  const context = {
    URL,
    window: { location },
    document: {
      getElementById(id) { return id === 'gwrtLoginForm' ? form : null; },
      getElementsByName(name) { return name === 'luci_password' ? [{ focus() {} }] : []; },
    },
  };
  vm.runInNewContext(script, context);
  assert.equal(typeof handler, 'function', 'login form registers a submit handler');
  handler({
    submitter: clickedTarget ? { getAttribute(name) { return name === 'data-login-target' ? clickedTarget : null; } } : null,
  });
  return new URL(action, location.href).href;
}

for (const theme of themes) {
  const sysauth = read(theme, 'root/usr/share/ucode/luci/template/themes/gwrt/sysauth.ut');
  const css = read(theme, 'htdocs/luci-static/gwrt/css/cascade.css');
  const header = read(theme, 'root/usr/share/ucode/luci/template/themes/gwrt/header.ut');
  const headerLogin = read(theme, 'root/usr/share/ucode/luci/template/themes/gwrt/header_login.ut');
  const makefile = read(theme, 'Makefile');

  const release = Number(makefile.match(/^PKG_RELEASE:=(\d+)$/m)?.[1]);
  assert(release >= 125);
  for (const template of [header, headerLogin])
    assert.match(template, new RegExp('cascade\\.css\\?v=\\d{8}r' + release + '"'));
  assert.match(sysauth, /<form id="gwrtLoginForm" method="post" action="\{\{ http\.getenv\('REQUEST_URI'\) \}\}">/);
  assert.match(sysauth, /data-login-target="gwrt">GWRT<\/button>/);
  assert.match(sysauth, /data-login-target="native">原生<\/button>/);
  assert.doesNotMatch(sysauth, /<input[^>]+type="submit"/i, 'the separate generic login button is removed');
  assert.match(css, /\.gwrt-login-actions\{display:grid;grid-template-columns:repeat\(2,minmax\(0,1fr\)\)/);
  assert.match(css, /\.gwrt-login-choice\{[^}]*min-height:48px/);

  const match = sysauth.match(/<script type="text\/javascript">\/\/<!\[CDATA\[([\s\S]*?)\/\/\]\]><\/script>/);
  assert(match, 'login submit behavior is present in the rendered theme template');
  const script = match[1];
  assert.match(script, /event\.submitter/);
  assert.match(script, /target\.port = secure \? '444' : '81'/);

  const http = { href: 'http://192.0.2.1/cgi-bin/luci/admin/status/overview?view=compact', protocol: 'http:', port: '' };
  assert.equal(
    submitAction(script, http, 'gwrt'),
    'http://192.0.2.1/cgi-bin/luci/admin/status/overview?view=compact',
    'GWRT submits to the original URL and reaches the requested page directly',
  );
  assert.equal(
    submitAction(script, http, 'native'),
    'http://192.0.2.1:81/cgi-bin/luci/admin/status/overview?view=compact',
    'native submits the same form directly to the native HTTP port',
  );
  const https = { href: 'https://router.example/cgi-bin/luci/admin/status/overview', protocol: 'https:', port: '' };
  assert.equal(
    submitAction(script, https, 'native'),
    'https://router.example:444/cgi-bin/luci/admin/status/overview?view=compact',
    'native submits directly to the native HTTPS port',
  );
  assert.equal(
    submitAction(script, http, null),
    'http://192.0.2.1/cgi-bin/luci/admin/status/overview?view=compact',
    'keyboard submit without an explicit button retains the GWRT destination',
  );
}

console.log('PASS GWRT r125 login: direct GWRT/native form actions, HTTP/HTTPS mapping, keyboard submit, responsive choices, dual source copies');
