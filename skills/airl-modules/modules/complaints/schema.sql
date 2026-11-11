-- Модуль «Обращения и жалобы» (complaints). Требует kit/kit.sql в той же схеме
-- и представление src_cmp_clients (адаптер или demo_src.sql).

-- Категории обращений: свой срок (часы) и ответственная роль.
CREATE TABLE IF NOT EXISTS cmp_categories (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code             text        NOT NULL UNIQUE,
    title            text        NOT NULL,
    sla_hours        int         CHECK (sla_hours IS NULL OR sla_hours > 0),   -- NULL = по приоритету
    default_priority text        NOT NULL DEFAULT 'normal' CHECK (default_priority IN ('critical', 'high', 'normal', 'low')),
    owner_role       text,
    archived         boolean     NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       text        NOT NULL,
    updated_at       timestamptz,
    updated_by       text
);

CREATE TABLE IF NOT EXISTS cmp_cases (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_no          text        NOT NULL UNIQUE,
    kind             text        NOT NULL CHECK (kind IN ('complaint', 'claim', 'question', 'feedback', 'praise')),
    channel          text        NOT NULL CHECK (channel IN ('phone', 'telegram', 'site', 'email', 'instagram',
                                     'delivery_feedback', 'service', 'walk_in')),
    category_id      bigint      NOT NULL REFERENCES cmp_categories (id),
    client_id        text,                                -- ключ из src_cmp_clients; NULL — частное лицо без карточки
    contact_name     text,                                -- ПДн, только если клиента нет в src_cmp_clients
    contact_phone    text,                                -- ПДн
    subject          text        NOT NULL,
    description      text        NOT NULL,
    priority         text        NOT NULL DEFAULT 'normal' CHECK (priority IN ('critical', 'high', 'normal', 'low')),
    status           text        NOT NULL DEFAULT 'new'
                     CHECK (status IN ('new', 'in_progress', 'waiting_customer', 'resolved', 'closed', 'rejected')),
    responsible      text,
    due_at           timestamptz,                         -- срок по SLA, ставится сам при создании
    object_type      text        CHECK (object_type IN ('order', 'batch', 'equipment', 'delivery', 'service_request', 'product')),
    object_id        text,                                -- номер заказа, партии (PR из inspection-journal), оборудования
    root_cause       text,
    resolution       text,
    reject_reason    text,
    resolved_at      timestamptz,                         -- когда клиенту дан ответ с решением (или отказом)
    closed_at        timestamptz,
    escalation_level int         NOT NULL DEFAULT 0 CHECK (escalation_level BETWEEN 0 AND 2),
    csat             smallint    CHECK (csat BETWEEN 1 AND 5),
    csat_at          timestamptz,
    csat_comment     text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       text        NOT NULL,
    updated_at       timestamptz,
    updated_by       text,
    CHECK ((object_type IS NULL) = (object_id IS NULL)),
    CHECK (client_id IS NOT NULL OR contact_name IS NOT NULL OR channel IN ('site', 'instagram')),
    CHECK (status IN ('new', 'rejected') OR responsible IS NOT NULL),
    CHECK (status NOT IN ('resolved', 'closed') OR (resolution IS NOT NULL AND resolved_at IS NOT NULL)),
    CHECK (status <> 'rejected' OR (reject_reason IS NOT NULL AND resolved_at IS NOT NULL)),
    CHECK (status <> 'closed' OR closed_at IS NOT NULL),
    CHECK (csat IS NULL OR (csat_at IS NOT NULL AND status IN ('resolved', 'closed')))
);
CREATE INDEX IF NOT EXISTS cmp_cases_status_idx ON cmp_cases (status, due_at);
CREATE INDEX IF NOT EXISTS cmp_cases_object_idx ON cmp_cases (object_type, object_id);
CREATE INDEX IF NOT EXISTS cmp_cases_client_idx ON cmp_cases (client_id, created_at);

-- История переписки и внутренние заметки. Вложения — airl_attachments (entity = 'cmp_cases').
CREATE TABLE IF NOT EXISTS cmp_comments (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id     bigint      NOT NULL REFERENCES cmp_cases (id),
    visibility  text        NOT NULL DEFAULT 'internal' CHECK (visibility IN ('internal', 'customer')),
    body        text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);
CREATE INDEX IF NOT EXISTS cmp_comments_case_idx ON cmp_comments (case_id, created_at);

DROP TRIGGER IF EXISTS cmp_categories_touch ON cmp_categories;
CREATE TRIGGER cmp_categories_touch BEFORE UPDATE ON cmp_categories FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS cmp_cases_touch ON cmp_cases;
CREATE TRIGGER cmp_cases_touch BEFORE UPDATE ON cmp_cases FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS cmp_comments_touch ON cmp_comments;
CREATE TRIGGER cmp_comments_touch BEFORE UPDATE ON cmp_comments FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Срок по SLA при создании: часы категории, иначе часы по приоритету из настроек.
CREATE OR REPLACE FUNCTION cmp_set_due() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.due_at IS NULL THEN
        NEW.due_at := coalesce(NEW.created_at, now()) + make_interval(hours => coalesce(
            (SELECT c.sla_hours FROM cmp_categories c WHERE c.id = NEW.category_id),
            (airl_setting('complaints', 'sla_hours',
                '{"critical": 4, "high": 24, "normal": 48, "low": 120}') ->> NEW.priority)::int,
            48));
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS cmp_cases_due ON cmp_cases;
CREATE TRIGGER cmp_cases_due BEFORE INSERT ON cmp_cases FOR EACH ROW EXECUTE FUNCTION cmp_set_due();

-- Переходы статусов (схема из MODULE.md), отметки времени и журнал.
CREATE OR REPLACE FUNCTION cmp_status_guard() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT ((OLD.status = 'new'              AND NEW.status IN ('in_progress', 'rejected'))
             OR (OLD.status = 'in_progress'      AND NEW.status IN ('waiting_customer', 'resolved', 'rejected'))
             OR (OLD.status = 'waiting_customer' AND NEW.status IN ('in_progress', 'resolved'))
             OR (OLD.status = 'resolved'         AND NEW.status IN ('closed', 'in_progress'))) THEN
            RAISE EXCEPTION 'complaints: переход % → % не разрешён', OLD.status, NEW.status;
        END IF;
        CASE NEW.status
            WHEN 'resolved'    THEN NEW.resolved_at := coalesce(NEW.resolved_at, now());
            WHEN 'rejected'    THEN NEW.resolved_at := coalesce(NEW.resolved_at, now());
                                    NEW.closed_at   := coalesce(NEW.closed_at, now());
            WHEN 'closed'      THEN NEW.closed_at   := coalesce(NEW.closed_at, now());
            WHEN 'in_progress' THEN IF OLD.status = 'resolved' THEN NEW.resolved_at := NULL; END IF;
            ELSE NULL;
        END CASE;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (coalesce(NEW.updated_by, 'system'), 'complaints', 'cmp_cases', NEW.id::text,
                'status', OLD.status, NEW.status, coalesce(NEW.reject_reason, NEW.resolution));
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS cmp_cases_status ON cmp_cases;
CREATE TRIGGER cmp_cases_status BEFORE UPDATE ON cmp_cases FOR EACH ROW EXECUTE FUNCTION cmp_status_guard();

-- Журнал обращений.
CREATE OR REPLACE VIEW v_cmp_cases AS
SELECT k.id, k.case_no, k.kind, k.channel, c.code AS category, c.title AS category_title,
       k.client_id, coalesce(cl.client_name, k.contact_name) AS client_name, cl.city,
       k.subject, k.priority, k.status, k.responsible, k.object_type, k.object_id,
       k.created_at, k.due_at, k.resolved_at, k.closed_at,
       round(extract(epoch FROM k.due_at - now()) / 3600, 1) AS hours_left,
       (k.status IN ('new', 'in_progress', 'waiting_customer') AND now() > k.due_at) AS overdue,
       (coalesce(k.resolved_at, now()) > k.due_at AND k.kind <> 'praise') AS sla_breached,
       round(extract(epoch FROM k.resolved_at - k.created_at) / 3600, 1) AS hours_to_resolve,
       k.escalation_level, k.root_cause, k.resolution, k.reject_reason, k.csat, k.csat_comment
FROM cmp_cases k
JOIN cmp_categories c ON c.id = k.category_id
LEFT JOIN src_cmp_clients cl ON cl.client_id = k.client_id;

-- Экран «Очередь»: открытые обращения по сроку.
CREATE OR REPLACE VIEW v_cmp_queue AS
SELECT * FROM v_cmp_cases
WHERE status IN ('new', 'in_progress', 'waiting_customer');

-- Повторяющиеся проблемы за repeat_days: один объект (партия, заказ, машина)
-- или один клиент с одной категорией — два и более обращений.
CREATE OR REPLACE VIEW v_cmp_repeat AS
WITH recent AS (
    SELECT * FROM v_cmp_cases
    WHERE kind <> 'praise'
      AND created_at > now() - make_interval(days => (airl_setting('complaints', 'repeat_days', '90'))::text::int)
)
SELECT 'object'::text AS dimension, object_type || ':' || object_id AS key, min(category_title) AS category_title,
       count(*) AS cases, count(DISTINCT client_id) AS clients, min(created_at) AS first_at, max(created_at) AS last_at,
       string_agg(case_no, ', ' ORDER BY created_at) AS case_nos
FROM recent WHERE object_id IS NOT NULL
GROUP BY object_type, object_id HAVING count(*) >= 2
UNION ALL
SELECT 'client'::text, 'client:' || client_id || ' · ' || category, min(category_title),
       count(*), 1::bigint, min(created_at), max(created_at),
       string_agg(case_no, ', ' ORDER BY created_at)
FROM recent WHERE client_id IS NOT NULL
GROUP BY client_id, category HAVING count(*) >= 2;

-- Жалобы по партиям: для контроля качества (связь с inspection-journal по номеру партии).
CREATE OR REPLACE VIEW v_cmp_batches AS
SELECT object_id AS batch, count(*) AS cases,
       count(*) FILTER (WHERE status IN ('new', 'in_progress', 'waiting_customer')) AS open_cases,
       count(DISTINCT client_id) AS clients,
       min(created_at) AS first_at, max(created_at) AS last_at,
       string_agg(case_no || ' ' || subject, '; ' ORDER BY created_at) AS cases_list
FROM v_cmp_cases
WHERE object_type = 'batch'
GROUP BY object_id;

-- Сводка по месяцам и категориям.
CREATE OR REPLACE VIEW v_cmp_monthly AS
SELECT to_char(date_trunc('month', created_at), 'YYYY-MM') AS month, category, category_title,
       count(*) AS cases,
       count(*) FILTER (WHERE sla_breached AND status <> 'waiting_customer') AS sla_breached,
       round(avg(hours_to_resolve), 1) AS avg_hours_to_resolve,
       round(avg(csat), 2) AS csat_avg
FROM v_cmp_cases
GROUP BY date_trunc('month', created_at), category, category_title;

-- Эскалация: просрочка SLA — ответственному и escalate_l1; через escalate_l2_hours
-- после срока — escalate_l2. Одно уведомление на обращение, уровень и получателя.
CREATE OR REPLACE FUNCTION cmp_escalate() RETURNS int LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE n int;
BEGIN
    WITH due AS (
        SELECT k.id, k.case_no, k.subject, k.responsible, k.escalation_level,
               CASE WHEN now() > k.due_at + make_interval(hours => (airl_setting('complaints', 'escalate_l2_hours', '24'))::text::int)
                    THEN 2 ELSE 1 END AS level
        FROM cmp_cases k
        WHERE k.status IN ('new', 'in_progress', 'waiting_customer') AND now() > k.due_at
    ), rcpt AS (
        SELECT d.*, r.recipient, r.lvl
        FROM due d
        CROSS JOIN LATERAL (VALUES
            (coalesce(d.responsible, ''), 1),
            (airl_setting('complaints', 'escalate_l1', '"head_support"') #>> '{}', 1),
            (airl_setting('complaints', 'escalate_l2', '"ceo"') #>> '{}', 2)) AS r(recipient, lvl)
        WHERE r.lvl <= d.level AND r.recipient <> ''
    ), ins AS (
        INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
        SELECT 'complaints:sla_l' || lvl || ':' || id || ':' || recipient, 'complaints',
               airl_setting('complaints', 'notify_channel', '"in_app"') #>> '{}', recipient,
               'Обращение ' || case_no || ' «' || subject || '» просрочено'
               || CASE WHEN lvl = 2 THEN ' больше чем на сутки' ELSE '' END
        FROM rcpt
        ON CONFLICT (dedup_key) DO NOTHING
        RETURNING 1
    )
    SELECT count(*) INTO n FROM ins;
    UPDATE cmp_cases k SET escalation_level = d.level, updated_by = 'system'
    FROM (SELECT id, CASE WHEN now() > due_at + make_interval(hours => (airl_setting('complaints', 'escalate_l2_hours', '24'))::text::int)
                          THEN 2 ELSE 1 END AS level
          FROM cmp_cases WHERE status IN ('new', 'in_progress', 'waiting_customer') AND now() > due_at) d
    WHERE k.id = d.id AND k.escalation_level < d.level;
    RETURN n;
END $$;

-- Показатель: доля обращений, по которым ответ с решением дан позже срока, по месяцу срока (due_at).
-- Открытые обращения с прошедшим сроком тоже считаются нарушением. Благодарности не считаются.
CREATE OR REPLACE VIEW m_complaint_sla_breach_rate AS
SELECT 'complaint_sla_breach_rate'::text AS metric_id,
       to_char(date_trunc('month', due_at), 'YYYY-MM') AS period,
       round(100.0 * count(*) FILTER (WHERE coalesce(resolved_at, now()) > due_at) / NULLIF(count(*), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(
           round(100.0 * count(*) FILTER (WHERE coalesce(resolved_at, now()) > due_at) / NULLIF(count(*), 0), 2),
           (airl_setting('complaints', 'sla_breach_warn', '10'))::text::numeric,
           (airl_setting('complaints', 'sla_breach_bad', '20'))::text::numeric,
           false) AS status
FROM cmp_cases
WHERE kind <> 'praise' AND due_at <= now()
GROUP BY date_trunc('month', due_at);

-- Показатель: средняя оценка клиента (1–5) по месяцу оценки (csat_at).
CREATE OR REPLACE VIEW m_csat_avg AS
SELECT 'csat_avg'::text AS metric_id,
       to_char(date_trunc('month', csat_at), 'YYYY-MM') AS period,
       round(avg(csat), 2) AS value,
       'балл'::text AS unit,
       airl_traffic(round(avg(csat), 2),
           (airl_setting('complaints', 'csat_warn', '4.2'))::text::numeric,
           (airl_setting('complaints', 'csat_bad', '3.8'))::text::numeric,
           true) AS status
FROM cmp_cases
WHERE csat IS NOT NULL
GROUP BY date_trunc('month', csat_at);
