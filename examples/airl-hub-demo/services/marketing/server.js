'use strict';
// Сервис отдела «Маркетинг»: расход на рекламу по каналам и кампаниям, CPL, CAC, ROMI, конверсия
// (всё — из metrics по формулам карты), бюджет каналов и заметки к кампаниям (пишет только в mart_marketing).
// Персональных данных нет: заявки — количеством, без контактов.
const { deptService, mapKpis, toHubMetric, q, HttpError } = require('../shared/lib/service');
const { makePool } = require('../shared/lib/db');

const pool = makePool('DATABASE_URL');
const db = (sql, p) => q(pool, sql, p);
const HEAD = ['head_marketing'];
const EDIT = ['head_marketing', 'staff_marketing'];
const KPIS = ['ad_spend', 'cpl', 'cac', 'romi', 'marketing_conversion', 'lead'];
const HUB_METRICS = ['ad_spend', 'cpl', 'cac', 'romi'];
const CHANNELS = ['instagram', 'site', 'telegram', 'meta_form', 'event', 'referral'];

// «Свои записи»: маркетолог ведёт свои каналы; руководитель маркетинга — все.
async function channelScope(u) {
  if (u.role !== 'staff_marketing') return null;
  const [s] = await db('SELECT channels FROM mart_marketing.mkt_staff_channels WHERE login = $1', [u.sub]);
  if (!s) throw new HttpError(403, 'Вы не привязаны к каналам — обратитесь к руководителю маркетинга');
  return s.channels;
}

const bounds = async () => (await db("SELECT * FROM metrics.period_bounds('month', metrics.as_of())"))[0];

deptService({
  dir: __dirname,
  port: Number(process.env.PORT || 3005),
  pool,
  summary: async () => {
    const k = await mapKpis(pool, HUB_METRICS);
    const metrics = k.map((r) => toHubMetric(r, `/marketing/#/overview?metric=${r.metric_id}`));
    const alerts = [];
    const [bu] = await db('SELECT value, status FROM mart_marketing.m_mkt_budget_usage');
    if (bu && bu.status !== 'ok') alerts.push({ level: bu.status, text: `Расход на рекламу по прогнозу — ${String(bu.value).replace('.', ',')}% бюджета месяца`, link: '/marketing/#/budget' });
    const b = await bounds();
    const cur = await db('SELECT channel_title, cpl FROM metrics.marketing_channels($1, $2)', [b.cur_from, b.cur_to]);
    const prev = new Map((await db('SELECT channel, channel_title, cpl FROM metrics.marketing_channels($1, $2)', [b.prev_from, b.prev_to])).map((r) => [r.channel_title, r.cpl]));
    const up = cur.filter((r) => r.cpl && prev.get(r.channel_title) && r.cpl > prev.get(r.channel_title) * 1.25)
      .map((r) => `${r.channel_title} +${Math.round(100 * (r.cpl / prev.get(r.channel_title) - 1))}%`);
    if (up.length) alerts.push({ level: 'warning', text: `Заявка подорожала больше чем на 25%: ${up.join(', ')}`, link: '/marketing/#/overview' });
    const [nl] = await db('SELECT count(*)::int AS n FROM metrics.marketing_campaigns($1, $2) WHERE no_leads', [b.cur_from, b.cur_to]);
    if (nl.n > 0) alerts.push({ level: 'warning', text: `Кампаний с расходом без заявок: ${nl.n} — проверьте UTM-метки`, link: '/marketing/#/campaigns' });
    return { metrics, alerts };
  },
  routes: [
    ['GET', '/api/overview', async () => {
      const kpis = await mapKpis(pool, KPIS);
      const b = await bounds();
      const channels = await db('SELECT * FROM metrics.marketing_channels($1, $2)', [b.cur_from, b.cur_to]);
      const spend = await db("SELECT label, value FROM metrics.series('ad_spend', 'month', 12)");
      const cpl = await db("SELECT label, value FROM metrics.series('cpl', 'month', 12)");
      return { period: b.label, compare: `${b.prev_from} – ${b.prev_to}`, kpis, channels, spend, cpl };
    }],

    ['GET', '/api/campaigns', async (ctx, u) => {
      const scope = await channelScope(u);
      const b = await bounds();
      const rows = await db(`SELECT c.*, (SELECT count(*) FROM mart_marketing.mkt_campaign_notes n WHERE n.campaign_id = c.campaign_id)::int AS notes
                             FROM metrics.marketing_campaigns($1, $2) c`, [b.cur_from, b.cur_to]);
      return { period: b.label, scope: scope ? `Мои каналы: ${scope.join(', ')}` : 'Все каналы',
        rows: rows.map((r) => ({ ...r, own: !scope || scope.includes(r.channel) })) };
    }],

    ['GET', '/api/campaigns/:id/notes', async (ctx) => {
      const id = String(ctx.params.id);
      if (!/^[a-z0-9_]{3,60}$/.test(id)) throw new HttpError(404, 'Кампания не найдена');
      return { rows: await db('SELECT id, note, created_by, created_at FROM mart_marketing.mkt_campaign_notes WHERE campaign_id = $1 ORDER BY created_at DESC LIMIT 50', [id]) };
    }],

    // Заметка к кампании: маркетолог — только к кампаниям своих каналов (чужая = не найдена).
    ['POST', '/api/campaigns/:id/notes', async (ctx, u) => {
      const id = String(ctx.params.id);
      if (!/^[a-z0-9_]{3,60}$/.test(id)) throw new HttpError(404, 'Кампания не найдена');
      const note = String((ctx.body && ctx.body.note) || '').trim().slice(0, 1000);
      if (!note) throw new HttpError(400, 'Напишите заметку');
      const scope = await channelScope(u);
      const [c] = await db(`SELECT campaign_id, channel FROM metrics.marketing_campaigns('2000-01-01', metrics.as_of()) WHERE campaign_id = $1`, [id]);
      if (!c || (scope && !scope.includes(c.channel))) throw new HttpError(404, 'Кампания не найдена');
      const [r] = await db('INSERT INTO mart_marketing.mkt_campaign_notes (campaign_id, note, created_by) VALUES ($1, $2, $3) RETURNING id', [id, note, u.sub]);
      await db("INSERT INTO mart_marketing.airl_audit (actor, module, entity, entity_id, action) VALUES ($1, 'marketing', 'campaign_note', $2, 'create')", [u.sub, String(r.id)]);
      return { ok: true, id: r.id };
    }, EDIT],

    ['GET', '/api/budget', async () => {
      const rows = await db(`SELECT month, channel, channel_title, budget, fact, forecast, comment, updated_by
                             FROM mart_marketing.v_mkt_budget
                             WHERE month IN (date_trunc('month', metrics.as_of())::date, (date_trunc('month', metrics.as_of()) + interval '1 month')::date)
                             ORDER BY month, budget DESC`);
      const [u] = await db('SELECT * FROM mart_marketing.m_mkt_budget_usage');
      return { usage: u || null, rows };
    }],

    // Главное действие руководителя маркетинга: «Изменить бюджет» канала на месяц (новая версия, старая — в истории).
    ['POST', '/api/budget', async (ctx, u) => {
      const b = ctx.body || {};
      if (!CHANNELS.includes(b.channel)) throw new HttpError(400, 'Нет такого канала');
      if (!/^\d{4}-\d{2}$/.test(b.month || '')) throw new HttpError(400, 'Укажите месяц ГГГГ-ММ');
      const v = Number(b.amount);
      if (!Number.isFinite(v) || v < 0 || v > 1e10) throw new HttpError(400, 'Бюджет — число от 0');
      const comment = String(b.comment || '').trim().slice(0, 500);
      if (!comment) throw new HttpError(400, 'Напишите, почему меняете бюджет');
      const c = await pool.connect();
      try {
        await c.query('BEGIN'); await c.query('SET LOCAL search_path TO mart_marketing');
        const { rows: old } = await c.query("UPDATE mkt_budgets SET status = 'archived', updated_by = $3 WHERE month = $1::date AND channel = $2 AND status = 'active' RETURNING amount", [`${b.month}-01`, b.channel, u.sub]);
        const { rows: [r] } = await c.query('INSERT INTO mkt_budgets (month, channel, amount, comment, created_by, updated_by) VALUES ($1::date, $2, $3, $4, $5, $5) RETURNING id', [`${b.month}-01`, b.channel, v, comment, u.sub]);
        await c.query(`INSERT INTO airl_audit (actor, module, entity, entity_id, action, comment, details)
                       VALUES ($1, 'marketing', 'budget', $2, 'update', $3, jsonb_build_object('from', $4::numeric, 'to', $5::numeric))`,
        [u.sub, `${b.month}:${b.channel}`, comment, old[0] ? old[0].amount : null, v]);
        await c.query('COMMIT');
        return { ok: true, id: r.id };
      } catch (e) { await c.query('ROLLBACK').catch(() => {}); throw e; } finally { c.release(); }
    }, HEAD],
  ],
});
