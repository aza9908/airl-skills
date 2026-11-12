'use strict';
// Общий каркас HTTP-сервера сервисов хаба: маршруты, JSON, статика под base_path,
// заголовки безопасности, ошибки без стека наружу. Только стандартная библиотека Node.js.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json', '.png': 'image/png', '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon', '.txt': 'text/plain; charset=utf-8',
};

const SECURITY_HEADERS = {
  'Content-Security-Policy': [
    "default-src 'self'", "script-src 'self'", "style-src 'self' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com", "img-src 'self' data:", "connect-src 'self'",
    "manifest-src 'self'", "worker-src 'self'", "frame-ancestors 'none'", "base-uri 'none'", "form-action 'self'",
  ].join('; '),
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'same-origin',
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  'Cross-Origin-Opener-Policy': 'same-origin',
};

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function send(res, status, body, headers = {}) {
  const isBuf = Buffer.isBuffer(body);
  const payload = isBuf || typeof body === 'string' ? body : JSON.stringify(body);
  res.writeHead(status, {
    ...SECURITY_HEADERS,
    'Content-Type': isBuf || typeof body === 'string' ? (headers['Content-Type'] || 'text/plain; charset=utf-8') : 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...headers,
  });
  res.end(payload);
}

function readJson(req, limit = 32 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0; let over = false; const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      // Сверх лимита — дочитываем и выбрасываем, чтобы клиент получил ответ 413, а не обрыв связи.
      if (size > limit) { if (!over) { over = true; reject(new HttpError(413, 'Слишком большой запрос')); } return; }
      chunks.push(c);
    });
    req.on('end', () => {
      if (over) return;
      if (!chunks.length) return resolve({});
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { reject(new HttpError(400, 'Тело запроса — не JSON')); }
    });
    req.on('error', reject);
  });
}

function parseCookies(header) {
  const out = {};
  for (const part of String(header || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}

// Статика: файлы из нескольких папок под префиксами. Путь нормализуется — выход за папку невозможен.
function serveStatic(res, dir, rel, { cache = 'no-cache' } = {}) {
  const safe = path.normalize('/' + rel).replace(/^(\.\.[/\\])+/, '');
  const file = path.join(dir, safe);
  if (!file.startsWith(dir)) return false;
  let stat;
  try { stat = fs.statSync(file); } catch { return false; }
  if (!stat.isFile()) return false;
  const ext = path.extname(file);
  const headers = { 'Content-Type': MIME[ext] || 'application/octet-stream', 'Cache-Control': cache };
  if (path.basename(file) === 'sw.js') headers['Service-Worker-Allowed'] = path.posix.dirname(rel) === '.' ? '/' : '/';
  send(res, 200, fs.readFileSync(file), headers);
  return true;
}

/**
 * createApp({ name, routes: [[method, path, handler]], statics: [[prefix, dir]], spa: {prefix, file} })
 * handler(ctx) → { status, body, headers } | объект (200 JSON). ctx: { req, res, url, params, query, cookies, body }.
 * Путь маршрута может содержать :param.
 */
function createApp({ name, routes = [], statics = [], spa = null, before = null }) {
  const compiled = routes.map(([method, p, handler]) => {
    const keys = [];
    const re = new RegExp('^' + p.replace(/\/:([a-zA-Z_]+)/g, (_, k) => { keys.push(k); return '/([^/]+)'; }) + '$');
    return { method, re, keys, handler };
  });

  return http.createServer(async (req, res) => {
    const started = Date.now();
    let url;
    try { url = new URL(req.url, 'http://local'); } catch { return send(res, 400, { error: 'Плохой адрес' }); }
    const ctx = { req, res, url, query: Object.fromEntries(url.searchParams), cookies: parseCookies(req.headers.cookie), params: {} };
    try {
      if (before) { const r = await before(ctx); if (r === 'handled') return; }
      for (const r of compiled) {
        const m = url.pathname.match(r.re);
        if (!m || r.method !== req.method) continue;
        r.keys.forEach((k, i) => { ctx.params[k] = decodeURIComponent(m[i + 1]); });
        if (req.method === 'POST' || req.method === 'PUT') ctx.body = await readJson(req);
        const out = await r.handler(ctx);
        if (out === 'handled') return;
        if (out && typeof out.status === 'number') return send(res, out.status, out.body ?? '', out.headers || {});
        return send(res, 200, out ?? {});
      }
      if (req.method === 'GET' || req.method === 'HEAD') {
        for (const [prefix, dir, opts] of statics) {
          if (url.pathname.startsWith(prefix) && serveStatic(res, dir, url.pathname.slice(prefix.length), opts)) return;
        }
        if (spa && url.pathname.startsWith(spa.prefix) && !url.pathname.includes('/api/')) {
          return send(res, 200, fs.readFileSync(spa.file), { 'Content-Type': MIME['.html'], 'Cache-Control': 'no-cache' });
        }
      }
      send(res, 404, { error: 'Не найдено' });
    } catch (e) {
      const status = e instanceof HttpError ? e.status : 500;
      if (status === 500) console.error(`[${name}] ${req.method} ${url.pathname}: ${e.code || ''} ${e.message}`);
      send(res, status, { error: status === 500 ? 'Внутренняя ошибка. Попробуйте ещё раз; если повторяется — напишите команде AIRL' : e.message });
    } finally {
      if (process.env.LOG_REQUESTS === '1') console.log(`[${name}] ${req.method} ${url.pathname} ${res.statusCode} ${Date.now() - started}ms`);
    }
  });
}

module.exports = { createApp, send, readJson, parseCookies, HttpError, SECURITY_HEADERS };
