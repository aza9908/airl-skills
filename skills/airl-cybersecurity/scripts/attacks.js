'use strict';
// Проверка безопасности действием (/airl-cybersecurity, группы 1–6) — общий скрипт атак.
// Основа — tests/security_attacks.js демо-хаба AIRL. Только Node.js 18+, без зависимостей.
//
//   node attacks.js attacks.json [http://127.0.0.1:3000]
//
// Токены тестовых пользователей — из переменных окружения TOKEN_<РОЛЬ> (TOKEN_CEO,
// TOKEN_STAFF_SALES …): их выдаёт провайдер входа или хаб. Значения не печатаются.
// Строки подключения для атак на права базы — из переменных, имена которых указаны
// в attacks.json (например SALES_DB_URL). Запускать только на локальной или тестовой копии.
// Печатает таблицу «Атака | Ожидали | Получили | Итог» для SECURITY.md;
// код выхода 1 — хоть одна атака прошла, 2 — ошибка запуска.
const fs = require('node:fs');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

const conf = JSON.parse(fs.readFileSync(process.argv[2] || 'attacks.json', 'utf8'));
const BASE = (process.argv[3] || conf.base_url || 'http://127.0.0.1:3000').replace(/\/$/, '');
const rows = [];
let failed = 0;
const rec = (a, exp, got, ok) => { rows.push([a, exp, got, ok ? 'ок' : '**ПРОВАЛ**']); if (!ok) failed++; };
const tok = (role) => process.env['TOKEN_' + role.toUpperCase()] || null;
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');

async function req(path, token, opts = {}) {
  const r = await fetch(BASE + path, { ...opts, redirect: 'manual',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(opts.headers || {}) } });
  let body = null; try { body = await r.json(); } catch { /* не JSON */ }
  return { status: r.status, body, headers: r.headers };
}
function psqlAs(urlVar, sql) {
  if (!process.env[urlVar]) return 'нет переменной ' + urlVar;
  try {
    execFileSync('psql', [process.env[urlVar], '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-c', sql], { stdio: 'pipe' });
    return 'выполнилось';
  } catch (e) { return /permission denied|нет доступа|must be owner/i.test(String(e.stderr)) ? 'нет прав' : 'ошибка: ' + String(e.stderr).split('\n')[0].slice(0, 80); }
}

(async () => {
  const protectedPaths = conf.protected || [];          // адреса API, закрытые входом
  // 1. Вход: без токена, подмена роли, alg=none, чужой ключ
  for (const p of protectedPaths) { const r = await req(p); rec(`${p} без токена`, '401', String(r.status), r.status === 401); }
  const low = conf.low_role && tok(conf.low_role);
  if (low && protectedPaths.length) {
    const [h, pl, sig] = low.split('.');
    const payload = JSON.parse(Buffer.from(pl, 'base64url'));
    const target = conf.high_path || protectedPaths[0];
    let r = await req(target, `${h}.${b64u({ ...payload, role: 'ceo' })}.${sig}`);
    rec(`${conf.low_role}: role=ceo вписан в токен руками`, '401', String(r.status), r.status === 401);
    r = await req(target, `${b64u({ alg: 'none', typ: 'JWT' })}.${b64u({ ...payload, role: 'ceo' })}.`);
    rec('токен alg=none', '401', String(r.status), r.status === 401);
    const other = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;
    const data = `${h}.${b64u({ ...payload, role: 'ceo' })}`;
    r = await req(target, `${data}.${crypto.sign('RSA-SHA256', Buffer.from(data), other).toString('base64url')}`);
    rec('токен подписан чужим ключом', '401', String(r.status), r.status === 401);
  }
  if (conf.health) {
    const r = await req(conf.health);
    const keys = Object.keys(r.body || {});
    rec(`${conf.health} без токена: открыт и без данных`, '200, только status/service/version/map_version', `${r.status}, поля: ${keys.join(',')}`,
      r.status === 200 && keys.every((k) => ['status', 'service', 'version', 'map_version'].includes(k)));
  }
  // 2. Роли и IDOR: [роль, метод, путь, ожидаемый код, тело]
  for (const [role, method, path, want, body] of conf.roles || []) {
    const t = tok(role);
    if (!t) { rec(`${role} → ${method} ${path}`, String(want), `нет TOKEN_${role.toUpperCase()}`, false); continue; }
    const r = await req(path, t, { method, ...(body ? { body: JSON.stringify(body) } : {}) });
    rec(`${role} → ${method} ${path}`, String(want), String(r.status), r.status === want);
  }
  // 5. ПДн не уходят в сводку хаба
  if (conf.summary && conf.pii_patterns && tok('ceo')) {
    const s = JSON.stringify((await req(conf.summary, tok('ceo'))).body || {});
    const hit = conf.pii_patterns.some((re) => new RegExp(re).test(s));
    rec(`${conf.summary}: нет персональных данных`, 'только агрегаты', hit ? 'найдены ПДн' : 'агрегаты', !hit);
  }
  // 6. Заголовки безопасности
  if (protectedPaths.length && tok('ceo')) {
    const r = await req(protectedPaths[0], tok('ceo'));
    const need = ['content-security-policy', 'x-content-type-options', 'strict-transport-security', 'referrer-policy'];
    rec('заголовки безопасности', need.join(', '), need.filter((x) => r.headers.get(x)).length + ' из 4', need.every((x) => r.headers.get(x)));
  }
  // 3. Права базы: [переменная со строкой подключения, SQL, ожидаем «нет прав» | «выполнилось»]
  for (const [v, sql, want] of conf.db || []) {
    const got = psqlAs(v, sql);
    rec(`${v}: ${sql.slice(0, 60)}`, want || 'нет прав', got, got === (want || 'нет прав'));
  }
  console.log('| Атака | Ожидали | Получили | Итог |\n|---|---|---|---|');
  for (const x of rows) console.log(`| ${x.join(' | ')} |`);
  console.log(`\nАтак: ${rows.length}, не прошло (как и должно): ${rows.length - failed}, прошло: ${failed}`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e.message); process.exit(2); });
