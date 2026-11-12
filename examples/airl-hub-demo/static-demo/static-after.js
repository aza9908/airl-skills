// Отключаем то, чего нет в статической версии: service worker и выход на страницу входа.
if (window.AIRL) { window.AIRL.registerSW = function () {}; }
document.addEventListener('click', function (e) {
  const t = e.target.closest('button, a');
  if (t && /Выйти/.test(t.textContent || '')) { e.preventDefault(); e.stopImmediatePropagation(); location.href = '/'; }
}, true);
