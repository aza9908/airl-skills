-- Модуль «Онбординг, обучение, аттестация» (onboarding). Требует kit/kit.sql в той же
-- схеме и представление src_onb_employees (адаптер или demo_src.sql).
-- ФИО хранится только в источнике; экраны модуля показывают короткое имя (display_name).

-- Чек-листы адаптации по должности. position = NULL — шаблон для всех остальных должностей.
CREATE TABLE IF NOT EXISTS onb_templates (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text        NOT NULL UNIQUE,
    title       text        NOT NULL,
    position    text,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);

CREATE TABLE IF NOT EXISTS onb_template_items (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    template_id      bigint      NOT NULL REFERENCES onb_templates (id),
    ord              int         NOT NULL,
    code             text        NOT NULL,
    title            text        NOT NULL,
    due_day          int         NOT NULL CHECK (due_day >= 0),     -- день от даты приёма
    responsible_role text        NOT NULL CHECK (responsible_role IN ('employee', 'manager', 'mentor', 'hr', 'it')),
    kind             text        NOT NULL DEFAULT 'task' CHECK (kind IN ('task', 'document', 'course', 'permit')),
    ref_code         text,                                          -- код документа, курса или допуска
    UNIQUE (template_id, code),
    CHECK (kind = 'task' OR ref_code IS NOT NULL)
);

-- Онбординг конкретного сотрудника и его пункты.
CREATE TABLE IF NOT EXISTS onb_instances (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id   text        NOT NULL,
    template_id   bigint      NOT NULL REFERENCES onb_templates (id),
    started_on    date        NOT NULL,
    status        text        NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed', 'cancelled')),
    completed_at  timestamptz,
    cancel_reason text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL,
    updated_at    timestamptz,
    updated_by    text,
    UNIQUE (employee_id, template_id),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS onb_tasks (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    instance_id bigint      NOT NULL REFERENCES onb_instances (id),
    item_id     bigint      NOT NULL REFERENCES onb_template_items (id),
    due_date    date        NOT NULL,
    status      text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'skipped')),
    done_at     timestamptz,
    done_by     text,
    comment     text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    UNIQUE (instance_id, item_id),
    CHECK (status <> 'done' OR (done_at IS NOT NULL AND done_by IS NOT NULL)),
    CHECK (status <> 'skipped' OR comment IS NOT NULL)
);

-- Курсы и тесты.
CREATE TABLE IF NOT EXISTS onb_courses (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text         NOT NULL UNIQUE,
    title       text         NOT NULL,
    pass_score  numeric(5,2) NOT NULL CHECK (pass_score BETWEEN 0 AND 100),
    material_url text,
    active      boolean      NOT NULL DEFAULT true,
    created_at  timestamptz  NOT NULL DEFAULT now(),
    created_by  text         NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);

CREATE TABLE IF NOT EXISTS onb_questions (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id      bigint      NOT NULL REFERENCES onb_courses (id),
    ord            int         NOT NULL,
    question       text        NOT NULL,
    choices        text[]      NOT NULL,
    correct_choice int         NOT NULL,                     -- номер верного варианта, с 1
    UNIQUE (course_id, ord),
    CHECK (correct_choice BETWEEN 1 AND cardinality(choices))
);

CREATE TABLE IF NOT EXISTS onb_attempts (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    course_id    bigint       NOT NULL REFERENCES onb_courses (id),
    employee_id  text         NOT NULL,
    answers      jsonb        NOT NULL,                      -- {"<ord>": <номер варианта>}
    score        numeric(5,2) NOT NULL CHECK (score BETWEEN 0 AND 100),
    passed       boolean      NOT NULL,
    finished_at  timestamptz  NOT NULL DEFAULT now(),
    created_at   timestamptz  NOT NULL DEFAULT now(),
    created_by   text         NOT NULL,
    updated_at   timestamptz,
    updated_by   text
);
CREATE INDEX IF NOT EXISTS onb_attempts_emp_idx ON onb_attempts (employee_id, course_id, finished_at);

-- Документы для ознакомления: ссылка на базу знаний и версия.
CREATE TABLE IF NOT EXISTS onb_documents (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_code           text        NOT NULL,
    version            text        NOT NULL,
    title              text        NOT NULL,
    url                text        NOT NULL,
    required_positions text[],                                -- NULL — для всех
    published_on       date        NOT NULL,
    archived           boolean     NOT NULL DEFAULT false,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         text        NOT NULL,
    updated_at         timestamptz,
    updated_by         text,
    UNIQUE (doc_code, version)
);

-- Подтверждение ознакомления: кто, какую версию, когда. Ставит сам сотрудник.
CREATE TABLE IF NOT EXISTS onb_acks (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document_id bigint      NOT NULL REFERENCES onb_documents (id),
    employee_id text        NOT NULL,
    acked_at    timestamptz NOT NULL DEFAULT now(),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    UNIQUE (document_id, employee_id)
);

-- Навыки и допуски; оценки — история, действует последняя.
CREATE TABLE IF NOT EXISTS onb_skills (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            text        NOT NULL UNIQUE,
    title           text        NOT NULL,
    kind            text        NOT NULL CHECK (kind IN ('skill', 'permit')),
    validity_months int         CHECK (validity_months IS NULL OR validity_months > 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      text        NOT NULL,
    updated_at      timestamptz,
    updated_by      text
);

CREATE TABLE IF NOT EXISTS onb_assessments (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id  text        NOT NULL,
    skill_id     bigint      NOT NULL REFERENCES onb_skills (id),
    level        smallint    NOT NULL CHECK (level BETWEEN 0 AND 3),   -- 0 нет · 1 под контролем · 2 сам · 3 учит других
    assessed_on  date        NOT NULL,
    valid_until  date,
    assessor     text        NOT NULL,
    basis        text,                                                  -- экзамен, номер попытки, приказ
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text        NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    UNIQUE (employee_id, skill_id, assessed_on)
);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['onb_templates', 'onb_instances', 'onb_tasks', 'onb_courses', 'onb_attempts',
                             'onb_documents', 'onb_acks', 'onb_skills', 'onb_assessments'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_touch', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION airl_touch()', t || '_touch', t);
    END LOOP;
END $$;

-- Журнал смены статуса пункта и онбординга.
CREATE OR REPLACE FUNCTION onb_status_audit() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF OLD.status NOT IN ('open', 'active') THEN
            RAISE EXCEPTION 'onboarding: % уже в статусе %, менять нельзя', TG_TABLE_NAME, OLD.status;
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (coalesce(NEW.updated_by, 'system'), 'onboarding', TG_TABLE_NAME, NEW.id::text,
                'status', OLD.status, NEW.status, NULL);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS onb_tasks_status ON onb_tasks;
CREATE TRIGGER onb_tasks_status BEFORE UPDATE ON onb_tasks FOR EACH ROW EXECUTE FUNCTION onb_status_audit();
DROP TRIGGER IF EXISTS onb_instances_status ON onb_instances;
CREATE TRIGGER onb_instances_status BEFORE UPDATE ON onb_instances FOR EACH ROW EXECUTE FUNCTION onb_status_audit();

-- Сотрудники с коротким именем «Имя Ф.» — его показывают экраны вместо ФИО.
CREATE OR REPLACE VIEW v_onb_people AS
SELECT e.employee_id,
       (split_part(e.full_name, ' ', 1) ||
        CASE WHEN split_part(e.full_name, ' ', 2) <> '' THEN ' ' || left(split_part(e.full_name, ' ', 2), 1) || '.' ELSE '' END)::text AS display_name,
       e.position, e.department, e.hired_at, e.manager_id, e.active,
       (current_date - e.hired_at) AS days_since_hire
FROM src_onb_employees e;

-- Экран «Мои задачи»: пункты онбординга с ответственным и просрочкой.
CREATE OR REPLACE VIEW v_onb_tasks AS
SELECT t.id, i.employee_id, p.display_name, p.position, p.department, p.manager_id,
       it.ord, it.title, it.kind, it.ref_code, it.responsible_role,
       CASE it.responsible_role WHEN 'employee' THEN i.employee_id WHEN 'manager' THEN p.manager_id END AS responsible_user,
       t.due_date, t.status, t.done_at, t.done_by, t.comment,
       (t.status = 'open' AND t.due_date < current_date) AS overdue,
       CASE WHEN t.status = 'open' AND t.due_date < current_date THEN current_date - t.due_date END AS days_overdue,
       (t.status = 'done' AND t.done_at::date <= t.due_date) AS on_time
FROM onb_tasks t
JOIN onb_instances i ON i.id = t.instance_id AND i.status <> 'cancelled'
JOIN onb_template_items it ON it.id = t.item_id
LEFT JOIN v_onb_people p ON p.employee_id = i.employee_id;

-- Экран «Новые сотрудники»: прогресс онбординга.
CREATE OR REPLACE VIEW v_onb_progress AS
SELECT i.id AS instance_id, i.employee_id, p.display_name, p.position, p.department, p.manager_id,
       i.started_on, (current_date - i.started_on) AS day_no, tp.title AS template, i.status,
       count(t.id) AS items_total,
       count(t.id) FILTER (WHERE t.status IN ('done', 'skipped')) AS items_done,
       count(t.id) FILTER (WHERE t.status = 'open' AND t.due_date < current_date) AS items_overdue,
       round(100.0 * count(t.id) FILTER (WHERE t.status IN ('done', 'skipped')) / NULLIF(count(t.id), 0), 0) AS pct_done
FROM onb_instances i
JOIN onb_templates tp ON tp.id = i.template_id
LEFT JOIN onb_tasks t ON t.instance_id = i.id
LEFT JOIN v_onb_people p ON p.employee_id = i.employee_id
GROUP BY i.id, i.employee_id, p.display_name, p.position, p.department, p.manager_id, i.started_on, tp.title, i.status;

-- Действующая версия каждого документа.
CREATE OR REPLACE VIEW v_onb_documents AS
SELECT DISTINCT ON (d.doc_code) d.*
FROM onb_documents d
WHERE NOT d.archived AND d.published_on <= current_date
ORDER BY d.doc_code, d.published_on DESC, d.id DESC;

-- Экран «Ознакомление»: кто должен прочитать действующую версию и прочитал ли.
-- Срок — ack_days дней от публикации версии или от приёма, что позже.
CREATE OR REPLACE VIEW v_onb_ack_status AS
SELECT d.id AS document_id, d.doc_code, d.version, d.title, d.url,
       p.employee_id, p.display_name, p.position, p.department, p.manager_id,
       (greatest(d.published_on, p.hired_at) + (airl_setting('onboarding', 'ack_days', '7'))::text::int) AS ack_due,
       a.acked_at,
       (a.id IS NOT NULL) AS acked,
       (a.id IS NULL AND greatest(d.published_on, p.hired_at) + (airl_setting('onboarding', 'ack_days', '7'))::text::int < current_date) AS overdue
FROM v_onb_documents d
JOIN v_onb_people p ON p.active AND (d.required_positions IS NULL OR p.position = ANY (d.required_positions))
LEFT JOIN onb_acks a ON a.document_id = d.id AND a.employee_id = p.employee_id;

-- Экран «Матрица компетенций»: последняя оценка по сотруднику и навыку, срок допуска.
CREATE OR REPLACE VIEW v_onb_matrix AS
SELECT DISTINCT ON (a.employee_id, a.skill_id)
       a.employee_id, p.display_name, p.position, p.department, s.code AS skill_code, s.title AS skill, s.kind,
       a.level, a.assessed_on, a.valid_until, a.assessor,
       CASE WHEN a.valid_until IS NULL THEN 'valid'
            WHEN a.valid_until < current_date THEN 'expired'
            WHEN a.valid_until < current_date + (airl_setting('onboarding', 'permit_warn_days', '30'))::text::int THEN 'expiring'
            ELSE 'valid' END::text AS validity
FROM onb_assessments a
JOIN onb_skills s ON s.id = a.skill_id
JOIN v_onb_people p ON p.employee_id = a.employee_id AND p.active
ORDER BY a.employee_id, a.skill_id, a.assessed_on DESC, a.id DESC;

-- История обучения: попытки тестов.
CREATE OR REPLACE VIEW v_onb_attempts AS
SELECT at.id, at.employee_id, p.display_name, c.code AS course_code, c.title AS course, c.pass_score,
       at.score, at.passed, at.finished_at,
       row_number() OVER (PARTITION BY at.employee_id, at.course_id ORDER BY at.finished_at) AS attempt_no
FROM onb_attempts at
JOIN onb_courses c ON c.id = at.course_id
LEFT JOIN v_onb_people p ON p.employee_id = at.employee_id;

-- Создать онбординг новым сотрудникам (принятым не раньше generate_window_days назад).
CREATE OR REPLACE FUNCTION onb_generate(p_actor text) RETURNS int LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE n int;
BEGIN
    INSERT INTO onb_instances (employee_id, template_id, started_on, created_by)
    SELECT e.employee_id,
           (SELECT t.id FROM onb_templates t
            WHERE t.active AND (t.position = e.position OR t.position IS NULL)
            ORDER BY (t.position IS NULL), t.id LIMIT 1),
           e.hired_at, p_actor
    FROM src_onb_employees e
    WHERE e.active AND e.hired_at <= current_date
      AND e.hired_at >= current_date - (airl_setting('onboarding', 'generate_window_days', '90'))::text::int
      AND NOT EXISTS (SELECT 1 FROM onb_instances i WHERE i.employee_id = e.employee_id)
      AND EXISTS (SELECT 1 FROM onb_templates t WHERE t.active AND (t.position = e.position OR t.position IS NULL))
    ON CONFLICT (employee_id, template_id) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;

    INSERT INTO onb_tasks (instance_id, item_id, due_date, created_by)
    SELECT i.id, it.id, i.started_on + it.due_day, p_actor
    FROM onb_instances i
    JOIN onb_template_items it ON it.template_id = i.template_id
    WHERE i.status = 'active'
    ON CONFLICT (instance_id, item_id) DO NOTHING;
    RETURN n;
END $$;

-- Сдать тест: балл считается на сервере по верным ответам. Сданный тест закрывает пункт онбординга.
CREATE OR REPLACE FUNCTION onb_submit_attempt(p_course_code text, p_employee_id text, p_answers jsonb, p_actor text)
RETURNS bigint LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    c  onb_courses;
    sc numeric(5,2);
    v_id bigint;
BEGIN
    SELECT * INTO c FROM onb_courses WHERE code = p_course_code AND active;
    IF NOT FOUND THEN RAISE EXCEPTION 'onboarding: курс % не найден', p_course_code; END IF;
    SELECT round(100.0 * count(*) FILTER (WHERE (p_answers ->> q.ord::text)::int = q.correct_choice) / NULLIF(count(*), 0), 2)
      INTO sc FROM onb_questions q WHERE q.course_id = c.id;
    INSERT INTO onb_attempts (course_id, employee_id, answers, score, passed, created_by)
    VALUES (c.id, p_employee_id, p_answers, coalesce(sc, 0), coalesce(sc, 0) >= c.pass_score, p_actor)
    RETURNING onb_attempts.id INTO v_id;
    IF coalesce(sc, 0) >= c.pass_score THEN
        UPDATE onb_tasks t SET status = 'done', done_at = now(), done_by = p_actor, updated_by = p_actor
        FROM onb_instances i, onb_template_items it
        WHERE t.instance_id = i.id AND t.item_id = it.id AND t.status = 'open'
          AND i.employee_id = p_employee_id AND it.kind = 'course' AND it.ref_code = p_course_code;
    END IF;
    RETURN v_id;
END $$;

-- Подтвердить ознакомление с действующей версией документа. Закрывает пункт онбординга.
CREATE OR REPLACE FUNCTION onb_ack(p_doc_code text, p_employee_id text, p_actor text)
RETURNS bigint LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE d_id bigint;
BEGIN
    SELECT id INTO d_id FROM v_onb_documents WHERE doc_code = p_doc_code;
    IF d_id IS NULL THEN RAISE EXCEPTION 'onboarding: документ % не найден', p_doc_code; END IF;
    INSERT INTO onb_acks (document_id, employee_id, created_by) VALUES (d_id, p_employee_id, p_actor)
    ON CONFLICT (document_id, employee_id) DO NOTHING;
    UPDATE onb_tasks t SET status = 'done', done_at = now(), done_by = p_actor, updated_by = p_actor
    FROM onb_instances i, onb_template_items it
    WHERE t.instance_id = i.id AND t.item_id = it.id AND t.status = 'open'
      AND i.employee_id = p_employee_id AND it.kind = 'document' AND it.ref_code = p_doc_code;
    RETURN d_id;
END $$;

-- Показатель: доля пунктов онбординга, выполненных в срок, по месяцу срока (due_date).
-- Считаются пункты со сроком в прошлом и уже выполненные; пропущенные (skipped) не считаются.
CREATE OR REPLACE VIEW m_onboarding_on_time_rate AS
SELECT 'onboarding_on_time_rate'::text AS metric_id,
       to_char(date_trunc('month', due_date), 'YYYY-MM') AS period,
       round(100.0 * count(*) FILTER (WHERE on_time) / NULLIF(count(*), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(round(100.0 * count(*) FILTER (WHERE on_time) / NULLIF(count(*), 0), 2),
           (airl_setting('onboarding', 'on_time_warn', '85'))::text::numeric,
           (airl_setting('onboarding', 'on_time_bad', '70'))::text::numeric,
           true) AS status
FROM v_onb_tasks
WHERE status <> 'skipped' AND (due_date < current_date OR status = 'done')
GROUP BY date_trunc('month', due_date);

-- Показатель: доля обязательных ознакомлений с действующими версиями, которые подтверждены.
-- Считаются только те, у кого срок ack_days уже прошёл; на текущий день.
CREATE OR REPLACE VIEW m_ack_coverage AS
SELECT 'ack_coverage'::text AS metric_id,
       to_char(current_date, 'YYYY-MM-DD') AS period,
       round(100.0 * count(*) FILTER (WHERE acked) / NULLIF(count(*), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(round(100.0 * count(*) FILTER (WHERE acked) / NULLIF(count(*), 0), 2),
           (airl_setting('onboarding', 'ack_warn', '95'))::text::numeric,
           (airl_setting('onboarding', 'ack_bad', '85'))::text::numeric,
           true) AS status
FROM v_onb_ack_status
WHERE acked OR ack_due < current_date;
