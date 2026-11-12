'use strict';
// Сервис отдела «Продажи»: воронка заявок amoCRM (из core, только чтение), план-факт (модуль plan-fact),
// напоминания «перезвонить» по своим заявкам. Пишет только в mart_sales.
const { deptService, mapKpis, toHubMetric, q, HttpError } = require('../shared/lib/service');
const { makePool } = require('../shared/lib/db');

const pool = makePool('DATABASE_URL');
const db = (sql, p) => q(pool, sql, p);
const HEAD = ['head_sales'];
const PLAN_METRICS = ['revenue', 'lead', 'enrollments'];

// «Свои записи»: сотрудник видит только заявки своего менеджера amoCRM; руководитель и ceo — все.
async function managerScope(u) {
  if (u.role !== 'staff_sales') return null;
  const [m] = await db('SELECT manager_id FROM mart_sales.sales_staff WHERE login = $1', [u.sub]);
  if (!m) throw new HttpError(403, 'Вы не привязаны к менеджеру amoCRM — обратитесь к руководителю продаж');
  return m.manager_id;
}

async function planCompletion() {
  return db(`SELECT metric_id, period, value, unit, status FROM mart_sales.m_plan_completion
             WHERE period = to_char(current_date, 'YYYY-MM') ORDER BY metric_id`);
}

deptService({
  dir: __dirname,
  port: Number(process.env.PORT || 3002),
  pool,
  summary: async () => {
    const k = await mapKpis(pool, ['lead', 'conversion_lead_to_deal', 'avg_check']);
    const pc = (await planCompletion()).find((r) => r.metric_id === 'plan_completion:revenue');
    const metrics = k.map((r) => toHubMetric(r, `/sales/#/overview?metric=${r.metric_id}`));
    if (pc) metrics.push({ id: pc.metric_id, title: 'Выполнение плана', value: Number(pc.value), unit: pc.unit, period: pc.period, compare: null, status: pc.status, link: '/sales/#/plan' });
    const [o] = await db(`SELECT count(*)::int AS n FROM core.leads l WHERE l.stage = 'open' AND l.created_date < current_date - 3
                           AND NOT EXISTS (SELECT 1 FROM mart_sales.lead_followups f WHERE f.lead_id = l.lead_id AND f.status = 'active')`);
    const red = (await db("SELECT count(*)::int AS n FROM mart_sales.v_pf_current WHERE status = 'danger'"))[0].n;
    const alerts = [];
    if (o.n > 0) alerts.push({ level: 'warning', text: `${o.n} открытых заявок старше 3 дней без напоминания`, link: '/sales/#/leads' });
    if (red > 0) alerts.push({ level: 'danger', text: `${red} строк плана в красной зоне по прогнозу`, link: '/sales/#/plan' });
    return { metrics, alerts };
  },
  routes: [
    ['GET', '/api/overview', async () => {
      const kpis = await mapKpis(pool, ['lead', 'conversion_lead_to_deal', 'avg_check']);
      const plan = await planCompletion();
      const funnel = await db('SELECT f.*, metrics.channel_title(f.channel) AS channel_title FROM metrics.lead_funnel(date_trunc(\'month\', metrics.as_of())::date, metrics.as_of()) f');
      const series = await db("SELECT label, value FROM metrics.series('lead', 'month', 12)");
      return { kpis, plan, funnel, series };
    }],

    ['GET', '/api/plan', async () => ({
      current: await db(`SELECT plan_id, metric_id, title, unit, dimension_type, dimension_value, plan_value, fact_value, forecast_value,
                                completion_pct, forecast_pct, status, month FROM mart_sales.v_pf_current
                         WHERE dimension_type = 'company' ORDER BY metric_id`),
      next: await db(`SELECT metric_id, period, plan_value FROM mart_sales.v_pf_plans
                      WHERE month = (date_trunc('month', current_date) + interval '1 month')::date AND dimension_type = 'company'
                        AND status = 'active' ORDER BY metric_id`),
    })],

    // Главное действие руководителя продаж: «Изменить план» — новая версия, старая остаётся в истории.
    ['POST', '/api/plan', async (ctx, u) => {
      const b = ctx.body || {};
      if (!PLAN_METRICS.includes(b.metric_id)) throw new HttpError(400, 'Нет такого показателя в плане');
      if (!/^\d{4}-\d{2}$/.test(b.month || '')) throw new HttpError(400, 'Укажите месяц ГГГГ-ММ');
      const v = Number(b.value);
      if (!Number.isFinite(v) || v <= 0 || v > 1e12) throw new HttpError(400, 'План — положительное число');
      const comment = String(b.comment || '').trim().slice(0, 500);
      if (!comment) throw new HttpError(400, 'Напишите, почему меняете план');
      const c = await pool.connect();
      try {
        await c.query('BEGIN'); await c.query('SET LOCAL search_path TO mart_sales');
        const { rows: [r] } = await c.query("SELECT pf_set_plan($1, $2::date, 'company', 'all', $3, $4, $5) AS id", [b.metric_id, `${b.month}-01`, v, u.sub, comment]);
        await c.query('COMMIT');
        return { ok: true, plan_id: r.id };
      } catch (e) { await c.query('ROLLBACK').catch(() => {}); throw e; } finally { c.release(); }
    }, HEAD],

    ['GET', '/api/leads', async (ctx, u) => {
      const mgr = await managerScope(u);
      const rows = await db(`SELECT l.lead_id, l.created_date, l.channel, l.pipeline, l.status, l.amount, l.manager_id, m.name AS manager,
                                    f.due_date AS followup_date, f.comment AS followup_comment
                             FROM core.leads l LEFT JOIN core.managers m ON m.manager_id = l.manager_id
                             LEFT JOIN LATERAL (SELECT due_date, comment FROM mart_sales.lead_followups x WHERE x.lead_id = l.lead_id AND x.status = 'active' ORDER BY id DESC LIMIT 1) f ON true
                             WHERE l.stage = 'open' AND NOT l.is_duplicate AND ($1::text IS NULL OR l.manager_id = $1)
                             ORDER BY l.created_date LIMIT 300`, [mgr]);
      return { scope: mgr ? 'Мои заявки' : 'Все открытые заявки', rows };
    }],

    // «Перезвонить»: только по своей заявке (сотрудник) или по любой (руководитель).
    ['POST', '/api/leads/:id/followup', async (ctx, u) => {
      const id = String(ctx.params.id);
      if (!/^\d{1,12}$/.test(id)) throw new HttpError(404, 'Заявка не найдена');
      const b = ctx.body || {};
      if (!/^\d{4}-\d{2}-\d{2}$/.test(b.due_date || '')) throw new HttpError(400, 'Укажите дату звонка');
      const mgr = await managerScope(u);
      const [l] = await db("SELECT manager_id FROM core.leads WHERE lead_id = $1 AND stage = 'open'", [id]);
      if (!l || (mgr && l.manager_id !== mgr)) throw new HttpError(404, 'Заявка не найдена'); // чужая заявка = не найдена
      const [r] = await db(`INSERT INTO mart_sales.lead_followups (lead_id, due_date, comment, created_by, updated_by)
                            VALUES ($1, $2, $3, $4, $4) RETURNING id`, [id, b.due_date, b.comment ? String(b.comment).slice(0, 1000) : null, u.sub]);
      await db("INSERT INTO mart_sales.airl_audit (actor, module, entity, entity_id, action) VALUES ($1, 'sales', 'followup', $2, 'create')", [u.sub, String(r.id)]);
      return { ok: true, id: r.id };
    }, ['head_sales', 'staff_sales']],
  ],
});
