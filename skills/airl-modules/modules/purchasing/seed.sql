-- Синтетические данные модуля для разработки и показа: закупки обжарочного цеха и РЦ.
-- История заказов вносится напрямую (как перенос открытых заказов при запуске),
-- текущий цикл — через функции модуля. Повторный запуск ничего не дублирует.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('purchasing', 'currency',           '"KZT"',              'demo'),
 ('purchasing', 'timezone',           '"Asia/Almaty"',      'demo'),
 ('purchasing', 'approval_mode',      '"builtin"',          'demo'),
 ('purchasing', 'auto_approve_limit', '300000',             'demo'),
 ('purchasing', 'window_days',        '60',                 'demo'),
 ('purchasing', 'lead_time_days',     '14',                 'demo'),
 ('purchasing', 'safety_days',        '7',                  'demo'),
 ('purchasing', 'review_days',        '14',                 'demo'),
 ('purchasing', 'safety_method',      '"stddev"',           'demo'),
 ('purchasing', 'service_level',      '95',                 'demo'),
 ('purchasing', 'over_receipt_pct',   '2',                  'demo'),
 ('purchasing', 'qc_categories',      '["green_coffee"]',   'demo'),
 ('purchasing', 'approver_recipient', '"purchasing_head"',  'demo'),
 ('purchasing', 'buyer_recipient',    '"buyer_saule"',      'demo'),
 ('purchasing', 'channel',            '"telegram"',         'demo'),
 ('purchasing', 'contract_warn_days', '30',                 'demo'),
 ('purchasing', 'on_time_warn',       '90',                 'demo'),
 ('purchasing', 'on_time_bad',        '80',                 'demo'),
 ('purchasing', 'ppv_warn',           '2',                  'demo'),
 ('purchasing', 'ppv_bad',            '5',                  'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO pur_supplier_terms (supplier_id, payment_terms_days, prepayment_pct, lead_time_days, min_order_amount, currency,
                                contract_no, contract_from, contract_until, incoterms, created_by) VALUES
 ('SUP-01', 30, 30, 45, 5000,   'USD', 'GBT-2026/04',   current_date - 200, current_date + 20,  'DAP Алматы', 'demo'),
 ('SUP-02', 14,  0,  5, 100000, 'KZT', NULL,            NULL,               NULL,               NULL,         'demo'),
 ('SUP-03', 30,  0, 10, 150000, 'KZT', 'ПС-12/2026',    current_date - 300, current_date + 65,  NULL,         'demo'),
 ('SUP-04',  7,  0, 14, 200000, 'KZT', NULL,            NULL,               NULL,               NULL,         'demo'),
 ('SUP-05', 21,  0,  7, 50000,  'KZT', 'СА-03/2026',    current_date - 150, current_date + 215, NULL,         'demo'),
 ('SUP-06',  0, 100, 3, NULL,   'KZT', NULL,            NULL,               NULL,               NULL,         'demo')
ON CONFLICT (supplier_id) DO NOTHING;

INSERT INTO pur_prices (supplier_id, sku, kind, price, currency, moq, valid_from, valid_to, created_by) VALUES
 ('SUP-01', 'GR-ETH-SID',   'contract',   7.20, 'USD', 60,   current_date - 200, current_date + 20,  'demo'),
 ('SUP-01', 'GR-BRA-CER',   'contract',   4.80, 'USD', 60,   current_date - 200, current_date + 20,  'demo'),
 ('SUP-01', 'GR-COL-HUI',   'contract',   6.10, 'USD', 60,   current_date - 200, current_date + 20,  'demo'),
 ('SUP-02', 'GR-BRA-CER',   'price_list', 2550, 'KZT', 30,   current_date - 60,  NULL,               'demo'),
 ('SUP-03', 'PK-VALVE-250', 'contract',   65,   'KZT', 1000, current_date - 300, current_date + 65,  'demo'),
 ('SUP-03', 'PK-BOX-12',    'contract',   210,  'KZT', 100,  current_date - 300, current_date + 65,  'demo'),
 ('SUP-04', 'PK-VALVE-250', 'price_list', 61,   'KZT', 5000, current_date - 30,  NULL,               'demo'),
 ('SUP-05', 'SY-VAN-1L',    'contract',   2400, 'KZT', 12,   current_date - 150, current_date + 215, 'demo'),
 ('SUP-06', 'SP-GASKET-58', 'price_list', 1800, 'KZT', NULL, current_date - 90,  NULL,               'demo')
ON CONFLICT (supplier_id, sku, kind, valid_from) DO NOTHING;

INSERT INTO pur_item_settings (sku, warehouse_id, preferred_supplier_id, lead_time_days, order_multiple, min_order_qty, created_by) VALUES
 ('GR-ETH-SID',   'ROAST',  'SUP-01', 45, 60,  300,  'demo'),
 ('GR-BRA-CER',   'ROAST',  'SUP-01', 45, 60,  600,  'demo'),
 ('GR-COL-HUI',   'ROAST',  'SUP-01', 45, 60,  300,  'demo'),
 ('PK-VALVE-250', 'ROAST',  'SUP-03', NULL, 500, 1000, 'demo'),
 ('PK-BOX-12',    'ROAST',  'SUP-03', NULL, 50,  100,  'demo'),
 ('SY-VAN-1L',    'RC-ALA', 'SUP-05', NULL, 12,  NULL, 'demo'),
 ('SP-GASKET-58', 'RC-ALA', 'SUP-06', 3,    1,   NULL, 'demo')
ON CONFLICT (sku, warehouse_id) DO NOTHING;

DO $$
DECLARE
    v_po   bigint;
    v_req  bigint;
    v_rid  bigint;
    r      record;
BEGIN
    IF EXISTS (SELECT 1 FROM pur_orders) THEN RETURN; END IF;

    -- История: заказы последних трёх месяцев (переносятся при запуске).
    -- PO-000001: зерно, Колумбия куплена дороже контракта; Эфиопия пришла на 2 дня позже.
    INSERT INTO pur_orders (supplier_id, warehouse_id, currency, expected_date, payment_terms_days, created_by)
    VALUES ('SUP-01', 'ROAST', 'USD', current_date - 30, 30, 'buyer_saule') RETURNING id INTO v_po;
    INSERT INTO pur_order_lines (po_id, line_no, sku, qty, unit, price, created_by) VALUES
        (v_po, 1, 'GR-ETH-SID', 600, 'кг', 7.20, 'buyer_saule'),
        (v_po, 2, 'GR-COL-HUI', 600, 'кг', 6.40, 'buyer_saule');
    PERFORM pur_send(v_po, 'buyer_saule');
    PERFORM pur_confirm(v_po, NULL, 'buyer_saule');
    UPDATE pur_orders SET order_date = current_date - 75, sent_at = now() - interval '75 days' WHERE id = v_po;
    FOR r IN SELECT l.id, l.sku, l.qty FROM pur_order_lines l WHERE l.po_id = v_po ORDER BY l.line_no LOOP
        v_rid := pur_receive(r.id, r.qty, 'storekeeper_marat', 'GBT-' || right(r.sku, 3) || '-0826',
                             now() - CASE r.sku WHEN 'GR-ETH-SID' THEN interval '28 days' ELSE interval '31 days' END);
        PERFORM pur_set_qc(v_rid, true, 'Влажность 11%, дефектов 3 на 300 г', 'qgrader_ainur');
    END LOOP;
    PERFORM pur_close_po(v_po, 'buyer_saule');

    -- PO-000002: упаковка; короба пришли не все — недопоставка закрыта.
    INSERT INTO pur_orders (supplier_id, warehouse_id, currency, expected_date, payment_terms_days, created_by)
    VALUES ('SUP-03', 'ROAST', 'KZT', current_date - 25, 30, 'buyer_saule') RETURNING id INTO v_po;
    INSERT INTO pur_order_lines (po_id, line_no, sku, qty, unit, price, created_by) VALUES
        (v_po, 1, 'PK-VALVE-250', 6000, 'шт', 65, 'buyer_saule'),
        (v_po, 2, 'PK-BOX-12',     400, 'шт', 210, 'buyer_saule');
    PERFORM pur_send(v_po, 'buyer_saule');
    UPDATE pur_orders SET order_date = current_date - 40, sent_at = now() - interval '40 days' WHERE id = v_po;
    PERFORM pur_receive(l.id, 6000, 'storekeeper_marat', NULL, now() - interval '26 days') FROM pur_order_lines l WHERE l.po_id = v_po AND l.line_no = 1;
    PERFORM pur_receive(l.id, 300, 'storekeeper_marat', NULL, now() - interval '24 days') FROM pur_order_lines l WHERE l.po_id = v_po AND l.line_no = 2;
    PERFORM pur_close_line_short(l.id, 'Поставщик снял размер с производства, 100 шт не будет', 'buyer_saule')
    FROM pur_order_lines l WHERE l.po_id = v_po AND l.line_no = 2;

    -- PO-000003: сироп дороже контракта, пришла половина, вторая опаздывает.
    INSERT INTO pur_orders (supplier_id, warehouse_id, currency, expected_date, payment_terms_days, created_by)
    VALUES ('SUP-05', 'RC-ALA', 'KZT', current_date - 5, 21, 'buyer_saule') RETURNING id INTO v_po;
    INSERT INTO pur_order_lines (po_id, line_no, sku, qty, unit, price, created_by) VALUES
        (v_po, 1, 'SY-VAN-1L', 120, 'шт', 2450, 'buyer_saule');
    PERFORM pur_send(v_po, 'buyer_saule');
    UPDATE pur_orders SET order_date = current_date - 12, sent_at = now() - interval '12 days' WHERE id = v_po;
    PERFORM pur_receive(l.id, 60, 'storekeeper_marat', NULL, now() - interval '4 days') FROM pur_order_lines l WHERE l.po_id = v_po;

    -- PO-000004: Эфиопия, партия не прошла проверку качества — ждём замену.
    INSERT INTO pur_orders (supplier_id, warehouse_id, currency, expected_date, payment_terms_days, created_by)
    VALUES ('SUP-01', 'ROAST', 'USD', current_date - 10, 30, 'buyer_saule') RETURNING id INTO v_po;
    INSERT INTO pur_order_lines (po_id, line_no, sku, qty, unit, price, created_by) VALUES
        (v_po, 1, 'GR-ETH-SID', 300, 'кг', 7.20, 'buyer_saule');
    PERFORM pur_send(v_po, 'buyer_saule');
    UPDATE pur_orders SET order_date = current_date - 50, sent_at = now() - interval '50 days' WHERE id = v_po;
    v_rid := pur_receive((SELECT l.id FROM pur_order_lines l WHERE l.po_id = v_po), 300, 'storekeeper_marat',
                         'GBT-SID-0911', now() - interval '10 days', '1c', '1C-ПТ-000812');
    PERFORM pur_set_qc(v_rid, false, 'Влажность 13,5% при норме до 12%, запах мешковины', 'qgrader_ainur');

    -- PO-000005: Бразилия, подтверждён, едет.
    INSERT INTO pur_orders (supplier_id, warehouse_id, currency, expected_date, payment_terms_days, created_by)
    VALUES ('SUP-01', 'ROAST', 'USD', current_date + 25, 30, 'buyer_saule') RETURNING id INTO v_po;
    INSERT INTO pur_order_lines (po_id, line_no, sku, qty, unit, price, created_by) VALUES
        (v_po, 1, 'GR-BRA-CER', 1200, 'кг', 4.80, 'buyer_saule');
    PERFORM pur_send(v_po, 'buyer_saule');
    PERFORM pur_confirm(v_po, current_date + 28, 'buyer_saule');

    -- Текущий цикл. 1) Заявки по точке заказа.
    PERFORM pur_generate_requests('system');
    -- 2) Отправить: мелкие в тенге согласуются правилом, валютные ждут руководителя.
    FOR r IN SELECT id FROM pur_requests WHERE status = 'draft' AND source = 'reorder' ORDER BY id LOOP
        PERFORM pur_submit(r.id, 'buyer_saule');
    END LOOP;
    PERFORM pur_decide(id, true, 'purchasing_head') FROM pur_requests
    WHERE status = 'submitted' AND sku = 'GR-COL-HUI';

    -- 3) Внеплановая: кофемолка для нового клиента, три предложения.
    INSERT INTO pur_requests (description, sku, category, warehouse_id, qty, unit, needed_by, source, unplanned, justification,
                              est_price, created_by)
    VALUES ('Кофемолка Mahlkönig E65S для кофейни «Орбита»', 'EQ-GRINDER', 'equipment', 'RC-ALA', 2, 'шт', current_date + 14,
            'manual', true, 'Новый клиент с контрактом на 24 мес., оборудование в аренду', 1150000, 'manager_timur')
    RETURNING id INTO v_req;
    PERFORM pur_submit(v_req, 'manager_timur');
    PERFORM pur_decide(v_req, true, 'purchasing_head');
    INSERT INTO pur_offers (request_id, supplier_id, price, currency, fx_rate, lead_time_days, valid_until, comment, created_by) VALUES
        (v_req, 'SUP-06', 1120000, 'KZT', 1,      21, current_date + 10, 'Под заказ, гарантия 6 мес.', 'buyer_saule'),
        (v_req, 'SUP-02', 1185000, 'KZT', 1,       3, current_date + 7,  'Есть на складе, гарантия 12 мес.', 'buyer_saule'),
        (v_req, 'SUP-04', 2350,    'USD', 492.50, 30, current_date + 14, 'Поставка из Германии', 'buyer_saule');
    PERFORM pur_choose_offer(o.id, 'buyer_saule', 'Нужно через 2 недели, у дешёвого — 3 недели; гарантия 12 мес.')
    FROM pur_offers o WHERE o.request_id = v_req AND o.supplier_id = 'SUP-02';

    -- 4) Черновики заказов из согласованного; один отправлен.
    PERFORM pur_make_orders('buyer_saule');
    PERFORM pur_send(o.id, 'buyer_saule') FROM pur_orders o WHERE o.status = 'draft' AND o.supplier_id = 'SUP-02';

    PERFORM pur_plan_notifications();
END $$;
