// Статическая демо-версия: данные — снимок JSON синтетического хаба, входа и сервера нет.
(function () {
  const realFetch = window.fetch.bind(window);
  const file = (p) => '/data/' + p.replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '') + '.json';
  window.fetch = function (input, opts) {
    const url = typeof input === 'string' ? input : input.url;
    const path = url.replace(location.origin, '');
    const method = (opts && opts.method) || 'GET';
    if (path.startsWith('/auth/')) {
      const exp = Math.floor(Date.now() / 1000) + 3600; // срок «сессии» всегда через час: без бесконечных продлений
      if (method === 'GET' && path === '/auth/me') return realFetch(file(path)).then((r) => r.json()).then((d) => new Response(JSON.stringify(Object.assign(d, { exp })), { status: 200, headers: { 'Content-Type': 'application/json' } }));
      const body = path === '/auth/refresh' ? { exp } : {};
      return Promise.resolve(new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } }));
    }
    if (path.startsWith('/hub/api/')) return realFetch(file(path));
    return realFetch(input, opts);
  };
  try { navigator.serviceWorker && navigator.serviceWorker.getRegistrations().then((rs) => rs.forEach((r) => r.unregister())); } catch (e) { /* нет SW */ }
  document.addEventListener('DOMContentLoaded', function () {
    const b = document.createElement('div');
    b.className = 'demo-banner';
    b.textContent = 'Демо-версия хаба AIRL на синтетических данных: компании, люди и суммы вымышлены. Вход, роли и сервисы отделов — в полной версии.';
    document.body.prepend(b);
  });
})();
