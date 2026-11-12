'use strict';
/* Регистрация service worker и плашка «Доступна новая версия». Шаблон /airl-pwa.
   Плашку показываем, только если ДО регистрации у этого scope уже был активный SW
   (reg.active): иначе она выскочит при первой установке — в хабе страницу уже
   контролирует SW оболочки, и проверка navigator.serviceWorker.controller врёт.
   Разметка без style= и onclick= (CSP без 'unsafe-inline'): обработчики — addEventListener,
   видимость — через атрибут hidden и классы из CSS. */
(async () => {
  if (!('serviceWorker' in navigator)) return;
  const BASE = document.documentElement.dataset.base || '';      // <html data-base="/sales">
  const before = await navigator.serviceWorker.getRegistration(BASE + '/');
  const hadActive = Boolean(before && before.active);
  const reg = await navigator.serviceWorker.register(BASE + '/sw.js', { scope: BASE + '/' });
  const bar = document.getElementById('update-bar');            // <div id="update-bar" hidden>…<button>Обновить</button></div>
  const show = (w) => {
    if (!hadActive || !bar) return;
    bar.hidden = false;
    bar.querySelector('button').addEventListener('click', () => w.postMessage('skipWaiting'), { once: true });
  };
  if (reg.waiting) show(reg.waiting);
  reg.addEventListener('updatefound', () => {
    const w = reg.installing;
    w.addEventListener('statechange', () => { if (w.state === 'installed') show(w); });
  });
  let reloaded = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => { if (hadActive && !reloaded) { reloaded = true; location.reload(); } });
})();
