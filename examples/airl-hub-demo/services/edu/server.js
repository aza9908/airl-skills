'use strict';
// Сервис отдела «Обучение»: потоки курса VibeOps, слушатели, отметки куратора «риск отсева».
// Читает core.cohorts, core.enrollments, имя из карточки клиента и metrics; пишет только в mart_edu.
const { deptService, mapKpis, toHubMetric, maskName, q, HttpError } = require('../shared/lib/service');
const { makePool } = require('../shared/lib/db');

const pool = makePool('DATABASE_URL');
const db = (sql, p) => q(pool, sql, p);
const EDIT = ['head_edu', 'staff_edu'];
const LEVELS = ['risk', 'watch', 'resolved'];
const REASONS = ['absences', 'no_homework', 'payment', 'personal', 'other'];

// «Свои записи»: куратор видит только свои потоки; руководитель обучения и ceo — все.
async function curatorScope(u) {
  if (u.role !== 'staff_edu') return null;
  const [c] = await db('SELECT curator FROM mart_edu.edu_curators WHERE login = $1', [u.sub]);
  if (!c) throw new HttpError(403, 'Вы не привязаны к потокам — обратитесь к руководителю обучения');
  return c.curator;
}

deptService({
  dir: __dirname,
  port: Number(process.env.PORT || 3003),
  pool,
  summary: async () => {
    const k = await mapKpis(pool, ['enrollments', 'cohort_fill_rate', 'course_completion_rate']);
    const [r] = await db('SELECT metric_id, period, value, unit, status FROM mart_edu.m_edu_at_risk');
    const metrics = k.map((x) => toHubMetric(x, `/edu/#/overview?metric=${x.metric_id}`));
    metrics.push({ id: r.metric_id, title: 'Слушатели под риском отсева', value: Number(r.value), unit: r.unit, period: r.period, compare: null, status: r.status, link: '/edu/#/cohorts' });
    const low = await db(`SELECT cohort_code, fill_pct FROM metrics.cohort_fill_rate_detail
                          WHERE start_date > metrics.as_of() AND start_date <= metrics.as_of() + 21 AND fill_pct < 70`);
    const alerts = low.map((c) => ({ level: 'warning', text: `Поток ${c.cohort_code} стартует в течение 3 недель, заполнен на ${String(c.fill_pct).replace('.', ',')}%`, link: '/edu/#/cohorts' }));
    if (Number(r.value) > 0) alerts.push({ level: r.status === 'danger' ? 'danger' : 'warning', text: `${r.value} слушателей под риском отсева`, link: '/edu/#/cohorts' });
    return { metrics, alerts };
  },
  routes: [
    ['GET', '/api/overview', async (ctx, u) => {
      const cur = await curatorScope(u);
      const kpis = await mapKpis(pool, ['enrollments', 'cohort_fill_rate', 'course_completion_rate']);
      const cohorts = await db(`SELECT d.*, (SELECT count(*) FROM core.enrollments e WHERE e.cohort_code = d.cohort_code AND e.status = 'завершил') AS completed,
                                       (SELECT count(*) FROM core.enrollments e WHERE e.cohort_code = d.cohort_code AND e.status = 'отчислен') AS dropped,
                                       (SELECT count(*) FROM mart_edu.edu_flags f WHERE f.cohort_code = d.cohort_code AND f.status = 'active' AND f.level = 'risk') AS at_risk
                                FROM metrics.cohort_fill_rate_detail d
                                WHERE ($1::text IS NULL OR d.curator = $1) AND d.start_date >= metrics.as_of() - 270
                                ORDER BY d.start_date DESC`, [cur]);
      const series = await db("SELECT label, value FROM metrics.series('enrollments', 'month', 12)");
      return { kpis, cohorts, series, scope: cur ? `Мои потоки (${cur})` : 'Все потоки' };
    }],

    ['GET', '/api/cohorts/:code', async (ctx, u) => {
      const code = String(ctx.params.code);
      if (!/^VO-\d{4}-\d{2}$/.test(code)) throw new HttpError(404, 'Поток не найден');
      const cur = await curatorScope(u);
      const [c] = await db('SELECT * FROM metrics.cohort_fill_rate_detail WHERE cohort_code = $1', [code]);
      if (!c || (cur && c.curator !== cur)) throw new HttpError(404, 'Поток не найден'); // чужой поток = не найден
      const students = await db(`SELECT e.enrollment_id, cl.name, e.status, e.attended_pct, e.final_project,
                                        f.level AS flag_level, f.reason AS flag_reason, f.comment AS flag_comment, f.updated_by AS flag_by
                                 FROM core.enrollments e LEFT JOIN core.clients cl ON cl.client_id = e.client_id
                                 LEFT JOIN mart_edu.edu_flags f ON f.enrollment_id = e.enrollment_id AND f.status = 'active'
                                 WHERE e.cohort_code = $1 ORDER BY e.attended_pct NULLS LAST, e.enrollment_id`, [code]);
      const pii = EDIT.includes(u.role); // имена без маски — только сотрудникам обучения (карта, раздел 7)
      return { cohort: c, students: students.map((s) => ({ ...s, name: pii ? s.name : maskName(s.name), flag_comment: pii ? s.flag_comment : (s.flag_comment ? '•••' : null) })) };
    }],

    // Главное действие куратора: «Отметить риск отсева» (одна активная отметка на слушателя).
    ['POST', '/api/flags', async (ctx, u) => {
      const b = ctx.body || {};
      const id = String(b.enrollment_id || '');
      if (!/^VO-\d{4}-\d{2}:\d{1,3}$/.test(id)) throw new HttpError(404, 'Слушатель не найден');
      if (!LEVELS.includes(b.level) || !REASONS.includes(b.reason)) throw new HttpError(400, 'Выберите уровень и причину');
      const cur = await curatorScope(u);
      const [e] = await db('SELECT e.cohort_code, c.curator FROM core.enrollments e JOIN core.cohorts c USING (cohort_code) WHERE e.enrollment_id = $1', [id]);
      if (!e || (cur && e.curator !== cur)) throw new HttpError(404, 'Слушатель не найден');
      const comment = b.comment ? String(b.comment).slice(0, 1000) : null;
      const c = await pool.connect();
      try {
        await c.query('BEGIN'); await c.query('SET LOCAL search_path TO mart_edu');
        const { rows: old } = await c.query("UPDATE edu_flags SET status = 'archived', updated_by = $2 WHERE enrollment_id = $1 AND status = 'active' RETURNING level", [id, u.sub]);
        const { rows: [f] } = await c.query(`INSERT INTO edu_flags (enrollment_id, cohort_code, level, reason, comment, created_by, updated_by)
                                             VALUES ($1, $2, $3, $4, $5, $6, $6) RETURNING id`, [id, e.cohort_code, b.level, b.reason, comment, u.sub]);
        await c.query(`INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status)
                       VALUES ($1, 'edu', 'flag', $2, 'status', $3, $4)`, [u.sub, id, old[0]?.level || null, b.level]);
        await c.query('COMMIT');
        return { ok: true, id: f.id };
      } catch (err) { await c.query('ROLLBACK').catch(() => {}); throw err; } finally { c.release(); }
    }, EDIT],
  ],
});
