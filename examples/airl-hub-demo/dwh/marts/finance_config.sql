-- Настройка модулей отдела «Финансы» (mart_finance): ответы на вопросы настройки
-- MODULE.md. Значения — СИНТЕТИЧЕСКИЕ (демо): в реальной компании статьи и счета
-- переносятся из Excel финансового директора, бюджет — из его бюджета.
-- Выполняется после kit.sql и schema.sql модулей. Повторный запуск безопасен.
SET search_path TO mart_finance;

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('kit',          'currency',               '"KZT"',              'setup'),
 -- pnl-cashflow (пороги — те же, что в metrics.definitions по карте, раздел 4)
 ('pnl-cashflow', 'eliminate_intragroup',    'true',               'setup'),
 ('pnl-cashflow', 'intragroup_cogs_article', '"COGS-CONTR"',       'setup'),
 ('pnl-cashflow', 'margin_warn',             '65',                 'setup'),
 ('pnl-cashflow', 'margin_bad',              '55',                 'setup'),
 ('pnl-cashflow', 'net_warn_pct',            '10',                 'setup'),
 ('pnl-cashflow', 'cash_warn',               '25000000',           'setup'),
 ('pnl-cashflow', 'cash_bad',                '12000000',           'setup'),
 ('pnl-cashflow', 'budget_tolerance_pct',    '10',                 'setup'),
 ('pnl-cashflow', 'recipient',               '"role:head_finance"', 'setup'),
 ('pnl-cashflow', 'data_recipient',          '"role:staff_finance"', 'setup'),
 ('pnl-cashflow', 'channel',                 '"in_app"',           'setup'),
 -- receivables
 ('receivables', 'currency',              '"KZT"',               'setup'),
 ('receivables', 'use_contract_terms',    'true',                'setup'),
 ('receivables', 'include_aggregators',   'false',               'setup'),
 ('receivables', 'overdue_warn',          '8000000',             'setup'),
 ('receivables', 'overdue_bad',           '15000000',            'setup'),
 ('receivables', 'share_warn',            '20',                  'setup'),
 ('receivables', 'share_bad',             '35',                  'setup'),
 ('receivables', 'promise_tolerance_pct', '5',                   'setup'),
 ('receivables', 'finance_recipient',     '"role:head_finance"', 'setup'),
 ('receivables', 'channel',               '"in_app"',            'setup'),
 -- bank-reconciliation
 ('bank-reconciliation', 'amount_only_days',     '60',                   'setup'),
 ('bank-reconciliation', 'auto_confirm_enabled', 'false',                'setup'),
 ('bank-reconciliation', 'auto_confirm_from',    'null',                 'setup'),
 ('bank-reconciliation', 'auto_confirm_rules',   '["amount_tax_doc"]',   'setup'),
 ('bank-reconciliation', 'unmatched_grace_days', '2',                    'setup'),
 ('bank-reconciliation', 'unmatched_warn',       '1',                    'setup'),
 ('bank-reconciliation', 'unmatched_bad',        '10',                   'setup'),
 ('bank-reconciliation', 'match_rate_warn',      '70',                   'setup'),
 ('bank-reconciliation', 'match_rate_bad',       '50',                   'setup'),
 ('bank-reconciliation', 'recipient',            '"role:staff_finance"', 'setup'),
 ('bank-reconciliation', 'reverse_recipient',    '"role:head_finance"',  'setup'),
 ('bank-reconciliation', 'channel',              '"in_app"',             'setup')
ON CONFLICT (module, key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by;

-- Дерево управленческих статей AIRL. Родители — раньше детей.
INSERT INTO pnl_articles (code, title, parent_code, section, nature, ord, created_by) VALUES
 ('REV',          'Выручка',                          NULL,        'revenue', 'income',  10, 'setup'),
 ('REV-COURSE',   'Курс VibeOps',                     'REV',       'revenue', 'income',  10, 'setup'),
 ('REV-CORP',     'Корпоративное обучение',           'REV',       'revenue', 'income',  20, 'setup'),
 ('REV-DEV',      'Разработка и внедрение ИИ',        'REV',       'revenue', 'income',  30, 'setup'),
 ('REV-CONS',     'Консалтинг',                       'REV',       'revenue', 'income',  40, 'setup'),
 ('COGS',         'Прямые расходы',                   NULL,        'cogs',    'expense', 10, 'setup'),
 ('COGS-CONTR',   'Подрядчики',                       'COGS',      'cogs',    'expense', 10, 'setup'),
 ('COGS-CLOUD',   'Облако и API ИИ',                  'COGS',      'cogs',    'expense', 20, 'setup'),
 ('OPEX-SELL',    'Коммерческие расходы',             NULL,        'opex',    'expense', 10, 'setup'),
 ('OPEX-ADS',     'Реклама',                          'OPEX-SELL', 'opex',    'expense', 10, 'setup'),
 ('OPEX-ADM',     'Административные расходы',         NULL,        'opex',    'expense', 20, 'setup'),
 ('OPEX-PAYROLL', 'ФОТ с налогами',                   'OPEX-ADM',  'opex',    'expense', 10, 'setup'),
 ('OPEX-RENT',    'Аренда',                           'OPEX-ADM',  'opex',    'expense', 20, 'setup'),
 ('OPEX-BANK',    'Банковские комиссии',              'OPEX-ADM',  'opex',    'expense', 30, 'setup'),
 ('TAX-CIT',      'Корпоративный подоходный налог',   NULL,        'tax',     'expense', 10, 'setup')
ON CONFLICT (code) DO NOTHING;

INSERT INTO pnl_account_map (account_prefix, article_code, created_by) VALUES
 ('6010.01', 'REV-COURSE',   'setup'), ('6010.02', 'REV-CORP',  'setup'),
 ('6010.03', 'REV-DEV',      'setup'), ('6010.04', 'REV-CONS',  'setup'),
 ('7010.01', 'COGS-CONTR',   'setup'), ('7010.02', 'COGS-CLOUD', 'setup'),
 ('7110',    'OPEX-ADS',     'setup'), ('7210.01', 'OPEX-PAYROLL', 'setup'),
 ('7210.02', 'OPEX-RENT',    'setup'), ('7210.08', 'OPEX-BANK', 'setup'),
 ('7710',    'TAX-CIT',      'setup')
ON CONFLICT (account_prefix) DO NOTHING;

INSERT INTO pnl_group_counterparties (counterparty_id, title, created_by) VALUES
 ('GRP-airl',     'ТОО «AI Research Labs» (своё юрлицо)', 'setup'),
 ('GRP-airl_dev', 'ТОО «AIRL Dev» (своё юрлицо)',          'setup')
ON CONFLICT (counterparty_id) DO NOTHING;

INSERT INTO pnl_cf_articles (code, title, activity, created_by) VALUES
 ('CF-SALES',      'Поступления от покупателей',        'operating', 'setup'),
 ('CF-SUPPLIERS',  'Оплата поставщикам',                'operating', 'setup'),
 ('CF-PAYROLL',    'Зарплата',                          'operating', 'setup'),
 ('CF-RENT',       'Аренда',                            'operating', 'setup'),
 ('CF-TAX',        'Налоги',                            'operating', 'setup'),
 ('CF-DIVIDENDS',  'Дивиденды участникам',              'financing', 'setup'),
 ('CF-INTRAGROUP', 'Расчёты между своими юрлицами',     'internal',  'setup')
ON CONFLICT (code) DO NOTHING;

-- Начальные остатки денег — «ввод остатков» 1С на дату начала истории.
INSERT INTO pnl_cash_openings (cash_account, as_of, amount, currency, created_by)
SELECT account_id, as_of, amount, 'KZT', 'setup' FROM core.cash_openings
ON CONFLICT (cash_account) DO NOTHING;

-- Бюджет статья × месяц × юрлицо: среднее факта трёх месяцев до прошлого (синтетика:
-- так «финдиректор» составил бюджет). Реклама и облако в последних месяцах выросли —
-- бюджет превышен, это видно на экране «ОПиУ» и в уведомлениях.
WITH months AS (
    SELECT (date_trunc('month', current_date) - make_interval(months => k))::date AS month
    FROM generate_series(-1, 14) k
),
fact AS (
    SELECT date_trunc('month', entry_date)::date AS month, branch_id,
           pnl_article_for(account_code) AS article_code, sum(amount) AS amount
    FROM src_pnl_entries GROUP BY 1, 2, 3
)
INSERT INTO pnl_budgets (article_code, month, branch_id, amount, currency, created_by)
SELECT f.article_code, m.month, f.branch_id, round(avg(f.amount), -4), 'KZT', 'setup'
FROM months m
JOIN fact f ON f.month BETWEEN (m.month - interval '4 months')::date AND (m.month - interval '2 months')::date
WHERE f.article_code <> '_UNMAPPED'
GROUP BY f.article_code, m.month, f.branch_id
ON CONFLICT (article_code, month, branch_id) DO NOTHING;

-- Закрытые месяцы: всё старше прошлого месяца.
SELECT pnl_close_month((date_trunc('month', current_date) - make_interval(months => i))::date,
                       'setup', 'Месяц закрыт в 1С')
FROM generate_series(2, 17) i
WHERE NOT EXISTS (SELECT 1 FROM pnl_periods p
                  WHERE p.month = (date_trunc('month', current_date) - make_interval(months => i))::date
                    AND p.status = 'closed');

SELECT pnl_rebuild('setup');
SELECT pnl_queue_notifications();

-- Сверка банка: первый подбор, комиссии банка — «не сопоставлять».
SELECT bank_mark_line(line_id, 'bank_fee', 'setup', 'Комиссия за обслуживание')
FROM src_bank_statement_lines l
WHERE purpose LIKE 'Комиссия%' AND NOT EXISTS (SELECT 1 FROM bank_line_marks m WHERE m.line_id = l.line_id);
SELECT bank_suggest('setup');
