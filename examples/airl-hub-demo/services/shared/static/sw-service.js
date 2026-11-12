'use strict';
/* Service worker сервиса отдела (scope /<id>/, один файл на все сервисы): оболочка — из кэша,
   данные API — сначала сеть, без сети — последние сохранённые; /api/hub/summary, /healthz
   и запись — только сеть. Чужие пути (хаб, другие отделы) не трогает. */
const BASE = new URL(self.registration.scope).pathname;          // например /finance/
const ID = BASE.replace(/\//g, '');
const VERSION = `${ID}-v1`;
const SHELL = [BASE, BASE + 'app.js', BASE + 'manifest.webmanifest', BASE + 'assets/airl-tokens.css', BASE + 'assets/ui.css', BASE + 'assets/ui.js', BASE + 'assets/logo-airl-white.png'];
self.addEventListener('install', (e) => { e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).catch(() => {})); });
self.addEventListener('activate', (e) => { e.waitUntil(caches.keys().then((k) => Promise.all(k.filter((x) => x.startsWith(`${ID}-`) && !x.startsWith(VERSION)).map((x) => caches.delete(x)))).then(() => self.clients.claim())); });
self.addEventListener('message', (e) => { if (e.data === 'skipWaiting') self.skipWaiting(); });
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== location.origin || e.request.method !== 'GET' || !url.pathname.startsWith(BASE)) return;
  if (url.pathname === BASE + 'healthz' || url.pathname === BASE + 'api/hub/summary') return;
  if (url.pathname.startsWith(BASE + 'api/')) {
    e.respondWith((async () => {
      try {
        const r = await Promise.race([fetch(e.request), new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 4000))]);
        if (r.ok) (await caches.open(VERSION + '-data')).put(e.request, r.clone());
        return r;
      } catch {
        return (await caches.match(e.request)) || new Response('{"error":"Нет сети"}', { status: 503, headers: { 'Content-Type': 'application/json' } });
      }
    })());
    return;
  }
  e.respondWith(caches.match(e.request).then((hit) => hit || fetch(e.request).catch(() => caches.match(BASE))));
});
