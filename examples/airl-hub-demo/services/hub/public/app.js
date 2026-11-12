'use strict';
/* Экран руководителя хаба AIRL в стиле «1С Hub». Все цифры — из /hub/api/* (схема metrics)
   и /<id>/api/hub/summary. В браузере ничего не пересчитывается: только форматирование и раскладка.
   Одна длинная страница с разделами; вкладки в белой «таблетке» прокручивают к разделу. */
(() => {
  const { esc, api, post, fmtValue, fmtMoney, fmtShort, fmtTime, fmtBig, kpiCard, statCard, groupedBars, barChart, areaChart, donut, hbars, errorBox, empty, pad2 } = AIRL;
  const view = document.getElementById('view');
  const navEl = document.getElementById('nav');
  const GRAINS = [['day', 'День'], ['week', 'Неделя'], ['month', 'Месяц'], ['quarter', 'Квартал']];
  const GRAIN_N = { day: '30 дней', week: '13 недель', month: '18 месяцев', quarter: '6 кварталов' };
  const LOWER_BETTER = new Set(['receivables_overdue', 'turnover_rate', 'time_to_hire', 'open_vacancies', 'payroll_fund', 'ad_spend', 'cpl', 'cac']);
  const STATUS_PILL = { ok: ['ok', 'Остаток: в норме'], warning: ['warning', 'Остаток: внимание'], danger: ['rose', 'Остаток: ниже нормы'] };
  const DEPT_TITLE = { finance: 'Финансы', sales: 'Продажи', marketing: 'Маркетинг', edu: 'Обучение', hr: 'HR' };
  let grain = 'month';
  try { grain = localStorage.getItem('hub.grain') || 'month'; } catch { /* приватный режим */ }
  let me = null;
  let tabs = [];

  const seg = () => `<div class="seg" role="group" aria-label="Период">${GRAINS.map(([g, t]) =>
    `<button type="button" data-grain="${g}" aria-pressed="${g === grain}">${t}</button>`).join('')}</div>`;
  const secHead = (no, title, sub, right = '') => `<div class="sec-head"><span class="no">${pad2(no)}</span><div><h2>${esc(title)}</h2><div class="sub">${esc(sub)}</div></div>${right ? `<div class="right">${right}</div>` : '<span></span>'}</div>`;
  const dmy = (iso) => (/^\d{4}-\d{2}-\d{2}/.test(String(iso)) ? String(iso).slice(0, 10).split('-').reverse().join('.') : String(iso || ''));
  const card = (id, title, sub, body, cls = '') => `<div class="card ${cls}"${id ? ` id="${id}"` : ''}><h2>${esc(title)}${sub ? `<span class="sub">${esc(sub)}</span>` : ''}</h2>${body}</div>`;
  const kpiOf = (kpis, id) => kpis.find((k) => k.metric_id === id);
  const kpi = (k, sub) => (k ? kpiCard({ ...k, id: k.metric_id }, { lowerIsBetter: LOWER_BETTER.has(k.metric_id), sub: sub ?? `было ${fmtValue(k.prev_value, k.unit)}` }) : '');

  // ---------- 01 Обзор ----------
  function heroCard(k, cash) {
    const [pc, pt] = STATUS_PILL[k.status] || STATUS_PILL.ok;
    const pts = (cash ? cash.points : []).map((p) => ({ label: p.label, value: p.value, title: fmtMoney(p.value) }));
    return `<div class="kpi hero ${esc(k.status)}" data-metric="cash_balance">
      <div class="l"><span>Деньги на счетах</span><span class="pill ${pc}">${esc(pt)}</span></div>
      <div class="v${Number(k.value) < 0 ? ' neg' : ''}${AIRL.lenCls(k.value, k.unit)}" data-value="${esc(k.value)}">${fmtBig(k.value, k.unit)}</div>
      <div class="asof">на ${esc(k.cur_to ? dmy(k.cur_to) : k.period)} · все счета и касса</div>
      <div class="subs"><div><div class="t">Прошлый период</div><div class="n">${fmtBig(k.prev_value, k.unit)}</div></div>
        <div><div class="t">Изменение</div><div class="n">${AIRL.delta(k.value, k.prev_value, { unit: k.unit })}</div></div></div>
      ${pts.length > 1 ? areaChart(pts, { dark: true, height: 200 }) : ''}</div>`;
  }

  function overviewSec(no, ov, x) {
    const k = ov.kpis; const fin = ov.departments.includes('finance');
    const cash = kpiOf(k, 'cash_balance');
    let g1; let g1t;
    if (fin) { g1t = 'Результат за период'; g1 = ['revenue', 'net_profit', 'gross_margin', 'headcount'].map((id) => kpi(kpiOf(k, id))).join(''); }
    else { g1t = `Показатели отдела «${DEPT_TITLE[ov.departments[0]] || ''}»`; g1 = k.map((m) => kpi(m)).join(''); }
    const sales = (x.tiles.tiles || []).find((t) => t.id === 'sales' && t.ok);
    const plan = sales && (sales.metrics || []).find((m) => m.id === 'plan_completion:revenue');
    const g2 = (fin ? kpi(kpiOf(k, 'receivables_overdue'), `было ${fmtValue(kpiOf(k, 'receivables_overdue')?.prev_value, 'KZT')}`) : '')
      + (x.fc ? statCard('Выручка с 1-го числа', x.fc.fact, 'KZT', `${x.fc.days_passed} из ${x.fc.days_total} дней месяца`)
        + statCard('Прогноз выручки на месяц', x.fc.forecast, 'KZT', `оценка по темпу · год назад ${fmtMoney(x.fc.last_year)}`) : '')
      + (plan ? statCard('Выполнение плана выручки', plan.value, '%', 'сервис «Продажи», модуль план-факт', plan.status) : '');
    const right = `<div class="kpi-groups"><div class="group-label">${esc(g1t)}</div><div class="kpis four">${g1}</div>
      ${g2 ? `<div class="group-label">${fin ? 'Долги и ожидаемые поступления' : 'Ожидаемые поступления'}</div><div class="kpis four" id="forecast">${g2}</div>` : ''}</div>`;
    return `<section class="sec" id="overview">${secHead(no, 'Обзор', `Главные цифры компании · ${ov.period} против ${ov.compare} (те же дни)`, seg())}
      <div class="overview-grid${cash ? '' : ' solo'}">${cash ? heroCard(cash, x.cash) : ''}${right}</div>
      ${alertsCard(ov.kpis, x.tiles)}</section>`;
  }

  function alertsCard(kpis, tiles) {
    const items = [];
    for (const k of kpis) if (k.status === 'danger') items.push({ level: 'danger', text: `${k.title}: ${fmtValue(k.value, k.unit)} (было ${fmtValue(k.prev_value, k.unit)})` });
    for (const t of tiles.tiles || []) for (const a of t.alerts || []) items.push({ level: a.level, text: `${t.title}: ${a.text}`, link: a.link });
    for (const t of tiles.tiles || []) if (!t.ok) items.push({ level: 'warning', text: `${t.title}: нет данных от сервиса` });
    return card('alerts', 'На что обратить внимание', 'Автоматическая проверка показателей и сервисов отделов', items.length
      ? `<ol class="attn">${items.map((i) => `<li class="${esc(i.level)}"><span>${i.link ? `<a href="${esc(i.link)}">${esc(i.text)}</a>` : esc(i.text)}</span></li>`).join('')}</ol>`
      : empty('Красных сигналов нет'));
  }

  // ---------- 02 Доходы и расходы ----------
  function pnlCard(p) {
    const rows = p.lines.map((l) => {
      const cls = l.kind === 'margin' ? 'is-margin' : l.kind === 'net' ? 'is-net' : l.kind === 'total' ? 'is-section' : 'is-sub';
      const d = l.prev === null || Number(l.prev) === 0 ? '—' : AIRL.delta(Number(l.amount), Number(l.prev));
      return `<tr class="${cls}"><td data-label="Строка">${esc(l.title)}</td><td class="n ${Number(l.amount) < 0 ? 'neg' : ''}" data-label="Период">${fmtMoney(l.amount)}</td><td class="n" data-label="Прошлый">${fmtMoney(l.prev)}</td><td class="n" data-label="Изм.">${d}</td></tr>`;
    }).join('');
    return card('pnl', 'Отчёт о прибылях и убытках', `${p.period} · без внутригрупповых оборотов · текущий месяц предварительный`,
      `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Строка</th><th class="n">Период</th><th class="n">Прошлый</th><th class="n">Изменение</th></tr></thead><tbody>${rows}</tbody></table></div>`);
  }

  function incomeSec(no, x) {
    const labels = x.rev.points.map((p) => p.label);
    const np = new Map((x.np ? x.np.points : []).map((p) => [p.label, p.value]));
    const bars = groupedBars(labels, [
      { name: 'Выручка', values: x.rev.points.map((p) => p.value), titles: x.rev.points.map((p) => fmtMoney(p.value)) },
      { name: 'Чистая прибыль', values: labels.map((l) => np.get(l) ?? 0), cls: 's2', titles: labels.map((l) => fmtMoney(np.get(l))) }], { span: 'wide' });
    const exp = x.pnl.lines.filter((l) => l.kind === 'expense' && Number(l.amount) !== 0)
      .map((l) => ({ label: l.title, value: Math.abs(Number(l.amount)) })).sort((a, b) => b.value - a.value);
    const sum = exp.reduce((s, r) => s + r.value, 0);
    return `<section class="sec" id="income">${secHead(no, 'Доходы и расходы', 'Сколько заработали и на что потратили — по начислению, из 1С')}
      <div class="grid-wide">${card('', 'Выручка и чистая прибыль', `${GRAIN_N[x.rev.grain]} · наведите на столбец, чтобы увидеть сумму · последний период неполный`, bars)}
      ${card('', 'Структура расходов', `${x.pnl.period} · статьи ОПиУ`, exp.length ? donut(exp, { total: `${fmtShort(sum)} ₸`, cap: 'расходы' }) : empty('Расходов за период нет'))}</div>
      ${pnlCard(x.pnl)}</section>`;
  }

  // ---------- 03 Деньги ----------
  function moneySec(no, x) {
    const fin = (x.tiles.tiles || []).find((t) => t.id === 'finance' && t.ok);
    const mods = fin ? (fin.metrics || []).filter((m) => !['revenue', 'gross_margin', 'cash_balance', 'net_profit', 'receivables_overdue'].includes(String(m.id).split(':')[0])) : [];
    const notes = fin ? (fin.alerts || []) : [];
    const pts = x.cash.points.map((p) => ({ label: p.label, value: p.value, title: fmtMoney(p.value) }));
    return `<section class="sec" id="money">${secHead(no, 'Деньги', 'Остаток на счетах и в кассе обоих юрлиц, в тенге')}
      <div class="grid-wide">${card('', 'Остаток денег по периодам', `${GRAIN_N[x.cash.grain]} · на конец каждого периода`, areaChart(pts, { height: 260, span: 'wide' }))}
      ${card('', 'Банк и касса', 'Сверка выписок и движение денег — в сервисе «Финансы»',
    `${mods.length ? `<div class="mini">${mods.map((m) => `<div><div class="t">${esc(m.title)}</div><div class="n">${fmtBig(m.value, m.unit)}</div></div>`).join('')}</div>` : ''}
        ${notes.length ? `<ul class="alert-list">${notes.map((n) => `<li><span class="badge ${esc(n.level)}">${n.level === 'danger' ? 'риск' : 'внимание'}</span><span>${esc(n.text)}</span></li>`).join('')}</ul>` : empty('Замечаний от сервиса «Финансы» нет')}
        <div class="actions spaced"><a class="btn" href="/finance/#/cash">Движение денег</a><a class="btn secondary" href="/finance/#/bank">Сверка банка</a></div>`)}</div></section>`;
  }

  // ---------- 04 Клиенты и счета ----------
  function clientsSec(no, x) {
    const cls = ['', '', 'warning', 'danger', 'danger'];
    const rows = x.aging.buckets.map((b) => ({ label: b.bucket, value: b.amount, cls: cls[b.ord] || '', sub: `документов с остатком: ${b.docs}` }));
    const docs = x.aging.buckets.reduce((s, b) => s + Number(b.docs), 0);
    return `<section class="sec" id="clients">${secHead(no, 'Клиенты и счета', 'Кто и сколько должен — по срокам оплаты, с НДС')}
      ${card('aging', 'Дебиторка по срокам', `на конец вчерашнего дня · документов с остатком: ${docs}`,
    `${rows.length ? hbars(rows) : empty('Долгов нет')}<div class="actions"><a class="btn" href="/finance/#/debtors">Должники и звонки</a></div>`)}</section>`;
  }

  // ---------- 05 Продажи ----------
  function salesSec(no, ov, x, kpisInOverview) {
    const ks = kpisInOverview ? '' : `<div class="kpis">${ov.kpis.filter((k) => k.department === 'sales').map((k) => kpi(k)).join('')}</div>`;
    const f = x.funnel;
    const tot = f.channels.reduce((s, c) => ({ leads: s.leads + Number(c.leads), won: s.won + Number(c.won) }), { leads: 0, won: 0 });
    const funnel = f.channels.length ? hbars(f.channels.map((c) => ({ label: c.channel_title || c.channel, value: c.leads, sub: `в работе ${c.open} · отказ ${c.lost} · оплата ${c.won}` })), { fmt: (v) => fmtValue(v, 'шт'), one: true })
      + `<p class="csub">Итого: ${tot.leads} заявок, оплачено ${tot.won}</p>` : empty('Заявок за период нет');
    const leads = x.lead ? barChart(x.lead.points.map((p, i) => ({ label: p.label, value: p.value, cls: i === x.lead.points.length - 1 ? 'cur' : '' })), { fmt: (v) => String(Math.round(v)), span: 'wide' }) : '';
    return `<section class="sec" id="sales">${secHead(no, 'Продажи', 'Заявки из amoCRM и оплаты из 1С — без дублей за 30 дней')}${ks}
      <div class="grid-wide">${card('', 'Заявки по периодам', `${GRAIN_N[grain]} · чёрный — текущий, неполный`, leads)}
      ${card('funnel', 'Заявки по каналам', `${f.period} · «оплата» — заявки периода, уже оплаченные`, funnel)}</div>
      <div class="actions"><a class="btn" href="/sales/">Открыть сервис «Продажи»</a></div></section>`;
  }

  // ---------- 06 Обучение ----------
  function eduSec(no, ov, x, kpisInOverview) {
    const ks = kpisInOverview ? '' : `<div class="kpis">${ov.kpis.filter((k) => k.department === 'edu').map((k) => kpi(k)).join('')}</div>`;
    const en = x.enr ? barChart(x.enr.points.map((p, i) => ({ label: p.label, value: p.value, cls: i === x.enr.points.length - 1 ? 'cur' : '' })), { fmt: (v) => String(Math.round(v)) }) : '';
    const cr = x.compl ? areaChart(x.compl.points.map((p) => ({ label: p.label, value: p.value, title: fmtValue(p.value, '%') })), { height: 240, fmt: (v) => fmtValue(v, '%') }) : '';
    return `<section class="sec" id="edu">${secHead(no, 'Обучение', 'Курс VibeOps: записи, заполненность потоков, выпуск')}${ks}
      <div class="grid2">${card('', 'Записи на курс', `${GRAIN_N[grain]} · человек`, en)}${card('', 'Доля завершивших курс', `${GRAIN_N[grain]} · по выпущенным потокам`, cr)}</div>
      <div class="actions"><a class="btn" href="/edu/">Открыть сервис «Обучение»</a></div></section>`;
  }

  // ---------- Маркетинг ----------
  function marketingSec(no, ov, x, kpisInOverview) {
    const ks = kpisInOverview ? '' : `<div class="kpis">${ov.kpis.filter((k) => k.department === 'marketing').map((k) => kpi(k)).join('')}</div>`;
    const m = x.mkt;
    const spend = m.channels.filter((c) => Number(c.spend) > 0);
    const sum = spend.reduce((s, c) => s + Number(c.spend), 0);
    const cpl = m.channels.filter((c) => c.cpl !== null).sort((a, b) => b.cpl - a.cpl);
    const romi = m.channels.filter((c) => c.romi !== null).sort((a, b) => b.romi - a.romi);
    const rows = m.campaigns.map((c) => `<tr><td data-label="Кампания">${esc(c.title)}</td><td data-label="Канал">${esc(c.channel_title)}</td>
      <td class="n" data-label="Расход">${fmtMoney(c.spend)}</td><td class="n" data-label="Заявки">${c.no_leads ? '<span class="badge warning">0</span>' : c.leads}</td>
      <td class="n" data-label="CPL">${fmtMoney(c.cpl)}</td><td class="n" data-label="ROMI">${fmtValue(c.romi, '%')}</td></tr>`).join('');
    const sp = x.spend ? barChart(x.spend.points.map((p, i) => ({ label: p.label, value: p.value, cls: i === x.spend.points.length - 1 ? 'cur' : '', title: fmtMoney(p.value) })), { span: 'wide' }) : '';
    return `<section class="sec" id="marketing">${secHead(no, 'Маркетинг', 'Реклама: расход кабинетов Meta, Google, Telegram и бюджета, заявки amoCRM, оплаты 1С')}${ks}
      <div class="grid-wide">${card('', 'Расход на рекламу', `${GRAIN_N[grain]} · чёрный — текущий, неполный`, sp)}
      ${card('mkt-channels', 'Расход по каналам', m.period, spend.length ? donut(spend.map((c) => ({ label: c.channel_title, value: c.spend })), { total: `${fmtShort(sum)} ₸`, cap: 'расход' }) : empty('Расхода за период нет'))}</div>
      <div class="grid2">${card('', 'Цена заявки по каналам (CPL)', `${m.period} · расход / заявки`, cpl.length ? hbars(cpl.map((c) => ({ label: c.channel_title, value: c.cpl, sub: `${c.leads} заявок · расход ${fmtMoney(c.spend)}` })), { one: true }) : empty('Нет данных'))}
      ${card('', 'Окупаемость по каналам (ROMI)', `${m.period} · по выручке курса без НДС`, romi.length ? hbars(romi.map((c) => ({ label: c.channel_title, value: Math.max(0, c.romi), text: fmtValue(c.romi, '%'), cls: c.romi <= 100 ? 'danger' : c.romi < 200 ? 'warning' : '', sub: `слушателей ${c.won} · CAC ${fmtMoney(c.cac)}` })), { one: true }) : empty('Нет данных'))}</div>
      ${card('campaigns', 'Кампании периода', 'самые дорогие · «0» заявок — проверьте UTM-метки', rows ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Кампания</th><th>Канал</th><th class="n">Расход</th><th class="n">Заявки</th><th class="n">CPL</th><th class="n">ROMI</th></tr></thead><tbody>${rows}</tbody></table></div>` : empty('Кампаний нет'))}
      <div class="actions"><a class="btn" href="/marketing/">Открыть сервис «Маркетинг»</a></div></section>`;
  }

  // ---------- HR ----------
  function hrSec(no, ov, x, kpisInOverview) {
    const ks = kpisInOverview ? '' : `<div class="kpis">${ov.kpis.filter((k) => k.department === 'hr' && k.metric_id !== 'headcount').map((k) => kpi(k)).join('')}</div>`;
    const h = x.hr;
    const moves = groupedBars(h.moves.map((m) => m.label), [
      { name: 'Приняты', values: h.moves.map((m) => m.hires), titles: h.moves.map((m) => `${m.hires} чел.`) },
      { name: 'Уволены', values: h.moves.map((m) => m.terminations), cls: 's2', titles: h.moves.map((m) => `${m.terminations} чел.`) }], { fmt: (v) => String(Math.round(v)), span: 'wide' });
    const pay = h.payroll.filter((r) => Number(r.amount) > 0);
    const vac = h.vacancies.map((v) => `<tr><td data-label="Должность">${esc(v.job_title)}</td><td data-label="Отдел">${esc(v.department)}</td>
      <td data-label="Открыта">${dmy(v.opened)}</td><td class="n" data-label="Дней"><span class="badge ${v.days_open > 50 ? 'danger' : v.days_open > 35 ? 'warning' : 'ok'}">${v.days_open}</span></td><td data-label="Источник">${esc(v.source)}</td></tr>`).join('');
    return `<section class="sec" id="hr">${secHead(no, 'HR', 'Кадры 1С:ЗУП и таблица вакансий · без окладов и имён: только суммы по отделам')}${ks}
      <div class="grid-wide">${card('', 'Найм и увольнения', `${GRAIN_N[grain]} · человек`, moves)}
      ${card('payroll', 'ФОТ по отделам', `${h.period} · с налогами · отделы до 3 человек объединены`, pay.length ? donut(pay.map((r) => ({ label: `${r.department} · ${r.people} чел.`, value: r.amount })), { total: `${fmtShort(pay.reduce((s, r) => s + Number(r.amount), 0))} ₸`, cap: 'ФОТ' }) : empty('Нет начислений'))}</div>
      ${card('vacancies', 'Открытые вакансии', 'сколько дней открыта: больше 35 — жёлтая, больше 50 — красная', vac ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Должность</th><th>Отдел</th><th>Открыта</th><th class="n">Дней</th><th>Источник</th></tr></thead><tbody>${vac}</tbody></table></div>` : empty('Открытых вакансий нет'))}
      <div class="actions"><a class="btn" href="/hr/">Открыть сервис «HR»</a></div></section>`;
  }

  // ---------- 08 Операции ----------
  function worst(ms) { const s = (ms || []).map((m) => m.status); return s.includes('danger') ? 'danger' : s.includes('warning') ? 'warning' : 'ok'; }
  function tilesBlock(t) {
    if (!t.tiles.length) return '';
    return `<div class="tiles" id="tiles">${t.tiles.map((x) => x.ok ? `
      <section class="tile" data-service="${esc(x.id)}">
        <header><h3>${esc(x.title)}</h3><span class="badge ${worst(x.metrics)}">${{ ok: 'в норме', warning: 'внимание', danger: 'риск' }[worst(x.metrics)]}</span></header>
        <div>${(x.metrics || []).map((m) => `<div class="row"><span>${esc(m.title)}</span><span class="num"><span class="badge ${esc(m.status)}">${fmtValue(m.value, m.unit)}</span></span></div>`).join('')}</div>
        ${(x.alerts || []).length ? `<ul class="alerts">${x.alerts.map((a) => `<li>${esc(a.text)}</li>`).join('')}</ul>` : ''}
        <div class="foot"><span>обновлено в ${fmtTime(x.generated_at)}</span><a class="btn small" href="${esc(x.base_path)}/" data-open="${esc(x.id)}">Открыть</a></div>
      </section>` : `
      <section class="tile gray" data-service="${esc(x.id)}"><header><h3>${esc(x.title)}</h3><span class="badge gray">нет данных</span></header>
        <p class="muted">Нет данных от сервиса · проверено в ${fmtTime(x.checked_at)}</p></section>`).join('')}</div>`;
  }
  function opsSec(no, x) {
    const dg = x.digest ? card('digest', 'Утренняя сводка', `${x.digest.how} · ${x.digest.date || ''}`, `<pre class="digest">${esc(x.digest.text)}</pre>`) : '';
    return `<section class="sec" id="ops">${secHead(no, 'Операции', 'Сервисы отделов: их показатели, сигналы и вход в работу')}
      ${tilesBlock(x.tiles) || empty('Сервисов отделов для вашей роли нет')}${dg}</section>`;
  }

  // ---------- вкладки ----------
  function buildTabs(ov) {
    const d = ov.departments; const fin = d.includes('finance');
    return [
      ['overview', 'Обзор', true], ['income', 'Доходы и расходы', fin], ['money', 'Деньги', fin], ['clients', 'Клиенты и счета', fin],
      ['sales', 'Продажи', d.includes('sales')], ['marketing', 'Маркетинг', d.includes('marketing')], ['edu', 'Обучение', d.includes('edu')],
      ['hr', 'HR', d.includes('hr')], ['ops', 'Операции', true],
    ].filter((t) => t[2]).map(([id, title]) => ({ id, title, href: `#${id}` }));
  }
  function setTab(id) {
    navEl.querySelectorAll('a[data-tab]').forEach((a) => { if (a.dataset.tab === id) a.setAttribute('aria-current', 'true'); else a.removeAttribute('aria-current'); });
    AIRL.revealTab(navEl);
  }
  let spyRaf = 0;
  function spy() {
    if (spyRaf) return;
    spyRaf = requestAnimationFrame(() => {
      spyRaf = 0;
      let cur = tabs[0] && tabs[0].id;
      for (const t of tabs) { const s = document.getElementById(t.id); if (s && s.getBoundingClientRect().top < 160) cur = t.id; }
      if ((window.innerHeight + window.scrollY) >= document.documentElement.scrollHeight - 4 && tabs.length) cur = tabs[tabs.length - 1].id;
      if (navEl.querySelector('[aria-current]')?.dataset.tab !== cur) setTab(cur);
    });
  }
  navEl.addEventListener('click', (e) => {
    const a = e.target.closest('a[data-tab]'); if (!a) return;
    e.preventDefault();
    const s = document.getElementById(a.dataset.tab);
    if (s) s.scrollIntoView({ behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'start' });
    setTab(a.dataset.tab);
  });

  // ---------- загрузка и раскладка ----------
  const skeleton = () => `${secHead(1, 'Обзор', 'Загружаем показатели…', seg())}<div class="overview-grid"><div class="skeleton"></div><div class="kpis four" aria-busy="true">${'<div class="skeleton"></div>'.repeat(8)}</div></div>`;

  async function render() {
    view.innerHTML = skeleton(); // старые карточки убираем сразу: на экране не бывает цифр другого периода
    try {
      const S = (m) => api(`/hub/api/series?metric=${m}&grain=${grain}`).catch(() => null);
      const [ov, tiles] = await Promise.all([api(`/hub/api/overview?grain=${grain}`), api('/hub/api/tiles').catch(() => ({ tiles: [] }))]);
      const d = ov.departments; const fin = d.includes('finance'); const sales = d.includes('sales'); const edu = d.includes('edu');
      const mk = d.includes('marketing'); const hr = d.includes('hr');
      const [pnl, aging, funnel, fc, digest, rev, np, cash, lead, enr, compl, mkt, spend, hrd] = await Promise.all([
        fin ? api(`/hub/api/pnl?grain=${grain}`) : null, fin ? api('/hub/api/aging') : null,
        sales ? api(`/hub/api/funnel?grain=${grain}`) : null, (fin || sales) ? api('/hub/api/forecast').catch(() => null) : null,
        me.role === 'ceo' ? api('/hub/api/digest').catch(() => null) : null,
        fin ? S('revenue') : null, fin ? S('net_profit') : null, fin ? S('cash_balance') : null,
        sales ? S('lead') : null, edu ? S('enrollments') : null, edu ? S('course_completion_rate') : null,
        mk ? api(`/hub/api/marketing?grain=${grain}`) : null, mk ? S('ad_spend') : null, hr ? api(`/hub/api/hr?grain=${grain}`) : null]);
      const x = { tiles, pnl, aging, funnel, fc, digest, rev, np, cash, lead, enr, compl, mkt, spend, hr: hrd };
      tabs = buildTabs(ov);
      const no = (id) => tabs.findIndex((t) => t.id === id) + 1;
      const kpisInOverview = !fin; // без финансов показатели отдела — в «Обзоре»
      const html = {
        overview: () => overviewSec(no('overview'), ov, x), income: () => incomeSec(no('income'), x), money: () => moneySec(no('money'), x),
        clients: () => clientsSec(no('clients'), x), sales: () => salesSec(no('sales'), ov, x, kpisInOverview), edu: () => eduSec(no('edu'), ov, x, kpisInOverview),
        marketing: () => marketingSec(no('marketing'), ov, x, kpisInOverview), hr: () => hrSec(no('hr'), ov, x, kpisInOverview), ops: () => opsSec(no('ops'), x),
      };
      const cur = navEl.querySelector('[aria-current]')?.dataset.tab;
      navEl.innerHTML = AIRL.nav(tabs, cur && tabs.some((t) => t.id === cur) ? cur : 'overview');
      view.innerHTML = tabs.map((t) => html[t.id]()).join('');
      AIRL.caption(`ТОО AIRL · ТОО AIRL Dev · ${ov.period} · данные 1С по ${dmy(ov.as_of)}`);
      AIRL.updated(new Date());
      view.querySelectorAll('[data-grain]').forEach((b) => b.addEventListener('click', () => {
        grain = b.dataset.grain;
        try { localStorage.setItem('hub.grain', grain); } catch { /* ничего */ }
        render();
      }));
      AIRL.applyWidths(view);
      view.querySelectorAll('[data-open]').forEach((a) => a.addEventListener('click', () => { post('/hub/api/open', { service: a.dataset.open }).catch(() => {}); }));
      spy();
    } catch (e) {
      view.innerHTML = secHead(1, 'Обзор', '', seg()) + errorBox(e.status === 403 ? 'Экран руководителя недоступен для вашей роли' : `Не удалось загрузить показатели: ${e.message}`);
    }
  }

  // Продлеваем токен за 10 минут до конца срока.
  function scheduleRefresh() {
    const ms = Math.max(30000, (me.exp * 1000 - Date.now()) - 10 * 60 * 1000);
    setTimeout(async () => { try { const r = await post('/auth/refresh'); me.exp = r.exp; } catch { /* api() отправит на вход */ } scheduleRefresh(); }, ms);
  }

  (async () => {
    try { me = await AIRL.topbar('Экран руководителя', 'hub', { brandTag: 'h1' }); } catch (e) { view.innerHTML = errorBox('Не удалось открыть хаб: ' + e.message); return; }
    // Старые адреса разделов (#/finance и т. п.) ведут к нужному разделу страницы.
    const OLD = { '#/finance': 'income', '#/sales': 'sales', '#/edu': 'edu', '#team': 'hr' };
    const target = OLD[location.hash] || location.hash.replace(/^#\/?/, '');
    await render();
    if (target && document.getElementById(target)) { document.getElementById(target).scrollIntoView(); setTab(target); }
    window.addEventListener('scroll', spy, { passive: true });
    scheduleRefresh();
    AIRL.registerSW('/');
  })();
})();
