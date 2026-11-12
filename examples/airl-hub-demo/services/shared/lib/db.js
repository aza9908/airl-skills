'use strict';
// Слой доступа к хранилищу — одно место на сервис. Строка подключения только из окружения:
// сервис ходит в базу своим пользователем svc_<отдел>, а не администратором.
const { Pool, types } = require('pg');

// numeric → число JS (суммы до 2^53 копеек — достаточно), date → строка ГГГГ-ММ-ДД.
types.setTypeParser(1700, (v) => (v === null ? null : Number(v)));
types.setTypeParser(20, (v) => (v === null ? null : Number(v)));
types.setTypeParser(1082, (v) => v);

function makePool(envName = 'DATABASE_URL') {
  const url = process.env[envName];
  if (!url) throw new Error(`Нет ${envName} — строка подключения задаётся в .env`);
  const pool = new Pool({ connectionString: url, max: 5, idleTimeoutMillis: 30000, statement_timeout: 10000 });
  pool.on('error', (e) => console.error('db pool:', e.code || e.message));
  return pool;
}

async function q(pool, sql, params = []) {
  const r = await pool.query(sql, params);
  return r.rows;
}

module.exports = { makePool, q };
