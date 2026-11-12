'use strict';
// Маски ПДн, форма показателя для хаба, HTTP-каркас: заголовки безопасности, 404 без стека, лимит тела.
const test = require('node:test');
const assert = require('node:assert');
const { maskPhone, maskName, toHubMetric, nowAlmaty } = require('../shared/lib/service');
const { createApp, HttpError } = require('../shared/lib/server');

test('маска телефона: код страны и последние 4 цифры', () => {
  assert.equal(maskPhone('+77000001234'), '+7*******1234');
  assert.equal(maskPhone(null), null);
});

test('маска имени: первая буква каждого слова', () => {
  assert.equal(maskName('Айгерим С.'), 'А*** С***');
});

test('показатель для хаба: число, светофор, период ГГГГ-ММ', () => {
  const m = toHubMetric({ metric_id: 'revenue', title: 'Выручка', value: '100.5', prev_value: null, unit: 'KZT', status: 'ok', cur_from: '2026-11-01', prev_from: '2026-10-01' }, '/x');
  assert.equal(m.value, 100.5);
  assert.equal(m.period, '2026-11');
  assert.equal(m.compare.value, null);
  const empty = toHubMetric({ metric_id: 'cohort_fill_rate', value: null, status: 'ok', cur_from: '2026-11-01', prev_from: '2026-10-01' });
  assert.equal(empty.value, 0);
  assert.equal(empty.status, 'warning');
});

test('время с поясом Алматы', () => {
  assert.match(nowAlmaty(), /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+05:00$/);
});

test('каркас: заголовки безопасности, ошибки без стека, лимит тела', async () => {
  const app = createApp({ name: 't', routes: [
    ['GET', '/ok/:id', (ctx) => ({ id: ctx.params.id })],
    ['GET', '/boom', () => { throw new Error('секретная деталь'); }],
    ['GET', '/deny', () => { throw new HttpError(403, 'нет'); }],
    ['POST', '/echo', (ctx) => ctx.body],
  ] });
  await new Promise((r) => app.listen(0, r));
  const base = `http://127.0.0.1:${app.address().port}`;
  try {
    let r = await fetch(`${base}/ok/42`);
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { id: '42' });
    for (const h of ['content-security-policy', 'x-content-type-options', 'strict-transport-security', 'referrer-policy']) assert.ok(r.headers.get(h), h);
    r = await fetch(`${base}/boom`);
    assert.equal(r.status, 500);
    assert.ok(!(await r.text()).includes('секретная'));
    assert.equal((await fetch(`${base}/deny`)).status, 403);
    assert.equal((await fetch(`${base}/nope`)).status, 404);
    r = await fetch(`${base}/echo`, { method: 'POST', body: 'x'.repeat(40000) });
    assert.equal(r.status, 413);
    r = await fetch(`${base}/echo`, { method: 'POST', body: '{bad' });
    assert.equal(r.status, 400);
  } finally { app.close(); }
});
