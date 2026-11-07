(() => {
  const state = { csrf: '', user: null, isAdmin: false, devices: [], selected: '', claimTokens: {}, localTokens: {}, localTokenRequests: {}, notificationsEnabled: true, deviceStatusReady: false, market: [], marketError: '', marketOpen: false, appsOpen: false, installedOpen: false, timer: null, discovering: false, terminalCommandId: '', packageSearchCommandId: '', editorSubmit: null, appUpdate: null, weather: null, weatherLoaded: false, devicesCollapsed: false, view: 'overview', dtab: 'system', clientLabels: {} };
  const SAFE_APPLY_KINDS = new Set(['wifi.set', 'wifi.radio.set', 'network.lan.set', 'network.firewall.set']);
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

  function setTheme(theme, persist = true) {
    const next = theme === 'light' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    document.documentElement.style.colorScheme = next;
    if (persist) {
      try { localStorage.setItem('gwrt-theme', next); } catch (_) {}
    }
    const toggle = $('#theme-toggle'), label = $('#theme-toggle-label');
    const target = next === 'dark' ? '浅色模式' : '深色模式';
    if (label) label.textContent = target;
    if (toggle) {
      toggle.setAttribute('aria-pressed', String(next === 'light'));
      toggle.setAttribute('aria-label', `切换为${target}`);
    }
  }

  function initTheme() {
    let saved = 'dark';
    try { saved = localStorage.getItem('gwrt-theme') || saved; } catch (_) {}
    setTheme(saved, false);
  }

  initTheme();

  function showToast(message, type = 'success') {
    const toast = $('#toast');
    toast.textContent = message;
    toast.className = `toast show ${type}`;
    toast.classList.add('show');
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => toast.classList.remove('show'), 2600);
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>'"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]));
  }

  function formatBytes(value) {
    const number = Number(value || 0);
    if (!Number.isFinite(number)) return '-';
    if (number < 1024) return `${number.toFixed(0)} B`;
    if (number < 1024 * 1024) return `${(number / 1024).toFixed(1)} KiB`;
    if (number < 1024 * 1024 * 1024) return `${(number / 1024 / 1024).toFixed(1)} MiB`;
    return `${(number / 1024 / 1024 / 1024).toFixed(1)} GiB`;
  }

  function formatRate(value) { return `${formatBytes(value || 0)}/s`; }

  function formatTemperature(value) {
    const number = Number(value);
    return Number.isFinite(number) ? `${number.toFixed(1)} °C` : '-';
  }

  function formatAge(timestamp) {
    const seconds = Math.max(0, Math.floor(Date.now() / 1000 - Number(timestamp || 0)));
    if (!timestamp || !Number.isFinite(seconds)) return '等待上报';
    if (seconds < 10) return '刚刚';
    if (seconds < 60) return `${seconds} 秒前`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
    return `${Math.floor(seconds / 3600)} 小时前`;
  }

  async function api(path, options = {}) {
    const headers = { Accept: 'application/json', ...(options.headers || {}) };
    if (options.body && !headers['Content-Type']) headers['Content-Type'] = 'application/json';
    if (options.method && options.method !== 'GET' && state.csrf) headers['X-GWRT-CSRF'] = state.csrf;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch(path, { ...options, headers, signal: options.signal || controller.signal });
      const data = await response.json().catch(() => ({ ok: false, error: '服务器返回无效数据' }));
      if (!response.ok) throw new Error(data.error || `请求失败 (${response.status})`);
      return data;
    } finally { clearTimeout(timeout); }
  }

  async function refreshCaptcha() {
    try {
      const data = await api('/api/auth/captcha');
      if (!data?.ok || !data.svg) return;
      const login = $('#login-captcha'), register = $('#register-captcha');
      if (login) login.innerHTML = data.svg;
      if (register) register.innerHTML = data.svg;
      const loginId = $('#login-form [name="captcha_id"]'), registerId = $('#register-form [name="captcha_id"]');
      if (loginId) loginId.value = data.id;
      if (registerId) registerId.value = data.id;
      const loginInput = $('#login-form [name="captcha"]'), registerInput = $('#register-form [name="captcha"]');
      if (loginInput) loginInput.value = '';
      if (registerInput) registerInput.value = '';
    } catch (_) { /* 验证码失败时登录仍可尝试（服务端会校验） */ }
  }

  function setAuthMode(mode) {
    const register = mode === 'register';
    $$('.auth-form').forEach(form => {
      const active = form.dataset.authForm === mode;
      form.hidden = !active;
      form.classList.toggle('is-active', active);
    });
    $('#auth-title').textContent = register ? '创建你的空间' : '欢迎回来';
    $('#auth-description').textContent = register ? '注册后绑定并管理属于你的 GWRT 路由器。' : '登录后进入你的设备工作台。';
    $$('.auth-tab').forEach(tab => {
      const active = tab.dataset.authMode === mode;
      tab.classList.toggle('active', active);
      tab.setAttribute('aria-selected', String(active));
    });
    $('#auth-error').textContent = '';
    refreshCaptcha();
  }

  function setLoggedIn(user) {
    state.user = user || null;
    state.isAdmin = Boolean(user && user.is_admin);
    document.body.classList.toggle('authenticated', Boolean(user));
    $('#login-view').hidden = Boolean(user);
    $('#dashboard-view').hidden = !user;
    $('#profile-button').hidden = !user;
    $('#profile-name').textContent = user ? user.username : '账户';
    $('#profile-menu-name').textContent = user ? user.username : '-';
    $('#user-avatar').textContent = user ? String(user.username || 'G').slice(0, 1).toUpperCase() : 'G';
    $('#connection-label').textContent = user ? '服务已连接' : '未连接';
    $('.status-dot').classList.toggle('connected', Boolean(user));
    if (!user) {
      state.deviceStatusReady = false;
      state.localTokens = {};
      state.claimTokens = {};
      state.localTokenRequests = {};
    }
    if (user) { window.scrollTo(0, 0); closeProfileMenu(); }
  }

  function closeProfileMenu() {
    const menu = $('#profile-menu'), button = $('#profile-button');
    if (!menu || !button) return;
    menu.hidden = true;
    button.setAttribute('aria-expanded', 'false');
  }

  function toggleProfileMenu() {
    const menu = $('#profile-menu'), button = $('#profile-button');
    if (!menu || !button || button.hidden) return;
    menu.hidden = !menu.hidden;
    button.setAttribute('aria-expanded', String(!menu.hidden));
  }

  function nativeBridge() {
    return window.GWRTNative && (typeof window.GWRTNative.discoverLocalRouter === 'function' || typeof window.GWRTNative.scanPairCode === 'function') ? window.GWRTNative : null;
  }

  function setPairStatus(message, error = false) {
    $('#pair-status').textContent = message;
    $('#pair-status').classList.toggle('error', error);
  }

  function parsePairPayload(value) {
    if (value && typeof value === 'object') {
      if (!value.device_id || (!value.claim_token && !value.pair_token)) throw new Error('绑定信息不完整');
      return value;
    }
    const text = String(value || '').trim();
    if (!text) throw new Error('没有读取到绑定信息');
    try { return parsePairPayload(JSON.parse(text)); } catch (_) {}
    let url;
    try { url = new URL(text); } catch (_) { throw new Error('二维码不是 GWRT 绑定码'); }
    if (url.protocol !== 'gwrt:' || url.hostname !== 'bind') throw new Error('二维码不是 GWRT 绑定码');
    const device_id = url.searchParams.get('device_id') || '';
    const claim_token = url.searchParams.get('claim_token') || '';
    const pair_token = url.searchParams.get('pair_token') || '';
    if (!device_id || (!claim_token && !pair_token)) throw new Error('二维码缺少一次性绑定凭证');
    return { device_id, claim_token, pair_token };
  }

  function startRefreshTimer() {
    clearInterval(state.timer);
    state.timer = setInterval(() => {
      if (!document.hidden && state.user) refreshDevices().catch(() => {});
    }, 5000);
  }

  function refreshDevices() {
    if (!state.refreshRequest) {
      state.refreshRequest = fetchDevices().finally(() => { state.refreshRequest = null; });
    }
    return state.refreshRequest;
  }

  async function fetchDevices() {
    const data = await api('/api/devices');
    const previous = state.selected;
    const previousStatuses = new Map(state.devices.map(device => [device.device_id, Boolean(device.online)]));
    state.devices = data.devices || [];
    if (!state.devices.some(device => device.device_id === state.selected)) state.selected = state.devices[0]?.device_id || '';
    if (previous !== state.selected) { state.market = []; state.marketError = ''; state.marketOpen = false; state.appsOpen = false; state.installedOpen = false; }
    if (state.deviceStatusReady) {
      const changes = state.devices.filter(device => previousStatuses.has(device.device_id) && previousStatuses.get(device.device_id) !== Boolean(device.online) && device.notify_enabled !== false);
      if (changes.length === 1) {
        const device = changes[0];
        showToast(`${deviceName(device)} 已${device.online ? '上线' : '离线'}`, device.online ? 'success' : 'warning');
        playNotifySound(device.online);
      } else if (changes.length > 1) {
        showToast(`${changes.length} 台设备状态已更新`, 'info');
        playNotifySound();
      }
    }
    state.deviceStatusReady = true;
    renderMetrics(); renderDevices(); renderFleetOverview();
    if (state.view === 'device') renderDeviceView();
  }

  async function loadSettings() {
    const data = await api('/api/settings');
    state.notificationsEnabled = data.settings?.device_notifications !== false;
    const toggle = $('#device-notification-toggle');
    if (toggle) toggle.checked = state.notificationsEnabled;
  }

  async function claimPair(value, source = '设备') {
    try {
      const pair = parsePairPayload(value);
      setPairStatus(`正在绑定 ${pair.device_id}…`);
      const result = await api('/api/devices/claim', { method: 'POST', body: JSON.stringify({
        device_id: pair.device_id, claim_token: pair.claim_token || '', pair_token: pair.pair_token || '', serial: pair.serial || '', mac: pair.mac || '', model: pair.model || '', arch: pair.arch || '', version: pair.version || '', firmware_version: pair.firmware_version || pair.version || '', agent_version: Number(pair.agent_version || 0)
      }) });
      if (pair.claim_token) state.claimTokens[pair.device_id] = pair.claim_token;
      state.selected = pair.device_id;
      await refreshDevices();
      setPairStatus(`${source}绑定成功：${pair.device_id}，正在准备本地控制…`); showToast(`${source}绑定成功`);
      if (result.local_token_command_id) ensureLocalToken(pair.device_id, result.local_token_command_id);
      return true;
    } catch (error) { setPairStatus(error.message, true); showToast(error.message, 'error'); return false; }
  }

  // 添加设备：先自动发现当前网络的路由器，发现结果必须经用户确认才绑定；扫码仍可用。
  function startManualDiscovery() {
    const bridge = nativeBridge();
    if (!bridge) { setPairStatus('自动发现和扫码仅在 Android App 中可用。', true); showToast('请使用 GWRT Control Android App', 'error'); return; }
    if (state.discovering) return;
    state.discovering = true;
    $('#bind-pair-button').disabled = true;
    setPairStatus('正在搜索当前网络的 GWRT 路由器…');
    if (typeof bridge.discoverLocalRouter === 'function') bridge.discoverLocalRouter();
    else { state.discovering = false; $('#bind-pair-button').disabled = false; bridge.scanPairCode(); }
  }

  function finishDiscovery() {
    state.discovering = false;
    $('#bind-pair-button').disabled = false;
  }

  let pendingPair = null;
  function showPairConfirm(data) {
    pendingPair = data;
    $('#pair-confirm-copy').innerHTML = `在<b>当前网络</b>发现一台 GWRT 路由器：<br><br><span class="mono">${escapeHtml(data.model || '未知型号')}</span><br><span class="mono">${escapeHtml(data.device_id)}</span>${data.mac ? `<br>MAC ${escapeHtml(data.mac)}` : ''}<br><br>确认将这台设备绑定到当前账号？`;
    $('#pair-confirm-dialog').showModal();
  }

  function renderMetrics() {
    const online = state.devices.filter(device => device.online).length;
    const clients = state.devices.reduce((sum, device) => sum + (Array.isArray(device.clients) ? device.clients.filter(client => client.online !== false).length : 0), 0);
    const containers = state.devices.reduce((sum, device) => sum + (Array.isArray(device.containers?.items) ? device.containers.items.length : 0), 0);
    $('#metric-total').textContent = state.devices.length;
    $('#metric-online').textContent = online;
    $('#metric-offline').textContent = state.devices.length - online;
    $('#metric-containers').textContent = containers;
    $('#metric-clients').textContent = clients;
  }

  /* ── 总看台：每台设备的 AP / 容器 / 终端 / 在线状态摘要 ── */
  function renderFleetOverview() {
    const box = $('#fleet-overview');
    if (!box) return;
    if (!state.devices.length) { box.innerHTML = ''; return; }
    box.innerHTML = state.devices.map(device => {
      const wifi = Array.isArray(device.telemetry?.wifi) ? device.telemetry.wifi : [];
      const aps = wifi.filter(item => item.enabled !== false).map(item => `${item.ssid || item.band || 'Wi-Fi'}${item.band ? ' · ' + item.band : ''}`);
      const containers = Array.isArray(device.containers?.items) ? device.containers.items.length : 0;
      const clients = Array.isArray(device.clients) ? device.clients.filter(c => c.online !== false).length : 0;
      const sub = [];
      if (aps.length) sub.push(`AP ${aps.join(' / ')}`);
      if (containers) sub.push(`容器 ${containers}`);
      sub.push(`终端 ${clients}`);
      return `<button class="fleet-card ${device.online ? 'online' : ''}" type="button" data-device="${escapeHtml(device.device_id)}">
        <span class="fleet-dot" aria-hidden="true"></span>
        <span class="fleet-copy"><strong>${escapeHtml(deviceName(device))}</strong><small>${escapeHtml(sub.join(' · '))}</small></span>
        <span class="fleet-status">${device.online ? 'ONLINE' : 'OFFLINE'}</span>
      </button>`;
    }).join('');
  }

  function deviceName(device) { return device.display_name || device.name || device.model || device.device_id; }

  function deviceRowHtml(device) {
    const owner = device.bound === false
      ? '<span class="device-owner-tag unbound">未绑定</span>'
      : (state.isAdmin && device.owner_username ? `<span class="device-owner-tag">${escapeHtml(device.owner_username)}</span>` : '');
    return `<button class="device-row ${state.selected === device.device_id ? 'selected' : ''} ${device.bound === false ? 'is-unbound' : ''}" type="button" data-device="${escapeHtml(device.device_id)}">
      <span class="device-state ${device.online ? 'online' : ''}" aria-hidden="true"></span>
      <span><strong>${escapeHtml(deviceName(device))}</strong><small>${escapeHtml(device.device_id)} · ${escapeHtml(device.mac || 'no-mac')}${device.region ? ' · ' + escapeHtml(device.region) : ''}</small></span>
      ${owner}
      <time>${device.online ? 'ONLINE' : 'OFFLINE'}</time>
    </button>`;
  }

  function renderDevices() {
    const listEl = $('#device-list');
    if (!listEl) return;   // 首页已改为只保留顶部 fleet 卡片
    $('#device-empty').hidden = state.devices.length !== 0;
    if (state.isAdmin) {
      // 管理员视图：服务端已按地域排序，相同地域连续 → 分组展示
      const groups = [];
      let lastRegion = null;
      for (const device of state.devices) {
        const region = device.region || '';
        if (region !== lastRegion) { groups.push({ region, devices: [] }); lastRegion = region; }
        groups[groups.length - 1].devices.push(device);
      }
      $('#device-list').innerHTML = groups.map(group => `<div class="device-region-group">
        <div class="device-region-head"><span class="device-region-pin">📍</span>${escapeHtml(group.region || '未知地域')}<b>${group.devices.length}</b></div>
        ${group.devices.map(deviceRowHtml).join('')}
      </div>`).join('');
    } else {
      $('#device-list').innerHTML = state.devices.map(deviceRowHtml).join('');
    }
  }

  async function loadWeather() {
    if (state.weatherLoaded) return;
    state.weatherLoaded = true;
    try {
      const data = await api('/api/weather');
      state.weather = data && data.ok ? data : null;
    } catch (_) { state.weather = null; }
    renderMetrics();
    if (state.view === 'device' && state.selected) {
      renderDeviceInfo(state.devices.find(item => item.device_id === state.selected));
      if (state.dtab === 'system') renderDeviceTab();
    }
  }

  /* ── 两页导航（总览 / 设备详情） ── */
  function showOverview() {
    startRefreshTimer();
    state.view = 'overview';
    $('#overview-view').hidden = false;
    $('#device-view').hidden = true;
    stopCurve();
    if (window.location.hash && window.location.hash !== '#/') history.replaceState(null, '', '#/');
    window.scrollTo(0, 0);
  }

  function showDevice(deviceId) {
    const device = state.devices.find(d => d.device_id === deviceId);
    if (!device) { showOverview(); return; }
    startRefreshTimer(5000);
    state.selected = deviceId;
    state.view = 'device';
    $('#overview-view').hidden = true;
    $('#device-view').hidden = false;
    const hash = '#/device/' + encodeURIComponent(deviceId);
    if (window.location.hash !== hash) history.pushState(null, '', hash);
    window.scrollTo(0, 0);
    renderDeviceView();
    loadOafMap().then(() => { if (state.selected === deviceId && state.dtab === 'system') renderDeviceTab(); });
    if (state.dtab === 'system') startCurve(); else stopCurve();
  }

  function currentHashDevice() {
    const m = (window.location.hash || '').match(/^#\/device\/(.+)$/);
    return m ? decodeURIComponent(m[1]) : '';
  }

  function renderDeviceView() {
    const device = state.devices.find(item => item.device_id === state.selected);
    if (!device) { showOverview(); return; }
    $('#device-view-name').textContent = deviceName(device);
    const readonly = device.can_manage === false;
    $('#device-view').classList.toggle('readonly', readonly);
    const roBadge = $('#device-readonly-badge');
    if (roBadge) {
      roBadge.hidden = !readonly;
      roBadge.textContent = device.bound === false ? '未绑定 · 仅查看' : (device.owner_username ? `其他账号 · ${device.owner_username} · 仅查看` : '仅查看');
    }
    const status = $('#device-view-status');
    status.textContent = device.online ? 'ONLINE' : 'OFFLINE';
    status.className = `online-badge ${device.online ? 'online' : ''}`;
    const index = state.devices.findIndex(d => d.device_id === device.device_id);
    const idxEl = $('#device-index');
    if (idxEl) idxEl.textContent = `${index + 1} / ${state.devices.length}`;
    renderDeviceInfo(device);
    renderDeviceTab();
  }

  function renderDeviceInfo(device) {
    const telemetry = device.telemetry || {};
    const wifi = Array.isArray(telemetry.wifi) ? telemetry.wifi : [];
    const temps = Array.isArray(telemetry.temperatures) ? telemetry.temperatures : [];
    const cpuTemp = temps.find(item => /cpu/i.test(item.name || ''));
    const env = state.weather && state.weather.ok && state.weather.temp_c != null && Number.isFinite(Number(state.weather.temp_c)) ? state.weather : null;
    const left = [
      ['SOC', telemetry.soc_model || telemetry.soc || device.model || '-'],
      ['温度', cpuTemp ? formatTemperature(cpuTemp.celsius) : '-'],
      ['型号', device.model || '-'],
      ['内核', telemetry.kernel || '-'],
      ['固件', device.firmware_version || device.version || '-'],
      ['地域', device.region || '-'],
      ['硬件标识', device.hardware_id ? escapeHtml(device.hardware_id.length > 20 ? device.hardware_id.slice(0, 20) + '…' : device.hardware_id) : '-'],
    ];
    const right = wifi.map((item, i) => [`WiFi ${i + 1}`, `${item.band || 'Wi‑Fi'} · ${item.ssid || '-'} · ch${item.channel || '-'}${item.enabled === false ? '（停用）' : ''}`]);
    right.push(['环境', env ? `${env.temp_c} °C${env.area ? ' · ' + env.area : ''}` : (state.weatherLoaded ? '不可用' : '获取中…')]);
    const notifyEnabled = device.notify_enabled !== false;
    $('#device-info-card').innerHTML = `<div class="device-info-card">
      <div class="info-left">${left.map(([k, v]) => `<div class="info-line"><span>${k}</span><b>${escapeHtml(v)}</b></div>`).join('')}</div>
      <div class="info-divider"></div>
      <div class="info-right">${right.map(([k, v]) => `<div class="info-line"><span>${k}</span><b>${escapeHtml(v)}</b></div>`).join('')}</div>
      <div class="info-footer"><span>已运行 ${escapeHtml(formatUptime(Number(telemetry.uptime || 0)))}</span><span>本地 ${escapeHtml(telemetry.local_time || '-')}</span></div>
      <div class="notify-row"><span>设备离线/上线提醒</span><input type="checkbox" data-notify-toggle ${notifyEnabled ? 'checked' : ''}></div>
    </div>`;
  }

  function renderDeviceTab() {
    const device = state.devices.find(item => item.device_id === state.selected);
    if (!device) return;
    if (state.dtab === 'system') renderDeviceSystem(device);
    else if (state.dtab === 'clients') renderClients(device);
    else if (state.dtab === 'topology') renderTopology(device);
    else if (state.dtab === 'mesh') renderMesh(device);
    else if (state.dtab === 'plugins') renderPackages(device);
    else if (state.dtab === 'terminal') renderTerminal();
    else if (state.dtab === 'settings') renderControls(device);
  }

  /* ── 设备离线/上线提示音（QQ 风格"咳2声"，Web Audio 合成） ── */
  function playNotifySound(online) {
    if (!window.AudioContext && !window.webkitAudioContext) return;
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      const ctx = state.audioCtx || (state.audioCtx = new Ctx());
      if (ctx.state === 'suspended') { ctx.resume().catch(() => {}); }
      const now = ctx.currentTime;
      const beep = (freq, start, dur, vol) => {
        const osc = ctx.createOscillator(), gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.setValueAtTime(freq, start);
        osc.frequency.exponentialRampToValueAtTime(freq * 0.82, start + dur);
        gain.gain.setValueAtTime(0.0001, start);
        gain.gain.exponentialRampToValueAtTime(vol || 0.22, start + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0001, start + dur);
        osc.connect(gain); gain.connect(ctx.destination);
        osc.start(start); osc.stop(start + dur + 0.05);
      };
      // 两声短促"咳"：离线用较低音，上线用稍高音
      if (online === false) { beep(620, now, 0.16, 0.2); beep(520, now + 0.24, 0.2, 0.2); }
      else { beep(880, now, 0.15, 0.2); beep(700, now + 0.22, 0.18, 0.2); }
    } catch (_) { /* 音频不可用时静默 */ }
  }
  // 浏览器/WebView 需要一次用户交互后才能出声：首次点击时恢复 AudioContext
  document.addEventListener('pointerdown', () => {
    const ctx = state.audioCtx;
    if (ctx && ctx.state === 'suspended') ctx.resume().catch(() => {});
  }, { once: true });

  /* ── 左右滑动切换设备 ── */
  let swipeX = 0, swipeY = 0;
  document.addEventListener('touchstart', e => {
    const t = e.touches && e.touches[0];
    if (!t || state.view !== 'device') return;
    const scroll = $('#device-scroll');
    if (scroll && scroll.scrollTop > 0) return;
    // 屏幕边缘 36px 内让给系统（Android 边缘返回/侧滑手势），不做设备切换
    if (t.clientX < 36 || t.clientX > window.innerWidth - 36) return;
    // 横向可滚动区域（拓扑图等）内部不拦截，避免误切设备
    const target = e.target && e.target.closest ? e.target.closest('.gwrt-topology, .topo-ports-bus, .device-nav, .port-strip') : null;
    if (target) return;
    swipeX = t.clientX; swipeY = t.clientY;
  }, { passive: true });
  document.addEventListener('touchend', e => {
    if (state.view !== 'device' || !swipeX) return;
    const t = e.changedTouches && e.changedTouches[0];
    if (!t) return;
    const dx = t.clientX - swipeX, dy = t.clientY - swipeY;
    swipeX = 0; swipeY = 0;
    if (Math.abs(dx) < 60 || Math.abs(dx) < Math.abs(dy) * 1.4) return;
    const list = state.devices;
    const idx = list.findIndex(d => d.device_id === state.selected);
    if (dx < 0 && idx < list.length - 1) showDevice(list[idx + 1].device_id);
    else if (dx > 0 && idx > 0) showDevice(list[idx - 1].device_id);
  }, { passive: true });

  /* ── WAN 负载 / 速率 1 分钟曲线（Canvas 轻量自绘） ── */
  const curve = { data: [], timer: null };

  function curveSample(device) {
    const t = device.telemetry || {};
    const point = {
      t: Date.now(),
      rx: Number(t.network?.wan_rx_bps || 0),
      tx: Number(t.network?.wan_tx_bps || 0),
      load: Number(String(t.load || '').split(/\s+/)[0] || 0)
    };
    // 值没变化就不重复入点，避免 3s 采样把同一份数据刷成平段
    const last = curve.data[curve.data.length - 1];
    if (!last || last.rx !== point.rx || last.tx !== point.tx || last.load !== point.load) curve.data.push(point);
    while (curve.data.length && curve.data[0].t < Date.now() - 60000) curve.data.shift();
  }

  function startCurve() {
    if (curve.timer) return;
    const device = state.devices.find(d => d.device_id === state.selected);
    if (device) curveSample(device);
    drawCurve();
    curve.timer = setInterval(() => {
      const dev = state.devices.find(d => d.device_id === state.selected);
      if (!dev) return;
      curveSample(dev);
      drawCurve();
    }, 3000);
  }

  function stopCurve() {
    if (curve.timer) { clearInterval(curve.timer); curve.timer = null; }
  }

  function formatMbps(bps) {
    const mbps = Number(bps || 0) / 1000000;
    return mbps >= 100 ? `${Math.round(mbps)}M` : `${mbps.toFixed(1)}M`;
  }

  function drawCurve() {
    const canvas = $('#curve-canvas');
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const W = canvas.clientWidth || 320, H = 150;
    canvas.width = W; canvas.height = H;
    ctx.clearRect(0, 0, W, H);
    ctx.strokeStyle = 'rgba(148,163,184,.14)'; ctx.lineWidth = 1;
    ctx.fillStyle = 'var(--muted, #94a3b8)'; ctx.font = '9px monospace';
    const leftPad = 34, rightPad = 30;
    const plotW = W - leftPad - rightPad, plotH = H - 16;
    for (let i = 0; i <= 4; i++) {
      const y = 8 + plotH * i / 4;
      ctx.beginPath(); ctx.moveTo(leftPad, y); ctx.lineTo(W - rightPad, y); ctx.stroke();
      ctx.fillText(String(4 - i), 2, y + 3);
      ctx.fillText(String(100 - i * 25), W - rightPad + 4, y + 3);
    }
    const speedPeak = Math.max(1, ...curve.data.map(p => Math.max(p.rx, p.tx) / 1000000)) * 1.2;
    const loadPeak = Math.max(0.1, ...curve.data.map(p => p.load)) * 1.3;
    const now = Date.now();
    const px = p => leftPad + (1 - (now - p.t) / 60000) * plotW;
    const pySpeed = v => 8 + plotH - (v / 1000000 / speedPeak) * plotH;
    const pyLoad = v => 8 + plotH - Math.min(1, v / loadPeak) * plotH;
    const line = (color, get) => {
      ctx.strokeStyle = color; ctx.lineWidth = 1.6; ctx.beginPath();
      let started = false;
      curve.data.forEach(p => {
        const x = px(p), y = get(p);
        if (x < leftPad) return;
        if (!started) { ctx.moveTo(x, y); started = true; } else ctx.lineTo(x, y);
      });
      ctx.stroke();
    };
    line('#3b82f6', p => pySpeed(p.rx));
    line('#10b981', p => pySpeed(p.tx));
    line('#f59e0b', p => pyLoad(p.load));
    const last = curve.data[curve.data.length - 1];
    const legend = $('#curve-legend');
    if (legend && last) {
      legend.innerHTML = `<span class="lg lg-down">下行 ${formatRate(last.rx)}</span><span class="lg lg-up">上行 ${formatRate(last.tx)}</span><span class="lg lg-load">负载 ${last.load.toFixed(2)}</span>`;
    }
  }

  function usageBar(label, used, total, unit = '') {
    const num = Number(total || 0), usedNum = Number(used || 0);
    const pct = num > 0 ? Math.max(0, Math.min(100, Math.round(usedNum / num * 100))) : 0;
    const usedText = num > 0 ? `${formatBytes(usedNum)} / ${formatBytes(num)}` : (usedNum > 0 ? formatBytes(usedNum) : '-');
    const tone = pct >= 85 ? 'hot' : pct >= 60 ? 'warn' : 'ok';
    return `<div class="usage-row"><span class="usage-label">${escapeHtml(label)}</span><div class="usage-track"><div class="usage-fill ${tone}" style="width:${pct}%"></div></div><span class="usage-value">${escapeHtml(usedText)}${unit ? ' ' + unit : ''}</span></div>`;
  }

  function tempRow(label, temp) {
    if (temp === null || temp === undefined) return '';
    const celsius = Number(temp);
    if (!Number.isFinite(celsius)) return '';
    return `<div class="sys-row"><span>${escapeHtml(label)}</span><strong>${celsius.toFixed(1)} °C</strong></div>`;
  }

  function renderDeviceSystem(device) {
    const telemetry = device.telemetry || {};
    const memory = telemetry.memory || {}, storage = telemetry.storage || {}, disk = telemetry.disk || {}, network = telemetry.network || {};
    const conn = telemetry.connections || {}, emmc = telemetry.emmc || {};
    const update = device.agent_update;
    const swapUsed = memory.total_kb ? Number(memory.swap_total_kb || 0) - Number(memory.swap_free_kb || 0) : 0;
    const agentStatus = update ? `可更新 v${update.version}` : '最新';
    const emmcStatus = emmc.pre_eol >= 3 ? '危险' : (emmc.pre_eol === 2 ? '警告' : '正常');
    $('#device-tab-content').innerHTML = `
      <div class="sys-card sys-card-wide">
        <div class="sys-card-title">内存 / 硬盘</div>
        <div class="usage-stack">
          ${usageBar('内存', memory.used_kb * 1024, memory.total_kb * 1024)}
          ${memory.swap_total_kb ? usageBar('Swap', swapUsed * 1024, memory.swap_total_kb * 1024) : ''}
          ${memory.zram_size_kb ? usageBar('ZRAM', memory.zram_used_kb * 1024, memory.zram_size_kb * 1024) : ''}
          ${usageBar('硬盘', (disk.used_kb || storage.used_kb) * 1024, (disk.total_kb || storage.total_kb) * 1024)}
          ${emmc.used_pct !== undefined && emmc.used_pct !== null ? `<div class="usage-row"><span class="usage-label">eMMC 寿命</span><div class="usage-track"><div class="usage-fill ${Number(emmc.used_pct) >= 85 ? 'hot' : Number(emmc.used_pct) >= 60 ? 'warn' : 'ok'}" style="width:${Number(emmc.used_pct)}%"></div></div><span class="usage-value">${Number(emmc.used_pct)}% · ${emmcStatus}</span></div>` : ''}
          ${emmc.brand || emmc.mfg_date ? `<div class="usage-row"><span class="usage-label">eMMC 颗粒</span><span class="usage-value">${escapeHtml(emmc.brand || '-')}${emmc.product ? ' · ' + escapeHtml(emmc.product) : ''}${emmc.mfg_date ? ' · ' + escapeHtml(emmc.mfg_date) : ''}</span></div>` : ''}
        </div>
      </div>
      <div class="sys-card sys-card-wide">
        <div class="sys-card-title">网络</div>
        <div class="sys-rows">
          <div class="sys-row"><span>实时速率</span><strong>↓ ${formatRate(telemetry.network?.wan_rx_bps ?? telemetry.network?.rx_bps)} · ↑ ${formatRate(telemetry.network?.wan_tx_bps ?? telemetry.network?.tx_bps)}</strong></div>
          <div class="sys-row"><span>WAN IPv4</span><strong>${escapeHtml(telemetry.wan?.ipv4 || '-')}</strong></div>
          <div class="sys-row"><span>WAN IPv6</span><strong class="mono wrap">${escapeHtml(telemetry.wan?.ipv6 || '-')}</strong></div>
          <div class="sys-row"><span>LAN</span><strong class="mono">${escapeHtml(telemetry.lan_ipv4 || '-')}</strong></div>
          <div class="sys-row"><span>连接数</span><strong>${conn.total ?? '-'} · TCP ${conn.tcp ?? '-'} · UDP ${conn.udp ?? '-'}</strong></div>
        </div>
        <div class="port-strip">${renderPortChips(device)}</div>
      </div>
      <div class="sys-card sys-card-wide">
        <div class="sys-card-title">负载 / WAN 速率（1 分钟曲线）</div>
        <div class="curve-wrap"><canvas id="curve-canvas" height="150"></canvas>
          <div class="curve-legend" id="curve-legend"><span class="lg lg-down">下行</span><span class="lg lg-up">上行</span><span class="lg lg-load">负载</span></div>
        </div>
      </div>
      <div class="sys-card sys-card-wide active-apps-card">
        <div class="sys-card-title">活跃 App</div>
        ${activeAppsHtml(device)}
      </div>
      <div class="sys-card sys-card-wide">
        <div class="sys-card-title">GWRT Agent</div>
        <div class="agent-line-row"><b>v${escapeHtml(device.agent_version || '--')}</b><span class="agent-status ${update ? 'updatable' : ''}">${escapeHtml(agentStatus)}</span>
          <button class="button button-quiet" type="button" data-reboot-device>重启路由器</button>
          ${update ? `<button class="button button-primary" type="button" data-agent-update>更新</button>` : ''}
        </div>
      </div>
      <div class="device-danger-zone">
        <div><strong>设备绑定</strong><span>解绑后需在路由器 SSH 下执行 <span class="mono">gwrt-agent pair --qr</span> 显示二维码重新绑定。</span></div>
        <button class="button button-danger" type="button" data-unbind-open>解绑设备</button>
      </div>`;
    drawCurve();
  }

  /* ── 网口状态（RJ45/SFP 图标 + 速率着色） ── */
  function portSpeedColor(speed) {
    const m = String(speed || '').match(/^(\d+)/);
    const n = m ? parseInt(m[1], 10) : 0;
    if (n >= 10000) return 'gold';
    if (n >= 5000) return 'red';
    if (n >= 2500) return 'blue';
    if (n >= 1000) return 'green';
    if (n >= 100) return 'cyan';
    if (n >= 10) return 'brown';
    return 'gray';
  }

  function renderPortChips(device) {
    const topo = device.topology || {};
    const ports = Array.isArray(topo.ports) ? topo.ports.filter(p => p.role !== 'wifi') : [];
    const states = topo.states || {};
    if (!ports.length) return '<span class="muted">暂无网口数据</span>';
    return ports.map(p => {
      const st = states[p.name] || {};
      const up = st.carrier === true;
      const isSfp = /sfp|qsfp|xfp/i.test(p.name || '');
      const color = up ? portSpeedColor(st.speed) : 'gray';
      const sub = up ? topoPortSpeed(st.speed) : '未插入';
      return `<div class="port-chip ${color}" title="${escapeHtml(p.label || p.name)} · ${escapeHtml(sub)}">
        <span class="port-box">${isSfp ? '<span class="port-icon sfp"><svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><rect x="8" y="8" width="8" height="8" rx="1"/><circle cx="12" cy="12" r="1.6" class="port-dot"/></svg></span>' : '<span class="port-icon rj45"><svg viewBox="0 0 24 24"><rect x="3" y="8" width="18" height="11" rx="1.5"/><path d="M6 8V6h12v2M8 6V4h8v2"/><path d="M6.5 19v2M12 19v2M17.5 19v2"/></svg></span>'}</span>
        <span class="port-name">${escapeHtml(p.label || p.name)}</span><span class="port-speed">${escapeHtml(sub)}</span>
      </div>`;
    }).join('');
  }

  /* ── 活跃 App（OAF app_list + app map 图标） ── */
  let oafAppMap = null;
  let oafKnownIcons = null;
  async function loadOafMap() {
    if (oafAppMap) return;
    try { oafAppMap = await fetch('/apps/oaf-app-map.json', { cache: 'no-store' }).then(r => r.json()); }
    catch (_) { oafAppMap = {}; }
    oafKnownIcons = new Set(Object.values(oafAppMap || {}).map(v => v && v.id).filter(Boolean));
  }

  function activeAppsHtml(device) {
    const oaf = device.telemetry?.oaf || {};
    const byId = {}, domToId = {};
    Object.entries(oafAppMap || {}).forEach(([dom, v]) => {
      if (!v || !v.id) return;
      byId[String(v.id)] = v.name || ('App ' + v.id);
      domToId[String(dom).toLowerCase()] = String(v.id);
    });
    const normId = item => (item && typeof item === 'object') ? String(item.id ?? item.app_id ?? item.appid ?? item.app ?? '').trim() : String(item ?? '').trim();
    const items = [], seen = new Set();
    (Array.isArray(oaf.app_list) ? oaf.app_list : []).map(normId).filter(Boolean).forEach(id => {
      if (seen.has(id)) return; seen.add(id); items.push({ id, name: byId[id] || ('App ' + id) });
    });
    /* 路由真源：fwx get_active_users 的 users[{app,url}]（appfilter get_app_filter 多数固件不存在） */
    (Array.isArray(oaf.active_users) ? oaf.active_users : []).forEach(u => {
      if (!u || typeof u !== 'object') return;
      const dom = String(u.url || '').toLowerCase();
      let id = '';
      if (dom) { for (const key in domToId) { if (dom === key || dom.endsWith('.' + key) || dom.indexOf(key) >= 0) { id = domToId[key]; break; } } }
      const name = String(u.app || '').trim() || byId[id] || dom || '未知';
      const key = id || name;
      if (seen.has(key)) return; seen.add(key);
      items.push({ id, name });
    });
    if (!items.length) return '<div class="active-apps-empty"><strong>0</strong><span>apps active</span><div class="app-icon-grid"><span class="muted">OAF / fwx 未提供活跃 App</span></div></div>';
    const shown = items.slice(0, 60);
    return `<div class="active-apps-head"><strong>${shown.length}</strong><span>apps active</span></div><div class="app-icon-grid">${shown.map(it => {
      /* 不用 loading="lazy"（Android WebView 常不触发）；失败由事件代理兜底 */
      const icon = it.id
        ? `<img src="/apps/${encodeURIComponent(it.id)}.png" alt="" data-app-fallback="${escapeHtml(String(it.name[0] || '?'))}">`
        : `<span class="active-app-fallback">${escapeHtml(String(it.name[0] || '?'))}</span>`;
      return `<span class="active-app" title="${escapeHtml(it.name)}">${icon}<i>${escapeHtml(it.name)}</i></span>`;
    }).join('')}</div>`;
  }

  function formatUptime(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) return '-';
    const d = Math.floor(seconds / 86400), h = Math.floor((seconds % 86400) / 3600), m = Math.floor((seconds % 3600) / 60);
    if (d > 0) return `${d} 天 ${h} 小时`;
    if (h > 0) return `${h} 小时 ${m} 分`;
    return `${m} 分`;
  }

  /* ── 终端设备图标：与路由器主题同一套识别优先级 ──
     人工标注 > OUI(MAC) > 主机名品牌 > 系统特性 > 设备类型 > 首字母 > 通用图标 */
  const OUI_EXTRA = {'a68de4':'xiaomi','78c294':'xiaomi','788b2a':'xiaomi','c84d44':'google','109027':'synology','18cedf':'radxa','504289':'zte'};
  const OUI_SOLID = {synology:'synology.png', zte:'zte.png'};
  const OUI_BRAND_COLORS = {acer:'#83b81a',amazon:'#ff9900',android:'#3ddc84',apple:'#a2aaad',asus:'#00539b',broadcom:'#cc092f',dell:'#007db8',fnos:'#2568ed',framework:'#6b7280',fujitsu:'#e60012',gigabyte:'#005daa',google:'#4285f4',honor:'#0f6cff',hp:'#0096d6',huawei:'#cf0a2c',intel:'#0071c5',lenovo:'#e2231a',lg:'#a50034',linksys:'#1e4e9c',linux:'#c9d1d9',mediatek:'#ff6a00',microsoft:'#00a4ef',midea:'#00a9e0',motorola:'#0091dc',msi:'#ff0000',netgear:'#00822c',nokia:'#124191',nvidia:'#76b900',oneplus:'#eb0028',oppo:'#1ba784',panasonic:'#0055a4',qnap:'#660099',radxa:'#74bc1f',raspberrypi:'#a22846',samsung:'#1428a0',sharp:'#e60012',sony:'#6b7280',synology:'#00a1e9',tcl:'#e60012',toshiba:'#e60012',tplink:'#4acbd6',ubuntu:'#e95420',ubiquiti:'#0559c9',vivo:'#415fff',vmware:'#6b7280',xiaomi:'#ff6900',zte:'#008ed3'};
  const DEV_BRANDS = [
    {slug:'xiaomi',host:['xiaomi','redmi','mi-','-mi-','mitv','mijia','mibt','miai','xiaoai','aqara','lumi','yeelink','roborock','chuangmi','viomi','zhimi']},
    {slug:'google',host:['chrom','pixel','google','nexus','nest']},
    {slug:'apple',host:['iphone','ipad','macbook','imac','apple','airpods','appletv','apple-watch']},
    {slug:'synology',host:['synology','diskstation','xpenology','dsm']},
    {slug:'samsung',host:['samsung','galaxy','sm-']},
    {slug:'huawei',host:['huawei','mate-','nova','-al00','-an00','-tn00','-tl00','-l29','-lx1','foa-','hry-','lio-','ana-','els-','tas-','noh-','jef-','cdl-']},
    {slug:'honor',host:['honor','hry-']},
    {slug:'oneplus',host:['oneplus']},
    {slug:'oppo',host:['oppo','realme']},
    {slug:'vivo',host:['vivo','iqoo']},
    {slug:'asus',host:['asus','zenwifi']},
    {slug:'tplink',host:['tp-link','tplink','archer']}
  ];
  const DEVICE_TYPE_LABELS = {phone:'手机',tablet:'平板',pc:'电脑',watch:'穿戴',home:'智能家居',ap:'AP',iot:'物联设备',unknown:'设备'};
  const DEVICE_TYPE_TXT = {phone:'📱',tablet:'',pc:'💻',watch:'⌚',home:'⌂',ap:'',iot:'IoT',unknown:'?'};
  let ouiDbMap = {}, ouiNames = {}, ouiDbLoaded = false;
  async function loadOuiDb() {
    if (ouiDbLoaded) return;
    ouiDbLoaded = true;
    try {
      const data = await fetch('/oui-vendors.json', { cache: 'force-cache' }).then(r => r.json());
      const vendors = Array.isArray(data.vendors) ? data.vendors : [];
      const prefixes = data.prefixes || {};
      Object.keys(prefixes).forEach(p => { const v = vendors[prefixes[p]]; if (v && v[0]) ouiDbMap[p.toUpperCase()] = v[0]; });
      vendors.forEach(v => { if (v && v[0]) ouiNames[v[0]] = v[1] || v[0]; });
    } catch (_) {}
  }
  function normMac2(v) { const hex = String(v || '').toLowerCase().replace(/[^0-9a-f]/g, ''); return hex.length === 12 ? hex.match(/.{2}/g).join(':') : String(v || '').toLowerCase(); }
  function ouiSlugForMac(mac) {
    const hex = normMac2(mac).replace(/[^0-9a-f]/g, '').toUpperCase();
    if (hex.length !== 12) return '';
    if (parseInt(hex.slice(0, 2), 16) & 3) return '';
    for (const n of [9, 7, 6]) { const p = hex.slice(0, n); if (Object.prototype.hasOwnProperty.call(ouiDbMap, p)) return ouiDbMap[p]; }
    return '';
  }
  function clientLabel(mac) { const l = state.clientLabels && state.clientLabels[normMac2(mac)]; return l || null; }
  function devBrandSlug(host, mac) {
    const man = clientLabel(mac);
    if (man && man.brand && (OUI_BRAND_COLORS[man.brand] || man.brand === 'fnos')) return man.brand;
    const s = ouiSlugForMac(mac);
    if (s) return s;
    const hex = normMac2(mac).replace(/[^0-9a-f]/g, '').toLowerCase();
    if (hex.length >= 6 && OUI_EXTRA[hex.slice(0, 6)]) return OUI_EXTRA[hex.slice(0, 6)];
    const h = String(host || '').toLowerCase();
    for (const b of DEV_BRANDS) { for (const kw of b.host) { if (h.indexOf(kw) !== -1) return b.slug; } }
    return devOS(h);
  }
  function devOS(h) {
    if (!h) return '';
    if (/fnos|fnnas|feiniu|飞牛/.test(h)) return 'fnos';
    if (/ubuntu/.test(h)) return 'ubuntu';
    if (/iphone|ipad|ipod|apple[- ]?watch|apple[- ]?tv|macbook|imac|mac-?mini|mac-?pro|macos/.test(h)) return 'apple';
    if (/^desktop-|^laptop-|^win-?\d|^windows|windows-/.test(h)) return 'microsoft';
    if (/^android|android[-_ ]|redmi-|^sm-|^chz-|^foa-|^vog-|^ane-|^els-|^jef-|^noh-|^cdl-|^hm-|^mi\d|^mi-|oneplus|^pixel|^moto|^vivo|^oppo|realme|^rmx|^cph|meizu/.test(h)) return 'android';
    if (/armbian|raspbian|ubuntu|debian|centos|fedora|archlinux|fnnas|truenas|openwrt|lede|^linux|^rpi|raspberry|^tux|^orangepi|^rock|^nanopi|^jetson/.test(h)) return 'linux';
    return '';
  }
  function devTypeJs(host) {
    const h = String(host || '').toLowerCase();
    if (/ipad|tablet|\btab\b|\bpad\b|平板|kindle|ereader|surface/.test(h)) return 'tablet';
    if (/iphone|android|redmi|huawei|honor|oppo|vivo|galaxy|\bsm-|pixel|nexus|iqoo|oneplus|realme|nova|mate-|\bmi-|phone|mobile|手机/.test(h)) return 'phone';
    if (/watch|gear|手表|手环|\bband\b|bip|amazfit|ticwatch|wear/.test(h)) return 'watch';
    if (/gecoos|集客|access[-\s]?point|\bap\b|wlan\d*|repeater|mesh|bridge/.test(h)) return 'ap';
    if (/mijia|aqara|lumi|yeelink|yeelight|roborock|xiaoai|homepod|tuya|sonoff|tasmota|esphome|\besp|camera|cam|ipc|door|lock|plug|bulb|light|lamp|switch|sensor|thermostat|speaker|soundbox|tv|盒子|电视|摄像|门锁|插座|灯|传感|音箱|扫地|家居/.test(h)) return 'home';
    if (/switch|gateway|zigbee|ble|bluetooth|mesh|iot|mcu|module/.test(h)) return 'iot';
    if (/windows|\bpc\b|macbook|imac|thinkpad|laptop|desktop|computer|notebook|笔记本|电脑|server|nas|fnnas|armbian|linux|ubuntu|debian|synology|qnap|unraid|openwrt|router|workstation/.test(h)) return 'pc';
    return 'unknown';
  }
  function devLogoHtml(host, mac) {
    const label = String(host || mac || 'unknown');
    const man = clientLabel(mac);
    let t = (man && man.type && DEVICE_TYPE_LABELS[man.type]) ? man.type : devTypeJs(label);
    const typeLabel = DEVICE_TYPE_LABELS[t] || '设备';
    const slug = devBrandSlug(host, mac);
    const attr = mac ? ` data-client-label="${escapeHtml(normMac2(mac))}"` : '';
    if (slug) {
      const color = OUI_BRAND_COLORS[slug] || 'var(--muted,#94a3b8)';
      const name = ouiNames[slug] || slug;
      if (OUI_SOLID[slug]) return `<span class="client-logo solid"${attr} title="${escapeHtml(name + ' · ' + typeLabel + ' · ' + label)}"><img src="/brands/${OUI_SOLID[slug]}" alt=""></span>`;
      return `<span class="client-logo real-brand"${attr} style="--brand:${color}" title="${escapeHtml(name + ' · ' + typeLabel + ' · ' + label)}"><span class="client-logo-mask" style="--m:url(/brands/${slug}.svg)"></span></span>`;
    }
    const known = t && t !== 'unknown';
    if (known) {
      const txt = DEVICE_TYPE_TXT[t] || '';
      return `<span class="client-logo type"${attr} title="${escapeHtml(typeLabel + ' · ' + label)}">${escapeHtml(txt)}</span>`;
    }
    let init = '';
    const s0 = label.replace(/^[^0-9a-zA-Z\u4e00-\u9fa5]+/, '');
    if (s0 && !/^\d{1,3}(\.\d{1,3}){3}$/.test(label) && label.indexOf(':') < 0 && !/^unknown$/i.test(label)) init = s0[0].toUpperCase();
    if (init) return `<span class="client-logo initial"${attr} title="${escapeHtml(label)}">${escapeHtml(init)}</span>`;
    return `<span class="client-logo fallback"${attr} title="${escapeHtml(label)}"><span class="client-logo-mask" style="--m:url(/brands/computer.svg)"></span></span>`;
  }

  function renderClients(device) {
    state.clientLabels = device.client_labels || {};
    const clients = device.clients || [];
    $('#device-tab-content').innerHTML = clients.length ? `<div class="client-list">${clients.map(client => `
      <div class="client-item">
        <div class="client-main">${devLogoHtml(client.hostname, client.mac)}<button class="client-name-edit" type="button" data-client-label="${escapeHtml(normMac2(client.mac || ''))}" data-client-host="${escapeHtml(client.hostname || '')}" title="点击标注名称 / 品牌 / 类型">${escapeHtml((clientLabel(client.mac) || {}).name || client.hostname || client.mac || '-')}</button><span class="mono">${escapeHtml(client.ip || client.mac || '-')}</span><span class="client-status ${client.online === false ? 'off' : ''}">${client.online === false ? '离线' : '在线'}</span>${client.via ? `<span class="client-via">${escapeHtml(client.via)}</span>` : ''}</div>
        <div class="client-actions"><button class="button button-danger" type="button" data-client-command="block" data-mac="${escapeHtml(client.mac || '')}">拉黑</button><button class="button button-quiet" type="button" data-client-command="limit" data-mac="${escapeHtml(client.mac || '')}">限速</button><button class="button button-quiet" type="button" data-client-command="wake" data-mac="${escapeHtml(client.mac || '')}">唤醒</button></div>
      </div>`).join('')}</div>` : '<div class="empty-state"><strong>暂无终端数据</strong><span>等待 Agent 上报 DHCP / OAF 终端信息。</span></div>';
  }

  /* 终端标注：写服务端 collected_labels（与 agent 上报的合并通道） */
  function openClientLabelDialog(mac, host) {
    const key = normMac2(mac);
    if (!key) return;
    const cur = clientLabel(key) || {};
    const brandOptions = Object.keys(OUI_BRAND_COLORS).sort((a, b) => (ouiNames[a] || a).localeCompare(ouiNames[b] || b))
      .map(slug => `<option value="${slug}"${cur.brand === slug ? ' selected' : ''}>${escapeHtml(ouiNames[slug] || slug)}</option>`).join('');
    const typeOptions = Object.keys(DEVICE_TYPE_LABELS).map(t => `<option value="${t}"${cur.type === t ? ' selected' : ''}>${escapeHtml(DEVICE_TYPE_LABELS[t])}</option>`).join('');
    openEditDialog(`终端标注 · ${escapeHtml(host || key)}`,
      `<label>名称<input name="name" maxlength="64" value="${escapeHtml(cur.name || '')}" placeholder="${escapeHtml(host || '')}"></label>
       <div class="form-grid"><label>品牌 / 系统<select name="brand"><option value="">（自动识别）</option>${brandOptions}</select></label>
       <label>设备类型<select name="type"><option value="">（自动识别）</option>${typeOptions}</select></label></div>
       <p class="editor-note mono">${escapeHtml(key)}</p>`,
      async form => {
        await api(`/api/devices/${encodeURIComponent(state.selected)}/client-label`, { method: 'POST', body: { mac: key, name: formValue(form, 'name'), brand: formValue(form, 'brand'), type: formValue(form, 'type') } });
        await refreshDevices().catch(() => {});
        return true;
      },
      { kicker: 'CLIENT LABEL', help: '只采集人工标注过的名称/品牌/类型；正常识别的终端不会上报。保存后与 Agent 采集共用同一张表。' });
  }

  function iconSvg(icon) {
    const paths = { network: '<path d="M4 7h6v6H4zM14 11h6v6h-6zM10 10l4 3M7 13v5h10"/>', shield: '<path d="m12 3 7 3v5c0 4.5-2.7 7.8-7 10-4.3-2.2-7-5.5-7-10V6l7-3Z"/><path d="m9 12 2 2 4-4"/>', globe: '<circle cx="12" cy="12" r="8"/><path d="M4 12h16M12 4c2 2.2 3 4.9 3 8s-1 5.8-3 8c-2-2.2-3-4.9-3-8s1-5.8 3-8Z"/>', download: '<path d="M12 4v10m-4-4 4 4 4-4M5 19h14"/>', route: '<circle cx="6" cy="6" r="2"/><circle cx="18" cy="18" r="2"/><path d="M8 6h4a4 4 0 0 1 4 4v6"/>', filter: '<path d="M4 5h16l-6 7v5l-4 2v-7L4 5Z"/>', store: '<path d="M4 9h16l-1 10H5L4 9ZM6 9l1-4h10l1 4M9 13h6"/>' };
    return `<svg viewBox="0 0 24 24" aria-hidden="true">${paths[icon] || paths.route}</svg>`;
  }

  function pluginEditor(app) {
    const c = app.config || {};
    if (app.id === 'passwall') {
      const subscriptions = c.subscriptions?.length ? c.subscriptions : [{ index: 0, remark: '', url: '', boot_update: '0' }];
      return `<p class="editor-note">对应 LuCI：PassWall → 节点订阅。可添加 / 删除订阅，点击「更新」拉取；「全部更新」更新所有订阅。</p>${subscriptions.map(item => `<div class="plugin-form sub-form"><div class="form-grid"><label>订阅名称<input data-plugin-input data-app="passwall" data-key="subscription_remark" data-index="${item.index}" value="${escapeHtml(item.remark)}" maxlength="80"></label><label>订阅地址<input data-plugin-input data-app="passwall" data-key="subscription_url" data-index="${item.index}" type="url" value="${escapeHtml(item.url)}" placeholder="https://…"></label></div><label class="check-field"><input data-plugin-input data-app="passwall" data-key="subscription_boot_update" data-index="${item.index}" type="checkbox" value="1" ${String(item.boot_update) === '1' ? 'checked' : ''}> 开机自动更新</label><div class="editor-actions"><button class="button button-secondary" type="button" data-sub-update data-index="${item.index}">更新订阅</button><button class="button button-danger" type="button" data-sub-delete data-index="${item.index}">删除</button></div></div>`).join('')}
      <div class="sub-add"><div class="section-label">添加订阅</div><div class="form-grid"><label>订阅名称<input id="sub-new-remark" maxlength="80" placeholder="可选"></label><label>订阅地址<input id="sub-new-url" type="url" placeholder="https://…"></label></div><div class="editor-actions"><button class="button button-secondary" type="button" data-sub-add>添加</button><button class="button button-quiet" type="button" data-sub-update-all>全部更新</button></div></div>`;
    }
    if (app.id === 'openclash') {
      const subscriptions = c.subscriptions?.length ? c.subscriptions : [{ index: 0, name: '', address: '' }];
      return `<p class="editor-note">对应 LuCI：OpenClash → 配置订阅。可添加 / 删除订阅，点击「更新」拉取；「全部更新」更新所有配置。</p>${subscriptions.map(item => `<div class="plugin-form sub-form"><div class="form-grid"><label>配置名称<input data-plugin-input data-app="openclash" data-key="subscription_name" data-index="${item.index}" value="${escapeHtml(item.name)}" maxlength="80"></label><label>订阅地址<input data-plugin-input data-app="openclash" data-key="subscription_url" data-index="${item.index}" type="url" value="${escapeHtml(item.address)}" placeholder="https://…"></label></div><div class="editor-actions"><button class="button button-secondary" type="button" data-sub-update data-index="${item.index}">更新配置</button><button class="button button-danger" type="button" data-sub-delete data-index="${item.index}">删除</button></div></div>`).join('')}
      <div class="sub-add"><div class="section-label">添加订阅</div><div class="form-grid"><label>配置名称<input id="sub-new-name" maxlength="80" placeholder="例如 Airport"></label><label>订阅地址<input id="sub-new-url" type="url" placeholder="https://…"></label></div><div class="editor-actions"><button class="button button-secondary" type="button" data-sub-add>添加</button><button class="button button-quiet" type="button" data-sub-update-all>全部更新</button></div></div>
      <div class="plugin-form compact-form"><label class="check-field"><input data-plugin-input data-app="openclash" data-key="auto_update" data-index="0" type="checkbox" value="1" ${String(c.auto_update) === '1' ? 'checked' : ''}> 开启自动更新</label></div>`;
    }
    if (app.id === 'easytier') {
      const forwards = String(c.et_forward || '').split(/\s+/).filter(Boolean);
      const has = value => forwards.includes(value) ? 'checked' : '';
      return `<p class="editor-note">对应 LuCI：EasyTier → 配置文件。这里只保存 <span class="mono">/etc/easytier/config.toml</span> 和高级防火墙开关。</p><div class="form-grid"><label>启动方式<select data-plugin-input data-app="easytier" data-key="etcmd" data-index="0"><option value="config" ${c.etcmd === 'config' ? 'selected' : ''}>配置文件</option><option value="web" ${c.etcmd === 'web' ? 'selected' : ''}>Web 界面</option></select></label><label>虚拟接口掩码<input data-plugin-input data-app="easytier" data-key="interface_netmask" data-index="0" value="${escapeHtml(c.interface_netmask || '255.0.0.0')}" placeholder="255.0.0.0"></label></div><label>完整配置文件<textarea class="config-textarea" data-plugin-input data-app="easytier" data-key="config_file" data-index="0" spellcheck="false">${escapeHtml(c.config_file || '')}</textarea></label><fieldset class="advanced-box"><legend>高级 / 防火墙</legend><label class="check-field"><input data-plugin-input data-app="easytier" data-key="auto_config_interface" data-index="0" type="checkbox" value="1" ${String(c.auto_config_interface) !== '0' ? 'checked' : ''}> 自动配置 EasyTier 网络接口</label><label class="check-field"><input data-plugin-input data-app="easytier" data-key="auto_config_firewall" data-index="0" type="checkbox" value="1" ${String(c.auto_config_firewall) !== '0' ? 'checked' : ''}> 自动添加和管理防火墙规则</label><div class="forward-grid"><label class="check-field"><input data-forward="etfwlan" type="checkbox" ${has('etfwlan')}> EasyTier → LAN</label><label class="check-field"><input data-forward="etfwwan" type="checkbox" ${has('etfwwan')}> EasyTier → WAN</label><label class="check-field"><input data-forward="lanfwet" type="checkbox" ${has('lanfwet')}> LAN → EasyTier</label><label class="check-field"><input data-forward="wanfwet" type="checkbox" ${has('wanfwet')}> WAN → EasyTier</label></div></fieldset><div class="editor-actions"><button class="button button-quiet" type="button" data-plugin-download>在线下载并启动</button></div>`;
    }
    if (app.id === 'daed') {
      return '<p class="editor-note">daed 的订阅存储在它自己的 wing.db 中，由 daed 自带面板管理（LuCI → DAED → Dashboard，监听 :2023）。这里不做内置订阅的写死显示；请在 daed 面板中添加、删除或更新订阅。</p>';
    }
    return '<p class="editor-note">这个插件暂未提供安全的专用编辑器。</p>';
  }

  function renderPackages(device) {
    // 输入框聚焦时（包名搜索 / 系统源安装输入中）不重建 DOM，避免键盘被踢、输入内容丢失
    const focused = document.activeElement && document.activeElement.closest && document.activeElement.closest('#device-tab-content input, #device-tab-content textarea, #device-tab-content select');
    if (focused) return;
    const packages = device.packages || {}, containers = device.containers || {}, apps = packages.apps || [];
    const packageItems = Array.isArray(packages.items) ? packages.items : [];
    const containerItems = Array.isArray(containers.items) ? containers.items : [];
    const hasContainers = containerItems.length > 0;
    const appCards = apps.map(app => `<article class="app-card" data-app-id="${escapeHtml(app.id)}"><div class="app-icon">${iconSvg(app.icon)}</div><div class="app-copy"><strong>${escapeHtml(app.name || app.id)}</strong><small>${app.running ? '运行中' : app.enabled ? '已启用' : '已停用'} · ${escapeHtml(app.id)}</small></div><div class="app-actions"><button class="button button-quiet" type="button" data-plugin-app="${escapeHtml(app.id)}" data-enabled="${app.enabled ? '1' : '0'}">${app.enabled ? '停用' : '启用'}</button>${['passwall', 'openclash', 'easytier'].includes(app.id) ? '<button class="button button-secondary" type="button" data-plugin-settings>设置</button>' : ''}</div></article>`).join('');
    const market = state.market.map(item => {
      const packageName = item.package || item.id || item.name || '';
      const icon = item.icon ? `<img class="market-icon" src="${escapeHtml(item.icon)}" alt="">` : iconSvg('store');
      return `<article class="market-card"><div class="app-icon">${icon}</div><div class="app-copy"><strong>${escapeHtml(item.name || packageName)}</strong><small>${escapeHtml(item.description || packageName)}${item.version ? ` · v${escapeHtml(item.version)}` : ''}</small></div><button class="button button-secondary" type="button" data-istore-app="${escapeHtml(packageName)}">安装</button></article>`;
    }).join('');
    $('#device-tab-content').innerHTML = `<div class="data-grid"><div class="data-item"><span>已安装包</span><strong>${packages.count ?? packageItems.length}</strong></div><div class="data-item"><span>容器引擎</span><strong>${escapeHtml(containers.engine || 'none')}</strong></div><div class="data-item"><span>运行容器</span><strong>${containerItems.length}</strong></div></div>
      <button class="collapse-heading" type="button" data-toggle-packages="apps"><span>已发现插件 / 服务 <b>${apps.length}</b></span><span>${state.appsOpen ? '收起' : '展开'}</span></button>${state.appsOpen ? `<div class="app-grid">${appCards || '<span class="muted">暂未发现常用服务</span>'}</div>` : ''}
      <button class="store-launcher" type="button" data-market-open><span class="app-icon">${iconSvg('store')}</span><span><strong>iStore 应用市场</strong><small>点击后再加载当前设备可安装的 iStore 应用</small></span><b>${state.marketOpen ? '已打开' : '打开'}</b></button>${state.marketOpen ? `<div class="market-area"><div class="market-tools"><div class="editor-note">${escapeHtml(state.marketError || 'iStore 安装会调用路由器已有的 iStore 安装器，自动处理 iStore 软件源与依赖。')}</div><div class="tool-row"><input id="package-query" placeholder="输入包名搜索（留空点搜索 = apk update）" aria-label="软件包搜索"><button class="button button-secondary" data-command="package-search" type="button">搜索 / 更新源</button></div><div class="tool-row"><input id="package-install-input" placeholder="输入准确包名安装" aria-label="软件包名称"><button class="button button-primary" data-command="package-install" type="button">系统源安装</button></div><div class="tool-row"><input id="market-query" placeholder="筛选下面 iStore 应用（即时过滤，直接点安装）" aria-label="筛选 iStore 应用"></div><pre class="command-output" id="package-search-output" aria-live="polite"></pre></div><div class="app-grid">${market || '<span class="muted">正在获取 iStore 应用，或当前设备未返回可用应用。</span>'}</div></div>` : ''}
      <button class="collapse-heading" type="button" data-toggle-packages="installed"><span>已安装软件包 <b>${packages.count ?? packageItems.length}</b></span><span>${state.installedOpen ? '收起' : '展开'}</span></button>${state.installedOpen ? `<div class="tag-list">${packageItems.slice(0, 80).map(item => `<span class="tag">${escapeHtml(item)}</span>`).join('') || '<span class="muted">暂无数据</span>'}</div>` : ''}
      ${hasContainers ? `<div class="section-label section-heading">容器</div><table class="data-table"><thead><tr><th>名称</th><th>镜像</th><th>状态</th></tr></thead><tbody>${containerItems.map(item => `<tr><td>${escapeHtml(item.name)}</td><td class="mono">${escapeHtml(item.image)}</td><td>${escapeHtml(item.status)}</td></tr>`).join('')}</tbody></table>` : ''}`;
  }

  function renderControls(device) {
    const wifi = device.telemetry?.wifi || [];
    const radios = wifi.map(item => `<div class="control-row radio-editor" data-radio="${Number(item.radio) || 0}" data-channel="${escapeHtml(item.channel || '')}" data-txpower="${escapeHtml(item.txpower || '')}" data-ssid="${escapeHtml(item.ssid || '')}" data-encryption="${escapeHtml(item.encryption || '')}" data-hidden="${item.hidden ? '1' : ''}" data-has-key="${item.has_key ? '1' : ''}"><div><strong>${escapeHtml(item.band || 'Wi‑Fi')} · ${escapeHtml(item.ssid || '（未设置 SSID）')}</strong><span>信道 ${escapeHtml(item.channel || '-')} · 功率 ${escapeHtml(item.txpower || '-')} dBm · ${escapeHtml(item.encryption || '无加密')}${item.hidden ? ' · 隐藏' : ''}</span></div><button class="button button-secondary" data-edit="wifi-radio" type="button">修改</button></div>`).join('');
    $('#device-tab-content').innerHTML = `<div class="control-grid">
      <div class="control-row"><div><strong>AppFilter / OAF</strong><span>识别、过滤与终端策略 · ${escapeHtml(oafSummary(device))}</span></div><div class="control-actions"><button class="button button-secondary" data-edit="oaf" type="button">修改规则</button><button class="button button-secondary" data-command="enable-oaf" type="button">启用</button><button class="button button-quiet" data-command="disable-oaf" type="button">停用</button></div></div>
      <div class="control-row"><div><strong>OAF 终端白名单</strong><span>按 MAC 加入 / 移出 OAF 过滤终端（AppFilter）</span></div><div class="control-actions"><input id="oaf-mac-input" placeholder="例如 00:11:22:33:44:55" maxlength="17" aria-label="MAC 地址"><button class="button button-secondary" data-command="oaf-add-user" type="button">保存 MAC</button><button class="button button-quiet" data-command="oaf-list-users" type="button">查看列表</button></div></div>
      <div id="oaf-users"></div>
      <div class="section-label section-heading">Wi‑Fi SSID（一个 SSID 一张卡，点修改一次改完）</div>${radios || '<span class="muted">暂无 Wi‑Fi 配置</span>'}
      <div class="control-row"><div><strong>主机名</strong><span>修改路由器系统名称</span></div><button class="button button-secondary" data-edit="hostname" type="button">修改</button></div>
      <div class="control-row"><div><strong>LAN 地址</strong><span>会触发网络重载，失败自动回滚</span></div><button class="button button-secondary" data-edit="lan" type="button">修改</button></div>
      <div class="control-row"><div><strong>防火墙默认策略</strong><span>只修改 input / output / forward</span></div><button class="button button-secondary" data-edit="firewall" type="button">修改</button></div>
      <div class="control-row"><div><strong>WAN</strong><span>仅 Android 当前 Wi‑Fi/LAN 直连路由器时允许修改</span></div><button class="button button-secondary" data-edit="wan" type="button">本地修改</button></div>
    </div>`;
  }

  function renderTerminal() {
    const panel = $('#device-tab-content');
    if (!panel) return;
    // 已渲染就不重建：终端不依赖刷新数据，重建会销毁输入框导致键盘被踢、输入内容丢失
    if ($('#terminal-command')) return;
    panel.innerHTML = `<div class="terminal-box"><p class="editor-note">受限远程终端：支持状态查询、ubus 只读查询、UCI 只读查询和服务状态；不支持 shell 管道、重定向、文件上传或任意写入。</p><div class="terminal-input-row"><input id="terminal-command" class="mono" placeholder="例如 ubus call network.interface.wan6 status" aria-label="远程命令"><button class="button button-primary" data-command="terminal-exec" type="button">执行</button></div><pre class="command-output" id="terminal-output" aria-live="polite">${escapeHtml($('#terminal-output')?.textContent || '')}</pre></div>`;
  }

  const TOPO_ICONS = {
    dish: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="16" r="2.5"/><path d="M12 13.5V9"/><path d="M7.5 7c3-2.5 6-2.5 9 0"/><path d="M5 4.5c4.5-4 9.5-4 14 0"/></svg>',
    router: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="9" width="16" height="9" rx="2"/><rect x="7" y="12" width="2.5" height="2.5" rx=".4"/><rect x="11" y="12" width="2.5" height="2.5" rx=".4"/><rect x="15" y="12" width="2" height="2.5" rx=".4"/><line x1="8" y1="7" x2="8" y2="9"/><line x1="16" y1="7" x2="16" y2="9"/><circle cx="12" cy="5.5" r="1"/><line x1="12" y1="6.5" x2="12" y2="9"/></svg>',
    lan: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="3" width="8" height="6" rx="1"/><rect x="7" y="13" width="10" height="5" rx="1"/><line x1="10" y1="9" x2="10" y2="13"/><line x1="14" y1="9" x2="14" y2="13"/><line x1="12" y1="18" x2="12" y2="21"/></svg>',
    wifi: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M2 8c5.5-5 14.5-5 20 0"/><path d="M5.5 11.5c3.5-3 9.5-3 13 0"/><path d="M9 15c1.5-1.5 4.5-1.5 6 0"/><circle cx="12" cy="18" r="1.1" fill="currentColor" stroke="none"/></svg>',
    switch: '<svg viewBox="0 0 30 16" fill="none" stroke="currentColor" stroke-width="1.2"><rect x="1" y="3" width="28" height="10" rx="2"/><circle cx="5" cy="8" r="1.2"/><circle cx="9" cy="8" r="1.2"/><circle cx="13" cy="8" r="1.2"/><circle cx="17" cy="8" r="1.2"/><circle cx="21" cy="8" r="1.2"/><circle cx="25" cy="8" r="1.2"/></svg>',
    phone: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="2" width="10" height="20" rx="2.5"/><line x1="10.5" y1="18.5" x2="13.5" y2="18.5"/></svg>',
    laptop: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="11" rx="1.5"/><line x1="2" y1="19" x2="22" y2="19"/></svg>',
    tablet: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2" width="12" height="20" rx="2"/><line x1="10" y1="19" x2="14" y2="19"/></svg>',
    iot: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="7" y="7" width="10" height="10" rx="1.5"/><rect x="10" y="10" width="4" height="4" rx=".5"/><line x1="9" y1="7" x2="9" y2="4"/><line x1="15" y1="7" x2="15" y2="4"/><line x1="9" y1="17" x2="9" y2="20"/><line x1="15" y1="17" x2="15" y2="20"/><line x1="7" y1="9" x2="4" y2="9"/><line x1="7" y1="15" x2="4" y2="15"/><line x1="17" y1="9" x2="20" y2="9"/><line x1="17" y1="15" x2="20" y2="15"/></svg>',
    watch: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="8" width="8" height="8" rx="2"/><path d="M9.5 8l-1-3h7l-1 3"/><path d="M9.5 16l-1 3h7l-1 3"/></svg>'
  };

  function topoNormMac(value) { const raw = String(value || '').toLowerCase(); const hex = raw.replace(/[^0-9a-f]/g, ''); return hex.length === 12 ? hex.match(/.{2}/g).join(':') : raw; }

  function topoDeviceType(host) {
    const h = String(host || '').toLowerCase();
    if (/ipad|tablet|\btab\b|\bpad\b|平板|kindle|ereader|e-reader|surface/.test(h)) return 'tablet';
    if (/iphone|android|redmi|huawei|honor|oppo|vivo|galaxy|\bsm-|pixel|nexus|iqoo|oneplus|realme|nova|mate-|\bmi-|phone|mobile|手机/.test(h)) return 'phone';
    if (/windows|\bpc\b|macbook|imac|thinkpad|laptop|desktop|computer|notebook|笔记本|电脑|server|nas|synology|qnap|unraid/.test(h)) return 'laptop';
    if (/watch|gear|手表|手环|\bband\b|bip|amazfit|ticwatch/.test(h)) return 'watch';
    return 'iot';
  }

  function topoPortSpeed(speed) {
    const m = String(speed || '').match(/^(\d+)/);
    if (!m) return '-';
    const n = parseInt(m[1], 10);
    return n >= 1000 ? `${(n / 1000).toFixed(n % 1000 ? 1 : 0)}G` : `${n}M`;
  }

  function topoPortKey(port) {
    return (port.ifnames && port.ifnames[0]) || port.name;
  }

  function renderTopology(device) {
    const panel = $('#device-tab-content');
    if (!panel) return;
    const topo = device.topology || {};
    const ports = Array.isArray(topo.ports) ? topo.ports : [];
    const states = topo.states && typeof topo.states === 'object' ? topo.states : {};
    const clients = Array.isArray(topo.clients) ? topo.clients : [];
    const hasData = ports.length || clients.length;
    if (!hasData) {
      panel.innerHTML = '<div class="empty-state"><strong>暂无拓扑数据</strong><span>需要 Agent v12 及以上版本上报网络拓扑；旧版 Agent 正在运行时不会显示。</span></div>';
      return;
    }
    const wanPort = ports.find(p => p.role === 'wan');
    const lanPorts = ports.filter(p => p.role === 'lan');
    const wifiPorts = ports.filter(p => p.role === 'wifi');
    const portByName = {};
    ports.forEach(p => { portByName[topoPortKey(p)] = p; if (p.name) portByName[p.name] = p; });
    const wifiIfnames = new Set(wifiPorts.flatMap(p => p.ifnames && p.ifnames.length ? p.ifnames : [p.name]));
    const devByPort = {};
    const placed = new Set();
    clients.forEach(c => {
      if (!c.mac) return;
      const key = topoNormMac(c.mac);
      if (placed.has(key)) return;
      const portName = String(c.port || '');
      let target = portByName[portName] || null;
      if (!target && wifiIfnames.has(portName)) target = portByName[portName];
      if (!target && c.via && /wifi/i.test(String(c.via))) {
        target = wifiPorts.find(p => {
          const band = String(p.label || '');
          const via = String(c.via || '').toLowerCase();
          if (/wifi24|2\.4/.test(via)) return /2\.4/.test(band);
          if (/wifi6|6g/.test(via)) return /6g/i.test(band);
          if (/wifi5/.test(via)) return /5\./.test(band);
          return false;
        }) || null;
      }
      if (!target && c.online !== false) {
        target = (lanPorts.length ? lanPorts[0] : null) || wifiPorts[0] || null;
      }
      placed.add(key);
      if (target) {
        const tkey = topoPortKey(target);
        (devByPort[tkey] = devByPort[tkey] || []).push(c);
      }
    });
    const allPorts = lanPorts.concat(wifiPorts);
    const counts = allPorts.map(p => ({ port: p, key: topoPortKey(p), count: (devByPort[topoPortKey(p)] || []).length })).sort((a, b) => b.count - a.count);
    const heavyKey = counts.length && counts[0].port.role === 'lan' && counts[0].count >= 6 ? counts[0].key : '';
    const connV = '<svg class="topo-conn-v" viewBox="0 0 2 16" width="2" height="16" preserveAspectRatio="none"><line x1="1" y1="0" x2="1" y2="16" stroke="currentColor" stroke-width="1"/></svg>';
    const busConn = (pos) => {
      let svg = '<svg class="topo-bus-conn" viewBox="0 0 100 16" preserveAspectRatio="none">';
      if (pos !== 'only') {
        if (pos !== 'first') svg += '<line x1="0" y1="0" x2="50" y2="0" vector-effect="non-scaling-stroke"/>';
        if (pos !== 'last') svg += '<line x1="50" y1="0" x2="100" y2="0" vector-effect="non-scaling-stroke"/>';
      }
      svg += '<line x1="50" y1="0" x2="50" y2="16" vector-effect="non-scaling-stroke"/></svg>';
      return svg;
    };
    const devIcon = (client) => {
      const type = topoDeviceType(client.host);
      const name = String(client.host || client.ip || client.mac || 'device');
      const signal = client.signal ? ` · ${client.signal} dBm` : '';
      const title = `${name}${client.ip ? ` · ${client.ip}` : ''}${signal}`;
      return `<span class="topo-dev-col" title="${escapeHtml(title)}"><span class="topo-dev-icon topo-${type}">${TOPO_ICONS[type] || TOPO_ICONS.iot}</span><span class="topo-dev-name">${escapeHtml(String(name).slice(0, 10))}</span></span>`;
    };
    const portNode = (p) => {
      const isWifi = p.role === 'wifi';
      const st = states[p.name] || {};
      const up = isWifi ? p.wifiUp !== false : st.carrier === true;
      let sub;
      if (isWifi) sub = up ? `ch${p.channel || '?'}${p.htmode ? ' ' + p.htmode : ''} · ${p.clients || 0} 台` : 'off';
      else sub = up ? topoPortSpeed(st.speed) : 'down';
      return `<div class="topo-node ${isWifi ? 'wifi' : 'lan'}${up ? ' up' : ' down'}"><span class="topo-icon">${isWifi ? TOPO_ICONS.wifi : TOPO_ICONS.lan}</span><span class="topo-label">${escapeHtml(p.label || p.name)}</span><span class="topo-sub">${escapeHtml(sub)}</span></div>`;
    };
    const childrenHtml = (p) => {
      const key = topoPortKey(p);
      const children = devByPort[key] || [];
      if (!children.length) return '';
      let html = connV;
      if (p.role === 'lan' && children.length > 1) {
        html += `<span class="topo-switch-node" title="交换机 · ${children.length} 台设备">${TOPO_ICONS.switch}</span>${connV}`;
      }
      const wide = key === heavyKey;
      const cols = wide ? Math.min(10, Math.max(3, Math.ceil(Math.sqrt(children.length * 2)))) : children.length;
      html += `<div class="topo-dev-row${wide ? ' topo-dev-row-wide' : ''}"${wide ? ` style="--topo-cols:${cols}"` : ''}>${children.map(devIcon).join('')}</div>`;
      return html;
    };
    const wanIp = (device.telemetry && device.telemetry.wan && device.telemetry.wan.ipv4) || '';
    const wanState = wanPort ? states[wanPort.name] || {} : {};
    const wanUp = wanPort ? wanState.carrier === true : false;
    let html = '';
    if (wanPort) {
      html += `<div class="topo-center"><div class="topo-node wan${wanUp ? ' up' : ' down'}"><span class="topo-icon">${TOPO_ICONS.dish}</span><span class="topo-label">${escapeHtml(wanPort.label || 'WAN')}</span><span class="topo-sub">${escapeHtml(wanUp ? topoPortSpeed(wanState.speed) + (wanIp ? ' · ' + wanIp : '') : 'down')}</span></div></div>${connV}`;
    }
    html += `<div class="topo-center"><div class="topo-node router"><span class="topo-icon">${TOPO_ICONS.router}</span><span class="topo-label">${escapeHtml(deviceName(device))}</span></div></div>${connV}`;
    html += `<div class="topo-ports-bus">${allPorts.map((p, i) => {
      const pos = allPorts.length === 1 ? 'only' : i === 0 ? 'first' : i === allPorts.length - 1 ? 'last' : 'mid';
      return `<div class="topo-port-col">${busConn(pos)}${portNode(p)}${childrenHtml(p)}</div>`;
    }).join('')}</div>`;
    const online = clients.filter(c => c.online !== false).length;
    panel.innerHTML = `<div class="topo-stats"><span>端口 <b>${ports.length}</b></span><span>设备 <b>${clients.length}</b></span><span>在线 <b>${online}</b></span></div><div class="gwrt-topology">${html}</div>`;
  }

  const meshPending = new Set();
  function meshMac(value) {
    const hex = String(value || '').replace(/[:-]/g, '').toLowerCase();
    return /^[0-9a-f]{12}$/.test(hex) ? hex.match(/.{2}/g).join(':') : '';
  }

  function renderMesh(device) {
    const mesh = device.mesh || device.gwrt_mesh || {};
    const panel = $('#device-tab-content');
    if (!mesh.available) {
      panel.innerHTML = '<div class="empty-state"><strong>当前设备尚未上报 GWRT Mesh</strong><span>安装 agent 1712-r7，并启用 wifiroam 后可发现同一局域网内未组网的 GWRT AP。</span></div>';
      return;
    }
    const members = Array.isArray(mesh.members) ? mesh.members.filter(n => n && typeof n === 'object') : [];
    const seen = new Set([meshMac(device.mac), ...members.map(n => meshMac(n.mac || n.id))]);
    const raw = Array.isArray(mesh.discovered_devices) ? mesh.discovered_devices : Array.isArray(mesh.discover) ? mesh.discover.map(mac => ({mac})) : [];
    const candidates = raw.filter(n => {
      if (!n || typeof n !== 'object' || n.pairable === false) return false;
      const mac = meshMac(n.mac);
      if (!mac || seen.has(mac)) return false;
      seen.add(mac); return true;
    });
    const fresh = device.online !== false && Number(device.last_seen) > Date.now() / 1000 - 60;
    const manage = device.can_manage !== false && mesh.role === 'cap' && fresh;
    const role = {cap:'主 AP',sap:'子 AP',unconfigured:'未组网'}[mesh.role] || '未组网';
    const rows = members.map(n => {
      const link = n.uplink?.type || n.uplink_type || '';
      const label = {wired:'有线',wireless:'无线',wifi:'无线',unknown:'未知回传'}[link] || link;
      return `<div class="control-row"><div><strong>${escapeHtml(n.name || n.model || n.mac || n.id)}</strong><span>${escapeHtml(n.ip || n.mac || '')} · ${n.online === false ? '离线' : '在线'}${label ? ' · '+escapeHtml(label) : ''}${n.clients != null ? ' · '+escapeHtml(n.clients)+' 台终端' : ''}</span></div></div>`;
    }).join('');
    const discovered = candidates.map(n => {
      const mac = meshMac(n.mac), pending = meshPending.has(device.device_id + ':' + mac);
      return `<div class="control-row"><div><strong>${escapeHtml(n.name || n.model || mac)}</strong><span>${escapeHtml(n.ip || '')} ${escapeHtml(mac)}${n.model ? ' · '+escapeHtml(n.model) : ''}</span></div><button class="button button-secondary" type="button" data-mesh-add="${mac}"${!manage || pending ? ' disabled' : ''}>${pending ? '正在添加…' : '添加'}</button></div>`;
    }).join('');
    panel.innerHTML = `<div class="mesh-panel"><div class="topo-stats"><span>${escapeHtml(role)}</span><span>在线子 AP <b>${escapeHtml(mesh.peers_online || 0)}</b></span><span>每 5 秒刷新</span></div><h3>已组网 AP</h3>${rows || '<p class="muted">暂无子 AP</p>'}<h3>局域网发现</h3><p class="editor-note">仅显示开启发现的未组网 GWRT AP；普通第三方 AP 不能通过此协议直接添加。${!fresh ? '当前数据已过期，等待设备重新上报。' : mesh.role !== 'cap' ? '请在主 AP 中添加设备。' : ''}</p>${discovered || '<p class="muted">暂未发现可添加的 AP</p>'}</div>`;
  }

  async function addMeshDevice(button) {
    const deviceId = state.selected, mac = meshMac(button.dataset.meshAdd);
    const key = deviceId + ':' + mac;
    if (!mac || button.disabled || meshPending.has(key)) return;
    meshPending.add(key);
    const device = state.devices.find(d => d.device_id === deviceId);
    if (device) renderMesh(device);
    try { await sendCommand('mesh.pair', {mac}); }
    catch (_) { /* sendCommand displays the server error. */ }
    finally {
      meshPending.delete(key);
      if (state.selected === deviceId && state.dtab === 'mesh') {
        const current = state.devices.find(d => d.device_id === deviceId);
        if (current) renderMesh(current);
      }
    }
  }

  async function waitCommand(commandId, kind) {
    for (let attempt = 0; attempt < (kind === 'mesh.pair' ? 90 : 52); attempt++) {
      await new Promise(resolve => setTimeout(resolve, 700));
      try {
        const data = await api(`/api/commands/${encodeURIComponent(commandId)}`), command = data.command || {};
        if (!['success', 'failed', 'rejected'].includes(command.status)) continue;
        const failed = command.status !== 'success';
        const result = command.result;
        if (kind === 'terminal.exec') {
          const output = $('#terminal-output');
          if (output) output.textContent = typeof result === 'string' ? result : JSON.stringify(result || {}, null, 2);
        }
        if (kind === 'package.search' || kind === 'istore.install' || kind === 'package.install') {
          const output = $('#package-search-output');
          if (output) output.textContent = typeof result === 'string' ? result : JSON.stringify(result || {}, null, 2);
        }
        if (kind === 'oaf.get_users') renderOafUsers(result);
        if (!failed && SAFE_APPLY_KINDS.has(kind)) {
          try { await api(`/api/commands/${encodeURIComponent(commandId)}/confirm`, { method: 'POST', body: '{}' }); }
          catch (_) { showToast('设置已应用，但确认未送达；路由器将在 30 秒后自动回滚', 'warning'); }
        }
        if (!failed && kind !== 'terminal.exec' && kind !== 'package.search') await refreshDevices().catch(() => {});
        const title = kind === 'istore.install' ? 'iStore 安装' : kind === 'package.install' ? '软件包安装' : kind === 'oaf.get_users' ? 'OAF 列表刷新' : kind === 'oaf.add_users' ? 'OAF 添加终端' : kind === 'oaf.del_user' ? 'OAF 移出终端' : kind;
        showToast(failed ? `${title}失败：${typeof result === 'string' ? result : '设备返回失败'}` : `${title}完成`, failed ? 'error' : 'success');
        return command;
      } catch (_) {}
    }
    showToast('命令已发送，设备暂未返回结果', 'warning');
    return null;
  }

  async function waitLocalToken(commandId) {
    for (let attempt = 0; attempt < 60; attempt++) {
      await new Promise(resolve => setTimeout(resolve, 700));
      try {
        const data = await api(`/api/commands/${encodeURIComponent(commandId)}`), command = data.command || {};
        if (!['success', 'failed', 'rejected'].includes(command.status)) continue;
        if (command.status === 'success' && typeof command.result === 'string' && /^[a-f0-9]{32,128}$/i.test(command.result)) return command.result;
        showToast('本地控制凭证下发失败，请确认 Agent 已更新并在线', 'error');
        return '';
      } catch (_) {}
    }
    showToast('Agent 暂未返回本地控制凭证', 'warning');
    return '';
  }

  function ensureLocalToken(deviceId, commandId = '') {
    if (state.localTokens[deviceId]) return Promise.resolve(state.localTokens[deviceId]);
    if (state.localTokenRequests[deviceId]) return state.localTokenRequests[deviceId];
    const promise = (async () => {
      try {
        const command = commandId ? { command_id: commandId } : await api(`/api/devices/${encodeURIComponent(deviceId)}/commands`, { method: 'POST', body: JSON.stringify({ kind: 'agent.issue_local_token', payload: {} }) });
        const token = await waitLocalToken(command.command_id);
        if (token) state.localTokens[deviceId] = token;
        return token;
      } catch (error) {
        showToast(error.message || '无法准备本地控制凭证', 'error');
        return '';
      } finally {
        delete state.localTokenRequests[deviceId];
      }
    })();
    state.localTokenRequests[deviceId] = promise;
    return promise;
  }

  async function sendCommand(kind, payload, wait = true, silent = false) {
    if (!state.selected) return;
    if (kind === 'network.set_wan') {
      const bridge = nativeBridge();
      if (!bridge || typeof bridge.sendLocalCommand !== 'function') { if (!silent) showToast('WAN 只能在 Android 当前 Wi‑Fi/LAN 直连路由器修改', 'error'); return; }
      const token = await ensureLocalToken(state.selected);
      if (!token) return;
      bridge.sendLocalCommand(JSON.stringify({ device_id: state.selected, local_token: token, kind, payload })); return;
    }
    try { const data = await api(`/api/devices/${encodeURIComponent(state.selected)}/commands`, { method: 'POST', body: JSON.stringify({ kind, payload }) }); if (!wait) { if (!silent) showToast('设置已排队，路由器会依次应用', 'info'); return data; } if (!silent) showToast('命令已发送，等待路由器返回', 'info'); return waitCommand(data.command_id, kind); }
    catch (error) { if (!silent) showToast(error.message, 'error'); throw error; }
  }

  function openEditDialog(title, fields, submit, options = {}) {
    const dialog = $('#edit-dialog');
    if (!dialog) return;
    $('#edit-kicker').textContent = options.kicker || 'SETTINGS';
    $('#edit-title').textContent = title;
    $('#edit-fields').innerHTML = fields;
    $('#edit-help').textContent = options.help || '';
    $('#edit-form button[type="submit"]').textContent = options.submitText || '保存设置';
    state.editorSubmit = submit;
    dialog.showModal();
    setTimeout(() => $('input, select, textarea', dialog)?.focus(), 0);
  }

  function closeEditDialog() {
    $('#edit-dialog')?.close();
    state.editorSubmit = null;
  }

  async function renameDevice(name) {
    await api(`/api/devices/${encodeURIComponent(state.selected)}/rename`, { method: 'POST', body: JSON.stringify({ name }) });
    await refreshDevices();
    showToast('设备名称已保存');
    return true;
  }

  function openUnbindDialog() {
    const device = state.devices.find(item => item.device_id === state.selected);
    if (!device) return;
    $('#unbind-title').textContent = '解绑设备';
    $('#unbind-copy').innerHTML = `确认解绑“${escapeHtml(deviceName(device))}”（${escapeHtml(device.device_id)}）？解绑后设备会从当前账号移除。<br><br>重新绑定：在路由器同一 Wi-Fi 下点「添加设备」自动发现，或路由器本地 SSH 执行<br><span class="mono">gwrt-agent pair --qr</span><br>显示二维码后扫码。`;
    $('#unbind-dialog').showModal();
  }

  async function unbindDevice() {
    const device = state.devices.find(item => item.device_id === state.selected);
    if (!device) return;
    try {
      await api(`/api/devices/${encodeURIComponent(device.device_id)}/unbind`, { method: 'POST', body: '{}' });
      delete state.claimTokens[device.device_id];
      delete state.localTokens[device.device_id];
      state.selected = ''; state.market = []; state.marketOpen = false; state.appsOpen = false; state.installedOpen = false;
      await refreshDevices();
      setPairStatus('设备已解绑；要重新添加，请在路由器本地自动发现或扫码。');
      showToast('设备已解绑');
    } catch (error) { showToast(error.message, 'error'); }
  }

  async function savePluginForm(root) {
    const fields = $$('[data-plugin-input]', root);
    const commands = [];
    for (const field of fields) {
      const value = field.type === 'checkbox' ? (field.checked ? '1' : '0') : field.value;
      const urlField = $(`[data-plugin-input][data-key="subscription_url"][data-index="${field.dataset.index}"]`, root);
      if (urlField && !urlField.value.trim()) continue;
      if (field.dataset.key === 'config_file' && !value.trim()) { showToast('EasyTier 配置文件不能为空', 'error'); return; }
      commands.push(sendCommand('plugin.config.set', { app: field.dataset.app, key: field.dataset.key, index: Number(field.dataset.index || 0), value }, false, true));
    }
    const forwardFields = $$('[data-forward]', root);
    if (forwardFields.length) commands.push(sendCommand('plugin.config.set', { app: 'easytier', key: 'et_forward', index: 0, value: forwardFields.filter(item => item.checked).map(item => item.dataset.forward).join(' ') }, false, true));
    await Promise.all(commands);
    showToast('配置已排队，路由器会依次应用', 'info');
    return true;
  }

  function commandFromControls(command, target) {
    if (command === 'enable-oaf') return sendCommand('oaf.set_base', { enable: 1 });
    if (command === 'disable-oaf') return sendCommand('oaf.set_base', { enable: 0 });
    if (command === 'oaf-add-user') {
      const input = $('#oaf-mac-input');
      const mac = (input?.value || '').trim().toUpperCase();
      if (!/^([0-9A-F]{2}:){5}[0-9A-F]{2}$/.test(mac)) return showToast('请输入合法 MAC（如 00:11:22:33:44:55）', 'error');
      if (input) input.value = '';
      return sendCommand('oaf.add_users', { mac_list: [mac] });
    }
    if (command === 'oaf-list-users') {
      const box = $('#oaf-users');
      if (box) box.innerHTML = '<span class="muted">加载中…</span>';
      return sendCommand('oaf.get_users', {});
    }
    if (command === 'package-search') {
      const query = $('#package-query')?.value.trim() || '';
      if (query) return sendCommand('package.search', { query });
      showToast('搜索为空：正在更新软件源…', 'info');
      return sendCommand('package.update', {}, false).then(() => showToast('软件源已更新', 'success')).catch(() => {});
    }
    if (command === 'package-install') {
      const packageName = $('#package-install-input')?.value.trim() || '';
      return packageName ? sendCommand('package.install', { package: packageName }) : showToast('请输入准确软件包名', 'error');
    }
    if (command === 'terminal-exec') {
      const value = $('#terminal-command')?.value.trim() || '';
      return value ? sendCommand('terminal.exec', { command: value }) : showToast('请输入命令', 'error');
    }
  }

  function formValue(form, name) {
    return String(new FormData(form).get(name) || '').trim();
  }

  function renderOafUsers(result) {
    const box = $('#oaf-users');
    if (!box) return;
    let users = [];
    try {
      const parsed = typeof result === 'string' ? JSON.parse(result) : (result || {});
      const raw = Array.isArray(parsed) ? parsed : (parsed.mac_list || parsed.users || parsed.result || []);
      users = (Array.isArray(raw) ? raw : []).map(item => typeof item === 'string' ? { mac: item } : (item || {})).filter(item => item.mac);
    } catch (_) { users = []; }
    box.innerHTML = users.length
      ? `<div class="oaf-users-list">${users.map(u => `<div class="oaf-user-row"><span class="mono">${escapeHtml(String(u.mac).toUpperCase())}</span><span>${escapeHtml(u.hostname || u.nickname || u.ip || '')}</span><button class="button button-danger" type="button" data-oaf-del="${escapeHtml(u.mac)}">移出</button></div>`).join('')}</div>`
      : '<span class="muted">暂无 OAF 过滤终端，或设备未返回数据</span>';
  }

  function openPluginEditor(appId) {
    const app = state.devices.find(item => item.device_id === state.selected)?.packages?.apps?.find(item => item.id === appId);
    if (!app) return showToast('插件信息已过期，请刷新设备', 'error');
    const dialog = $('#edit-dialog');
    if (dialog) dialog.dataset.pluginApp = appId;
    openEditDialog(`${app.name || app.id} 设置`, pluginEditor(app), form => savePluginForm(form), { kicker: 'PLUGIN SETTINGS', help: '保存后由 Agent 写入对应的 LuCI/UCI 配置，窗口会自动关闭。' });
  }

  async function subscriptionAction(target) {
    const dialog = $('#edit-dialog');
    const app = dialog?.dataset.pluginApp || '';
    if (!app) return;
    const index = Number(target.dataset.index || 0);
    if (target.closest('[data-sub-delete]')) {
      await sendCommand('plugin.subscription.delete', { app, index });
    } else if (target.closest('[data-sub-update]')) {
      await sendCommand('plugin.subscription.update', { app, index }, false);
      showToast('已触发订阅更新，稍后自动刷新', 'info');
      return;
    } else if (target.closest('[data-sub-update-all]')) {
      await sendCommand('plugin.subscription.update', { app, index: -1 }, false);
      showToast('已触发全部订阅更新，稍后自动刷新', 'info');
      return;
    } else if (target.closest('[data-sub-add]')) {
      const urlInput = $('#sub-new-url');
      const url = urlInput?.value.trim() || '';
      if (!url) { showToast('请输入订阅地址', 'error'); return; }
      const remark = ($('#sub-new-remark')?.value.trim() || $('#sub-new-name')?.value.trim() || '');
      await sendCommand('plugin.subscription.add', { app, url, remark });
    }
    closeEditDialog();
    showToast('订阅已更新，等待路由器上报', 'success');
    await refreshDevices().catch(() => {});
  }

  /* OAF 基础配置摘要 + 编辑 */
  function oafBaseOf(device) {
    const raw = device.telemetry?.oaf?.base_raw;
    if (!raw) return {};
    try { const v = typeof raw === 'string' ? JSON.parse(raw) : raw; return (v && typeof v === 'object') ? v : {}; } catch (_) { return {}; }
  }
  function oafSummary(device) {
    const base = oafBaseOf(device);
    const on = base.enable === 1 || base.enable === '1' || base.enable === true;
    const parts = [on ? '已启用' : '未启用'];
    if (base.work_mode !== undefined) parts.push('工作模式 ' + base.work_mode);
    if (base.app_filter_mode !== undefined) parts.push('过滤模式 ' + base.app_filter_mode);
    if (base.disable_quic !== undefined) parts.push(base.disable_quic ? '禁 QUIC' : 'QUIC 开');
    return parts.join(' · ');
  }
  function openOafEditor(device) {
    const base = oafBaseOf(device);
    const apps = device.telemetry?.oaf?.app_list;
    const appIds = Array.isArray(apps) ? apps.map(item => (item && typeof item === 'object') ? item.id : item).filter(Boolean).join(',') : '';
    return openEditDialog('AppFilter / OAF 规则',
      `<div class="form-grid">
         <label class="check-field"><input name="enable" type="checkbox" value="1"${(base.enable === 1 || base.enable === '1' || base.enable === true) ? ' checked' : ''}> 启用 OAF</label>
         <label class="check-field"><input name="disable_quic" type="checkbox" value="1"${base.disable_quic ? ' checked' : ''}> 禁用 QUIC</label>
       </div>
       <div class="form-grid">
         <label>工作模式 work_mode<input name="work_mode" type="number" min="0" max="2" value="${escapeHtml(String(base.work_mode ?? 0))}"></label>
         <label>过滤模式 app_filter_mode<input name="app_filter_mode" type="number" min="0" max="2" value="${escapeHtml(String(base.app_filter_mode ?? 0))}"></label>
         <label>记录 record_enable<input name="record_enable" type="number" min="0" max="1" value="${escapeHtml(String(base.record_enable ?? 0))}"></label>
         <label>用户模式 mode<input name="mode" type="number" min="0" max="2" value="0"></label>
       </div>
       <label>App 列表（英文逗号分隔的 App ID）<input name="app_ids" value="${escapeHtml(appIds)}" placeholder="例如 3001,3003"></label>`,
      async form => {
        const on = formValue(form, 'enable') === '1' ? 1 : 0;
        await sendCommand('oaf.set_base', { enable: on, work_mode: Number(formValue(form, 'work_mode')) || 0, record_enable: Number(formValue(form, 'record_enable')) || 0, disable_quic: formValue(form, 'disable_quic') === '1' ? 1 : 0, app_filter_mode: Number(formValue(form, 'app_filter_mode')) || 0 });
        const mode = formValue(form, 'mode');
        if (mode !== '') await sendCommand('oaf.set_user_mode', { mode: Number(mode) || 0 });
        const ids = formValue(form, 'app_ids').split(',').map(v => Number(v.trim())).filter(v => Number.isInteger(v) && v > 0 && v < 100000);
        if (ids.length) await sendCommand('oaf.set_apps', { apps: ids });
        return true;
      },
      { kicker: 'APPFILTER', help: '写入 appfilter 的 set_app_filter_base / set_app_filter_user / set_app_filter。App 列表写空则不修改；工作/过滤/记录模式为数字。' });
  }

  function openEditor(kind, target) {
    const device = state.devices.find(item => item.device_id === state.selected);
    if (!device) return;
    const wifi = device.telemetry?.wifi || [];
    if (kind === 'oaf') return openOafEditor(device);
    if (kind === 'device-name') {
      return openEditDialog('设备显示名称', `<label>显示名称<input name="name" maxlength="64" required value="${escapeHtml(device.display_name || '')}" placeholder="${escapeHtml(device.model || device.device_id)}"></label>`, async form => renameDevice(formValue(form, 'name')), { kicker: 'DEVICE NAME', help: '只修改当前账号中的显示名称，不会改动路由器系统主机名。' });
    }
    if (kind === 'app-rules') {
      return openEditDialog('AppFilter 规则', '<label>App ID 列表<input name="apps" required placeholder="例如 3001,3003"></label>', async form => { const apps = formValue(form, 'apps').split(',').map(item => Number(item.trim())).filter(item => Number.isInteger(item) && item > 0 && item < 100000); if (!apps.length) { showToast('请输入至少一个有效 App ID', 'error'); return false; } await sendCommand('oaf.set_apps', { app_list: apps }); return true; }, { kicker: 'APPFILTER', help: '以英文逗号分隔多个 App ID。' });
    }
    if (kind === 'wifi-radio') {
      const row = target.closest('.radio-editor');
      const radio = Number(row?.dataset.radio || 0);
      const cur = wifi.find(item => Number(item.radio) === radio) || {};
      const encOptions = [['', '（不修改）'], ['none', '开放（无密码）'], ['psk2', 'WPA2-PSK'], ['psk-mixed', 'WPA/WPA2 混合'], ['sae', 'WPA3-SAE'], ['sae-mixed', 'WPA2/WPA3 混合'], ['owe', 'OWE（开放加密）']];
      const encSel = encOptions.map(([v, label]) => `<option value="${v}"${(cur.encryption || '') === v ? ' selected' : ''}>${escapeHtml(label)}</option>`).join('');
      const body = `<div class="form-grid"><label>Wi‑Fi 名称（SSID）<input name="ssid" maxlength="32" required value="${escapeHtml(cur.ssid || '')}" placeholder="例如 GWRT-5G"></label><label>加密方式<select name="encryption">${encSel}</select></label></div>
        <div class="form-grid"><label>新密码<input name="password" type="password" minlength="8" maxlength="63" placeholder="${cur.has_key ? '留空表示不修改' : '8-63 位，开放网络可留空'}"></label><label>信道<input name="channel" type="number" min="0" max="233" required value="${escapeHtml(cur.channel || '')}"></label></div>
        <div class="form-grid"><label>发射功率（dBm）<input name="txpower" type="number" min="0" max="40" required value="${escapeHtml(cur.txpower || '')}"></label><label class="check-field"><input name="hidden" type="checkbox" value="1"${cur.hidden ? ' checked' : ''}> 隐藏 SSID</label></div>`;
      return openEditDialog(`${cur.band || 'Wi‑Fi'} SSID 设置`, body, async form => {
        const ssid = formValue(form, 'ssid'), password = formValue(form, 'password'), encryption = formValue(form, 'encryption');
        const channel = Number(formValue(form, 'channel')), txpower = Number(formValue(form, 'txpower'));
        const hidden = formValue(form, 'hidden') === '1' ? '1' : '0';
        if (!ssid) { showToast('SSID 不能为空', 'error'); return false; }
        if (password && (password.length < 8 || password.length > 63)) { showToast('密码需要 8-63 位，留空表示不修改', 'error'); return false; }
        if (!Number.isInteger(channel) || !Number.isInteger(txpower)) { showToast('请填写信道和功率', 'error'); return false; }
        await sendCommand('wifi.radio.set', { radio, channel, txpower, ssid, password, encryption, hidden });
        return true;
      }, { kicker: 'WI-FI SSID', help: 'SSID 名 / 密码 / 加密 / 隐藏 / 信道 / 功率 一次改完并保存；留空的密码表示不修改。保存后 Wi‑Fi 会重载，30 秒内失联自动回滚。' });
    }
    if (kind === 'wifi') {
      return openEditDialog('Wi‑Fi SSID / 密码', `<div class="form-grid"><label>Wi‑Fi 名称<input name="ssid" maxlength="32" required value="${escapeHtml(wifi[0]?.ssid || '')}"></label><label>新密码<input name="password" type="password" maxlength="63" minlength="8" required placeholder="8-63 位"></label></div>`, async form => { const ssid = formValue(form, 'ssid'), password = formValue(form, 'password'); if (!ssid || password.length < 8 || password.length > 63) { showToast('SSID 不能为空，密码需要 8-63 位', 'error'); return false; } await sendCommand('wifi.set', { ssid, password }); return true; }, { kicker: 'WI-FI', help: '修改会应用到无线网络；30 秒内失联将自动回滚。' });
    }
    if (kind === 'hostname') {
      return openEditDialog('修改主机名', `<label>主机名<input name="hostname" maxlength="64" required value="${escapeHtml(device.telemetry?.hostname || '')}" placeholder="例如 gwrt-home"></label>`, async form => { await sendCommand('system.hostname.set', { hostname: formValue(form, 'hostname') }); return true; }, { kicker: 'SYSTEM' });
    }
    if (kind === 'lan') {
      return openEditDialog('LAN 地址', `<div class="form-grid"><label>LAN IP<input name="ipaddr" required value="${escapeHtml(device.telemetry?.lan_ipv4 || '')}" placeholder="192.168.1.1"></label><label>子网掩码<input name="netmask" required placeholder="255.255.255.0"></label></div><label>网关（可选）<input name="gateway" placeholder="192.168.1.254"></label>`, async form => { await sendCommand('network.lan.set', { ipaddr: formValue(form, 'ipaddr'), netmask: formValue(form, 'netmask'), gateway: formValue(form, 'gateway') }); return true; }, { kicker: 'LAN', help: '修改 LAN 会重载网络；30 秒内失联将自动回滚。' });
    }
    if (kind === 'firewall') {
      const policies = name => `<label>${name}<select name="${name.toLowerCase()}"><option>ACCEPT</option><option>DROP</option><option>REJECT</option></select></label>`;
      return openEditDialog('防火墙默认策略', `<div class="form-grid">${policies('INPUT')}${policies('OUTPUT')}${policies('FORWARD')}</div>`, async form => { await sendCommand('network.firewall.set', { input: formValue(form, 'input'), output: formValue(form, 'output'), forward: formValue(form, 'forward') }); return true; }, { kicker: 'FIREWALL', help: '修改防火墙策略会触发安全回滚。' });
    }
    if (kind === 'wan') {
      return openEditDialog('本地修改 WAN', '<label>协议<select name="proto"><option value="dhcp">DHCP</option><option value="static">静态 IPv4</option><option value="pppoe">PPPoE</option></select></label><div class="form-grid"><label>静态 IP<input name="ipaddr"></label><label>掩码<input name="netmask"></label><label>网关<input name="gateway"></label><label>PPPoE 用户名<input name="username"></label></div><label>PPPoE 密码<input name="password" type="password"></label>', async form => { await sendCommand('network.set_wan', { proto: formValue(form, 'proto') || 'dhcp', ipaddr: formValue(form, 'ipaddr'), netmask: formValue(form, 'netmask'), gateway: formValue(form, 'gateway'), username: formValue(form, 'username'), password: formValue(form, 'password') }); return true; }, { kicker: 'LOCAL WAN', help: '只能在 Android 已绑定且当前连接该路由器 Wi‑Fi/LAN 时应用。' });
    }
  }

  function openLimitDialog(mac) {
    const dialog = $('#limit-dialog');
    if (!dialog) return;
    dialog.dataset.mac = mac;
    $('#limit-down').value = '';
    $('#limit-up').value = '';
    dialog.showModal();
  }

  function nativeAppVersion() {
    try { return Number(window.GWRTNative?.getAppVersion?.() || 0); } catch (_) { return 0; }
  }

  function openAppUpdate(manifest) {
    state.appUpdate = manifest;
    $('#update-title').textContent = `发现新版本 ${manifest.version_name || ''}`.trim();
    $('#update-copy').textContent = manifest.message || 'GWRT Control 有新的 Android 版本可用。';
    $('#update-notes').textContent = manifest.notes || '';
    $('#app-update-dialog').showModal();
  }

  async function checkAppUpdate(force = false) {
    const current = nativeAppVersion();
    if (!current) {
      if (force) showToast('网页端无法安装 App，请在 Android App 内检查更新', 'info');
      return;
    }
    try {
      const response = await fetch('/updates/app/manifest.json', { cache: 'no-store', headers: { Accept: 'application/json' } });
      const manifest = await response.json();
      if (!response.ok || !Number.isInteger(Number(manifest.version_code)) || !manifest.apk_url || !/^[a-f0-9]{64}$/i.test(manifest.sha256 || '')) throw new Error('更新信息无效');
      if (Number(manifest.version_code) <= current) { if (force) showToast('GWRT Control 已是最新版本', 'success'); return; }
      openAppUpdate(manifest);
    } catch (error) { if (force) showToast(error.message || '检查更新失败', 'error'); }
  }

  async function createAppLoginCode() {
    try {
      const data = await api('/api/auth/app-code', { method: 'POST', body: '{}' });
      $('#app-login-code').textContent = data.code || '--------';
      $('#app-login-code-expiry').textContent = `剩余 ${Number(data.expires_in || 120)} 秒`;
      $('#app-login-code-dialog').showModal();
    } catch (error) { showToast(error.message || '动态登录码生成失败', 'error'); }
  }

  $('#limit-dialog')?.addEventListener('click', event => {
    if (event.target === event.currentTarget) event.currentTarget.close();
  });
  $('#limit-form')?.addEventListener('submit', event => {
    event.preventDefault();
    const dialog = $('#limit-dialog'), down = Number($('#limit-down').value), up = Number($('#limit-up').value);
    if (!Number.isInteger(down) || !Number.isInteger(up) || down < 0 || up < 0 || down > 100000000 || up > 100000000) { showToast('上下行限速需要填写 0-100000000 Kbps', 'error'); return; }
    dialog.close();
    sendCommand('client.limit', { mac: dialog.dataset.mac, down_kbps: down, up_kbps: up });
  });
  $('#edit-dialog')?.addEventListener('click', event => {
    if (event.target === event.currentTarget || event.target.closest('[data-dialog-close]')) closeEditDialog();
    if (event.target.closest('[data-plugin-download]')) sendCommand('plugin.download', { app: 'easytier' });
    if (event.target.closest('[data-sub-add], [data-sub-delete], [data-sub-update], [data-sub-update-all]')) subscriptionAction(event.target);
  });
  $('#edit-form')?.addEventListener('submit', async event => {
    event.preventDefault();
    try { if (state.editorSubmit && await state.editorSubmit(event.currentTarget)) closeEditDialog(); }
    catch (_) { /* sendCommand already displayed the actionable failure */ }
  });
  $('#app-update-dialog')?.addEventListener('click', event => {
    if (event.target === event.currentTarget || event.target.closest('[data-update-later]')) event.currentTarget.close();
  });
  $('#app-login-code-dialog')?.addEventListener('click', event => {
    if (event.target === event.currentTarget) event.currentTarget.close();
  });
  $('#update-download')?.addEventListener('click', () => {
    const update = state.appUpdate, bridge = window.GWRTNative;
    if (!update) return;
    const url = new URL(update.apk_url, window.location.origin);
    $('#app-update-dialog').close();
    if (bridge?.downloadApk) { bridge.downloadApk(url.toString(), String(update.version_name || ''), String(update.sha256 || '')); showToast('正在下载更新包，完成后会打开系统安装器', 'info'); }
    else { showToast('网页端无法安装 App 更新包，请使用 Android App', 'error'); }
  });

  function authPayload(form) {
    return {
      username: form.get('username'), password: form.get('password'),
      captcha_id: String(form.get('captcha_id') || ''), captcha: String(form.get('captcha') || '')
    };
  }

  $('#login-form').addEventListener('submit', async event => {
    event.preventDefault(); $('#auth-error').textContent = ''; const form = new FormData(event.currentTarget);
    try { const data = await api('/api/auth/login', { method: 'POST', body: JSON.stringify(authPayload(form)) }); state.csrf = data.csrf; setLoggedIn(data.user); await loadSettings(); await refreshDevices(); loadWeather(); startRefreshTimer(); showToast('登录成功'); }
    catch (error) { $('#auth-error').textContent = error.message; refreshCaptcha(); }
  });
  $('#register-form').addEventListener('submit', async event => {
    event.preventDefault(); $('#auth-error').textContent = ''; const form = new FormData(event.currentTarget); const password = String(form.get('password') || '');
    if (password !== String(form.get('password_confirm') || '')) { $('#auth-error').textContent = '两次输入的密码不一致'; return; }
    try { const data = await api('/api/auth/register', { method: 'POST', body: JSON.stringify(authPayload(form)) }); state.csrf = data.csrf; setLoggedIn(data.user); await loadSettings(); await refreshDevices(); loadWeather(); startRefreshTimer(); showToast('账号已创建'); }
    catch (error) { $('#auth-error').textContent = error.message; refreshCaptcha(); }
  });
  $$('.auth-tab').forEach(tab => tab.addEventListener('click', () => setAuthMode(tab.dataset.authMode)));
  document.addEventListener('click', event => {
    const refresh = event.target.closest('[data-captcha-refresh], .captcha-box');
    if (refresh) refreshCaptcha();
  });
  $('#logout-button').addEventListener('click', async () => { try { await api('/api/auth/logout', { method: 'POST', body: '{}' }); } catch (_) {} if (state.timer) clearInterval(state.timer); state.timer = null; state.csrf = ''; state.devices = []; state.selected = ''; state.market = []; state.marketOpen = false; closeProfileMenu(); setLoggedIn(null); setAuthMode('login'); });
  $('#profile-button').addEventListener('click', toggleProfileMenu);
  document.addEventListener('click', event => { if (!$('#account-menu')?.contains(event.target)) closeProfileMenu(); });
  $('[data-account-action="check-update"]')?.addEventListener('click', () => { closeProfileMenu(); checkAppUpdate(true); });
  $('[data-account-action="change-password"]')?.addEventListener('click', () => { closeProfileMenu(); $('#password-dialog')?.showModal(); });
  $('#password-form')?.addEventListener('submit', async event => {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    const newPassword = String(form.get('new_password') || '');
    if (newPassword !== String(form.get('new_password_confirm') || '')) { showToast('两次输入的新密码不一致', 'error'); return; }
    try {
      await api('/api/auth/password', { method: 'POST', body: JSON.stringify({ old_password: form.get('old_password'), new_password: newPassword }) });
      $('#password-dialog')?.close();
      showToast('密码已修改，请用新密码登录', 'success');
    } catch (error) { showToast(error.message, 'error'); }
  });
  $('[data-account-action="app-login-code"]')?.addEventListener('click', () => { closeProfileMenu(); createAppLoginCode(); });
  $('#theme-toggle')?.addEventListener('click', () => { setTheme(document.documentElement.dataset.theme === 'light' ? 'dark' : 'light'); closeProfileMenu(); });
  $('#device-notification-toggle')?.addEventListener('change', async event => {
    const toggle = event.currentTarget, previous = state.notificationsEnabled;
    state.notificationsEnabled = toggle.checked;
    try {
      const data = await api('/api/settings/notifications', { method: 'POST', body: JSON.stringify({ enabled: toggle.checked ? 1 : 0 }) });
      state.notificationsEnabled = data.settings?.device_notifications !== false;
      toggle.checked = state.notificationsEnabled;
      showToast(state.notificationsEnabled ? '已开启设备上线 / 离线提示' : '已关闭设备上线 / 离线提示', 'success');
    } catch (error) {
      state.notificationsEnabled = previous;
      toggle.checked = previous;
      showToast(error.message, 'error');
    }
  });
  $('#refresh-button').addEventListener('click', () => refreshDevices().catch(error => showToast(error.message, 'error')));
  $('#unbind-form')?.addEventListener('submit', event => { event.preventDefault(); $('#unbind-dialog')?.close(); unbindDevice(); });
  $$('[data-unbind-cancel]').forEach(btn => btn.addEventListener('click', () => $('#unbind-dialog')?.close()));
  let rebootCountdown = 0;
  function openRebootDialog() {
    const device = state.devices.find(d => d.device_id === state.selected);
    if (!device) return;
    $('#reboot-title').textContent = `重启 ${deviceName(device)}`;
    $('#reboot-countdown').textContent = '请确认：重启会断开网络约 1 分钟。';
    $('#reboot-confirm').disabled = true;
    $('#reboot-dialog').showModal();
    rebootCountdown = 10;
    $('#reboot-countdown').textContent = `请在 ${rebootCountdown} 秒后点击确认…`;
    clearInterval(rebootCountdown.timer);
    rebootCountdown.timer = setInterval(() => {
      rebootCountdown--;
      if (rebootCountdown <= 0) {
        clearInterval(rebootCountdown.timer);
        $('#reboot-confirm').disabled = false;
        $('#reboot-countdown').textContent = '可以点击确认重启了。';
      } else {
        $('#reboot-countdown').textContent = `请在 ${rebootCountdown} 秒后点击确认…`;
      }
    }, 1000);
  }
  $('#reboot-form')?.addEventListener('submit', event => {
    event.preventDefault();
    clearInterval(rebootCountdown.timer);
    $('#reboot-dialog')?.close();
    sendCommand('system.reboot', {}, false);
    showToast('重启指令已下发，路由器将重启', 'warning');
  });
  $$('[data-reboot-cancel]').forEach(btn => btn.addEventListener('click', () => { clearInterval(rebootCountdown.timer); $('#reboot-dialog')?.close(); }));
  $('#device-list')?.addEventListener('click', event => { const row = event.target.closest('[data-device]'); if (!row) return; if (renameJustFired) { renameJustFired = false; return; } showDevice(row.dataset.device); });
  $('#fleet-overview')?.addEventListener('click', event => { const row = event.target.closest('[data-device]'); if (row) { if (renameJustFired) { renameJustFired = false; return; } showDevice(row.dataset.device); } });
  /* 设备列表长按（600ms）→ 修改显示名称；长按后松手不触发进入详情 */
  let renameLongPress = null, renameDeviceId = '', renameJustFired = false;
  ($('#device-list') || $('#fleet-overview'))?.addEventListener('touchstart', event => {
    const row = event.target.closest('[data-device]');
    if (!row || state.view !== 'overview') return;
    const device = state.devices.find(d => d.device_id === row.dataset.device);
    if (!device) return;
    renameDeviceId = row.dataset.device;
    renameLongPress = setTimeout(() => {
      renameJustFired = true;
      setTimeout(() => { renameJustFired = false; }, 1000);
      state.selected = renameDeviceId;
      openEditDialog('设备显示名称', `<label>显示名称<input name="name" maxlength="64" required value="${escapeHtml(device.display_name || '')}" placeholder="${escapeHtml(device.model || device.device_id)}"></label>`, async form => { await renameDevice(formValue(form, 'name')); return true; }, { kicker: 'DEVICE NAME', help: '只修改当前账号中的显示名称，不会改动路由器系统主机名。' });
    }, 600);
  }, { passive: true });
  ['touchmove', 'touchend', 'touchcancel'].forEach(type => document.addEventListener(type, () => { clearTimeout(renameLongPress); renameLongPress = null; }, { passive: true }));
  $('#bind-pair-button').addEventListener('click', startManualDiscovery);
  $('#toggle-devices')?.addEventListener('click', () => {
    state.devicesCollapsed = !state.devicesCollapsed;
    const body = $('#devices-body'), btn = $('#toggle-devices');
    if (body) body.hidden = state.devicesCollapsed;
    if (btn) { btn.textContent = state.devicesCollapsed ? '展开' : '收起'; btn.setAttribute('aria-expanded', String(!state.devicesCollapsed)); }
  });
  $('#device-back')?.addEventListener('click', showOverview);
  $('#device-name-edit')?.addEventListener('click', () => openEditor('device-name'));
  window.addEventListener('hashchange', () => { const id = currentHashDevice(); if (id) showDevice(id); else showOverview(); });
  $('#device-nav')?.addEventListener('click', event => {
    const btn = event.target.closest('[data-dtab]');
    if (!btn || btn.dataset.dtab === state.dtab) return;
    state.dtab = btn.dataset.dtab;
    $$('#device-nav [data-dtab]').forEach(item => item.classList.toggle('active', item === btn));
    if (state.dtab === 'system') startCurve(); else stopCurve();
    renderDeviceTab();
  });
  document.addEventListener('change', event => {
    const notify = event.target.closest('[data-notify-toggle]');
    if (!notify || !state.selected) return;
    const enabled = notify.checked ? 1 : 0;
    notify.disabled = true;
    api(`/api/devices/${encodeURIComponent(state.selected)}/notify`, { method: 'POST', body: JSON.stringify({ enabled }) })
      .then(() => { showToast(enabled ? '已开启该设备离线/上线提醒' : '已关闭该设备离线/上线提醒', 'success'); refreshDevices(); })
      .catch(error => { notify.checked = !notify.checked; showToast(error.message, 'error'); })
      .finally(() => { notify.disabled = false; });
  });

  /* iStore 应用即时筛选（不重建 DOM，避免输入被踢） */
  $('#device-tab-content').addEventListener('input', event => {
    const box = event.target.closest('#market-query');
    if (!box) return;
    const q = String(box.value || '').trim().toLowerCase();
    document.querySelectorAll('#device-tab-content .market-card').forEach(card => {
      card.hidden = q && card.textContent.toLowerCase().indexOf(q) < 0;
    });
  });

  /* 图标加载失败 → 事件代理兑底成首字母（比内联 onerror 稳，兼容 Android WebView） */
  document.addEventListener('error', event => {
    const img = event.target;
    if (img && img.tagName === 'IMG' && img.dataset && img.dataset.appFallback !== undefined) {
      const span = document.createElement('span');
      span.className = 'active-app-fallback';
      span.textContent = img.dataset.appFallback || '?';
      if (img.parentNode) img.parentNode.replaceChild(span, img);
    }
  }, true);

  /* 设备详情页内容区的事件代理 */
  $('#device-tab-content').addEventListener('click', async event => {
    const meshAdd = event.target.closest('[data-mesh-add]');
    if (meshAdd) return addMeshDevice(meshAdd);
    if (event.target.closest('[data-agent-update]')) {
      if (!window.confirm('确认更新当前 Agent？更新包会先校验 SHA-256 和签名。')) return;
      return sendCommand('agent.update', {}, false);
    }
    if (event.target.closest('[data-unbind-open]')) return openUnbindDialog();
    if (event.target.closest('[data-reboot-device]')) return openRebootDialog();
    const labelBtn = event.target.closest('[data-client-label]');
    if (labelBtn) return openClientLabelDialog(labelBtn.dataset.clientLabel, labelBtn.dataset.clientHost);
    const client = event.target.closest('[data-client-command]');
    if (client) { const mac = client.dataset.mac; if (client.dataset.clientCommand === 'block') return sendCommand('client.block', { mac, blocked: 1 }); if (client.dataset.clientCommand === 'wake') return sendCommand('client.wake', { mac }); return openLimitDialog(mac); }
    const command = event.target.closest('[data-command]')?.dataset.command;
    if (!command) return;
    return commandFromControls(command, event.target);
  });
  /* 插件 / 市场 / 设置 tab 的交互（代理在 device-tab-content 上） */
  $('#device-tab-content').addEventListener('click', event => {
    const device = state.devices.find(item => item.device_id === state.selected);
    if (!device) return;
    const oafDel = event.target.closest('[data-oaf-del]');
    if (oafDel) return sendCommand('oaf.del_user', { mac: oafDel.dataset.oafDel }).then(() => commandFromControls('oaf-list-users'));
    const toggle = event.target.closest('[data-toggle-packages]')?.dataset.togglePackages;
    if (toggle) { if (toggle === 'apps') state.appsOpen = !state.appsOpen; else state.installedOpen = !state.installedOpen; return renderPackages(device); }
    if (event.target.closest('[data-market-open]')) { state.marketOpen = true; renderPackages(device); return loadMarket(); }
    if (event.target.closest('[data-istore-app]')) return sendCommand('istore.install', { app: event.target.closest('[data-istore-app]').dataset.istoreApp });
    if (event.target.closest('[data-plugin-settings]')) return openPluginEditor(event.target.closest('.app-card')?.dataset.appId);
    const plugin = event.target.closest('[data-plugin-app]');
    if (plugin) { const enabled = plugin.dataset.enabled !== '1'; return sendCommand('plugin.service.set', { app: plugin.dataset.pluginApp, enabled: enabled ? 1 : 0, running: enabled ? 1 : 0 }); }
    const edit = event.target.closest('[data-edit]');
    if (edit) return openEditor(edit.dataset.edit, edit);
  });
  $$('.nav-item').forEach(item => item.addEventListener('click', () => { $$('.nav-item').forEach(nav => nav.classList.toggle('active', nav === item)); }));

  async function loadMarket() {
    if (!state.selected || !state.marketOpen) { state.market = []; state.marketError = ''; return; }
    try {
      const data = await api(`/api/istore?device_id=${encodeURIComponent(state.selected)}`);
      state.market = data.items || []; state.marketError = ''; renderDevice();
    } catch (error) { state.market = []; state.marketError = error.message; renderDevice(); }
  }
  async function loadFooter() {
    try {
      const response = await fetch('/api/healthz', { cache: 'no-store', headers: { Accept: 'application/json' } });
      const data = await response.json();
      const el = $('#footer-version');
      if (el && data && data.version) {
        const env = window.GWRTNative ? 'App' : 'Web';
        el.textContent = `GWRT Control v${data.version} · ${env} 环境 · 构建 ${data.build_time || '未知'}`;
      }
    } catch (_) { /* footer 仅是辅助信息，失败时静默 */ }
  }
  window.gwrtNativeQr = payload => claimPair(payload, '扫码设备');
  window.gwrtNativeQrError = message => { finishDiscovery(); setPairStatus(String(message || '扫码失败'), true); };
  window.gwrtNativeDiscovery = payload => {
    finishDiscovery();
    let data;
    try { data = typeof payload === 'string' ? JSON.parse(payload) : payload; } catch (_) { data = { ok: false, error: '本地发现返回了无效数据' }; }
    if (!data?.ok) {
      setPairStatus((data?.error || '当前网络没有发现 GWRT 路由器') + '，正在打开扫码…', true);
      const bridge = nativeBridge();
      if (bridge && typeof bridge.scanPairCode === 'function') bridge.scanPairCode();
      return;
    }
    if (state.devices.some(item => item.device_id === data.device_id)) {
      setPairStatus(`${data.device_id} 已绑定，无需重复添加。`);
      return;
    }
    // 发现结果必须用户确认后才绑定，防止无关设备静默进入账号
    showPairConfirm(data);
  };
  window.gwrtNativeLocalResult = payload => { let data; try { data = typeof payload === 'string' ? JSON.parse(payload) : payload; } catch (_) { data = { ok: false, error: '本地返回无效数据' }; } if (data?.ok) { setPairStatus('WAN 本地配置已提交。'); showToast('WAN 已通过当前局域网应用'); } else showToast(data?.error || 'WAN 本地配置失败', 'error'); };
  window.gwrtNativeUpdateResult = payload => { try { const data = typeof payload === 'string' ? JSON.parse(payload) : payload; showToast(data?.message || '更新下载失败', data?.ok ? 'success' : 'error'); } catch (_) { showToast('更新下载失败', 'error'); } };
  // 只读设备（其他账号绑定 / 未绑定）的兜底拦截：捕获阶段拦下所有操作交互
  const isReadonlyView = () => {
    if (state.view !== 'device' || !state.selected) return false;
    const device = state.devices.find(d => d.device_id === state.selected);
    return Boolean(device && device.can_manage === false);
  };
  document.addEventListener('click', event => {
    if (!isReadonlyView()) return;
    const target = event.target && event.target.closest ? event.target.closest('button, [role="button"], [data-action], input[type="checkbox"]') : null;
    if (!target || target.closest('.device-nav') || target.closest('#device-back')) return;
    event.preventDefault();
    event.stopPropagation();
    showToast('该设备由其他账号绑定，仅可查看状态', 'error');
  }, true);
  document.addEventListener('keydown', event => {
    if (event.key !== 'Enter' || !isReadonlyView()) return;
    if (event.target && event.target.closest && event.target.closest('#device-view')) {
      event.preventDefault();
      event.stopPropagation();
      showToast('该设备由其他账号绑定，仅可查看状态', 'error');
    }
  }, true);
  $('#pair-confirm-form').addEventListener('submit', async event => {
    event.preventDefault();
    $('#pair-confirm-dialog').close();
    const pair = pendingPair;
    pendingPair = null;
    if (pair) claimPair(pair, '本地路由器');
  });
  $('#pair-confirm-dialog [data-pair-cancel]').addEventListener('click', () => {
    $('#pair-confirm-dialog').close();
    pendingPair = null;
    setPairStatus('已取消绑定，设备未添加到账号。');
  });
  $('#bind-pair-button').disabled = false;
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { clearInterval(state.timer); state.timer = null; }
    else if (state.user) { refreshDevices().catch(() => {}); startRefreshTimer(); }
  });
  loadFooter();
  loadOuiDb();
  refreshCaptcha();
  setTimeout(() => checkAppUpdate(), 800);
  (async () => { try { const data = await api('/api/me'); state.csrf = data.csrf; setLoggedIn(data.user); await loadSettings(); await refreshDevices(); loadWeather(); startRefreshTimer(); } catch (_) { setLoggedIn(null); } })();
})();
