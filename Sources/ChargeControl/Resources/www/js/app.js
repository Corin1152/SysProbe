/* ══════════════════════════════════════════════════════════
   ChargeLimiter 前端 · 重写版逻辑
   ──────────────────────────────────────────────────────────
   与原版的契约完全一致，所以 ui.mm / daemon 一行都不用改：
     · 通信：POST /bridge，body 是 JSON，含 api 字段
     · 响应：{status:0, data:{...}} —— 回调拿到的是整个响应对象
     · 7 个 API：get_conf / set_conf / reset_conf / get_bat_info
                / set_charge_status / set_inflow_status / get_statistics

   与原版的差别只在「界面这一层」：
     · 去掉 jQuery / Vue / Element UI —— 用原生 DOM
     · 去掉浮窗、快速充电、历史统计、电源信息、系统信息
     · 语言跟随系统，**不写 localStorage**（原版会缓存，导致改不回系统语言）
   ══════════════════════════════════════════════════════════ */

(function () {
  'use strict';

  /* ── 通信 ─────────────────────────────────────────── */

  // 回调注册表：daemon 的响应里带 callback 名字，用字符串取函数（沿用原版约定）
  var CB = {};

  function ipcSend(req, onDone) {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/bridge', true);
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.timeout = 3000;
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return;
      var ok = xhr.status === 200;
      if (ok) {
        var data = null;
        try { data = JSON.parse(xhr.responseText); } catch (e) { data = null; }
        if (data) {
          // 原版约定：req.callback 指向一个全局函数名，由前端自己调用
          if (req.callback) {
            var fn = CB[req.callback];
            if (fn) fn(data);
          }
          if (onDone) onDone(true, data);
          return;
        }
      }
      if (onDone) onDone(false, null);
    };
    xhr.ontimeout = function () { if (onDone) onDone(false, null); };
    xhr.send(JSON.stringify(req));
  }

  function setConf(key, val) { ipcSend({ api: 'set_conf', key: key, val: val }); }

  /* ── 文案（跟随系统，不缓存）──────────────────────── */

  var LANG = 'zh_CN';
  var TEXT = {};

  function detectLang() {
    var l = (navigator.language || 'zh').toLowerCase();
    if (l.indexOf('zh') === 0) return l.indexOf('tw') > 0 || l.indexOf('hk') > 0 ? 'zh_TW' : 'zh_CN';
    if (l.indexOf('vi') === 0) return 'vi';
    if (l.indexOf('ar') === 0) return 'ar';
    return 'en';
  }

  function t(key) { return TEXT[key] !== undefined ? TEXT[key] : key; }

  function applyText() {
    var nodes = document.querySelectorAll('[data-i18n]');
    for (var i = 0; i < nodes.length; i++) {
      var k = nodes[i].getAttribute('data-i18n');
      if (TEXT[k] !== undefined) nodes[i].textContent = TEXT[k];
    }
  }

  /* ── 配置项定义 ───────────────────────────────────── */

  // 键名与原版**完全一致** —— 这样文案表能直接复用作者维护的 5 语言译文。
  // 值也与原版一致：原版 action 用空串表示「不动作」，mode 只有这两种。
  var MODES = [
    { v: 'charge_on_plug', k: 'charge_on_plug', d: 'charge_on_plug_desc' },
    { v: 'edge_trigger',   k: 'edge_trigger',   d: 'edge_trigger_desc' }
  ];
  var FREQS = [1, 2, 3, 5, 10, 30];
  var ACTIONS = [
    { v: '',     k: 'none' },
    { v: 'noti', k: 'noti' }
  ];
  // 热模拟与 PPM 共用同一组档位 —— 原版里它们指向的就是同一个 cuffmods 数组
  var CUFF_MODES = ['off', 'nominal', 'light', 'moderate', 'heavy'];

  var conf = {};   // 本地缓存的配置

  function labelOf(list, v, fallback) {
    for (var i = 0; i < list.length; i++) {
      if (list[i].v === v) return t(list[i].k);
    }
    return fallback !== undefined ? fallback : String(v);
  }

  /* ── 渲染：充电控制页 ─────────────────────────────── */

  function el(id) { return document.getElementById(id); }

  function setSwitch(node, on, disabled) {
    if (!node) return;
    node.className = 'sw' + (node.id === 'sw-temp' ? ' accent' : '') +
                     (on ? ' on' : '') + (disabled ? ' dis' : '');
  }

  function renderConf() {
    setSwitch(el('sw-enable'), !!conf.enable);
    setSwitch(el('sw-temp'), !!conf.enable_temp);
    setSwitch(el('sw-smart'), !!conf.adv_prefer_smart);
    setSwitch(el('sw-inhibit'), !!conf.adv_predictive_inhibit_charge);
    setSwitch(el('sw-inflow'), !!conf.adv_disable_inflow);
    setSwitch(el('sw-limit'), !!conf.adv_limit_inflow);

    var mode = null;
    for (var i = 0; i < MODES.length; i++) if (MODES[i].v === conf.mode) mode = MODES[i];
    el('val-mode').textContent = mode ? t(mode.k) : (conf.mode || '—');
    el('hint-mode').textContent = mode ? t(mode.d) : '';

    el('val-freq').textContent = conf.update_freq ? (conf.update_freq + ' s') : '—';
    el('val-action').textContent = labelOf(ACTIONS, conf.action);

    el('val-below').textContent = fmtPct(conf.charge_below);
    el('val-above').textContent = fmtPct(conf.charge_above);
    el('rg-below').value = conf.charge_below || 20;
    el('rg-above').value = conf.charge_above || 80;

    el('val-tstop').textContent = fmtDeg(conf.charge_temp_above);
    el('val-tstart').textContent = fmtDeg(conf.charge_temp_below);
    el('rg-tstop').value = conf.charge_temp_above || 40;
    el('rg-tstart').value = conf.charge_temp_below || 35;

    // 档位文案直接复用原版的键（off / nominal / light / moderate / heavy）。
    // 原版这两个值默认为空串，空串按 off 显示 —— 否则那一行会是空白。
    el('val-thermal').textContent = cuffLabel(conf.adv_def_thermal_mode);
    el('val-ppm').textContent = cuffLabel(conf.ppm_simulate_mode);
  }

  function cuffLabel(v) {
    var value = v || 'off';
    for (var i = 0; i < CUFF_MODES.length; i++) {
      if (CUFF_MODES[i] === value) return t(value);
    }
    return t('off');
  }

  function fmtPct(v) { return (v === undefined || v === null) ? '—' : (v + '%'); }
  function fmtDeg(v) { return (v === undefined || v === null) ? '—' : (v + '°'); }

  /* ── 渲染：电池信息页 ─────────────────────────────── */

  function pct(a, b) { return (!b) ? 0 : Math.max(0, Math.min(100, Math.round(a / b * 100))); }

  function tempColor(c) {
    if (c < 28) return 'var(--t-cold)';
    if (c < 34) return 'var(--t-cool)';
    if (c < 39) return 'var(--t-warm)';
    if (c < 44) return 'var(--t-hot)';
    return 'var(--t-veryhot)';
  }

  function renderBat(d) {
    if (!d) return;
    var cap = d.CurrentCapacity, max = d.NominalChargeCapacity;
    var health = pct(max, d.DesignCapacity);

    el('bar-cap').style.width = pct(cap, 100) + '%';
    el('txt-cap').textContent = fmtPct(cap);
    el('bar-cap').style.background = 'var(--battery)';

    el('bar-health').style.width = health + '%';
    el('txt-health').textContent = health + '%';
    el('bar-health').style.background = 'var(--accent)';

    // Temperature 是**百分之一摄氏度**，不是摄氏度 —— 守护进程自己也是 /100 用的
    // （见 daemon.mm 里 `temperature_.intValue / 100.0`）。忘了除就会出现
    // 「3500 °C」这种读数，而且温度条的配色阈值（28/34/39/44）也会全部判成最高档。
    var tc = d.Temperature / 100;
    el('bar-temp').style.width = Math.min(100, (tc / 50) * 100) + '%';
    el('txt-temp').textContent = (d.Temperature === undefined ? '—' : tc.toFixed(1) + '°C');
    el('bar-temp').style.background = tempColor(tc);

    setSwitch(el('sw-charging'), !!d.IsCharging);
    setSwitch(el('sw-installed'), !!d.BatteryInstalled, true);

    el('v-cycle').textContent = d.CycleCount !== undefined ? d.CycleCount : '—';
    el('v-design').textContent = d.DesignCapacity !== undefined ? d.DesignCapacity + ' mAh' : '—';
    el('v-nominal').textContent = max !== undefined ? max + ' mAh' : '—';
    el('v-amp').textContent = d.Amperage !== undefined ? d.Amperage + ' mA' : '—';
    el('v-bootv').textContent = d.BootVoltage !== undefined ? (d.BootVoltage / 1000).toFixed(2) + ' V' : '—';
    el('v-volt').textContent = d.Voltage !== undefined ? (d.Voltage / 1000).toFixed(2) + ' V' : '—';
    el('v-serial').textContent = d.Serial || '—';

    if (d.UpdateTime) {
      var dt = new Date(d.UpdateTime * 1000);
      el('foot-update').textContent = t('UpdateAt') + ' ' + dt.toLocaleTimeString();
    }
  }

  /* ── 弹层选择器 ───────────────────────────────────── */

  var sheetPick = null;

  function openSheet(title, items, current, onPick) {
    el('sheet-title').textContent = title;
    var box = el('sheet-list');
    box.innerHTML = '';
    items.forEach(function (it) {
      var row = document.createElement('div');
      row.className = 'sheet-item';
      var label = document.createElement('span');
      label.textContent = it.label;
      row.appendChild(label);
      if (it.value === current) {
        var tick = document.createElement('span');
        tick.className = 'tick';
        tick.textContent = '✓';
        row.appendChild(tick);
      }
      row.onclick = function () { closeSheet(); onPick(it.value); };
      box.appendChild(row);
    });
    sheetPick = onPick;
    el('sheet').className = 'sheet on';
  }

  function closeSheet() { el('sheet').className = 'sheet'; sheetPick = null; }

  /* ── 事件绑定 ─────────────────────────────────────── */

  function bindTabs() {
    var tabs = document.querySelectorAll('.tab');
    for (var i = 0; i < tabs.length; i++) {
      tabs[i].onclick = function () {
        var name = this.getAttribute('data-tab');
        var all = document.querySelectorAll('.tab');
        for (var j = 0; j < all.length; j++) all[j].className = 'tab';
        this.className = 'tab on';
        var panes = document.querySelectorAll('.pane');
        for (var k = 0; k < panes.length; k++) panes[k].className = 'pane';
        el('pane-' + name).className = 'pane on';
        window.scrollTo(0, 0);
      };
    }
  }

  function bindSwitches() {
    function toggle(id, key) {
      el(id).onclick = function () {
        var on = this.className.indexOf('on') < 0;
        setSwitch(this, on);
        conf[key] = on ? 1 : 0;
        setConf(key, on ? 1 : 0);
      };
    }
    toggle('sw-enable', 'enable');
    toggle('sw-temp', 'enable_temp');
    toggle('sw-smart', 'adv_prefer_smart');
    toggle('sw-inhibit', 'adv_predictive_inhibit_charge');
    toggle('sw-inflow', 'adv_disable_inflow');
    toggle('sw-limit', 'adv_limit_inflow');

    // 「正在充电」是即时动作，不是配置项 —— 走 set_charge_status
    el('sw-charging').onclick = function () {
      var on = this.className.indexOf('on') < 0;
      setSwitch(this, on);
      ipcSend({ api: 'set_charge_status', flag: on ? 1 : 0 });
    };
  }

  function bindSliders() {
    function slider(id, key, out, unit) {
      var node = el(id);
      node.oninput = function () { el(out).textContent = this.value + unit; };
      node.onchange = function () {
        conf[key] = parseInt(this.value, 10);
        setConf(key, conf[key]);
      };
    }
    slider('rg-below', 'charge_below', 'val-below', '%');
    slider('rg-above', 'charge_above', 'val-above', '%');
    slider('rg-tstop', 'charge_temp_above', 'val-tstop', '°');
    slider('rg-tstart', 'charge_temp_below', 'val-tstart', '°');
  }

  function bindPickers() {
    el('row-mode').onclick = function () {
      openSheet(t('mode'), MODES.map(function (m) {
        return { label: t(m.k), value: m.v };
      }), conf.mode, function (v) {
        conf.mode = v;
        setConf('mode', v);
        renderConf();
      });
    };
    el('row-freq').onclick = function () {
      // 值统一用数字：openSheet 里是严格比较（===），字符串和数字比不出相等，
      // 那样当前项就不会打勾。
      openSheet(t('update_freq'), FREQS.map(function (v) {
        return { label: v + ' s', value: v };
      }), Number(conf.update_freq), function (v) {
        conf.update_freq = v;
        setConf('update_freq', v);
        renderConf();
      });
    };
    el('row-action').onclick = function () {
      openSheet(t('action'), ACTIONS.map(function (a) {
        return { label: t(a.k), value: a.v };
      }), conf.action, function (v) {
        conf.action = v;
        setConf('action', v);
        renderConf();
      });
    };
    // 热模拟与 PPM 用同一组档位（原版如此），所以抽成一个函数
    function cuffSheet(titleKey, current, onPick) {
      openSheet(t(titleKey), CUFF_MODES.map(function (v) {
        return { label: t(v), value: v };
      }), current || 'off', onPick);
    }
    el('row-thermal').onclick = function () {
      cuffSheet('adv_thermal_simulate', conf.adv_def_thermal_mode, function (v) {
        conf.adv_def_thermal_mode = v;
        setConf('adv_def_thermal_mode', v);
        renderConf();
      });
    };
    el('row-ppm').onclick = function () {
      cuffSheet('adv_ppm_simulate', conf.ppm_simulate_mode, function (v) {
        conf.ppm_simulate_mode = v;
        setConf('ppm_simulate_mode', v);
        renderConf();
      });
    };
    el('row-reset').onclick = function () {
      openSheet(t('reset'), [
        { label: t('reset_confirm'), value: 'yes' }
      ], null, function () {
        ipcSend({ api: 'reset_conf' }, function () { loadConf(); });
      });
    };
    el('sheet').onclick = function (e) {
      if (e.target === this) closeSheet();
    };
    document.querySelector('.sheet-cancel').onclick = closeSheet;
  }

  /* ── 轮询 ─────────────────────────────────────────── */

  var offline = false;

  function loadConf() {
    ipcSend({ api: 'get_conf' }, function (ok, res) {
      if (!ok || !res || !res.data) { markOffline(); return; }
      conf = res.data;
      renderConf();
      clearOffline();
    });
  }

  function pollBat() {
    ipcSend({ api: 'get_bat_info' }, function (ok, res) {
      if (!ok || !res || !res.data) { markOffline(); return; }
      renderBat(res.data);
      clearOffline();
    });
  }

  function markOffline() {
    if (offline) return;
    offline = true;
    toast(t('service_offline'));
  }

  function clearOffline() { offline = false; }

  var toastTimer = null;
  function toast(msg) {
    var node = el('toast');
    node.textContent = msg;
    node.className = 'toast on';
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { node.className = 'toast'; }, 2600);
  }

  /* ── 启动 ─────────────────────────────────────────── */

  function boot() {
    LANG = detectLang();
    // 拉文案表（跟随系统语言，不写 localStorage）
    var xhr = new XMLHttpRequest();
    xhr.open('GET', 'lang.json', true);
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== 4) return;
      try {
        var all = JSON.parse(xhr.responseText);
        TEXT = all[LANG] || all.en || {};
      } catch (e) { TEXT = {}; }
      applyText();
      renderConf();
    };
    xhr.send();

    bindTabs();
    bindSwitches();
    bindSliders();
    bindPickers();

    loadConf();
    pollBat();
    setInterval(pollBat, 1000);
    setInterval(loadConf, 5000);   // 配置偶尔同步一次即可（可能被快捷指令改）
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
