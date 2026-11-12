'use strict';
// Проверка токена хаба на сервере (контракт входа — COMPANY_MAP.md, раздел 8):
// JWT RS256, подпись по публичным ключам (JWKS), срок, издатель (iss), аудитория (aud).
// Роль и отдел берутся только из проверенного токена. Токен — из cookie airl_session
// или заголовка Authorization: Bearer (сервис принимает оба).
const crypto = require('node:crypto');
const { HttpError } = require('./server');

const COOKIE = process.env.AIRL_COOKIE || 'airl_session';
const ISSUER = process.env.AIRL_ISSUER || 'https://hub.airl.kz';
const AUDIENCE = process.env.AIRL_AUDIENCE || 'airl-hub';
const JWKS_URL = process.env.AIRL_JWKS_URL || 'http://127.0.0.1:3000/.well-known/jwks.json';

const b64u = (buf) => Buffer.from(buf).toString('base64url');
const fromB64u = (s) => Buffer.from(s, 'base64url');

let jwksCache = { at: 0, keys: new Map() };
let localKeys = null; // хаб проверяет свои токены без сети

function setLocalKeys(jwks) {
  localKeys = new Map(jwks.keys.map((k) => [k.kid, crypto.createPublicKey({ key: k, format: 'jwk' })]));
}

async function getKey(kid) {
  if (localKeys) return localKeys.get(kid);
  const fresh = Date.now() - jwksCache.at < 10 * 60 * 1000;
  if (!fresh || !jwksCache.keys.has(kid)) {
    const r = await fetch(JWKS_URL, { signal: AbortSignal.timeout(3000) });
    if (!r.ok) throw new Error(`JWKS недоступен: ${r.status}`);
    const body = await r.json();
    jwksCache = { at: Date.now(), keys: new Map(body.keys.map((k) => [k.kid, crypto.createPublicKey({ key: k, format: 'jwk' })])) };
  }
  return jwksCache.keys.get(kid);
}

function signJwt(payload, privateKey, kid, ttlSec = 3600) {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT', kid };
  const body = { iss: ISSUER, aud: AUDIENCE, iat: now, nbf: now - 5, exp: now + ttlSec, ...payload };
  const data = `${b64u(JSON.stringify(header))}.${b64u(JSON.stringify(body))}`;
  const sig = crypto.sign('RSA-SHA256', Buffer.from(data), privateKey);
  return `${data}.${b64u(sig)}`;
}

async function verifyJwt(token) {
  const parts = String(token || '').split('.');
  if (parts.length !== 3) throw new HttpError(401, 'Нужен вход через хаб');
  let header, payload;
  try {
    header = JSON.parse(fromB64u(parts[0]).toString('utf8'));
    payload = JSON.parse(fromB64u(parts[1]).toString('utf8'));
  } catch { throw new HttpError(401, 'Нужен вход через хаб'); }
  if (header.alg !== 'RS256') throw new HttpError(401, 'Нужен вход через хаб');
  const key = await getKey(header.kid);
  if (!key) throw new HttpError(401, 'Нужен вход через хаб');
  const ok = crypto.verify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`), key, fromB64u(parts[2]));
  const now = Math.floor(Date.now() / 1000);
  if (!ok || payload.iss !== ISSUER || payload.aud !== AUDIENCE || !(payload.exp > now) || (payload.nbf && payload.nbf > now + 5)) {
    throw new HttpError(401, 'Нужен вход через хаб');
  }
  if (!/^(ceo|(head|staff)_[a-z]+)$/.test(payload.role || '')) throw new HttpError(401, 'Нужен вход через хаб');
  return payload;
}

function tokenFrom(ctx) {
  const h = ctx.req.headers.authorization || '';
  if (h.startsWith('Bearer ')) return h.slice(7).trim();
  return ctx.cookies[COOKIE] || null;
}

// Пользователь из проверенного токена или 401.
async function requireUser(ctx) {
  const t = tokenFrom(ctx);
  if (!t) throw new HttpError(401, 'Нужен вход через хаб');
  ctx.user = await verifyJwt(t);
  return ctx.user;
}

// Запрет по умолчанию: роль должна быть в списке, иначе 403.
async function requireRole(ctx, roles) {
  const u = await requireUser(ctx);
  if (!roles.includes(u.role)) throw new HttpError(403, 'Нет доступа для вашей роли');
  return u;
}

module.exports = { signJwt, verifyJwt, requireUser, requireRole, tokenFrom, setLocalKeys, COOKIE, ISSUER, AUDIENCE };
