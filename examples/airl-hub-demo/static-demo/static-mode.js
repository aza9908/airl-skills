// Статическая демо-версия: данные — снимок JSON синтетического хаба под ролью ceo, входа и сервера нет.
// Любой GET к /auth/me, /hub/api/... и /<сервис>/api/... берётся из файла /data/<путь>.json
// (имя — путь с запросом, где всё, кроме латиницы и цифр, заменено на «_»; так же его пишет scripts/build_static.py).
(function () {
  const realFetch = window.fetch.bind(window);
  const file = (p) => '/data/' + p.replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '') + '.json';
  const json = (body, status) => new Response(JSON.stringify(body), { status: status || 200, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
  const isApi = (path) => path === '/auth/me' || path.startsWith('/auth/') || /^\/[a-z]+\/api\//.test(path);
  window.fetch = function (input, opts) {
    const url = typeof input === 'string' ? input : input.url;
    const path = url.replace(location.origin, '');
    const method = ((opts && opts.method) || (typeof input !== 'string' && input.method) || 'GET').toUpperCase();
    if (!isApi(path)) return realFetch(input, opts);
    const exp = Math.floor(Date.now() / 1000) + 3600; // срок «сессии» всегда через час: без бесконечных продлений
    if (path === '/auth/me' && method === 'GET') return realFetch(file(path)).then((r) => r.json()).then((d) => json(Object.assign(d, { exp })));
    if (path.startsWith('/auth/')) return Promise.resolve(json(path === '/auth/refresh' ? { ok: true, exp } : { ok: true }));
    if (method !== 'GET') {
      if (path === '/hub/api/open') return Promise.resolve(json({ ok: true }));
      return Promise.resolve(json({ error: 'Демо-версия только для просмотра: изменения не сохраняются' }, 403));
    }
    return realFetch(file(path)).then((r) => (r.ok ? r : json({ error: 'Этих данных нет в снимке демо-версии' }, 404)));
  };
  try { navigator.serviceWorker && navigator.serviceWorker.getRegistrations().then((rs) => rs.forEach((r) => r.unregister())); } catch (e) { /* нет SW */ }
  document.addEventListener('DOMContentLoaded', function () {
    const b = document.createElement('div');
    b.className = 'demo-banner';
    b.setAttribute('role', 'note');
    b.textContent = 'Демо-версия хаба AIRL на синтетических данных: компании, люди и суммы вымышлены. Снимок под ролью руководителя, изменения не сохраняются; вход и роли — в полной версии.';
    document.body.prepend(b);
  });
})();
