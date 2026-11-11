-- Модуль «Журнал проверок» (inspection-journal). Требует kit/kit.sql в той же схеме
-- и представление src_inspection_objects (адаптер или demo_src.sql).

CREATE TABLE IF NOT EXISTS insp_templates (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text        NOT NULL UNIQUE,
    title       text        NOT NULL,
    object_type text        NOT NULL,
    sku         text,                          -- шаблон для конкретного продукта или NULL для всех
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);

CREATE TABLE IF NOT EXISTS insp_template_items (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    template_id bigint      NOT NULL REFERENCES insp_templates (id),
    ord         int         NOT NULL,
    code        text        NOT NULL,
    title       text        NOT NULL,
    kind        text        NOT NULL CHECK (kind IN ('number', 'pass_fail', 'text', 'choice')),
    unit        text,
    target      numeric,
    min_value   numeric,
    max_value   numeric,
    choices     text[],
    required    boolean     NOT NULL DEFAULT true,
    UNIQUE (template_id, code),
    CHECK (kind <> 'number' OR min_value IS NULL OR max_value IS NULL OR min_value <= max_value)
);

CREATE TABLE IF NOT EXISTS insp_checks (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    check_no     text        NOT NULL UNIQUE,
    object_id    text        NOT NULL,
    template_id  bigint      NOT NULL REFERENCES insp_templates (id),
    status       text        NOT NULL DEFAULT 'draft'
                 CHECK (status IN ('draft', 'passed', 'rejected')),
    disposition  text
                 CHECK (disposition IN ('quarantine', 'rework', 'conditional_release', 'written_off')),
    comment      text,
    checked_at   timestamptz,
    checked_by   text,
    decided_at   timestamptz,
    decided_by   text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text        NOT NULL,
    updated_at   timestamptz,
    updated_by   text,
    CHECK (status = 'draft' OR (checked_at IS NOT NULL AND checked_by IS NOT NULL)),
    CHECK (status <> 'rejected' OR comment IS NOT NULL),
    CHECK (disposition IS NULL OR status = 'rejected')
);
CREATE INDEX IF NOT EXISTS insp_checks_object_idx ON insp_checks (object_id, checked_at);

CREATE TABLE IF NOT EXISTS insp_results (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    check_id    bigint      NOT NULL REFERENCES insp_checks (id),
    item_id     bigint      NOT NULL REFERENCES insp_template_items (id),
    value_num   numeric,
    value_text  text,
    passed      boolean,
    UNIQUE (check_id, item_id)
);

CREATE TABLE IF NOT EXISTS insp_actions (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    check_id    bigint      REFERENCES insp_checks (id),
    kind        text        NOT NULL CHECK (kind IN ('corrective', 'preventive')),
    description text        NOT NULL,
    owner       text        NOT NULL,
    due_date    date        NOT NULL,
    status      text        NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done', 'cancelled')),
    done_at     timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);

DROP TRIGGER IF EXISTS insp_checks_touch ON insp_checks;
CREATE TRIGGER insp_checks_touch BEFORE UPDATE ON insp_checks FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS insp_actions_touch ON insp_actions;
CREATE TRIGGER insp_actions_touch BEFORE UPDATE ON insp_actions FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Последняя завершённая проверка каждого объекта.
CREATE OR REPLACE VIEW v_insp_last_check AS
SELECT DISTINCT ON (c.object_id) c.*
FROM insp_checks c
WHERE c.status IN ('passed', 'rejected')
ORDER BY c.object_id, c.checked_at DESC, c.id DESC;

-- Экран «Ждут проверки»: объекты без завершённой проверки.
CREATE OR REPLACE VIEW v_insp_pending AS
SELECT o.object_id, o.object_type, o.title, o.sku, o.lot, o.produced_at, o.produced_by, o.branch_id,
       now() - o.produced_at AS waiting,
       (now() - o.produced_at) > make_interval(hours => (airl_setting('inspection-journal', 'overdue_hours', '24'))::text::int) AS overdue
FROM src_inspection_objects o
LEFT JOIN v_insp_last_check lc ON lc.object_id = o.object_id
WHERE lc.id IS NULL;

-- Экран журнала.
CREATE OR REPLACE VIEW v_insp_journal AS
SELECT c.id, c.check_no, c.object_id, o.title, o.sku, o.lot, o.branch_id, t.title AS template,
       c.status, c.disposition, c.comment, c.checked_at, c.checked_by, c.decided_at, c.decided_by
FROM insp_checks c
JOIN insp_templates t ON t.id = c.template_id
LEFT JOIN src_inspection_objects o ON o.object_id = c.object_id;

-- Экран «Отклонённые»: реестр с решением.
CREATE OR REPLACE VIEW v_insp_rejected AS
SELECT j.*, (j.disposition IS NULL) AS awaiting_decision
FROM v_insp_journal j
WHERE j.status = 'rejected';

-- Экран «Стабильность»: числовые замеры относительно цели и допуска по продукту.
CREATE OR REPLACE VIEW v_insp_stability AS
SELECT o.sku, i.code AS item_code, i.title AS item, i.unit, i.target, i.min_value, i.max_value,
       c.checked_at, r.value_num,
       (r.value_num < i.min_value OR r.value_num > i.max_value) AS out_of_tolerance
FROM insp_results r
JOIN insp_checks c ON c.id = r.check_id AND c.status IN ('passed', 'rejected')
JOIN insp_template_items i ON i.id = r.item_id AND i.kind = 'number'
LEFT JOIN src_inspection_objects o ON o.object_id = c.object_id;

-- Показатель: доля отклонённых по месяцам (последняя проверка объекта).
CREATE OR REPLACE VIEW m_qc_reject_rate AS
SELECT 'qc_reject_rate'::text AS metric_id,
       to_char(date_trunc('month', checked_at), 'YYYY-MM') AS period,
       round(100.0 * count(*) FILTER (WHERE status = 'rejected') / NULLIF(count(*), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(
           round(100.0 * count(*) FILTER (WHERE status = 'rejected') / NULLIF(count(*), 0), 2),
           (airl_setting('inspection-journal', 'reject_warn', '3'))::text::numeric,
           (airl_setting('inspection-journal', 'reject_bad', '7'))::text::numeric,
           false) AS status
FROM v_insp_last_check
GROUP BY date_trunc('month', checked_at);

-- Показатель: объекты без проверки сверх срока, на текущий момент.
CREATE OR REPLACE VIEW m_qc_unchecked_overdue AS
SELECT 'qc_unchecked_overdue'::text AS metric_id,
       to_char(now(), 'YYYY-MM-DD') AS period,
       count(*) FILTER (WHERE overdue)::numeric AS value,
       'шт'::text AS unit,
       airl_traffic(count(*) FILTER (WHERE overdue), 1, 4, false) AS status
FROM v_insp_pending;

-- Экран «Действия»: корректирующие и предупреждающие действия, просроченные сверху.
CREATE OR REPLACE VIEW v_insp_actions AS
SELECT a.id, a.kind, a.description, a.owner, a.due_date, a.status, a.done_at,
       c.check_no, c.object_id,
       (a.status = 'open' AND a.due_date < current_date) AS overdue
FROM insp_actions a
LEFT JOIN insp_checks c ON c.id = a.check_id;
