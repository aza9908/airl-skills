-- Демо-источники для модуля «Согласование заявок»: подразделения и контрагенты.
-- Синтетика, только для разработки и показа. В работе src_appr_departments и
-- src_appr_counterparties заменяет адаптер /airl-dwh (оргструктура, 1С) или /airl-connect.

CREATE TABLE IF NOT EXISTS demo_appr_departments (
    dept_id      text PRIMARY KEY,
    dept_name    text NOT NULL,
    branch_id    text,
    head_user_id text
);

INSERT INTO demo_appr_departments VALUES
 ('trade_ala', 'Торговая компания Алматы',      'ala', 'u_head_ala'),
 ('trade_ast', 'Торговая компания Астана',      'ast', 'u_head_ast'),
 ('roast',     'Обжарочный цех и QC',           'ala', 'u_head_roast'),
 ('dc',        'Распределительный центр',       'ala', 'u_head_dc'),
 ('office',    'Общие функции (офис, IT, HR)',  'ala', 'u_coo')
ON CONFLICT (dept_id) DO NOTHING;

CREATE OR REPLACE VIEW src_appr_departments AS
SELECT dept_id, dept_name, branch_id, head_user_id
FROM demo_appr_departments;

CREATE TABLE IF NOT EXISTS demo_appr_counterparties (
    counterparty_id   text PRIMARY KEY,
    counterparty_name text NOT NULL,
    counterparty_type text NOT NULL,
    tax_id            text,
    first_deal_date   date
);

INSERT INTO demo_appr_counterparties VALUES
 ('SUP-001',  'Green Coffee Trading B.V. (Нидерланды)', 'supplier',   NULL,           current_date - 1100),
 ('SUP-PACK', 'ТОО «ПакЛайн Алматы»',                   'supplier',   '170440011111', current_date - 800),
 ('SUP-EQ',   'ТОО «Ростер Сервис»',                    'contractor', '190240022222', current_date - 600),
 ('SUP-ADV',  'ТОО «Медиа Плюс»',                       'contractor', '200540033333', current_date - 400),
 ('SUP-ADV2', 'ИП «Наружка Абая»',                      'contractor', '850101300444', current_date - 45),
 ('SUP-IT',   'ТОО «1С-Сервис Казахстан»',              'contractor', '150640055555', current_date - 1500),
 ('SUP-LOG',  'ТОО «Быстрая доставка»',                 'contractor', '160840066666', current_date - 700),
 ('EMP-014',  'Сотрудник 014 (подотчёт)',               'employee',   NULL,           current_date - 900),
 ('EMP-021',  'Сотрудник 021 (подотчёт)',               'employee',   NULL,           current_date - 300)
ON CONFLICT (counterparty_id) DO NOTHING;

CREATE OR REPLACE VIEW src_appr_counterparties AS
SELECT counterparty_id, counterparty_name, counterparty_type, tax_id, first_deal_date
FROM demo_appr_counterparties;
