-- Демо-источники: справочник товаров, подтверждённые заказы и остатки 1С синтетической
-- кофейной компании (РЦ Алматы, обжарочный цех). Только для разработки и показа.
-- В работе src_pick_* заменяет адаптер /airl-dwh или /airl-connect (обычно поверх 1С).

CREATE TABLE IF NOT EXISTS demo_pick_items (
    sku             text PRIMARY KEY,
    sku_name        text          NOT NULL,
    unit            text          NOT NULL,
    barcode         text,
    kind            text          NOT NULL,
    track_lots      boolean       NOT NULL,
    shelf_life_days int,
    unit_cost       numeric(18,2)
);

INSERT INTO demo_pick_items VALUES
 ('CF-ESP-1KG',   'STEP Espresso Blend 1 кг',              'шт', '4870001000011', 'packed',    true,  180, 9800.00),
 ('CF-ETH-250',   'Эфиопия Сидамо 250 г',                  'шт', '4870001000028', 'packed',    true,  180, 3900.00),
 ('CF-COL-250',   'Колумбия Уила 250 г',                   'шт', '4870001000035', 'packed',    true,  180, 3600.00),
 ('SY-VAN-1L',    'Сироп ваниль 1 л',                      'шт', '4870001000042', 'goods',     true,  365, 2400.00),
 ('ML-OAT-1L',    'Овсяное молоко 1 л',                    'шт', '4870001000059', 'goods',     true,  270, 1350.00),
 ('PK-VALVE-250', 'Пакет с клапаном 250 г',                'шт', '4870001000066', 'packaging', false, NULL,  65.00),
 ('GR-ETH-SID',   'Зелёное зерно Эфиопия Сидамо',          'кг', NULL,            'green',     true,  730, 4700.00),
 ('RS-ETH-SID',   'Обжаренное зерно Эфиопия Сидамо, без упаковки', 'кг', NULL,    'roast',     true,   30, NULL)
ON CONFLICT (sku) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_pick_orders (
    order_id     text PRIMARY KEY,
    order_no     text        NOT NULL,
    client_id    text        NOT NULL,
    client_name  text        NOT NULL,
    warehouse_id text        NOT NULL,
    confirmed_at timestamptz NOT NULL,
    ship_by      timestamptz NOT NULL,
    status       text        NOT NULL
);

INSERT INTO demo_pick_orders VALUES
 ('O-24101', 'ЗК-24101', 'CL-001', 'Кофейня «Достык»',        'RC-ALA', now() - interval '20 days', now() - interval '19 days', 'confirmed'),
 ('O-24102', 'ЗК-24102', 'CL-002', 'Ресторан «Самал»',        'RC-ALA', now() - interval '13 days', now() - interval '12 days', 'confirmed'),
 ('O-24103', 'ЗК-24103', 'CL-003', 'Кофейня «Абай 44»',       'RC-ALA', now() - interval '6 days',  now() - interval '5 days',  'confirmed'),
 ('O-24104', 'ЗК-24104', 'CL-004', 'Офис «Нурлы Тау»',        'RC-ALA', now() - interval '5 days',  now() - interval '4 days',  'confirmed'),
 ('O-24105', 'ЗК-24105', 'CL-001', 'Кофейня «Достык»',        'RC-ALA', now() - interval '2 days',  now() - interval '1 day',   'confirmed'),
 ('O-24106', 'ЗК-24106', 'CL-005', 'Отель «Медеу»',           'RC-ALA', now() - interval '5 hours', now() + interval '3 hours', 'confirmed'),
 ('O-24107', 'ЗК-24107', 'CL-006', 'Кофейня «Есиль» (Астана)', 'RC-ALA', now() - interval '3 hours', now() + interval '20 hours', 'confirmed'),
 ('O-24108', 'ЗК-24108', 'CL-002', 'Ресторан «Самал»',        'RC-ALA', now() - interval '2 hours', now() + interval '1 day',   'cancelled')
ON CONFLICT (order_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_pick_order_lines (
    order_id text          NOT NULL,
    line_no  int           NOT NULL,
    sku      text          NOT NULL,
    qty      numeric(18,3) NOT NULL,
    PRIMARY KEY (order_id, line_no)
);

INSERT INTO demo_pick_order_lines VALUES
 ('O-24101', 1, 'CF-ESP-1KG', 10), ('O-24101', 2, 'SY-VAN-1L', 6),
 ('O-24102', 1, 'CF-ETH-250', 12), ('O-24102', 2, 'ML-OAT-1L', 4),
 ('O-24103', 1, 'CF-ESP-1KG', 6),  ('O-24103', 2, 'CF-COL-250', 5), ('O-24103', 3, 'SY-VAN-1L', 2),
 ('O-24104', 1, 'CF-ETH-250', 8),  ('O-24104', 2, 'PK-VALVE-250', 50),
 ('O-24105', 1, 'CF-ESP-1KG', 4),  ('O-24105', 2, 'ML-OAT-1L', 6),
 ('O-24106', 1, 'CF-ETH-250', 10), ('O-24106', 2, 'SY-VAN-1L', 3),
 ('O-24107', 1, 'CF-ESP-1KG', 8),  ('O-24107', 2, 'CF-COL-250', 4),
 ('O-24108', 1, 'CF-ETH-250', 5)
ON CONFLICT (order_id, line_no) DO NOTHING;

-- Остатки 1С по складу и партии — для сверки с движениями модуля.
CREATE TABLE IF NOT EXISTS demo_pick_stock_1c (
    sku          text          NOT NULL,
    warehouse_id text          NOT NULL,
    lot_no       text          NOT NULL DEFAULT '',
    qty          numeric(18,3) NOT NULL,
    updated_at   timestamptz   NOT NULL,
    PRIMARY KEY (sku, warehouse_id, lot_no)
);

INSERT INTO demo_pick_stock_1c VALUES
 ('CF-ESP-1KG', 'RC-ALA', 'PR-1001',  140, now() - interval '1 hour'),
 ('CF-ESP-1KG', 'RC-ALA', 'PR-1002',   40, now() - interval '1 hour'),
 ('CF-ETH-250', 'RC-ALA', 'PR-0995',   30, now() - interval '1 hour'),
 ('CF-ETH-250', 'RC-ALA', 'PR-1003P',  40, now() - interval '1 hour'),
 ('CF-COL-250', 'RC-ALA', 'PR-1004',   36, now() - interval '1 hour'),
 ('SY-VAN-1L',  'RC-ALA', 'SV-0611',   16, now() - interval '1 hour'),
 ('SY-VAN-1L',  'RC-ALA', 'SV-0815',   60, now() - interval '1 hour'),
 ('ML-OAT-1L',  'RC-ALA', 'MO-1020',   24, now() - interval '1 hour'),
 ('ML-OAT-1L',  'RC-ALA', 'MO-0930',    6, now() - interval '1 hour'),
 ('PK-VALVE-250','RC-ALA', '',        3000, now() - interval '1 hour'),
 ('GR-ETH-SID', 'ROAST',  'GL-24-017', 168, now() - interval '1 hour')
ON CONFLICT (sku, warehouse_id, lot_no) DO NOTHING;

CREATE OR REPLACE VIEW src_pick_items AS
SELECT sku, sku_name, unit, barcode, kind, track_lots, shelf_life_days, unit_cost
FROM demo_pick_items;

CREATE OR REPLACE VIEW src_pick_orders AS
SELECT order_id, order_no, client_id, client_name, warehouse_id, confirmed_at, ship_by, status
FROM demo_pick_orders;

CREATE OR REPLACE VIEW src_pick_order_lines AS
SELECT order_id, line_no, sku, qty
FROM demo_pick_order_lines;

CREATE OR REPLACE VIEW src_pick_stock_1c AS
SELECT sku, warehouse_id, NULLIF(lot_no, '') AS lot_no, qty, updated_at
FROM demo_pick_stock_1c;
