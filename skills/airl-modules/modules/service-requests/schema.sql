-- Модуль «Сервисные заявки» (service-requests). Требует kit/kit.sql в той же схеме
-- и представления src_clients, src_parts (адаптер или demo_src.sql).
-- Запчасти модуль только учитывает; списание со склада в учётной системе делает человек.

-- Паспорт оборудования.
CREATE TABLE IF NOT EXISTS svc_equipment (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equipment_no    text        NOT NULL UNIQUE,          -- внутренний номер (наклейка на корпусе)
    kind            text        NOT NULL CHECK (kind IN ('espresso_machine', 'grinder', 'water_filter',
                                    'brewer', 'medical_device', 'other')),
    model           text        NOT NULL,
    serial_no       text,
    client_id       text        NOT NULL,                 -- ключ из src_clients
    address         text,                                 -- адрес установки, если отличается от клиента
    owner           text        NOT NULL DEFAULT 'client' CHECK (owner IN ('client', 'company')),
    installed_at    date,
    warranty_until  date,
    archived        boolean     NOT NULL DEFAULT false,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      text        NOT NULL,
    updated_at      timestamptz,
    updated_by      text
);
CREATE INDEX IF NOT EXISTS svc_equipment_client_idx ON svc_equipment (client_id);

-- Заявки.
CREATE TABLE IF NOT EXISTS svc_requests (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_no    text        NOT NULL UNIQUE,
    kind          text        NOT NULL CHECK (kind IN ('repair', 'maintenance', 'installation', 'barista_service', 'other')),
    equipment_id  bigint      REFERENCES svc_equipment (id),
    client_id     text        NOT NULL,
    problem       text        NOT NULL,
    priority      text        NOT NULL DEFAULT 'normal' CHECK (priority IN ('critical', 'high', 'normal', 'low')),
    source        text        NOT NULL CHECK (source IN ('phone', 'telegram', 'site', 'sales_manager', 'planned')),
    status        text        NOT NULL DEFAULT 'new'
                  CHECK (status IN ('new', 'assigned', 'in_progress', 'waiting_parts', 'done', 'closed', 'cancelled')),
    technician    text,
    planned_at    timestamptz,
    due_at        timestamptz,                            -- срок по SLA, ставится сам при создании
    assigned_at   timestamptz,
    started_at    timestamptz,
    done_at       timestamptz,
    closed_at     timestamptz,
    resolution    text,
    cancel_reason text,
    billable      boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL,
    updated_at    timestamptz,
    updated_by    text,
    CHECK (status IN ('new', 'cancelled') OR technician IS NOT NULL),
    CHECK (status NOT IN ('done', 'closed') OR (done_at IS NOT NULL AND resolution IS NOT NULL)),
    CHECK (status <> 'closed' OR closed_at IS NOT NULL),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL),
    CHECK (kind IN ('barista_service', 'other') OR equipment_id IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS svc_requests_equipment_idx ON svc_requests (equipment_id, created_at);
CREATE INDEX IF NOT EXISTS svc_requests_status_idx ON svc_requests (status, due_at);

-- Запчасти по заявке. written_off_ref — номер документа списания в учётной системе.
CREATE TABLE IF NOT EXISTS svc_parts_used (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id       bigint        NOT NULL REFERENCES svc_requests (id),
    sku              text          NOT NULL,              -- ключ из src_parts
    qty              numeric(18,3) NOT NULL CHECK (qty > 0),
    written_off_ref  text,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    created_by       text          NOT NULL,
    updated_at       timestamptz,
    updated_by       text,
    UNIQUE (request_id, sku)
);

-- Сервисный акт. Фото — в airl_attachments (entity = 'svc_acts').
CREATE TABLE IF NOT EXISTS svc_acts (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    act_no            text        NOT NULL UNIQUE,
    request_id        bigint      NOT NULL UNIQUE REFERENCES svc_requests (id),
    work_done         text        NOT NULL,
    labor_minutes     int         CHECK (labor_minutes IS NULL OR labor_minutes >= 0),
    signer_name       text,                               -- кто принял работу у клиента (ПДн)
    confirm_method    text        CHECK (confirm_method IN ('code', 'signature', 'paper')),
    confirm_code_hash text,                               -- хеш одноразового кода, сам код не храним
    confirmed_at      timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        text        NOT NULL,
    updated_at        timestamptz,
    updated_by        text,
    CHECK (confirmed_at IS NULL OR (signer_name IS NOT NULL AND confirm_method IS NOT NULL))
);

-- План обслуживания: раз в interval_days по оборудованию.
CREATE TABLE IF NOT EXISTS svc_maint_plans (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    equipment_id  bigint      NOT NULL UNIQUE REFERENCES svc_equipment (id),
    interval_days int         NOT NULL CHECK (interval_days > 0),
    next_due      date        NOT NULL,
    work_template text        NOT NULL,
    active        boolean     NOT NULL DEFAULT true,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL,
    updated_at    timestamptz,
    updated_by    text
);

DROP TRIGGER IF EXISTS svc_equipment_touch ON svc_equipment;
CREATE TRIGGER svc_equipment_touch BEFORE UPDATE ON svc_equipment FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS svc_requests_touch ON svc_requests;
CREATE TRIGGER svc_requests_touch BEFORE UPDATE ON svc_requests FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS svc_parts_used_touch ON svc_parts_used;
CREATE TRIGGER svc_parts_used_touch BEFORE UPDATE ON svc_parts_used FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS svc_acts_touch ON svc_acts;
CREATE TRIGGER svc_acts_touch BEFORE UPDATE ON svc_acts FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS svc_maint_plans_touch ON svc_maint_plans;
CREATE TRIGGER svc_maint_plans_touch BEFORE UPDATE ON svc_maint_plans FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Срок по SLA при создании: от planned_at (плановое) или от created_at, часы по приоритету.
CREATE OR REPLACE FUNCTION svc_set_due() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.due_at IS NULL THEN
        NEW.due_at := coalesce(NEW.planned_at, NEW.created_at, now())
            + make_interval(hours => coalesce(
                (airl_setting('service-requests', 'sla_hours',
                    '{"critical": 8, "high": 24, "normal": 72, "low": 168}') ->> NEW.priority)::int, 72));
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS svc_requests_due ON svc_requests;
CREATE TRIGGER svc_requests_due BEFORE INSERT ON svc_requests FOR EACH ROW EXECUTE FUNCTION svc_set_due();

-- Переходы статусов (схема из MODULE.md), отметки времени и журнал.
CREATE OR REPLACE FUNCTION svc_status_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT ((OLD.status = 'new'           AND NEW.status IN ('assigned', 'cancelled'))
             OR (OLD.status = 'assigned'      AND NEW.status IN ('in_progress', 'cancelled'))
             OR (OLD.status = 'in_progress'   AND NEW.status IN ('waiting_parts', 'done', 'cancelled'))
             OR (OLD.status = 'waiting_parts' AND NEW.status IN ('in_progress', 'cancelled'))
             OR (OLD.status = 'done'          AND NEW.status IN ('closed', 'in_progress'))) THEN
            RAISE EXCEPTION 'service-requests: переход % → % не разрешён', OLD.status, NEW.status;
        END IF;
        IF NEW.status = 'closed' AND NOT EXISTS (
            SELECT 1 FROM svc_acts a WHERE a.request_id = NEW.id AND a.confirmed_at IS NOT NULL) THEN
            RAISE EXCEPTION 'service-requests: закрыть можно только после подтверждения акта клиентом';
        END IF;
        CASE NEW.status
            WHEN 'assigned'    THEN NEW.assigned_at := coalesce(NEW.assigned_at, now());
            WHEN 'in_progress' THEN NEW.started_at  := coalesce(NEW.started_at, now()); NEW.done_at := NULL;
            WHEN 'done'        THEN NEW.done_at     := coalesce(NEW.done_at, now());
            WHEN 'closed'      THEN NEW.closed_at   := coalesce(NEW.closed_at, now());
            ELSE NULL;
        END CASE;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (coalesce(NEW.updated_by, 'system'), 'service-requests', 'svc_requests', NEW.id::text,
                'status', OLD.status, NEW.status, coalesce(NEW.cancel_reason, NEW.resolution));
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS svc_requests_status ON svc_requests;
CREATE TRIGGER svc_requests_status BEFORE UPDATE ON svc_requests FOR EACH ROW EXECUTE FUNCTION svc_status_guard();

-- Повторная поломка: ремонт того же оборудования, начатый в течение repeat_days
-- после завершения предыдущего ремонта.
CREATE OR REPLACE VIEW v_svc_repeat AS
SELECT r.id, r.request_no, r.equipment_id, r.client_id, r.created_at, r.problem,
       p.request_no AS prev_request_no, p.done_at AS prev_done_at, p.technician AS prev_technician,
       (r.created_at::date - p.done_at::date) AS days_after_prev
FROM svc_requests r
JOIN LATERAL (
    SELECT q.request_no, q.done_at, q.technician
    FROM svc_requests q
    WHERE q.equipment_id = r.equipment_id AND q.id <> r.id AND q.kind = 'repair'
      AND q.done_at IS NOT NULL AND q.done_at < r.created_at
    ORDER BY q.done_at DESC LIMIT 1
) p ON true
WHERE r.kind = 'repair' AND r.status <> 'cancelled'
  AND r.created_at - p.done_at <= make_interval(days => (airl_setting('service-requests', 'repeat_days', '30'))::text::int);

-- Экран «Заявки»: все заявки с клиентом, оборудованием, сроком и флагами.
CREATE OR REPLACE VIEW v_svc_requests AS
SELECT r.id, r.request_no, r.kind, r.status, r.priority, r.source, r.problem,
       r.client_id, c.client_name, c.city, coalesce(e.address, c.address) AS address,
       r.equipment_id, e.equipment_no, e.model, e.serial_no,
       (e.warranty_until IS NOT NULL AND e.warranty_until >= r.created_at::date) AS under_warranty,
       r.technician, r.planned_at, r.due_at, r.created_at, r.assigned_at, r.started_at, r.done_at, r.closed_at,
       r.resolution, r.cancel_reason,
       (r.status NOT IN ('done', 'closed', 'cancelled') AND now() > r.due_at) AS overdue,
       (coalesce(r.done_at, now()) > r.due_at AND r.status <> 'cancelled') AS sla_breached,
       EXISTS (SELECT 1 FROM v_svc_repeat x WHERE x.id = r.id) AS is_repeat
FROM svc_requests r
LEFT JOIN svc_equipment e ON e.id = r.equipment_id
LEFT JOIN src_clients c ON c.client_id = r.client_id;

-- Экран «Мои заявки» техника: открытые, по сроку.
CREATE OR REPLACE VIEW v_svc_open AS
SELECT * FROM v_svc_requests
WHERE status IN ('new', 'assigned', 'in_progress', 'waiting_parts');

-- Экран «Оборудование»: паспорт и история.
CREATE OR REPLACE VIEW v_svc_equipment AS
SELECT e.id, e.equipment_no, e.kind, e.model, e.serial_no, e.client_id, c.client_name,
       coalesce(e.address, c.address) AS address, e.owner, e.installed_at, e.warranty_until,
       (e.warranty_until >= current_date) AS under_warranty,
       (SELECT max(r.done_at) FROM svc_requests r WHERE r.equipment_id = e.id AND r.kind = 'maintenance') AS last_maintenance_at,
       mp.next_due AS next_maintenance_due,
       (SELECT count(*) FROM svc_requests r WHERE r.equipment_id = e.id AND r.kind = 'repair'
          AND r.status <> 'cancelled' AND r.created_at > now() - interval '12 months') AS repairs_12m,
       (SELECT count(*) FROM v_svc_repeat x WHERE x.equipment_id = e.id) AS repeat_breakdowns,
       e.archived
FROM svc_equipment e
LEFT JOIN src_clients c ON c.client_id = e.client_id
LEFT JOIN svc_maint_plans mp ON mp.equipment_id = e.id AND mp.active;

-- Запчасти по заявкам: что использовано и что ещё не списано в учёте.
CREATE OR REPLACE VIEW v_svc_parts AS
SELECT pu.id, r.request_no, r.status AS request_status, pu.sku, p.part_name, pu.qty, p.unit,
       pu.written_off_ref, (pu.written_off_ref IS NULL) AS awaiting_write_off, pu.created_at, pu.created_by
FROM svc_parts_used pu
JOIN svc_requests r ON r.id = pu.request_id
LEFT JOIN src_parts p ON p.sku = pu.sku;

-- Загрузка техников за текущий месяц.
CREATE OR REPLACE VIEW v_svc_technicians AS
SELECT r.technician,
       count(*) FILTER (WHERE r.status IN ('assigned', 'in_progress', 'waiting_parts')) AS open_requests,
       count(*) FILTER (WHERE r.done_at >= date_trunc('month', now())) AS done_this_month,
       round(avg(extract(epoch FROM r.done_at - r.created_at) / 3600)
             FILTER (WHERE r.done_at >= date_trunc('month', now()) - interval '2 months'), 1) AS avg_hours_to_done,
       coalesce(sum(a.labor_minutes) FILTER (WHERE r.done_at >= date_trunc('month', now())), 0) AS labor_minutes_this_month
FROM svc_requests r
LEFT JOIN svc_acts a ON a.request_id = r.id
WHERE r.technician IS NOT NULL
GROUP BY r.technician;

-- Создать плановые заявки на ТО на горизонт plan_horizon_days. Повторный вызов дублей не создаёт.
CREATE OR REPLACE FUNCTION svc_generate_planned(p_actor text) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    pl record;
    n  int := 0;
    k  int;
BEGIN
    FOR pl IN
        SELECT mp.id, mp.equipment_id, mp.next_due, mp.interval_days, mp.work_template, e.equipment_no, e.client_id
        FROM svc_maint_plans mp
        JOIN svc_equipment e ON e.id = mp.equipment_id AND NOT e.archived
        WHERE mp.active
          AND mp.next_due <= current_date + (airl_setting('service-requests', 'plan_horizon_days', '14'))::text::int
    LOOP
        INSERT INTO svc_requests (request_no, kind, equipment_id, client_id, problem, priority, source,
                                  planned_at, created_by)
        VALUES ('PM-' || pl.equipment_no || '-' || to_char(pl.next_due, 'YYYYMMDD'), 'maintenance',
                pl.equipment_id, pl.client_id, pl.work_template, 'low', 'planned',
                pl.next_due::timestamptz + interval '10 hours', p_actor)
        ON CONFLICT (request_no) DO NOTHING;
        GET DIAGNOSTICS k = ROW_COUNT;
        n := n + k;
        UPDATE svc_maint_plans SET next_due = pl.next_due + pl.interval_days, updated_by = p_actor
        WHERE id = pl.id;
    END LOOP;
    RETURN n;
END $$;

-- Поставить в очередь уведомления о просрочке SLA: одно на заявку и получателя.
CREATE OR REPLACE FUNCTION svc_notify_overdue() RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'service-requests:sla_breach:' || v.id || ':' || rcpt.r,
           'service-requests',
           airl_setting('service-requests', 'notify_channel', '"in_app"') #>> '{}',
           rcpt.r,
           'Заявка ' || v.request_no || ' (' || coalesce(v.client_name, v.client_id) || ') просрочена по SLA'
    FROM v_svc_open v
    CROSS JOIN LATERAL (VALUES (coalesce(v.technician, '')),
                               (airl_setting('service-requests', 'escalate_to', '"head_service"') #>> '{}')) AS rcpt(r)
    WHERE v.overdue AND rcpt.r <> ''
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;

-- Показатель: доля заявок, выполненных позже срока SLA, по месяцу выполнения (done_at).
CREATE OR REPLACE VIEW m_service_sla_breach_rate AS
SELECT 'service_sla_breach_rate'::text AS metric_id,
       to_char(date_trunc('month', done_at), 'YYYY-MM') AS period,
       round(100.0 * count(*) FILTER (WHERE done_at > due_at) / NULLIF(count(*), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(
           round(100.0 * count(*) FILTER (WHERE done_at > due_at) / NULLIF(count(*), 0), 2),
           (airl_setting('service-requests', 'sla_breach_warn', '10'))::text::numeric,
           (airl_setting('service-requests', 'sla_breach_bad', '20'))::text::numeric,
           false) AS status
FROM svc_requests
WHERE done_at IS NOT NULL AND status IN ('done', 'closed')
GROUP BY date_trunc('month', done_at);

-- Показатель: доля повторных поломок среди ремонтов, по месяцу создания заявки.
CREATE OR REPLACE VIEW m_repeat_breakdown_rate AS
SELECT 'repeat_breakdown_rate'::text AS metric_id,
       to_char(date_trunc('month', r.created_at), 'YYYY-MM') AS period,
       round(100.0 * count(x.id) / NULLIF(count(*), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(
           round(100.0 * count(x.id) / NULLIF(count(*), 0), 2),
           (airl_setting('service-requests', 'repeat_warn', '5'))::text::numeric,
           (airl_setting('service-requests', 'repeat_bad', '10'))::text::numeric,
           false) AS status
FROM svc_requests r
LEFT JOIN v_svc_repeat x ON x.id = r.id
WHERE r.kind = 'repair' AND r.status <> 'cancelled'
GROUP BY date_trunc('month', r.created_at);
