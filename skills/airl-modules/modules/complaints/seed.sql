-- Синтетические записи модуля для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('complaints', 'sla_hours',         '{"critical": 4, "high": 24, "normal": 48, "low": 120}', 'demo'),
 ('complaints', 'escalate_l1',       '"head_support"', 'demo'),
 ('complaints', 'escalate_l2',       '"ceo"',          'demo'),
 ('complaints', 'escalate_l2_hours', '24',             'demo'),
 ('complaints', 'notify_channel',    '"in_app"',       'demo'),
 ('complaints', 'repeat_days',       '90',             'demo'),
 ('complaints', 'csat_ask',          'true',           'demo'),
 ('complaints', 'sla_breach_warn',   '10',             'demo'),
 ('complaints', 'sla_breach_bad',    '20',             'demo'),
 ('complaints', 'csat_warn',         '4.2',            'demo'),
 ('complaints', 'csat_bad',          '3.8',            'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO cmp_categories (code, title, sla_hours, default_priority, owner_role, created_by) VALUES
 ('quality',    'Качество кофе',             24,   'high',   'head_qc',       'demo'),
 ('delivery',   'Доставка',                  24,   'normal', 'head_logistics','demo'),
 ('order',      'Заказ и комплектация',      NULL, 'normal', 'head_warehouse','demo'),
 ('service',    'Сервис оборудования',       NULL, 'high',   'head_service',  'demo'),
 ('billing',    'Оплата и документы',        72,   'low',    'accountant',    'demo'),
 ('staff',      'Работа сотрудников',        48,   'normal', 'head_support',  'demo'),
 ('suggestion', 'Предложения и отзывы',      120,  'low',    'marketing',     'demo')
ON CONFLICT (code) DO NOTHING;

-- v.d — дней назад, v.h — через сколько часов дан ответ с решением (NULL — ещё нет).
INSERT INTO cmp_cases (case_no, kind, channel, category_id, client_id, contact_name, contact_phone,
                       subject, description, priority, status, responsible, object_type, object_id,
                       root_cause, resolution, reject_reason, created_at, resolved_at, closed_at,
                       csat, csat_at, created_by)
SELECT v.no, v.kind, v.channel, c.id, v.client_id, v.cname, v.cphone, v.subject, v.descr, v.priority, v.status,
       v.resp, v.otype, v.oid, v.cause,
       CASE WHEN v.status IN ('resolved', 'closed') THEN v.resolution END,
       CASE WHEN v.status = 'rejected' THEN v.resolution END,
       now() - make_interval(days => v.d, hours => 3),
       CASE WHEN v.h IS NOT NULL THEN now() - make_interval(days => v.d, hours => 3) + make_interval(hours => v.h) END,
       CASE WHEN v.status IN ('closed', 'rejected') THEN now() - make_interval(days => v.d, hours => 3) + make_interval(hours => v.h + 24) END,
       v.csat,
       CASE WHEN v.csat IS NOT NULL THEN now() - make_interval(days => v.d, hours => 3) + make_interval(hours => v.h + 20) END,
       'support_1'
FROM (VALUES
 ('CS-0001', 'complaint', 'phone',             'quality',    'C-0101', NULL,    NULL,           'Кислый вкус эспрессо',             'Бленд из последней поставки кислит, гости жалуются', 'high',     'closed',           'qc_lead',     'batch',     'PR-1002', 'Пережарка партии, отклонена QC, но часть ушла клиенту', 'Замена 10 кг, извинения', 75, 20,   4),
 ('CS-0002', 'complaint', 'telegram',          'quality',    'C-0102', NULL,    NULL,           'Горечь, похоже на пережарку',      'Эспрессо горчит третий день',                        'high',     'closed',           'qc_lead',     'batch',     'PR-1002', 'Та же партия PR-1002',                                 'Замена 6 кг',              73, 30,   3),
 ('CS-0003', 'complaint', 'delivery_feedback', 'delivery',   'C-0103', NULL,    NULL,           'Привезли на 3 часа позже окна',    'Окно 9–11, привезли в 14:00',                        'normal',   'closed',           'logist_1',    'order',     'ORD-55120', 'Перегруз маршрута',                                  'Скидка 5% на следующий заказ', 60, 10, 5),
 ('CS-0004', 'claim',     'phone',             'order',      'C-0201', NULL,    NULL,           'Недовложение 2 упаковки',          'По накладной 12, по факту 10',                       'high',     'closed',           'wh_lead',     'order',     'ORD-55210', 'Ошибка комплектовщика',                              'Довезли 2 упаковки',       50, 50,   2),
 ('CS-0005', 'complaint', 'service',           'service',    'C-0101', NULL,    NULL,           'Третья поломка за два месяца',     'Машину опять ремонтируют, просим замену',            'high',     'closed',           'head_service','equipment', 'EQ-001',  'Износ группы, нужен капремонт',                       'Подменная машина на время капремонта', 40, 12, 4),
 ('CS-0006', 'praise',    'site',              'suggestion', 'C-0301', NULL,    NULL,           'Спасибо за Кению',                 'Очень вкусно, возьму ещё',                           'low',      'closed',           'marketing_1', NULL,        NULL,      NULL,                                                  'Поблагодарили, промокод',  35, 6,    NULL),
 ('CS-0007', 'feedback',  'instagram',         'suggestion', NULL,     'Айжан', '+77019990007', 'Хотим декаф в 1 кг',               'Можно ли декаф в большой упаковке',                  'low',      'rejected',         'marketing_1', NULL,        NULL,      NULL,                                                  'Нет в ассортименте, передано в маркетинг', 30, 20, NULL),
 ('CS-0008', 'complaint', 'delivery_feedback', 'staff',      'C-0202', NULL,    NULL,           'Курьер был груб',                  'Отказался занести коробки',                          'normal',   'closed',           'head_support','delivery',  'DLV-8812', 'Нарушение стандарта водителем',                     'Беседа с водителем, извинения', 20, 40, 3),
 ('CS-0009', 'complaint', 'telegram',          'quality',    'C-0201', NULL,    NULL,           'Зерно быстро выдыхается',          'Через неделю после вскрытия нет аромата',            'normal',   'waiting_customer', 'qc_lead',     'batch',     'PR-0995', NULL,                                                   NULL,                       12, NULL, NULL),
 ('CS-0010', 'claim',     'email',             'billing',    'C-0103', NULL,    NULL,           'Нет счёт-фактуры за октябрь',      'Бухгалтерия клиента не получила ЭСФ',                'low',      'closed',           'accountant_1',NULL,        NULL,      'ЭСФ не выписана',                                    'Выписана и отправлена',    9,  30,   5),
 ('CS-0011', 'complaint', 'phone',             'quality',    'C-0102', NULL,    NULL,           'Снова горчит',                     'Новая поставка тоже горчит',                         'high',     'in_progress',      'qc_lead',     'batch',     'PR-1002', NULL,                                                   NULL,                       6,  NULL, NULL),
 ('CS-0012', 'complaint', 'delivery_feedback', 'delivery',   'C-0104', NULL,    NULL,           'Помятые пакеты',                   '3 пакета с порванными клапанами',                    'normal',   'in_progress',      'logist_1',    'order',     'ORD-55690', NULL,                                                 NULL,                       0,  NULL, NULL),
 ('CS-0013', 'question',  'site',              'order',      'C-0301', NULL,    NULL,           'Где мой заказ?',                   'Заказ с сайта три дня назад',                        'normal',   'new',              NULL,          'order',     'ORD-55702', NULL,                                                 NULL,                       0,  NULL, NULL),
 ('CS-0014', 'complaint', 'service',           'service',    'C-0201', NULL,    NULL,           'Машина снова без давления',        'После ремонта неделя — и опять',                     'high',     'in_progress',      'head_service','equipment', 'EQ-006',  NULL,                                                   NULL,                       4,  NULL, NULL)
) AS v(no, kind, channel, cat, client_id, cname, cphone, subject, descr, priority, status, resp, otype, oid, cause, resolution, d, h, csat)
JOIN cmp_categories c ON c.code = v.cat
ON CONFLICT (case_no) DO NOTHING;

INSERT INTO cmp_comments (case_id, visibility, body, created_at, created_by)
SELECT k.id, v.vis, v.body, k.created_at + make_interval(hours => v.h), v.author
FROM (VALUES ('CS-0001', 'internal', 'Проверил журнал QC: PR-1002 отклонена по цвету 66, часть отгружена до решения', 2, 'qc_lead'),
             ('CS-0001', 'customer', 'Заменим 10 кг сегодня, приносим извинения', 4, 'support_1'),
             ('CS-0009', 'customer', 'Подскажите, как храните зерно после вскрытия? Пришлите фото упаковки', 3, 'qc_lead'),
             ('CS-0011', 'internal', 'Повтор по PR-1002 — вся партия в карантин, см. inspection-journal', 1, 'qc_lead'))
     AS v(no, vis, body, h, author)
JOIN cmp_cases k ON k.case_no = v.no
WHERE NOT EXISTS (SELECT 1 FROM cmp_comments x WHERE x.case_id = k.id AND x.body = v.body);

DO $$ BEGIN PERFORM cmp_escalate(); END $$;
