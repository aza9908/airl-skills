'use strict';
// Проверка безопасности действием (/airl-cybersecurity, группы 1–6): атаки на работающий хаб.
// Запуск: DEMO_PASSWORD=... node tests/security_attacks.js [http://127.0.0.1:8080]
// Для атак на права базы нужны строки подключения сервисов (берутся из .env).
// Печатает таблицу «Атака | Ожидали | Получили | Итог» и выходит с кодом 1, если хоть одна атака прошла.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const BASE = process.argv[2] || 'http://127.0.0.1:8080';
const ROOT = path.resolve(__dirname, '..');
const PW = process.env.DEMO_PASSWORD;
const rows = [];
let failed = 0;

function rec(attack, expected, got, ok) { rows.push([attack, expected, got, ok ? 'ок' : '**ПРОВАЛ**']); if (!ok) failed++; }

async function login(user) {
  const r = await fetch(`${BASE}/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ login: user, password: PW }) });
  const c = r.headers.get('set-cookie') || '';
  const m = c.match(/airl_session=([^;]+)/);
  if (!m) throw new Error(`вход ${user} не удался: ${r.status}`);
  return m[1];
}
async function req(p, token, opts = {}) {
  const r = await fetch(BASE + p, { ...opts, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(opts.headers || {}) } });
  let body = null; try { body = await r.json(); } catch { /* не JSON */ }
  return { status: r.status, body, headers: r.headers };
}
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');

function psqlAs(urlVar, sql) {
  try {
    execFileSync('psql', [process.env[urlVar], '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', sql], { stdio: 'pipe' });
    return 'выполнилось';
  } catch (e) { return /permission denied|нет доступа/i.test(String(e.stderr)) ? 'нет прав' : 'ошибка: ' + String(e.stderr).split('\n')[0].slice(0, 80); }
}

(async () => {
  if (!PW) { console.error('Нужен DEMO_PASSWORD'); process.exit(2); }
  const T = {};
  for (const u of ['ceo', 'head_finance', 'staff_finance', 'head_sales', 'staff_sales', 'staff_edu', 'head_hr', 'staff_hr', 'head_marketing', 'staff_marketing']) T[u] = await login(u);

  // ---- 1. Вход только через хаб ----
  for (const p of ['/finance/api/overview', '/sales/api/leads', '/edu/api/overview', '/hr/api/onboarding', '/marketing/api/campaigns', '/hub/api/overview',
    '/finance/api/hub/summary', '/hr/api/hub/summary', '/marketing/api/hub/summary', '/hub/api/hr', '/hub/api/marketing']) {
    const r = await req(p); rec(`${p} без токена`, '401', String(r.status), r.status === 401);
  }
  const [h, pl, sig] = T.staff_sales.split('.');
  const payload = JSON.parse(Buffer.from(pl, 'base64url'));
  const forged = `${h}.${b64u({ ...payload, role: 'ceo' })}.${sig}`;
  let r = await req('/finance/api/overview', forged); rec('staff_sales поменял role на ceo в токене', '401', String(r.status), r.status === 401);
  const other = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;
  const hdr = JSON.parse(Buffer.from(h, 'base64url'));
  const data = `${b64u(hdr)}.${b64u({ ...payload, role: 'ceo' })}`;
  const evil = `${data}.${crypto.sign('RSA-SHA256', Buffer.from(data), other).toString('base64url')}`;
  r = await req('/hub/api/overview', evil); rec('токен подписан чужим ключом', '401', String(r.status), r.status === 401);
  const keyFile = path.join(ROOT, '.secrets', 'jwt-private.pem');
  if (fs.existsSync(keyFile)) {
    const pk = crypto.createPrivateKey(fs.readFileSync(keyFile));
    const now = Math.floor(Date.now() / 1000);
    const d2 = `${b64u(hdr)}.${b64u({ ...payload, iat: now - 7200, nbf: now - 7200, exp: now - 3600 })}`;
    r = await req('/sales/api/leads', `${d2}.${crypto.sign('RSA-SHA256', Buffer.from(d2), pk).toString('base64url')}`);
    rec('просроченный токен', '401', String(r.status), r.status === 401);
    const d3 = `${b64u(hdr)}.${b64u({ ...payload, aud: 'other-app' })}`;
    r = await req('/sales/api/leads', `${d3}.${crypto.sign('RSA-SHA256', Buffer.from(d3), pk).toString('base64url')}`);
    rec('токен с чужой аудиторией (aud)', '401', String(r.status), r.status === 401);
  }
  const noneTok = `${b64u({ alg: 'none', typ: 'JWT' })}.${b64u({ ...payload, role: 'ceo' })}.`;
  r = await req('/hub/api/overview', noneTok); rec('токен alg=none', '401', String(r.status), r.status === 401);
  r = await req('/finance/healthz'); rec('/finance/healthz без токена (открыт, без данных)', '200, только status/version',
    `${r.status}, поля: ${Object.keys(r.body || {}).join(',')}`, r.status === 200 && Object.keys(r.body).every((k) => ['status', 'service', 'version', 'map_version'].includes(k)));

  // ---- 2. Роли по отделам ----
  const cases = [
    ['staff_sales', '/finance/api/overview', 403], ['staff_sales', '/finance/api/hub/summary', 403], ['staff_sales', '/hub/api/overview', 403],
    ['staff_sales', '/edu/api/overview', 403], ['head_finance', '/sales/api/overview', 403], ['head_finance', '/hub/api/funnel', 403],
    ['head_finance', '/hub/api/pnl', 200], ['head_finance', '/hub/api/digest', 403], ['staff_finance', '/finance/api/hub/summary', 403],
    ['staff_edu', '/finance/api/debtors', 403], ['ceo', '/edu/api/overview', 200], ['head_sales', '/hub/api/series?metric=cash_balance', 403],
    // HR и маркетинг
    ['staff_sales', '/hr/api/overview', 403], ['staff_sales', '/marketing/api/overview', 403], ['staff_hr', '/marketing/api/overview', 403],
    ['staff_marketing', '/hr/api/onboarding', 403], ['head_marketing', '/hr/api/vacancies', 403], ['head_hr', '/marketing/api/budget', 403],
    ['head_hr', '/hub/api/marketing', 403], ['head_marketing', '/hub/api/hr', 403], ['head_hr', '/hub/api/pnl', 403],
    ['head_marketing', '/hub/api/series?metric=payroll_fund', 403], ['head_hr', '/hub/api/series?metric=payroll_fund', 200],
    ['staff_hr', '/hr/api/payroll', 403], ['staff_hr', '/hr/api/hub/summary', 403], ['staff_marketing', '/marketing/api/hub/summary', 403],
    ['staff_hr', '/hub/api/overview', 403], ['ceo', '/hr/api/payroll', 200], ['ceo', '/marketing/api/overview', 200],
    ['head_hr', '/hub/api/hr', 200], ['head_marketing', '/hub/api/marketing', 200],
  ];
  for (const [u, p, want] of cases) { r = await req(p, T[u]); rec(`${u} → ${p}`, String(want), String(r.status), r.status === want); }
  r = await req('/sales/api/plan', T.staff_sales, { method: 'POST', body: JSON.stringify({ metric_id: 'revenue', month: '2026-12', value: 1, comment: 'x' }) });
  rec('staff_sales меняет план (действие head)', '403', String(r.status), r.status === 403);
  r = await req('/finance/api/debtors/CL-000000000000/actions', T.ceo, { method: 'POST', body: JSON.stringify({ kind: 'call', result: 'reached' }) });
  rec('ceo пишет в витрину финансов', '403', String(r.status), r.status === 403);
  r = await req('/hr/api/onboarding/tasks/1/done', T.ceo, { method: 'POST', body: '{}' });
  rec('ceo отмечает пункт онбординга (пишет в mart_hr)', '403', String(r.status), r.status === 403);
  r = await req('/hr/api/onboarding/tasks/1/done', T.head_marketing, { method: 'POST', body: '{}' });
  rec('head_marketing отмечает пункт онбординга', '403', String(r.status), r.status === 403);
  r = await req('/marketing/api/budget', T.staff_marketing, { method: 'POST', body: JSON.stringify({ month: '2026-12', channel: 'instagram', amount: 1, comment: 'x' }) });
  rec('staff_marketing меняет бюджет (действие head)', '403', String(r.status), r.status === 403);
  r = await req('/marketing/api/budget', T.head_hr, { method: 'POST', body: JSON.stringify({ month: '2026-12', channel: 'instagram', amount: 1, comment: 'x' }) });
  rec('head_hr меняет бюджет маркетинга', '403', String(r.status), r.status === 403);

  // IDOR: заявка чужого менеджера, поток чужого куратора
  const all = (await req('/sales/api/leads', T.head_sales)).body.rows;
  const foreign = all.find((l) => l.manager_id !== '9001');
  r = await req(`/sales/api/leads/${foreign.lead_id}/followup`, T.staff_sales, { method: 'POST', body: JSON.stringify({ due_date: '2026-12-01' }) });
  rec('staff_sales: напоминание по чужой заявке (подмена id)', '404', String(r.status), r.status === 404);
  const own = (await req('/sales/api/leads', T.staff_sales)).body.rows;
  rec('staff_sales видит только свои заявки', 'все manager_id = 9001', `${own.length} строк, чужих: ${own.filter((l) => l.manager_id !== '9001').length}`, own.every((l) => l.manager_id === '9001'));
  const coh = (await req('/edu/api/overview', T.ceo)).body.cohorts.find((c) => c.curator !== 'Куратор 1');
  r = await req(`/edu/api/cohorts/${coh.cohort_code}`, T.staff_edu); rec('staff_edu: поток другого куратора', '404', String(r.status), r.status === 404);
  // HR: онбординг отдела, который ведёт не этот HR-менеджер (staff_hr — продажи, обучение, маркетинг, HR)
  const onb = (await req('/hr/api/onboarding', T.head_hr)).body.rows;
  const devInst = onb.find((x) => x.department === 'Разработка');
  if (devInst) {
    r = await req(`/hr/api/onboarding/${devInst.instance_id}`, T.staff_hr); rec('staff_hr: онбординг чужого отдела (подмена id)', '404', String(r.status), r.status === 404);
    const task = (await req(`/hr/api/onboarding/${devInst.instance_id}`, T.head_hr)).body.tasks[0];
    r = await req(`/hr/api/onboarding/tasks/${task.id}/done`, T.staff_hr, { method: 'POST', body: '{}' });
    rec('staff_hr: «Готово» по пункту чужого отдела (подмена id)', '404', String(r.status), r.status === 404);
  } else rec('staff_hr: онбординг чужого отдела', 'есть онбординг разработки', 'нет данных', false);
  const ownOnb = (await req('/hr/api/onboarding', T.staff_hr)).body.rows;
  rec('staff_hr видит только свои отделы', 'нет «Разработка», «Финансы»', `${ownOnb.length} строк, чужих: ${ownOnb.filter((x) => ['Разработка', 'Финансы'].includes(x.department)).length}`,
    ownOnb.every((x) => !['Разработка', 'Финансы'].includes(x.department)));
  // Маркетинг: заметка к кампании канала, который ведёт не этот маркетолог (staff_marketing — instagram, meta_form)
  const camp = (await req('/marketing/api/campaigns', T.head_marketing)).body.rows.find((c) => !['instagram', 'meta_form'].includes(c.channel));
  r = await req(`/marketing/api/campaigns/${camp.campaign_id}/notes`, T.staff_marketing, { method: 'POST', body: JSON.stringify({ note: 'атака' }) });
  rec('staff_marketing: заметка к кампании чужого канала (подмена id)', '404', String(r.status), r.status === 404);

  // ---- 5. Персональные данные: маска на сервере ----
  const dc = (await req('/finance/api/debtors', T.ceo)).body.rows.find((x) => x.kind === 'person');
  const ds = (await req('/finance/api/debtors', T.staff_finance)).body.rows.find((x) => x.kind === 'person');
  if (dc && ds) rec('ceo видит имя физлица-должника', 'с маской', dc.client_name, /\*\*\*/.test(dc.client_name) && !/\*\*\*/.test(ds.client_name));
  const sum = await req('/finance/api/hub/summary', T.ceo);
  rec('в /api/hub/summary нет ПДн', 'только агрегаты', /Демо-|\+7700|9913/.test(JSON.stringify(sum.body)) ? 'есть имена' : 'агрегаты', !/\+7700|9913/.test(JSON.stringify(sum.body)));
  // HR: ФИО и оклады. Фамилии синтетики — «Демоев…», «Тестов…» и т. п.; полное ФИО — «Фамилия Имя».
  const SURN = /(Демоев|Тестов|Примеров|Образцов|Шаблонов|Макетов)а? [А-ЯЁ][а-яё]+/;
  const SAL = /"(oklad|salary|nachisleno|full_name|fio)"/;
  const onbCeo = (await req('/hr/api/onboarding', T.ceo)).body.rows;
  const onbHr = (await req('/hr/api/onboarding', T.head_hr)).body.rows;
  rec('ceo видит имена новых сотрудников', 'с маской (их видит только HR)', onbCeo[0] ? onbCeo[0].display_name : '—',
    onbCeo.length > 0 && onbCeo.every((x) => /\*\*\*/.test(x.display_name)) && onbHr.every((x) => !/\*\*\*/.test(x.display_name)));
  let leak = [];
  for (const [u, p] of [['ceo', '/hr/api/overview'], ['ceo', '/hr/api/payroll'], ['head_hr', '/hr/api/onboarding'], ['head_hr', '/hr/api/vacancies'],
    ['ceo', '/hr/api/hub/summary'], ['ceo', '/hub/api/hr'], ['head_hr', `/hr/api/onboarding/${onbHr[0] ? onbHr[0].instance_id : 1}`]]) {
    const b = JSON.stringify((await req(p, T[u])).body);
    if (SURN.test(b) || SAL.test(b)) leak.push(p);
  }
  rec('HR: полных ФИО и окладов нет ни в одном ответе', 'нет', leak.length ? leak.join(', ') : 'нет', leak.length === 0);
  const pay = (await req('/hr/api/payroll', T.ceo)).body.by_department;
  rec('ФОТ по отделам: нет отдела меньше 3 человек', 'малые отделы объединены', pay.map((x) => `${x.department}:${x.people}`).join('; '), pay.every((x) => x.people >= 3));
  const ms = JSON.stringify((await req('/marketing/api/hub/summary', T.ceo)).body) + JSON.stringify((await req('/marketing/api/campaigns', T.ceo)).body);
  rec('маркетинг: нет контактов (телефон, e-mail, имя)', 'только агрегаты', /\+7700|@|Заявка:/.test(ms) ? 'есть контакты' : 'агрегаты', !/\+7700|@|Заявка:/.test(ms));

  // ---- 6. Заголовки безопасности ----
  r = await req('/finance/api/overview', T.ceo);
  const need = ['content-security-policy', 'x-content-type-options', 'strict-transport-security', 'referrer-policy'];
  rec('заголовки безопасности', need.join(', '), need.filter((x) => r.headers.get(x)).length + ' из 4', need.every((x) => r.headers.get(x)));
  const lr = await fetch(`${BASE}/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ login: 'ceo', password: PW }) });
  const sc = lr.headers.get('set-cookie') || '';
  rec('cookie входа', 'HttpOnly; Secure; SameSite=Lax', sc.replace(/airl_session=[^;]+/, 'airl_session=…'), /HttpOnly/.test(sc) && /Secure/.test(sc) && /SameSite=Lax/.test(sc));

  // ---- 3. Свой участок — права базы ----
  if (process.env.SALES_DB_URL) {
    for (const [v, sql] of [['SALES_DB_URL', "INSERT INTO mart_finance.rcv_actions (client_id, kind, result, created_by) VALUES ('x', 'call', 'reached', 'attack')"],
      ['SALES_DB_URL', 'SELECT name FROM core.clients LIMIT 1'], ['EDU_DB_URL', 'SELECT phone FROM core.clients LIMIT 1'],
      ['FIN_DB_URL', "INSERT INTO core.sales_docs (doc_id) VALUES ('x')"], ['HUB_DB_URL', 'SELECT * FROM core.leads LIMIT 1'],
      ['FIN_DB_URL', 'SELECT * FROM mart_sales.pf_plans LIMIT 1'], ['EDU_DB_URL', 'CREATE TABLE mart_finance.x (id int)'],
      ['AI_DB_URL', 'SELECT * FROM mart_finance.rcv_actions LIMIT 1'],
      // HR и маркетинг: чужие витрины, ФИО и сырые данные
      ['HR_DB_URL', "INSERT INTO mart_marketing.mkt_budgets (month, channel, amount, created_by, updated_by) VALUES ('2026-12-01', 'site', 1, 'attack', 'attack')"],
      ['MKT_DB_URL', "UPDATE mart_hr.onb_tasks SET status = 'done', done_at = now(), done_by = 'attack' WHERE id = 1"],
      ['MKT_DB_URL', 'SELECT full_name FROM core.employee_names LIMIT 1'], ['HR_DB_URL', 'SELECT full_name FROM core.employee_names LIMIT 1'],
      ['HR_DB_URL', 'SELECT * FROM raw_1c.zup_nachisleniya LIMIT 1'], ['HR_DB_URL', 'SELECT name FROM core.clients LIMIT 1'],
      ['MKT_DB_URL', 'SELECT * FROM core.leads LIMIT 1'], ['FIN_DB_URL', 'SELECT * FROM mart_hr.src_onb_employees LIMIT 1'],
      ['HUB_DB_URL', 'SELECT * FROM core.payroll_monthly LIMIT 1'], ['AI_DB_URL', 'SELECT * FROM mart_hr.onb_tasks LIMIT 1'],
      ['SALES_DB_URL', 'CREATE TABLE mart_marketing.x (id int)']]) {
      const got = psqlAs(v, sql);
      rec(`${v.replace('_DB_URL', '').toLowerCase()}: ${sql.slice(0, 60)}`, 'нет прав', got, got === 'нет прав');
    }
    const ok = psqlAs('EDU_DB_URL', 'SELECT client_id, name FROM core.clients LIMIT 1');
    rec('svc_edu: имя слушателя (разрешённые колонки)', 'выполнилось', ok, ok === 'выполнилось');
  }

  console.log('| Атака | Ожидали | Получили | Итог |\n|---|---|---|---|');
  for (const x of rows) console.log(`| ${x.join(' | ')} |`);
  console.log(`\nАтак: ${rows.length}, не прошло (как и должно): ${rows.length - failed}, прошло: ${failed}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
