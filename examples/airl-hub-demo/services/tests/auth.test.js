'use strict';
// Проверка токена хаба: подпись, срок, аудитория, издатель, alg=none, подмена роли.
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('node:crypto');
const auth = require('../shared/lib/auth');

const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = crypto.createPublicKey(privateKey).export({ format: 'jwk' });
auth.setLocalKeys({ keys: [{ ...jwk, kid: 'k1' }] });
const user = { sub: 'ceo', role: 'ceo', department: null };
const b64u = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');

test('свой токен проходит проверку', async () => {
  const t = auth.signJwt(user, privateKey, 'k1', 60);
  const p = await auth.verifyJwt(t);
  assert.equal(p.role, 'ceo');
  assert.equal(p.aud, auth.AUDIENCE);
});

test('подмена роли ломает подпись → 401', async () => {
  const [h, p, s] = auth.signJwt({ ...user, role: 'staff_sales' }, privateKey, 'k1', 60).split('.');
  const forged = `${h}.${b64u({ ...JSON.parse(Buffer.from(p, 'base64url')), role: 'ceo' })}.${s}`;
  await assert.rejects(auth.verifyJwt(forged), (e) => e.status === 401);
});

test('просроченный токен → 401', async () => {
  const t = auth.signJwt(user, privateKey, 'k1', -10);
  await assert.rejects(auth.verifyJwt(t), (e) => e.status === 401);
});

test('чужая аудитория и чужой издатель → 401', async () => {
  await assert.rejects(auth.verifyJwt(auth.signJwt({ ...user, aud: 'other' }, privateKey, 'k1', 60)), (e) => e.status === 401);
  await assert.rejects(auth.verifyJwt(auth.signJwt({ ...user, iss: 'https://evil' }, privateKey, 'k1', 60)), (e) => e.status === 401);
});

test('alg=none и неизвестный ключ → 401', async () => {
  const none = `${b64u({ alg: 'none', kid: 'k1' })}.${b64u({ ...user, iss: auth.ISSUER, aud: auth.AUDIENCE, exp: 9e9 })}.`;
  await assert.rejects(auth.verifyJwt(none), (e) => e.status === 401);
  const other = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey;
  await assert.rejects(auth.verifyJwt(auth.signJwt(user, other, 'k2', 60)), (e) => e.status === 401);
});

test('роль вне схемы ролей карты → 401', async () => {
  await assert.rejects(auth.verifyJwt(auth.signJwt({ ...user, role: 'admin' }, privateKey, 'k1', 60)), (e) => e.status === 401);
});

test('токен берётся из заголовка или cookie', () => {
  assert.equal(auth.tokenFrom({ req: { headers: { authorization: 'Bearer abc' } }, cookies: {} }), 'abc');
  assert.equal(auth.tokenFrom({ req: { headers: {} }, cookies: { airl_session: 'xyz' } }), 'xyz');
  assert.equal(auth.tokenFrom({ req: { headers: {} }, cookies: {} }), null);
});
