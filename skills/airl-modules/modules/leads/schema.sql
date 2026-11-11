-- Модуль «Лиды и сквозная воронка» (leads). Требует kit/kit.sql в той же схеме и
-- представления src_lead_deals, src_lead_ad_costs (адаптер или demo_src.sql).
-- Лиды принимает сам модуль: серверный обработчик вебхука (сайт, Meta Lead Ads через
-- коннектор, Telegram-бот, ручной ввод) вызывает lead_capture(payload). Каждый лид получает
-- номер L-<ггггммдд>-<nnnn> и короткий код для клиента; затем — менеджер по правилам,
-- срок первого ответа, статусы до продажи и связь с реальной сделкой из CRM/1С.

CREATE OR REPLACE FUNCTION lead_currency() RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT airl_setting('leads', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}'
$$;

-- Телефон в одном виде: +7XXXXXXXXXX (KZ), +998XXXXXXXXX (UZ). 8-701… → +7701…;
-- 9 цифр — узбекский номер без кода страны. Непонятный номер — NULL.
CREATE OR REPLACE FUNCTION lead_norm_phone(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
    WITH d AS (SELECT regexp_replace(COALESCE(p, ''), '\D', '', 'g') AS x)
    SELECT CASE
        WHEN length(x) = 11 AND left(x, 1) = '8'   THEN '+7' || substr(x, 2)
        WHEN length(x) = 11 AND left(x, 1) = '7'   THEN '+' || x
        WHEN length(x) = 10 AND left(x, 1) = '7'   THEN '+7' || x
        WHEN length(x) = 12 AND left(x, 3) = '998' THEN '+' || x
        WHEN length(x) = 9                         THEN '+998' || x
        WHEN length(x) BETWEEN 10 AND 15           THEN '+' || x
    END FROM d
$$;

-- Маска для экранов и выгрузок: +7701*****67, a***@mail.kz.
CREATE OR REPLACE FUNCTION lead_mask_phone(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
    SELECT CASE WHEN p IS NULL THEN NULL ELSE left(p, length(p) - 7) || '*****' || right(p, 2) END
$$;

CREATE OR REPLACE FUNCTION lead_mask_email(p text) RETURNS text
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
    SELECT CASE WHEN p IS NULL OR position('@' IN p) = 0 THEN NULL
                ELSE left(p, 1) || '***' || substr(p, position('@' IN p)) END
$$;

-- Короткий код для клиента (назвать по телефону, ввести в форме заказа): 6 знаков без
-- похожих символов (нет 0/O, 1/I).
CREATE OR REPLACE FUNCTION lead_random_code() RETURNS text
LANGUAGE sql VOLATILE SET search_path FROM CURRENT AS $$
    SELECT string_agg(substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ', 1 + floor(random() * 32)::int, 1), '')
    FROM generate_series(1, 6)
$$;

-- Начало рабочего времени для лида, пришедшего в момент p_at: сам момент, если сейчас
-- рабочее время, иначе ближайшее начало рабочего дня (настройки work_hours, timezone).
CREATE OR REPLACE FUNCTION lead_work_start(p_at timestamptz) RETURNS timestamptz
LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $$
DECLARE
    v_tz    text  := airl_setting('leads', 'timezone', airl_setting('kit', 'timezone', '"Asia/Almaty"')) #>> '{}';
    v_wh    jsonb := airl_setting('leads', 'work_hours', '{"days": [1,2,3,4,5,6], "from": "09:00", "to": "19:00"}');
    v_from  time  := (v_wh->>'from')::time;
    v_to    time  := (v_wh->>'to')::time;
    v_days  int[] := ARRAY(SELECT jsonb_array_elements_text(v_wh->'days')::int);
    v_local timestamp := p_at AT TIME ZONE v_tz;
    v_day   date;
BEGIN
    FOR i IN 0..7 LOOP
        v_day := v_local::date + i;
        CONTINUE WHEN NOT (extract(isodow FROM v_day)::int = ANY (v_days));
        IF i = 0 AND v_local::time >= v_from AND v_local::time < v_to THEN RETURN p_at; END IF;
        IF i > 0 OR v_local::time < v_from THEN RETURN (v_day + v_from) AT TIME ZONE v_tz; END IF;
    END LOOP;
    RETURN p_at;
END $$;

CREATE TABLE IF NOT EXISTS lead_day_counters (
    day        date        PRIMARY KEY,
    last_no    int         NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz
);

CREATE TABLE IF NOT EXISTS lead_lost_reasons (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        text        NOT NULL UNIQUE,
    title       text        NOT NULL,
    active      boolean     NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text
);

CREATE TABLE IF NOT EXISTS lead_leads (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lead_no           text        NOT NULL UNIQUE,         -- L-20261111-0007
    public_code       text        NOT NULL UNIQUE,         -- K7M2QX — клиент называет менеджеру
    channel           text        NOT NULL
                      CHECK (channel IN ('site', 'instagram', 'meta_form', 'telegram', 'whatsapp', 'phone', 'manual', 'other')),
    contact_name      text,
    phone             text,                                -- +77011234567, персональные данные
    email             text,                                -- персональные данные
    messenger_id      text,                                -- id чата Telegram/WhatsApp, персональные данные
    city              text,
    interest          text,
    message           text,
    utm_source        text,
    utm_medium        text,
    utm_campaign      text,
    utm_content       text,
    utm_term          text,
    ad_id             text,
    ad_name           text,
    form_id           text,
    campaign          text        NOT NULL,                -- ключ кампании для расходов: utm_campaign или «без кампании»
    status            text        NOT NULL DEFAULT 'new'
                      CHECK (status IN ('new', 'in_work', 'qualified', 'won', 'lost')),
    lost_reason       text        REFERENCES lead_lost_reasons (code),
    status_comment    text,
    assigned_to       text,
    assigned_rule_id  bigint,
    assigned_at       timestamptz,
    received_at       timestamptz NOT NULL,
    out_of_hours      boolean     NOT NULL DEFAULT false,
    sla_start_at      timestamptz NOT NULL,
    sla_due_at        timestamptz NOT NULL,
    first_response_at timestamptz,
    qualified_at      timestamptz,
    closed_at         timestamptz,
    reopened_at       timestamptz,
    touches_count     int         NOT NULL DEFAULT 1,
    last_touch_at     timestamptz NOT NULL,
    consent_marketing boolean     NOT NULL DEFAULT false,
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        text        NOT NULL,
    updated_at        timestamptz,
    updated_by        text,
    CHECK (phone IS NOT NULL OR email IS NOT NULL OR messenger_id IS NOT NULL),
    CHECK (status <> 'lost' OR lost_reason IS NOT NULL),
    CHECK (status NOT IN ('won', 'lost') OR closed_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS lead_leads_phone_idx ON lead_leads (phone, last_touch_at);
CREATE INDEX IF NOT EXISTS lead_leads_email_idx ON lead_leads (email, last_touch_at);
CREATE INDEX IF NOT EXISTS lead_leads_status_idx ON lead_leads (status, sla_due_at);

-- Каждое обращение (в том числе повторное — дубль того же лида). payload — как пришло.
CREATE TABLE IF NOT EXISTS lead_touches (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lead_id      bigint      NOT NULL REFERENCES lead_leads (id),
    channel      text        NOT NULL,
    external_id  text,                                     -- id заявки в источнике: повтор вебхука не создаёт дубль
    utm_source   text,
    utm_campaign text,
    ad_id        text,
    is_first     boolean     NOT NULL,
    payload      jsonb       NOT NULL,                     -- персональные данные
    received_at  timestamptz NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text        NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS lead_touches_external ON lead_touches (channel, external_id) WHERE external_id IS NOT NULL;

-- Маршрутизация: правило подходит, если совпали непустые поля; меньше priority — раньше.
-- Внутри правила менеджеры по кругу (round-robin) в порядке ord.
CREATE TABLE IF NOT EXISTS lead_routing_rules (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code         text        NOT NULL UNIQUE,
    title        text        NOT NULL,
    priority     int         NOT NULL DEFAULT 100,
    channel      text,
    city         text,
    interest     text,
    rr_last_ord  int         NOT NULL DEFAULT 0,
    active       boolean     NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   text        NOT NULL,
    updated_at   timestamptz,
    updated_by   text
);

CREATE TABLE IF NOT EXISTS lead_rule_managers (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id     bigint      NOT NULL REFERENCES lead_routing_rules (id),
    manager_id  text        NOT NULL,
    ord         int         NOT NULL,
    active      boolean     NOT NULL DEFAULT true,               -- отпуск, увольнение
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL,
    updated_at  timestamptz,
    updated_by  text,
    UNIQUE (rule_id, manager_id),
    UNIQUE (rule_id, ord)
);

-- Связь лида со сделкой из CRM/1С (фиксируется один раз: атрибуция не «плывёт»).
CREATE TABLE IF NOT EXISTS lead_deal_links (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lead_id     bigint        NOT NULL REFERENCES lead_leads (id),
    deal_id     text          NOT NULL UNIQUE,
    amount      numeric(18,2) NOT NULL,
    currency    char(3)       NOT NULL,
    won_at      timestamptz   NOT NULL,
    matched_by  text          NOT NULL CHECK (matched_by IN ('lead_ref', 'phone', 'manual')),
    created_at  timestamptz   NOT NULL DEFAULT now(),
    created_by  text          NOT NULL
);
CREATE INDEX IF NOT EXISTS lead_deal_links_lead_idx ON lead_deal_links (lead_id);

-- Согласие на рекламные сообщения: только добавление; действует последняя запись.
CREATE TABLE IF NOT EXISTS lead_consents (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lead_id     bigint      NOT NULL REFERENCES lead_leads (id),
    granted     boolean     NOT NULL,
    text        text,                                   -- текст, с которым согласился (или «отписался»)
    source      text        NOT NULL,                   -- форма, бот, звонок
    at          timestamptz NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL
);
CREATE INDEX IF NOT EXISTS lead_consents_lead_idx ON lead_consents (lead_id, at);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['lead_lost_reasons', 'lead_leads', 'lead_routing_rules', 'lead_rule_managers'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_touch', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION airl_touch()', t || '_touch', t);
    END LOOP;
END $$;

-- Согласия не меняются и не удаляются: отзыв — новая запись granted = false.
CREATE OR REPLACE FUNCTION lead_consents_readonly() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    RAISE EXCEPTION 'leads: согласие не меняется — добавьте новую запись (отзыв — granted = false)';
END $$;
DROP TRIGGER IF EXISTS lead_consents_readonly ON lead_consents;
CREATE TRIGGER lead_consents_readonly BEFORE UPDATE OR DELETE ON lead_consents FOR EACH ROW EXECUTE FUNCTION lead_consents_readonly();

-- Статусы лида: new → in_work → qualified → won | lost; new → lost (спам, дубль);
-- new | in_work → won (купил сразу); lost → new (вернулся сам); lost → won (сделка нашлась в CRM/1С).
CREATE OR REPLACE FUNCTION lead_leads_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF (OLD.status, NEW.status) NOT IN (
            ('new', 'in_work'), ('new', 'lost'), ('new', 'won'),
            ('in_work', 'qualified'), ('in_work', 'won'), ('in_work', 'lost'),
            ('qualified', 'won'), ('qualified', 'lost'),
            ('lost', 'new'), ('lost', 'won')) THEN
            RAISE EXCEPTION 'leads: переход % → % не разрешён (%)', OLD.status, NEW.status, OLD.lead_no;
        END IF;
        IF NEW.status = 'in_work' THEN NEW.first_response_at := COALESCE(NEW.first_response_at, now()); END IF;
        IF NEW.status = 'qualified' THEN NEW.qualified_at := COALESCE(NEW.qualified_at, now()); END IF;
        IF NEW.status IN ('won', 'lost') THEN NEW.closed_at := COALESCE(NEW.closed_at, now()); END IF;
        IF NEW.status = 'new' THEN
            NEW.reopened_at := now(); NEW.closed_at := NULL; NEW.lost_reason := NULL;
        END IF;
        IF NEW.status = 'won' THEN NEW.lost_reason := NULL; END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment, details)
        VALUES (COALESCE(NEW.updated_by, 'system'), 'leads', 'lead', NEW.lead_no, 'status', OLD.status, NEW.status,
                NEW.status_comment, jsonb_build_object('lost_reason', NEW.lost_reason));
    END IF;
    IF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to AND OLD.assigned_to IS NOT NULL THEN
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, comment, details)
        VALUES (COALESCE(NEW.updated_by, 'system'), 'leads', 'lead', NEW.lead_no, 'update', 'переназначен',
                jsonb_build_object('from', OLD.assigned_to, 'to', NEW.assigned_to));
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS lead_leads_status ON lead_leads;
CREATE TRIGGER lead_leads_status BEFORE UPDATE ON lead_leads FOR EACH ROW EXECUTE FUNCTION lead_leads_guard();

-- Назначить менеджера по правилам маршрутизации (по кругу внутри правила).
-- Нет подходящего правила или все менеджеры неактивны — fallback_assignee.
CREATE OR REPLACE FUNCTION lead_assign(p_lead_id bigint, p_actor text, p_at timestamptz DEFAULT now()) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_lead lead_leads%ROWTYPE;
    v_rule record;
    v_mgr  record;
    v_to   text;
    v_rule_id bigint;
    v_channel text := airl_setting('leads', 'channel', '"telegram"') #>> '{}';
BEGIN
    SELECT * INTO v_lead FROM lead_leads WHERE id = p_lead_id FOR UPDATE;
    FOR v_rule IN
        SELECT r.id FROM lead_routing_rules r
        WHERE r.active
          AND (r.channel IS NULL OR r.channel = v_lead.channel)
          AND (r.city IS NULL OR lower(r.city) = lower(v_lead.city))
          AND (r.interest IS NULL OR r.interest = v_lead.interest)
        ORDER BY r.priority, r.id
    LOOP
        PERFORM 1 FROM lead_routing_rules WHERE id = v_rule.id FOR UPDATE;   -- очередь правила — по одному
        SELECT m.manager_id, m.ord INTO v_mgr
        FROM lead_rule_managers m
        JOIN lead_routing_rules rr ON rr.id = m.rule_id
        WHERE m.rule_id = v_rule.id AND m.active
        ORDER BY (m.ord <= rr.rr_last_ord), m.ord
        LIMIT 1;
        IF FOUND THEN
            UPDATE lead_routing_rules SET rr_last_ord = v_mgr.ord WHERE id = v_rule.id;
            v_to := v_mgr.manager_id; v_rule_id := v_rule.id;
            EXIT;
        END IF;
    END LOOP;
    v_to := COALESCE(v_to, airl_setting('leads', 'fallback_assignee', '"role:sales_head"') #>> '{}');
    UPDATE lead_leads SET assigned_to = v_to, assigned_rule_id = v_rule_id, assigned_at = p_at, updated_by = p_actor
     WHERE id = p_lead_id;
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text, not_before)
    VALUES ('leads:new:' || v_lead.lead_no || ':' || v_to, 'leads', v_channel, v_to,
            'Новый лид ' || v_lead.lead_no || ': ' || COALESCE(v_lead.contact_name, 'без имени') || ', '
            || COALESCE(v_lead.city, 'город не указан') || ', ' || COALESCE(v_lead.interest, 'интерес не указан')
            || '. Ответить до ' || to_char(v_lead.sla_due_at AT TIME ZONE
                   (airl_setting('leads', 'timezone', airl_setting('kit', 'timezone', '"Asia/Almaty"')) #>> '{}'), 'DD.MM HH24:MI'),
            v_lead.sla_start_at)
    ON CONFLICT (dedup_key) DO NOTHING;
    RETURN v_to;
END $$;

-- Приём лида. Вызывает серверный обработчик вебхука (сайт, Meta через коннектор,
-- Telegram-бот) или форма ручного ввода. Ключи payload — в MODULE.md.
-- Возвращает {"lead_no", "public_code", "duplicate", "out_of_hours"}.
-- Повтор того же вебхука (channel + external_id) ничего не создаёт.
-- Тот же телефон / e-mail / чат за dedup_days дней — тот же лид: новое обращение
-- добавляется к нему; потерянный лид возвращается в «новые».
CREATE OR REPLACE FUNCTION lead_capture(p jsonb, p_actor text) RETURNS jsonb
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_channel  text        := COALESCE(NULLIF(p->>'channel', ''), 'manual');
    v_received timestamptz := COALESCE((p->>'received_at')::timestamptz, now());
    v_phone    text        := lead_norm_phone(p->>'phone');
    v_email    text        := lower(NULLIF(btrim(p->>'email'), ''));
    v_msgr     text        := NULLIF(btrim(p->>'messenger_id'), '');
    v_ext      text        := NULLIF(p->>'external_id', '');
    v_days     int         := (airl_setting('leads', 'dedup_days', '30'))::text::int;
    v_sla      int         := (airl_setting('leads', 'sla_minutes', '15'))::text::int;
    v_tz       text        := airl_setting('leads', 'timezone', airl_setting('kit', 'timezone', '"Asia/Almaty"')) #>> '{}';
    v_lead     lead_leads%ROWTYPE;
    v_seq      int;
    v_no       text;
    v_code     text;
    v_start    timestamptz;
    v_reply    text;
BEGIN
    IF v_channel NOT IN ('site', 'instagram', 'meta_form', 'telegram', 'whatsapp', 'phone', 'manual', 'other') THEN
        RAISE EXCEPTION 'leads: неизвестный канал %', v_channel;
    END IF;
    IF v_phone IS NULL AND v_email IS NULL AND v_msgr IS NULL THEN
        RAISE EXCEPTION 'leads: нет контакта — нужен телефон, e-mail или чат';
    END IF;

    IF v_ext IS NOT NULL THEN
        SELECT l.* INTO v_lead FROM lead_touches t JOIN lead_leads l ON l.id = t.lead_id
        WHERE t.channel = v_channel AND t.external_id = v_ext;
        IF FOUND THEN
            RETURN jsonb_build_object('lead_no', v_lead.lead_no, 'public_code', v_lead.public_code,
                                      'duplicate', true, 'repeat_request', true, 'out_of_hours', v_lead.out_of_hours);
        END IF;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('leads:contact:' || COALESCE(v_phone, v_email, v_msgr)));
    SELECT * INTO v_lead FROM lead_leads l
    WHERE ((v_phone IS NOT NULL AND l.phone = v_phone) OR (v_email IS NOT NULL AND l.email = v_email)
           OR (v_msgr IS NOT NULL AND l.messenger_id = v_msgr))
      AND l.last_touch_at >= v_received - make_interval(days => v_days)
    ORDER BY l.last_touch_at DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
        INSERT INTO lead_touches (lead_id, channel, external_id, utm_source, utm_campaign, ad_id, is_first, payload, received_at, created_by)
        VALUES (v_lead.id, v_channel, v_ext, p->>'utm_source', p->>'utm_campaign', p->>'ad_id', false, p, v_received, p_actor);
        UPDATE lead_leads
           SET touches_count = touches_count + 1, last_touch_at = greatest(last_touch_at, v_received),
               phone = COALESCE(phone, v_phone), email = COALESCE(email, v_email), messenger_id = COALESCE(messenger_id, v_msgr),
               status = CASE WHEN status = 'lost' THEN 'new' ELSE status END,
               status_comment = CASE WHEN status = 'lost' THEN 'вернулся: новое обращение (' || v_channel || ')' ELSE status_comment END,
               updated_by = p_actor
         WHERE id = v_lead.id;
        IF p ? 'consent_marketing' THEN
            INSERT INTO lead_consents (lead_id, granted, text, source, at, created_by)
            VALUES (v_lead.id, (p->>'consent_marketing')::boolean, p->>'consent_text', v_channel, v_received, p_actor);
            UPDATE lead_leads SET consent_marketing = (p->>'consent_marketing')::boolean WHERE id = v_lead.id;
        END IF;
        INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
        SELECT 'leads:repeat:' || v_lead.lead_no || ':' || t.id || ':' || v_lead.assigned_to, 'leads',
               airl_setting('leads', 'channel', '"telegram"') #>> '{}', v_lead.assigned_to,
               'Повторное обращение по лиду ' || v_lead.lead_no || ' (' || v_channel || ')'
        FROM lead_touches t WHERE t.lead_id = v_lead.id AND v_lead.assigned_to IS NOT NULL
        ORDER BY t.id DESC LIMIT 1
        ON CONFLICT (dedup_key) DO NOTHING;
        RETURN jsonb_build_object('lead_no', v_lead.lead_no, 'public_code', v_lead.public_code,
                                  'duplicate', true, 'out_of_hours', v_lead.out_of_hours);
    END IF;

    INSERT INTO lead_day_counters (day, last_no) VALUES ((v_received AT TIME ZONE v_tz)::date, 1)
    ON CONFLICT (day) DO UPDATE SET last_no = lead_day_counters.last_no + 1, updated_at = now()
    RETURNING last_no INTO v_seq;
    v_no := 'L-' || to_char((v_received AT TIME ZONE v_tz)::date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 4, '0');
    LOOP
        v_code := lead_random_code();
        EXIT WHEN NOT EXISTS (SELECT 1 FROM lead_leads WHERE public_code = v_code);
    END LOOP;
    v_start := lead_work_start(v_received);

    INSERT INTO lead_leads (lead_no, public_code, channel, contact_name, phone, email, messenger_id, city, interest, message,
                            utm_source, utm_medium, utm_campaign, utm_content, utm_term, ad_id, ad_name, form_id, campaign,
                            received_at, out_of_hours, sla_start_at, sla_due_at, last_touch_at, consent_marketing,
                            created_at, created_by, updated_by)
    VALUES (v_no, v_code, v_channel, NULLIF(btrim(p->>'name'), ''), v_phone, v_email, v_msgr,
            NULLIF(btrim(p->>'city'), ''), NULLIF(p->>'interest', ''), p->>'message',
            p->>'utm_source', p->>'utm_medium', p->>'utm_campaign', p->>'utm_content', p->>'utm_term',
            p->>'ad_id', p->>'ad_name', p->>'form_id',
            COALESCE(NULLIF(p->>'utm_campaign', ''), 'без кампании'),
            v_received, v_start > v_received, v_start, v_start + make_interval(mins => v_sla), v_received,
            COALESCE((p->>'consent_marketing')::boolean, false),
            v_received, p_actor, p_actor)
    RETURNING * INTO v_lead;

    INSERT INTO lead_touches (lead_id, channel, external_id, utm_source, utm_campaign, ad_id, is_first, payload, received_at, created_by)
    VALUES (v_lead.id, v_channel, v_ext, p->>'utm_source', p->>'utm_campaign', p->>'ad_id', true, p, v_received, p_actor);
    IF p ? 'consent_marketing' THEN
        INSERT INTO lead_consents (lead_id, granted, text, source, at, created_by)
        VALUES (v_lead.id, (p->>'consent_marketing')::boolean, p->>'consent_text', v_channel, v_received, p_actor);
    END IF;
    INSERT INTO airl_audit (actor, module, entity, entity_id, action, details)
    VALUES (p_actor, 'leads', 'lead', v_no, 'create',
            jsonb_build_object('channel', v_channel, 'campaign', v_lead.campaign, 'out_of_hours', v_lead.out_of_hours));

    PERFORM lead_assign(v_lead.id, p_actor, v_received);

    -- Вне рабочего времени — автоответ клиенту (отправляет бот/коннектор канала по lead_no).
    v_reply := airl_setting('leads', 'auto_reply_text', 'null') #>> '{}';
    IF v_lead.out_of_hours AND v_reply IS NOT NULL THEN
        INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
        VALUES ('leads:autoreply:' || v_no || ':lead:' || v_no, 'leads',
                CASE WHEN v_channel IN ('telegram') THEN 'telegram' WHEN v_phone IS NOT NULL THEN 'sms' ELSE 'email' END,
                'lead:' || v_no,
                replace(replace(v_reply, '{code}', v_code),
                        '{start}', to_char(v_start AT TIME ZONE v_tz, 'DD.MM HH24:MI')))
        ON CONFLICT (dedup_key) DO NOTHING;
    END IF;

    RETURN jsonb_build_object('lead_no', v_no, 'public_code', v_code, 'duplicate', false, 'out_of_hours', v_lead.out_of_hours);
END $$;

-- Смена статуса менеджером. Роль и «свой лид» проверяет сервер до вызова.
CREATE OR REPLACE FUNCTION lead_set_status(p_lead_no text, p_status text, p_actor text,
                                           p_lost_reason text DEFAULT NULL, p_comment text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_n int;
BEGIN
    IF p_status = 'lost' AND p_lost_reason IS NULL THEN RAISE EXCEPTION 'leads: укажите причину потери'; END IF;
    UPDATE lead_leads SET status = p_status, lost_reason = COALESCE(p_lost_reason, lost_reason),
                          status_comment = p_comment, updated_by = p_actor
     WHERE lead_no = p_lead_no;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'leads: лид % не найден', p_lead_no; END IF;
    RETURN p_status;
END $$;

-- Отзыв согласия на рекламу (клиент написал «отпишите меня»).
CREATE OR REPLACE FUNCTION lead_consent_withdraw(p_lead_no text, p_actor text, p_source text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    INSERT INTO lead_consents (lead_id, granted, text, source, at, created_by)
    SELECT id, false, 'отзыв согласия', p_source, now(), p_actor FROM lead_leads WHERE lead_no = p_lead_no;
    UPDATE lead_leads SET consent_marketing = false, updated_by = p_actor WHERE lead_no = p_lead_no;
END $$;

-- Связать сделки из CRM/1С с лидами: по номеру лида или коду (lead_ref), иначе по телефону —
-- последний лид с этим телефоном, созданный не раньше чем за attribution_days до сделки.
-- Лид со сделкой становится won. Повторный запуск безопасен.
CREATE OR REPLACE FUNCTION lead_sync_deals(p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_days int := (airl_setting('leads', 'attribution_days', '90'))::text::int;
    v_n    int;
BEGIN
    INSERT INTO lead_deal_links (lead_id, deal_id, amount, currency, won_at, matched_by, created_by)
    SELECT m.lead_id, d.deal_id, d.amount, d.currency, d.won_at, m.how, p_actor
    FROM src_lead_deals d
    CROSS JOIN LATERAL (
        SELECT x.lead_id, x.how FROM (
            SELECT l.id AS lead_id, 'lead_ref'::text AS how, 1 AS pri, l.received_at
            FROM lead_leads l
            WHERE d.lead_ref IS NOT NULL AND (l.lead_no = d.lead_ref OR l.public_code = upper(btrim(d.lead_ref)))
            UNION ALL
            SELECT l.id, 'phone', 2, l.received_at
            FROM lead_leads l
            WHERE l.phone = lead_norm_phone(d.phone)
              AND l.received_at <= d.won_at AND l.received_at >= d.won_at - make_interval(days => v_days)
        ) x
        ORDER BY x.pri, x.received_at DESC
        LIMIT 1
    ) m
    WHERE NOT EXISTS (SELECT 1 FROM lead_deal_links k WHERE k.deal_id = d.deal_id)
    ON CONFLICT (deal_id) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    UPDATE lead_leads l
       SET status = 'won', closed_at = (SELECT min(k.won_at) FROM lead_deal_links k WHERE k.lead_id = l.id),
           status_comment = 'сделка найдена в CRM/1С', updated_by = p_actor
     WHERE l.status IN ('new', 'in_work', 'qualified', 'lost')
       AND EXISTS (SELECT 1 FROM lead_deal_links k WHERE k.lead_id = l.id);
    RETURN v_n;
END $$;

-- Экран «Лиды»: контакты замаскированы. Полный телефон отдаёт сервер назначенному менеджеру.
CREATE OR REPLACE VIEW v_lead_leads AS
SELECT l.id, l.lead_no, l.public_code, l.channel, l.contact_name, lead_mask_phone(l.phone) AS phone_masked,
       lead_mask_email(l.email) AS email_masked, (l.messenger_id IS NOT NULL) AS has_messenger,
       l.city, l.interest, l.utm_source, l.utm_medium, l.campaign, l.utm_content, l.ad_name,
       l.status, l.lost_reason, r.title AS lost_reason_title, l.status_comment, l.assigned_to,
       l.received_at, l.out_of_hours, l.sla_start_at, l.sla_due_at, l.first_response_at,
       round(extract(epoch FROM COALESCE(l.first_response_at, now()) - l.sla_start_at) / 60) AS response_minutes,
       COALESCE(l.first_response_at, now()) > l.sla_due_at AS sla_breached,
       l.qualified_at, l.closed_at, l.reopened_at, l.touches_count, l.last_touch_at, l.consent_marketing,
       COALESCE(d.deals, 0) AS deals, COALESCE(d.revenue, 0)::numeric(18,2) AS revenue
FROM lead_leads l
LEFT JOIN lead_lost_reasons r ON r.code = l.lost_reason
LEFT JOIN (SELECT lead_id, count(*) AS deals, sum(amount) FILTER (WHERE currency = lead_currency()) AS revenue
           FROM lead_deal_links GROUP BY lead_id) d ON d.lead_id = l.id;

-- Экран «Новые»: ждут первого ответа, просроченные сверху.
CREATE OR REPLACE VIEW v_lead_queue AS
SELECT lead_no, public_code, channel, contact_name, phone_masked, city, interest, campaign, assigned_to,
       received_at, out_of_hours, sla_due_at,
       round(extract(epoch FROM sla_due_at - now()) / 60) AS minutes_left,
       now() > sla_due_at AS overdue, touches_count, reopened_at
FROM v_lead_leads
WHERE status = 'new'
ORDER BY sla_due_at;

-- Воронка: месяц прихода лида × канал.
CREATE OR REPLACE VIEW v_lead_funnel AS
SELECT to_char(date_trunc('month', received_at), 'YYYY-MM') AS period, channel,
       count(*)                                                        AS leads,
       count(*) FILTER (WHERE first_response_at IS NOT NULL)           AS reached,
       count(*) FILTER (WHERE qualified_at IS NOT NULL OR status = 'won') AS qualified,
       count(*) FILTER (WHERE status = 'won')                          AS won,
       count(*) FILTER (WHERE status = 'lost')                         AS lost,
       round(100.0 * count(*) FILTER (WHERE status = 'won') / count(*), 1) AS conversion_pct,
       sum(revenue)::numeric(18,2)                                     AS revenue
FROM v_lead_leads
GROUP BY 1, 2;

-- Экран «Кампании»: месяц × кампания. Лиды и выручка — по месяцу прихода лида (когорта),
-- расходы — по месяцу расхода. CPL = расход / лиды; CAC = расход / лиды с продажей;
-- ROMI = (выручка × romi_margin_pct % − расход) / расход × 100. Только валюта отчётов.
CREATE OR REPLACE VIEW v_lead_campaigns AS
WITH l AS (
    SELECT date_trunc('month', received_at)::date AS month, campaign,
           string_agg(DISTINCT channel, ', ') AS channels,
           count(*) AS leads,
           count(*) FILTER (WHERE qualified_at IS NOT NULL OR status = 'won') AS qualified,
           count(*) FILTER (WHERE status = 'won') AS won,
           sum(revenue) AS revenue
    FROM v_lead_leads GROUP BY 1, 2
),
c AS (
    SELECT date_trunc('month', day)::date AS month, campaign, string_agg(DISTINCT channel, ', ') AS ad_channels,
           sum(cost) AS cost
    FROM src_lead_ad_costs WHERE currency = lead_currency()
    GROUP BY 1, 2
),
j AS (
    SELECT COALESCE(l.month, c.month) AS month, COALESCE(l.campaign, c.campaign) AS campaign,
           COALESCE(l.channels, c.ad_channels) AS channels,
           COALESCE(l.leads, 0) AS leads, COALESCE(l.qualified, 0) AS qualified, COALESCE(l.won, 0) AS won,
           COALESCE(l.revenue, 0)::numeric(18,2) AS revenue, c.cost::numeric(18,2) AS cost
    FROM l FULL JOIN c ON c.month = l.month AND c.campaign = l.campaign
)
SELECT month, to_char(month, 'YYYY-MM') AS period, campaign, channels, leads, qualified, won, revenue, cost,
       round(cost / NULLIF(leads, 0), 2) AS cpl,
       round(cost / NULLIF(won, 0), 2)   AS cac,
       round(100 * (revenue * (airl_setting('leads', 'romi_margin_pct', '100'))::text::numeric / 100 - cost) / NULLIF(cost, 0), 1) AS romi_pct,
       (cost > 0 AND leads = 0) AS cost_without_leads,
       lead_currency()::char(3) AS currency
FROM j;

-- Причины потерь по месяцам.
CREATE OR REPLACE VIEW v_lead_lost_reasons AS
SELECT to_char(date_trunc('month', closed_at), 'YYYY-MM') AS period, lost_reason, lost_reason_title, count(*) AS leads
FROM v_lead_leads WHERE status = 'lost'
GROUP BY 1, 2, 3;

-- Нагрузка менеджеров.
CREATE OR REPLACE VIEW v_lead_managers AS
SELECT assigned_to,
       count(*) FILTER (WHERE status IN ('new', 'in_work', 'qualified')) AS open_leads,
       count(*) FILTER (WHERE status = 'new' AND now() > sla_due_at)     AS overdue_first_response,
       count(*) FILTER (WHERE received_at >= now() - interval '30 days') AS leads_30d,
       count(*) FILTER (WHERE status = 'won' AND received_at >= now() - interval '30 days') AS won_30d
FROM v_lead_leads GROUP BY assigned_to;

-- Аудитория рассылок: только лиды с действующим согласием. Контакты отдаёт сервер
-- сервису рассылки; на экране — только маска.
CREATE OR REPLACE VIEW v_lead_audience AS
SELECT l.lead_no, l.public_code, l.channel, l.city, l.interest, l.phone_masked, l.email_masked, l.has_messenger,
       c.at AS consent_at, c.source AS consent_source
FROM v_lead_leads l
JOIN LATERAL (SELECT granted, at, source FROM lead_consents WHERE lead_id = l.id ORDER BY at DESC, id DESC LIMIT 1) c ON c.granted;

-- Показатель: медиана минут от начала рабочего времени до первого ответа, по месяцу
-- прихода лида. Лиды без ответа считаются по текущему моменту — молчание не прячется.
CREATE OR REPLACE VIEW m_lead_first_response_minutes AS
WITH x AS (
    SELECT date_trunc('month', received_at) AS m,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY
               extract(epoch FROM greatest(COALESCE(first_response_at, now()) - sla_start_at, interval '0')) / 60))::numeric, 1) AS v
    FROM lead_leads
    WHERE channel <> 'manual'
    GROUP BY 1
)
SELECT 'lead_first_response_minutes'::text AS metric_id, to_char(m, 'YYYY-MM') AS period, v AS value,
       'мин'::text AS unit,
       airl_traffic(v, (airl_setting('leads', 'sla_minutes', '15'))::text::numeric,
                       (airl_setting('leads', 'frt_bad_minutes', '60'))::text::numeric, false) AS status
FROM x;

-- Показатель: доля лидов месяца, дошедших до продажи (по месяцу прихода лида).
-- Последние 1–2 месяца ещё «дозревают» — сделки приходят позже.
CREATE OR REPLACE VIEW m_lead_to_sale_conversion AS
WITH x AS (
    SELECT date_trunc('month', received_at) AS m,
           round(100.0 * count(*) FILTER (WHERE status = 'won') / count(*), 1) AS v
    FROM lead_leads GROUP BY 1
)
SELECT 'lead_to_sale_conversion'::text AS metric_id, to_char(m, 'YYYY-MM') AS period, v AS value,
       '%'::text AS unit,
       airl_traffic(v, (airl_setting('leads', 'conversion_warn', '10'))::text::numeric,
                       (airl_setting('leads', 'conversion_bad', '5'))::text::numeric, true) AS status
FROM x;

-- Показатель: ROMI компании по месяцу (все кампании с расходом), %.
CREATE OR REPLACE VIEW m_lead_romi AS
WITH x AS (
    SELECT period, sum(revenue) FILTER (WHERE cost > 0) AS revenue, sum(cost) AS cost
    FROM v_lead_campaigns GROUP BY period
)
SELECT 'romi'::text AS metric_id, period,
       round(100 * (revenue * (airl_setting('leads', 'romi_margin_pct', '100'))::text::numeric / 100 - cost) / cost, 1) AS value,
       '%'::text AS unit,
       airl_traffic(round(100 * (revenue * (airl_setting('leads', 'romi_margin_pct', '100'))::text::numeric / 100 - cost) / cost, 1),
           (airl_setting('leads', 'romi_warn', '100'))::text::numeric,
           (airl_setting('leads', 'romi_bad', '0'))::text::numeric, true) AS status
FROM x WHERE cost > 0;

-- Уведомления (раз в 5–10 минут): лид без первого ответа после срока — руководителю
-- продаж, один раз на лид.
CREATE OR REPLACE FUNCTION lead_queue_notifications() RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_channel text := airl_setting('leads', 'channel', '"telegram"') #>> '{}';
    v_head    text := airl_setting('leads', 'escalation_recipient', '"role:sales_head"') #>> '{}';
    v_n int;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'leads:sla:' || l.lead_no || ':' || v_head, 'leads', v_channel, v_head,
           'Лид ' || l.lead_no || ' без ответа ' || floor(extract(epoch FROM now() - l.sla_start_at) / 60)
           || ' мин (менеджер ' || COALESCE(l.assigned_to, 'не назначен') || ', кампания ' || l.campaign || ')'
    FROM lead_leads l
    WHERE l.status = 'new' AND l.first_response_at IS NULL AND now() > l.sla_due_at
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;
