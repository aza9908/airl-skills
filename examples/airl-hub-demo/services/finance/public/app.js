'use strict';
/* Сервис «Финансы». Экраны и тексты — из SPEC.md и MODULE.md модулей pnl-cashflow, receivables,
   bank-reconciliation. Цифры приходят с сервера готовыми; браузер только показывает. */
(() => {
  const { esc, api, post, fmtValue, fmtMoney, fmtShort, kpiCard, barChart, loading, errorBox, empty } = AIRL;
  const B = '/finance';
  const view = document.getElementById('view');
  const nav = document.getElementById('nav');
  const dlg = document.getElementById('dlg');
  let me;
  const canEdit = () => ['head_finance', 'staff_finance'].includes(me.role);
  const LOWER = new Set(['receivables_overdue']);
  const items = [
    { id: 'overview', title: 'Обзор', href: '#/overview' }, { id: 'pnl', title: 'ОПиУ', href: '#/pnl' },
    { id: 'cash', title: 'ДДС', href: '#/cash' }, { id: 'debtors', title: 'Должники', href: '#/debtors' },
    { id: 'bank', title: 'Сверка банка', href: '#/bank' },
  ];
  let curNo = 1;
  const head = (t, sub, right = '') => AIRL.head(curNo, t, sub, right);

  async function overview() {
    view.innerHTML = head('Финансы', 'Загружаем…') + loading(5);
    const d = await api(`${B}/api/overview`);
    const mods = d.modules.map((m) => `<div class="kpi ${esc(m.status)}"><div class="l">${esc({ bank_unmatched_count: 'Неразнесённые строки выписки', receivables_overdue_share: 'Доля просрочки в дебиторке' }[m.metric_id] || m.metric_id)}</div><div class="v">${fmtValue(m.value, m.unit)}</div><div class="s">модуль, на ${esc(m.period)}</div></div>`).join('');
    const rev = d.revenue.map((r, i) => ({ label: r.period.slice(5) + '.' + r.period.slice(2, 4), value: r.value, cls: i === d.revenue.length - 1 ? 'cur' : '' }));
    view.innerHTML = head('Финансы', 'Текущий месяц с 1-го по вчера против тех же дней прошлого месяца · цифры из metrics')
      + `<div class="kpis">${d.kpis.map((k) => kpiCard({ ...k, id: k.metric_id }, { lowerIsBetter: LOWER.has(k.metric_id), sub: `было ${fmtValue(k.prev_value, k.unit)}` })).join('')}${mods}</div>`
      + `<div class="card"><h2>Выручка по месяцам <span class="sub">без НДС и внутригрупповых · последний месяц неполный</span></h2>${barChart(rev, { fmt: fmtShort, span: 'full' })}</div>`
      + `<div class="grid3"><a class="btn" href="#/debtors">Должники →</a><a class="btn secondary" href="#/bank">Сверка банка →</a><a class="btn secondary" href="#/pnl">ОПиУ →</a></div>`;
  }

  async function pnl(params) {
    view.innerHTML = head('ОПиУ', 'Загружаем…') + loading(2);
    const d = await api(`${B}/api/pnl?month=${encodeURIComponent(params.get('month') || '')}&branch=${encodeURIComponent(params.get('branch') || 'all')}`);
    const sel = `<label class="sr-only" for="m">Месяц</label><select id="m">${d.months.map((m) => `<option ${m === d.month ? 'selected' : ''}>${m}</option>`).join('')}</select>
      <label class="sr-only" for="b">Юрлицо</label><select id="b">${[['all', 'Компания (без внутригрупповых)'], ['airl', 'ТОО AIRL'], ['airl_dev', 'ТОО AIRL Dev']].map(([v, t]) => `<option value="${v}" ${v === d.branch ? 'selected' : ''}>${t}</option>`).join('')}</select>`;
    const pre = d.lines.some((l) => l.preliminary);
    const rows = d.lines.map((l) => {
      const cls = l.line_code === '=gross_profit' ? 'is-margin' : l.line_code === '=net_profit' ? 'is-net' : l.line_kind === 'section' || l.line_kind === 'subtotal' ? 'is-section' : l.depth > 1 ? 'is-sub' : '';
      const dev = l.deviation === null ? '—' : `<span class="${l.deviation < 0 ? 'neg' : 'pos'}">${fmtMoney(l.deviation)}</span>`;
      return `<tr class="${cls}"><td data-label="Строка">${esc(l.line_title)}</td><td class="n" data-label="Факт">${fmtMoney(l.fact)}</td><td class="n" data-label="Бюджет">${fmtMoney(l.budget)}</td><td class="n" data-label="Отклонение">${dev}</td><td class="n" data-label="Год назад">${fmtMoney(l.fact_ly)}</td><td class="n" data-label="% выручки">${l.pct_of_revenue === null ? '—' : fmtValue(l.pct_of_revenue, '%')}</td></tr>`;
    }).join('');
    view.innerHTML = head('ОПиУ', `Управленческий отчёт о прибылях и убытках · ${d.month}`, `<div class="form-row">${sel}</div>`)
      + (pre ? '<div class="note">Предварительно: себестоимость и начисления могут измениться после закрытия месяца в 1С.</div>' : '')
      + (d.unmapped ? `<div class="note">Есть счета без статьи: ${d.unmapped}. Они в строке «Не разнесено по статьям».</div>` : '')
      + `<div class="card"><div class="scroll-x"><table class="tbl cards"><thead><tr><th>Строка</th><th class="n">Факт</th><th class="n">Бюджет</th><th class="n">Отклонение</th><th class="n">Год назад</th><th class="n">% выручки</th></tr></thead><tbody>${rows}</tbody></table></div>
        <p class="muted">Доход «+», расход «−»; отклонение «+» — лучше бюджета. Модуль pnl-cashflow, данные 1С через хранилище.</p></div>`;
    const go = () => { location.hash = `#/pnl?month=${view.querySelector('#m').value}&branch=${view.querySelector('#b').value}`; };
    view.querySelector('#m').onchange = go; view.querySelector('#b').onchange = go;
  }

  async function cash() {
    view.innerHTML = head('ДДС', 'Загружаем…') + loading(2);
    const d = await api(`${B}/api/cashflow`);
    const pts = d.balance.map((r, i) => ({ label: r.period.slice(5) + '.' + r.period.slice(2, 4), value: r.closing, cls: i === d.balance.length - 1 ? 'cur' : '' }));
    const rows = d.balance.slice().reverse().map((r) => `<tr><td data-label="Месяц">${r.period}</td><td class="n" data-label="Начало">${fmtMoney(r.opening)}</td><td class="n" data-label="Операционная">${fmtMoney(r.operating)}</td><td class="n" data-label="Инвестиционная">${fmtMoney(r.investing)}</td><td class="n" data-label="Финансовая">${fmtMoney(r.financing)}</td><td class="n" data-label="Конец"><b>${fmtMoney(r.closing)}</b></td></tr>`).join('');
    view.innerHTML = head('Движение денег', 'Все счета и касса обоих юрлиц, в тенге · переводы между своими юрлицами в сумме дают ноль')
      + `<div class="card"><h2>Остаток на конец месяца</h2>${barChart(pts, { fmt: fmtShort, span: 'full' })}</div>`
      + `<div class="card"><div class="scroll-x"><table class="tbl cards"><thead><tr><th>Месяц</th><th class="n">Начало</th><th class="n">Операционная</th><th class="n">Инвестиционная</th><th class="n">Финансовая</th><th class="n">Конец</th></tr></thead><tbody>${rows}</tbody></table></div></div>`;
  }

  async function debtors() {
    view.innerHTML = head('Должники', 'Загружаем…') + loading(1);
    const d = await api(`${B}/api/debtors`);
    const rows = d.rows.filter((r) => r.overdue > 0 || r.not_due > 0).map((r) => `<tr>
      <td data-label="Клиент"><a href="#/client/${esc(r.client_id)}">${esc(r.client_name)}</a></td>
      <td class="n" data-label="Весь долг">${fmtMoney(r.open_total)}</td><td class="n" data-label="Просрочено">${r.overdue > 0 ? `<span class="neg">${fmtMoney(r.overdue)}</span>` : '—'}</td>
      <td class="n" data-label="90+ дней">${r.overdue_90_plus > 0 ? fmtMoney(r.overdue_90_plus) : '—'}</td><td class="n" data-label="Дней">${r.max_days_overdue || '—'}</td>
      <td data-label="Последнее действие">${r.last_action_at ? esc(new Date(r.last_action_at).toLocaleDateString('ru-RU')) + ' · ' + esc(r.last_action_result) : '—'}</td>
      <td data-label="">${canEdit() ? `<button class="btn small js-call" data-client="${esc(r.client_id)}" data-name="${esc(r.client_name)}">Записать звонок</button>` : ''}</td></tr>`).join('');
    view.innerHTML = head('Должники', `Просроченная дебиторка: ${fmtMoney(d.overdue.value)} — та же цифра, что на экране руководителя`)
      + `<div class="card">${rows ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Клиент</th><th class="n">Весь долг</th><th class="n">Просрочено</th><th class="n">90+ дней</th><th class="n">Дней</th><th>Последнее действие</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>` : empty('Просроченных долгов нет')}</div>`;
    view.querySelectorAll('.js-call').forEach((b) => b.addEventListener('click', () => callForm(b.dataset.client, b.dataset.name)));
  }

  async function client(id) {
    view.innerHTML = head('Клиент', 'Загружаем…') + loading(1);
    const d = await api(`${B}/api/debtors/${encodeURIComponent(id)}`);
    const docs = d.docs.map((x) => `<tr><td data-label="Документ">${esc(x.doc_no)}</td><td data-label="Дата">${esc(x.doc_date)}</td><td data-label="Срок">${esc(x.effective_due_date || '—')}</td><td class="n" data-label="Сумма">${fmtMoney(x.amount)}</td><td class="n" data-label="Остаток">${fmtMoney(x.balance)}</td><td data-label="Статус"><span class="badge ${x.bucket === 'current' ? 'ok' : 'danger'}">${esc(x.bucket === 'current' ? 'срок не наступил' : x.bucket + ' дн.')}</span></td></tr>`).join('');
    const acts = d.actions.map((a) => `<li><span class="badge gray">${esc(new Date(a.created_at).toLocaleDateString('ru-RU'))}</span><span>${esc(a.kind)} · ${esc(a.result)}${a.comment ? ' — ' + esc(a.comment) : ''} <span class="muted">(${esc(a.created_by)})</span></span></li>`).join('');
    view.innerHTML = head(d.client.name, d.client.kind === 'person' ? 'Физлицо · ' + (d.client.phone || '') : 'Компания', canEdit() ? '<button class="btn js-call">Записать звонок</button>' : '')
      + `<div class="card"><h2>Документы с остатком</h2>${docs ? `<table class="tbl cards"><thead><tr><th>Документ</th><th>Дата</th><th>Срок</th><th class="n">Сумма</th><th class="n">Остаток</th><th>Статус</th></tr></thead><tbody>${docs}</tbody></table>` : empty('Долгов нет')}</div>`
      + `<div class="card"><h2>Действия</h2>${acts ? `<ul class="alert-list">${acts}</ul>` : empty('Действий ещё не было')}</div>`;
    const b = view.querySelector('.js-call'); if (b) b.onclick = () => callForm(d.client.client_id, d.client.name);
  }

  function callForm(clientId, name) {
    dlg.innerHTML = `<form method="dialog" id="cf"><h2>Звонок: ${esc(name)}</h2>
      <label for="k">Что сделали</label><select id="k" name="kind"><option value="call">Звонок</option><option value="message">Сообщение</option><option value="meeting">Встреча</option><option value="letter">Письмо</option><option value="claim">Претензия</option></select>
      <label for="r">Результат</label><select id="r" name="result"><option value="reached">Дозвонились</option><option value="not_reached">Не дозвонились</option><option value="promised">Клиент обещал оплатить</option><option value="disputed">Спорит с суммой</option><option value="refused">Отказ</option><option value="other">Другое</option></select>
      <div class="form-row" id="pr" hidden><div><label for="pd">Дата оплаты</label><input id="pd" type="date" name="promised_date"></div><div><label for="pa">Сумма, ₸</label><input id="pa" type="number" min="1" step="1" name="promised_amount"></div></div>
      <label for="c">Комментарий</label><textarea id="c" name="comment" maxlength="1000"></textarea>
      <label for="n">Следующий контакт</label><input id="n" type="date" name="next_contact_date">
      <p class="error neg" id="fe" role="alert" hidden></p>
      <div class="form-row"><button class="btn secondary" value="cancel" type="button" id="cancel">Отмена</button><button class="btn" type="submit" id="save">Сохранить</button></div></form>`;
    const f = dlg.querySelector('#cf');
    f.result.onchange = () => { dlg.querySelector('#pr').hidden = f.result.value !== 'promised'; };
    dlg.querySelector('#cancel').onclick = () => dlg.close();
    f.onsubmit = async (e) => {
      e.preventDefault();
      const fe = dlg.querySelector('#fe'); fe.hidden = true;
      const data = Object.fromEntries(new FormData(f));
      try { await post(`${B}/api/debtors/${encodeURIComponent(clientId)}/actions`, data); dlg.close(); route(); }
      catch (ex) { fe.textContent = navigator.onLine ? ex.message : 'Звонок не сохранён. Текст остался в форме — нажмите «Сохранить» ещё раз'; fe.hidden = false; }
    };
    dlg.showModal();
  }

  async function bank() {
    view.innerHTML = head('Сверка банка', 'Загружаем…') + loading(2);
    const d = await api(`${B}/api/bank`);
    const ks = d.metrics.map((m) => `<div class="kpi ${esc(m.status)}"><div class="l">${esc(m.metric_id === 'bank_unmatched_count' ? 'Не разнесено дольше 2 дней' : 'Разнесено по подсказке')}</div><div class="v">${fmtValue(m.value, m.unit)}</div><div class="s">на ${esc(m.period)}</div></div>`).join('');
    const sug = d.suggestions.map((s) => `<tr><td data-label="Дата">${esc(s.value_date)}</td><td data-label="Плательщик">${esc(s.counterparty_name || '—')}</td><td class="n" data-label="Сумма">${fmtMoney(s.amount)}</td>
      <td data-label="Документ">${(s.allocations || []).map((a) => esc(a.doc_no)).join(', ')}</td><td data-label="Уверенность"><span class="badge ${s.confidence === 'high' ? 'ok' : s.confidence === 'medium' ? 'warning' : 'danger'}">${esc(s.confidence)}</span></td>
      <td data-label="">${canEdit() ? `<button class="btn small js-ok" data-id="${s.match_id}">Подтвердить</button> <button class="btn small secondary js-no" data-id="${s.match_id}">Отклонить</button>` : ''}</td></tr>`).join('');
    const un = d.unmatched.map((s) => `<tr><td data-label="Дата">${esc(s.value_date)}</td><td data-label="Плательщик">${esc(s.counterparty_name || '—')}</td><td class="n" data-label="Сумма">${fmtMoney(s.amount)}</td><td data-label="Назначение">${esc(s.purpose || '')}</td><td data-label="Дней">${s.age_days}${s.overdue ? ' <span class="badge danger">долго</span>' : ''}</td></tr>`).join('');
    view.innerHTML = head('Сверка банка', 'Строки выписок двух банков, которых ещё нет в 1С · подбор: сумма + БИН + номер документа в назначении')
      + `<div class="kpis">${ks}</div>`
      + `<div class="card"><h2>Подсказки модуля</h2>${sug ? `<table class="tbl cards"><thead><tr><th>Дата</th><th>Плательщик</th><th class="n">Сумма</th><th>Документ</th><th>Уверенность</th><th></th></tr></thead><tbody>${sug}</tbody></table>` : empty('Подсказок нет — все строки разобраны')}</div>`
      + `<div class="card"><h2>Не разнесено</h2>${un ? `<table class="tbl cards"><thead><tr><th>Дата</th><th>Плательщик</th><th class="n">Сумма</th><th>Назначение</th><th>Дней</th></tr></thead><tbody>${un}</tbody></table>` : empty('Все строки выписки разнесены')}</div>`;
    view.querySelectorAll('.js-ok').forEach((b) => b.addEventListener('click', async () => { b.disabled = true; try { await post(`${B}/api/bank/${b.dataset.id}/confirm`); bank(); } catch (e) { alert(e.message); b.disabled = false; } }));
    view.querySelectorAll('.js-no').forEach((b) => b.addEventListener('click', async () => {
      const reason = prompt('Почему отклоняете? (обязательно)'); if (!reason) return;
      try { await post(`${B}/api/bank/${b.dataset.id}/reject`, { reason }); bank(); } catch (e) { alert(e.message); }
    }));
  }

  async function route() {
    const [p, qs] = (location.hash || '#/overview').slice(2).split('?');
    const params = new URLSearchParams(qs || '');
    const [name, arg] = p.split('/');
    { const cur = name === 'client' ? 'debtors' : name; nav.innerHTML = AIRL.nav(items, cur); curNo = Math.max(1, items.findIndex((i) => i.id === cur) + 1); AIRL.revealTab(nav); }
    try {
      if (name === 'pnl') await pnl(params);
      else if (name === 'cash') await cash();
      else if (name === 'debtors') await debtors();
      else if (name === 'client' && arg) await client(arg);
      else if (name === 'bank') await bank();
      else await overview();
    } catch (e) { view.innerHTML = errorBox(e.status === 403 ? 'Нет доступа для вашей роли' : `Не удалось загрузить данные: ${e.message}`); }
  }

  (async () => {
    try { me = await AIRL.topbar('Финансы', 'finance'); } catch (e) { view.innerHTML = errorBox(e.message); return; }
    AIRL.caption('Финансы · ОПиУ, движение денег, должники и сверка банка · данные 1С и двух банков');
    if (!['ceo', 'head_finance', 'staff_finance'].includes(me.role)) { view.innerHTML = errorBox('Сервис «Финансы» недоступен для вашей роли'); return; }
    window.addEventListener('hashchange', route); route(); AIRL.registerSW(`${B}/`);
    post('/hub/api/open', { service: 'finance' }).catch(() => {});
  })();
})();
