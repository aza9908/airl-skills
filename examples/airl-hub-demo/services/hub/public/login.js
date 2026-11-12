'use strict';
(() => {
  const f = document.getElementById('login-form');
  const err = document.getElementById('err');
  const btn = document.getElementById('submit');
  const next = new URLSearchParams(location.search).get('next');
  f.addEventListener('submit', async (e) => {
    e.preventDefault();
    err.hidden = true; btn.disabled = true; btn.textContent = 'Входим…';
    try {
      const r = await fetch('/auth/login', {
        method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ login: f.login.value, password: f.password.value, next }),
      });
      const body = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(body.error || 'Не удалось войти');
      location.href = body.next || '/';
    } catch (ex) {
      err.textContent = navigator.onLine ? ex.message : 'Нет сети. Вход возможен только онлайн';
      err.hidden = false; btn.disabled = false; btn.textContent = 'Войти';
    }
  });
})();
