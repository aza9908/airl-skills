'use strict';
// Проверка статической демо-версии (dist-static/, собрана scripts/build_static.py) без сервера хаба:
// каждая страница и раздел открываются, ошибок в консоли нет, нет горизонтальной прокрутки на 390 px,
// переключатель отделов ведёт в сервис, переключатель периода работает, «Не удалось загрузить» нигде нет.
// Запуск: python3 -m http.server <порт> --bind 127.0.0.1 -d dist-static  и  node tests/static.playwright.js http://127.0.0.1:<порт>
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');

const BASE = process.argv[2] || 'http://127.0.0.1:8099';
const DATA = path.join(__dirname, '..', 'dist-static', 'data');
let fails = 0;
const ok = (cond, text) => { console.log(`${cond ? '✔' : '✖'} ${text}`); if (!cond) fails++; };
const first = (file, key, field) => { try { return JSON.parse(fs.readFileSync(path.join(DATA, file), 'utf8'))[key][0][field]; } catch { return null; } };

const ROUTES = {
  '/': ['', '#income', '#marketing', '#hr', '#ops'],
  '/finance/': ['#/overview', '#/pnl', '#/cash', '#/debtors', `#/client/${first('finance_api_debtors.json', 'rows', 'client_id')}`, '#/bank'],
  '/sales/': ['#/overview', '#/plan', '#/leads'],
  '/marketing/': ['#/overview', '#/campaigns', '#/budget'],
  '/edu/': ['#/overview', '#/cohorts', `#/cohort/${first('edu_api_overview.json', 'cohorts', 'cohort_code')}`],
  '/hr/': ['#/overview', '#/vacancies', '#/onboarding', `#/person/${first('hr_api_onboarding.json', 'rows', 'instance_id')}`, '#/payroll'],
};

async function open(browser, mobile) {
  const ctx = await browser.newContext(mobile
    ? { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, locale: 'ru-RU' }
    : { viewport: { width: 1440, height: 900 }, locale: 'ru-RU' });
  const p = await ctx.newPage();
  p.errors = [];
  p.on('console', (m) => { if (m.type() === 'error' && !/fonts\.g/.test(m.text())) p.errors.push(m.text()); });
  p.on('pageerror', (e) => p.errors.push(e.message));
  p.on('response', (r) => { if (r.status() >= 400 && !/fonts\.g/.test(r.url())) p.errors.push(`${r.status()} ${r.url()}`); });
  return { ctx, p };
}
const settle = async (p) => {
  await p.waitForSelector('#view .kpi, #view .tbl, #view .card, #view .state', { timeout: 15000 });
  await p.waitForFunction(() => !document.querySelector('#view [aria-busy="true"]'), null, { timeout: 15000 }).catch(() => {});
  await p.waitForTimeout(400);
};

(async () => {
  const browser = await chromium.launch(process.env.PW_CHROMIUM ? { executablePath: process.env.PW_CHROMIUM } : {});
  for (const mobile of [false, true]) {
    const { ctx, p } = await open(browser, mobile);
    for (const [base, hashes] of Object.entries(ROUTES)) {
      for (const h of hashes) {
        p.errors = [];
        await p.goto(`${BASE}${base}${h}`);
        await settle(p);
        const err = await p.$$eval('.state.error', (e) => e.map((x) => x.textContent.trim()));
        const banner = await p.$('.demo-banner');
        const noScroll = await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1);
        ok(err.length === 0 && p.errors.length === 0 && banner && (!mobile || noScroll),
          `${mobile ? 'телефон 390' : 'компьютер'} ${base}${h}${err.length ? ' · ' + err[0] : ''}`
          + `${p.errors.length ? ' · ' + p.errors.slice(0, 2).join(' | ') : ''}${mobile && !noScroll ? ' · горизонтальная прокрутка' : ''}`);
      }
    }
    if (!mobile) {
      await p.goto(`${BASE}/`); await settle(p);
      for (const g of ['day', 'week', 'quarter', 'month']) {
        p.errors = [];
        await p.click(`[data-grain="${g}"]`);
        await p.waitForSelector(`[data-grain="${g}"][aria-pressed="true"]`);
        await settle(p);
        const err = await p.$$('.state.error');
        ok(err.length === 0 && p.errors.length === 0 && await p.$('#hr') && await p.$('#marketing'), `экран руководителя, период «${g}»: разделы на месте, ошибок нет`);
      }
      const tiles = await p.$$eval('.tile', (t) => t.map((x) => x.dataset.service));
      ok(tiles.length === 5, `плитки всех 5 отделов: ${tiles.join(', ')}`);
      const opts = await p.$$eval('#svc-switch option', (o) => o.map((x) => x.value));
      ok(opts.length === 6, `переключатель отделов: ${opts.join(', ')}`);
      for (const v of opts.filter((x) => x !== '/')) {
        await p.goto(`${BASE}/`); await settle(p);
        await Promise.all([p.waitForURL((u) => u.pathname === v), p.selectOption('#svc-switch', v)]);
        await settle(p);
        ok(new URL(p.url()).pathname === v && !(await p.$('.state.error')), `переключатель → ${v}`);
      }
      await p.goto(`${BASE}/hr/`); await settle(p);
      await Promise.all([p.waitForURL((u) => u.pathname === '/'), p.click('.logout')]);
      ok(new URL(p.url()).pathname === '/', '«Выйти» → экран руководителя (страницы входа нет)');
    }
    await ctx.close();
  }
  await browser.close();
  console.log(`\nИтог: ${fails ? 'есть провалы: ' + fails : 'статическая версия: все проверки зелёные'}`);
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
