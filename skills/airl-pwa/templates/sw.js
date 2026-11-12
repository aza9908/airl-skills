'use strict';
/* Service worker продукта или сервиса отдела. Шаблон /airl-pwa, часть 4.
   Основа — оболочка демо-хаба AIRL. Подставь BASE (base_path: "/sales" или "" для своего
   продукта) и список SHELL. Правила:
   - кэши только со СВОИМ префиксом (PREFIX): при обновлении удаляем только свои старые,
     чужие (оболочки хаба и других сервисов на том же домене) не трогаем;
   - вход, выход, всё не-GET, /healthz и /api/hub/summary — только сеть, не кэшируются;
   - данные API — сначала сеть (таймаут 4 с), без сети — последнее сохранённое;
   - SW оболочки хаба (scope «/») добавляет в SKIP_PATHS пути всех сервисов из реестра. */
const BASE = '/[id сервиса]';                    // '' для своего продукта на корне домена
const PREFIX = 'airl-[id сервиса]-';             // уникальный префикс кэшей этого SW
const VERSION = PREFIX + '[версия сборки]';       // меняется при каждой сборке
const DATA = PREFIX + 'data';
const SHELL = [BASE + '/', BASE + '/app.js', BASE + '/app.css', BASE + '/manifest.webmanifest'];
const SKIP_PATHS = [BASE + '/auth/', BASE + '/healthz', BASE + '/api/hub/summary', BASE + '/tg/'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(VERSION).then((c) => c.addAll(SHELL)).catch(() => {}));
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k.startsWith(PREFIX) && k !== VERSION && k !== DATA).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});
// плашка «Доступна новая версия · Обновить» присылает 'skipWaiting'
self.addEventListener('message', (e) => {
  if (e.data === 'skipWaiting') self.skipWaiting();
  if (e.data === 'logout') e.waitUntil(caches.delete(DATA));   // выход: данные пользователя — долой
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== location.origin || e.request.method !== 'GET') return;              // только сеть
  if (BASE && !(url.pathname === BASE || url.pathname.startsWith(BASE + '/'))) return;  // чужие пути — мимо
  if (SKIP_PATHS.some((p) => url.pathname.startsWith(p))) return;                       // правда, а не кэш
  if (url.pathname.startsWith(BASE + '/api/')) {
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
  e.respondWith(caches.match(e.request).then((hit) => hit || fetch(e.request)));
});
