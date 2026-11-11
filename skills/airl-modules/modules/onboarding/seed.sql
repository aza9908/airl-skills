-- Синтетические записи модуля для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('onboarding', 'generate_window_days', '90', 'demo'),
 ('onboarding', 'ack_days',             '7',  'demo'),
 ('onboarding', 'permit_warn_days',     '30', 'demo'),
 ('onboarding', 'on_time_warn',         '85', 'demo'),
 ('onboarding', 'on_time_bad',          '70', 'demo'),
 ('onboarding', 'ack_warn',             '95', 'demo'),
 ('onboarding', 'ack_bad',              '85', 'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO onb_templates (code, title, position, created_by) VALUES
 ('onb-barista', 'Адаптация бариста',          'Бариста', 'hr_1'),
 ('onb-default', 'Адаптация: общий чек-лист',  NULL,      'hr_1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO onb_template_items (template_id, ord, code, title, due_day, responsible_role, kind, ref_code)
SELECT t.id, v.ord, v.code, v.title, v.due_day, v.role, v.kind, v.ref
FROM onb_templates t
JOIN (VALUES
 ('onb-barista', 1, 'uniform',   'Выдать форму, шкафчик и доступ в кассу',             0,  'hr',       'task',     NULL),
 ('onb-barista', 2, 'mentor',    'Познакомить с наставником',                          0,  'manager',  'task',     NULL),
 ('onb-barista', 3, 'std',       'Ознакомиться со стандартом приготовления эспрессо',  1,  'employee', 'document', 'STD-ESPRESSO'),
 ('onb-barista', 4, 'sanitary',  'Ознакомиться с санитарными правилами',               3,  'employee', 'document', 'REG-SANITARY'),
 ('onb-barista', 5, 'test',      'Сдать тест «Основы эспрессо»',                       7,  'employee', 'course',   'C-ESPRESSO-1'),
 ('onb-barista', 6, 'shifts',    'Отработать 5 смен с наставником',                    14, 'mentor',   'task',     NULL),
 ('onb-barista', 7, 'solo',      'Аттестация: допуск к самостоятельной смене',         30, 'manager',  'permit',   'P-BAR-SOLO'),
 ('onb-default', 1, 'access',    'Выдать пропуск и рабочие доступы',                   0,  'it',       'task',     NULL),
 ('onb-default', 2, 'safety',    'Ознакомиться с инструкцией по охране труда',         1,  'employee', 'document', 'REG-SAFETY'),
 ('onb-default', 3, 'rules',     'Ознакомиться с правилами внутреннего распорядка',    3,  'employee', 'document', 'REG-INTERNAL'),
 ('onb-default', 4, 'meet',      'Встреча с руководителем: цели на испытательный срок', 7, 'manager',  'task',     NULL),
 ('onb-default', 5, 'review',    'Итоговая беседа по испытательному сроку',            60, 'manager',  'task',     NULL)
) AS v(tpl, ord, code, title, due_day, role, kind, ref) ON v.tpl = t.code
ON CONFLICT (template_id, code) DO NOTHING;

INSERT INTO onb_courses (code, title, pass_score, material_url, created_by)
VALUES ('C-ESPRESSO-1', 'Основы эспрессо', 80, 'https://kb.example.invalid/academy/espresso-1', 'head_barista')
ON CONFLICT (code) DO NOTHING;

INSERT INTO onb_questions (course_id, ord, question, choices, correct_choice)
SELECT c.id, v.ord, v.q, v.choices, v.correct
FROM onb_courses c,
     (VALUES (1, 'Сколько граммов молотого кофе в двойном эспрессо по стандарту STEP?', ARRAY['14', '18', '22'], 2),
             (2, 'Время экстракции двойного эспрессо', ARRAY['10–15 с', '25–30 с', '45–50 с'], 2),
             (3, 'Что делать, если эспрессо течёт слишком быстро?', ARRAY['Помол крупнее', 'Помол мельче', 'Меньше кофе'], 2),
             (4, 'Сколько хранится открытая пачка зерна в кофейне?', ARRAY['до 7 дней', 'до 30 дней', 'до 3 месяцев'], 1),
             (5, 'Температура молока для капучино', ARRAY['40–45 °C', '60–65 °C', '80–85 °C'], 2))
     AS v(ord, q, choices, correct)
WHERE c.code = 'C-ESPRESSO-1'
ON CONFLICT (course_id, ord) DO NOTHING;

INSERT INTO onb_documents (doc_code, version, title, url, required_positions, published_on, created_by)
VALUES
 ('STD-ESPRESSO', '1', 'Стандарт приготовления эспрессо', 'https://kb.example.invalid/std/espresso?v=1', ARRAY['Бариста', 'Старший бариста'], current_date - 400, 'head_barista'),
 ('STD-ESPRESSO', '2', 'Стандарт приготовления эспрессо', 'https://kb.example.invalid/std/espresso?v=2', ARRAY['Бариста', 'Старший бариста'], current_date - 20,  'head_barista'),
 ('REG-SANITARY', '3', 'Санитарные правила кофейни',      'https://kb.example.invalid/reg/sanitary?v=3', ARRAY['Бариста', 'Старший бариста', 'Обжарщик'], current_date - 180, 'hr_1'),
 ('REG-SAFETY',   '1', 'Инструкция по охране труда',      'https://kb.example.invalid/reg/safety?v=1',   NULL, current_date - 700, 'hr_1'),
 ('REG-INTERNAL', '2', 'Правила внутреннего распорядка',  'https://kb.example.invalid/reg/internal?v=2', NULL, current_date - 90,  'hr_1')
ON CONFLICT (doc_code, version) DO NOTHING;

-- Ознакомления сотрудников, работающих давно (v.ago — дней назад).
INSERT INTO onb_acks (document_id, employee_id, acked_at, created_by)
SELECT d.id, v.emp, now() - make_interval(days => v.ago), v.emp
FROM (VALUES ('STD-ESPRESSO', '1', 'E-002', 390), ('STD-ESPRESSO', '1', 'E-003', 380), ('STD-ESPRESSO', '1', 'E-004', 290),
             ('STD-ESPRESSO', '2', 'E-002', 18),  ('STD-ESPRESSO', '2', 'E-004', 10),
             ('REG-SANITARY', '3', 'E-002', 175), ('REG-SANITARY', '3', 'E-003', 170), ('REG-SANITARY', '3', 'E-004', 172),
             ('REG-SANITARY', '3', 'E-005', 160),
             ('REG-SAFETY',   '1', 'E-001', 690), ('REG-SAFETY',   '1', 'E-002', 690), ('REG-SAFETY',   '1', 'E-003', 495),
             ('REG-SAFETY',   '1', 'E-004', 298), ('REG-SAFETY',   '1', 'E-005', 690), ('REG-SAFETY',   '1', 'E-006', 418),
             ('REG-SAFETY',   '1', 'E-007', 248), ('REG-SAFETY',   '1', 'E-010', 690), ('REG-SAFETY',   '1', 'E-011', 690),
             ('REG-SAFETY',   '1', 'E-101', 39),  ('REG-SAFETY',   '1', 'E-104', 69),
             ('REG-INTERNAL', '2', 'E-001', 88),  ('REG-INTERNAL', '2', 'E-002', 85),  ('REG-INTERNAL', '2', 'E-003', 80),
             ('REG-INTERNAL', '2', 'E-004', 84),  ('REG-INTERNAL', '2', 'E-005', 86),  ('REG-INTERNAL', '2', 'E-006', 70),
             ('REG-INTERNAL', '2', 'E-010', 88),  ('REG-INTERNAL', '2', 'E-011', 87),  ('REG-INTERNAL', '2', 'E-104', 66))
     AS v(code, ver, emp, ago)
JOIN onb_documents d ON d.doc_code = v.code AND d.version = v.ver
ON CONFLICT (document_id, employee_id) DO NOTHING;

INSERT INTO onb_skills (code, title, kind, validity_months, created_by) VALUES
 ('S-ESPRESSO', 'Эспрессо и молочные напитки по стандарту', 'skill',  NULL, 'hr_1'),
 ('S-CUPPING',  'Каппинг и оценка вкуса',                   'skill',  NULL, 'hr_1'),
 ('P-BAR-SOLO', 'Допуск к самостоятельной смене бариста',   'permit', 12,   'hr_1'),
 ('P-ROASTER',  'Допуск к работе на ростере',               'permit', 12,   'hr_1'),
 ('P-STACKER',  'Допуск к работе на штабелёре',             'permit', 24,   'hr_1')
ON CONFLICT (code) DO NOTHING;

INSERT INTO onb_assessments (employee_id, skill_id, level, assessed_on, valid_until, assessor, basis, created_by)
SELECT v.emp, s.id, v.lvl, current_date - v.ago,
       CASE WHEN s.validity_months IS NOT NULL THEN (current_date - v.ago + make_interval(months => s.validity_months))::date END,
       v.assessor, v.basis, v.assessor
FROM (VALUES ('E-002', 'S-ESPRESSO', 3, 300, 'E-001', 'экзамен'),
             ('E-002', 'P-BAR-SOLO', 2, 340, 'E-001', 'аттестация'),
             ('E-003', 'S-ESPRESSO', 2, 400, 'E-002', 'экзамен'),
             ('E-003', 'P-BAR-SOLO', 2, 380, 'E-002', 'аттестация'),
             ('E-004', 'S-ESPRESSO', 1, 250, 'E-002', 'экзамен'),
             ('E-004', 'S-ESPRESSO', 2, 60,  'E-002', 'повторный экзамен'),
             ('E-004', 'P-BAR-SOLO', 2, 200, 'E-002', 'аттестация'),
             ('E-005', 'P-ROASTER',  2, 350, 'E-010', 'аттестация'),
             ('E-005', 'S-CUPPING',  2, 120, 'E-010', 'каппинг-сессия'),
             ('E-006', 'P-STACKER',  2, 400, 'E-011', 'удостоверение №118'),
             ('E-007', 'P-STACKER',  2, 240, 'E-011', 'удостоверение №131'))
     AS v(emp, skill, lvl, ago, assessor, basis)
JOIN onb_skills s ON s.code = v.skill
ON CONFLICT (employee_id, skill_id, assessed_on) DO NOTHING;

-- Онбординг новичков и отметки выполнения (v.late — на сколько дней позже срока; NULL — не сделано).
DO $$ BEGIN PERFORM onb_generate('hr_1'); END $$;

UPDATE onb_tasks t
SET status = 'done', done_at = (t.due_date + v.late)::timestamptz + interval '15 hours',
    done_by = v.who, updated_by = v.who
FROM onb_instances i, onb_template_items it,
     (VALUES ('E-101', 'uniform', 0, 'hr_1'),   ('E-101', 'mentor', 0, 'E-002'), ('E-101', 'std', 0, 'E-101'),
             ('E-101', 'sanitary', 1, 'E-101'), ('E-101', 'shifts', 3, 'E-002'),
             ('E-102', 'uniform', 0, 'hr_1'),   ('E-102', 'mentor', 0, 'E-002'), ('E-102', 'sanitary', 2, 'E-102'),
             ('E-103', 'access', 0, 'it_1'),
             ('E-104', 'access', 0, 'it_1'),    ('E-104', 'safety', 0, 'E-104'), ('E-104', 'rules', 1, 'E-104'),
             ('E-104', 'meet', 4, 'E-010')) AS v(emp, code, late, who)
WHERE t.instance_id = i.id AND t.item_id = it.id AND i.employee_id = v.emp AND it.code = v.code
  AND t.status = 'open';

-- Тесты: E-101 сдала с первого раза, E-102 не сдал.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM onb_attempts WHERE employee_id = 'E-101') THEN
        PERFORM onb_submit_attempt('C-ESPRESSO-1', 'E-101', '{"1": 2, "2": 2, "3": 2, "4": 1, "5": 2}', 'E-101');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM onb_attempts WHERE employee_id = 'E-102') THEN
        PERFORM onb_submit_attempt('C-ESPRESSO-1', 'E-102', '{"1": 2, "2": 1, "3": 1, "4": 1, "5": 2}', 'E-102');
    END IF;
END $$;
