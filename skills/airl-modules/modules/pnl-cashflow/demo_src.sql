-- Демо-источники для модуля «ОПиУ и ДДС»: проводки по счетам доходов и расходов и
-- движение денег за 15 месяцев. Синтетика, только для разработки и показа. В работе
-- src_pnl_entries и src_pnl_cash заменяет адаптер /airl-dwh поверх 1С (обороты по счетам
-- 6xxx/7xxx и документы движения денег со статьёй ДДС).
--
-- Компания: два торговых филиала (ala, ast), обжарка (roast) продаёт зерно филиалам
-- внутри группы и внешним клиентам, офис (office) несёт общие расходы.

CREATE TABLE IF NOT EXISTS demo_pnl_entries (
    entry_id        text PRIMARY KEY,
    entry_date      date          NOT NULL,
    account_code    text          NOT NULL,
    amount          numeric(18,2) NOT NULL,
    currency        char(3)       NOT NULL,
    branch_id       text          NOT NULL,
    direction       text          NOT NULL,
    source_doc      text,
    counterparty_id text
);

CREATE TABLE IF NOT EXISTS demo_pnl_cash (
    cash_id         text PRIMARY KEY,
    pay_date        date          NOT NULL,
    cash_account    text          NOT NULL,
    amount          numeric(18,2) NOT NULL,
    currency        char(3)       NOT NULL,
    cf_article      text,
    branch_id       text          NOT NULL,
    counterparty_id text,
    source_doc      text
);

-- Шаблон оборотов: счёт, филиал, сумма в месяц, направление, сколько документов в месяц,
-- контрагент. Сумма меняется по сезону (зима выше), растёт на 1% в месяц и «шумит».
INSERT INTO demo_pnl_entries
SELECT 'E-' || t.code || '-' || to_char(m.month, 'YYYYMM') || '-' || k,
       d.entry_date, t.account_code,
       round(t.base / t.per_month
             * (1 + 0.12 * cos(2 * pi() * (extract(month FROM m.month) - 1) / 12)::numeric)
             * (1 + 0.01 * (14 - m.i))
             * (1 + 0.06 * ((abs(hashtext(t.code || m.i || k)) % 200) - 100) / 100.0), 2),
       'KZT', t.branch_id, t.direction,
       t.doc_prefix || '-' || to_char(m.month, 'YYMM') || '-' || k, t.counterparty_id
FROM (VALUES
 ('ALA-REV',   '6010',    'ala',    42000000, 'income',  4, 'РН',  'CL-ALA'),
 ('ALA-COGS',  '7010',    'ala',    26000000, 'expense', 4, 'СП',  NULL),
 ('ALA-MKT',   '7110.01', 'ala',     1800000, 'expense', 2, 'АКТ', 'SUP-ADV'),
 ('ALA-LOG',   '7110.02', 'ala',     1200000, 'expense', 2, 'АКТ', 'SUP-LOG'),
 ('ALA-PAY',   '7210.01', 'ala',     4500000, 'expense', 1, 'ЗП',  NULL),
 ('ALA-RENT',  '7210.02', 'ala',     1500000, 'expense', 1, 'АКТ', 'LANDLORD-1'),
 ('AST-REV',   '6010',    'ast',    25000000, 'income',  4, 'РН',  'CL-AST'),
 ('AST-COGS',  '7010',    'ast',    15800000, 'expense', 4, 'СП',  NULL),
 ('AST-MKT',   '7110.01', 'ast',     1200000, 'expense', 2, 'АКТ', 'SUP-ADV'),
 ('AST-LOG',   '7110.02', 'ast',     1400000, 'expense', 2, 'АКТ', 'SUP-LOG'),
 ('AST-PAY',   '7210.01', 'ast',     3000000, 'expense', 1, 'ЗП',  NULL),
 ('AST-RENT',  '7210.02', 'ast',     1100000, 'expense', 1, 'АКТ', 'LANDLORD-2'),
 ('RST-REV',   '6010',    'roast',   8000000, 'income',  4, 'РН',  'CL-HORECA'),
 ('RST-SVC',   '6010.02', 'roast',    600000, 'income',  1, 'АКТ', 'CL-HORECA'),
 ('RST-IG1',   '6010',    'roast',  24000000, 'income',  4, 'РН',  'GRP-ALA'),
 ('RST-IG2',   '6010',    'roast',  14000000, 'income',  4, 'РН',  'GRP-AST'),
 ('RST-COGS',  '7010',    'roast',  34500000, 'expense', 4, 'СП',  NULL),
 ('RST-PAY',   '7210.01', 'roast',   2500000, 'expense', 1, 'ЗП',  NULL),
 ('RST-DA',    '7210.05', 'roast',    900000, 'expense', 1, 'АМ',  NULL),
 ('OFF-PAY',   '7210.01', 'office',  6000000, 'expense', 1, 'ЗП',  NULL),
 ('OFF-RENT',  '7210.02', 'office',  1200000, 'expense', 1, 'АКТ', 'LANDLORD-1'),
 ('OFF-IT',    '7210.03', 'office',   800000, 'expense', 1, 'АКТ', 'SUP-IT'),
 ('OFF-DA',    '7210.05', 'office',   300000, 'expense', 1, 'АМ',  NULL),
 ('OFF-INT',   '7310',    'office',   700000, 'expense', 1, 'БАНК','BANK-1'),
 ('OFF-CIT',   '7710',    'office',  2000000, 'expense', 1, 'НАЛ', NULL),
 ('OFF-OTHI',  '6280',    'office',   300000, 'income',  1, 'БУХ', NULL),
 ('OFF-OTHE',  '7480',    'office',   150000, 'expense', 1, 'БУХ', NULL)
) AS t(code, account_code, branch_id, base, direction, per_month, doc_prefix, counterparty_id)
CROSS JOIN LATERAL (SELECT i, (date_trunc('month', current_date) - make_interval(months => i))::date AS month
                    FROM generate_series(0, 14) i) m
CROSS JOIN LATERAL generate_series(1, t.per_month) k
CROSS JOIN LATERAL (SELECT least(m.month + (k - 1) * 7 + 6, (m.month + interval '1 month - 1 day')::date) AS entry_date) d
WHERE d.entry_date < current_date
ON CONFLICT (entry_id) DO NOTHING;

-- Одна проводка в долларах (курсовая разница по контракту на зерно) — в итог не идёт,
-- показывается в списке «в другой валюте».
INSERT INTO demo_pnl_entries VALUES
 ('E-USD-1', current_date - 20, '7430', 1200.00, 'USD', 'roast', 'expense', 'БУХ-USD-1', 'SUP-001')
ON CONFLICT (entry_id) DO NOTHING;

-- Деньги: поступления от покупателей, оплаты поставщикам, зарплата, аренда, налоги,
-- покупка ростера (инвестиции), кредит и его погашение (финансирование), переводы
-- между своими счетами.
INSERT INTO demo_pnl_cash
SELECT 'C-' || t.code || '-' || to_char(m.month, 'YYYYMM') || '-' || k,
       d.pay_date, t.cash_account,
       round(t.base / t.per_month
             * (1 + 0.10 * cos(2 * pi() * (extract(month FROM m.month) - 1) / 12)::numeric)
             * (1 + 0.01 * (14 - m.i))
             * (1 + 0.05 * ((abs(hashtext(t.code || m.i || k)) % 200) - 100) / 100.0), 2),
       'KZT', t.cf_article, t.branch_id, t.counterparty_id,
       'ДДС-' || t.code || '-' || to_char(m.month, 'YYMM') || '-' || k
FROM (VALUES
 ('IN-ALA',  'KZ-MAIN',   40500000, 'CF-SALES',     'ala',    4, 'CL-ALA'),
 ('IN-AST',  'KZ-MAIN',   24000000, 'CF-SALES',     'ast',    4, 'CL-AST'),
 ('IN-RST',  'KZ-KASPI',   8200000, 'CF-SALES',     'roast',  4, 'CL-HORECA'),
 ('SUP',     'KZ-MAIN',  -30500000, 'CF-SUPPLIERS', 'roast',  4, 'SUP-001'),
 ('PAY',     'KZ-MAIN',  -16000000, 'CF-PAYROLL',   'office', 2, NULL),
 ('RENT',    'KZ-MAIN',   -3800000, 'CF-RENT',      'office', 1, 'LANDLORD-1'),
 ('OPEX',    'KZ-MAIN',   -5600000, 'CF-OPEX',      'office', 2, 'SUP-ADV'),
 ('TAX',     'KZ-MAIN',   -4200000, 'CF-TAX',       'office', 1, NULL),
 ('INT',     'KZ-MAIN',    -700000, 'CF-INTEREST',  'office', 1, 'BANK-1'),
 ('TR-OUT',  'KZ-KASPI',  -6000000, 'CF-TRANSFER',  'office', 1, NULL),
 ('TR-IN',   'KZ-MAIN',    6000000, 'CF-TRANSFER',  'office', 1, NULL)
) AS t(code, cash_account, base, cf_article, branch_id, per_month, counterparty_id)
CROSS JOIN LATERAL (SELECT i, (date_trunc('month', current_date) - make_interval(months => i))::date AS month
                    FROM generate_series(0, 14) i) m
CROSS JOIN LATERAL generate_series(1, t.per_month) k
CROSS JOIN LATERAL (SELECT least(m.month + (k - 1) * 7 + 9, (m.month + interval '1 month - 1 day')::date) AS pay_date) d
WHERE d.pay_date < current_date
ON CONFLICT (cash_id) DO NOTHING;

INSERT INTO demo_pnl_cash VALUES
 ('C-CAPEX-1', (date_trunc('month', current_date) - interval '9 months')::date + 14, 'KZ-MAIN', -18000000.00, 'KZT', 'CF-CAPEX',    'roast',  'SUP-EQ',  'ДДС-CAPEX-1'),
 ('C-LOAN-1',  (date_trunc('month', current_date) - interval '10 months')::date + 3, 'KZ-MAIN',  20000000.00, 'KZT', 'CF-LOAN-IN',  'office', 'BANK-1',  'ДДС-LOAN-1'),
 ('C-USD-1',   current_date - 15,                                                    'USD-MAIN',   -19200.00, 'USD', 'CF-SUPPLIERS','roast',  'SUP-001', 'ДДС-USD-1')
ON CONFLICT (cash_id) DO NOTHING;

INSERT INTO demo_pnl_cash
SELECT 'C-LOAN-R-' || i, (date_trunc('month', current_date) - make_interval(months => i))::date + 20,
       'KZ-MAIN', -1000000.00, 'KZT', 'CF-LOAN-OUT', 'office', 'BANK-1', 'ДДС-LOAN-R-' || i
FROM generate_series(1, 8) i
ON CONFLICT (cash_id) DO NOTHING;

CREATE OR REPLACE VIEW src_pnl_entries AS
SELECT entry_id, entry_date, account_code, amount, currency, branch_id, direction, source_doc, counterparty_id
FROM demo_pnl_entries;

CREATE OR REPLACE VIEW src_pnl_cash AS
SELECT cash_id, pay_date, cash_account, amount, currency, cf_article, branch_id, counterparty_id, source_doc
FROM demo_pnl_cash;
