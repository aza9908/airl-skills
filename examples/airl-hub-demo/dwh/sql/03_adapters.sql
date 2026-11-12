-- Адаптеры src_<…>: вход модулей /airl-modules поверх core и metrics.
-- Пишет команда AIRL (/airl-dwh). Колонки и типы — один к одному с разделом «Данные»
-- MODULE.md каждого модуля. Владелец представлений — администратор хранилища:
-- сервис читает адаптер, но не получает прав на сами таблицы core.

-- ===================== mart_finance =====================

-- pnl-cashflow: обороты по счетам доходов (6010.xx по направлениям) и расходов (7xxx).
CREATE OR REPLACE VIEW mart_finance.src_pnl_entries AS
SELECT d.doc_id                                            AS entry_id,
       d.doc_date                                          AS entry_date,
       CASE d.service_line WHEN 'Курс VibeOps' THEN '6010.01' WHEN 'Корпоративное обучение' THEN '6010.02'
                           WHEN 'Разработка ИИ' THEN '6010.03' ELSE '6010.04' END::text AS account_code,
       d.amount_net::numeric(18,2)                         AS amount,
       d.currency::char(3)                                 AS currency,
       d.entity_id                                         AS branch_id,
       'income'::text                                      AS direction,
       d.doc_no                                            AS source_doc,
       CASE WHEN d.is_intragroup THEN 'GRP-' || d.counterparty_entity ELSE d.client_id END AS counterparty_id
FROM core.sales_docs d
UNION ALL
SELECT e.expense_id, e.doc_date, e.account_code, e.amount_net::numeric(18,2), 'KZT'::char(3), e.entity_id,
       'expense', e.expense_id,
       CASE WHEN e.is_intragroup THEN 'GRP-' || le.entity_id ELSE e.supplier_id END
FROM core.expenses e
LEFT JOIN core.suppliers s ON s.supplier_id = e.supplier_id
LEFT JOIN core.legal_entities le ON le.bin = s.tax_id AND s.is_group;

-- pnl-cashflow: движение денег (поступление «+», платёж «−») со статьёй ДДС.
CREATE OR REPLACE VIEW mart_finance.src_pnl_cash AS
SELECT p.payment_id AS cash_id, p.pay_date, p.account_id AS cash_account, p.amount::numeric(18,2) AS amount,
       'KZT'::char(3) AS currency,
       CASE WHEN p.is_intragroup THEN 'CF-INTRAGROUP' ELSE 'CF-SALES' END AS cf_article,
       p.entity_id AS branch_id, COALESCE(p.client_id, 'GRP') AS counterparty_id, p.payment_id AS source_doc
FROM core.payments_in p
UNION ALL
SELECT p.payment_id, p.pay_date, p.account_id, (-p.amount)::numeric(18,2), 'KZT'::char(3),
       CASE WHEN p.is_intragroup THEN 'CF-INTRAGROUP'
            WHEN p.cf_article = 'Зарплата' THEN 'CF-PAYROLL' WHEN p.cf_article = 'Аренда' THEN 'CF-RENT'
            WHEN p.cf_article = 'Налоги' THEN 'CF-TAX' WHEN p.cf_article = 'Дивиденды' THEN 'CF-DIVIDENDS' ELSE 'CF-SUPPLIERS' END,
       p.entity_id, p.supplier_id, p.payment_id
FROM core.payments_out p;

-- receivables: документы реализации с оплатами (по 1С), без внутригрупповых.
CREATE OR REPLACE VIEW mart_finance.src_receivables_docs AS
SELECT d.client_id, c.name AS client_name, d.doc_no, d.doc_date, d.due_date,
       d.amount_gross::numeric AS amount,
       COALESCE((SELECT sum(p.amount) FROM core.payments_in p WHERE p.doc_id = d.doc_id), 0)::numeric AS paid_amount,
       d.currency::char(3) AS currency, d.manager_id, d.entity_id AS branch_id
FROM core.sales_docs d
JOIN core.clients c ON c.client_id = d.client_id
WHERE NOT d.is_intragroup;

CREATE OR REPLACE VIEW mart_finance.src_rcv_clients AS
SELECT c.client_id, c.name AS client_name, NULL::numeric AS credit_limit,
       CASE c.kind WHEN 'company' THEN 30 ELSE 0 END AS payment_terms_days,
       NULL::text AS manager_id, false AS is_aggregator
FROM core.clients c;

-- bank-reconciliation: строки выписок, которые ещё не разнесены в 1С.
CREATE OR REPLACE VIEW mart_finance.src_bank_statement_lines AS
SELECT l.statement_id, l.bank, a.iban AS account, l.line_id, l.value_date, l.amount::numeric(18,2) AS amount,
       l.currency::char(3) AS currency, l.counterparty_name, l.counterparty_tax_id, l.purpose, l.doc_no
FROM core.bank_lines l JOIN core.cash_accounts a ON a.account_id = l.account_id
WHERE NOT l.booked;

-- bank-reconciliation: документы, которые ждут оплату (остаток по 1С > 0).
CREATE OR REPLACE VIEW mart_finance.src_bank_open_items AS
SELECT x.* FROM (
    SELECT d.doc_id AS item_id, 'invoice'::text AS item_type, 'in'::text AS direction,
           c.tax_id AS counterparty_tax_id, c.name AS counterparty_name, d.doc_no, d.doc_date,
           d.amount_gross::numeric(18,2) AS amount,
           COALESCE((SELECT sum(p.amount) FROM core.payments_in p WHERE p.doc_id = d.doc_id), 0)::numeric(18,2) AS paid_before,
           d.currency::char(3) AS currency
    FROM core.sales_docs d JOIN core.clients c ON c.client_id = d.client_id
    WHERE NOT d.is_intragroup
) x WHERE x.amount - x.paid_before > 0;

-- ===================== mart_sales =====================

-- plan-fact: факты из единых показателей (дневные, аддитивные). Строку company/all даёт адаптер.
CREATE OR REPLACE VIEW mart_sales.src_pf_facts AS
SELECT 'revenue'::text AS metric_id, day AS period, 'category'::text AS dimension_type,
       service_line AS dimension_value, value::numeric AS value
FROM metrics.revenue_daily
UNION ALL
SELECT 'revenue', day, 'company', 'all', sum(value) FROM metrics.revenue_daily GROUP BY day
UNION ALL
SELECT 'enrollments', day, 'company', 'all', value FROM metrics.enrollments_daily
UNION ALL
SELECT 'lead', day, 'company', 'all', value FROM metrics.lead_daily;
