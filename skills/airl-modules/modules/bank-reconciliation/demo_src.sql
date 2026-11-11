-- Демо-источники для модуля «Сверка банковской выписки»: строки выписок и открытые
-- документы (счета покупателям, заявки на оплату поставщикам). Синтетика, только для
-- разработки и показа. В работе src_bank_statement_lines заполняет адаптер, который
-- разбирает файлы выписок (1CClientBankExchange, CSV Kaspi/Halyk, MT940), а
-- src_bank_open_items — адаптер /airl-dwh или /airl-connect поверх 1С.

CREATE TABLE IF NOT EXISTS demo_bank_lines (
    line_id             text PRIMARY KEY,
    statement_id        text          NOT NULL,
    bank                text          NOT NULL,
    account             text          NOT NULL,
    value_date          date          NOT NULL,
    amount              numeric(18,2) NOT NULL,
    currency            char(3)       NOT NULL,
    counterparty_name   text,
    counterparty_tax_id text,
    purpose             text,
    doc_no              text
);

CREATE TABLE IF NOT EXISTS demo_bank_open_items (
    item_id             text PRIMARY KEY,
    item_type           text          NOT NULL,
    direction           text          NOT NULL,
    counterparty_tax_id text,
    counterparty_name   text,
    doc_no              text          NOT NULL,
    doc_date            date          NOT NULL,
    amount              numeric(18,2) NOT NULL,
    paid_before         numeric(18,2) NOT NULL DEFAULT 0,
    currency            char(3)       NOT NULL
);

-- Шесть постоянных покупателей (кофейни, HoReCa).
CREATE OR REPLACE VIEW demo_bank_customers AS
SELECT * FROM (VALUES
 (0, '180340012345', 'ТОО «Кофейня Арабика»'),
 (1, '190440023456', 'ТОО «Бариста Хаус»'),
 (2, '200540034567', 'ТОО «Утро Кофе Астана»'),
 (3, '170640045678', 'ТОО «Ресторан Достар»'),
 (4, '160740056789', 'ИП «Кофе с собой»'),
 (5, '150840067890', 'ТОО «Отель Нурлы»')) AS c(n, tax_id, name);

-- Обычный поток: 40 счетов покупателям за последние ~70 дней, 36 из них оплачены.
-- Каждый 5-й платёж без номера счёта в назначении, каждый 7-й — без БИН (перевод Kaspi).
INSERT INTO demo_bank_open_items
SELECT 'INV-' || (2000 + i), 'invoice', 'in', c.tax_id, c.name, 'СФ-' || (2000 + i),
       current_date - 70 + i, 50000 + ((i * 37) % 20) * 25000, 0, 'KZT'
FROM generate_series(1, 40) i
JOIN demo_bank_customers c ON c.n = i % 6
ON CONFLICT (item_id) DO NOTHING;

INSERT INTO demo_bank_lines
SELECT 'KSP-' || to_char(d, 'YYYYMMDD') || '-' || lpad(i::text, 3, '0'),
       'KASPI-' || to_char(d, 'YYYYMMDD'), 'Kaspi Business', 'KZ86722S000012345678', d,
       50000 + ((i * 37) % 20) * 25000, 'KZT',
       CASE WHEN i % 7 = 0 THEN 'Физ. лицо (Kaspi перевод)' ELSE c.name END,
       CASE WHEN i % 7 = 0 THEN NULL ELSE c.tax_id END,
       CASE WHEN i % 5 = 0 THEN 'Оплата за кофе по договору поставки'
            ELSE 'Оплата по счету на оплату № СФ-' || (2000 + i) || ' от '
                 || to_char(current_date - 70 + i, 'DD.MM.YYYY') || ', в т.ч. НДС 12%' END,
       NULL
FROM generate_series(1, 40) i
JOIN demo_bank_customers c ON c.n = i % 6
CROSS JOIN LATERAL (SELECT current_date - 67 + i + (i % 5) AS d) x
WHERE i % 9 <> 0
ON CONFLICT (line_id) DO NOTHING;

-- Отдельные случаи для показа и проверки.
INSERT INTO demo_bank_open_items VALUES
 ('INV-3001', 'invoice',         'in',  '180340012345', 'ТОО «Кофейня Арабика»', 'СФ-3001',       current_date - 9,  800000.00, 0,        'KZT'),
 ('INV-3002', 'invoice',         'in',  '180340012345', 'ТОО «Кофейня Арабика»', 'СФ-3002',       current_date - 8,  450000.00, 0,        'KZT'),
 ('INV-3010', 'invoice',         'in',  '190440023456', 'ТОО «Бариста Хаус»',    'СФ-3010',       current_date - 12, 900000.00, 0,        'KZT'),
 ('INV-3020', 'invoice',         'in',  '200540034567', 'ТОО «Утро Кофе Астана»', 'СФ-3020',      current_date - 10, 150000.00, 0,        'KZT'),
 ('INV-3021', 'invoice',         'in',  '200540034567', 'ТОО «Утро Кофе Астана»', 'СФ-3021',      current_date - 6,  150000.00, 0,        'KZT'),
 ('INV-3030', 'invoice',         'in',  '170640045678', 'ТОО «Ресторан Достар»',  'СФ-3030',      current_date - 20, 600000.00, 200000.00, 'KZT'),
 ('ORD-5501', 'order',           'in',  '160740056789', 'ИП «Кофе с собой»',      'ЗК-5501',      current_date - 3,  95000.00,  0,        'KZT'),
 ('PR-0002',  'payment_request', 'out', '170440011111', 'ТОО «ПакЛайн Алматы»',   'Счёт 552',     current_date - 6,  1850000.00, 0,       'KZT'),
 ('PR-0004',  'payment_request', 'out', NULL,           'Green Coffee Trading B.V.', 'GCT-2026-07', current_date - 7, 19200.00, 0,        'USD'),
 ('PR-0010',  'payment_request', 'out', '850101300444', 'ИП «Наружка Абая»',      'Договор 17',   current_date - 15, 550000.00, 0,        'KZT')
ON CONFLICT (item_id) DO NOTHING;

INSERT INTO demo_bank_lines VALUES
 -- одна оплата за два счёта (разбивка)
 ('HAL-' || to_char(current_date - 2, 'YYYYMMDD') || '-001', 'HALYK-' || to_char(current_date - 2, 'YYYYMMDD'), 'Halyk Bank', 'KZ49601A871000123456',
  current_date - 2, 1250000.00, 'KZT', 'ТОО «Кофейня Арабика»', '180340012345', 'Оплата по счетам СФ-3001, СФ-3002 за кофе', NULL),
 -- частичная оплата
 ('HAL-' || to_char(current_date - 3, 'YYYYMMDD') || '-002', 'HALYK-' || to_char(current_date - 3, 'YYYYMMDD'), 'Halyk Bank', 'KZ49601A871000123456',
  current_date - 3, 300000.00, 'KZT', 'ТОО «Бариста Хаус»', '190440023456', 'Частичная оплата по счету СФ-3010', NULL),
 -- два счёта на одинаковую сумму, в назначении нет номера — неоднозначно
 ('HAL-' || to_char(current_date - 1, 'YYYYMMDD') || '-003', 'HALYK-' || to_char(current_date - 1, 'YYYYMMDD'), 'Halyk Bank', 'KZ49601A871000123456',
  current_date - 1, 150000.00, 'KZT', 'ТОО «Утро Кофе Астана»', '200540034567', 'Оплата за поставку кофе', NULL),
 -- остаток по счёту, часть которого оплатили до запуска модуля
 ('HAL-' || to_char(current_date - 4, 'YYYYMMDD') || '-004', 'HALYK-' || to_char(current_date - 4, 'YYYYMMDD'), 'Halyk Bank', 'KZ49601A871000123456',
  current_date - 4, 400000.00, 'KZT', 'ТОО «Ресторан Достар»', '170640045678', 'Доплата по сч. СФ-3030', NULL),
 -- исходящий платёж поставщику по заявке
 ('HAL-' || to_char(current_date - 2, 'YYYYMMDD') || '-005', 'HALYK-' || to_char(current_date - 2, 'YYYYMMDD'), 'Halyk Bank', 'KZ49601A871000123456',
  current_date - 2, -1850000.00, 'KZT', 'ТОО «ПакЛайн Алматы»', '170440011111', 'Оплата по счету 552 (заявка ЗР-0002) за дой-пак 1 кг', '000412'),
 -- валютный платёж поставщику зерна (БИН нет — иностранная компания)
 ('HAL-' || to_char(current_date - 5, 'YYYYMMDD') || '-006', 'HALYK-USD-' || to_char(current_date - 5, 'YYYYMMDD'), 'Halyk Bank', 'KZ11601A871000654321',
  current_date - 5, -19200.00, 'USD', 'Green Coffee Trading B.V.', NULL, 'Payment under contract GCT-2026-07, green coffee Brazil', 'SWIFT-77'),
 -- комиссия банка — сопоставлять не с чем
 ('HAL-' || to_char(current_date - 2, 'YYYYMMDD') || '-007', 'HALYK-' || to_char(current_date - 2, 'YYYYMMDD'), 'Halyk Bank', 'KZ49601A871000123456',
  current_date - 2, -1500.00, 'KZT', 'АО «Народный Банк Казахстана»', '940140000385', 'Комиссия за обслуживание счета', NULL),
 -- неизвестное поступление
 ('KSP-' || to_char(current_date - 6, 'YYYYMMDD') || '-901', 'KASPI-' || to_char(current_date - 6, 'YYYYMMDD'), 'Kaspi Business', 'KZ86722S000012345678',
  current_date - 6, 75000.00, 'KZT', 'Физ. лицо (Kaspi перевод)', NULL, 'Оплата', NULL),
 -- оплата заказа без счёта: номер заказа в назначении
 ('KSP-' || to_char(current_date - 1, 'YYYYMMDD') || '-902', 'KASPI-' || to_char(current_date - 1, 'YYYYMMDD'), 'Kaspi Business', 'KZ86722S000012345678',
  current_date - 1, 95000.00, 'KZT', 'ИП «Кофе с собой»', '160740056789', 'Предоплата по заказу ЗК-5501', NULL)
ON CONFLICT (line_id) DO NOTHING;

CREATE OR REPLACE VIEW src_bank_statement_lines AS
SELECT statement_id, bank, account, line_id, value_date, amount, currency,
       counterparty_name, counterparty_tax_id, purpose, doc_no
FROM demo_bank_lines;

CREATE OR REPLACE VIEW src_bank_open_items AS
SELECT item_id, item_type, direction, counterparty_tax_id, counterparty_name,
       doc_no, doc_date, amount, paid_before, currency
FROM demo_bank_open_items;
