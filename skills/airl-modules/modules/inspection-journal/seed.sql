-- Синтетические проверки для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('inspection-journal', 'object_type',   '"batch"', 'demo'),
 ('inspection-journal', 'overdue_hours', '24',      'demo'),
 ('inspection-journal', 'reject_warn',   '3',       'demo'),
 ('inspection-journal', 'reject_bad',    '7',       'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO insp_templates (code, title, object_type, created_by)
VALUES ('roast-qc', 'Контроль партии обжарки', 'batch', 'demo')
ON CONFLICT (code) DO NOTHING;

INSERT INTO insp_template_items (template_id, ord, code, title, kind, unit, target, min_value, max_value)
SELECT t.id, v.ord, v.code, v.title, v.kind, v.unit, v.target, v.min_value, v.max_value
FROM insp_templates t,
     (VALUES (1, 'color',  'Цвет обжарки (Agtron)', 'number',    'ед.', 62, 60, 64),
             (2, 'cup',    'Каппинг: без дефектов',  'pass_fail', NULL, NULL, NULL, NULL),
             (3, 'notes',  'Заметки',                'text',      NULL, NULL, NULL, NULL))
     AS v(ord, code, title, kind, unit, target, min_value, max_value)
WHERE t.code = 'roast-qc'
ON CONFLICT (template_id, code) DO NOTHING;

INSERT INTO insp_checks (check_no, object_id, template_id, status, comment, checked_at, checked_by, created_by)
SELECT v.check_no, v.object_id, t.id, v.status, v.comment, now() - v.ago, 'qc_1', 'qc_1'
FROM insp_templates t,
     (VALUES ('QC-0001', 'PR-1001', 'passed',   NULL,                         interval '60 hours'),
             ('QC-0002', 'PR-1002', 'rejected', 'Цвет 66 — пережарено',       interval '40 hours'),
             ('QC-0003', 'PR-1003', 'passed',   NULL,                         interval '20 hours'))
     AS v(check_no, object_id, status, comment, ago)
WHERE t.code = 'roast-qc'
ON CONFLICT (check_no) DO NOTHING;

INSERT INTO insp_results (check_id, item_id, value_num, passed)
SELECT c.id, i.id, v.value_num, v.passed
FROM (VALUES ('QC-0001', 'color', 62.5, true),
             ('QC-0002', 'color', 66.0, false),
             ('QC-0003', 'color', 61.0, true)) AS v(check_no, item_code, value_num, passed)
JOIN insp_checks c ON c.check_no = v.check_no
JOIN insp_template_items i ON i.template_id = c.template_id AND i.code = v.item_code
ON CONFLICT (check_id, item_id) DO NOTHING;

INSERT INTO insp_actions (check_id, kind, description, owner, due_date, created_by)
SELECT c.id, 'corrective', 'Скорректировать профиль: снизить финальную температуру на 3 °C', 'head_roast', current_date + 3, 'head_roast'
FROM insp_checks c WHERE c.check_no = 'QC-0002'
AND NOT EXISTS (SELECT 1 FROM insp_actions a WHERE a.check_id = c.id);
