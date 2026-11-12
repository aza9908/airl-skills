'use strict';
// Сервис отдела «Финансы»: ОПиУ и ДДС (pnl-cashflow), должники (receivables), сверка банка
// (bank-reconciliation). Читает адаптеры src_<…> и metrics, пишет только в mart_finance.
const path = require('node:path');
const { deptService, mapKpis, toHubMetric, maskName, maskPhone, q, HttpError } = require('../shared/lib/service');
const { makePool } = require('../shared/lib/db');

const pool = makePool('DATABASE_URL');
const HUB_METRICS = ['revenue', 'gross_margin', 'cash_balance', 'receivables_overdue'];
const EDIT = ['head_finance', 'staff_finance'];
const seesPii = (u) => EDIT.includes(u.role); // бухгалтерия видит имена физлиц без маски (карта, раздел 7)
const ym = /^\d{4}-\d{2}$/;

async function db(sql, params) { return q(pool, sql, params); }
// Одна транзакция с search_path витрины: функции модулей пишут в airl_audit этой схемы.
async function tx(fn) {
  const c = await pool.connect();
  try {
    await c.query('BEGIN'); await c.query('SET LOCAL search_path TO mart_finance');
    const r = await fn(c); await c.query('COMMIT'); return r;
  } catch (e) { await c.query('ROLLBACK').catch(() => {}); throw e; } finally { c.release(); }
}

// Пересчёт после ночной загрузки core: ОПиУ, подбор сверки банка, уведомления модулей.
async function nightly() {
  try {
    await tx(async (c) => {
      await c.query("SELECT pnl_rebuild('scheduler')");
      await c.query("SELECT bank_suggest('scheduler')");
      await c.query('SELECT pnl_queue_notifications(), rcv_queue_notifications(), bank_queue_notifications()');
    });
    console.log('finance: пересчёт модулей выполнен');
  } catch (e) { console.error('finance nightly:', e.code || e.message); }
}

deptService({
  dir: __dirname,
  port: Number(process.env.PORT || 3001),
  pool,
  summary: async () => {
    const k = await mapKpis(pool, HUB_METRICS);
    const [b] = await db('SELECT value FROM mart_finance.m_bank_unmatched_count');
    const [d] = await db("SELECT count(*) AS n, COALESCE(sum(overdue_90_plus), 0) AS amt FROM mart_finance.v_rcv_aging WHERE overdue_90_plus > 0");
    const [o] = await db("SELECT count(*) AS n FROM mart_finance.airl_notifications WHERE module = 'pnl-cashflow' AND text LIKE 'Перерасход%' AND sent_at IS NULL AND cancelled_at IS NULL");
    const alerts = [];
    if (Number(b?.value) > 0) alerts.push({ level: 'warning', text: `${b.value} строк выписки не разнесены дольше 2 дней`, link: '/finance/#/bank' });
    if (Number(d.n) > 0) alerts.push({ level: 'danger', text: `${d.n} клиентов с долгом старше 90 дней`, link: '/finance/#/debtors' });
    if (Number(o.n) > 0) alerts.push({ level: 'warning', text: `${o.n} статей расходов с перерасходом бюджета`, link: '/finance/#/pnl' });
    return { metrics: k.map((r) => toHubMetric(r, `/finance/#/overview?metric=${r.metric_id}`)), alerts };
  },
  routes: [
    ['GET', '/api/overview', async () => {
      const kpis = await mapKpis(pool, ['revenue', 'gross_margin', 'net_profit', 'cash_balance', 'receivables_overdue']);
      const modules = await db(`SELECT metric_id, period, value, unit, status FROM mart_finance.m_bank_unmatched_count
                                UNION ALL SELECT * FROM mart_finance.m_receivables_overdue_share`);
      const revenue = await db("SELECT period, value FROM metrics.m_revenue ORDER BY period");
      return { kpis, modules, revenue };
    }],

    ['GET', '/api/pnl', async (ctx) => {
      const months = (await db("SELECT DISTINCT period FROM mart_finance.v_pnl_report WHERE month <= current_date ORDER BY period DESC")).map((r) => r.period);
      const month = ym.test(ctx.query.month || '') && months.includes(ctx.query.month) ? ctx.query.month : months[0];
      const branch = ['all', 'airl', 'airl_dev'].includes(ctx.query.branch) ? ctx.query.branch : 'all';
      const lines = await db(`SELECT line_code, line_title, line_kind, depth, is_leaf, fact, budget, deviation, deviation_pct, fact_ly, pct_of_revenue, preliminary
                              FROM mart_finance.v_pnl_report WHERE period = $1 AND branch_id = $2 ORDER BY sort_key`, [month, branch]);
      const unmapped = await db('SELECT count(*)::int AS n FROM mart_finance.v_pnl_unmapped');
      return { months, month, branch, lines, unmapped: unmapped[0].n };
    }],

    ['GET', '/api/cashflow', async () => ({
      balance: await db('SELECT period, opening, operating, investing, financing, internal, closing FROM mart_finance.v_pnl_cash_balance ORDER BY period'),
    })],

    ['GET', '/api/debtors', async (ctx, u) => {
      const rows = await db(`SELECT a.client_id, a.client_name, c.kind, a.open_total, a.not_due, a.overdue_1_30, a.overdue_31_60,
                                    a.overdue_61_90, a.overdue_90_plus, a.overdue, a.max_days_overdue, a.last_action_at,
                                    a.last_action_kind, a.last_action_result, a.next_contact_date, a.promised_date, a.promised_amount, a.promise_outcome
                             FROM mart_finance.v_rcv_aging a JOIN core.clients c ON c.client_id = a.client_id
                             WHERE a.open_total > 0 ORDER BY a.overdue DESC, a.open_total DESC LIMIT 200`);
      const [m] = await db('SELECT value, status FROM mart_finance.m_receivables_overdue');
      return { overdue: m, rows: rows.map((r) => ({ ...r, client_name: r.kind === 'person' && !seesPii(u) ? maskName(r.client_name) : r.client_name })) };
    }],

    ['GET', '/api/debtors/:client', async (ctx, u) => {
      const id = ctx.params.client;
      if (!/^CL-[0-9a-f]{12}$/.test(id)) throw new HttpError(404, 'Клиент не найден');
      const [c] = await db('SELECT client_id, kind, name, phone FROM core.clients WHERE client_id = $1', [id]);
      if (!c) throw new HttpError(404, 'Клиент не найден');
      const docs = await db(`SELECT doc_no, doc_date, effective_due_date, amount, paid_amount, balance, bucket, days_overdue
                             FROM mart_finance.v_rcv_docs WHERE client_id = $1 ORDER BY doc_date`, [id]);
      const actions = await db('SELECT created_at, created_by, kind, result, comment, next_contact_date FROM mart_finance.v_rcv_actions WHERE client_id = $1 ORDER BY created_at DESC LIMIT 50', [id]);
      const promises = await db('SELECT promised_date, promised_amount, outcome, comment FROM mart_finance.v_rcv_promises WHERE client_id = $1 ORDER BY created_at DESC LIMIT 20', [id]);
      const pii = seesPii(u) || c.kind === 'company';
      return { client: { ...c, name: pii ? c.name : maskName(c.name), phone: seesPii(u) ? c.phone : maskPhone(c.phone) }, docs, actions, promises };
    }],

    // Главное действие «Записать звонок»: действие по долгу и, если клиент обещал, обещание оплаты.
    ['POST', '/api/debtors/:client/actions', async (ctx, u) => {
      const id = ctx.params.client; const b = ctx.body || {};
      if (!/^CL-[0-9a-f]{12}$/.test(id)) throw new HttpError(404, 'Клиент не найден');
      const kinds = ['call', 'message', 'meeting', 'letter', 'claim'];
      const results = ['reached', 'not_reached', 'promised', 'disputed', 'refused', 'other'];
      if (!kinds.includes(b.kind) || !results.includes(b.result)) throw new HttpError(400, 'Выберите вид действия и результат');
      const comment = b.comment ? String(b.comment).slice(0, 1000) : null;
      if (['disputed', 'refused', 'other'].includes(b.result) && !comment) throw new HttpError(400, 'Для этого результата нужен комментарий');
      const next = b.next_contact_date && /^\d{4}-\d{2}-\d{2}$/.test(b.next_contact_date) ? b.next_contact_date : null;
      if (b.result === 'promised' && !(/^\d{4}-\d{2}-\d{2}$/.test(b.promised_date || '') && Number(b.promised_amount) > 0)) {
        throw new HttpError(400, 'Клиент обещал оплатить: укажите дату и сумму');
      }
      const [exists] = await db('SELECT 1 FROM mart_finance.src_receivables_docs WHERE client_id = $1 LIMIT 1', [id]);
      if (!exists) throw new HttpError(404, 'Клиент не найден');
      return tx(async (c) => {
        const { rows: [a] } = await c.query(`INSERT INTO rcv_actions (client_id, kind, result, comment, next_contact_date, created_by)
                                             VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`, [id, b.kind, b.result, comment, next, u.sub]);
        await c.query(`INSERT INTO airl_audit (actor, module, entity, entity_id, action, comment) VALUES ($1, 'receivables', 'action', $2, 'create', $3)`, [u.sub, String(a.id), b.result]);
        if (b.result === 'promised') {
          const { rows: [p] } = await c.query(`INSERT INTO rcv_promises (client_id, action_id, promised_date, promised_amount, currency, created_by)
                                               VALUES ($1, $2, $3, $4, 'KZT', $5) RETURNING id`, [id, a.id, b.promised_date, Number(b.promised_amount), u.sub]);
          await c.query(`INSERT INTO airl_audit (actor, module, entity, entity_id, action) VALUES ($1, 'receivables', 'promise', $2, 'create')`, [u.sub, String(p.id)]);
        }
        return { ok: true, action_id: a.id };
      });
    }, EDIT],

    ['GET', '/api/bank', async (ctx, u) => {
      const sugg = await db(`SELECT match_id, match_no, line_id, value_date, bank, amount, counterparty_name, purpose, kind, rule, confidence, explanation, allocations, conflict
                             FROM mart_finance.v_bank_suggestions ORDER BY value_date DESC`);
      const unmatched = await db(`SELECT line_id, bank, value_date, amount, counterparty_name, counterparty_tax_id, purpose, state, age_days, overdue
                                  FROM mart_finance.v_bank_unmatched ORDER BY value_date DESC`);
      const metrics = await db(`SELECT * FROM mart_finance.m_bank_unmatched_count UNION ALL
                                (SELECT * FROM mart_finance.m_bank_auto_match_rate ORDER BY period DESC LIMIT 1)`);
      const mask = (r) => (seesPii(u) ? r : { ...r, counterparty_name: maskName(r.counterparty_name), counterparty_tax_id: r.counterparty_tax_id ? '********' + String(r.counterparty_tax_id).slice(-4) : null, purpose: r.purpose && r.purpose.length > 30 ? r.purpose.slice(0, 30) + '…' : r.purpose });
      return { metrics, suggestions: sugg.map(mask), unmatched: unmatched.map(mask) };
    }],

    ['POST', '/api/bank/:match/confirm', async (ctx, u) => {
      const id = Number(ctx.params.match);
      if (!Number.isInteger(id) || id <= 0) throw new HttpError(404, 'Сопоставление не найдено');
      return tx(async (c) => {
        const { rows } = await c.query("SELECT 1 FROM bank_matches WHERE id = $1 AND status = 'suggested'", [id]);
        if (!rows.length) throw new HttpError(409, 'Сопоставление уже обработано или не найдено — обновите экран');
        const { rows: [r] } = await c.query('SELECT bank_confirm($1, $2) AS status', [id, u.sub]);
        return { ok: true, status: r.status };
      });
    }, EDIT],

    ['POST', '/api/bank/:match/reject', async (ctx, u) => {
      const id = Number(ctx.params.match);
      const reason = String((ctx.body || {}).reason || '').trim().slice(0, 500);
      if (!Number.isInteger(id) || id <= 0) throw new HttpError(404, 'Сопоставление не найдено');
      if (!reason) throw new HttpError(400, 'Укажите причину');
      return tx(async (c) => {
        const { rows } = await c.query("SELECT 1 FROM bank_matches WHERE id = $1 AND status = 'suggested'", [id]);
        if (!rows.length) throw new HttpError(409, 'Сопоставление уже обработано или не найдено — обновите экран');
        const { rows: [r] } = await c.query('SELECT bank_reject($1, $2, $3) AS status', [id, u.sub, reason]);
        return { ok: true, status: r.status };
      });
    }, EDIT],
  ],
});

nightly();
setInterval(nightly, 24 * 3600 * 1000).unref();
module.exports = { root: path.resolve(__dirname) };
