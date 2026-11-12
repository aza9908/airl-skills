'use strict';
// Тестовые пользователи хаба — по одному на роль (раздел 7 карты). Пароль — из DEMO_PASSWORD
// (задаётся при первом запуске в .env, в git не попадает, в вывод не печатается).
// Повторный запуск обновляет пароль. Подключение — пользователем svc_hub.
const crypto = require('node:crypto');
const { Client } = require('pg');

const USERS = [
  ['ceo', 'Руководитель AIRL (демо)', 'ceo', null],
  ['head_finance', 'Финансовый директор (демо)', 'head_finance', 'finance'],
  ['staff_finance', 'Бухгалтер (демо)', 'staff_finance', 'finance'],
  ['head_sales', 'Руководитель продаж (демо)', 'head_sales', 'sales'],
  ['staff_sales', 'Менеджер по продажам (демо)', 'staff_sales', 'sales'],
  ['head_edu', 'Руководитель обучения (демо)', 'head_edu', 'edu'],
  ['staff_edu', 'Куратор потока (демо)', 'staff_edu', 'edu'],
];

function hash(password) {
  const salt = crypto.randomBytes(16);
  return `scrypt$${salt.toString('base64')}$${crypto.scryptSync(password, salt, 64).toString('base64')}`;
}

(async () => {
  const pw = process.env.DEMO_PASSWORD;
  if (!pw || pw.length < 10) { console.error('DEMO_PASSWORD не задан или короче 10 знаков'); process.exit(2); }
  const c = new Client({ connectionString: process.env.HUB_DATABASE_URL || process.env.DATABASE_URL });
  await c.connect();
  for (const [login, name, role, dept] of USERS) {
    await c.query(`INSERT INTO hub.users (login, display_name, role, department, password_hash)
                   VALUES ($1, $2, $3, $4, $5)
                   ON CONFLICT (login) DO UPDATE SET display_name = EXCLUDED.display_name, role = EXCLUDED.role,
                     department = EXCLUDED.department, password_hash = EXCLUDED.password_hash, failed_logins = 0, locked_until = NULL`,
    [login, name, role, dept, hash(pw)]);
  }
  await c.end();
  console.log(`Пользователи хаба: ${USERS.map((u) => u[0]).join(', ')} (пароль — DEMO_PASSWORD из .env)`);
})().catch((e) => { console.error('create_users:', e.message); process.exit(1); });
