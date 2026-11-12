'use strict';
/* Сервис «HR»: численность и текучесть, вакансии, онбординг (модуль onboarding), ФОТ по отделам.
   Цифры — из metrics и витрины mart_hr; имена сотрудников приходят с сервера уже с маской для ролей не из HR. */
(() => {
  const { esc, api, post, fmtValue, fmtMoney, fmtShort, kpiCard, groupedBars, barChart, donut, hbars, loading, errorBox, empty } = AIRL;
  const B = '/hr';
  const view = document.getElementById('view');
  const nav = document.getElementById('nav');
  const dlg = document.getElementById('dlg');
  let me;
  const isHr = () => ['head_hr', 'staff_hr'].includes(me.role);
  const seesPayroll = () => ['ceo', 'head_hr'].includes(me.role);
  let items = [];
  let curNo = 1;
  const head = (t, sub, right = '') => AIRL.head(curNo, t, sub, right);
  const card = (title, sub, body, cls = '') => `<div class="card ${cls}"><h2>${esc(title)}${sub ? ` <span class="sub">${esc(sub)}</span>` : ''}</h2>${body}</div>`;
  const ROLE = { employee: 'сотрудник', manager: 'руководитель', mentor: 'наставник', hr: 'HR', it: 'ИТ' };
  const KIND = { task: 'задача', document: 'ознакомление', course: 'курс', permit: 'допуск' };
  const dmy = (iso) => (/^\d{4}-\d{2}-\d{2}/.test(String(iso)) ? String(iso).slice(0, 10).split('-').reverse().join('.') : '—');

  function vacancyTable(rows) {
    return rows.length ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Должность</th><th>Отдел</th><th>Открыта</th><th class="n">Дней</th><th>Источник</th><th class="n">Откликов</th><th>Статус</th></tr></thead><tbody>${rows.map((v) => `<tr>
      <td data-label="Должность">${esc(v.job_title)}</td><td data-label="Отдел">${esc(v.department)}</td><td data-label="Открыта">${dmy(v.opened)}</td>
      <td class="n" data-label="Дней">${v.status === 'open' ? `<span class="badge ${v.days_open > 50 ? 'danger' : v.days_open > 35 ? 'warning' : 'ok'}">${v.days_open}</span>` : v.days_open}</td>
      <td data-label="Источник">${esc(v.source)}</td><td class="n" data-label="Откликов">${v.candidates ?? '—'}</td>
      <td data-label="Статус">${v.status === 'open' ? 'открыта' : v.status === 'closed' ? `закрыта ${dmy(v.closed)}` : 'отменена'}</td></tr>`).join('')}</tbody></table></div>` : empty('Вакансий нет');
  }

  async function overview() {
    view.innerHTML = head('HR', 'Загружаем…') + loading(5);
    const d = await api(`${B}/api/overview`);
    const lower = new Set(['turnover_rate', 'time_to_hire', 'open_vacancies', 'payroll_fund']);
    const kp = d.kpis.map((k) => kpiCard({ ...k, id: k.metric_id }, { lowerIsBetter: lower.has(k.metric_id), sub: `было ${fmtValue(k.prev_value, k.unit)}` })).join('')
      + (d.on_time ? `<div class="kpi ${esc(d.on_time.status)}"><div class="l"><span>Онбординг в срок</span><span class="dot" aria-hidden="true"></span></div><div class="v">${fmtValue(d.on_time.value, '%')}</div><div class="s">модуль onboarding · ${esc(d.on_time.period)}</div></div>` : '');
    const moves = groupedBars(d.moves.map((m) => m.label), [
      { name: 'Приняты', values: d.moves.map((m) => m.hires), titles: d.moves.map((m) => `${m.hires} чел.`) },
      { name: 'Уволены', values: d.moves.map((m) => m.terminations), cls: 's2', titles: d.moves.map((m) => `${m.terminations} чел.`) }], { fmt: (v) => String(Math.round(v)) });
    const pay = d.payroll ? card('ФОТ по отделам', `${d.payroll_month} · с налогами работодателя · отделы до 3 человек объединены`,
      donut(d.payroll.map((r) => ({ label: `${r.department} · ${r.people} чел.`, value: r.amount })), { total: `${fmtShort(d.payroll.reduce((s, r) => s + Number(r.amount), 0))} ₸`, cap: 'ФОТ' }))
      : card('Численность по месяцам', 'на конец месяца', barChart(d.headcount.map((p, i) => ({ label: p.label, value: p.value, cls: i === d.headcount.length - 1 ? 'cur' : '' })), { fmt: (v) => String(Math.round(v)) }));
    view.innerHTML = head('HR', 'Текущий месяц с 1-го по вчера против тех же дней прошлого · кадры 1С:ЗУП, вакансии — таблица HR')
      + `<div class="kpis">${kp}</div>`
      + `<div class="grid2">${card('Найм и увольнения', '12 месяцев · человек', moves)}${pay}</div>`;
  }

  async function vacancies() {
    view.innerHTML = head('Вакансии', 'Загружаем…') + loading(1);
    const d = await api(`${B}/api/vacancies`);
    const open = d.rows.filter((v) => v.status === 'open');
    view.innerHTML = head('Вакансии', `Открыто: ${open.length} · закрытые за полгода — ниже · срок закрытия считается в metrics (time_to_hire)`)
      + card('Открытые', 'дольше 35 дней — жёлтые, дольше 50 — красные', vacancyTable(open))
      + card('Закрытые и отменённые', 'за 180 дней', vacancyTable(d.rows.filter((v) => v.status !== 'open')));
  }

  async function onboarding() {
    view.innerHTML = head('Новые сотрудники', 'Загружаем…') + loading(2);
    const d = await api(`${B}/api/onboarding`);
    const rows = d.rows.map((r) => `<tr><td data-label="Сотрудник"><a href="#/person/${esc(r.instance_id)}">${esc(r.display_name || '—')}</a></td>
      <td data-label="Должность">${esc(r.position)}</td><td data-label="Отдел">${esc(r.department)}</td><td data-label="Пришёл">${dmy(r.started_on)}</td>
      <td class="n" data-label="День">${r.day_no}</td><td class="n" data-label="Сделано">${r.items_done} из ${r.items_total}</td>
      <td class="n" data-label="Просрочено">${r.items_overdue > 0 ? `<span class="badge danger">${r.items_overdue}</span>` : '—'}</td></tr>`).join('');
    const chart = d.series.length ? barChart(d.series.map((s, i) => ({ label: s.period.slice(5) + '.' + s.period.slice(2, 4), value: s.value, cls: i === d.series.length - 1 ? 'cur' : '' })), { fmt: (v) => fmtValue(v, '%'), height: 200 }) : empty('Пока нет данных');
    view.innerHTML = head('Новые сотрудники', `${d.scope} · модуль onboarding · ${isHr() ? 'имена — «Фамилия И.»' : 'имена скрыты: их видит только HR'}`)
      + `<div class="grid2">${card('Пункты онбординга, закрытые в срок', 'по месяцу срока · светофор: 85% и 70%', chart)}
         ${card('Сейчас', '', `<div class="mini"><div><div class="t">Онбординг в срок</div><div class="n">${d.on_time ? fmtValue(d.on_time.value, '%') : '—'}</div></div><div><div class="t">Просрочено пунктов</div><div class="n">${d.rows.reduce((s, r) => s + Number(r.items_overdue), 0)}</div></div></div>`)}</div>`
      + card('Онбординг', 'активные и пришедшие за 120 дней', rows ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Сотрудник</th><th>Должность</th><th>Отдел</th><th>Пришёл</th><th class="n">День</th><th class="n">Сделано</th><th class="n">Просрочено</th></tr></thead><tbody>${rows}</tbody></table></div>` : empty('Новых сотрудников за последние 120 дней нет'));
  }

  async function personView(id) {
    view.innerHTML = head('Онбординг', 'Загружаем…') + loading(1);
    const d = await api(`${B}/api/onboarding/${encodeURIComponent(id)}`);
    const p = d.person;
    const rows = d.tasks.map((t) => `<tr><td data-label="Пункт">${esc(t.title)}</td><td data-label="Вид">${esc(KIND[t.kind] || t.kind)}</td><td data-label="Кто">${esc(ROLE[t.responsible_role] || t.responsible_role)}</td>
      <td data-label="Срок">${dmy(t.due_date)}</td>
      <td data-label="Статус">${t.status === 'done' ? `<span class="badge ${t.on_time ? 'ok' : 'warning'}">${t.on_time ? 'в срок' : 'с опозданием'} · ${dmy(t.done_on)}</span>` : t.overdue ? `<span class="badge danger">просрочен ${t.days_overdue} дн.</span>` : t.status === 'skipped' ? 'пропущен' : 'открыт'}</td>
      <td data-label="">${d.can_edit && t.status === 'open' ? `<button class="btn small js-done" data-id="${esc(t.id)}">Готово</button>` : ''}</td></tr>`).join('');
    view.innerHTML = head(p.display_name || 'Сотрудник', `${p.position} · ${p.department} · пришёл ${dmy(p.started_on)} · день ${p.day_no} · сделано ${p.pct_done ?? 0}%`)
      + card('Чек-лист адаптации', 'шаблон «Адаптация в AIRL»', rows ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Пункт</th><th>Вид</th><th>Кто</th><th>Срок</th><th>Статус</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>` : empty('Пунктов нет'))
      + '<p><a href="#/onboarding">← Все новые сотрудники</a></p>';
    view.querySelectorAll('.js-done').forEach((b) => b.addEventListener('click', () => {
      dlg.innerHTML = `<form id="df"><h2>Отметить пункт выполненным</h2><label for="c">Комментарий (необязательно)</label><textarea id="c" name="comment" maxlength="500"></textarea>
        <p class="neg" id="fe" role="alert" hidden></p><div class="form-row"><button class="btn secondary" type="button" id="x">Отмена</button><button class="btn" type="submit">Готово</button></div></form>`;
      dlg.querySelector('#x').onclick = () => dlg.close();
      dlg.querySelector('#df').onsubmit = async (e) => {
        e.preventDefault();
        try { await post(`${B}/api/onboarding/tasks/${encodeURIComponent(b.dataset.id)}/done`, { comment: e.target.comment.value }); dlg.close(); personView(id); }
        catch (ex) { const fe = dlg.querySelector('#fe'); fe.textContent = navigator.onLine ? ex.message : 'Нет сети: отметка не сохранена, нажмите ещё раз'; fe.hidden = false; }
      };
      dlg.showModal();
    }));
  }

  async function payroll() {
    view.innerHTML = head('ФОТ и отсутствия', 'Загружаем…') + loading(2);
    const d = await api(`${B}/api/payroll`);
    const fund = barChart(d.fund.map((f, i) => ({ label: f.period.slice(5) + '.' + f.period.slice(2, 4), value: f.value, cls: i === d.fund.length - 1 ? 'cur' : '', title: fmtMoney(f.value) })), { height: 220 });
    const abs = d.absences.map((a) => `<tr><td data-label="Отдел">${esc(a.department)}</td><td class="n" data-label="Отпуск, дн.">${a.vacation_days}</td><td class="n" data-label="Больничный, дн.">${a.sick_days}</td></tr>`).join('');
    view.innerHTML = head('ФОТ и отсутствия', d.note)
      + `<div class="grid2">${card('Фонд оплаты труда по месяцам', 'metrics.payroll_fund · текущий месяц — по вчера, начисление ЗУП предварительное', fund)}
         ${card('ФОТ по отделам', `${d.month} · сумма и число людей`, hbars(d.by_department.map((r) => ({ label: r.department, value: r.amount, sub: `${r.people} чел.` })), { one: true }))}</div>`
      + card('Отпуска и больничные', 'дни за 3 месяца, по отделам (без людей)', abs ? `<table class="tbl cards"><thead><tr><th>Отдел</th><th class="n">Отпуск, дн.</th><th class="n">Больничный, дн.</th></tr></thead><tbody>${abs}</tbody></table>` : empty('Отсутствий нет'));
  }

  async function route() {
    const [name, arg] = (location.hash || '#/overview').slice(2).split('?')[0].split('/');
    { const cur = name === 'person' ? 'onboarding' : name; nav.innerHTML = AIRL.nav(items, cur); curNo = Math.max(1, items.findIndex((i) => i.id === cur) + 1); AIRL.revealTab(nav); }
    try {
      if (name === 'vacancies') await vacancies();
      else if (name === 'onboarding') await onboarding();
      else if (name === 'person' && arg) await personView(arg);
      else if (name === 'payroll' && seesPayroll()) await payroll();
      else await overview();
      AIRL.applyWidths(view);
    } catch (e) { view.innerHTML = errorBox(e.status === 404 ? 'Не найдено или недоступно для вашей роли' : e.status === 403 ? e.message : `Не удалось загрузить данные: ${e.message}`); }
  }

  (async () => {
    try { me = await AIRL.topbar('HR', 'hr'); } catch (e) { view.innerHTML = errorBox(e.message); return; }
    AIRL.caption('HR · численность, текучесть, вакансии, онбординг и ФОТ по отделам · 1С:ЗУП и таблица HR');
    if (!['ceo', 'head_hr', 'staff_hr'].includes(me.role)) { view.innerHTML = errorBox('Сервис «HR» недоступен для вашей роли'); return; }
    items = [{ id: 'overview', title: 'Обзор', href: '#/overview' }, { id: 'vacancies', title: 'Вакансии', href: '#/vacancies' },
      { id: 'onboarding', title: 'Новые сотрудники', href: '#/onboarding' }];
    if (seesPayroll()) items.push({ id: 'payroll', title: 'ФОТ и отсутствия', href: '#/payroll' });
    if (me.role === 'staff_hr' && !location.hash) location.hash = '#/onboarding';
    window.addEventListener('hashchange', route); route(); AIRL.registerSW(`${B}/`);
    post('/hub/api/open', { service: 'hr' }).catch(() => {});
  })();
})();
