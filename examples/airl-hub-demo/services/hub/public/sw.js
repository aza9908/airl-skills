'use strict';
/* Service worker оболочки хаба. Управляет всем доменом, поэтому НЕ трогает пути сервисов
   отделов (/finance/, /sales/, /edu/ — список из реестра) и вход/выход. */
const VERSION = 'hub-v2';
const SHELL = ['/', '/app.js', '/login', '/login.js', '/login.css', '/manifest.webmanifest',
  '/assets/airl-tokens.css', '/assets/ui.css', '/assets/ui.js', '/assets/logo-airl-white.png', '/assets/star-mark.svg'];
const SERVICE_PATHS = ['/finance', '/sales', '/edu'];
const DATA = `${VERSION}-data`;

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).catch(() => {}));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k.startsWith('hub-') && !k.startsWith(VERSION)).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('message', (e) => { if (e.data === 'skipWaiting') self.skipWaiting(); });

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== location.origin || e.request.method !== 'GET') return;           // только сеть
  if (SERVICE_PATHS.some((p) => url.pathname === p || url.pathname.startsWith(p + '/'))) return; // чужие пути — мимо
  if (url.pathname.startsWith('/auth/') || url.pathname === '/healthz' || url.pathname.startsWith('/.well-known/')) return;
  if (url.pathname === '/hub/api/tiles') return;                                        // хаб видит правду, не кэш
  if (url.pathname.startsWith('/hub/api/')) {
    // данные: сначала сеть (таймаут 4 с), без сети — последнее сохранённое
    e.respondWith((async () => {
      try {
        const r = await Promise.race([fetch(e.request), new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 4000))]);
        if (r.ok) (await caches.open(DATA)).put(e.request, r.clone());
        return r;
      } catch {
        const c = await caches.match(e.request);
        return c || new Response(JSON.stringify({ error: 'Нет сети' }), { status: 503, headers: { 'Content-Type': 'application/json' } });
      }
    })());
    return;
  }
  // оболочка: из кэша, обновление в фоне
  e.respondWith(caches.match(e.request).then((hit) => hit || fetch(e.request)));
});
