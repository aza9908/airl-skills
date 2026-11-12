'use strict';
// Оболочка хаба AIRL: вход (демо-издатель JWT вместо Authentik), шапка, экран руководителя,
// плитки сервисов из их /api/hub/summary, реестр hub/services.json, журнал хаба.
// Цифры экрана руководителя — только из схемы metrics (svc_hub читает metrics и больше ничего).
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { createApp, send, HttpError } = require('../shared/lib/server');
const auth = require('../shared/lib/auth');
const { makePool, q } = require('../shared/lib/db');

const VERSION = process.env.APP_VERSION || 'dev';
const MAP_VERSION = '1.1';
const PORT = Number(process.env.PORT || 3000);
const ROOT = path.resolve(__dirname, '..', '..');
const PUB = path.join(__dirname, 'public');
const SHARED = path.join(__dirname, '..', 'shared', 'static');
const KEYS_DIR = process.env.KEYS_DIR || path.join(ROOT, '.secrets');
const TOKEN_TTL = 60 * 60;
const COOKIE_SECURE = process.env.COOKIE_SECURE !== '0';

const pool = makePool('DATABASE_URL');
const registry = JSON.parse(fs.readFileSync(process.env.HUB_REGISTRY || path.join(ROOT, 'hub', 'services.json'), 'utf8')).services;
// Контракты сервисов (airl.service.json): кому виден сервис — roles.view.
const contracts = Object.fromEntries(registry.map((s) => {
  const p = path.join(process.env.SERVICES_DIR || path.join(ROOT, 'services'), s.id, 'airl.service.json');
  return [s.id, JSON.parse(fs.readFileSync(p, 'utf8'))];
}));

// ---------- ключи подписи токенов (создаются при первом запуске, в git не попадают) ----------
fs.mkdirSync(KEYS_DIR, { recursive: true, mode: 0o700 });
const keyFile = path.join(KEYS_DIR, 'jwt-private.pem');
if (!fs.existsSync(keyFile)) {
  const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  fs.writeFileSync(keyFile, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
}
const privateKey = crypto.createPrivateKey(fs.readFileSync(keyFile));
const publicJwk = crypto.createPublicKey(privateKey).export({ format: 'jwk' });
const KID = crypto.createHash('sha256').update(publicJwk.n).digest('base64url').slice(0, 16);
const JWKS = { keys: [{ ...publicJwk, kid: KID, alg: 'RS256', use: 'sig' }] };
auth.setLocalKeys(JWKS);

// ---------- журнал хаба (без ПДн, кроме логина) ----------
function journal(login, event, detail = null) {
  pool.query('INSERT INTO hub.journal (login, event, detail) VALUES ($1, $2, $3)', [login, event, detail ? String(detail).slice(0, 300) : null])
    .catch((e) => console.error('journal:', e.code || e.message));
}

// ---------- ограничение частоты входа ----------
// Считаем неудачные попытки с одного адреса: 20 за 10 минут → 429. Удачный вход не расходует лимит
// (иначе отдел из 20 человек за одним NAT упирался бы в лимит утром); подбор пароля к одному
// логину дополнительно останавливает блокировка после 5 ошибок (hub.users.locked_until).
const failures = new Map(); // ip → [время неудачи]
const recent = (ip) => (failures.get(ip) || []).filter((t) => Date.now() - t < 10 * 60 * 1000);
const rateLimited = (ip) => recent(ip).length >= 20;
function failed(ip) { const arr = recent(ip); arr.push(Date.now()); failures.set(ip, arr); }

function verifyPassword(password, stored) {
  const [scheme, salt, hash] = String(stored).split('$');
  if (scheme !== 'scrypt' || !salt || !hash) return false;
  const calc = crypto.scryptSync(String(password), Buffer.from(salt, 'base64'), 64);
  const want = Buffer.from(hash, 'base64');
  return want.length === calc.length && crypto.timingSafeEqual(calc, want);
}

function cookie(token, maxAge) {
  return `${auth.COOKIE}=${token}; HttpOnly; ${COOKIE_SECURE ? 'Secure; ' : ''}SameSite=Lax; Path=/; Max-Age=${maxAge}`;
}

const deptOf = (role) => (role === 'ceo' ? null : role.split('_').slice(1).join('_'));
const canSeeDept = (user, dept) => user.role === 'ceo' || (user.role.startsWith('head_') && deptOf(user.role) === dept);
const visibleServices = (user) => registry.filter((s) => ['connected', 'degraded'].includes(s.status)
  && (contracts[s.id].roles.view || []).includes(user.role));
const landing = (user) => (user.role.startsWith('staff_') ? `/${deptOf(user.role)}/` : '/');

async function userFromCookie(ctx) {
  try { return await auth.requireUser(ctx); } catch { return null; }
}

// Экран руководителя — только ceo и head_<отдел>; сотрудник сразу в свой сервис.
async function requireOverview(ctx) {
  const u = await auth.requireUser(ctx);
  if (u.role.startsWith('staff_')) throw new HttpError(403, 'Экран руководителя недоступен для вашей роли');
  return u;
}

const GRAINS = new Set(['day', 'week', 'month', 'quarter']);
const grainOf = (ctx) => (GRAINS.has(ctx.query.grain) ? ctx.query.grain : 'month');

// ---------- плитки: параллельный опрос /<id>/api/hub/summary с таймаутом 3 с и кэшем 60 с ----------
const tileCache = new Map(); // `${login}` → { at, data }
async function fetchSummary(svc, token) {
  const upstream = process.env[`UPSTREAM_${svc.id.toUpperCase()}`] || svc.upstream;
  const url = `http://${upstream}${svc.base_path}/api/hub/summary`;
  const started = Date.now();
  try {
    const r = await fetch(url, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' }, signal: AbortSignal.timeout(3000) });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const body = await r.json();
    return { id: svc.id, title: svc.title, base_path: svc.base_path, ok: true, ms: Date.now() - started, ...body };
  } catch (e) {
    return { id: svc.id, title: svc.title, base_path: svc.base_path, ok: false, error: e.name === 'TimeoutError' ? 'нет ответа за 3 с' : e.message, checked_at: new Date().toISOString() };
  }
}

const app = createApp({
  name: 'hub',
  routes: [
    ['GET', '/healthz', () => ({ status: 'ok', service: 'hub', version: VERSION, map_version: MAP_VERSION })],
    ['GET', '/.well-known/jwks.json', () => ({ status: 200, body: JWKS, headers: { 'Cache-Control': 'public, max-age=600' } })],

    ['GET', '/login', (ctx) => {
      send(ctx.res, 200, fs.readFileSync(path.join(PUB, 'login.html')), { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
      return 'handled';
    }],

    ['POST', '/auth/login', async (ctx) => {
      const ip = ctx.req.headers['x-forwarded-for']?.split(',')[0].trim() || ctx.req.socket.remoteAddress;
      if (rateLimited(ip)) throw new HttpError(429, 'Слишком много попыток входа. Подождите 10 минут');
      const login = String(ctx.body.login || '').trim().toLowerCase();
      const password = String(ctx.body.password || '');
      if (!/^[a-z][a-z0-9_]{2,40}$/.test(login) || !password || password.length > 200) { failed(ip); throw new HttpError(401, 'Неверный логин или пароль'); }
      const [u] = await q(pool, 'SELECT login, display_name, role, department, password_hash, disabled, failed_logins, locked_until FROM hub.users WHERE login = $1', [login]);
      if (!u || u.disabled) { failed(ip); journal(login, 'login_failed', 'нет пользователя'); throw new HttpError(401, 'Неверный логин или пароль'); }
      if (u.locked_until && new Date(u.locked_until) > new Date()) throw new HttpError(429, 'Вход временно заблокирован после неудачных попыток. Попробуйте через 15 минут');
      if (!verifyPassword(password, u.password_hash)) {
        await pool.query(`UPDATE hub.users SET failed_logins = failed_logins + 1,
          locked_until = CASE WHEN failed_logins + 1 >= 5 THEN now() + interval '15 minutes' END WHERE login = $1`, [login]);
        failed(ip);
        journal(login, 'login_failed', 'пароль');
        throw new HttpError(401, 'Неверный логин или пароль');
      }
      await pool.query('UPDATE hub.users SET failed_logins = 0, locked_until = NULL WHERE login = $1', [login]);
      const token = auth.signJwt({ sub: u.login, email: `${u.login}@demo.airl.kz`, role: u.role, department: u.department, name: u.display_name }, privateKey, KID, TOKEN_TTL);
      journal(login, 'login');
      const next = typeof ctx.body.next === 'string' && /^\/[a-z0-9/_#-]*$/i.test(ctx.body.next) && !ctx.body.next.startsWith('//') ? ctx.body.next : null;
      const user = { role: u.role };
      const target = next && !(next === '/' && u.role.startsWith('staff_')) ? next : landing(user);
      return { status: 200, body: { ok: true, next: target }, headers: { 'Set-Cookie': cookie(token, TOKEN_TTL) } };
    }],

    ['POST', '/auth/logout', async (ctx) => {
      const u = await userFromCookie(ctx);
      if (u) journal(u.sub, 'logout');
      return { status: 200, body: { ok: true }, headers: { 'Set-Cookie': cookie('', 0), 'Clear-Site-Data': '"cache", "storage"' } };
    }],

    // Оболочка сама продлевает токен до истечения срока.
    ['POST', '/auth/refresh', async (ctx) => {
      const u = await auth.requireUser(ctx);
      const token = auth.signJwt({ sub: u.sub, email: u.email, role: u.role, department: u.department, name: u.name }, privateKey, KID, TOKEN_TTL);
      return { status: 200, body: { ok: true, exp: Math.floor(Date.now() / 1000) + TOKEN_TTL }, headers: { 'Set-Cookie': cookie(token, TOKEN_TTL) } };
    }],

    ['GET', '/auth/me', async (ctx) => {
      const u = await auth.requireUser(ctx);
      const services = visibleServices(u).map(({ id, title, base_path }) => ({ id, title, base_path }));
      if (!u.role.startsWith('staff_')) services.unshift({ id: 'hub', title: 'Экран руководителя', base_path: '' });
      return { login: u.sub, name: u.name, role: u.role, department: u.department, exp: u.exp, services };
    }],

    ['POST', '/hub/api/open', async (ctx) => {
      const u = await auth.requireUser(ctx);
      const id = String(ctx.body.service || '');
      if (registry.some((s) => s.id === id)) journal(u.sub, 'open_service', id);
      return { ok: true };
    }],

    // ---------- экран руководителя ----------
    ['GET', '/hub/api/overview', async (ctx) => {
      const u = await requireOverview(ctx);
      const grain = grainOf(ctx);
      const rows = await q(pool, 'SELECT * FROM metrics.kpi_period($1)', [grain]);
      const kpis = rows.filter((r) => canSeeDept(u, r.department) || (r.department === 'ceo' && u.role === 'ceo'));
      const [asOf] = await q(pool, 'SELECT metrics.as_of() AS as_of');
      const depts = u.role === 'ceo' ? ['finance', 'sales', 'marketing', 'edu', 'hr'] : [deptOf(u.role)];
      return {
        as_of: asOf.as_of, grain, period: rows[0]?.period, compare: rows[0] ? `${rows[0].prev_from} – ${rows[0].prev_to}` : null,
        departments: depts, kpis,
      };
    }],

    ['GET', '/hub/api/series', async (ctx) => {
      const u = await requireOverview(ctx);
      const metric = String(ctx.query.metric || 'revenue');
      const [def] = await q(pool, "SELECT department FROM metrics.definitions WHERE metric_id = $1 AND source = 'metrics'", [metric]);
      if (!def) throw new HttpError(404, 'Нет такого показателя в карте');
      if (!canSeeDept(u, def.department) && u.role !== 'ceo') throw new HttpError(403, 'Показатель другого отдела');
      const grain = grainOf(ctx);
      const n = { day: 30, week: 13, month: 18, quarter: 6 }[grain];
      return { metric, grain, points: await q(pool, 'SELECT * FROM metrics.series($1, $2, $3)', [metric, grain, n]) };
    }],

    ['GET', '/hub/api/pnl', async (ctx) => {
      const u = await requireOverview(ctx);
      if (!canSeeDept(u, 'finance')) throw new HttpError(403, 'Только для руководителя и финансов');
      const [b] = await q(pool, 'SELECT * FROM metrics.period_bounds($1, metrics.as_of())', [grainOf(ctx)]);
      const cur = await q(pool, 'SELECT * FROM metrics.pnl($1, $2)', [b.cur_from, b.cur_to]);
      const prev = await q(pool, 'SELECT * FROM metrics.pnl($1, $2)', [b.prev_from, b.prev_to]);
      const pm = new Map(prev.map((r) => [r.line_code, r.amount]));
      return { period: b.label, compare: `${b.prev_from} – ${b.prev_to}`, preliminary: true,
        lines: cur.map((r) => ({ ...r, prev: pm.get(r.line_code) ?? null })) };
    }],

    ['GET', '/hub/api/aging', async (ctx) => {
      const u = await requireOverview(ctx);
      if (!canSeeDept(u, 'finance')) throw new HttpError(403, 'Только для руководителя и финансов');
      return { buckets: await q(pool, 'SELECT * FROM metrics.receivables_aging()') };
    }],

    ['GET', '/hub/api/funnel', async (ctx) => {
      const u = await requireOverview(ctx);
      if (!canSeeDept(u, 'sales')) throw new HttpError(403, 'Только для руководителя и продаж');
      const [b] = await q(pool, 'SELECT * FROM metrics.period_bounds($1, metrics.as_of())', [grainOf(ctx)]);
      return { period: b.label, channels: await q(pool, 'SELECT f.*, metrics.channel_title(f.channel) AS channel_title FROM metrics.lead_funnel($1, $2) f', [b.cur_from, b.cur_to]) };
    }],

    // HR: найм и увольнения по периодам, открытые вакансии, ФОТ по отделам за период (малые отделы объединены).
    ['GET', '/hub/api/hr', async (ctx) => {
      const u = await requireOverview(ctx);
      if (!canSeeDept(u, 'hr')) throw new HttpError(403, 'Только для руководителя и HR');
      const grain = grainOf(ctx);
      const n = { day: 30, week: 13, month: 18, quarter: 6 }[grain];
      const [b] = await q(pool, 'SELECT * FROM metrics.period_bounds($1, metrics.as_of())', [grain]);
      return {
        period: b.label, grain,
        moves: await q(pool, 'SELECT label, hires, terminations FROM metrics.hr_moves($1, $2)', [grain, n]),
        vacancies: await q(pool, "SELECT job_title, department, opened, days_open, source FROM metrics.vacancies() WHERE status = 'open' ORDER BY days_open DESC"),
        payroll: await q(pool, 'SELECT * FROM metrics.payroll_by_department($1, $2)', [b.cur_from, b.cur_to]),
      };
    }],

    // Маркетинг: каналы и кампании за период (расход, заявки, CPL, CAC, ROMI — формулы metrics).
    ['GET', '/hub/api/marketing', async (ctx) => {
      const u = await requireOverview(ctx);
      if (!canSeeDept(u, 'marketing')) throw new HttpError(403, 'Только для руководителя и маркетинга');
      const [b] = await q(pool, 'SELECT * FROM metrics.period_bounds($1, metrics.as_of())', [grainOf(ctx)]);
      return {
        period: b.label,
        channels: await q(pool, 'SELECT * FROM metrics.marketing_channels($1, $2)', [b.cur_from, b.cur_to]),
        campaigns: await q(pool, 'SELECT campaign_id, title, channel_title, spend, leads, won, cpl, romi, no_leads FROM metrics.marketing_campaigns($1, $2) LIMIT 8', [b.cur_from, b.cur_to]),
      };
    }],

    ['GET', '/hub/api/forecast', async (ctx) => {
      const u = await requireOverview(ctx);
      if (!canSeeDept(u, 'finance') && !canSeeDept(u, 'sales')) throw new HttpError(403, 'Нет доступа');
      const [f] = await q(pool, 'SELECT * FROM metrics.revenue_forecast()');
      return f;
    }],

    // Утренняя сводка /airl-ai: файл пишет ai/run_digest.sh (раз в день). Числа в ней сверены
    // с фактами; без ключа модели — шаблонная сводка без ИИ, и это написано в поле how.
    ['GET', '/hub/api/digest', async (ctx) => {
      const u = await requireOverview(ctx);
      if (u.role !== 'ceo') throw new HttpError(403, 'Сводка — для руководителя компании');
      const file = process.env.DIGEST_FILE || path.join(ROOT, 'ai', 'out', 'digest.json');
      try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { throw new HttpError(404, 'Сводки ещё нет'); }
    }],

    ['GET', '/hub/api/tiles', async (ctx) => {
      const u = await requireOverview(ctx);
      const token = auth.tokenFrom(ctx);
      const key = u.sub;
      const hit = tileCache.get(key);
      if (hit && Date.now() - hit.at < 60000 && ctx.query.fresh !== '1') return hit.data;
      const svcs = visibleServices(u).filter((s) => canSeeDept(u, s.id));
      const tiles = await Promise.all(svcs.map((s) => fetchSummary(s, token)));
      for (const t of tiles) if (!t.ok) journal(u.sub, 'summary_error', `${t.id}: ${t.error}`);
      // Подписи показателей — из карты (metrics.definitions), а не из ответа сервиса.
      const defs = Object.fromEntries((await q(pool, 'SELECT metric_id, title FROM metrics.definitions')).map((d) => [d.metric_id, d.title]));
      for (const t of tiles) for (const m of t.metrics || []) {
        const base = String(m.id).split(':')[0];
        const DIM = { revenue: 'выручка', lead: 'заявки', enrollments: 'записи' };
        const dim = String(m.id).split(':')[1];
        m.title = (defs[base] || m.title) + (dim && dim !== 'all' ? ` · ${DIM[dim] || dim}` : '');
      }
      const data = { generated_at: new Date().toISOString(), tiles };
      tileCache.set(key, { at: Date.now(), data });
      return data;
    }],
  ],
  statics: [
    ['/assets/', SHARED, { cache: 'public, max-age=3600' }],
    ['/', PUB, { cache: 'no-cache' }],
  ],
  // Корень и экран руководителя: без входа — на /login; сотрудник — сразу в свой сервис.
  before: async (ctx) => {
    if (ctx.req.method !== 'GET') return null;
    if (ctx.url.pathname === '/' || ctx.url.pathname === '/index.html') {
      const u = await userFromCookie(ctx);
      if (!u) { send(ctx.res, 302, '', { Location: '/login' }); return 'handled'; }
      if (u.role.startsWith('staff_')) { journal(u.sub, 'denied', 'экран руководителя → свой сервис'); send(ctx.res, 302, '', { Location: landing(u) }); return 'handled'; }
      send(ctx.res, 200, fs.readFileSync(path.join(PUB, 'index.html')), { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
      return 'handled';
    }
    return null;
  },
});

app.listen(PORT, () => console.log(`hub ${VERSION} слушает :${PORT}`));
