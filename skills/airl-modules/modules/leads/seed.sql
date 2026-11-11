-- Синтетические настройки, правила и лиды для разработки и показа. Лиды заводятся через
-- lead_capture — тем же путём, что и вебхук. Повторный запуск ничего не дублирует:
-- external_id у каждой заявки свой.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('leads', 'dedup_days',           '30',                                                       'demo'),
 ('leads', 'sla_minutes',          '15',                                                       'demo'),
 ('leads', 'frt_bad_minutes',      '60',                                                       'demo'),
 ('leads', 'timezone',             '"Asia/Almaty"',                                            'demo'),
 ('leads', 'work_hours',           '{"days": [1,2,3,4,5,6], "from": "09:00", "to": "19:00"}',  'demo'),
 ('leads', 'auto_reply_text',      '"Спасибо! Мы получили заявку {code}. Менеджер ответит {start}."', 'demo'),
 ('leads', 'fallback_assignee',    '"role:sales_head"',                                        'demo'),
 ('leads', 'escalation_recipient', '"role:sales_head"',                                        'demo'),
 ('leads', 'attribution_days',     '90',                                                       'demo'),
 ('leads', 'romi_margin_pct',      '100',                                                      'demo'),
 ('leads', 'conversion_warn',      '10',                                                       'demo'),
 ('leads', 'conversion_bad',       '5',                                                        'demo'),
 ('leads', 'romi_warn',            '100',                                                      'demo'),
 ('leads', 'romi_bad',             '0',                                                        'demo'),
 ('leads', 'channel',              '"telegram"',                                               'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO lead_lost_reasons (code, title, created_by) VALUES
 ('no_answer',   'Не отвечает',                 'demo'),
 ('price',       'Дорого',                      'demo'),
 ('competitor',  'Выбрал другого поставщика',   'demo'),
 ('not_target',  'Не наш клиент / спам',        'demo'),
 ('no_stock',    'Нет нужного товара',          'demo')
ON CONFLICT (code) DO NOTHING;

INSERT INTO lead_routing_rules (code, title, priority, channel, city, interest, created_by) VALUES
 ('B2B',     'HoReCa и офисы — отдел B2B',   10,  NULL, NULL,     'b2b',    'demo'),
 ('AST',     'Астана — розница',             50,  NULL, 'Астана', NULL,     'demo'),
 ('DEFAULT', 'Алматы и остальные — розница', 100, NULL, NULL,     NULL,     'demo')
ON CONFLICT (code) DO NOTHING;

INSERT INTO lead_rule_managers (rule_id, manager_id, ord, created_by)
SELECT r.id, v.manager_id, v.ord, 'demo'
FROM (VALUES ('B2B', 'm_ruslan', 1), ('B2B', 'm_dana', 2),
             ('AST', 'm_aliya', 1),
             ('DEFAULT', 'm_aidana', 1), ('DEFAULT', 'm_timur', 2), ('DEFAULT', 'm_saule', 3)) AS v(rule_code, manager_id, ord)
JOIN lead_routing_rules r ON r.code = v.rule_code
ON CONFLICT (rule_id, manager_id) DO NOTHING;

-- 360 заявок за 120 дней. Канал и кампания — по i % 10; телефон — та же формула, что в demo_src.
SELECT count(lead_capture(jsonb_strip_nulls(jsonb_build_object(
           'channel',      c.channel,
           'external_id',  'demo-' || i,
           'received_at',  least(((current_date - (120 - i / 3)) + time '08:00' + make_interval(mins => (i * 37) % 780))
                                     AT TIME ZONE 'Asia/Almaty',
                                 now() - interval '30 minutes'),
           'name',         'Клиент ' || i,
           'phone',        '+7 70' || lpad((10000000 + (i * 7919) % 89999999)::text, 8, '0'),
           'email',        CASE WHEN c.channel IN ('site', 'meta_form') THEN 'client' || i || '@example.kz' END,
           'city',         CASE i % 3 WHEN 0 THEN 'Астана' ELSE 'Алматы' END,
           'interest',     c.interest,
           'utm_source',   c.utm_source,
           'utm_medium',   c.utm_medium,
           'utm_campaign', c.campaign,
           'ad_id',        CASE WHEN c.campaign IS NOT NULL THEN 'ad-' || (i % 4) END,
           'consent_marketing', (i % 4 <> 0),
           'consent_text', CASE WHEN i % 4 <> 0 THEN 'Согласен получать новости и предложения' END)), 'seed'))
FROM generate_series(1, 360) i
JOIN (VALUES (0, 'instagram', 'ig_autumn_blend',      'retail', 'instagram', 'paid'),
             (1, 'instagram', 'ig_autumn_blend',      'retail', 'instagram', 'paid'),
             (2, 'instagram', 'ig_horeca_b2b',        'b2b',    'instagram', 'paid'),
             (3, 'meta_form', 'ig_horeca_b2b',        'b2b',    'facebook',  'paid'),
             (4, 'site',      'google_search_coffee', 'retail', 'google',    'cpc'),
             (5, 'site',      'google_search_coffee', 'retail', 'google',    'cpc'),
             (6, 'telegram',  'tg_bot_organic',       'retail', 'telegram',  'organic'),
             (7, 'telegram',  'tg_bot_organic',       'retail', 'telegram',  'organic'),
             (8, 'meta_form', 'fb_office_coffee',     'b2b',    'facebook',  'paid'),
             (9, 'phone',     NULL,                   'retail', NULL,        NULL))
     AS c(k, channel, campaign, interest, utm_source, utm_medium) ON c.k = i % 10;

-- Повторные обращения тем же телефоном через 2 дня из другого канала — тот же лид.
SELECT count(lead_capture(jsonb_build_object(
           'channel', 'telegram', 'external_id', 'demo-repeat-' || i,
           'received_at', ((current_date - (118 - i / 3)) + time '12:00') AT TIME ZONE 'Asia/Almaty',
           'phone', '8 70' || lpad((10000000 + (i * 7919) % 89999999)::text, 8, '0'),
           'utm_source', 'telegram', 'utm_campaign', 'tg_bot_organic'), 'seed'))
FROM generate_series(23, 345, 23) i;

-- Работа менеджеров с лидами старше двух дней (только тех, что ещё «новые»).
UPDATE lead_leads l
   SET status = 'in_work',
       first_response_at = l.sla_start_at + make_interval(mins => abs(hashtext(l.lead_no || 'f')) % 30
                                                             + CASE WHEN l.channel = 'meta_form' THEN 40 ELSE 2 END),
       updated_by = l.assigned_to
 WHERE l.status = 'new' AND l.received_at < now() - interval '2 days' AND l.first_response_at IS NULL
   AND NOT (l.channel = 'site' AND (abs(hashtext(l.lead_no)) % 9) = 0);   -- часть заявок с сайта забыли

UPDATE lead_leads l
   SET status = 'qualified', qualified_at = l.first_response_at + interval '1 day', updated_by = l.assigned_to
 WHERE l.status = 'in_work' AND (abs(hashtext(l.lead_no)) % 3) = 0;

UPDATE lead_leads l
   SET status = 'lost',
       lost_reason = (ARRAY['no_answer', 'price', 'competitor', 'not_target', 'no_stock'])[1 + abs(hashtext(l.lead_no || 'r')) % 5],
       closed_at = l.first_response_at + interval '2 days', updated_by = l.assigned_to
 WHERE l.status IN ('in_work', 'qualified') AND (abs(hashtext(l.lead_no || 'l')) % 4) = 0
   AND l.received_at < now() - interval '7 days';

-- Сделки из CRM/1С: связать с лидами и отметить продажу.
SELECT lead_sync_deals('seed');
SELECT lead_queue_notifications();
