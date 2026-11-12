'use strict';
/* Экран руководителя хаба AIRL. Все цифры — из /hub/api/* (схема metrics) и /<id>/api/hub/summary.
   В браузере ничего не пересчитывается: только форматирование и раскладка. */
(() => {
  const { esc, api, post, fmtValue, fmtMoney, fmtShort, fmtTime, kpiCard, barChart, hbars, loading, errorBox, empty } = AIRL;
  const view = document.getElementById('view');
  const navEl = document.getElementById('nav');
  const GRAINS = [['day', 'День'], ['week', 'Неделя'], ['month', 'Месяц'], ['quarter', 'Квартал']];
  const LOWER_BETTER = new Set(['receivables_overdue']);
  const DEPT_TITLE = { finance: 'Финансы', sales: 'Продажи', edu: 'Обучение', ceo: 'Компания' };
  let grain = 'month';
  try { grain = localStorage.getItem('hub.grain') || 'month'; } catch { /* приватный режим */ }
  let me = null;

  const seg = () => `<div class="seg" role="group" aria-label="Период">${GRAINS.map(([g, t]) =>
    `<button type="button" data-grain="${g}" aria-pressed="${g === grain}">${t}</button>`).join('')}</div>`;

  function head(title, sub) {
    return `<div class="page-head"><div><h1>${esc(title)}</h1><div class="sub" id="asof">${esc(sub || '')}</div></div><span class="spacer"></span>${seg()}</div>`;
  }

  function bindSeg(render) {
    view.querySelectorAll('[data-grain]').forEach((b) => b.addEventListener('click', () => {
      grain = b.dataset.grain;
      try { localStorage.setItem('hub.grain', grain); } catch { /* ничего */ }
      render();
    }));
  }

  const kpiBlock = (kpis) => `<div class="kpis">${kpis.map((k) => kpiCard({ ...k, id: k.metric_id },
    { lowerIsBetter: LOWER_BETTER.has(k.metric_id), sub: `было ${fmtValue(k.prev_value, k.unit)} · ${DEPT_TITLE[k.department] || ''}` })).join('')}</div>`;

  function seriesCard(title, s, unit) {
    const pts = s.points.map((p, i) => ({ label: p.label, value: p.value, cls: i === s.points.length - 1 ? 'cur' : '', title: fmtValue(p.value, unit) }));
    const fmt = unit === 'KZT' ? fmtShort : (v) => fmtValue(v, unit);
    return `<div class="card"><h2>${esc(title)} <span class="sub">· ${esc({ day: '30 дней', week: '13 недель', month: '18 месяцев', quarter: '6 кварталов' }[s.grain])} · последний период — неполный, по вчера</span></h2>${barChart(pts, { fmt })}</div>`;
  }

  function pnlCard(p) {
    const rows = p.lines.map((l) => {
      const cls = l.kind === 'margin' ? (l.line_code === 'gross_profit' ? 'is-margin' : 'is-margin') : l.kind === 'net' ? 'is-net' : l.kind === 'total' ? 'is-section' : 'is-sub';
      const d = l.prev === null || l.prev === 0 ? '—' : `${(((l.amount - l.prev) / Math.abs(l.prev)) * 100).toFixed(1).replace('.', ',')}%`;
      return `<tr class="${cls}"><td data-label="Строка">${esc(l.title)}</td><td class="n ${l.amount < 0 ? 'neg' : ''}" data-label="Период">${fmtMoney(l.amount)}</td><td class="n" data-label="Прошлый">${fmtMoney(l.prev)}</td><td class="n" data-label="Изм.">${d}</td></tr>`;
    }).join('');
    return `<div class="card" id="pnl"><h2>ОПиУ компании <span class="sub">· ${esc(p.period)} · без внутригрупповых оборотов · текущий месяц предварительный</span></h2>
      <div class="scroll-x"><table class="tbl cards"><thead><tr><th>Строка</th><th class="n">Период</th><th class="n">Прошлый</th><th class="n">Изм.</th></tr></thead><tbody>${rows}</tbody></table></div></div>`;
  }

  function agingCard(a) {
    const cls = ['', '', 'warning', 'danger', 'danger'];
    const rows = a.buckets.map((b) => ({ label: b.bucket, value: b.amount, cls: cls[b.ord] || '' }));
    return `<div class="card" id="aging"><h2>Дебиторка по срокам <span class="sub">· на конец вчерашнего дня · с НДС</span></h2>${rows.length ? hbars(rows) : empty('Долгов нет')}
      <p class="muted">Документов с остатком: ${a.buckets.reduce((s, b) => s + Number(b.docs), 0)}. Подробно — в сервисе «Финансы» → «Должники».</p></div>`;
  }

  function funnelCard(f) {
    const rows = f.channels.map((c) => `<tr><td data-label="Канал">${esc(c.channel)}</td><td class="n" data-label="Заявки">${c.leads}</td><td class="n" data-label="В работе">${c.open}</td><td class="n" data-label="Отказ">${c.lost}</td><td class="n" data-label="Оплата">${c.won}</td></tr>`).join('');
    const tot = f.channels.reduce((s, c) => ({ leads: s.leads + Number(c.leads), won: s.won + Number(c.won) }), { leads: 0, won: 0 });
    return `<div class="card" id="funnel"><h2>Заявки по каналам <span class="sub">· ${esc(f.period)} · без дублей (30 дней)</span></h2>
      ${f.channels.length ? `<table class="tbl cards"><thead><tr><th>Канал</th><th class="n">Заявки</th><th class="n">В работе</th><th class="n">Отказ</th><th class="n">Оплата</th></tr></thead><tbody>${rows}</tbody>
      <tfoot><tr class="is-section"><td>Итого</td><td class="n">${tot.leads}</td><td></td><td></td><td class="n">${tot.won}</td></tr></tfoot></table>` : empty('Заявок за период нет')}</div>`;
  }

  function forecastCard(f, tiles) {
    const sales = (tiles || []).find((t) => t.id === 'sales' && t.ok);
    const plan = sales && (sales.metrics || []).find((m) => m.id === 'plan_completion:revenue');
    return `<div class="card" id="forecast"><h2>Прогноз месяца <span class="sub">· оценка по темпу, не план</span></h2>
      <div class="kpis">
        <div class="kpi"><div class="l">Выручка с 1-го числа</div><div class="v">${fmtMoney(f.fact)}</div><div class="s">${f.days_passed} из ${f.days_total} дней</div></div>
        <div class="kpi"><div class="l">Прогноз на конец месяца</div><div class="v">${fmtMoney(f.forecast)}</div><div class="s">тот же месяц год назад: ${fmtMoney(f.last_year)}</div></div>
        ${plan ? `<div class="kpi ${esc(plan.status)}"><div class="l">Выполнение плана выручки</div><div class="v">${fmtValue(plan.value, '%')}</div><div class="s">из сервиса «Продажи» (модуль план-факт)</div></div>` : ''}
      </div></div>`;
  }

  function tilesBlock(t) {
    if (!t.tiles.length) return '';
    return `<div class="tiles" id="tiles">${t.tiles.map((x) => x.ok ? `
      <section class="tile" data-service="${esc(x.id)}">
        <header><h3>${esc(x.title)}</h3><span class="badge ${worst(x.metrics)}">${{ ok: 'в норме', warning: 'внимание', danger: 'риск' }[worst(x.metrics)]}</span></header>
        ${(x.metrics || []).map((m) => `<div class="row"><span>${esc(m.title)}</span><span class="num"><span class="badge ${esc(m.status)}">${fmtValue(m.value, m.unit)}</span></span></div>`).join('')}
        ${(x.alerts || []).length ? `<ul class="alerts">${x.alerts.map((a) => `<li>${esc(a.text)}</li>`).join('')}</ul>` : ''}
        <div class="row muted"><span>обновлено в ${fmtTime(x.generated_at)}</span><a class="btn small secondary" href="${esc(x.base_path)}/" data-open="${esc(x.id)}">Открыть</a></div>
      </section>` : `
      <section class="tile gray" data-service="${esc(x.id)}"><header><h3>${esc(x.title)}</h3><span class="badge gray">нет данных</span></header>
        <p class="muted">Нет данных от сервиса · проверено в ${fmtTime(x.checked_at)}</p></section>`).join('')}</div>`;
  }
  function worst(ms) { const s = (ms || []).map((m) => m.status); return s.includes('danger') ? 'danger' : s.includes('warning') ? 'warning' : 'ok'; }

  function alertsCard(kpis, tiles) {
    const items = [];
    for (const k of kpis) if (k.status === 'danger') items.push({ level: 'danger', text: `${k.title}: ${fmtValue(k.value, k.unit)} (было ${fmtValue(k.prev_value, k.unit)})` });
    for (const t of tiles.tiles || []) for (const a of t.alerts || []) items.push({ level: a.level, text: `${t.title}: ${a.text}`, link: a.link });
    for (const t of tiles.tiles || []) if (!t.ok) items.push({ level: 'warning', text: `${t.title}: нет данных от сервиса` });
    return `<div class="card" id="alerts"><h2>Сигналы <span class="sub">· что проверить сегодня</span></h2>${items.length
      ? `<ul class="alert-list">${items.map((i) => `<li><span class="badge ${esc(i.level)}">${i.level === 'danger' ? 'риск' : 'внимание'}</span><span>${i.link ? `<a href="${esc(i.link)}">${esc(i.text)}</a>` : esc(i.text)}</span></li>`).join('')}</ul>`
      : empty('Красных сигналов нет')}</div>`;
  }

  async function digestCard() {
    try {
      const d = await api('/hub/api/digest');
      return `<div class="card" id="digest"><h2>Утренняя сводка <span class="sub">· ${esc(d.how)} · ${esc(d.date || '')}</span></h2><pre class="mono digest">${esc(d.text)}</pre></div>`;
    } catch { return ''; }
  }

  async function renderOverview() {
    view.innerHTML = head('Экран руководителя', 'Загружаем показатели…') + loading(8);
    bindSeg(renderOverview);
    try {
      const [ov, rev, tiles] = await Promise.all([api(`/hub/api/overview?grain=${grain}`), api(`/hub/api/series?metric=revenue&grain=${grain}`).catch(() => null), api('/hub/api/tiles').catch(() => ({ tiles: [] }))]);
      const fin = ov.departments.includes('finance'); const sales = ov.departments.includes('sales');
      const [pnl, aging, funnel, fc, dg] = await Promise.all([
        fin ? api(`/hub/api/pnl?grain=${grain}`) : null, fin ? api('/hub/api/aging') : null,
        sales ? api(`/hub/api/funnel?grain=${grain}`) : null, (fin || sales) ? api('/hub/api/forecast') : null, digestCard()]);
      view.innerHTML = head(me.role === 'ceo' ? 'Экран руководителя' : `Экран руководителя · ${DEPT_TITLE[ov.departments[0]]}`,
        `Период: ${ov.period} · сравнение: ${ov.compare} (те же дни) · данные загружены по ${ov.as_of}`)
        + dg + kpiBlock(ov.kpis) + tilesBlock(tiles)
        + `<div class="grid2">${rev ? seriesCard('Выручка', rev, 'KZT') : ''}${fc ? forecastCard(fc, tiles.tiles) : alertsCard(ov.kpis, tiles)}</div>`
        + (fin ? `<div class="grid2">${pnlCard(pnl)}<div>${agingCard(aging)}${alertsCard(ov.kpis, tiles)}</div></div>` : '')
        + (sales ? `<div class="grid2">${funnelCard(funnel)}${fin ? '' : alertsCard(ov.kpis, tiles)}</div>` : '')
        + (!fin && !sales ? alertsCard(ov.kpis, tiles) : '');
      bindSeg(renderOverview);
      AIRL.applyWidths(view);
      view.querySelectorAll('[data-open]').forEach((a) => a.addEventListener('click', () => { post('/hub/api/open', { service: a.dataset.open }).catch(() => {}); }));
    } catch (e) {
      view.innerHTML = head('Экран руководителя') + errorBox(e.status === 403 ? 'Экран руководителя недоступен для вашей роли' : `Не удалось загрузить показатели: ${e.message}`);
    }
  }

  async function renderDept(dept) {
    const title = DEPT_TITLE[dept];
    view.innerHTML = head(title, 'Загружаем…') + loading(4);
    bindSeg(() => renderDept(dept));
    try {
      const ov = await api(`/hub/api/overview?grain=${grain}`);
      if (!ov.departments.includes(dept)) { view.innerHTML = head(title) + errorBox('Этот отдел недоступен для вашей роли'); return; }
      const kpis = ov.kpis.filter((k) => k.department === dept);
      const metric = { finance: 'cash_balance', sales: 'lead', edu: 'enrollments' }[dept];
      const second = { finance: 'revenue', sales: 'conversion_lead_to_deal', edu: 'course_completion_rate' }[dept];
      const [s1, s2] = await Promise.all([api(`/hub/api/series?metric=${metric}&grain=${grain}`), api(`/hub/api/series?metric=${second}&grain=${grain}`)]);
      const u1 = kpis.find((k) => k.metric_id === metric)?.unit; const u2 = kpis.find((k) => k.metric_id === second)?.unit;
      let extra = '';
      if (dept === 'finance') { const [p, a] = await Promise.all([api(`/hub/api/pnl?grain=${grain}`), api('/hub/api/aging')]); extra = `<div class="grid2">${pnlCard(p)}${agingCard(a)}</div>`; }
      if (dept === 'sales') extra = funnelCard(await api(`/hub/api/funnel?grain=${grain}`));
      view.innerHTML = head(title, `Период: ${ov.period} · данные по ${ov.as_of}`) + kpiBlock(kpis)
        + `<div class="grid2">${seriesCard(kpis.find((k) => k.metric_id === metric)?.title || metric, s1, u1)}${seriesCard(kpis.find((k) => k.metric_id === second)?.title || second, s2, u2)}</div>`
        + extra + `<p><a class="btn" href="/${dept}/">Открыть сервис «${esc(title)}»</a></p>`;
      bindSeg(() => renderDept(dept));
      AIRL.applyWidths(view);
    } catch (e) {
      view.innerHTML = head(title) + errorBox(`Не удалось загрузить: ${e.message}`);
    }
  }

  function route() {
    const r = (location.hash || '#/overview').slice(2);
    const allowed = ['overview', ...(me.role === 'ceo' ? ['finance', 'sales', 'edu'] : [me.role.split('_')[1]])];
    const cur = allowed.includes(r) ? r : 'overview';
    navEl.innerHTML = AIRL.nav([{ id: 'overview', title: 'Обзор', href: '#/overview' },
      ...allowed.slice(1).map((d) => ({ id: d, title: DEPT_TITLE[d], href: `#/${d}` })),
      { group: 'Сервисы отделов' },
      ...me.services.filter((s) => s.id !== 'hub').map((s) => ({ id: 'svc-' + s.id, title: `${s.title} →`, href: `${s.base_path}/` }))], cur);
    if (cur === 'overview') renderOverview(); else renderDept(cur);
  }

  // Продлеваем токен за 10 минут до конца срока.
  function scheduleRefresh() {
    const ms = Math.max(30000, (me.exp * 1000 - Date.now()) - 10 * 60 * 1000);
    setTimeout(async () => { try { const r = await post('/auth/refresh'); me.exp = r.exp; } catch { /* api() отправит на вход */ } scheduleRefresh(); }, ms);
  }

  (async () => {
    try { me = await AIRL.topbar('Экран руководителя', 'hub'); } catch (e) { view.innerHTML = errorBox('Не удалось открыть хаб: ' + e.message); return; }
    window.addEventListener('hashchange', route);
    route();
    scheduleRefresh();
    AIRL.registerSW('/');
  })();
})();
