// Общие функции интерфейса хаба AIRL (браузер). Без библиотек: шапка, форматирование,
// запросы к API, состояния экрана, графики SVG, service worker с плашкой обновления.
'use strict';

const AIRL = (() => {
  // Папка общих файлов этого сервиса (/assets/ у хаба, /<id>/assets/ у сервиса отдела).
  const ASSETS = (document.currentScript && new URL('.', document.currentScript.src).pathname) || '/assets/';
  const nbsp = ' ';
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const intl = new Intl.NumberFormat('ru-RU', { maximumFractionDigits: 0 });
  const intl1 = new Intl.NumberFormat('ru-RU', { maximumFractionDigits: 1, minimumFractionDigits: 1 });
  const CUR = { KZT: '₸', UZS: 'сум' };

  function fmtValue(v, unit) {
    if (v === null || v === undefined || Number.isNaN(Number(v))) return '—';
    const n = Number(v);
    if (unit === '%') return intl1.format(n) + nbsp + '%';
    if (CUR[unit]) return intl.format(Math.round(n)) + nbsp + CUR[unit];
    return intl.format(n) + (unit ? nbsp + unit : '');
  }
  const fmtMoney = (v) => fmtValue(v, 'KZT');
  function fmtShort(v) { // для осей графиков: 48,3 млн
    const n = Number(v); const a = Math.abs(n);
    if (a >= 1e9) return (n / 1e9).toFixed(1).replace('.', ',') + ' млрд';
    if (a >= 1e6) return (n / 1e6).toFixed(1).replace('.', ',') + ' млн';
    if (a >= 1e3) return Math.round(n / 1e3) + ' тыс';
    return String(Math.round(n));
  }
  function fmtTime(iso) {
    try { return new Date(iso).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Almaty' }); } catch { return ''; }
  }

  // Изменение к прошлому периоду: для «меньше — лучше» рост — красный.
  function delta(cur, prev, { lowerIsBetter = false, unit = '' } = {}) {
    if (cur === null || prev === null || cur === undefined || prev === undefined) return '<span class="delta flat">нет сравнения</span>';
    let txt; let dir;
    if (unit === '%') { const d = cur - prev; txt = (d >= 0 ? '+' : '−') + intl1.format(Math.abs(d)) + ' п.п.'; dir = d; }
    else if (prev === 0) { return '<span class="delta flat">было 0</span>'; }
    else { const d = (cur - prev) / Math.abs(prev) * 100; txt = (d >= 0 ? '+' : '−') + intl1.format(Math.abs(d)) + '%'; dir = d; }
    const good = lowerIsBetter ? dir < 0 : dir > 0;
    const cls = Math.abs(dir) < 0.05 ? 'flat' : (good ? 'up' : 'down');
    const arrow = dir > 0 ? '▲' : dir < 0 ? '▼' : '•';
    return `<span class="delta ${cls}"><span aria-hidden="true">${arrow}</span> ${txt}</span>`;
  }

  async function api(path, opts = {}) {
    const r = await fetch(path, { credentials: 'same-origin', headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, ...opts });
    if (r.status === 401) {
      location.href = '/login?next=' + encodeURIComponent(location.pathname + location.hash);
      throw new Error('Нужен вход');
    }
    let body = {};
    try { body = await r.json(); } catch { /* пустой ответ */ }
    if (!r.ok) { const e = new Error(body.error || `Ошибка ${r.status}`); e.status = r.status; throw e; }
    return body;
  }
  const post = (path, data) => api(path, { method: 'POST', body: JSON.stringify(data || {}) });

  async function logout() {
    try { await fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' }); } catch { /* нет сети */ }
    try { for (const k of await caches.keys()) await caches.delete(k); } catch { /* нет кэшей */ }
    try { if (indexedDB.databases) for (const d of await indexedDB.databases()) indexedDB.deleteDatabase(d.name); } catch { /* нет IndexedDB */ }
    try { sessionStorage.clear(); localStorage.clear(); } catch { /* приватный режим */ }
    location.href = '/login';
  }

  // Шапка хаба: логотип (в хаб), название сервиса, переключатель отделов, пользователь, выход.
  async function topbar(serviceTitle, currentId) {
    const me = await api('/auth/me');
    const el = document.getElementById('topbar');
    const opts = me.services.map((s) => `<option value="${esc(s.base_path)}/" ${s.id === currentId ? 'selected' : ''}>${esc(s.title)}</option>`).join('');
    el.className = 'topbar';
    el.innerHTML = `
      <a class="logo" href="/" aria-label="AIRL — хаб руководителя"><img src="${ASSETS}logo-airl-white.png" alt="AIRL" width="69" height="22"></a>
      <span class="svc">${esc(serviceTitle)}</span>
      <span class="spacer"></span>
      ${me.services.length > 1 ? `<label class="sr-only" for="svc-switch">Отдел</label><select id="svc-switch" aria-label="Перейти в отдел">${opts}</select>` : ''}
      <span class="user" title="${esc(me.name)}"><span class="name">${esc(me.name)}</span><span class="role">${esc(me.role)}</span></span>
      <button class="logout" type="button">Выйти</button>`;
    el.querySelector('.logout').addEventListener('click', logout);
    const sw = el.querySelector('#svc-switch');
    if (sw) sw.addEventListener('change', () => { location.href = sw.value; });
    return me;
  }

  function nav(items, current) {
    return items.map((i) => i.group ? `<div class="group">${esc(i.group)}</div>`
      : `<a href="${esc(i.href)}" ${i.id === current ? 'aria-current="page"' : ''}>${esc(i.title)}</a>`).join('');
  }

  const loading = (n = 4) => `<div class="kpis" aria-busy="true" aria-label="Загрузка">${'<div class="skeleton"></div>'.repeat(n)}</div>`;
  const empty = (text) => `<div class="state">${esc(text)}</div>`;
  const errorBox = (text) => `<div class="state error" role="alert">${esc(text)} <br><button class="btn small secondary js-reload" type="button">Обновить</button></div>`;

  function kpiCard(m, { lowerIsBetter = false, sub = '' } = {}) {
    return `<div class="kpi ${esc(m.status)}" data-metric="${esc(m.id || m.metric_id)}">
      <div class="l">${esc(m.title)}</div>
      <div class="v" data-value="${esc(m.value)}">${fmtValue(m.value, m.unit)}</div>
      ${delta(m.value, m.prev_value ?? (m.compare ? m.compare.value : null), { lowerIsBetter, unit: m.unit })}
      <div class="s">${esc(sub)}</div></div>`;
  }

  // Столбчатый график: series = [{label, value, cls?}]
  function barChart(series, { height = 220, fmt = fmtShort } = {}) {
    const W = 640; const H = height; const L = 56; const B = 26; const T = 10; const R = 8;
    const vals = series.map((s) => Number(s.value) || 0);
    const max = Math.max(1, ...vals); const min = Math.min(0, ...vals);
    const span = max - min || 1;
    const y = (v) => T + (H - T - B) * (1 - (v - min) / span);
    const bw = (W - L - R) / Math.max(1, series.length);
    const ticks = [0, 0.5, 1].map((k) => min + span * k);
    let svg = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="График">`;
    for (const t of ticks) svg += `<line class="grid" x1="${L}" x2="${W - R}" y1="${y(t)}" y2="${y(t)}"/><text class="axis" x="${L - 6}" y="${y(t) + 4}" text-anchor="end">${esc(fmt(t))}</text>`;
    const every = Math.ceil(series.length / 12);
    series.forEach((s, i) => {
      const v = Number(s.value) || 0; const x = L + i * bw + bw * 0.15; const top = y(Math.max(v, 0)); const h = Math.abs(y(v) - y(0));
      svg += `<rect class="bar ${s.cls || ''}" x="${x}" y="${top}" width="${bw * 0.7}" height="${Math.max(h, 1)}" rx="4"><title>${esc(s.label)}: ${esc(s.title || fmt(v))}</title></rect>`;
      if (i % every === 0 || i === series.length - 1) svg += `<text class="axis" x="${x + bw * 0.35}" y="${H - 8}" text-anchor="middle">${esc(s.label)}</text>`;
    });
    return svg + '</svg>';
  }

  function hbars(rows, { fmt = fmtMoney } = {}) {
    const max = Math.max(1, ...rows.map((r) => Number(r.value) || 0));
    return rows.map((r) => `<div class="hbar"><span>${esc(r.label)}</span><span class="track"><span class="fill ${r.cls || ''}" data-w="${(100 * (Number(r.value) || 0) / max).toFixed(1)}"></span></span><span class="num r">${esc(fmt(r.value))}</span></div>`).join('');
  }

  // Service worker сервиса + плашка «Доступна новая версия · Обновить».
  function registerSW(scope) {
    if (!('serviceWorker' in navigator)) return;
    navigator.serviceWorker.register(scope + 'sw.js', { scope }).then((reg) => {
      // Плашка — только при обновлении уже установленной версии этого сервиса, не при первой установке
      // (страницу сервиса может контролировать service worker оболочки хаба со scope «/»).
      const hadActive = !!reg.active;
      reg.addEventListener('updatefound', () => {
        const nw = reg.installing;
        nw.addEventListener('statechange', () => {
          if (nw.state === 'installed' && hadActive) {
            const bar = document.createElement('div');
            bar.className = 'update-bar';
            bar.innerHTML = '<span>Доступна новая версия</span><button type="button">Обновить</button>';
            bar.querySelector('button').onclick = () => { nw.postMessage('skipWaiting'); location.reload(); };
            document.body.appendChild(bar);
          }
        });
      });
    }).catch(() => {});
    const off = () => {
      if (document.querySelector('.offline-bar')) return;
      const b = document.createElement('div'); b.className = 'offline-bar'; b.setAttribute('role', 'status');
      b.textContent = 'Нет сети — показаны последние загруженные данные'; document.body.appendChild(b);
    };
    window.addEventListener('offline', off);
    window.addEventListener('online', () => { const b = document.querySelector('.offline-bar'); if (b) b.remove(); });
    if (!navigator.onLine) off();
  }

  // CSP без 'unsafe-inline': ширины полос ставим через CSSOM, а не атрибутом style.
  function applyWidths(root = document) {
    root.querySelectorAll('[data-w]').forEach((e) => { e.style.width = e.dataset.w + '%'; });
  }
  document.addEventListener('click', (e) => { if (e.target.closest('.js-reload')) location.reload(); });

  return { applyWidths, esc, fmtValue, fmtMoney, fmtShort, fmtTime, delta, api, post, logout, topbar, nav, loading, empty, errorBox, kpiCard, barChart, hbars, registerSW };
})();
