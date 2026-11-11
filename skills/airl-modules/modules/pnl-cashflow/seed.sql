-- Синтетические справочники, бюджеты и закрытие месяцев для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('pnl-cashflow', 'eliminate_intragroup',    'true',                     'demo'),
 ('pnl-cashflow', 'intragroup_cogs_article', '"COGS-GOODS"',             'demo'),
 ('pnl-cashflow', 'margin_warn',             '35',                       'demo'),
 ('pnl-cashflow', 'margin_bad',              '25',                       'demo'),
 ('pnl-cashflow', 'net_warn_pct',            '10',                       'demo'),
 ('pnl-cashflow', 'cash_warn',               '20000000',                 'demo'),
 ('pnl-cashflow', 'cash_bad',                '5000000',                  'demo'),
 ('pnl-cashflow', 'budget_tolerance_pct',    '10',                       'demo'),
 ('pnl-cashflow', 'recipient',               '"role:fin_director"',      'demo'),
 ('pnl-cashflow', 'data_recipient',          '"role:chief_accountant"',  'demo'),
 ('pnl-cashflow', 'channel',                 '"telegram"',               'demo')
ON CONFLICT (module, key) DO NOTHING;

-- Дерево управленческих статей. Родители — раньше детей.
INSERT INTO pnl_articles (code, title, parent_code, section, nature, ord, created_by) VALUES
 ('REV',          'Выручка',                          NULL,       'revenue',      'income',  10, 'demo'),
 ('REV-COFFEE',   'Кофе: зерно и молотый',            'REV',      'revenue',      'income',  10, 'demo'),
 ('REV-SERVICE',  'Сервис оборудования',              'REV',      'revenue',      'income',  20, 'demo'),
 ('COGS-GOODS',   'Себестоимость продаж',             NULL,       'cogs',         'expense', 10, 'demo'),
 ('OPEX-SELL',    'Коммерческие расходы',             NULL,       'opex',         'expense', 10, 'demo'),
 ('OPEX-MKT',     'Маркетинг и реклама',              'OPEX-SELL','opex',         'expense', 10, 'demo'),
 ('OPEX-LOG',     'Доставка и логистика',             'OPEX-SELL','opex',         'expense', 20, 'demo'),
 ('OPEX-ADM',     'Административные расходы',         NULL,       'opex',         'expense', 20, 'demo'),
 ('OPEX-PAYROLL', 'Зарплата и налоги с ФОТ',          'OPEX-ADM', 'opex',         'expense', 10, 'demo'),
 ('OPEX-RENT',    'Аренда',                           'OPEX-ADM', 'opex',         'expense', 20, 'demo'),
 ('OPEX-IT',      'IT и связь',                       'OPEX-ADM', 'opex',         'expense', 30, 'demo'),
 ('OTH-INCOME',   'Прочие доходы',                    NULL,       'other',        'income',  10, 'demo'),
 ('DA',           'Амортизация',                      NULL,       'depreciation', 'expense', 10, 'demo'),
 ('FIN-INTEREST', 'Проценты по кредитам',             NULL,       'finance',      'expense', 10, 'demo'),
 ('TAX-CIT',      'Корпоративный подоходный налог',   NULL,       'tax',          'expense', 10, 'demo')
ON CONFLICT (code) DO NOTHING;

-- Счета 1С (план счетов РК) → статьи. Счёт 7480 намеренно не сопоставлен: он виден
-- в «Качестве данных» и строкой «Не разнесено по статьям».
INSERT INTO pnl_account_map (account_prefix, article_code, created_by) VALUES
 ('6010',    'REV-COFFEE',   'demo'),
 ('6010.02', 'REV-SERVICE',  'demo'),
 ('6280',    'OTH-INCOME',   'demo'),
 ('7010',    'COGS-GOODS',   'demo'),
 ('7110.01', 'OPEX-MKT',     'demo'),
 ('7110.02', 'OPEX-LOG',     'demo'),
 ('7210',    'OPEX-ADM',     'demo'),
 ('7210.01', 'OPEX-PAYROLL', 'demo'),
 ('7210.02', 'OPEX-RENT',    'demo'),
 ('7210.03', 'OPEX-IT',      'demo'),
 ('7210.05', 'DA',           'demo'),
 ('7310',    'FIN-INTEREST', 'demo'),
 ('7710',    'TAX-CIT',      'demo')
ON CONFLICT (account_prefix) DO NOTHING;

INSERT INTO pnl_group_counterparties (counterparty_id, title, created_by) VALUES
 ('GRP-ALA',   'ТОО «Торговая компания Алматы» (своя)', 'demo'),
 ('GRP-AST',   'ТОО «Торговая компания Астана» (своя)', 'demo'),
 ('GRP-ROAST', 'ТОО «Обжарочный цех» (своя)',           'demo')
ON CONFLICT (counterparty_id) DO NOTHING;

-- Общие расходы офиса: IT — по выручке филиалов, остальное — 50/30/20.
INSERT INTO pnl_alloc_rules (code, title, from_branch, article_code, method, priority, valid_from, created_by) VALUES
 ('ALLOC-IT',     'IT офиса — по выручке филиалов',    'office', 'OPEX-IT', 'revenue_share', 10,
  (date_trunc('month', current_date) - interval '24 months')::date, 'demo'),
 ('ALLOC-OFFICE', 'Расходы офиса — 50 / 30 / 20',      'office', NULL,      'fixed_pct',     100,
  (date_trunc('month', current_date) - interval '24 months')::date, 'demo')
ON CONFLICT (code) DO NOTHING;

INSERT INTO pnl_alloc_shares (rule_id, to_branch, share_pct, created_by)
SELECT r.id, v.to_branch, v.share_pct, 'demo'
FROM (VALUES ('ALLOC-IT', 'ala', NULL), ('ALLOC-IT', 'ast', NULL), ('ALLOC-IT', 'roast', NULL),
             ('ALLOC-OFFICE', 'ala', 50), ('ALLOC-OFFICE', 'ast', 30), ('ALLOC-OFFICE', 'roast', 20))
     AS v(rule_code, to_branch, share_pct)
JOIN pnl_alloc_rules r ON r.code = v.rule_code
ON CONFLICT (rule_id, to_branch) DO NOTHING;

INSERT INTO pnl_cf_articles (code, title, activity, created_by) VALUES
 ('CF-SALES',     'Поступления от покупателей',      'operating', 'demo'),
 ('CF-SUPPLIERS', 'Оплата поставщикам',              'operating', 'demo'),
 ('CF-PAYROLL',   'Зарплата',                        'operating', 'demo'),
 ('CF-RENT',      'Аренда',                          'operating', 'demo'),
 ('CF-OPEX',      'Прочие операционные платежи',     'operating', 'demo'),
 ('CF-TAX',       'Налоги',                          'operating', 'demo'),
 ('CF-CAPEX',     'Покупка оборудования',            'investing', 'demo'),
 ('CF-LOAN-IN',   'Получение кредита',               'financing', 'demo'),
 ('CF-LOAN-OUT',  'Погашение кредита',               'financing', 'demo'),
 ('CF-INTEREST',  'Проценты по кредиту',             'financing', 'demo'),
 ('CF-TRANSFER',  'Перевод между своими счетами',    'internal',  'demo')
ON CONFLICT (code) DO NOTHING;

INSERT INTO pnl_cash_openings (cash_account, as_of, amount, currency, created_by) VALUES
 ('KZ-MAIN',  (date_trunc('month', current_date) - interval '14 months')::date, 30000000.00, 'KZT', 'demo'),
 ('KZ-KASPI', (date_trunc('month', current_date) - interval '14 months')::date,  2000000.00, 'KZT', 'demo'),
 ('USD-MAIN', (date_trunc('month', current_date) - interval '14 months')::date,    50000.00, 'USD', 'demo')
ON CONFLICT (cash_account) DO NOTHING;

-- Бюджет на 15 месяцев (12 прошлых, текущий, 2 следующих), уже после распределения
-- расходов офиса: доля офиса включена в статьи филиалов.
INSERT INTO pnl_budgets (article_code, month, branch_id, amount, currency, created_by)
SELECT v.article_code, mo.month, v.branch_id,
       round(v.base * (1 + 0.12 * cos(2 * pi() * (extract(month FROM mo.month) - 1) / 12)::numeric) * (1 + 0.01 * (14 - mo.i)), -3),
       'KZT', 'u_fin'
FROM (VALUES
 ('ala',    'REV-COFFEE',   42500000), ('ala',   'COGS-GOODS', 26200000), ('ala',   'OPEX-MKT',  1800000),
 ('ala',    'OPEX-LOG',      1200000), ('ala',   'OPEX-PAYROLL', 7500000), ('ala',  'OPEX-RENT', 2100000),
 ('ala',    'OPEX-IT',        450000),
 ('ast',    'REV-COFFEE',   25300000), ('ast',   'COGS-GOODS', 15800000), ('ast',   'OPEX-MKT',  1200000),
 ('ast',    'OPEX-LOG',      1300000), ('ast',   'OPEX-PAYROLL', 4800000), ('ast',  'OPEX-RENT', 1460000),
 ('ast',    'OPEX-IT',        270000),
 ('roast',  'REV-COFFEE',   46200000), ('roast', 'REV-SERVICE',  600000), ('roast', 'COGS-GOODS', 34500000),
 ('roast',  'OPEX-PAYROLL',  3700000), ('roast', 'OPEX-RENT',    240000), ('roast', 'OPEX-IT',      80000),
 ('roast',  'DA',             900000),
 ('office', 'DA',             300000), ('office', 'FIN-INTEREST', 700000), ('office', 'TAX-CIT', 2000000),
 ('office', 'OTH-INCOME',     300000),
 -- компания: без продаж обжарки своим филиалам (38 млн выручки и себестоимости)
 ('all',    'REV-COFFEE',   76000000), ('all',   'COGS-GOODS', 38500000)
) AS v(branch_id, article_code, base)
CROSS JOIN LATERAL (SELECT i, (date_trunc('month', current_date) - make_interval(months => i))::date AS month
                    FROM generate_series(-2, 12) i) mo
ON CONFLICT (article_code, month, branch_id) DO NOTHING;

-- Закрытые месяцы: всё старше прошлого месяца. Один месяц открывали для исправления.
SELECT pnl_close_month((date_trunc('month', current_date) - make_interval(months => i))::date,
                       'u_chief_accountant', 'Месяц закрыт в 1С')
FROM generate_series(2, 14) i;

DO $$
DECLARE
    v_month date := (date_trunc('month', current_date) - interval '3 months')::date;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM airl_audit WHERE module = 'pnl-cashflow' AND entity = 'period'
                     AND entity_id = to_char(v_month, 'YYYY-MM') AND to_status = 'reopened') THEN
        PERFORM pnl_reopen_month(v_month, 'u_chief_accountant', 'Досчитана себестоимость по поздней поставке упаковки');
        PERFORM pnl_close_month(v_month, 'u_chief_accountant', 'Месяц закрыт повторно');
    END IF;
END $$;

SELECT pnl_rebuild('demo');
SELECT pnl_queue_notifications();
