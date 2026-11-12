-- Настройка модуля onboarding в витрине «HR» (ответы на вопросы MODULE.md). Значения СИНТЕТИЧЕСКИЕ:
-- в реальной компании чек-лист переносится из листа адаптации HR, документы — из базы знаний.
-- История онбординга за 18 месяцев восстановлена «как было бы» (детерминированно по номеру пункта),
-- чтобы показатель onboarding_on_time_rate было с чем сравнивать. Повторный запуск безопасен.
SET search_path TO mart_hr;

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('kit',        'currency',             '"KZT"', 'setup'),
 ('onboarding', 'generate_window_days', to_jsonb((SELECT current_date - min(hired_at) + 1 FROM src_onb_employees WHERE hired_at >= current_date - 540)), 'setup'),
 ('onboarding', 'ack_days',             '7',  'setup'),
 ('onboarding', 'permit_warn_days',     '30', 'setup'),
 ('onboarding', 'on_time_warn',         '85', 'setup'),
 ('onboarding', 'on_time_bad',          '70', 'setup'),
 ('onboarding', 'ack_warn',             '95', 'setup'),
 ('onboarding', 'ack_bad',              '85', 'setup')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO onb_templates (code, title, position, created_by) VALUES
 ('onb-airl', 'Адаптация в AIRL: общий чек-лист', NULL, 'setup')
ON CONFLICT (code) DO NOTHING;

INSERT INTO onb_template_items (template_id, ord, code, title, due_day, responsible_role, kind, ref_code)
SELECT t.id, v.ord, v.code, v.title, v.due_day, v.role, v.kind, v.ref
FROM onb_templates t
JOIN (VALUES
 (1, 'access',  'Доступы: почта, 1С, amoCRM, рабочие чаты',            0,  'it',       'task',     NULL),
 (2, 'rules',   'Ознакомиться с правилами внутреннего распорядка',     1,  'employee', 'document', 'REG-INTERNAL'),
 (3, 'goals',   'Встреча с руководителем: цели на испытательный срок', 2,  'manager',  'task',     NULL),
 (4, 'mentor',  'Назначить наставника, первая встреча',                3,  'manager',  'task',     NULL),
 (5, 'pdn',     'Ознакомиться с политикой защиты персональных данных', 5,  'employee', 'document', 'REG-PDN'),
 (6, 'course',  'Пройти курс «Продукты и клиенты AIRL»',               10, 'employee', 'course',   'C-AIRL-101'),
 (7, 'month',   'Встреча по итогам первого месяца',                    30, 'hr',       'task',     NULL),
 (8, 'review',  'Итоги испытательного срока',                          60, 'manager',  'task',     NULL)
) AS v(ord, code, title, due_day, role, kind, ref) ON t.code = 'onb-airl'
ON CONFLICT (template_id, code) DO NOTHING;

INSERT INTO onb_courses (code, title, pass_score, material_url, created_by)
VALUES ('C-AIRL-101', 'Продукты и клиенты AIRL', 80, 'https://kb.example.invalid/airl/101', 'setup')
ON CONFLICT (code) DO NOTHING;
INSERT INTO onb_questions (course_id, ord, question, choices, correct_choice)
SELECT c.id, v.ord, v.q, v.choices, v.correct
FROM onb_courses c,
     (VALUES (1, 'Какие направления у AIRL?', ARRAY['Только курс', 'Курс, корпоративное обучение, разработка ИИ, консалтинг', 'Только консалтинг'], 2),
             (2, 'Где хранятся персональные данные клиентов?', ARRAY['В личных чатах', 'В системах компании на территории РК', 'Где удобно'], 2),
             (3, 'Кто меняет статусы заявок?', ARRAY['Менеджер в amoCRM', 'Любой сотрудник в хабе', 'Бухгалтер'], 1))
     AS v(ord, q, choices, correct)
WHERE c.code = 'C-AIRL-101'
ON CONFLICT (course_id, ord) DO NOTHING;

INSERT INTO onb_documents (doc_code, version, title, url, required_positions, published_on, created_by) VALUES
 ('REG-INTERNAL', '1', 'Правила внутреннего распорядка', 'https://kb.example.invalid/reg/internal?v=1', NULL, current_date - 800, 'setup'),
 ('REG-PDN',      '1', 'Политика защиты персональных данных', 'https://kb.example.invalid/reg/pdn?v=1', NULL, current_date - 800, 'setup')
ON CONFLICT (doc_code, version) DO NOTHING;

-- Онбординг всем, кто пришёл за историю (окно — с первого найма периода).
SELECT onb_generate('setup');

-- История: пункты со сроком в прошлом закрыты — большинство в срок, часть с опозданием;
-- несколько свежих пунктов просрочены и открыты (их видно на экране «Новые сотрудники»).
WITH t AS (
    SELECT t.id, t.due_date, abs(hashtext('onb' || t.id::text)) % 100 AS r, it.responsible_role
    FROM onb_tasks t JOIN onb_template_items it ON it.id = t.item_id
    WHERE t.status = 'open' AND t.due_date < current_date
)
UPDATE onb_tasks o
SET status = 'done', done_by = 'setup', updated_by = 'setup',
    done_at = (t.due_date + CASE WHEN t.r < 76 THEN -(t.r % 3) WHEN t.r < 94 THEN 1 + t.r % 7 ELSE 0 END)::timestamptz + interval '12 hours'
FROM t
WHERE o.id = t.id
  AND NOT (t.r >= 72 AND t.due_date >= current_date - 40)          -- свежие «хвосты» остаются открытыми
  AND (t.due_date + CASE WHEN t.r < 76 THEN -(t.r % 3) WHEN t.r < 94 THEN 1 + t.r % 7 ELSE 0 END) < current_date;

-- Ознакомления, подтверждённые давними сотрудниками (до истории онбординга).
INSERT INTO onb_acks (document_id, employee_id, acked_at, created_by)
SELECT d.id, p.employee_id, d.published_on + 3, 'setup'
FROM v_onb_documents d JOIN v_onb_people p ON p.active
WHERE NOT EXISTS (SELECT 1 FROM onb_instances i WHERE i.employee_id = p.employee_id)
ON CONFLICT (document_id, employee_id) DO NOTHING;

-- staff_hr ведёт онбординг продаж, обучения, маркетинга и HR (разработку и финансы — руководитель HR).
INSERT INTO hr_staff_scope (login, departments, created_by)
VALUES ('staff_hr', ARRAY['Продажи', 'Обучение', 'Маркетинг', 'HR'], 'setup')
ON CONFLICT (login) DO NOTHING;
