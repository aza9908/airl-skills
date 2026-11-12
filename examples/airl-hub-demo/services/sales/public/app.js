'use strict';
/* Сервис «Продажи»: воронка заявок amoCRM, план-факт (модуль plan-fact), напоминания по своим заявкам. */
(() => {
  const { esc, api, post, fmtValue, kpiCard, barChart, loading, errorBox, empty } = AIRL;
  const B = '/sales';
  const view = document.getElementById('view');
  const nav = document.getElementById('nav');
  const dlg = document.getElementById('dlg');
  let me;
  const items = [{ id: 'overview', title: 'Воронка', href: '#/overview' }, { id: 'plan', title: 'План-факт', href: '#/plan' }, { id: 'leads', title: 'Открытые заявки', href: '#/leads' }];
  let curNo = 1;
  const head = (t, sub, right = '') => AIRL.head(curNo, t, sub, right);
  const PLAN_TITLE = { 'plan_completion:revenue': 'План по выручке', 'plan_completion:lead': 'План по заявкам', 'plan_completion:enrollments': 'План по записям на курс' };

  async function overview() {
    view.innerHTML = head('Продажи', 'Загружаем…') + loading(4);
    const d = await api(`${B}/api/overview`);
    const plan = d.plan.map((p) => `<div class="kpi ${esc(p.status)}"><div class="l">${esc(PLAN_TITLE[p.metric_id] || p.metric_id)}</div><div class="v">${fmtValue(p.value, '%')}</div><div class="s">модуль план-факт · ${esc(p.period)} · светофор по прогнозу</div></div>`).join('');
    const rows = d.funnel.map((c) => `<tr><td data-label="Канал">${esc(c.channel)}</td><td class="n" data-label="Заявки">${c.leads}</td><td class="n" data-label="В работе">${c.open}</td><td class="n" data-label="Отказ">${c.lost}</td><td class="n" data-label="Оплата">${c.won}</td></tr>`).join('');
    view.innerHTML = head('Продажи', 'Текущий месяц с 1-го по вчера · заявки из amoCRM, оплаты из 1С · цифры из metrics')
      + `<div class="kpis">${d.kpis.map((k) => kpiCard({ ...k, id: k.metric_id }, { sub: `было ${fmtValue(k.prev_value, k.unit)}` })).join('')}${plan}</div>`
      + `<div class="grid2"><div class="card"><h2>Заявки по месяцам <span class="sub">без дублей</span></h2>${barChart(d.series.map((s, i) => ({ label: s.label, value: s.value, cls: i === d.series.length - 1 ? 'cur' : '' })), { fmt: (v) => String(Math.round(v)) })}</div>
         <div class="card"><h2>Каналы этого месяца</h2>${rows ? `<table class="tbl cards"><thead><tr><th>Канал</th><th class="n">Заявки</th><th class="n">В работе</th><th class="n">Отказ</th><th class="n">Оплата</th></tr></thead><tbody>${rows}</tbody></table>` : empty('Заявок пока нет')}</div></div>`;
  }

  async function plan() {
    view.innerHTML = head('План-факт', 'Загружаем…') + loading(3);
    const d = await api(`${B}/api/plan`);
    const isHead = me.role === 'head_sales';
    const rows = d.current.map((p) => `<tr><td data-label="Показатель">${esc(p.title)}</td><td class="n" data-label="План">${fmtValue(p.plan_value, p.unit)}</td><td class="n" data-label="Факт">${fmtValue(p.fact_value, p.unit)}</td>
      <td class="n" data-label="Прогноз">${fmtValue(p.forecast_value, p.unit)}</td><td class="n" data-label="Прогноз, %"><span class="badge ${esc(p.status)}">${fmtValue(p.forecast_pct, '%')}</span></td>
      <td data-label="">${isHead ? `<button class="btn small js-plan" data-metric="${esc(p.metric_id)}" data-month="${esc(String(p.month).slice(0, 7))}" data-value="${esc(p.plan_value)}">Изменить план</button>` : ''}</td></tr>`).join('');
    view.innerHTML = head('План-факт', 'Месяц целиком · прогноз = факт / прошедшие дни × дни месяца (это оценка)')
      + `<div class="card">${rows ? `<table class="tbl cards"><thead><tr><th>Показатель</th><th class="n">План</th><th class="n">Факт</th><th class="n">Прогноз</th><th class="n">Прогноз, %</th><th></th></tr></thead><tbody>${rows}</tbody></table>` : empty('Планов на этот месяц нет')}
         ${isHead ? '' : '<p class="muted">Менять план может только руководитель продаж.</p>'}</div>`;
    view.querySelectorAll('.js-plan').forEach((b) => b.addEventListener('click', () => planForm(b.dataset)));
  }

  function planForm(ds) {
    dlg.innerHTML = `<form id="pf"><h2>Изменить план: ${esc(ds.metric)} · ${esc(ds.month)}</h2>
      <label for="v">Новый план</label><input id="v" name="value" type="number" min="1" step="1" value="${esc(ds.value)}" required>
      <label for="c">Почему меняем (обязательно)</label><textarea id="c" name="comment" required maxlength="500"></textarea>
      <p class="neg" id="fe" role="alert" hidden></p>
      <div class="form-row"><button class="btn secondary" type="button" id="x">Отмена</button><button class="btn" type="submit">Сохранить</button></div></form>`;
    dlg.querySelector('#x').onclick = () => dlg.close();
    dlg.querySelector('#pf').onsubmit = async (e) => {
      e.preventDefault();
      const f = e.target; const fe = dlg.querySelector('#fe');
      try { await post(`${B}/api/plan`, { metric_id: ds.metric, month: ds.month, value: Number(f.value.value), comment: f.comment.value }); dlg.close(); plan(); }
      catch (ex) { fe.textContent = ex.message; fe.hidden = false; }
    };
    dlg.showModal();
  }

  async function leads() {
    view.innerHTML = head('Открытые заявки', 'Загружаем…') + loading(1);
    const d = await api(`${B}/api/leads`);
    const rows = d.rows.map((l) => `<tr><td data-label="Заявка">${esc(l.lead_id)}</td><td data-label="Дата">${esc(l.created_date)}</td><td data-label="Канал">${esc(l.channel)}</td><td data-label="Статус">${esc(l.status)}</td>
      <td data-label="Менеджер">${esc(l.manager)}</td><td data-label="Перезвонить">${l.followup_date ? esc(l.followup_date) : '—'}</td>
      <td data-label=""><button class="btn small js-fu" data-id="${esc(l.lead_id)}">Перезвонить</button></td></tr>`).join('');
    view.innerHTML = head(d.scope, 'Статусы меняются в amoCRM; здесь — напоминания отдела · контакты клиента в хаб не загружаются')
      + `<div class="card">${rows ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Заявка</th><th>Дата</th><th>Канал</th><th>Статус</th><th>Менеджер</th><th>Перезвонить</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>` : empty('Открытых заявок нет')}</div>`;
    view.querySelectorAll('.js-fu').forEach((b) => b.addEventListener('click', () => {
      dlg.innerHTML = `<form id="ff"><h2>Перезвонить по заявке ${esc(b.dataset.id)}</h2><label for="d">Когда</label><input id="d" name="due_date" type="date" required>
        <label for="c">Комментарий</label><textarea id="c" name="comment" maxlength="1000"></textarea><p class="neg" id="fe" role="alert" hidden></p>
        <div class="form-row"><button class="btn secondary" type="button" id="x">Отмена</button><button class="btn" type="submit">Сохранить</button></div></form>`;
      dlg.querySelector('#x').onclick = () => dlg.close();
      dlg.querySelector('#ff').onsubmit = async (e) => {
        e.preventDefault(); const f = e.target;
        try { await post(`${B}/api/leads/${encodeURIComponent(b.dataset.id)}/followup`, { due_date: f.due_date.value, comment: f.comment.value }); dlg.close(); leads(); }
        catch (ex) { const fe = dlg.querySelector('#fe'); fe.textContent = ex.message; fe.hidden = false; }
      };
      dlg.showModal();
    }));
  }

  async function route() {
    const name = (location.hash || '#/overview').slice(2).split('?')[0];
    { const cur = name; nav.innerHTML = AIRL.nav(items, cur); curNo = Math.max(1, items.findIndex((i) => i.id === cur) + 1); AIRL.revealTab(nav); }
    try {
      if (name === 'plan') await plan(); else if (name === 'leads') await leads(); else await overview();
    } catch (e) { view.innerHTML = errorBox(e.status === 403 ? e.message : `Не удалось загрузить данные: ${e.message}`); }
  }

  (async () => {
    try { me = await AIRL.topbar('Продажи', 'sales'); } catch (e) { view.innerHTML = errorBox(e.message); return; }
    AIRL.caption('Продажи · заявки amoCRM, план-факт и напоминания · оплаты из 1С');
    if (!['ceo', 'head_sales', 'staff_sales'].includes(me.role)) { view.innerHTML = errorBox('Сервис «Продажи» недоступен для вашей роли'); return; }
    if (me.role === 'staff_sales' && !location.hash) location.hash = '#/leads';
    window.addEventListener('hashchange', route); route(); AIRL.registerSW(`${B}/`);
    post('/hub/api/open', { service: 'sales' }).catch(() => {});
  })();
})();
