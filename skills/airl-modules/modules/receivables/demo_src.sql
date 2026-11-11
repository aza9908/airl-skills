-- Демо-источники для модуля «Дебиторка»: клиенты и документы реализации.
-- Синтетика, только для разработки и показа. В работе src_clients и
-- src_receivables_docs заменяет адаптер /airl-dwh (1С: реализации и оплаты) или /airl-connect.

CREATE TABLE IF NOT EXISTS demo_rcv_clients (
    client_id          text PRIMARY KEY,
    client_name        text NOT NULL,
    credit_limit       numeric(18,2),
    payment_terms_days int,
    manager_id         text,
    is_aggregator      boolean NOT NULL DEFAULT false
);

INSERT INTO demo_rcv_clients VALUES
 ('CL-001', 'Кофейня «Зерно», Алматы',               3000000, 14,   'm_aidana', false),
 ('CL-002', 'Сеть кофеен «Daily Cup»',               8000000, 30,   'm_aidana', false),
 ('CL-003', 'Ресторан «Тюбетей», Алматы',            2000000, 14,   'm_ruslan', false),
 ('CL-004', 'Отель «Достар», Астана',                5000000, 30,   'm_dana',   false),
 ('CL-005', 'Кофейня «Бариста-бар», Астана',         1500000, 7,    'm_dana',   false),
 ('CL-006', 'ТОО «Офис-Сервис» (кофе в офисы)',      2500000, 21,   'm_timur',  false),
 ('CL-007', 'Пекарня «Бауырсак»',                    1000000, 14,   'm_ruslan', false),
 ('CL-008', 'Кофейня «Утро», Астана',                NULL,    NULL, 'm_timur',  false),
 ('CL-009', 'Kaspi Магазин',                         NULL,    10,   'm_aidana', true),
 ('CL-010', 'Кофейня «Lounge 24», Астана',           1200000, 14,   'm_dana',   false),
 ('CL-011', 'Кейтеринг «Той-Той»',                   3000000, 30,   'm_ruslan', false),
 ('CL-012', 'Halyk Market',                          NULL,    10,   'm_timur',  true)
ON CONFLICT (client_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_rcv_docs (
    doc_no      text PRIMARY KEY,
    client_id   text NOT NULL,
    client_name text NOT NULL,
    doc_date    date NOT NULL,
    due_date    date,
    amount      numeric(18,2) NOT NULL,
    paid_amount numeric(18,2) NOT NULL DEFAULT 0,
    currency    char(3) NOT NULL,
    manager_id  text,
    branch_id   text
);

-- days_ago — дата документа, due_in — отсрочка в днях (NULL — срок оплаты не указан).
-- КР-… — возврат (корректировка реализации) с минусом.
INSERT INTO demo_rcv_docs (doc_no, client_id, client_name, doc_date, due_date, amount, paid_amount, currency, manager_id, branch_id)
SELECT v.doc_no, v.client_id, COALESCE(c.client_name, v.client_name), current_date - v.days_ago,
       current_date - v.days_ago + v.due_in, v.amount, v.paid, v.currency, COALESCE(c.manager_id, v.manager_id), v.branch_id
FROM (VALUES
 ('РН-1001', 'CL-001', NULL,               50,  14,   600000,  600000, 'KZT', NULL,      'ala'),
 ('РН-1012', 'CL-001', NULL,               25,  14,   480000,  200000, 'KZT', NULL,      'ala'),
 ('РН-1025', 'CL-001', NULL,               5,   14,   520000,       0, 'KZT', NULL,      'ala'),
 ('РН-1003', 'CL-002', NULL,               70,  30,  2400000, 1000000, 'KZT', NULL,      'ala'),
 ('РН-1015', 'CL-002', NULL,               35,  30,  2100000,       0, 'KZT', NULL,      'ala'),
 ('РН-1030', 'CL-002', NULL,               10,  30,  2600000,       0, 'KZT', NULL,      'ala'),
 ('РН-1004', 'CL-003', NULL,               120, 14,   900000,  300000, 'KZT', NULL,      'ala'),
 ('РН-1016', 'CL-003', NULL,               45,  14,   650000,       0, 'KZT', NULL,      'ala'),
 ('КР-0003', 'CL-003', NULL,               30,  NULL, -150000,      0, 'KZT', NULL,      'ala'),
 ('РН-1031', 'CL-003', NULL,               8,   14,   950000,       0, 'KZT', NULL,      'ala'),
 ('РН-1005', 'CL-004', NULL,               40,  30,  1800000, 1800000, 'KZT', NULL,      'ast'),
 ('РН-1018', 'CL-004', NULL,               20,  30,  2200000,  500000, 'KZT', NULL,      'ast'),
 ('РН-1006', 'CL-005', NULL,               75,  7,    420000,  120000, 'KZT', NULL,      'ast'),
 ('РН-1019', 'CL-005', NULL,               20,  7,    380000,       0, 'KZT', NULL,      'ast'),
 ('РН-1007', 'CL-006', NULL,               15,  21,   950000,       0, 'KZT', NULL,      'ala'),
 ('РН-1020', 'CL-006', NULL,               28,  21,   700000,  700000, 'KZT', NULL,      'ala'),
 ('РН-1026', 'CL-006', NULL,               10,  21,   200000,  230000, 'KZT', NULL,      'ala'),
 ('РН-1008', 'CL-007', NULL,               95,  14,   260000,       0, 'KZT', NULL,      'ala'),
 ('РН-1009', 'CL-008', NULL,               20,  NULL,  340000,      0, 'KZT', NULL,      'ast'),
 ('РН-1021', 'CL-008', NULL,               50,  NULL,  280000, 100000, 'KZT', NULL,      'ast'),
 ('РН-1010', 'CL-009', NULL,               12,  NULL, 3500000,      0, 'KZT', NULL,      'ala'),
 ('РН-1022', 'CL-009', NULL,               3,   10,  1800000,       0, 'KZT', NULL,      'ala'),
 ('РН-1011', 'CL-010', NULL,               18,  NULL,  300000,      0, 'KZT', NULL,      'ast'),
 ('РН-1013', 'CL-011', NULL,               60,  30,  1500000,  500000, 'KZT', NULL,      'ala'),
 ('РН-1023', 'CL-011', NULL,               15,  30,  1200000,       0, 'KZT', NULL,      'ala'),
 ('РН-1014', 'CL-012', NULL,               25,  10,   900000,       0, 'KZT', NULL,      'ala'),
 ('РН-1024', 'CL-099', 'ИП «Кофе-точка»',  40,  14,   150000,       0, 'KZT', 'm_timur', 'ast'),
 ('РН-1027', 'CL-004', NULL,               12,  30,     4800,       0, 'USD', NULL,      'ast')
) AS v(doc_no, client_id, client_name, days_ago, due_in, amount, paid, currency, manager_id, branch_id)
LEFT JOIN demo_rcv_clients c ON c.client_id = v.client_id
ON CONFLICT (doc_no) DO NOTHING;

CREATE OR REPLACE VIEW src_clients AS
SELECT client_id, client_name, credit_limit, payment_terms_days, manager_id, is_aggregator
FROM demo_rcv_clients;

CREATE OR REPLACE VIEW src_receivables_docs AS
SELECT client_id, client_name, doc_no, doc_date, due_date, amount, paid_amount, currency, manager_id, branch_id
FROM demo_rcv_docs;
