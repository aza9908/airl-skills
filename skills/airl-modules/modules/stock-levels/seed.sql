-- Синтетические записи модуля для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('stock-levels', 'sales_window_days',   '60',    'demo'),
 ('stock-levels', 'lead_time_days',      '14',    'demo'),
 ('stock-levels', 'safety_days',         '7',     'demo'),
 ('stock-levels', 'order_cycle_days',    '14',    'demo'),
 ('stock-levels', 'slow_days',           '60',    'demo'),
 ('stock-levels', 'expiry_warn_days',    '30',    'demo'),
 ('stock-levels', 'cover_high_days',     '90',    'demo'),
 ('stock-levels', 'deficit_warn',        '1',     'demo'),
 ('stock-levels', 'deficit_bad',         '5',     'demo'),
 ('stock-levels', 'slow_share_warn',     '10',    'demo'),
 ('stock-levels', 'slow_share_bad',      '20',    'demo'),
 ('stock-levels', 'dismiss_snooze_days', '7',     'demo'),
 ('stock-levels', 'currency',            '"KZT"', 'demo')
ON CONFLICT (module, key) DO NOTHING;

-- Обжаренный кофе делаем сами: срок пополнения 3 дня. Пакеты везут из Китая: 45 дней, кратно 1000.
INSERT INTO stk_limits (sku, warehouse_id, min_qty, max_qty, lead_time_days, safety_days, order_multiple, note, created_by)
VALUES
 ('CF-ESP-1KG',   'RC-ALA', NULL, NULL,  3, 4, NULL,  'обжарка своя, 3 дня',             'demo'),
 ('CF-ESP-1KG',   'TK-AST', NULL, NULL,  5, 4, NULL,  'обжарка + перевозка в Астану',    'demo'),
 ('CF-ETH-250',   'RC-ALA', NULL, NULL,  3, 4, NULL,  NULL,                              'demo'),
 ('CF-COL-250',   'RC-ALA', NULL, NULL,  3, 4, NULL,  NULL,                              'demo'),
 ('PK-VALVE-250', 'ROAST',  NULL, NULL, 45, 15, 1000, 'поставщик в Китае, партия от 1000', 'demo'),
 ('GR-ETH-SID',   'ROAST',  300,  1500, 60, 14, 60,   'мешки по 60 кг',                   'demo')
ON CONFLICT (sku, warehouse_id) DO NOTHING;

INSERT INTO stk_discrepancies (doc_no, sku, warehouse_id, batch, system_qty, counted_qty, reason,
                               responsible, comment, status, resolution, counted_at, counted_by, created_by)
VALUES
 ('INV-0001', 'CF-ETH-250', 'RC-ALA', 'PR-1003', 100, 95, 'pick_error', 'picker_2',
  'Отгрузили 5 шт. вместо Колумбии', 'resolved', 'Исправлено в 1С, реализация №4512', now() - interval '12 days', 'wh_lead', 'wh_lead'),
 ('INV-0002', 'SY-VAN-1L', 'RC-ALA', 'SV-0611', 26, 24, 'damage', 'picker_1',
  'Две бутылки разбиты при приёмке', 'open', NULL, now() - interval '4 days', 'wh_lead', 'wh_lead'),
 ('INV-0003', 'PK-VALVE-250', 'ROAST', NULL, 3000, 3200, 'receipt_error', 'storekeeper',
  'Приход 200 шт. не проведён', 'open', NULL, now() - interval '2 days', 'wh_lead', 'wh_lead'),
 ('INV-0004', 'MG-LOGO-350', 'TK-AST', NULL, 143, 140, 'unknown', NULL,
  'Причина не найдена, пересчитать ещё раз', 'open', NULL, now() - interval '1 day', 'wh_ast', 'wh_ast')
ON CONFLICT (doc_no) DO NOTHING;

DO $$ BEGIN PERFORM stk_generate_suggestions('demo'); END $$;
