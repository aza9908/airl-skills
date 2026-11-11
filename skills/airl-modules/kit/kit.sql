-- Каркас модулей AIRL. Ставится один раз в схему продукта или витрины отдела
-- до любого модуля. Повторный запуск безопасен.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "SET search_path TO <схема>" -f kit.sql
--
-- Имена без схемы: всё создаётся в первой схеме search_path
-- (в хабе — mart_<отдел>, в своём продукте — схема приложения).

-- Настройки модулей: ответы на вопросы настройки, пороги светофора.
CREATE TABLE IF NOT EXISTS airl_settings (
    module      text        NOT NULL,
    key         text        NOT NULL,
    value       jsonb       NOT NULL,
    note        text,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text        NOT NULL,
    PRIMARY KEY (module, key)
);

-- Журнал событий: кто, когда, что сделал с какой записью. Только добавление.
CREATE TABLE IF NOT EXISTS airl_audit (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at          timestamptz NOT NULL DEFAULT now(),
    actor       text        NOT NULL,
    module      text        NOT NULL,
    entity      text        NOT NULL,
    entity_id   text        NOT NULL,
    action      text        NOT NULL,          -- create | update | status | view | export | delete
    from_status text,
    to_status   text,
    comment     text,
    details     jsonb
);
CREATE INDEX IF NOT EXISTS airl_audit_entity_idx ON airl_audit (module, entity, entity_id, at);

-- Вложения: файлы лежат в файловом хранилище, в базе только ссылка.
CREATE TABLE IF NOT EXISTS airl_attachments (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    module      text        NOT NULL,
    entity      text        NOT NULL,
    entity_id   text        NOT NULL,
    url         text        NOT NULL,
    filename    text        NOT NULL,
    mime_type   text,
    size_bytes  bigint CHECK (size_bytes IS NULL OR size_bytes >= 0),
    uploaded_at timestamptz NOT NULL DEFAULT now(),
    uploaded_by text        NOT NULL
);
CREATE INDEX IF NOT EXISTS airl_attachments_entity_idx ON airl_attachments (module, entity, entity_id);

-- Очередь уведомлений: одна запись на событие и получателя.
-- Уникальный ключ защищает от дублей при перезапуске.
CREATE TABLE IF NOT EXISTS airl_notifications (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    dedup_key   text        NOT NULL UNIQUE,
    module      text        NOT NULL,
    channel     text        NOT NULL CHECK (channel IN ('telegram', 'email', 'sms', 'in_app')),
    recipient   text        NOT NULL,
    text        text        NOT NULL,
    not_before  timestamptz NOT NULL DEFAULT now(),
    sent_at     timestamptz,
    error       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS airl_notifications_due_idx ON airl_notifications (not_before) WHERE sent_at IS NULL;

-- Поле updated_at обновляется само.
CREATE OR REPLACE FUNCTION airl_touch() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

-- Чтение настройки с значением по умолчанию: airl_setting('approvals', 'limit_ceo', '500000')
-- SET search_path FROM CURRENT привязывает функцию к схеме, в которой её создали:
-- показатели модуля читаются правильно из любой схемы (хаб, ИИ-слой). Читателю
-- нужно право SELECT на airl_settings этой схемы.
CREATE OR REPLACE FUNCTION airl_setting(p_module text, p_key text, p_default jsonb)
RETURNS jsonb LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT COALESCE(
        (SELECT value FROM airl_settings WHERE module = p_module AND key = p_key),
        p_default)
$$;

-- Светофор по порогам: для «больше — лучше» (higher_is_better = true)
-- и «меньше — лучше» (false).
CREATE OR REPLACE FUNCTION airl_traffic(p_value numeric, p_warn numeric, p_bad numeric, p_higher_is_better boolean)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_value IS NULL THEN 'warning'
        WHEN p_higher_is_better AND p_value <= p_bad  THEN 'danger'
        WHEN p_higher_is_better AND p_value <= p_warn THEN 'warning'
        WHEN NOT p_higher_is_better AND p_value >= p_bad  THEN 'danger'
        WHEN NOT p_higher_is_better AND p_value >= p_warn THEN 'warning'
        ELSE 'ok'
    END
$$;
