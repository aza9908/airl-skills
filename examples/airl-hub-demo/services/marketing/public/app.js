'use strict';
/* Сервис «Маркетинг»: расход на рекламу, CPL, CAC, ROMI по каналам и кампаниям (metrics),
   бюджет каналов и заметки к кампаниям (mart_marketing). Персональных данных нет. */
(() => {
  const { esc, api, post, fmtValue, fmtMoney, fmtShort, kpiCard, barChart, donut, hbars, loading, errorBox, empty } = AIRL;
  const B = '/marketing';
  const view = document.getElementById('view');
  const nav = document.getElementById('nav');
  const dlg = document.getElementById('dlg');
  let me;
  const items = [{ id: 'overview', title: 'Обзор', href: '#/overview' }, { id: 'campaigns', title: 'Кампании', href: '#/campaigns' }, { id: 'budget', title: 'Бюджет', href: '#/budget' }];
  let curNo = 1;
  const head = (t, sub, right = '') => AIRL.head(curNo, t, sub, right);
  const card = (title, sub, body, cls = '') => `<div class="card ${cls}"><h2>${esc(title)}${sub ? ` <span class="sub">${esc(sub)}</span>` : ''}</h2>${body}</div>`;
  const LOWER = new Set(['ad_spend', 'cpl', 'cac']);
  const pct = (v) => fmtValue(v, '%');

  async function overview() {
    view.innerHTML = head('Маркетинг', 'Загружаем…') + loading(6);
    const d = await api(`${B}/api/overview`);
    const ch = d.channels;
    const spend = ch.filter((c) => Number(c.spend) > 0);
    const cpl = ch.filter((c) => c.cpl !== null).sort((a, b) => b.cpl - a.cpl);
    const romi = ch.filter((c) => c.romi !== null).sort((a, b) => b.romi - a.romi);
    const tbl = ch.map((c) => `<tr><td data-label="Канал">${esc(c.channel_title)}</td><td class="n" data-label="Расход">${fmtMoney(c.spend)}</td><td class="n" data-label="Заявки">${c.leads}</td>
      <td class="n" data-label="CPL">${fmtMoney(c.cpl)}</td><td class="n" data-label="Слушатели">${c.won}</td><td class="n" data-label="CAC">${fmtMoney(c.cac)}</td>
      <td class="n" data-label="ROMI"><span class="badge ${c.romi === null ? '' : c.romi >= 200 ? 'ok' : c.romi > 100 ? 'warning' : 'danger'}">${pct(c.romi)}</span></td><td class="n" data-label="Конверсия">${pct(c.conversion)}</td></tr>`).join('');
    view.innerHTML = head('Маркетинг', `${d.period} против тех же дней прошлого месяца · расход — рекламные кабинеты и таблица бюджета, заявки — amoCRM, оплаты — 1С`)
      + `<div class="kpis">${d.kpis.map((k) => kpiCard({ ...k, id: k.metric_id }, { lowerIsBetter: LOWER.has(k.metric_id), sub: `было ${fmtValue(k.prev_value, k.unit)}` })).join('')}</div>`
      + `<div class="grid2">${card('Расход по каналам', d.period, spend.length ? donut(spend.map((c) => ({ label: c.channel_title, value: c.spend })), { total: `${fmtShort(spend.reduce((s, c) => s + Number(c.spend), 0))} ₸`, cap: 'расход' }) : empty('Расхода за период нет'))}
         ${card('Расход по месяцам', '12 месяцев · чёрный — текущий, неполный', barChart(d.spend.map((p, i) => ({ label: p.label, value: p.value, cls: i === d.spend.length - 1 ? 'cur' : '', title: fmtMoney(p.value) }))))}</div>`
      + `<div class="grid2">${card('Цена заявки по каналам (CPL)', 'расход канала / заявки канала', cpl.length ? hbars(cpl.map((c) => ({ label: c.channel_title, value: c.cpl, sub: `${c.leads} заявок` })), { one: true }) : empty('Нет данных'))}
         ${card('Окупаемость по каналам (ROMI)', 'выручка оплаченных заявок на курс без НДС − расход, к расходу', romi.length ? hbars(romi.map((c) => ({ label: c.channel_title, value: Math.max(0, c.romi), text: pct(c.romi), cls: c.romi <= 100 ? 'danger' : c.romi < 200 ? 'warning' : '', sub: `выручка ${fmtMoney(c.revenue)} · расход ${fmtMoney(c.spend)}` })), { one: true, fmt: pct }) : empty('Нет данных'))}</div>`
      + card('Каналы', 'CAC и ROMI — по воронке «Курс VibeOps»; заявки и CPL — все заявки канала', tbl ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Канал</th><th class="n">Расход</th><th class="n">Заявки</th><th class="n">CPL</th><th class="n">Слушатели</th><th class="n">CAC</th><th class="n">ROMI</th><th class="n">Конверсия</th></tr></thead><tbody>${tbl}</tbody></table></div>` : empty('Нет данных'));
  }

  async function campaigns() {
    view.innerHTML = head('Кампании', 'Загружаем…') + loading(1);
    const d = await api(`${B}/api/campaigns`);
    const canNote = ['head_marketing', 'staff_marketing'].includes(me.role);
    const rows = d.rows.map((c) => `<tr><td data-label="Кампания">${esc(c.title)}<div class="muted">${esc(c.campaign_id)}</div></td><td data-label="Канал">${esc(c.channel_title)}</td>
      <td class="n" data-label="Расход">${fmtMoney(c.spend)}</td><td class="n" data-label="Заявки">${c.no_leads ? '<span class="badge warning">0 · проверьте UTM</span>' : c.leads}</td><td class="n" data-label="CPL">${fmtMoney(c.cpl)}</td>
      <td class="n" data-label="Слушатели">${c.won}</td><td class="n" data-label="ROMI">${pct(c.romi)}</td>
      <td data-label="">${canNote && c.own ? `<button class="btn small js-note" data-id="${esc(c.campaign_id)}" data-title="${esc(c.title)}">Заметка${c.notes ? ` (${c.notes})` : ''}</button>` : c.notes ? `заметок: ${c.notes}` : ''}</td></tr>`).join('');
    view.innerHTML = head('Кампании', `${d.period} · ${d.scope} · по utm_campaign: расход кабинетов ↔ заявки amoCRM`)
      + card('Кампании месяца', 'сначала самые дорогие', rows ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Кампания</th><th>Канал</th><th class="n">Расход</th><th class="n">Заявки</th><th class="n">CPL</th><th class="n">Слушатели</th><th class="n">ROMI</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>` : empty('Кампаний за месяц нет'));
    view.querySelectorAll('.js-note').forEach((b) => b.addEventListener('click', async () => {
      const n = await api(`${B}/api/campaigns/${encodeURIComponent(b.dataset.id)}/notes`).catch(() => ({ rows: [] }));
      dlg.innerHTML = `<form id="nf"><h2>Заметка: ${esc(b.dataset.title)}</h2>${n.rows.length ? `<ul class="alert-list">${n.rows.map((x) => `<li><span>${esc(x.note)} <span class="muted">· ${esc(x.created_by)}</span></span></li>`).join('')}</ul>` : ''}
        <label for="t">Что поменяли или почему остановили</label><textarea id="t" name="note" maxlength="1000" required></textarea><p class="neg" id="fe" role="alert" hidden></p>
        <div class="form-row"><button class="btn secondary" type="button" id="x">Отмена</button><button class="btn" type="submit">Сохранить</button></div></form>`;
      dlg.querySelector('#x').onclick = () => dlg.close();
      dlg.querySelector('#nf').onsubmit = async (e) => {
        e.preventDefault();
        try { await post(`${B}/api/campaigns/${encodeURIComponent(b.dataset.id)}/notes`, { note: e.target.note.value }); dlg.close(); campaigns(); }
        catch (ex) { const fe = dlg.querySelector('#fe'); fe.textContent = navigator.onLine ? ex.message : 'Нет сети: заметка не сохранена'; fe.hidden = false; }
      };
      dlg.showModal();
    }));
  }

  async function budget() {
    view.innerHTML = head('Бюджет', 'Загружаем…') + loading(2);
    const d = await api(`${B}/api/budget`);
    const isHead = me.role === 'head_marketing';
    const months = [...new Set(d.rows.map((r) => String(r.month).slice(0, 7)))];
    const block = (m, i) => {
      const rs = d.rows.filter((r) => String(r.month).slice(0, 7) === m);
      const body = rs.map((r) => {
        const usage = r.budget > 0 ? (100 * r.forecast) / r.budget : null;
        return `<tr><td data-label="Канал">${esc(r.channel_title)}</td><td class="n" data-label="Бюджет">${fmtMoney(r.budget)}</td>
          ${i === 0 ? `<td class="n" data-label="Факт">${fmtMoney(r.fact)}</td><td class="n" data-label="Прогноз">${fmtMoney(r.forecast)}</td>
          <td class="n" data-label="Прогноз к бюджету"><span class="badge ${usage === null ? '' : usage >= 125 ? 'danger' : usage >= 110 ? 'warning' : 'ok'}">${pct(usage)}</span></td>` : ''}
          <td data-label="">${isHead ? `<button class="btn small js-b" data-m="${esc(m)}" data-c="${esc(r.channel)}" data-t="${esc(r.channel_title)}" data-v="${esc(r.budget)}">Изменить бюджет</button>` : ''}</td></tr>`;
      }).join('');
      return card(i === 0 ? `Текущий месяц · ${m}` : `Следующий месяц · ${m}`, i === 0 ? 'прогноз = факт / прошедшие дни × дни месяца (это оценка)' : 'план',
        `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Канал</th><th class="n">Бюджет</th>${i === 0 ? '<th class="n">Факт</th><th class="n">Прогноз</th><th class="n">Прогноз к бюджету</th>' : ''}<th></th></tr></thead><tbody>${body}</tbody></table></div>`);
    };
    view.innerHTML = head('Бюджет рекламы', `Исполнение по прогнозу: ${d.usage ? pct(d.usage.value) : '—'} · светофор 110% и 125%${isHead ? '' : ' · менять бюджет может руководитель маркетинга'}`)
      + (months.length ? months.map(block).join('') : empty('Бюджета нет'));
    view.querySelectorAll('.js-b').forEach((b) => b.addEventListener('click', () => {
      dlg.innerHTML = `<form id="bf"><h2>Бюджет: ${esc(b.dataset.t)} · ${esc(b.dataset.m)}</h2>
        <label for="v">Новый бюджет, ₸ без НДС</label><input id="v" name="amount" type="number" min="0" step="10000" value="${esc(b.dataset.v)}" required>
        <label for="c">Почему меняем (обязательно)</label><textarea id="c" name="comment" maxlength="500" required></textarea><p class="neg" id="fe" role="alert" hidden></p>
        <div class="form-row"><button class="btn secondary" type="button" id="x">Отмена</button><button class="btn" type="submit">Сохранить</button></div></form>`;
      dlg.querySelector('#x').onclick = () => dlg.close();
      dlg.querySelector('#bf').onsubmit = async (e) => {
        e.preventDefault(); const f = e.target;
        try { await post(`${B}/api/budget`, { month: b.dataset.m, channel: b.dataset.c, amount: Number(f.amount.value), comment: f.comment.value }); dlg.close(); budget(); }
        catch (ex) { const fe = dlg.querySelector('#fe'); fe.textContent = ex.message; fe.hidden = false; }
      };
      dlg.showModal();
    }));
  }

  async function route() {
    const name = (location.hash || '#/overview').slice(2).split('?')[0].split('/')[0];
    { nav.innerHTML = AIRL.nav(items, name); curNo = Math.max(1, items.findIndex((i) => i.id === name) + 1); AIRL.revealTab(nav); }
    try {
      if (name === 'campaigns') await campaigns(); else if (name === 'budget') await budget(); else await overview();
      AIRL.applyWidths(view);
    } catch (e) { view.innerHTML = errorBox(e.status === 403 ? e.message : `Не удалось загрузить данные: ${e.message}`); }
  }

  (async () => {
    try { me = await AIRL.topbar('Маркетинг', 'marketing'); } catch (e) { view.innerHTML = errorBox(e.message); return; }
    AIRL.caption('Маркетинг · расход, заявки и окупаемость рекламы по каналам и кампаниям · кабинеты Meta, Google, Telegram и amoCRM');
    if (!['ceo', 'head_marketing', 'staff_marketing'].includes(me.role)) { view.innerHTML = errorBox('Сервис «Маркетинг» недоступен для вашей роли'); return; }
    window.addEventListener('hashchange', route); route(); AIRL.registerSW(`${B}/`);
    post('/hub/api/open', { service: 'marketing' }).catch(() => {});
  })();
})();
