-- Модуль «Запись и напоминания» (appointments). Требует kit/kit.sql в той же схеме
-- и представление src_apt_resources (адаптер или demo_src.sql).
-- Сведения о здоровье — особая категория: модуль не хранит диагнозы и жалобы,
-- а в сообщения пациенту уходит только время и название организации.

-- Пациенты (клиенты). Ключ — внутренний id; телефон НЕ уникален (один номер на семью).
CREATE TABLE IF NOT EXISTS apt_customers (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_no        text        NOT NULL UNIQUE,         -- номер карты в клинике
    display_name       text        NOT NULL,                -- как обращаться (ПДн)
    phone              text        CHECK (phone ~ '^\+[0-9]{10,15}$'),   -- международный формат (ПДн)
    birth_date         date,                                -- ПДн, чтобы различать членов семьи
    preferred_language text        NOT NULL DEFAULT 'ru' CHECK (preferred_language IN ('ru', 'uz', 'kk')),
    telegram_user_id   bigint,                              -- после того как пациент сам поделился контактом
    external_id        text,                                -- id в МИС, если есть
    archived           boolean     NOT NULL DEFAULT false,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         text        NOT NULL,
    updated_at         timestamptz,
    updated_by         text
);
CREATE INDEX IF NOT EXISTS apt_customers_phone_idx ON apt_customers (phone);
CREATE INDEX IF NOT EXISTS apt_customers_tg_idx ON apt_customers (telegram_user_id);

-- Согласия: только добавление. Действует последняя запись по виду.
-- processing — обработка данных; telegram / sms / call — сообщения по инициативе клиники.
CREATE TABLE IF NOT EXISTS apt_consents (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id     bigint      NOT NULL REFERENCES apt_customers (id),
    kind            text        NOT NULL CHECK (kind IN ('processing', 'telegram', 'sms', 'call')),
    granted         boolean     NOT NULL,
    consent_version text        NOT NULL,                   -- версия текста согласия
    given_at        timestamptz NOT NULL DEFAULT now(),
    source          text        NOT NULL CHECK (source IN ('telegram_bot', 'reception', 'paper', 'site')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      text        NOT NULL,
    updated_at      timestamptz,
    updated_by      text
);
CREATE INDEX IF NOT EXISTS apt_consents_customer_idx ON apt_consents (customer_id, kind, given_at);

-- Рабочее время врача или кабинета. Вносит старший администратор или загрузчик из МИС.
CREATE TABLE IF NOT EXISTS apt_shifts (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    resource_id text        NOT NULL,                       -- ключ из src_apt_resources
    starts_at   timestamptz NOT NULL,
    ends_at     timestamptz NOT NULL,
    source      text        NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'import')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    UNIQUE (resource_id, starts_at),
    CHECK (ends_at > starts_at)
);

CREATE TABLE IF NOT EXISTS apt_appointments (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appt_no       text        NOT NULL UNIQUE,
    customer_id   bigint      NOT NULL REFERENCES apt_customers (id),
    resource_id   text        NOT NULL,
    starts_at     timestamptz NOT NULL,
    ends_at       timestamptz NOT NULL,
    status        text        NOT NULL DEFAULT 'booked'
                  CHECK (status IN ('booked', 'confirmed', 'arrived', 'done', 'no_show',
                                    'cancelled_by_patient', 'cancelled_by_clinic')),
    source        text        NOT NULL CHECK (source IN ('phone', 'telegram', 'walk_in', 'site')),
    confirmed_at  timestamptz,
    arrived_at    timestamptz,
    cancelled_at  timestamptz,
    cancel_reason text        CHECK (cancel_reason IN ('patient_request', 'no_answer', 'doctor_unavailable',
                                                       'duplicate', 'rescheduled', 'other')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL,
    updated_at    timestamptz,
    updated_by    text,
    CHECK (ends_at > starts_at),
    CHECK (status NOT IN ('cancelled_by_patient', 'cancelled_by_clinic') OR (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS apt_appointments_resource_idx ON apt_appointments (resource_id, starts_at);
CREATE INDEX IF NOT EXISTS apt_appointments_customer_idx ON apt_appointments (customer_id, starts_at);

-- Ответы на напоминания и итог обзвона.
CREATE TABLE IF NOT EXISTS apt_responses (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id bigint      NOT NULL REFERENCES apt_appointments (id),
    channel        text        NOT NULL CHECK (channel IN ('telegram', 'sms', 'call')),
    response       text        NOT NULL CHECK (response IN ('confirm', 'reschedule', 'cancel', 'no_answer')),
    received_at    timestamptz NOT NULL DEFAULT now(),
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     text        NOT NULL,                    -- 'bot' или пользователь регистратуры
    updated_at     timestamptz,
    updated_by     text
);
CREATE INDEX IF NOT EXISTS apt_responses_appt_idx ON apt_responses (appointment_id, received_at);

-- Список «пора на повторный приём». Причина — только из списка, без диагнозов.
CREATE TABLE IF NOT EXISTS apt_recalls (
    id                    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id           bigint      NOT NULL REFERENCES apt_customers (id),
    resource_id           text,
    due_date              date        NOT NULL,
    reason                text        NOT NULL CHECK (reason IN ('follow_up', 'periodic_check', 'other')),
    status                text        NOT NULL DEFAULT 'due' CHECK (status IN ('due', 'contacted', 'booked', 'declined', 'cancelled')),
    source_appointment_id bigint      REFERENCES apt_appointments (id),
    booked_appointment_id bigint      REFERENCES apt_appointments (id),
    contacted_at          timestamptz,
    created_at            timestamptz NOT NULL DEFAULT now(),
    created_by            text        NOT NULL,
    updated_at            timestamptz,
    updated_by            text,
    UNIQUE (customer_id, due_date, reason),
    CHECK (status <> 'booked' OR booked_appointment_id IS NOT NULL)
);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['apt_customers', 'apt_shifts', 'apt_appointments', 'apt_responses', 'apt_recalls'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_touch', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION airl_touch()', t || '_touch', t);
    END LOOP;
END $$;

-- Запись согласия неизменяема: отзыв — новая строка с granted = false.
CREATE OR REPLACE FUNCTION apt_consents_readonly() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    RAISE EXCEPTION 'appointments: запись согласия менять и удалять нельзя — добавьте новую';
END $$;
DROP TRIGGER IF EXISTS apt_consents_readonly ON apt_consents;
CREATE TRIGGER apt_consents_readonly BEFORE UPDATE OR DELETE ON apt_consents FOR EACH ROW EXECUTE FUNCTION apt_consents_readonly();

-- Защита от двойной записи: у врача (кабинета) не может быть двух действующих записей
-- на пересекающееся время. Блокировка по врачу — от одновременной записи из бота и регистратуры.
CREATE OR REPLACE FUNCTION apt_no_overlap() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.status IN ('booked', 'confirmed', 'arrived', 'done', 'no_show') THEN
        PERFORM pg_advisory_xact_lock(hashtext('appointments:' || NEW.resource_id));
        IF EXISTS (SELECT 1 FROM apt_appointments a
                   WHERE a.resource_id = NEW.resource_id AND a.appt_no <> NEW.appt_no
                     AND a.status IN ('booked', 'confirmed', 'arrived', 'done', 'no_show')
                     AND a.starts_at > NEW.starts_at - interval '1 day'
                     AND a.starts_at < NEW.ends_at AND a.ends_at > NEW.starts_at) THEN
            RAISE EXCEPTION 'appointments: время % уже занято', NEW.starts_at USING ERRCODE = 'unique_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS apt_appointments_overlap ON apt_appointments;
CREATE TRIGGER apt_appointments_overlap BEFORE INSERT OR UPDATE OF starts_at, ends_at, resource_id, status
    ON apt_appointments FOR EACH ROW EXECUTE FUNCTION apt_no_overlap();

-- Переходы статусов, отметки времени, журнал; отмена снимает запланированные напоминания.
CREATE OR REPLACE FUNCTION apt_status_guard() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF NOT ((OLD.status = 'booked'    AND NEW.status IN ('confirmed', 'arrived', 'no_show', 'cancelled_by_patient', 'cancelled_by_clinic'))
             OR (OLD.status = 'confirmed' AND NEW.status IN ('arrived', 'no_show', 'cancelled_by_patient', 'cancelled_by_clinic'))
             OR (OLD.status = 'arrived'   AND NEW.status = 'done')) THEN
            RAISE EXCEPTION 'appointments: переход % → % не разрешён', OLD.status, NEW.status;
        END IF;
        IF NEW.status = 'no_show' AND now() < NEW.starts_at THEN
            RAISE EXCEPTION 'appointments: «не пришёл» можно отметить только после начала приёма';
        END IF;
        CASE NEW.status
            WHEN 'confirmed' THEN NEW.confirmed_at := coalesce(NEW.confirmed_at, now());
            WHEN 'arrived'   THEN NEW.arrived_at   := coalesce(NEW.arrived_at, now());
            WHEN 'cancelled_by_patient', 'cancelled_by_clinic' THEN NEW.cancelled_at := coalesce(NEW.cancelled_at, now());
            ELSE NULL;
        END CASE;
        IF NEW.status IN ('no_show', 'cancelled_by_patient', 'cancelled_by_clinic') THEN
            UPDATE airl_notifications
            SET not_before = 'infinity', error = 'cancelled: appointment ' || NEW.status
            WHERE module = 'appointments' AND sent_at IS NULL
              AND dedup_key LIKE 'appointments:remind%:' || NEW.id || ':%';
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (coalesce(NEW.updated_by, 'system'), 'appointments', 'apt_appointments', NEW.id::text,
                'status', OLD.status, NEW.status, NEW.cancel_reason);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS apt_appointments_status ON apt_appointments;
CREATE TRIGGER apt_appointments_status BEFORE UPDATE ON apt_appointments FOR EACH ROW EXECUTE FUNCTION apt_status_guard();

-- Действующие согласия и можно ли писать первым.
CREATE OR REPLACE VIEW v_apt_consent_current AS
WITH last AS (
    SELECT DISTINCT ON (customer_id, kind) customer_id, kind, granted, consent_version, given_at
    FROM apt_consents
    ORDER BY customer_id, kind, given_at DESC, id DESC
)
SELECT c.id AS customer_id,
       coalesce(bool_or(l.granted) FILTER (WHERE l.kind = 'processing'), false) AS processing,
       coalesce(bool_or(l.granted) FILTER (WHERE l.kind = 'telegram'), false)   AS telegram_opt_in,
       coalesce(bool_or(l.granted) FILTER (WHERE l.kind = 'sms'), false)        AS sms_opt_in,
       coalesce(bool_or(l.granted) FILTER (WHERE l.kind = 'call'), false)       AS call_opt_in,
       max(l.consent_version) FILTER (WHERE l.kind = 'processing') AS consent_version,
       max(l.given_at) FILTER (WHERE l.kind = 'processing')        AS consent_at,
       (coalesce(bool_or(l.granted) FILTER (WHERE l.kind = 'processing'), false)
        AND coalesce(bool_or(l.granted) FILTER (WHERE l.kind = 'telegram'), false)
        AND c.telegram_user_id IS NOT NULL AND NOT c.archived) AS can_message_telegram
FROM apt_customers c
LEFT JOIN last l ON l.customer_id = c.id
GROUP BY c.id, c.telegram_user_id, c.archived;

-- Пациенты для экранов регистратуры: телефон целиком только для ролей с доступом к ПДн,
-- остальным — phone_masked.
CREATE OR REPLACE VIEW v_apt_customers AS
SELECT c.id, c.customer_no, c.display_name, c.phone,
       (left(c.phone, 4) || ' ** *** ' || right(c.phone, 2))::text AS phone_masked,
       c.birth_date, c.preferred_language, (c.telegram_user_id IS NOT NULL) AS has_telegram,
       k.processing, k.telegram_opt_in, k.can_message_telegram, k.consent_version, k.consent_at,
       (SELECT count(*) FROM apt_customers s WHERE s.phone = c.phone AND s.id <> c.id) AS same_phone_count,
       c.archived
FROM apt_customers c
JOIN v_apt_consent_current k ON k.customer_id = c.id;

-- Экран «Запись на день»: записи с пациентом, врачом и последним ответом.
CREATE OR REPLACE VIEW v_apt_day AS
SELECT a.id, a.appt_no, a.starts_at, a.ends_at,
       (a.starts_at AT TIME ZONE (airl_setting('appointments', 'timezone', '"Asia/Tashkent"') #>> '{}'))::date AS local_day,
       a.resource_id, r.resource_name, r.specialty, r.branch_id,
       a.customer_id, c.customer_no, c.display_name, c.phone, c.preferred_language,
       a.status, a.source, a.confirmed_at, a.arrived_at, a.cancelled_at, a.cancel_reason,
       (a.starts_at - a.cancelled_at) AS cancel_lead_time,
       lr.response AS last_response, lr.channel AS last_response_channel, lr.received_at AS last_response_at,
       k.can_message_telegram
FROM apt_appointments a
JOIN apt_customers c ON c.id = a.customer_id
JOIN v_apt_consent_current k ON k.customer_id = a.customer_id
LEFT JOIN src_apt_resources r ON r.resource_id = a.resource_id
LEFT JOIN LATERAL (SELECT x.response, x.channel, x.received_at FROM apt_responses x
                   WHERE x.appointment_id = a.id ORDER BY x.received_at DESC, x.id DESC LIMIT 1) lr ON true;

-- Экран «Не подтвердили»: записи на завтра без подтверждения — кому звонить.
CREATE OR REPLACE VIEW v_apt_unconfirmed AS
SELECT d.*,
       CASE WHEN NOT d.can_message_telegram THEN 'нет бота — позвонить'
            WHEN d.last_response IS NULL THEN 'не ответил в боте — позвонить'
            WHEN d.last_response = 'reschedule' THEN 'просит перенести'
            ELSE 'позвонить' END::text AS action_hint
FROM v_apt_day d
WHERE d.status = 'booked'
  AND d.local_day = (now() AT TIME ZONE (airl_setting('appointments', 'timezone', '"Asia/Tashkent"') #>> '{}'))::date + 1;

-- Свободное время на ближайшие booking_days дней (для бота и регистратуры).
CREATE OR REPLACE VIEW v_apt_free_slots AS
SELECT s.resource_id, r.resource_name, r.specialty, r.branch_id,
       g.slot_start, g.slot_start + make_interval(mins => r.slot_minutes) AS slot_end
FROM apt_shifts s
JOIN src_apt_resources r ON r.resource_id = s.resource_id AND r.active
CROSS JOIN LATERAL generate_series(s.starts_at, s.ends_at - make_interval(mins => r.slot_minutes),
                                   make_interval(mins => r.slot_minutes)) AS g(slot_start)
WHERE s.ends_at > now()
  AND s.starts_at < now() + make_interval(days => (airl_setting('appointments', 'booking_days', '7'))::text::int)
  AND g.slot_start > now()
  AND NOT EXISTS (SELECT 1 FROM apt_appointments a
                  WHERE a.resource_id = s.resource_id
                    AND a.status IN ('booked', 'confirmed', 'arrived', 'done', 'no_show')
                    AND a.starts_at < g.slot_start + make_interval(mins => r.slot_minutes)
                    AND a.ends_at > g.slot_start);

-- Экран «Пора на приём»: повторные визиты к сроку.
CREATE OR REPLACE VIEW v_apt_recall_due AS
SELECT rc.id, rc.customer_id, c.customer_no, c.display_name, c.phone, c.preferred_language,
       rc.resource_id, r.resource_name, rc.due_date, rc.reason, rc.status, rc.contacted_at,
       (rc.due_date < current_date) AS overdue,
       k.can_message_telegram, k.call_opt_in
FROM apt_recalls rc
JOIN apt_customers c ON c.id = rc.customer_id AND NOT c.archived
JOIN v_apt_consent_current k ON k.customer_id = rc.customer_id
LEFT JOIN src_apt_resources r ON r.resource_id = rc.resource_id
WHERE rc.status IN ('due', 'contacted')
  AND rc.due_date <= current_date + (airl_setting('appointments', 'recall_window_days', '14'))::text::int;

-- Загрузка по врачу и неделе: записанные минуты / минуты рабочего времени.
CREATE OR REPLACE VIEW v_apt_utilization AS
WITH tz AS (SELECT airl_setting('appointments', 'timezone', '"Asia/Tashkent"') #>> '{}' AS name),
avail AS (
    SELECT s.resource_id, to_char(s.starts_at AT TIME ZONE tz.name, 'IYYY-"W"IW') AS week,
           sum(extract(epoch FROM s.ends_at - s.starts_at) / 60) AS available_min
    FROM apt_shifts s, tz WHERE s.starts_at < now()
    GROUP BY 1, 2
), booked AS (
    SELECT a.resource_id, to_char(a.starts_at AT TIME ZONE tz.name, 'IYYY-"W"IW') AS week,
           sum(extract(epoch FROM a.ends_at - a.starts_at) / 60) AS booked_min
    FROM apt_appointments a, tz
    WHERE a.starts_at < now() AND a.status IN ('booked', 'confirmed', 'arrived', 'done', 'no_show')
    GROUP BY 1, 2
)
SELECT av.resource_id, r.resource_name, r.specialty, av.week,
       av.available_min::numeric(12,0) AS available_min,
       coalesce(b.booked_min, 0)::numeric(12,0) AS booked_min,
       round(100 * coalesce(b.booked_min, 0) / NULLIF(av.available_min, 0), 1) AS utilization_pct
FROM avail av
LEFT JOIN booked b ON b.resource_id = av.resource_id AND b.week = av.week
LEFT JOIN src_apt_resources r ON r.resource_id = av.resource_id;

-- Напоминания модуля в очереди уведомлений (для экрана «Напоминания» и проверки).
CREATE OR REPLACE VIEW v_apt_reminders AS
SELECT n.id, n.dedup_key, split_part(n.dedup_key, ':', 2) AS kind,
       split_part(n.dedup_key, ':', 3)::bigint AS appointment_id,
       n.channel, n.recipient, n.text, n.not_before, n.sent_at, n.error,
       CASE WHEN n.sent_at IS NOT NULL THEN 'sent'
            WHEN n.not_before = 'infinity' THEN 'cancelled'
            WHEN n.error IS NOT NULL THEN 'error'
            ELSE 'planned' END::text AS state
FROM airl_notifications n
WHERE n.module = 'appointments' AND n.dedup_key LIKE 'appointments:remind%';

-- Запланировать напоминания за reminder_hours часов до приёма (по умолчанию 24 и 2).
-- Только тем, у кого есть согласие на обработку и на Telegram. Тихие часы: первое
-- напоминание сдвигается на утро, остальные в тихие часы не отправляются.
-- Текст — только время и организация. Запускать каждые 15 минут; дублей не будет.
CREATE OR REPLACE FUNCTION apt_plan_reminders() RETURNS int LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    tz      text := airl_setting('appointments', 'timezone', '"Asia/Tashkent"') #>> '{}';
    qs      time := (airl_setting('appointments', 'quiet_from', '"21:00"') #>> '{}')::time;
    qe      time := (airl_setting('appointments', 'quiet_to', '"09:00"') #>> '{}')::time;
    org     text := airl_setting('appointments', 'org_name', '"Клиника"') #>> '{}';
    hrs     int[] := ARRAY(SELECT jsonb_array_elements_text(airl_setting('appointments', 'reminder_hours', '[24, 2]'))::int ORDER BY 1 DESC);
    first_h int;
    r       record;
    h       int;
    t       timestamptz;
    lt      timestamp;
    quiet   boolean;
    txt     text;
    n       int := 0;
    k       int;
BEGIN
    first_h := hrs[1];
    FOR r IN
        SELECT a.id, a.customer_id, a.starts_at, a.created_at, c.telegram_user_id, c.preferred_language
        FROM apt_appointments a
        JOIN apt_customers c ON c.id = a.customer_id
        JOIN v_apt_consent_current k ON k.customer_id = a.customer_id AND k.can_message_telegram
        WHERE a.status IN ('booked', 'confirmed')
          AND a.starts_at > now() AND a.starts_at <= now() + make_interval(hours => first_h + 24)
    LOOP
        FOREACH h IN ARRAY hrs LOOP
            t  := r.starts_at - make_interval(hours => h);
            lt := t AT TIME ZONE tz;
            quiet := CASE WHEN qs > qe THEN lt::time >= qs OR lt::time < qe
                          ELSE lt::time >= qs AND lt::time < qe END;
            IF quiet THEN
                IF h <> first_h THEN CONTINUE; END IF;
                lt := (CASE WHEN lt::time >= qs AND qs > qe THEN lt::date + 1 ELSE lt::date END) + qe;
                t  := lt AT TIME ZONE tz;
                IF t > r.starts_at - interval '3 hours' THEN CONTINUE; END IF;
            END IF;
            IF t < r.created_at OR t < now() - interval '1 hour' THEN CONTINUE; END IF;
            txt := CASE r.preferred_language
                WHEN 'uz' THEN org || ': siz ' || to_char(r.starts_at AT TIME ZONE tz, 'DD.MM') || ' kuni soat '
                               || to_char(r.starts_at AT TIME ZONE tz, 'HH24:MI') || ' da qabulga yozilgansiz. Kelasizmi?'
                WHEN 'kk' THEN org || ': сіз ' || to_char(r.starts_at AT TIME ZONE tz, 'DD.MM') || ' күні сағат '
                               || to_char(r.starts_at AT TIME ZONE tz, 'HH24:MI') || ' қабылдауға жазылдыңыз. Келесіз бе?'
                ELSE           org || ': вы записаны на ' || to_char(r.starts_at AT TIME ZONE tz, 'DD.MM') || ' в '
                               || to_char(r.starts_at AT TIME ZONE tz, 'HH24:MI') || '. Придёте?'
            END;
            INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text, not_before)
            VALUES ('appointments:remind' || h || ':' || r.id || ':' || r.customer_id, 'appointments', 'telegram',
                    r.telegram_user_id::text, txt, t)
            ON CONFLICT (dedup_key) DO NOTHING;
            GET DIAGNOSTICS k = ROW_COUNT;
            n := n + k;
        END LOOP;
    END LOOP;
    RETURN n;
END $$;

-- Показатель: доля неявок по неделе приёма (местное время).
-- Знаменатель: пришёл, принят, не пришёл, а также отмены пациентом позже чем за
-- late_cancel_hours часов (0 — поздние отмены не считаются). Будущие и неотмеченные не считаются.
CREATE OR REPLACE VIEW m_no_show_rate AS
WITH cfg AS (
    SELECT airl_setting('appointments', 'timezone', '"Asia/Tashkent"') #>> '{}' AS tz,
           (airl_setting('appointments', 'late_cancel_hours', '0'))::text::int AS late_h
), base AS (
    SELECT to_char(a.starts_at AT TIME ZONE cfg.tz, 'IYYY-"W"IW') AS week,
           (a.status = 'no_show'
            OR (a.status = 'cancelled_by_patient' AND a.cancelled_at > a.starts_at - make_interval(hours => cfg.late_h))) AS missed
    FROM apt_appointments a, cfg
    WHERE a.starts_at < now()
      AND (a.status IN ('arrived', 'done', 'no_show')
           OR (cfg.late_h > 0 AND a.status = 'cancelled_by_patient'
               AND a.cancelled_at > a.starts_at - make_interval(hours => cfg.late_h)))
)
SELECT 'no_show_rate'::text AS metric_id,
       week AS period,
       round(100.0 * count(*) FILTER (WHERE missed) / NULLIF(count(*), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(round(100.0 * count(*) FILTER (WHERE missed) / NULLIF(count(*), 0), 2),
           (airl_setting('appointments', 'no_show_warn', '10'))::text::numeric,
           (airl_setting('appointments', 'no_show_bad', '15'))::text::numeric,
           false) AS status
FROM base
GROUP BY week;

-- Показатель: загрузка врачей по неделе — записанные минуты / минуты рабочего времени (прошедшего).
CREATE OR REPLACE VIEW m_doctor_utilization AS
SELECT 'doctor_utilization'::text AS metric_id,
       week AS period,
       round(100 * sum(booked_min) / NULLIF(sum(available_min), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(round(100 * sum(booked_min) / NULLIF(sum(available_min), 0), 2),
           (airl_setting('appointments', 'utilization_warn', '70'))::text::numeric,
           (airl_setting('appointments', 'utilization_bad', '50'))::text::numeric,
           true) AS status
FROM v_apt_utilization
GROUP BY week;

-- Показатель: возврат пациентов за 90 дней. Когорта месяца M — пациенты с завершённым
-- визитом (arrived/done) в месяце M; вернулся — есть завершённый визит в другой день
-- в течение 90 дней после первого визита в M. Месяц появляется, когда 90 дней после
-- его конца прошли.
CREATE OR REPLACE VIEW m_return_rate_90d AS
WITH tz AS (SELECT airl_setting('appointments', 'timezone', '"Asia/Tashkent"') #>> '{}' AS name),
visits AS (
    SELECT a.customer_id, a.starts_at, (a.starts_at AT TIME ZONE tz.name)::date AS day
    FROM apt_appointments a, tz WHERE a.status IN ('arrived', 'done')
), cohort AS (
    SELECT customer_id, date_trunc('month', day)::date AS month, min(starts_at) AS first_at, min(day) AS first_day
    FROM visits GROUP BY customer_id, date_trunc('month', day)
)
SELECT 'return_rate_90d'::text AS metric_id,
       to_char(c.month, 'YYYY-MM') AS period,
       round(100.0 * count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM visits v WHERE v.customer_id = c.customer_id
             AND v.day > c.first_day AND v.starts_at <= c.first_at + interval '90 days')) / NULLIF(count(*), 0), 2) AS value,
       '%'::text AS unit,
       airl_traffic(round(100.0 * count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM visits v WHERE v.customer_id = c.customer_id
             AND v.day > c.first_day AND v.starts_at <= c.first_at + interval '90 days')) / NULLIF(count(*), 0), 2),
           (airl_setting('appointments', 'return_warn', '35'))::text::numeric,
           (airl_setting('appointments', 'return_bad', '25'))::text::numeric,
           true) AS status
FROM cohort c
WHERE (c.month + interval '1 month' + interval '90 days')::date <= current_date
GROUP BY c.month;
