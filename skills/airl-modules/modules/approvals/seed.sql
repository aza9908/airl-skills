-- Синтетические заявки, правила и бюджеты для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('approvals', 'currency',              '"KZT"',      'demo'),
 ('approvals', 'large_amount',          '5000000',    'demo'),
 ('approvals', 'new_counterparty_days', '90',         'demo'),
 ('approvals', 'remind_hours',          '24',         'demo'),
 ('approvals', 'cycle_warn_hours',      '24',         'demo'),
 ('approvals', 'cycle_bad_hours',       '72',         'demo'),
 ('approvals', 'channel',               '"telegram"', 'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO appr_categories (code, title, budget_controlled, requires_document, created_by) VALUES
 ('green_coffee', 'Зелёное зерно',                  false, true,  'demo'),
 ('packaging',    'Упаковка',                       true,  true,  'demo'),
 ('equipment',    'Оборудование и запчасти',        true,  true,  'demo'),
 ('marketing',    'Маркетинг и реклама',            true,  true,  'demo'),
 ('gifts',        'Подарки и представительские',    true,  false, 'demo'),
 ('travel',       'Командировки',                   true,  false, 'demo'),
 ('services',     'Услуги подрядчиков',             true,  true,  'demo'),
 ('logistics',    'Доставка и логистика',           true,  true,  'demo'),
 ('office',       'Офис и хозрасходы',              true,  false, 'demo')
ON CONFLICT (code) DO NOTHING;

INSERT INTO appr_rules (code, title, priority, request_type, category, min_amount, max_amount, created_by) VALUES
 ('R-UNPLANNED',   'Внеплановая закупка — любая сумма',          10,  'unplanned_purchase', NULL,           0,       NULL,    'demo'),
 ('R-GREEN-LARGE', 'Зелёное зерно от 5 млн',                     40,  NULL,                 'green_coffee', 5000000, NULL,    'demo'),
 ('R-GREEN',       'Зелёное зерно до 5 млн',                     50,  NULL,                 'green_coffee', 0,       5000000, 'demo'),
 ('R-GIFTS',       'Подарки и представительские',                50,  NULL,                 'gifts',        0,       NULL,    'demo'),
 ('R-SMALL',       'До 100 000',                                 100, NULL,                 NULL,           0,       100000,  'demo'),
 ('R-MID',         'От 100 000 до 1 000 000',                    100, NULL,                 NULL,           100000,  1000000, 'demo'),
 ('R-LARGE',       'От 1 000 000',                               100, NULL,                 NULL,           1000000, NULL,    'demo')
ON CONFLICT (code) DO NOTHING;

INSERT INTO appr_rule_steps (rule_id, step_no, approver_role, created_by)
SELECT ru.id, v.step_no, v.role, 'demo'
FROM (VALUES ('R-UNPLANNED', 1, 'dept_head'), ('R-UNPLANNED', 2, 'purchase_head'),
             ('R-UNPLANNED', 3, 'fin_director'), ('R-UNPLANNED', 4, 'ceo'),
             ('R-GREEN-LARGE', 1, 'purchase_head'), ('R-GREEN-LARGE', 2, 'fin_director'), ('R-GREEN-LARGE', 3, 'ceo'),
             ('R-GREEN', 1, 'purchase_head'), ('R-GREEN', 2, 'fin_director'),
             ('R-GIFTS', 1, 'dept_head'), ('R-GIFTS', 2, 'ceo'),
             ('R-SMALL', 1, 'dept_head'),
             ('R-MID', 1, 'dept_head'), ('R-MID', 2, 'fin_director'),
             ('R-LARGE', 1, 'dept_head'), ('R-LARGE', 2, 'fin_director'), ('R-LARGE', 3, 'ceo'))
     AS v(rule_code, step_no, role)
JOIN appr_rules ru ON ru.code = v.rule_code
ON CONFLICT (rule_id, step_no) DO NOTHING;

-- Бюджеты на прошлый и текущий месяц.
INSERT INTO appr_budgets (dept_id, category, month, amount, currency, created_by)
SELECT v.dept_id, v.category, (date_trunc('month', current_date) - make_interval(months => m.k))::date,
       v.amount, 'KZT', 'u_fin'
FROM (VALUES ('trade_ala', 'marketing', 1000000), ('trade_ala', 'travel',  300000),
             ('trade_ala', 'gifts',     200000),  ('trade_ast', 'marketing', 800000),
             ('trade_ast', 'gifts',     250000),  ('trade_ast', 'logistics', 600000),
             ('trade_ast', 'office',    100000),  ('roast',     'packaging', 2500000),
             ('roast',     'equipment', 1500000), ('dc',        'equipment', 500000),
             ('office',    'services',  400000))
     AS v(dept_id, category, amount),
     (VALUES (0), (1)) AS m(k)
ON CONFLICT (dept_id, category, month) DO NOTHING;

-- Заявки. m = 0 — бюджет текущего месяца, 1 — прошлого. Интервалы — «сколько назад».
INSERT INTO appr_requests (request_no, request_type, dept_id, category, counterparty_id, counterparty_name,
                           purpose, doc_ref, amount, currency, amount_base, budget_month, need_by, status,
                           rule_id, current_round, submitted_at, decided_at, paid_at, payment_ref,
                           cancel_reason, created_at, created_by)
SELECT v.request_no, v.request_type, v.dept_id, v.category, v.counterparty_id, v.counterparty_name,
       v.purpose, v.doc_ref, v.amount, v.currency, v.amount_base,
       (date_trunc('month', current_date) - make_interval(months => v.m))::date,
       current_date + v.need_in, v.status,
       (SELECT id FROM appr_rules WHERE code = v.rule_code),
       CASE WHEN v.submitted IS NULL THEN 0 ELSE 1 END,
       now() - v.submitted, now() - v.decided, now() - v.paid,
       CASE WHEN v.paid IS NOT NULL THEN 'ПП-' || substr(v.request_no, 4) END,
       v.cancel_reason,
       now() - COALESCE(v.submitted, interval '1 hour') - interval '1 hour', v.author
FROM (VALUES
 ('ЗР-0001', 'payment',            'trade_ala', 'marketing',    'SUP-ADV',  NULL, 'Таргетированная реклама в Instagram', 'Счёт 1187', 450000.00,  'KZT', 450000.00,  1, -30, 'paid',        'R-MID',        interval '40 days',  interval '39 days',  interval '37 days', NULL, 'u_marketing'),
 ('ЗР-0002', 'purchase',           'roast',     'packaging',    'SUP-PACK', NULL, 'Дой-пак 1 кг с клапаном, 5000 шт',   'Счёт 552',  1850000.00, 'KZT', 1850000.00, 1, -25, 'paid',        'R-LARGE',      interval '38 days',  interval '35 days',  interval '33 days', NULL, 'u_roast_buyer'),
 ('ЗР-0003', 'payment',            'trade_ast', 'gifts',        'EMP-014',  NULL, 'Подарки ключевым клиентам к Новому году', NULL,   320000.00,  'KZT', 320000.00,  0, 20,  'rejected',    'R-GIFTS',      interval '6 days',   interval '4 days',   NULL, NULL, 'u_ruslan'),
 ('ЗР-0004', 'purchase',           'roast',     'green_coffee', 'SUP-001',  NULL, 'Зелёное зерно Бразилия Серрадо, 2 т', 'Контракт GCT-2026-07', 19200.00, 'USD', 9600000.00, 0, 30, 'approved', 'R-GREEN-LARGE', interval '5 days', interval '2 days',   NULL, NULL, 'u_purchase'),
 ('ЗР-0005', 'unplanned_purchase', 'dc',        'equipment',    NULL,       'ТОО «Холод-Мастер»', 'Срочно: ремонт холодильной камеры РЦ', NULL, 780000.00, 'KZT', 780000.00, 0, 2, 'on_approval', 'R-UNPLANNED', interval '40 hours', NULL, NULL, NULL, 'u_dc_engineer'),
 ('ЗР-0006', 'expense',            'trade_ala', 'travel',       'EMP-021',  NULL, 'Командировка в Астану: дегустация для сети кофеен', NULL, 185000.00, 'KZT', 185000.00, 0, 5, 'on_approval', 'R-MID', interval '20 hours', NULL, NULL, NULL, 'u_aidana'),
 ('ЗР-0007', 'payment',            'trade_ala', 'marketing',    'SUP-ADV',  NULL, 'Съёмка контента для Instagram',     'Счёт 1243', 600000.00,  'KZT', 600000.00,  0, 10,  'approved',    'R-MID',        interval '9 days',   interval '8 days',   NULL, NULL, 'u_marketing'),
 ('ЗР-0008', 'payment',            'office',    'services',     'SUP-IT',   NULL, 'Абонентское обслуживание 1С',       'Счёт 3301', 95000.00,   'KZT', 95000.00,   0, 7,   'on_approval', 'R-SMALL',      interval '3 hours',  NULL, NULL, NULL, 'u_office'),
 ('ЗР-0009', 'expense',            'trade_ast', 'office',       'EMP-014',  NULL, 'Канцтовары для офиса Астаны',       NULL,        35000.00,   'KZT', 35000.00,   0, 14,  'draft',       NULL,           NULL,                NULL, NULL, NULL, 'u_ruslan'),
 ('ЗР-0010', 'payment',            'trade_ala', 'marketing',    'SUP-ADV2', NULL, 'Наружная реклама, пр. Абая',        'Договор 17', 550000.00, 'KZT', 550000.00,  0, 3,   'paid',        'R-MID',        interval '12 days',  interval '11 days',  interval '10 days', NULL, 'u_marketing'),
 ('ЗР-0011', 'payment',            'trade_ast', 'logistics',    'SUP-LOG',  NULL, 'Доставка до Астаны, 3 рейса',       'Счёт 77',   270000.00,  'KZT', 270000.00,  0, 4,   'returned',    'R-MID',        interval '3 days',   NULL, NULL, NULL, 'u_ruslan'),
 ('ЗР-0012', 'payment',            'roast',     'equipment',    'SUP-EQ',   NULL, 'Запчасти для ростера',              'Счёт 905',  1200000.00, 'KZT', 1200000.00, 1, -20, 'paid',        'R-LARGE',      interval '45 days',  interval '41 days',  interval '40 days', NULL, 'u_roast_buyer'),
 ('ЗР-0013', 'expense',            'trade_ala', 'gifts',        'EMP-021',  NULL, 'Цветы партнёру',                    NULL,        25000.00,   'KZT', 25000.00,   0, 1,   'cancelled',   NULL,           NULL,                NULL, NULL, 'Передумали, оплатили лично', 'u_aidana')
) AS v(request_no, request_type, dept_id, category, counterparty_id, counterparty_name, purpose, doc_ref,
       amount, currency, amount_base, m, need_in, status, rule_code, submitted, decided, paid, cancel_reason, author)
ON CONFLICT (request_no) DO NOTHING;

-- Решения по шагам (круг 1). decided — «сколько назад».
INSERT INTO appr_steps (request_id, round, step_no, approver_role, decision, decided_at, decided_by, comment, created_by)
SELECT r.id, 1, v.step_no, v.role, v.decision, now() - v.decided, v.decided_by, v.comment, 'system'
FROM (VALUES
 ('ЗР-0001', 1, 'dept_head',     'approved', interval '39 days 20 hours', 'u_head_ala',   NULL),
 ('ЗР-0001', 2, 'fin_director',  'approved', interval '39 days',          'u_fin',        NULL),
 ('ЗР-0002', 1, 'dept_head',     'approved', interval '37 days',          'u_head_roast', NULL),
 ('ЗР-0002', 2, 'fin_director',  'approved', interval '36 days',          'u_fin',        NULL),
 ('ЗР-0002', 3, 'ceo',           'approved', interval '35 days',          'u_ceo',        NULL),
 ('ЗР-0003', 1, 'dept_head',     'approved', interval '5 days',           'u_head_ast',   NULL),
 ('ЗР-0003', 2, 'ceo',           'rejected', interval '4 days',           'u_ceo',        'Сначала согласуйте список клиентов с коммерческим директором'),
 ('ЗР-0004', 1, 'purchase_head', 'approved', interval '4 days',           'u_purchase_head', NULL),
 ('ЗР-0004', 2, 'fin_director',  'approved', interval '3 days',           'u_fin',        NULL),
 ('ЗР-0004', 3, 'ceo',           'approved', interval '2 days',           'u_ceo',        NULL),
 ('ЗР-0005', 1, 'dept_head',     'approved', interval '30 hours',         'u_head_dc',   NULL),
 ('ЗР-0005', 2, 'purchase_head', 'pending',  NULL,                        NULL,           NULL),
 ('ЗР-0005', 3, 'fin_director',  'pending',  NULL,                        NULL,           NULL),
 ('ЗР-0005', 4, 'ceo',           'pending',  NULL,                        NULL,           NULL),
 ('ЗР-0006', 1, 'dept_head',     'approved', interval '18 hours',         'u_head_ala',   NULL),
 ('ЗР-0006', 2, 'fin_director',  'pending',  NULL,                        NULL,           NULL),
 ('ЗР-0007', 1, 'dept_head',     'approved', interval '8 days 20 hours',  'u_head_ala',   NULL),
 ('ЗР-0007', 2, 'fin_director',  'approved', interval '8 days',           'u_fin',        'Бюджет маркетинга Алматы почти исчерпан'),
 ('ЗР-0008', 1, 'dept_head',     'pending',  NULL,                        NULL,           NULL),
 ('ЗР-0010', 1, 'dept_head',     'approved', interval '11 days 22 hours', 'u_head_ala',   NULL),
 ('ЗР-0010', 2, 'fin_director',  'approved', interval '11 days',          'u_fin',        NULL),
 ('ЗР-0011', 1, 'dept_head',     'approved', interval '2 days',           'u_head_ast',   NULL),
 ('ЗР-0011', 2, 'fin_director',  'returned', interval '1 day',            'u_fin',        'Приложите акты выполненных работ'),
 ('ЗР-0012', 1, 'dept_head',     'approved', interval '44 days',          'u_head_roast', NULL),
 ('ЗР-0012', 2, 'fin_director',  'approved', interval '43 days',          'u_fin',        NULL),
 ('ЗР-0012', 3, 'ceo',           'approved', interval '41 days',          'u_ceo',        NULL)
) AS v(request_no, step_no, role, decision, decided, decided_by, comment)
JOIN appr_requests r ON r.request_no = v.request_no
ON CONFLICT (request_id, round, step_no) DO NOTHING;

-- Вложения: счета есть не у всех заявок (ЗР-0005 и ЗР-0011 — без документа).
INSERT INTO airl_attachments (module, entity, entity_id, url, filename, mime_type, uploaded_by)
SELECT 'approvals', 'request', v.no, 'https://files.example/approvals/' || v.no || '.pdf', v.no || '.pdf', 'application/pdf', 'demo'
FROM (VALUES ('ЗР-0001'), ('ЗР-0002'), ('ЗР-0004'), ('ЗР-0007'), ('ЗР-0008'), ('ЗР-0010'), ('ЗР-0012')) AS v(no)
WHERE NOT EXISTS (SELECT 1 FROM airl_attachments a
                  WHERE a.module = 'approvals' AND a.entity = 'request' AND a.entity_id = v.no);
