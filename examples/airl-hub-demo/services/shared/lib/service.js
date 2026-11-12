'use strict';
// Каркас сервиса отдела: base_path, /healthz, /api/hub/summary в формате хаба (/airl-pwa, часть 5),
// статика оболочки сервиса, проверка ролей на каждом API. Показатели — только из metrics и своей витрины.
const fs = require('node:fs');
const path = require('node:path');
const { createApp, HttpError } = require('./server');
const auth = require('./auth');
const { q } = require('./db');

const SHARED_STATIC = path.join(__dirname, '..', 'static');

function readContract(dir) {
  return JSON.parse(fs.readFileSync(path.join(dir, 'airl.service.json'), 'utf8'));
}

// Время с поясом компании: 2026-11-12T09:00:00+05:00
function nowAlmaty() {
  const d = new Date(Date.now() + 5 * 3600 * 1000);
  return d.toISOString().replace(/\.\d{3}Z$/, '+05:00');
}

// Показатели карты за текущий месяц (с 1-го по вчера) против тех же дней прошлого месяца.
async function mapKpis(pool, ids, grain = 'month') {
  const rows = await q(pool, 'SELECT * FROM metrics.kpi_period($1) WHERE metric_id = ANY($2)', [grain, ids]);
  return ids.map((id) => rows.find((r) => r.metric_id === id)).filter(Boolean);
}

function toHubMetric(r, link) {
  const ym = (d) => String(d).slice(0, 7);
  return {
    id: r.metric_id, title: r.title, value: r.value === null ? 0 : Number(r.value), unit: r.unit,
    period: ym(r.cur_from), compare: { value: r.prev_value === null ? null : Number(r.prev_value), period: ym(r.prev_from) },
    status: r.value === null ? 'warning' : r.status, link,
  };
}

// Маски ПДн — на сервере. Телефон: код страны и последние 4 цифры; имя: первая буква.
const maskPhone = (p) => (p ? String(p).replace(/^(\+\d)\d+(\d{4})$/, '$1*******$2') : p);
const maskName = (n) => (n ? String(n).trim().split(/\s+/).map((w) => w[0] + '***').join(' ') : n);

/**
 * deptService({ dir, port, pool, summary: async (ctx, user) => ({metrics, alerts}), routes })
 * routes: [[method, '/api/...', handler, roles?]] — путь без base_path; roles — кто может (по умолчанию roles.view).
 */
function deptService({ dir, port, pool, summary, routes = [] }) {
  const contract = readContract(dir);
  const base = contract.base_path;
  const version = process.env.APP_VERSION || contract.version;
  const viewRoles = contract.roles.view;
  const summaryRoles = contract.roles.summary || ['ceo', `head_${contract.id}`];

  const guarded = routes.map(([method, p, handler, roles]) => [method, base + p, async (ctx) => {
    // Запрет по умолчанию: без явного списка ролей — только roles.view; роль — из проверенного токена.
    ctx.user = await auth.requireRole(ctx, roles || viewRoles);
    return handler(ctx, ctx.user);
  }]);

  const app = createApp({
    name: contract.id,
    routes: [
      ['GET', `${base}/sw.js`, () => ({ status: 200, body: fs.readFileSync(path.join(SHARED_STATIC, 'sw-service.js')),
        headers: { 'Content-Type': 'text/javascript; charset=utf-8', 'Cache-Control': 'no-cache' } })],
      ['GET', `${base}/healthz`, () => ({ status: 'ok', service: contract.id, version, map_version: contract.map_version })],
      ['GET', `${base}/api/hub/summary`, async (ctx) => {
        const user = await auth.requireRole(ctx, summaryRoles);
        const s = await summary(ctx, user);
        return { service: contract.id, version, map_version: contract.map_version, generated_at: nowAlmaty(), metrics: s.metrics, alerts: s.alerts || [] };
      }],
      ...guarded,
    ],
    statics: [
      [`${base}/assets/`, SHARED_STATIC, { cache: 'public, max-age=3600' }],
      [`${base}/`, path.join(dir, 'public'), { cache: 'no-cache' }],
    ],
    spa: { prefix: `${base}/`, file: path.join(dir, 'public', 'index.html') },
    before: async (ctx) => {
      // /finance → /finance/ (как redir в Caddy)
      if (ctx.url.pathname === base) { ctx.res.writeHead(308, { Location: base + '/' }); ctx.res.end(); return 'handled'; }
      // API без маршрута — 404 только после проверки токена (не раскрываем список адресов)
      if (ctx.url.pathname.startsWith(`${base}/api/`) && !guarded.some(([m, p]) => m === ctx.req.method && new RegExp('^' + p.replace(/\/:([a-zA-Z_]+)/g, '/([^/]+)') + '$').test(ctx.url.pathname))
          && ctx.url.pathname !== `${base}/api/hub/summary`) {
        await auth.requireRole(ctx, viewRoles);
        throw new HttpError(404, 'Не найдено');
      }
      return null;
    },
  });
  app.listen(port, () => console.log(`${contract.id} ${version} слушает :${port} (${base})`));
  return { contract, app };
}

module.exports = { deptService, mapKpis, toHubMetric, maskPhone, maskName, nowAlmaty, q, HttpError };
