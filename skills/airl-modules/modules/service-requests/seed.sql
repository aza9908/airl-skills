-- Синтетические записи модуля для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('service-requests', 'sla_hours',         '{"critical": 8, "high": 24, "normal": 72, "low": 168}', 'demo'),
 ('service-requests', 'repeat_days',       '30',               'demo'),
 ('service-requests', 'plan_horizon_days', '14',               'demo'),
 ('service-requests', 'escalate_to',       '"head_service"',   'demo'),
 ('service-requests', 'notify_channel',    '"in_app"',         'demo'),
 ('service-requests', 'sla_breach_warn',   '10',               'demo'),
 ('service-requests', 'sla_breach_bad',    '20',               'demo'),
 ('service-requests', 'repeat_warn',       '5',                'demo'),
 ('service-requests', 'repeat_bad',        '10',               'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO svc_equipment (equipment_no, kind, model, serial_no, client_id, address, owner,
                           installed_at, warranty_until, created_by)
VALUES
 ('EQ-001', 'espresso_machine', 'La Marzocco Linea PB 2gr',  'LM-PB-21-0457', 'C-0101', NULL, 'client',  current_date - 980, current_date - 250, 'demo'),
 ('EQ-002', 'grinder',          'Mahlkönig E65S',            'MK-E65-88213',  'C-0101', NULL, 'company', current_date - 600, current_date + 130, 'demo'),
 ('EQ-003', 'espresso_machine', 'Victoria Arduino Eagle One','VA-EO-23-1190', 'C-0102', NULL, 'client',  current_date - 300, current_date + 430, 'demo'),
 ('EQ-004', 'espresso_machine', 'Jura WE8',                  'JU-WE8-77120',  'C-0103', '5 этаж, кухня', 'company', current_date - 420, current_date - 55, 'demo'),
 ('EQ-005', 'espresso_machine', 'La Marzocco Linea Mini',    'LM-MINI-6631',  'C-0104', NULL, 'client',  current_date - 200, current_date + 530, 'demo'),
 ('EQ-006', 'espresso_machine', 'Nuova Simonelli Appia II',  'NS-AP2-40551',  'C-0201', NULL, 'client',  current_date - 700, current_date - 335, 'demo'),
 ('EQ-007', 'grinder',          'Mazzer Super Jolly',        'MZ-SJ-120934',  'C-0202', NULL, 'company', current_date - 150, current_date + 580, 'demo'),
 ('EQ-008', 'water_filter',     'BWT bestmax M',             NULL,            'C-0201', NULL, 'company', current_date - 700, NULL,              'demo')
ON CONFLICT (equipment_no) DO NOTHING;

-- Заявки: v.d — дней назад создана, v.h — через сколько часов выполнена (NULL — не выполнена).
INSERT INTO svc_requests (request_no, kind, equipment_id, client_id, problem, priority, source, status,
                          technician, created_at, assigned_at, started_at, done_at, closed_at,
                          resolution, cancel_reason, created_by)
SELECT v.no, v.kind, e.id, coalesce(e.client_id, v.client_id), v.problem, v.priority, v.source, v.status,
       v.tech,
       now() - make_interval(days => v.d),
       CASE WHEN v.tech IS NOT NULL THEN now() - make_interval(days => v.d) + interval '1 hour' END,
       CASE WHEN v.status NOT IN ('new', 'assigned', 'cancelled') THEN now() - make_interval(days => v.d) + interval '2 hours' END,
       CASE WHEN v.h IS NOT NULL THEN now() - make_interval(days => v.d) + make_interval(hours => v.h) END,
       CASE WHEN v.status = 'closed' THEN now() - make_interval(days => v.d) + make_interval(hours => v.h + 3) END,
       v.resolution, v.cancel_reason, 'dispatcher_1'
FROM (VALUES
 ('SR-0001', 'repair',          'EQ-001', NULL,     'Течёт вода из-под группы',              'high',     'phone',         'closed',        'tech_arman', 70, 22,   'Заменён уплотнитель группы', NULL),
 ('SR-0002', 'repair',          'EQ-001', NULL,     'Снова течёт из-под левой группы',        'high',     'telegram',      'closed',        'tech_dias',  55, 30,   'Заменены уплотнитель и сеточка душа', NULL),
 ('SR-0003', 'repair',          'EQ-003', NULL,     'Не греет бойлер, кофейня стоит',         'critical', 'phone',         'closed',        'tech_arman', 45, 6,    'Сброшен термопредохранитель, заменён прессостат', NULL),
 ('SR-0004', 'repair',          'EQ-004', NULL,     'Ошибка 8, не мелет',                     'normal',   'site',          'closed',        'tech_oleg',  40, 100,  'Заменены жернова', NULL),
 ('SR-0005', 'barista_service', NULL,     'C-0202', 'Обучение двух новых бариста',            'normal',   'sales_manager', 'closed',        'tech_dias',  35, 48,   'Проведено обучение 3 часа', NULL),
 ('SR-0006', 'repair',          'EQ-007', NULL,     'Помол неравномерный',                    'normal',   'telegram',      'done',          'tech_oleg',  25, 20,   'Настроены жернова', NULL),
 ('SR-0007', 'repair',          'EQ-006', NULL,     'Нет давления, кофе течёт водой',         'high',     'phone',         'closed',        'tech_arman', 12, 40,   'Заменена помпа', NULL),
 ('SR-0008', 'repair',          'EQ-006', NULL,     'Опять падает давление к обеду',          'high',     'phone',         'waiting_parts', 'tech_arman', 5,  NULL, NULL, NULL),
 ('SR-0009', 'repair',          'EQ-005', NULL,     'Шумит помпа',                            'normal',   'telegram',      'assigned',      'tech_dias',  2,  NULL, NULL, NULL),
 ('SR-0010', 'repair',          'EQ-002', NULL,     'Скрипит при включении',                  'low',      'site',          'new',           NULL,         0,  NULL, NULL, NULL),
 ('SR-0011', 'maintenance',     'EQ-003', NULL,     'Плановое ТО: чистка групп, замена фильтра', 'low',   'planned',       'cancelled',     NULL,         30, NULL, NULL, 'Кофейня закрыта на ремонт, перенос'),
 ('SR-0012', 'repair',          'EQ-001', NULL,     'Не включается после отключения света',   'critical', 'phone',         'closed',        'tech_oleg',  8,  5,    'Заменён предохранитель платы', NULL)
) AS v(no, kind, eq, client_id, problem, priority, source, status, tech, d, h, resolution, cancel_reason)
LEFT JOIN svc_equipment e ON e.equipment_no = v.eq
ON CONFLICT (request_no) DO NOTHING;

INSERT INTO svc_parts_used (request_id, sku, qty, written_off_ref, created_by)
SELECT r.id, v.sku, v.qty, v.ref, r.technician
FROM (VALUES ('SR-0001', 'SP-GASKET-58', 1, '1С: списание №2201'),
             ('SR-0002', 'SP-GASKET-58', 2, '1С: списание №2240'),
             ('SR-0002', 'SP-SHOWER-58', 2, '1С: списание №2240'),
             ('SR-0003', 'SP-PRESS-SW',  1, '1С: списание №2263'),
             ('SR-0004', 'SP-BURR-64',   1, '1С: списание №2270'),
             ('SR-0007', 'SP-PUMP-ULKA', 1, NULL),
             ('SR-0008', 'SP-PRESS-SW',  1, NULL)) AS v(no, sku, qty, ref)
JOIN svc_requests r ON r.request_no = v.no
ON CONFLICT (request_id, sku) DO NOTHING;

INSERT INTO svc_acts (act_no, request_id, work_done, labor_minutes, signer_name, confirm_method,
                      confirm_code_hash, confirmed_at, created_by)
SELECT 'ACT-' || substr(r.request_no, 4), r.id, r.resolution, v.minutes,
       v.signer, v.method, CASE WHEN v.method = 'code' THEN md5('demo-' || r.request_no) END,
       CASE WHEN v.signer IS NOT NULL THEN r.done_at + interval '1 hour' END, r.technician
FROM (VALUES ('SR-0001', 40,  'Управляющий А. С.',  'code'),
             ('SR-0002', 75,  'Управляющий А. С.',  'signature'),
             ('SR-0003', 120, 'Бариста Д. К.',      'code'),
             ('SR-0004', 90,  'Офис-менеджер Г. Т.', 'paper'),
             ('SR-0005', 180, 'Владелец Е. Б.',     'code'),
             ('SR-0006', 30,  NULL,                 NULL),
             ('SR-0007', 110, 'Управляющий М. Н.',  'code'),
             ('SR-0012', 35,  'Управляющий А. С.',  'code')) AS v(no, minutes, signer, method)
JOIN svc_requests r ON r.request_no = v.no
ON CONFLICT (request_id) DO NOTHING;

INSERT INTO airl_attachments (module, entity, entity_id, url, filename, mime_type, size_bytes, uploaded_by)
SELECT 'service-requests', 'svc_acts', a.id::text, 'https://files.example.invalid/svc/' || a.act_no || '.jpg',
       a.act_no || '.jpg', 'image/jpeg', 245000, a.created_by
FROM svc_acts a
WHERE a.act_no IN ('ACT-0002', 'ACT-0007')
  AND NOT EXISTS (SELECT 1 FROM airl_attachments x
                  WHERE x.module = 'service-requests' AND x.entity = 'svc_acts' AND x.entity_id = a.id::text);

INSERT INTO svc_maint_plans (equipment_id, interval_days, next_due, work_template, created_by)
SELECT e.id, v.days, current_date + v.due, v.work, 'head_service'
FROM (VALUES ('EQ-001', 90,  5,  'Плановое ТО: чистка групп, замена уплотнителей, декальцинация'),
              ('EQ-003', 90,  40, 'Плановое ТО: чистка групп, замена фильтра'),
              ('EQ-008', 180, 10, 'Замена картриджа фильтра воды')) AS v(eq, days, due, work)
JOIN svc_equipment e ON e.equipment_no = v.eq
ON CONFLICT (equipment_id) DO NOTHING;

DO $$ BEGIN
    PERFORM svc_generate_planned('demo');
    PERFORM svc_notify_overdue();
END $$;
