-- Синтетические данные модуля для разработки и показа: РЦ Алматы и обжарочный цех.
-- Сценарий идёт через функции модуля (те же, что вызывает экран), поэтому seed заодно
-- проверяет правила. Повторный запуск ничего не дублирует.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('picking', 'timezone',                 '"Asia/Almaty"',    'demo'),
 ('picking', 'fefo_strict',              'true',             'demo'),
 ('picking', 'min_days_left',            '0',                'demo'),
 ('picking', 'require_expiry',           'true',             'demo'),
 ('picking', 'allow_unexpected_receipt', 'true',             'demo'),
 ('picking', 'expiry_warn_days',         '30',               'demo'),
 ('picking', 'late_warn_minutes',        '60',               'demo'),
 ('picking', 'head_recipient',           '"warehouse_head"', 'demo'),
 ('picking', 'channel',                  '"telegram"',       'demo'),
 ('picking', 'error_warn',               '0.5',              'demo'),
 ('picking', 'error_bad',                '1.0',              'demo'),
 ('picking', 'lph_warn',                 '40',               'demo'),
 ('picking', 'lph_bad',                  '25',               'demo'),
 ('picking', 'accuracy_warn',            '98',               'demo'),
 ('picking', 'accuracy_bad',             '95',               'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO pick_zones (warehouse_id, code, title, kind, created_by) VALUES
 ('RC-ALA', 'A',    'Стеллажи A',      'storage',   'demo'),
 ('RC-ALA', 'B',    'Стеллажи B',      'storage',   'demo'),
 ('RC-ALA', 'RCV',  'Зона приёмки',    'receiving', 'demo'),
 ('RC-ALA', 'PACK', 'Стол упаковки',   'packing',   'demo'),
 ('RC-ALA', 'Q',    'Карантин',        'quarantine','demo'),
 ('ROAST',  'G',    'Зелёное зерно',   'storage',   'demo'),
 ('ROAST',  'PACK', 'Фасовка',         'packing',   'demo')
ON CONFLICT (warehouse_id, code) DO NOTHING;

INSERT INTO pick_cells (zone_id, code, title, created_by)
SELECT z.id, v.code, v.title, 'demo'
FROM (VALUES ('RC-ALA', 'A',    'ALA-A-01-01', 'ряд 1, полка 1'),
             ('RC-ALA', 'A',    'ALA-A-01-02', 'ряд 1, полка 2'),
             ('RC-ALA', 'A',    'ALA-A-01-03', 'ряд 1, полка 3'),
             ('RC-ALA', 'A',    'ALA-A-02-01', 'ряд 2, полка 1'),
             ('RC-ALA', 'A',    'ALA-A-02-02', 'ряд 2, полка 2'),
             ('RC-ALA', 'B',    'ALA-B-01-01', 'ряд 1, полка 1'),
             ('RC-ALA', 'B',    'ALA-B-01-02', 'ряд 1, полка 2'),
             ('RC-ALA', 'RCV',  'ALA-RCV-01',  NULL),
             ('RC-ALA', 'PACK', 'ALA-PACK-01', NULL),
             ('RC-ALA', 'Q',    'ALA-Q-01',    NULL),
             ('ROAST',  'G',    'RST-G-01',    'мешки, паллет 1'),
             ('ROAST',  'PACK', 'RST-PACK-01', NULL)) AS v(wh, zone, code, title)
JOIN pick_zones z ON z.warehouse_id = v.wh AND z.code = v.zone
ON CONFLICT (code) DO NOTHING;

-- Партии. Цепочка кофе: зелёный лот GL-24-017 → партия обжарки PR-1003 → фасовка PR-1003P.
INSERT INTO pick_lots (sku, lot_no, kind, produced_on, expiry_date, supplier_lot, created_by) VALUES
 ('GR-ETH-SID', 'GL-24-017', 'green',  current_date - 60,  current_date + 500, 'ETH-SID-G2-0417', 'demo'),
 ('RS-ETH-SID', 'PR-1003',   'roast',  current_date - 30,  current_date,       NULL,              'demo'),
 ('CF-ETH-250', 'PR-1003P',  'packed', current_date - 30,  current_date + 150, NULL,              'demo'),
 ('CF-ETH-250', 'PR-0995',   'packed', current_date - 80,  current_date + 100, NULL,              'demo'),
 ('CF-ESP-1KG', 'PR-1001',   'packed', current_date - 30,  current_date + 150, NULL,              'demo'),
 ('CF-ESP-1KG', 'PR-1002',   'packed', current_date - 10,  current_date + 170, NULL,              'demo'),
 ('CF-COL-250', 'PR-1004',   'packed', current_date - 15,  current_date + 165, NULL,              'demo'),
 ('SY-VAN-1L',  'SV-0611',   'goods',  NULL,               current_date + 21,  NULL,              'demo'),
 ('SY-VAN-1L',  'SV-0815',   'goods',  NULL,               current_date + 140, NULL,              'demo'),
 ('ML-OAT-1L',  'MO-1020',   'goods',  NULL,               current_date + 9,   NULL,              'demo'),
 ('ML-OAT-1L',  'MO-0930',   'goods',  NULL,               current_date - 3,   NULL,              'demo')
ON CONFLICT (sku, lot_no) DO NOTHING;

INSERT INTO pick_lot_links (parent_lot_id, child_lot_id, kind, qty, created_by)
SELECT p.id, c.id, v.kind, v.qty, 'demo'
FROM (VALUES ('GR-ETH-SID', 'GL-24-017', 'RS-ETH-SID', 'PR-1003',  'roast', 12.0),
             ('RS-ETH-SID', 'PR-1003',   'CF-ETH-250', 'PR-1003P', 'pack',  10.0)) AS v(ps, pl, cs, cl, kind, qty)
JOIN pick_lots p ON p.sku = v.ps AND p.lot_no = v.pl
JOIN pick_lots c ON c.sku = v.cs AND c.lot_no = v.cl
ON CONFLICT (parent_lot_id, child_lot_id) DO NOTHING;

-- Начальные остатки по ячейкам (ввод остатков при запуске — по пересчёту).
INSERT INTO pick_moves (kind, sku, lot_id, to_cell_id, qty, reason, created_by)
SELECT 'opening', v.sku, l.id, c.id, v.qty, 'ввод остатков', 'demo'
FROM (VALUES ('CF-ESP-1KG', 'PR-1001',   'ALA-A-01-01', 100),
             ('CF-ESP-1KG', 'PR-1001',   'ALA-A-01-02',  40),
             ('CF-ESP-1KG', 'PR-1002',   'ALA-A-02-01',  40),
             ('CF-ETH-250', 'PR-0995',   'ALA-A-01-03',  30),
             ('CF-ETH-250', 'PR-1003P',  'ALA-A-02-02',  40),
             ('CF-COL-250', 'PR-1004',   'ALA-B-01-01',  36),
             ('SY-VAN-1L',  'SV-0611',   'ALA-B-01-02',  16),
             ('SY-VAN-1L',  'SV-0815',   'ALA-B-01-02',  60),
             ('ML-OAT-1L',  'MO-1020',   'ALA-B-01-01',  24),
             ('ML-OAT-1L',  'MO-0930',   'ALA-B-01-02',   6),
             ('PK-VALVE-250', NULL,      'ALA-B-01-01', 3000),
             ('GR-ETH-SID', 'GL-24-017', 'RST-G-01',    180)) AS v(sku, lot_no, cell, qty)
JOIN pick_cells c ON c.code = v.cell
LEFT JOIN pick_lots l ON l.sku = v.sku AND l.lot_no = v.lot_no
WHERE NOT EXISTS (SELECT 1 FROM pick_moves m WHERE m.kind = 'opening');

-- Сценарий: задания из заказов, сборка со сканированием, проверка упаковки, отгрузка,
-- приёмка с недостачей, пересчёт зоны B.
DO $$
DECLARE
    t   record;
    ln  record;
    f   record;
    r   record;
    v_q numeric;
    v_picker text;
    v_id bigint;
    v_cnt bigint;
    v_payload text;
BEGIN
    IF EXISTS (SELECT 1 FROM pick_tasks) THEN RETURN; END IF;
    PERFORM pick_generate_tasks('demo');

    FOR t IN SELECT pt.id, pt.order_id, pt.warehouse_id FROM pick_tasks pt
             WHERE pt.order_id IN ('O-24101', 'O-24102', 'O-24103', 'O-24104', 'O-24105', 'O-24106') ORDER BY pt.order_id LOOP
        v_picker := CASE WHEN t.order_id IN ('O-24101', 'O-24103', 'O-24105') THEN 'picker_aigerim' ELSE 'picker_daniyar' END;
        PERFORM pick_assign(t.id, v_picker, 'shift_lead');

        IF t.order_id = 'O-24103' THEN   -- ошибка сборщика: взял не тот товар — телефон не пустил
            SELECT * INTO r FROM pick_scan(t.id, 'AIRL:LOT:CF-ETH-250:PR-1003P', 1, v_picker);
        END IF;

        FOR ln IN SELECT * FROM pick_task_lines WHERE task_id = t.id ORDER BY line_no LOOP
            EXIT WHEN t.order_id = 'O-24106' AND ln.line_no > 1;          -- O-24106 собирается прямо сейчас
            LOOP
                SELECT * INTO ln FROM pick_task_lines WHERE id = ln.id;
                EXIT WHEN ln.done_at IS NOT NULL;
                SELECT * INTO f FROM pick_fefo(t.warehouse_id, ln.sku) LIMIT 1;
                IF NOT FOUND THEN RAISE EXCEPTION 'seed: нет остатка %', ln.sku; END IF;
                SELECT * INTO r FROM pick_scan(t.id, 'AIRL:CELL:' || f.cell_code, NULL, v_picker);
                IF NOT r.ok THEN RAISE EXCEPTION 'seed: % %', r.error_code, r.message; END IF;
                v_q := least(ln.qty - ln.qty_picked - ln.qty_short, f.qty);
                v_payload := CASE WHEN f.lot_no IS NULL THEN 'AIRL:SKU:' || ln.sku ELSE 'AIRL:LOT:' || ln.sku || ':' || f.lot_no END;
                SELECT * INTO r FROM pick_scan(t.id, v_payload, v_q, v_picker);
                IF NOT r.ok THEN RAISE EXCEPTION 'seed: % %', r.error_code, r.message; END IF;
            END LOOP;
        END LOOP;
        CONTINUE WHEN t.order_id = 'O-24106';

        IF t.order_id = 'O-24104' THEN   -- упаковщик нашёл в коробке чужой товар
            SELECT * INTO r FROM pick_pack_scan(t.id, 'AIRL:LOT:CF-ESP-1KG:PR-1002', 1, 'packer_olga');
        END IF;
        FOR f IN SELECT v.sku, v.lot_id, l.lot_no, sum(v.picked_qty) AS q FROM v_pick_task_picked v
                 LEFT JOIN pick_lots l ON l.id = v.lot_id WHERE v.task_id = t.id GROUP BY v.sku, v.lot_id, l.lot_no LOOP
            v_payload := CASE WHEN f.lot_no IS NULL THEN 'AIRL:SKU:' || f.sku ELSE 'AIRL:LOT:' || f.sku || ':' || f.lot_no END;
            SELECT * INTO r FROM pick_pack_scan(t.id, v_payload, f.q, 'packer_olga');
            IF NOT r.ok THEN RAISE EXCEPTION 'seed pack: % %', r.error_code, r.message; END IF;
        END LOOP;
        SELECT * INTO r FROM pick_pack_close(t.id, 'packer_olga');
        IF NOT r.ok THEN RAISE EXCEPTION 'seed close: % %', r.error_code, r.message; END IF;
        PERFORM pick_ship(t.id, 'packer_olga');
    END LOOP;

    -- Время сборки как в жизни (функции ставят now()): от подтверждения заказа.
    UPDATE pick_tasks pt
    SET started_at = o.confirmed_at + interval '50 minutes',
        picked_at  = o.confirmed_at + interval '50 minutes'
                     + make_interval(secs => 70 * (SELECT count(*) FROM pick_task_lines l WHERE l.task_id = pt.id)
                                             + 20 * (abs(hashtext(pt.order_id)) % 5)),
        checked_at = CASE WHEN pt.checked_at IS NOT NULL THEN o.confirmed_at + interval '75 minutes' END,
        shipped_at = CASE WHEN pt.shipped_at IS NOT NULL THEN o.confirmed_at + interval '2 hours' END,
        assigned_at = o.confirmed_at + interval '45 minutes'
    FROM src_pick_orders o
    WHERE o.order_id = pt.order_id AND pt.picked_at IS NOT NULL;
    UPDATE pick_tasks pt SET started_at = now() - interval '10 minutes', assigned_at = now() - interval '15 minutes'
    WHERE pt.order_id = 'O-24106';

    -- Приёмка от поставщика: сироп пришёл полностью, Колумбии — на 2 пачки меньше.
    INSERT INTO pick_receipts (warehouse_id, supplier_name, source_ref, expected_at, created_by)
    VALUES ('RC-ALA', 'ТОО «Кофе Трейд»', 'PO-000002', now() - interval '1 day', 'demo') RETURNING id INTO v_id;
    INSERT INTO pick_receipt_lines (receipt_id, line_no, sku, expected_qty, created_by) VALUES
        (v_id, 1, 'SY-VAN-1L', 12, 'demo'), (v_id, 2, 'CF-COL-250', 24, 'demo');
    SELECT * INTO r FROM pick_receive(v_id, '4870001000042', 'SV-0920', current_date + 200, 12, 'AIRL:CELL:ALA-RCV-01', 'storekeeper_marat');
    IF NOT r.ok THEN RAISE EXCEPTION 'seed receive: % %', r.error_code, r.message; END IF;
    SELECT * INTO r FROM pick_receive(v_id, 'AIRL:LOT:CF-COL-250:PR-1010', NULL, current_date + 175, 22, NULL, 'storekeeper_marat');
    IF NOT r.ok THEN RAISE EXCEPTION 'seed receive: % %', r.error_code, r.message; END IF;
    PERFORM pick_receipt_close(v_id, 'storekeeper_marat');
    -- Разместили сироп из приёмки на стеллаж.
    SELECT * INTO r FROM pick_move('AIRL:LOT:SY-VAN-1L:SV-0920', 'AIRL:CELL:ALA-RCV-01', 'AIRL:CELL:ALA-B-01-02', 12, 'storekeeper_marat');

    -- Пересчёт зоны B: овсяного молока на одну пачку меньше, чем по движениям.
    INSERT INTO pick_counts (warehouse_id, zone_id, created_by)
    SELECT 'RC-ALA', z.id, 'warehouse_head' FROM pick_zones z WHERE z.warehouse_id = 'RC-ALA' AND z.code = 'B'
    RETURNING id INTO v_cnt;
    FOR f IN SELECT s.cell_code, s.sku, s.lot_no, s.qty FROM v_pick_stock s
             WHERE s.warehouse_id = 'RC-ALA' AND s.zone_code = 'B' ORDER BY s.cell_code, s.sku, s.lot_no LOOP
        v_payload := CASE WHEN f.lot_no IS NULL THEN 'AIRL:SKU:' || f.sku ELSE 'AIRL:LOT:' || f.sku || ':' || f.lot_no END;
        SELECT * INTO r FROM pick_count_scan(v_cnt, 'AIRL:CELL:' || f.cell_code, v_payload,
                                             f.qty - CASE WHEN f.lot_no = 'MO-1020' THEN 1 ELSE 0 END, 'storekeeper_marat');
        IF NOT r.ok THEN RAISE EXCEPTION 'seed count: % %', r.error_code, r.message; END IF;
    END LOOP;
    PERFORM pick_count_close(v_cnt, 'warehouse_head');

    -- Просроченную партию молока — в карантин списанием из зоны хранения.
    UPDATE pick_lots SET hold = true, hold_reason = 'срок истёк', updated_by = 'warehouse_head'
    WHERE sku = 'ML-OAT-1L' AND lot_no = 'MO-0930';

    -- Причина по одному расхождению указана и закрыта.
    UPDATE pick_discrepancies SET responsible = 'picker_daniyar',
           resolution = 'Лишняя пачка возвращена в ячейку ALA-A-02-01, со сборщиком разобрали ошибку',
           status = 'resolved', updated_by = 'warehouse_head'
    WHERE source = 'pack' AND status = 'open';

    PERFORM pick_plan_notifications();
END $$;
