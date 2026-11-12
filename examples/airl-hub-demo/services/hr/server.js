'use strict';
// Сервис отдела «HR»: численность, текучесть, вакансии, ФОТ по отделам (только агрегаты),
// онбординг новых сотрудников (модуль onboarding). Читает metrics и адаптер src_onb_employees,
// пишет только в mart_hr. Оклады людей не видит никто: их нет ни в core, ни в витрине.
const { deptService, mapKpis, toHubMetric, maskName, q, HttpError } = require('../shared/lib/service');
const { makePool } = require('../shared/lib/db');

const pool = makePool('DATABASE_URL');
const db = (sql, p) => q(pool, sql, p);
const HR = ['head_hr', 'staff_hr'];
const KPIS = ['headcount', 'turnover_rate', 'time_to_hire', 'open_vacancies', 'payroll_fund'];
const HUB_METRICS = ['headcount', 'turnover_rate', 'open_vacancies'];
const PAYROLL = ['ceo', 'head_hr']; // ФОТ по отделам — руководителю компании и руководителю HR
const seesNames = (u) => HR.includes(u.role); // имена сотрудников без маски — только HR (карта, раздел 7)

// «Свои записи»: HR-менеджер ведёт онбординг своих отделов; руководитель HR и ceo — все.
async function deptScope(u) {
  if (u.role !== 'staff_hr') return null;
  const [s] = await db('SELECT departments FROM mart_hr.hr_staff_scope WHERE login = $1', [u.sub]);
  if (!s) throw new HttpError(403, 'Вы не привязаны к отделам — обратитесь к руководителю HR');
  return s.departments;
}

const onTimeNow = () => db(`SELECT metric_id, period, value, unit, status FROM mart_hr.m_onboarding_on_time_rate
                            WHERE period <= to_char(metrics.as_of(), 'YYYY-MM') ORDER BY period DESC LIMIT 1`);

const person = (u, name) => (seesNames(u) ? name : maskName(name));

deptService({
  dir: __dirname,
  port: Number(process.env.PORT || 3004),
  pool,
  summary: async () => {
    const k = await mapKpis(pool, HUB_METRICS);
    const metrics = k.map((r) => toHubMetric(r, `/hr/#/overview?metric=${r.metric_id}`));
    const [ot] = await onTimeNow();
    if (ot) metrics.push({ id: ot.metric_id, title: 'Онбординг в срок', value: Number(ot.value), unit: ot.unit, period: ot.period, compare: null, status: ot.status, link: '/hr/#/onboarding' });
    const alerts = [];
    const [old] = await db("SELECT count(*)::int AS n, max(days_open) AS d FROM metrics.vacancies() WHERE status = 'open' AND days_open > 45");
    if (old.n > 0) alerts.push({ level: 'warning', text: `Вакансий открыто дольше 45 дней: ${old.n} (самая долгая — ${old.d} дн.)`, link: '/hr/#/vacancies' });
    const [od] = await db('SELECT count(*)::int AS n FROM mart_hr.v_onb_tasks WHERE overdue');
    if (od.n > 0) alerts.push({ level: od.n > 3 ? 'danger' : 'warning', text: `Просрочено пунктов онбординга: ${od.n}`, link: '/hr/#/onboarding' });
    return { metrics, alerts };
  },
  routes: [
    ['GET', '/api/overview', async (ctx, u) => {
      const kpis = await mapKpis(pool, KPIS);
      const [onTime] = await onTimeNow();
      const moves = await db("SELECT label, hires, terminations FROM metrics.hr_moves('month', 12)");
      const headcount = await db("SELECT label, value FROM metrics.series('headcount', 'month', 12)");
      // ФОТ по отделам за прошлый полный месяц: отделы до 3 человек объединены (по сумме не вычислить оклад)
      const payroll = PAYROLL.includes(u.role)
        ? await db(`SELECT * FROM metrics.payroll_by_department((date_trunc('month', metrics.as_of()) - interval '1 month')::date,
                                                                (date_trunc('month', metrics.as_of()) - interval '1 day')::date)`)
        : null;
      const [m] = await db("SELECT to_char(date_trunc('month', metrics.as_of()) - interval '1 month', 'MM.YYYY') AS label");
      return { kpis, on_time: onTime || null, moves, headcount, payroll, payroll_month: m.label };
    }],

    ['GET', '/api/vacancies', async () => ({ rows: await db('SELECT * FROM metrics.vacancies()') })],

    ['GET', '/api/onboarding', async (ctx, u) => {
      const scope = await deptScope(u);
      const rows = await db(`SELECT instance_id, display_name, position, department, started_on, day_no, status,
                                    items_total, items_done, items_overdue, pct_done
                             FROM mart_hr.v_onb_progress
                             WHERE ($1::text[] IS NULL OR department = ANY ($1)) AND (status = 'active' OR started_on >= current_date - 120)
                             ORDER BY items_overdue DESC, started_on DESC`, [scope]);
      const [on] = await onTimeNow();
      const series = await db("SELECT period, value FROM mart_hr.m_onboarding_on_time_rate WHERE period <= to_char(metrics.as_of(), 'YYYY-MM') ORDER BY period DESC LIMIT 12");
      return { scope: scope ? `Мои отделы: ${scope.join(', ')}` : 'Все отделы', on_time: on || null, series: series.reverse(),
        rows: rows.map((r) => ({ ...r, display_name: person(u, r.display_name) })) };
    }],

    ['GET', '/api/onboarding/:id', async (ctx, u) => {
      const id = String(ctx.params.id);
      if (!/^\d{1,9}$/.test(id)) throw new HttpError(404, 'Онбординг не найден');
      const scope = await deptScope(u);
      const [p] = await db('SELECT instance_id, display_name, position, department, started_on, day_no, pct_done FROM mart_hr.v_onb_progress WHERE instance_id = $1', [id]);
      if (!p || (scope && !scope.includes(p.department))) throw new HttpError(404, 'Онбординг не найден'); // чужой отдел = не найден
      const tasks = await db(`SELECT t.id, t.ord, t.title, t.kind, t.responsible_role, t.due_date, t.status, t.done_at::date AS done_on,
                                     t.overdue, t.days_overdue, t.on_time
                              FROM mart_hr.v_onb_tasks t JOIN mart_hr.onb_tasks x ON x.id = t.id
                              WHERE x.instance_id = $1 ORDER BY t.ord`, [id]);
      return { person: { ...p, display_name: person(u, p.display_name) }, tasks, can_edit: HR.includes(u.role) };
    }],

    // Главное действие HR: «Готово» по пункту онбординга (статус меняет модуль, журнал — airl_audit).
    ['POST', '/api/onboarding/tasks/:id/done', async (ctx, u) => {
      const id = String(ctx.params.id);
      if (!/^\d{1,9}$/.test(id)) throw new HttpError(404, 'Пункт не найден');
      const scope = await deptScope(u);
      const [t] = await db('SELECT t.id, t.status, t.department FROM mart_hr.v_onb_tasks t WHERE t.id = $1', [id]);
      if (!t || (scope && !scope.includes(t.department))) throw new HttpError(404, 'Пункт не найден');
      if (t.status !== 'open') throw new HttpError(409, 'Пункт уже закрыт');
      const comment = ctx.body && ctx.body.comment ? String(ctx.body.comment).slice(0, 500) : null;
      await db(`UPDATE mart_hr.onb_tasks SET status = 'done', done_at = now(), done_by = $2, updated_by = $2, comment = COALESCE($3, comment)
                WHERE id = $1 AND status = 'open'`, [id, u.sub, comment]);
      return { ok: true };
    }, HR],

    ['GET', '/api/payroll', async () => {
      const months = await db(`SELECT to_char(m, 'YYYY-MM') AS month, to_char(m, 'MM.YYYY') AS label,
                                      m::date AS from_d, least(metrics.as_of(), (m + interval '1 month - 1 day')::date) AS to_d
                               FROM generate_series(date_trunc('month', metrics.as_of()) - interval '5 months', date_trunc('month', metrics.as_of()), interval '1 month') m
                               ORDER BY m DESC`);
      const fund = await db("SELECT period, value, status FROM metrics.m_payroll_fund ORDER BY period DESC LIMIT 12");
      const last = months[1];
      const byDept = await db('SELECT * FROM metrics.payroll_by_department($1, $2)', [last.from_d, last.to_d]);
      const absences = await db("SELECT * FROM metrics.absence_by_department((date_trunc('month', metrics.as_of()) - interval '2 months')::date, metrics.as_of())");
      return { month: last.label, by_department: byDept, fund: fund.reverse(), absences,
        note: 'Суммы по отделам с налогами работодателя; отделы до 3 человек объединены. Оклады людей в хаб не загружаются.' };
    }, PAYROLL],
  ],
});
