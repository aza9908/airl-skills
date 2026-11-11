-- Демо-источники: номенклатура закупок, поставщики, остатки, расход и оплаты
-- синтетической кофейной компании (обжарочный цех и РЦ Алматы). Только для разработки
-- и показа. В работе src_pur_* заменяет адаптер /airl-dwh или /airl-connect (обычно 1С).

CREATE TABLE IF NOT EXISTS demo_pur_items (
    sku      text PRIMARY KEY,
    sku_name text    NOT NULL,
    unit     text    NOT NULL,
    category text    NOT NULL,
    stocked  boolean NOT NULL
);

INSERT INTO demo_pur_items VALUES
 ('GR-ETH-SID',   'Зелёное зерно Эфиопия Сидамо',   'кг', 'green_coffee', true),
 ('GR-BRA-CER',   'Зелёное зерно Бразилия Серрадо', 'кг', 'green_coffee', true),
 ('GR-COL-HUI',   'Зелёное зерно Колумбия Уила',    'кг', 'green_coffee', true),
 ('PK-VALVE-250', 'Пакет с клапаном 250 г',         'шт', 'packaging',    true),
 ('PK-BOX-12',    'Гофрокороб на 12 пачек',         'шт', 'packaging',    true),
 ('SY-VAN-1L',    'Сироп ваниль 1 л',               'шт', 'goods',        true),
 ('SP-GASKET-58', 'Уплотнитель группы 58 мм',       'шт', 'spare_parts',  true),
 ('EQ-GRINDER',   'Кофемолка для кофейни клиента',  'шт', 'equipment',    false),
 ('SV-ROASTER-TO','ТО ростера (услуга)',            'усл','services',     false)
ON CONFLICT (sku) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_pur_suppliers (
    supplier_id   text PRIMARY KEY,
    supplier_name text    NOT NULL,
    tax_id        text,
    country       text,
    currency      char(3) NOT NULL,
    active        boolean NOT NULL
);

INSERT INTO demo_pur_suppliers VALUES
 ('SUP-01', 'Green Bean Trading LLP', '190440012345', 'KZ', 'USD', true),
 ('SUP-02', 'ТОО «Кофе Трейд»',       '170840023456', 'KZ', 'KZT', true),
 ('SUP-03', 'ТОО «ПакСервис»',        '150540034567', 'KZ', 'KZT', true),
 ('SUP-04', 'ТОО «Упаковка Азия»',    '200140045678', 'KZ', 'KZT', true),
 ('SUP-05', 'ТОО «Сироп Азия»',       '180340056789', 'KZ', 'KZT', true),
 ('SUP-06', 'ИП «Технос»',            '880101300123', 'KZ', 'KZT', true)
ON CONFLICT (supplier_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_pur_stock (
    sku          text          NOT NULL,
    warehouse_id text          NOT NULL,
    qty          numeric(18,3) NOT NULL,
    updated_at   timestamptz   NOT NULL,
    PRIMARY KEY (sku, warehouse_id)
);

INSERT INTO demo_pur_stock VALUES
 ('GR-ETH-SID',   'ROAST',   180, now() - interval '2 hours'),
 ('GR-BRA-CER',   'ROAST',  1350, now() - interval '2 hours'),
 ('GR-COL-HUI',   'ROAST',   260, now() - interval '2 hours'),
 ('PK-VALVE-250', 'ROAST',  3200, now() - interval '2 hours'),
 ('PK-BOX-12',    'ROAST',    60, now() - interval '2 hours'),
 ('SY-VAN-1L',    'RC-ALA',   84, now() - interval '2 hours'),
 ('SP-GASKET-58', 'RC-ALA',    3, now() - interval '2 hours')
ON CONFLICT (sku, warehouse_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_pur_consumption (
    sku          text          NOT NULL,
    warehouse_id text          NOT NULL,
    day          date          NOT NULL,
    qty_out      numeric(18,3) NOT NULL,
    PRIMARY KEY (sku, warehouse_id, day)
);

-- Расход за 90 дней: зерно — списание в обжарку, упаковка — в фасовку, сироп — продажи.
INSERT INTO demo_pur_consumption (sku, warehouse_id, day, qty_out)
SELECT p.sku, p.wh, d::date,
       greatest(0, round(p.base * (0.6 + 0.8 * ((abs(hashtext(p.sku || d::text)) % 100) / 100.0)), 0))
FROM (VALUES ('GR-ETH-SID',   'ROAST',  15.0),
             ('GR-BRA-CER',   'ROAST',  40.0),
             ('GR-COL-HUI',   'ROAST',  12.0),
             ('PK-VALVE-250', 'ROAST',  60.0),
             ('PK-BOX-12',    'ROAST',   8.0),
             ('SY-VAN-1L',    'RC-ALA',  3.0),
             ('SP-GASKET-58', 'RC-ALA',  0.2)) AS p(sku, wh, base)
CROSS JOIN generate_series(current_date - 90, current_date - 1, interval '1 day') AS d
WHERE extract(isodow FROM d) <> 7
ON CONFLICT (sku, warehouse_id, day) DO NOTHING;

-- Оплаты поставщикам из 1С (по номеру заказа поставщику из модуля).
CREATE TABLE IF NOT EXISTS demo_pur_payments (
    payment_id text PRIMARY KEY,
    po_no      text          NOT NULL,
    amount     numeric(18,2) NOT NULL,
    currency   char(3)       NOT NULL,
    paid_at    timestamptz   NOT NULL
);

INSERT INTO demo_pur_payments VALUES
 ('PAY-7001', 'PO-000001', 8160.00,    'USD', now() - interval '40 days'),
 ('PAY-7002', 'PO-000002', 380000.00,  'KZT', now() - interval '20 days'),
 ('PAY-7003', 'PO-000003', 120000.00,  'KZT', now() - interval '5 days')
ON CONFLICT (payment_id) DO NOTHING;

CREATE OR REPLACE VIEW src_pur_items AS
SELECT sku, sku_name, unit, category, stocked FROM demo_pur_items;

CREATE OR REPLACE VIEW src_pur_suppliers AS
SELECT supplier_id, supplier_name, tax_id, country, currency, active FROM demo_pur_suppliers;

CREATE OR REPLACE VIEW src_pur_stock AS
SELECT sku, warehouse_id, qty, updated_at FROM demo_pur_stock;

CREATE OR REPLACE VIEW src_pur_consumption AS
SELECT sku, warehouse_id, day, qty_out FROM demo_pur_consumption;

CREATE OR REPLACE VIEW src_pur_payments AS
SELECT payment_id, po_no, amount, currency, paid_at FROM demo_pur_payments;
