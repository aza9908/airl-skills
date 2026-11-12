// Общие функции интерфейса хаба AIRL (браузер) в стиле «1С Hub». Без библиотек: шапка, заголовок
// «1С✦Hub», вкладки, форматирование, запросы к API, состояния экрана, графики SVG, service worker.
'use strict';

const AIRL = (() => {
  // Папка общих файлов этого сервиса (/assets/ у хаба, /<id>/assets/ у сервиса отдела).
  const ASSETS = (document.currentScript && new URL('.', document.currentScript.src).pathname) || '/assets/';
  const THIN = ' '; // узкий неразрывный пробел: «81 573 ₸»
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const intl = new Intl.NumberFormat('ru-RU', { maximumFractionDigits: 0 });
  const intl1 = new Intl.NumberFormat('ru-RU', { maximumFractionDigits: 1, minimumFractionDigits: 1 });
  const CUR = { KZT: '₸', UZS: 'сум' };
  const tidy = (s) => s.replace(/[   ]/g, THIN).replace(/^-/, '−');

  function fmtValue(v, unit) {
    if (v === null || v === undefined || v === '' || Number.isNaN(Number(v))) return '—';
    const n = Number(v);
    if (unit === '%') return tidy(intl1.format(n)) + '%';
    if (CUR[unit]) return tidy(intl.format(Math.round(n))) + THIN + CUR[unit];
    return tidy(intl.format(n)) + (unit ? THIN + unit : '');
  }
  // То же, но валюта/единица чуть мельче — для крупных цифр карточек.
  function fmtBig(v, unit) {
    const s = fmtValue(v, unit);
    const u = CUR[unit] || (unit === '%' ? '%' : unit);
    if (!u || s === '—' || !s.endsWith(u)) return esc(s);
    return `${esc(s.slice(0, s.length - u.length).replace(/ $/, ''))}${THIN}<span class="cur">${esc(u)}</span>`;
  }
  const fmtMoney = (v) => fmtValue(v, 'KZT');
  function fmtShort(v) { // для осей графиков: 48,3 млн
    const n = Number(v); const a = Math.abs(n);
    const f = (x) => tidy(x.toFixed(1).replace('.', ',').replace(/,0$/, ''));
    if (a >= 1e9) return f(n / 1e9) + THIN + 'млрд';
    if (a >= 1e6) return f(n / 1e6) + THIN + 'млн';
    if (a >= 1e3) return tidy(String(Math.round(n / 1e3))) + THIN + 'тыс';
    return tidy(String(Math.round(n)));
  }
  function fmtTime(iso) {
    try { return new Date(iso).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit', timeZone: 'Asia/Almaty' }); } catch { return ''; }
  }
  function fmtStamp(d = new Date()) {
    try {
      const day = d.toLocaleDateString('ru-RU', { day: '2-digit', month: '2-digit', timeZone: 'Asia/Almaty' });
      return `${day}, ${fmtTime(d)}`;
    } catch { return ''; }
  }
  const pad2 = (n) => String(n).padStart(2, '0');

  // Изменение к прошлому периоду: для «меньше — лучше» рост — красный.
  function delta(cur, prev, { lowerIsBetter = false, unit = '' } = {}) {
    if (cur === null || prev === null || cur === undefined || prev === undefined) return '<span class="delta flat">нет сравнения</span>';
    let txt; let dir;
    cur = Number(cur); prev = Number(prev);
    if (unit === '%') { const d = cur - prev; txt = (d >= 0 ? '+' : '−') + tidy(intl1.format(Math.abs(d))) + THIN + 'п.п.'; dir = d; }
    else if (prev === 0) { return '<span class="delta flat">было 0</span>'; }
    else { const d = (cur - prev) / Math.abs(prev) * 100; txt = (d >= 0 ? '+' : '−') + tidy(intl1.format(Math.abs(d))) + '%'; dir = d; }
    const good = lowerIsBetter ? dir < 0 : dir > 0;
    const cls = Math.abs(dir) < 0.05 ? 'flat' : (good ? 'up' : 'down');
    const arrow = dir > 0 ? '▲' : dir < 0 ? '▼' : '•';
    return `<span class="delta ${cls}"><span aria-hidden="true">${arrow}</span>${THIN}${txt}</span>`;
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

  const brandHtml = (tag = 'div') => `<${tag} class="brand" aria-label="1С Hub">1С<img src="${ASSETS}star-mark.svg" alt="" width="80" height="80">Hub</${tag}>`;

  // Шапка: чёрная «таблетка» (логотип | 1С Hub · переключатель отделов · «Обновлено» · Выйти)
  // и под ней большой заголовок «1С✦Hub» с моноширинной подписью справа.
  async function topbar(serviceTitle, currentId, { brandTag } = {}) {
    const me = await api('/auth/me');
    const el = document.getElementById('topbar');
    const opts = me.services.map((s) => `<option value="${esc(s.base_path)}/" ${s.id === currentId ? 'selected' : ''}>${esc(s.title)}</option>`).join('');
    el.className = 'topbar';
    el.innerHTML = `
      <a class="logo" href="/" aria-label="AIRL — 1С Hub"><img src="${ASSETS}logo-airl-white.png" alt="AI Research Labs" width="106" height="34"></a>
      <span class="divider" aria-hidden="true"></span>
      <span class="product">1С Hub</span>
      <span class="who" title="${esc(me.name)} · ${esc(me.role)}">${esc(me.name)} · ${esc(me.role)}</span>
      <span class="spacer"></span>
      ${me.services.length > 1 ? `<label class="sr-only" for="svc-switch">Отдел</label><select id="svc-switch" aria-label="Перейти в отдел">${opts}</select>` : ''}
      <span class="updated"><span>Обновлено</span><span id="updated-at">${esc(fmtStamp())}</span></span>
      <button class="logout" type="button" title="Выйти: ${esc(me.name)}">Выйти</button>`;
    el.querySelector('.logout').addEventListener('click', logout);
    const sw = el.querySelector('#svc-switch');
    if (sw) sw.addEventListener('change', () => { location.href = sw.value; });
    if (!document.querySelector('.masthead')) {
      const m = document.createElement('div');
      m.className = 'masthead';
      m.innerHTML = `${brandHtml(brandTag || 'div')}<p class="caption" id="caption">${esc(serviceTitle)} · сервис хаба AIRL · демо на синтетических данных</p>`;
      el.insertAdjacentElement('afterend', m);
    }
    return me;
  }
  function caption(text) { const c = document.getElementById('caption'); if (c) c.textContent = text; }
  function updated(d) { const u = document.getElementById('updated-at'); if (u) u.textContent = fmtStamp(d); }

  // Вкладки в белой «таблетке»; активная — чёрная.
  function nav(items, current) {
    return items.map((i) => i.group ? `<span class="group" aria-hidden="true"></span>`
      : `<a href="${esc(i.href)}" ${i.id === current ? 'aria-current="page"' : ''}${i.id ? ` data-tab="${esc(i.id)}"` : ''}>${esc(i.title)}</a>`).join('');
  }

  // Заголовок раздела: «01  Заголовок / моноширинная подпись» (+ элементы справа).
  function head(no, title, sub, right = '', tag = 'h1') {
    return `<div class="page-head"><span class="no">${esc(typeof no === 'number' ? pad2(no) : no || '')}</span><div><${tag}>${esc(title)}</${tag}>${sub ? `<div class="sub">${esc(sub)}</div>` : ''}</div>${right ? `<div class="right">${right}</div>` : '<span></span>'}</div>`;
  }

  const loading = (n = 4) => `<div class="kpis" aria-busy="true" aria-label="Загрузка">${'<div class="skeleton"></div>'.repeat(n)}</div>`;
  const empty = (text) => `<div class="state">${esc(text)}</div>`;
  const errorBox = (text) => `<div class="state error" role="alert">${esc(text)} <br><button class="btn small secondary js-reload" type="button">Обновить</button></div>`;

  function kpiCard(m, { lowerIsBetter = false, sub = '', cls = '' } = {}) {
    const prev = m.prev_value ?? (m.compare ? m.compare.value : null);
    const neg = Number(m.value) < 0 ? ' neg' : '';
    return `<div class="kpi ${esc(m.status || '')} ${cls}" data-metric="${esc(m.id || m.metric_id)}">
      <div class="l"><span>${esc(m.title)}</span><span class="dot" aria-hidden="true"></span></div>
      <div class="v${neg}" data-value="${esc(m.value)}">${fmtBig(m.value, m.unit)}</div>
      <div class="s">${sub ? esc(sub) + ' · ' : ''}${delta(m.value, prev, { lowerIsBetter, unit: m.unit })}</div></div>`;
  }
  // Карточка без показателя карты (модуль, прогноз): заголовок, крупная цифра, подпись.
  const statCard = (title, value, unit, sub, status = '') => `<div class="kpi ${esc(status)}"><div class="l"><span>${esc(title)}</span><span class="dot" aria-hidden="true"></span></div>
      <div class="v${Number(value) < 0 ? ' neg' : ''}">${fmtBig(value, unit)}</div><div class="s">${esc(sub || '')}</div></div>`;

  // ---------- графики ----------
  let gid = 0;
  const topRounded = (x, y, w, h, r) => {
    r = Math.max(0, Math.min(r, w / 2, h));
    return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h}Z`;
  };
  function axisTicks(min, max) {
    const span = max - min || 1; const raw = span / 3;
    const p = 10 ** Math.floor(Math.log10(raw)); const step = [1, 2, 2.5, 5, 10].map((k) => k * p).find((s) => s >= raw) || raw;
    const lo = Math.floor(min / step) * step; const hi = Math.ceil(max / step) * step;
    const t = []; for (let v = lo; v <= hi + step / 2; v += step) t.push(Math.round(v * 1e6) / 1e6);
    return t;
  }

  // Столбчатый график; series = [{label, value, cls?, title?}]. Скругление только сверху.
  function barChart(series, { height = 240, fmt = fmtShort } = {}) {
    return groupedBars(series.map((s) => s.label), [{ values: series.map((s) => s.value), cls: series.map((s) => s.cls || ''), titles: series.map((s) => s.title) }], { height, fmt, legend: false });
  }

  // Сгруппированные столбцы: labels[], groups = [{name, values[], cls}] (фиолетовый и чёрный).
  function groupedBars(labels, groups, { height = 260, fmt = fmtShort, legend = true } = {}) {
    const W = 680; const H = height; const L = 62; const B = 30; const T = 12; const R = 6;
    const all = groups.flatMap((g) => g.values.map((v) => Number(v) || 0));
    const ticks = axisTicks(Math.min(0, ...all), Math.max(1, ...all));
    const min = ticks[0]; const max = ticks[ticks.length - 1]; const span = max - min || 1;
    const y = (v) => T + (H - T - B) * (1 - (v - min) / span);
    const n = Math.max(1, labels.length); const slot = (W - L - R) / n;
    const gap = groups.length > 1 ? Math.min(8, slot * 0.06) : 0;
    const bw = Math.min(46, (slot * 0.66 - gap * (groups.length - 1)) / groups.length);
    let svg = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="График">`;
    for (const t of ticks) svg += `<line class="grid" x1="${L}" x2="${W - R}" y1="${y(t)}" y2="${y(t)}"/><text class="axis" x="${L - 12}" y="${y(t) + 4}" text-anchor="end">${esc(fmt(t))}</text>`;
    const every = Math.ceil(n / 12);
    labels.forEach((lab, i) => {
      const cx = L + slot * i + slot / 2; const total = bw * groups.length + gap * (groups.length - 1);
      groups.forEach((g, gi) => {
        const v = Number(g.values[i]) || 0; const x = cx - total / 2 + gi * (bw + gap);
        const top = y(Math.max(v, 0)); const h = Math.max(Math.abs(y(v) - y(0)), 1.5);
        const cls = Array.isArray(g.cls) ? g.cls[i] : (g.cls || '');
        const tip = `${lab}${g.name ? ' · ' + g.name : ''}: ${(g.titles && g.titles[i]) || fmt(v)}`;
        svg += v >= 0 ? `<path class="bar ${esc(cls)}" d="${topRounded(x, top, bw, h, 7)}"><title>${esc(tip)}</title></path>`
          : `<rect class="bar ${esc(cls)}" x="${x}" y="${y(0)}" width="${bw}" height="${h}" rx="3"><title>${esc(tip)}</title></rect>`;
      });
      if (i % every === 0 || i === n - 1) svg += `<text class="axis" x="${cx}" y="${H - 6}" text-anchor="middle">${esc(lab)}</text>`;
    });
    svg += '</svg>';
    if (legend && groups.length > 1) svg += `<div class="legend">${groups.map((g, gi) => `<span><i class="${gi ? 's2' : ''}"></i>${esc(g.name)}</span>`).join('')}</div>`;
    return svg;
  }

  // Площадной график (фиолетовая линия + градиентная заливка). dark — для тёмной карточки.
  function areaChart(points, { height = 190, dark = false, fmt = fmtShort } = {}) {
    const W = 600; const H = height; const T = 14; const B = dark ? 6 : 28; const L = dark ? 0 : 56; const R = dark ? 0 : 8;
    const vals = points.map((p) => Number(p.value) || 0);
    if (!vals.length) return '';
    const lo = Math.min(...vals); const hi = Math.max(...vals);
    const min = dark ? lo - (hi - lo || 1) * 0.15 : Math.min(0, lo); const max = hi + (hi - lo || 1) * 0.08;
    const span = max - min || 1;
    const x = (i) => L + (W - L - R) * (vals.length === 1 ? 0.5 : i / (vals.length - 1));
    const y = (v) => T + (H - T - B) * (1 - (v - min) / span);
    const pts = vals.map((v, i) => [x(i), y(v)]);
    let d = `M${pts[0][0]},${pts[0][1]}`;
    for (let i = 1; i < pts.length; i++) { // плавная кривая (кардинальный сплайн)
      const p0 = pts[i - 2] || pts[i - 1]; const p1 = pts[i - 1]; const p2 = pts[i]; const p3 = pts[i + 1] || p2;
      d += `C${p1[0] + (p2[0] - p0[0]) / 6},${p1[1] + (p2[1] - p0[1]) / 6} ${p2[0] - (p3[0] - p1[0]) / 6},${p2[1] - (p3[1] - p1[1]) / 6} ${p2[0]},${p2[1]}`;
    }
    const id = `ag${++gid}`;
    const base = H - B;
    let svg = `<svg class="chart${dark ? '' : ' light'}" viewBox="0 0 ${W} ${H}" role="img" aria-label="График"${dark ? ' preserveAspectRatio="none"' : ''}>
      <defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#8f7bf0" stop-opacity="${dark ? 0.5 : 0.32}"/><stop offset="1" stop-color="#8f7bf0" stop-opacity="0"/></linearGradient></defs>`;
    if (!dark) {
      for (const t of axisTicks(min, max).filter((t) => t >= min && t <= max)) svg += `<line class="grid" x1="${L}" x2="${W - R}" y1="${y(t)}" y2="${y(t)}"/><text class="axis" x="${L - 10}" y="${y(t) + 4}" text-anchor="end">${esc(fmt(t))}</text>`;
      const every = Math.ceil(points.length / 8);
      points.forEach((p, i) => { if (i % every === 0 || i === points.length - 1) svg += `<text class="axis" x="${x(i)}" y="${H - 6}" text-anchor="${i === 0 ? 'start' : i === points.length - 1 ? 'end' : 'middle'}">${esc(p.label)}</text>`; });
    }
    svg += `<path d="${d}L${pts[pts.length - 1][0]},${base}L${pts[0][0]},${base}Z" fill="url(#${id})"/><path class="area-line" d="${d}" vector-effect="non-scaling-stroke"/>`;
    points.forEach((p, i) => { svg += `<circle cx="${pts[i][0]}" cy="${pts[i][1]}" r="9" fill="transparent"><title>${esc(p.label)}: ${esc(p.title || fmt(p.value))}</title></circle>`; });
    return svg + '</svg>';
  }

  // Кольцевая диаграмма + список: rows = [{label, value}] (value > 0).
  function donut(rows, { total, cap = '', fmt = fmtMoney } = {}) {
    const sum = rows.reduce((s, r) => s + Number(r.value), 0) || 1;
    const R = 80; const C = 2 * Math.PI * R; const gapLen = rows.length > 1 ? 5 : 0;
    let off = 0; let arcs = '';
    rows.forEach((r, i) => {
      const len = Math.max(0, (Number(r.value) / sum) * C - gapLen);
      arcs += `<circle class="c${i % 6}" r="${R}" cx="100" cy="100" stroke-dasharray="${len} ${C - len}" stroke-dashoffset="${-off}" stroke-linecap="round" transform="rotate(-90 100 100)"><title>${esc(r.label)}: ${esc(fmt(r.value))}</title></circle>`;
      off += (Number(r.value) / sum) * C;
    });
    const pct = (v) => { const p = (Number(v) / sum) * 100; return p < 1 ? '<1%' : tidy(String(Math.round(p))) + '%'; };
    return `<div class="donut-wrap"><svg class="donut" viewBox="0 0 200 200" role="img" aria-label="Структура">
        <circle class="track" r="${R}" cx="100" cy="100"/>${arcs}
        <text class="total" x="100" y="103" text-anchor="middle">${esc(total ?? fmtShort(sum))}</text><text class="cap" x="100" y="126" text-anchor="middle">${esc(cap)}</text></svg>
      <ul class="dlegend">${rows.map((r, i) => `<li><i class="c${i % 6}"></i><span>${esc(r.label)}</span><span class="amt">${esc(fmt(r.value))}<small>${pct(r.value)}</small></span></li>`).join('')}</ul></div>`;
  }

  // Горизонтальные полосы с градиентом: rows = [{label, value, sub?, cls?}].
  function hbars(rows, { fmt = fmtMoney, one = false } = {}) {
    const max = Math.max(1, ...rows.map((r) => Number(r.value) || 0));
    return `<div class="hbars${one ? ' one' : ''}">${rows.map((r) => `<div class="hbar"><div class="top"><span class="name">${esc(r.label)}</span><span class="amt">${esc(fmt(r.value))}</span></div>
      <span class="track"><span class="fill ${esc(r.cls || '')}" data-w="${(100 * (Number(r.value) || 0) / max).toFixed(1)}"></span></span>${r.sub ? `<div class="desc">${esc(r.sub)}</div>` : ''}</div>`).join('')}</div>`;
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
            bar.querySelector('button').addEventListener('click', () => { nw.postMessage('skipWaiting'); location.reload(); });
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
  // Активная вкладка видна в «таблетке» на телефоне.
  function revealTab(navEl) {
    const a = navEl && navEl.querySelector('[aria-current]');
    if (a && navEl.scrollWidth > navEl.clientWidth) navEl.scrollTo({ left: a.offsetLeft - 12, behavior: 'smooth' });
  }
  document.addEventListener('click', (e) => { if (e.target.closest('.js-reload')) location.reload(); });

  return { applyWidths, esc, fmtValue, fmtBig, fmtMoney, fmtShort, fmtTime, fmtStamp, delta, api, post, logout, topbar, caption, updated, nav, head, brandHtml,
    loading, empty, errorBox, kpiCard, statCard, barChart, groupedBars, areaChart, donut, hbars, registerSW, revealTab, pad2 };
})();
