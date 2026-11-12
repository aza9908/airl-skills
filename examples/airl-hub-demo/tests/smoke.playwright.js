'use strict';
// Сквозной тест Playwright: вход под ceo, head_finance, staff_sales; видимость по ролям;
// цифры карточек экрана руководителя = SQL metrics.kpi_period; скриншоты (компьютер и телефон, DPR 2).
// Запуск: DEMO_PASSWORD=... ADMIN_DB_URL=... node tests/smoke.playwright.js [http://127.0.0.1:8080]
const { chromium } = require('playwright');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');

const BASE = process.argv[2] || 'http://127.0.0.1:8080';
const PW = process.env.DEMO_PASSWORD;
const SHOTS = path.join(__dirname, '..', 'screenshots');
fs.mkdirSync(SHOTS, { recursive: true });
let fails = 0;
const ok = (cond, text) => { console.log(`${cond ? '✔' : '✖'} ${text}`); if (!cond) fails++; };

function sql(q) {
  return execFileSync('psql', [process.env.ADMIN_DB_URL, '-X', '-At', '-F', '\t', '-c', q], { encoding: 'utf8' }).trim()
    .split('\n').filter(Boolean).map((l) => l.split('\t'));
}

async function newPage(browser, mobile) {
  const ctx = await browser.newContext(mobile
    ? { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, locale: 'ru-RU', timezoneId: 'Asia/Almaty' }
    : { viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, locale: 'ru-RU', timezoneId: 'Asia/Almaty' });
  const page = await ctx.newPage();
  page.errors = [];
  page.on('console', (m) => { if (m.type() === 'error' && !/fonts\.g/.test(m.text())) page.errors.push(m.text()); });
  page.on('response', (r) => { if (r.status() >= 400 && !/\/api\//.test(r.url())) page.errors.push(`${r.status()} ${r.url()}`); });
  page.on('pageerror', (e) => page.errors.push(e.message));
  return { ctx, page };
}

async function login(page, user) {
  await page.goto(`${BASE}/login`);
  await page.fill('#login', user);
  await page.fill('#password', PW);
  await Promise.all([page.waitForURL((u) => !u.pathname.startsWith('/login')), page.click('#submit')]);
}

// Запрос из страницы (с cookie сессии браузера), возвращает код ответа.
const status = (page, url) => page.evaluate(async (u) => (await fetch(u, { credentials: 'same-origin' })).status, url);

async function shot(page, name) {
  await page.waitForTimeout(400);
  // телефон — первый экран (как видит человек), компьютер — страница целиком
  await page.screenshot({ path: path.join(SHOTS, `${name}.png`), fullPage: !/mobile/.test(name) });
}

(async () => {
  if (!PW || !process.env.ADMIN_DB_URL) { console.error('Нужны DEMO_PASSWORD и ADMIN_DB_URL'); process.exit(2); }
  const browser = await chromium.launch(process.env.PW_CHROMIUM ? { executablePath: process.env.PW_CHROMIUM } : {});

  // ---------- вход: страница ----------
  for (const mobile of [false, true]) {
    const { ctx, page } = await newPage(browser, mobile);
    await page.goto(`${BASE}/login`);
    await shot(page, `01-login-${mobile ? 'mobile' : 'desktop'}`);
    await ctx.close();
  }

  // ---------- ceo ----------
  for (const mobile of [false, true]) {
    const { ctx, page } = await newPage(browser, mobile);
    await login(page, 'ceo');
    ok(new URL(page.url()).pathname === '/', `ceo после входа на экране руководителя (${mobile ? 'телефон' : 'компьютер'})`);
    await page.waitForSelector('.kpi[data-metric]');
    await page.waitForSelector('#tiles');
    if (!mobile) {
      for (const grain of ['month', 'quarter', 'week', 'day']) {
        await page.click(`[data-grain="${grain}"]`);
        await page.waitForSelector(`[data-grain="${grain}"][aria-pressed="true"]`);
        await page.waitForSelector('.kpi[data-metric]');
        const cards = await page.$$eval('.kpi[data-metric]', (els) => els.map((e) => [e.dataset.metric, e.querySelector('.v').dataset.value]));
        const want = new Map(sql(`SELECT metric_id, COALESCE(value::text, '') FROM metrics.kpi_period('${grain}')`).map(([k, v]) => [k, v]));
        const bad = cards.filter(([k, v]) => Number(v || NaN) !== Number(want.get(k) || NaN) && !(v === '' && want.get(k) === ''));
        ok(cards.length === 12 && bad.length === 0, `ceo, период «${grain}»: ${cards.length} карточек, все равны SQL metrics.kpi_period (расхождений: ${bad.length})`);
      }
      await page.click('[data-grain="month"]');
      await page.waitForSelector('.kpi[data-metric]');
      const tiles = await page.$$eval('.tile', (t) => t.map((x) => x.dataset.service));
      ok(tiles.length === 3, `ceo видит плитки всех отделов: ${tiles.join(', ')}`);
      const tileRev = await page.$eval('[data-service="finance"]', (t) => t.textContent);
      ok(/Выручка/.test(tileRev) && /Валовая маржа/.test(tileRev), 'подписи плитки — из карты (Выручка, Валовая маржа)');
      ok(await page.$('#pnl') && await page.$('#aging') && await page.$('#funnel') && await page.$('#forecast'), 'ОПиУ, старение дебиторки, воронка, прогноз — на экране');
    }
    await shot(page, `02-ceo-overview-${mobile ? 'mobile' : 'desktop'}`);
    for (const [p, name, sel] of [['/finance/', 'finance-overview', '.kpi'], ['/finance/#/pnl', 'finance-pnl', '.tbl'], ['/finance/#/debtors', 'finance-debtors', '.tbl'],
      ['/finance/#/bank', 'finance-bank', '.kpi'], ['/sales/', 'sales-overview', '.kpi'], ['/sales/#/plan', 'sales-plan', '.tbl'], ['/edu/', 'edu-overview', '.kpi']]) {
      await page.goto(BASE + p); await page.waitForSelector(sel);
      if (!mobile || ['finance-overview', 'finance-pnl', 'sales-overview', 'edu-overview'].includes(name)) await shot(page, `03-ceo-${name}-${mobile ? 'mobile' : 'desktop'}`);
    }
    const fin = await page.goto(`${BASE}/finance/#/debtors`).then(() => page.waitForSelector('.tbl')).then(() => page.$$eval('.tbl tbody td:first-child a', (a) => a.map((x) => x.textContent)));
    ok(fin.some((n) => /\*\*\*/.test(n)) || fin.every((n) => /ТОО/.test(n)), 'ceo: имена физлиц-должников замаскированы');
    ok(page.errors.length === 0, `ceo: ошибок в консоли нет (${page.errors.slice(0, 2).join(' | ')})`);
    await ctx.close();
  }

  // ---------- head_finance ----------
  {
    const { ctx, page } = await newPage(browser, false);
    await login(page, 'head_finance');
    await page.waitForSelector('.kpi[data-metric]');
    const metrics = await page.$$eval('.kpi[data-metric]', (els) => els.map((e) => e.dataset.metric));
    ok(metrics.length === 5 && !metrics.includes('lead') && !metrics.includes('enrollments'), `head_finance видит только показатели финансов: ${metrics.join(', ')}`);
    const tiles = await page.$$eval('.tile', (t) => t.map((x) => x.dataset.service));
    ok(tiles.length === 1 && tiles[0] === 'finance', `head_finance: плитка только своего отдела (${tiles.join(', ')})`);
    ok(!(await page.$('#funnel')), 'head_finance: воронки продаж нет');
    const opts = await page.$$eval('#svc-switch option', (o) => o.map((x) => x.textContent));
    ok(!opts.includes('Продажи') && !opts.includes('Обучение'), `переключатель отделов: ${opts.join(', ')}`);
    await shot(page, '04-head_finance-overview-desktop');
    const st = await status(page, '/sales/api/overview');
    ok(st === 403, `head_finance → /sales/api/overview: ${st}`);
    await ctx.close();
  }

  // ---------- staff_sales ----------
  for (const mobile of [false, true]) {
    const { ctx, page } = await newPage(browser, mobile);
    await login(page, 'staff_sales');
    ok(new URL(page.url()).pathname === '/sales/', `staff_sales после входа сразу в своём сервисе (${page.url().replace(BASE, '')})`);
    await page.waitForSelector('.tbl, .state');
    const scope = await page.textContent('h1');
    ok(/Мои заявки/.test(scope), `staff_sales видит «${scope}»`);
    await shot(page, `05-staff_sales-leads-${mobile ? 'mobile' : 'desktop'}`);
    if (!mobile) {
      await page.goto(`${BASE}/`);
      ok(new URL(page.url()).pathname === '/sales/', 'staff_sales: экран руководителя → перенаправление в свой сервис');
      await page.goto(`${BASE}/finance/`);
      await page.waitForSelector('.state');
      ok(/недоступен/.test(await page.textContent('#view')), 'staff_sales: сервис «Финансы» недоступен');
      const st = await status(page, '/finance/api/debtors');
      ok(st === 403, `staff_sales → /finance/api/debtors: ${st}`);
      const opts = await page.$$eval('#svc-switch option', (o) => o.map((x) => x.textContent)).catch(() => []);
      ok(!opts.includes('Финансы'), 'staff_sales: в переключателе нет финансов');
      // выход чистит сессию
      await page.goto(`${BASE}/sales/`); await page.waitForSelector('.logout');
      await Promise.all([page.waitForURL(/\/login/), page.click('.logout')]);
      const st2 = await status(page, '/sales/api/leads');
      ok(st2 === 401, `после выхода API → ${st2}`);
    }
    await ctx.close();
  }

  // ---------- head_edu (мобильный экран сервиса обучения) ----------
  {
    const { ctx, page } = await newPage(browser, true);
    await login(page, 'head_edu');
    await page.goto(`${BASE}/edu/#/cohorts`); await page.waitForSelector('.tbl');
    await shot(page, '06-head_edu-cohorts-mobile');
    await ctx.close();
  }

  await browser.close();
  console.log(`\nИтог: ${fails ? 'есть провалы: ' + fails : 'все проверки зелёные'}`);
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
