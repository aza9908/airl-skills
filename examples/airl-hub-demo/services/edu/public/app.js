'use strict';
/* Сервис «Обучение»: потоки VibeOps, слушатели, отметка куратора «риск отсева». */
(() => {
  const { esc, api, post, fmtValue, kpiCard, barChart, loading, errorBox, empty } = AIRL;
  const B = '/edu';
  const view = document.getElementById('view');
  const nav = document.getElementById('nav');
  const dlg = document.getElementById('dlg');
  let me;
  const canEdit = () => ['head_edu', 'staff_edu'].includes(me.role);
  const items = [{ id: 'overview', title: 'Обзор', href: '#/overview' }, { id: 'cohorts', title: 'Потоки', href: '#/cohorts' }];
  const head = (t, sub, right = '') => `<div class="page-head"><div><h1>${esc(t)}</h1><div class="sub">${esc(sub || '')}</div></div><span class="spacer"></span>${right}</div>`;
  const REASON = { absences: 'пропуски', no_homework: 'нет домашних работ', payment: 'оплата', personal: 'личные причины', other: 'другое' };
  const LEVEL = { risk: ['danger', 'риск отсева'], watch: ['warning', 'наблюдаем'], resolved: ['ok', 'решено'] };

  function cohortTable(rows) {
    return rows.length ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Поток</th><th>Формат</th><th>Старт</th><th class="n">Мест</th><th class="n">Продано</th><th class="n">Заполнено</th><th class="n">Завершили</th><th class="n">Риск</th></tr></thead><tbody>${rows.map((c) => `<tr>
      <td data-label="Поток"><a href="#/cohort/${esc(c.cohort_code)}">${esc(c.cohort_code)}</a></td><td data-label="Формат">${esc(c.format)}</td><td data-label="Старт">${esc(c.start_date)}</td>
      <td class="n" data-label="Мест">${c.capacity}</td><td class="n" data-label="Продано">${c.seats_sold}</td>
      <td class="n" data-label="Заполнено"><span class="badge ${c.fill_pct >= 85 ? 'ok' : c.fill_pct >= 70 ? 'warning' : 'danger'}">${fmtValue(c.fill_pct, '%')}</span></td>
      <td class="n" data-label="Завершили">${c.completed}</td><td class="n" data-label="Риск">${c.at_risk > 0 ? `<span class="badge danger">${c.at_risk}</span>` : '—'}</td></tr>`).join('')}</tbody></table></div>` : empty('Потоков нет');
  }

  async function overview(onlyTable) {
    view.innerHTML = head('Обучение', 'Загружаем…') + loading(3);
    const d = await api(`${B}/api/overview`);
    if (onlyTable) { view.innerHTML = head('Потоки', d.scope) + `<div class="card">${cohortTable(d.cohorts)}</div>`; return; }
    view.innerHTML = head('Обучение', 'Курс VibeOps · текущий месяц с 1-го по вчера · цифры из metrics')
      + `<div class="kpis">${d.kpis.map((k) => kpiCard({ ...k, id: k.metric_id }, { sub: `было ${fmtValue(k.prev_value, k.unit)}` })).join('')}</div>`
      + `<div class="grid2"><div class="card"><h2>Записи на курс по месяцам</h2>${barChart(d.series.map((s, i) => ({ label: s.label, value: s.value, cls: i === d.series.length - 1 ? 'cur' : '' })), { fmt: (v) => String(Math.round(v)) })}</div>
         <div class="card"><h2>${esc(d.scope)} <span class="sub">· последние 9 месяцев и будущие</span></h2>${cohortTable(d.cohorts.slice(0, 6))}<p><a href="#/cohorts">Все потоки →</a></p></div></div>`;
  }

  async function cohort(code) {
    view.innerHTML = head(code, 'Загружаем…') + loading(1);
    const d = await api(`${B}/api/cohorts/${encodeURIComponent(code)}`);
    const rows = d.students.map((s) => `<tr><td data-label="Слушатель">${esc(s.name || '—')}</td><td data-label="Статус">${esc(s.status)}</td>
      <td class="n" data-label="Посещаемость">${s.attended_pct === null ? '—' : s.attended_pct + '%'}</td><td data-label="Проект">${s.final_project ? 'да' : 'нет'}</td>
      <td data-label="Отметка">${s.flag_level ? `<span class="badge ${LEVEL[s.flag_level][0]}">${LEVEL[s.flag_level][1]}</span> ${esc(REASON[s.flag_reason] || '')}` : '—'}</td>
      <td data-label="">${canEdit() && ['учится', 'записан'].includes(s.status) ? `<button class="btn small js-flag" data-id="${esc(s.enrollment_id)}" data-name="${esc(s.name)}">Отметить риск</button>` : ''}</td></tr>`).join('');
    const c = d.cohort;
    view.innerHTML = head(`Поток ${c.cohort_code}`, `${c.format} · ${c.start_date} — ${c.end_date} · ${c.seats_sold} из ${c.capacity} мест · ${c.curator}`)
      + `<div class="card">${rows ? `<div class="scroll-x"><table class="tbl cards"><thead><tr><th>Слушатель</th><th>Статус</th><th class="n">Посещаемость</th><th>Проект</th><th>Отметка</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>` : empty('В потоке пока нет слушателей')}</div>`;
    view.querySelectorAll('.js-flag').forEach((b) => b.addEventListener('click', () => flagForm(b.dataset.id, b.dataset.name, code)));
  }

  function flagForm(id, name, code) {
    dlg.innerHTML = `<form id="ff"><h2>Отметка: ${esc(name)}</h2>
      <label for="l">Уровень</label><select id="l" name="level"><option value="risk">Риск отсева</option><option value="watch">Наблюдаем</option><option value="resolved">Решено</option></select>
      <label for="r">Причина</label><select id="r" name="reason">${Object.entries(REASON).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select>
      <label for="c">Что сделали</label><textarea id="c" name="comment" maxlength="1000"></textarea><p class="neg" id="fe" role="alert" hidden></p>
      <div class="form-row"><button class="btn secondary" type="button" id="x">Отмена</button><button class="btn" type="submit">Сохранить</button></div></form>`;
    dlg.querySelector('#x').onclick = () => dlg.close();
    dlg.querySelector('#ff').onsubmit = async (e) => {
      e.preventDefault(); const f = e.target;
      try { await post(`${B}/api/flags`, { enrollment_id: id, level: f.level.value, reason: f.reason.value, comment: f.comment.value }); dlg.close(); cohort(code); }
      catch (ex) { const fe = dlg.querySelector('#fe'); fe.textContent = navigator.onLine ? ex.message : 'Нет сети: отметка не сохранена, попробуйте ещё раз'; fe.hidden = false; }
    };
    dlg.showModal();
  }

  async function route() {
    const [name, arg] = (location.hash || '#/overview').slice(2).split('?')[0].split('/');
    nav.innerHTML = AIRL.nav(items, name === 'cohort' ? 'cohorts' : name);
    try {
      if (name === 'cohort' && arg) await cohort(arg); else if (name === 'cohorts') await overview(true); else await overview(false);
    } catch (e) { view.innerHTML = errorBox(e.status === 404 ? 'Поток не найден или недоступен' : `Не удалось загрузить данные: ${e.message}`); }
  }

  (async () => {
    try { me = await AIRL.topbar('Обучение', 'edu'); } catch (e) { view.innerHTML = errorBox(e.message); return; }
    if (!['ceo', 'head_edu', 'staff_edu'].includes(me.role)) { view.innerHTML = errorBox('Сервис «Обучение» недоступен для вашей роли'); return; }
    window.addEventListener('hashchange', route); route(); AIRL.registerSW(`${B}/`);
    post('/hub/api/open', { service: 'edu' }).catch(() => {});
  })();
})();
