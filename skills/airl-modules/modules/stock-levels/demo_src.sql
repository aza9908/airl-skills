-- Демо-источники: синтетические остатки и продажи кофейной компании (РЦ Алматы,
-- ТК Астана, обжарочный цех). Только для разработки и показа.
-- В работе src_stock и src_sales_daily заменяет адаптер /airl-dwh или /airl-connect
-- (обычно поверх остатков и реализации из 1С).

CREATE TABLE IF NOT EXISTS demo_stk_stock (
    row_key      text PRIMARY KEY,
    sku          text           NOT NULL,
    sku_name     text           NOT NULL,
    warehouse_id text           NOT NULL,
    qty          numeric(18,3)  NOT NULL,
    unit         text           NOT NULL,
    batch        text,
    expiry_date  date,
    unit_cost    numeric(18,2),
    currency     char(3),
    updated_at   timestamptz    NOT NULL
);

INSERT INTO demo_stk_stock
SELECT v.sku || '|' || v.wh || '|' || coalesce(v.batch, '-'), v.sku, v.name, v.wh, v.qty, v.unit, v.batch,
       CASE WHEN v.exp_days IS NULL THEN NULL ELSE current_date + v.exp_days END,
       v.cost, 'KZT', now() - interval '2 hours'
FROM (VALUES
 ('CF-ESP-1KG',  'STEP Espresso Blend 1 кг',        'RC-ALA', 'PR-1001', 160::numeric, 'шт', 150, 9800.00),
 ('CF-ESP-1KG',  'STEP Espresso Blend 1 кг',        'RC-ALA', 'PR-1002',  40,          'шт', 170, 9800.00),
 ('CF-ESP-1KG',  'STEP Espresso Blend 1 кг',        'TK-AST', 'PR-0990',  18,          'шт', 120, 9800.00),
 ('CF-ETH-250',  'Эфиопия Сидамо 250 г',            'RC-ALA', 'PR-1003',  95,          'шт', 160, 3900.00),
 ('CF-ETH-250',  'Эфиопия Сидамо 250 г',            'TK-AST', 'PR-0995',  70,          'шт', 140, 3900.00),
 ('CF-COL-250',  'Колумбия Уила 250 г',             'RC-ALA', 'PR-1004',  12,          'шт', 165, 3600.00),
 ('CF-DEC-250',  'Декаф Колумбия 250 г',            'RC-ALA', 'PR-0950',  85,          'шт',  60, 4100.00),
 ('GR-BRA-CER',  'Зелёное зерно Бразилия Серрадо',  'ROAST',  'GL-24-021', 1350,       'кг', NULL, 2900.00),
 ('GR-ETH-SID',  'Зелёное зерно Эфиопия Сидамо',    'ROAST',  'GL-24-017', 180,        'кг', NULL, 4700.00),
 ('PK-VALVE-250','Пакет с клапаном 250 г',          'ROAST',  NULL,        3200,       'шт', NULL,   65.00),
 ('SY-VAN-1L',   'Сироп ваниль 1 л',                'RC-ALA', 'SV-0611',   24,         'шт',  21, 2400.00),
 ('SY-VAN-1L',   'Сироп ваниль 1 л',                'RC-ALA', 'SV-0815',   60,         'шт', 140, 2400.00),
 ('SY-LAV-1L',   'Сироп лаванда 1 л',               'RC-ALA', 'SL-0402',   38,         'шт',  25, 2600.00),
 ('ML-OAT-1L',   'Овсяное молоко 1 л',              'RC-ALA', 'MO-1020',   30,         'шт',   9, 1350.00),
 ('ML-OAT-1L',   'Овсяное молоко 1 л',              'RC-ALA', 'MO-0930',    6,         'шт',  -3, 1350.00),
 ('MG-STEP-350', 'Кружка STEP 350 мл',              'TK-AST', NULL,        140,        'шт', NULL, 1900.00)
) AS v(sku, name, wh, batch, qty, unit, exp_days, cost)
ON CONFLICT (row_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_stk_sales (
    sku          text          NOT NULL,
    warehouse_id text          NOT NULL,
    day          date          NOT NULL,
    qty_out      numeric(18,3) NOT NULL,
    PRIMARY KEY (sku, warehouse_id, day)
);

-- Продажи и расход за 120 дней. stop_days — сколько дней назад позиция перестала продаваться.
INSERT INTO demo_stk_sales (sku, warehouse_id, day, qty_out)
SELECT p.sku, p.wh, d::date,
       round(p.base * (0.8 + 0.2 * (extract(dow FROM d)::int % 3)), 0)
FROM (VALUES
 ('CF-ESP-1KG',   'RC-ALA', 12.0, 0),
 ('CF-ESP-1KG',   'TK-AST',  5.0, 0),
 ('CF-ETH-250',   'RC-ALA',  7.0, 0),
 ('CF-ETH-250',   'TK-AST',  2.0, 0),
 ('CF-COL-250',   'RC-ALA',  4.0, 0),
 ('CF-DEC-250',   'RC-ALA',  1.0, 0),
 ('GR-BRA-CER',   'ROAST',  40.0, 0),
 ('GR-ETH-SID',   'ROAST',  15.0, 0),
 ('PK-VALVE-250', 'ROAST',  60.0, 0),
 ('SY-VAN-1L',    'RC-ALA',  3.0, 0),
 ('SY-LAV-1L',    'RC-ALA',  2.0, 75),
 ('ML-OAT-1L',    'RC-ALA',  4.0, 0),
 ('MG-STEP-350',  'TK-AST',  1.0, 110)
) AS p(sku, wh, base, stop_days)
CROSS JOIN generate_series(current_date - 120, current_date - 1, interval '1 day') AS d
WHERE d::date < current_date - p.stop_days
ON CONFLICT (sku, warehouse_id, day) DO NOTHING;

CREATE OR REPLACE VIEW src_stock AS
SELECT sku, sku_name, warehouse_id, qty, unit, batch, expiry_date, unit_cost, currency, updated_at
FROM demo_stk_stock;

CREATE OR REPLACE VIEW src_sales_daily AS
SELECT sku, warehouse_id, day, qty_out
FROM demo_stk_sales;
