'use strict';
// Локальная замена Caddy для песочницы без Docker: тот же маршрут, что proxy/Caddyfile.
// Один адрес (по умолчанию http://127.0.0.1:8080), пути /<id>/* → сервис отдела, всё остальное → оболочка хаба.
// Префикс пути не срезается: сервис собран под свой base_path. Только для разработки.
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
const PORT = Number(process.env.PROXY_PORT || 8080);
const reg = JSON.parse(fs.readFileSync(path.join(ROOT, 'hub', 'services.json'), 'utf8')).services;
const LOCAL = { hub: '127.0.0.1:3000', finance: '127.0.0.1:3001', sales: '127.0.0.1:3002', edu: '127.0.0.1:3003' };
const routes = reg.filter((s) => s.status !== 'disabled')
  .map((s) => ({ prefix: s.base_path, target: process.env[`UPSTREAM_${s.id.toUpperCase()}`] || LOCAL[s.id] }));
const hub = process.env.UPSTREAM_HUB || LOCAL.hub;

http.createServer((req, res) => {
  const p = req.url.split('?')[0];
  const r = routes.find((x) => p === x.prefix || p.startsWith(x.prefix + '/'));
  if (r && p === r.prefix) { res.writeHead(308, { Location: r.prefix + '/' }); return res.end(); }
  const [host, port] = (r ? r.target : hub).split(':');
  const up = http.request({ host, port, path: req.url, method: req.method,
    headers: { ...req.headers, 'x-forwarded-for': req.socket.remoteAddress, 'x-forwarded-proto': 'http' } }, (u) => {
    res.writeHead(u.statusCode, u.headers); u.pipe(res);
  });
  up.on('error', () => { if (!res.headersSent) { res.writeHead(502, { 'Content-Type': 'text/plain; charset=utf-8' }); } res.end('Сервис недоступен (502)'); });
  req.pipe(up);
}).listen(PORT, '127.0.0.1', () => console.log(`dev-proxy http://127.0.0.1:${PORT} → hub + ${routes.map((r) => r.prefix).join(', ')}`));
