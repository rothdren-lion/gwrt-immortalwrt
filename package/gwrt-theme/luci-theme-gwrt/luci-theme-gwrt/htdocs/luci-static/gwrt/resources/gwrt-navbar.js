(function () {
  'use strict';

  function onReady(fn) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fn);
    else fn();
  }

  onReady(function () {
    var body = document.body;
    var monitor = document.getElementById('gwrtNavbarMonitor');
    if (!body || !monitor || body.classList.contains('gwrt-embedded') || !body.classList.contains('logged-in')) return;

    var POLL_MS = 15000;
    var busy = false;
    var stopped = false;
    var timer = null;

    function byId(id) { return document.getElementById(id); }

    function setItem(id, text, state, title) {
      var item = byId(id);
      if (!item) return;
      item.setAttribute('data-state', state || 'unknown');
      if (title) item.title = title;
      var value = byId(id + 'Text');
      if (value) value.textContent = text;
    }

    function rpc(object, method, params, timeoutMs) {
      if (typeof window.fetch !== 'function') return Promise.reject(new Error('fetch unavailable'));
      var sid = (window.L && L.env && L.env.sessionid) ? L.env.sessionid : '';
      var controller = (typeof window.AbortController === 'function') ? new AbortController() : null;
      var request = window.fetch('/ubus', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        cache: 'no-store',
        signal: controller ? controller.signal : undefined,
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: Date.now(),
          method: 'call',
          params: [sid, object, method, params || {}]
        })
      }).then(function (response) {
        if (!response.ok) throw new Error('HTTP ' + response.status);
        return response.json();
      }).then(function (json) {
        if (!json || !json.result || json.result[0] !== 0) throw new Error('RPC failed');
        return json.result[1] || {};
      });
      var timeout = new Promise(function (_, reject) {
        window.setTimeout(function () {
          if (controller) controller.abort();
          reject(new Error('RPC timeout'));
        }, timeoutMs || 6000);
      });
      return Promise.race([request, timeout]);
    }

    function parseExec(result) {
      var raw = result && result.stdout;
      if (typeof raw !== 'string' || !raw.trim()) throw new Error('empty helper output');
      return JSON.parse(raw);
    }

    function normalizeMac(value) {
      var mac = String(value || '').trim().toLowerCase().replace(/-/g, ':');
      return /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/.test(mac) ? mac : '';
    }

    function readDevices() {
      return rpc('file', 'exec', { command: '/usr/libexec/gwrt-clients-dump', params: [] }, 6000).then(parseExec);
    }

    function trackerInfo(info) {
      var updated = Number(info && info.updated) || 0;
      if (updated > 1000000000000) updated /= 1000;
      var fresh = updated > 0 && Math.abs(Date.now() / 1000 - updated) <= 90;
      var seen = {};
      var count = 0;
      (info && Array.isArray(info.clients) ? info.clients : []).forEach(function (client) {
        var mac = normalizeMac(client && client.mac);
        if (!mac) return;
        /* A tracker can retain both a stale lease and a fresh association for
         * one MAC.  Count it once, but let any online record win. */
        if (!seen[mac]) seen[mac] = false;
        if (client && client.online === true) seen[mac] = true;
      });
      Object.keys(seen).forEach(function (mac) { if (seen[mac]) count++; });
      return { fresh: fresh, count: count, updated: updated };
    }

    function processText(value) {
      var n = Number(value);
      return isFinite(n) ? (Math.round(n * 10) / 10).toFixed(n % 1 ? 1 : 0) + '%' : '';
    }

    function renderDevices(result) {
      var item = byId('gwrtNavbarDevices');
      if (!item) return;
      if (!result.ok) {
        setItem('gwrtNavbarDevices', '—', 'unknown', '真实在线设备数暂时不可用');
        return;
      }
      var tracker = trackerInfo(result.data);
      if (!tracker.fresh) {
        setItem('gwrtNavbarDevices', '—', 'warn', '真实在线设备数据已过期，等待客户端跟踪器更新');
        return;
      }
      setItem('gwrtNavbarDevices', String(tracker.count), 'ok', '真实在线设备：' + tracker.count + '（按去重 MAC 统计，数据新鲜）');
    }

    var uptimeBase = null;
    function renderUptime() {
      if (!uptimeBase) return;
      var seconds = Math.max(0, Math.floor(uptimeBase.seconds + (Date.now() - uptimeBase.at) / 1000));
      var days = Math.floor(seconds / 86400), hours = Math.floor(seconds % 86400 / 3600), minutes = Math.floor(seconds % 3600 / 60);
      setItem('gwrtNavbarUptime', (days ? days + '天 ' : '') + hours + '时' + minutes + '分', 'ok', '路由 uptime：' + seconds + ' 秒');
    }
    window.setInterval(renderUptime, 1000);

    function renderStatus(result) {
      if (!result.ok) {
        setItem('gwrtNavbarHealth', '未知', 'unknown', '路由状态探针暂时不可用');
        setItem('gwrtNavbarDns', '未知', 'unknown', 'DNS 状态暂时不可用');
        setItem('gwrtNavbarExternal', '未知', 'unknown', '对外网络状态暂时不可用');
        setItem('gwrtNavbarProcesses', '—', 'unknown', '进程状态暂时不可用');
        var missing = byId('gwrtNavbarTopProcess');
        if (missing) missing.textContent = '';
        return;
      }
      var data = result.data || {};
      if (data.uptime !== null && isFinite(Number(data.uptime))) { uptimeBase = { seconds: Number(data.uptime), at: Date.now() }; renderUptime(); }
      var dns = data.dns || {};
      var external = data.external || {};
      var dnsOk = typeof dns.ok === 'boolean' ? dns.ok : null;
      var externalOk = typeof external.ok === 'boolean' ? external.ok : null;
      setItem('gwrtNavbarDns', dnsOk === true ? '正常' : (dnsOk === false ? '故障' : '未知'), dnsOk === true ? 'ok' : (dnsOk === false ? 'bad' : 'unknown'), dnsOk === true ? '本机 DNS 查询正常' : (dnsOk === false ? '本机 DNS 查询失败' : '本机 DNS 状态未知'));
      setItem('gwrtNavbarExternal', externalOk === true ? '通' : (externalOk === false ? '断' : '未知'), externalOk === true ? 'ok' : (externalOk === false ? 'bad' : 'unknown'), externalOk === true ? '对外网络可达（' + String(external.method || '探针') + '）' : (externalOk === false ? '对外网络探测失败' : '对外网络状态未知'));

      var processes = Number(data.process_count);
      var top = Array.isArray(data.top_processes) && data.top_processes.length ? data.top_processes[0] : null;
      var topCpu = top ? Number(top.cpu) : NaN;
      var topName = top && top.name ? String(top.name) : '';
      var processState = isFinite(processes) ? (isFinite(topCpu) && topCpu >= 80 ? 'warn' : 'ok') : 'unknown';
      var processValue = isFinite(processes) ? String(Math.max(0, Math.round(processes))) : '—';
      var load = Number(data.load1);
      var processTitle = isFinite(load) ? '进程数：' + processValue + '，系统 1 分钟负载：' + load : '进程数：' + processValue;
      if (isFinite(topCpu) && topName) processTitle += '；最高 CPU：' + topName + ' ' + processText(topCpu);
      setItem('gwrtNavbarProcesses', processValue, processState, processTitle);
      var detail = byId('gwrtNavbarTopProcess');
      if (detail) detail.textContent = isFinite(topCpu) && topName ? topName + ' ' + processText(topCpu) : '';

      var healthState = 'unknown';
      var healthText = '未知';
      if (dnsOk === false && externalOk === false) { healthState = 'bad'; healthText = '异常'; }
      else if (dnsOk === false || externalOk === false || (isFinite(topCpu) && topCpu >= 80)) { healthState = 'warn'; healthText = '注意'; }
      else if (dnsOk === true && externalOk === true) { healthState = 'ok'; healthText = '正常'; }
      setItem('gwrtNavbarHealth', healthText, healthState, '路由综合状态：' + healthText + (isFinite(topCpu) && topCpu >= 80 ? '；存在高 CPU 进程' : ''));
    }

    function trafficBytes(n) {
      n=Number(n)||0;
      var units=['B','KB','MB','GB','TB','PB'],i=0;
      while(n>=1024&&i<units.length-1){n/=1024;i++;}
      return (i?n.toFixed(n>=100?0:1):Math.round(n))+' '+units[i];
    }
    function renderTraffic(data) {
      if(!data || !data.families || !isFinite(Number(data.total))) return;
      var el=byId('gwrtWanPeriods');if(!el)return;
      el.innerHTML='';
      var periods=Array.isArray(data.periods)?data.periods:[];
      var entries=[];
      ['today','week','month','year'].forEach(function(key){
        var p=periods.find(function(p){return p.key===key;});
        if(p)entries.push(p);
      });
      entries.push({key:'total',label:'总量',total:Number(data.total)});
      entries.forEach(function(p){
        var bytes=p.bytes||{},total=p.total;
        if(total===undefined){total=0;['up4','down4','up6','down6'].forEach(function(k){total+=Number(bytes[k])||0;});}
        var item=document.createElement('span'),label=document.createElement('span'),value=document.createElement('b');
        item.className='gwrt-navbar-period';
        label.className='gwrt-navbar-period-label';
        label.textContent=p.label;
        value.textContent=trafficBytes(total);item.appendChild(label);item.appendChild(value);
        item.title=p.label+'流量（IPv4 + IPv6）'+(p.bytes?'：IPv4 '+trafficBytes((Number(bytes.up4)||0)+(Number(bytes.down4)||0))+'，IPv6 '+trafficBytes((Number(bytes.up6)||0)+(Number(bytes.down6)||0)):'')+'；每半小时保存累计用量';
        if(!data.ok)item.title+='；当前显示最近记录';
        el.appendChild(item);
      });
    }
    window.gwrtRenderTrafficPeriods=renderTraffic;
    try{renderTraffic(JSON.parse(localStorage.getItem('gwrt_wan_traffic_v2')||'null'));}catch(e){}

    function poll() {
      if (stopped || busy || document.hidden) return;
      busy = true;
      var statusResult = rpc('file', 'exec', { command: '/usr/libexec/gwrt-navbar-status', params: [] }, 9000).then(function (data) {
        return { ok: true, data: parseExec(data) };
      }).catch(function () { return { ok: false }; });
      var devicesResult = readDevices().then(function (data) {
        return { ok: true, data: data };
      }).catch(function () { return { ok: false }; });
      var trafficResult=rpc('file','exec',{command:'/usr/libexec/gwrt-traffic-daily',params:['read']},6000).then(function(data){
        return parseExec(data);
      }).catch(function(){return null;});
      Promise.all([statusResult, devicesResult, trafficResult]).then(function (results) {
        renderStatus(results[0]);
        renderDevices(results[1]);
        renderTraffic(results[2]);
      }).then(function () {
        busy = false;
        if (!stopped && !document.hidden) timer = window.setTimeout(poll, POLL_MS);
      }, function () {
        busy = false;
        if (!stopped && !document.hidden) timer = window.setTimeout(poll, POLL_MS);
      });
    }

    document.addEventListener('visibilitychange', function () {
      if (document.hidden) {
        if (timer) { window.clearTimeout(timer); timer = null; }
      } else {
        if (!busy) poll();
      }
    });
    window.addEventListener('pagehide', function () {
      stopped = true;
      if (timer) window.clearTimeout(timer);
    });
    poll();
  });
}());
