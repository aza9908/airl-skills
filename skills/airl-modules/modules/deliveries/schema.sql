-- Модуль «Доставка» (deliveries): от подтверждённого заказа до подтверждения получения.
-- Маршруты на день по водителям, порядок остановок (вручную и подсказкой «ближайший
-- следующий» — эвристика, не оптимизация), экран водителя в телефоне, статусы с причинами,
-- подтверждение (имя, код клиента, фото), отзыв клиента, своевременность и стоимость.
-- Требует kit/kit.sql в той же схеме и представления src_dlv_orders, src_dlv_drivers
-- (адаптер или demo_src.sql). Карта — ссылкой в приложение карт телефона, платный API не нужен.
-- GPS-трекинга нет: координаты телефона пишутся только при смене статуса, если это
-- включено настройкой geo_on_status и водитель дал согласие.

CREATE SEQUENCE IF NOT EXISTS dlv_route_seq;
CREATE SEQUENCE IF NOT EXISTS dlv_delivery_seq;

-- Маршрут: водитель × день. Один действующий маршрут на водителя в день.
CREATE TABLE IF NOT EXISTS dlv_routes (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_no       text          NOT NULL UNIQUE DEFAULT 'RT-' || lpad(nextval('dlv_route_seq')::text, 6, '0'),
    route_date     date          NOT NULL,
    driver_id      text          NOT NULL,                     -- ключ из src_dlv_drivers
    status         text          NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'started', 'finished', 'cancelled')),
    started_at     timestamptz,
    finished_at    timestamptz,
    odometer_start int           CHECK (odometer_start IS NULL OR odometer_start >= 0),
    odometer_end   int,
    extra_cost     numeric(18,2) NOT NULL DEFAULT 0 CHECK (extra_cost >= 0),   -- парковка, платная дорога
    currency       char(3)       NOT NULL DEFAULT (airl_setting('deliveries', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}'),
    cancel_reason  text,
    created_at     timestamptz   NOT NULL DEFAULT now(),
    created_by     text          NOT NULL,
    updated_at     timestamptz,
    updated_by     text,
    CHECK (odometer_end IS NULL OR (odometer_start IS NOT NULL AND odometer_end >= odometer_start)),
    CHECK (status NOT IN ('started', 'finished') OR started_at IS NOT NULL),
    CHECK (status <> 'finished' OR (finished_at IS NOT NULL AND finished_at >= started_at)),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS dlv_routes_driver_day ON dlv_routes (driver_id, route_date) WHERE status <> 'cancelled';
CREATE INDEX IF NOT EXISTS dlv_routes_date_idx ON dlv_routes (route_date, status);

-- Доставка: попытка доставить заказ. Повторная попытка после неудачи — новая строка (attempt + 1).
-- Адрес, координаты и окно копируются из заказа на момент создания: водитель и отчёт
-- видят то, что было в путевом листе, даже если заказ потом поправили.
CREATE TABLE IF NOT EXISTS dlv_deliveries (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    delivery_no      text          NOT NULL UNIQUE DEFAULT 'DL-' || lpad(nextval('dlv_delivery_seq')::text, 6, '0'),
    order_id         text          NOT NULL,                   -- ключ из src_dlv_orders
    attempt          int           NOT NULL DEFAULT 1 CHECK (attempt >= 1),
    address          text          NOT NULL,                   -- ПДн, если клиент — физлицо
    lat              numeric(9,6)  CHECK (lat BETWEEN -90 AND 90),
    lon              numeric(9,6)  CHECK (lon BETWEEN -180 AND 180),
    window_from      timestamptz   NOT NULL,
    window_to        timestamptz   NOT NULL,
    weight_kg        numeric(10,1) CHECK (weight_kg IS NULL OR weight_kg >= 0),
    volume_m3        numeric(10,2) CHECK (volume_m3 IS NULL OR volume_m3 >= 0),
    amount_to_collect numeric(18,2) NOT NULL DEFAULT 0 CHECK (amount_to_collect >= 0),  -- оплата при получении
    currency         char(3)       NOT NULL DEFAULT (airl_setting('deliveries', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}'),
    status           text          NOT NULL DEFAULT 'new'
                     CHECK (status IN ('new', 'assigned', 'in_transit', 'delivered', 'partially_delivered', 'failed', 'returned', 'cancelled')),
    route_id         bigint        REFERENCES dlv_routes (id),
    stop_seq         int           CHECK (stop_seq > 0),
    status_at        timestamptz,                              -- когда водитель нажал (может прийти позже из офлайна)
    event_lat        numeric(9,6),                             -- геопозиция телефона при смене статуса (с согласия)
    event_lon        numeric(9,6),
    departed_at      timestamptz,
    delivered_at     timestamptz,
    recipient_name   text,                                     -- кто принял (ПДн)
    confirm_code     text          NOT NULL DEFAULT lpad((floor(random() * 10000))::int::text, 4, '0') CHECK (confirm_code ~ '^[0-9]{4}$'),
    code_confirmed   boolean       NOT NULL DEFAULT false,
    code_attempts    int           NOT NULL DEFAULT 0 CHECK (code_attempts >= 0),
    reason_code      text          CHECK (reason_code IN ('client_absent', 'address_wrong', 'client_refused', 'no_payment',
                                                          'damaged', 'wrong_items', 'vehicle_issue', 'out_of_time', 'other')),
    late_reason      text          CHECK (late_reason IN ('traffic', 'previous_stop_delay', 'loading_delay', 'address_search',
                                                          'client_asked_later', 'vehicle_issue', 'other')),
    comment          text,
    collected_amount numeric(18,2) CHECK (collected_amount IS NULL OR collected_amount >= 0),
    cancel_reason    text,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    created_by       text          NOT NULL,
    updated_at       timestamptz,
    updated_by       text,
    UNIQUE (order_id, attempt),
    UNIQUE (route_id, stop_seq),
    CHECK (window_to > window_from),
    CHECK ((lat IS NULL) = (lon IS NULL)),
    CHECK ((event_lat IS NULL) = (event_lon IS NULL)),
    CHECK ((route_id IS NULL) = (stop_seq IS NULL)),
    CHECK (status NOT IN ('new', 'cancelled') OR route_id IS NULL),
    CHECK (status IN ('new', 'cancelled') OR route_id IS NOT NULL),
    CHECK (status NOT IN ('in_transit', 'delivered', 'partially_delivered', 'failed', 'returned') OR departed_at IS NOT NULL),
    CHECK (status NOT IN ('delivered', 'partially_delivered') OR (delivered_at IS NOT NULL AND recipient_name IS NOT NULL)),
    CHECK (status <> 'partially_delivered' OR (reason_code IS NOT NULL AND comment IS NOT NULL)),
    CHECK (status NOT IN ('failed', 'returned') OR reason_code IS NOT NULL),
    CHECK (reason_code IS DISTINCT FROM 'other' OR comment IS NOT NULL),
    CHECK (status <> 'cancelled' OR cancel_reason IS NOT NULL)
);
-- Одна живая доставка на заказ: нельзя случайно отправить заказ двумя машинами.
CREATE UNIQUE INDEX IF NOT EXISTS dlv_deliveries_order_live ON dlv_deliveries (order_id)
    WHERE status NOT IN ('cancelled', 'failed', 'returned');
CREATE INDEX IF NOT EXISTS dlv_deliveries_route_idx ON dlv_deliveries (route_id, stop_seq);
CREATE INDEX IF NOT EXISTS dlv_deliveries_status_idx ON dlv_deliveries (status, window_from);

-- Отзыв клиента после доставки (один на доставку). Низкая оценка — повод для обращения
-- в модуле complaints (object_type = 'order', object_id = order_id).
CREATE TABLE IF NOT EXISTS dlv_feedback (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    delivery_id   bigint      NOT NULL UNIQUE REFERENCES dlv_deliveries (id),
    rating        int         NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment       text,
    channel       text        NOT NULL CHECK (channel IN ('telegram', 'sms', 'call', 'driver', 'site')),
    received_at   timestamptz NOT NULL DEFAULT now(),
    complaint_ref text,                                        -- номер обращения в complaints
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text        NOT NULL,
    updated_at    timestamptz,
    updated_by    text
);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['dlv_routes', 'dlv_deliveries', 'dlv_feedback'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_touch', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION airl_touch()', t || '_touch', t);
    END LOOP;
END $$;

-- Расстояние по прямой, км (формула гаверсинусов). Для подсказки порядка, не для навигации.
CREATE OR REPLACE FUNCTION dlv_km(p_lat1 numeric, p_lon1 numeric, p_lat2 numeric, p_lon2 numeric) RETURNS numeric
LANGUAGE sql IMMUTABLE SET search_path FROM CURRENT AS $$
    SELECT round((2 * 6371 * asin(sqrt(
        power(sin(radians((p_lat2 - p_lat1)::float8) / 2), 2)
        + cos(radians(p_lat1::float8)) * cos(radians(p_lat2::float8)) * power(sin(radians((p_lon2 - p_lon1)::float8) / 2), 2))))::numeric, 2)
$$;

-- Ссылка на точку в приложении карт (Яндекс, 2ГИС, Google) — без платного API.
CREATE OR REPLACE FUNCTION dlv_map_url(p_lat numeric, p_lon numeric) RETURNS text
LANGUAGE sql STABLE SET search_path FROM CURRENT AS $$
    SELECT CASE WHEN p_lat IS NULL THEN NULL ELSE
        CASE airl_setting('deliveries', 'map_provider', '"yandex"') #>> '{}'
            WHEN '2gis'   THEN 'https://2gis.kz/geo/' || p_lon || ',' || p_lat
            WHEN 'google' THEN 'https://www.google.com/maps/search/?api=1&query=' || p_lat || ',' || p_lon
            ELSE 'https://yandex.kz/maps/?pt=' || p_lon || ',' || p_lat || '&z=17&l=map'
        END END
$$;

-- ───────────── Статусы ─────────────
CREATE OR REPLACE FUNCTION dlv_status_guard() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_actor   text := coalesce(NEW.updated_by, NEW.created_by, 'system');
    v_allowed text[];
    v_route   dlv_routes%ROWTYPE;
    v_proof   jsonb;
    v_order   record;
    v_org     text := airl_setting('deliveries', 'org_name', '"STEP COFFEE"') #>> '{}';
    v_mgr     text := airl_setting('deliveries', 'manager_recipient', '"logistics_head"') #>> '{}';
    v_tz      text := airl_setting('deliveries', 'timezone', '"Asia/Almaty"') #>> '{}';
    v_details jsonb;
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> (CASE TG_TABLE_NAME WHEN 'dlv_routes' THEN 'planned' ELSE 'new' END) THEN
            RAISE EXCEPTION 'deliveries: новая запись % создаётся в начальном статусе', TG_TABLE_NAME;
        END IF;
        RETURN NEW;
    END IF;

    IF TG_TABLE_NAME = 'dlv_deliveries' THEN
        IF NEW.route_id IS DISTINCT FROM OLD.route_id
           AND NOT ((OLD.status = 'new' AND NEW.status = 'assigned') OR (OLD.status = 'assigned' AND NEW.status IN ('new', 'cancelled'))) THEN
            RAISE EXCEPTION 'deliveries: доставка % уже в маршруте — сначала снимите её с маршрута', NEW.delivery_no
                USING ERRCODE = 'unique_violation';
        END IF;
    END IF;
    IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;

    v_allowed := CASE TG_TABLE_NAME
        WHEN 'dlv_routes' THEN ARRAY['planned>started', 'planned>cancelled', 'started>finished']
        ELSE ARRAY['new>assigned', 'new>cancelled', 'assigned>new', 'assigned>cancelled', 'assigned>in_transit',
                   'in_transit>delivered', 'in_transit>partially_delivered', 'in_transit>failed', 'in_transit>returned',
                   'failed>returned']
    END;
    IF NOT (OLD.status || '>' || NEW.status) = ANY (v_allowed) THEN
        RAISE EXCEPTION 'deliveries: переход % → % не разрешён (%)', OLD.status, NEW.status, TG_TABLE_NAME;
    END IF;

    IF TG_TABLE_NAME = 'dlv_routes' THEN
        IF NEW.status = 'started' THEN NEW.started_at := coalesce(NEW.started_at, now()); END IF;
        IF NEW.status = 'finished' THEN
            IF EXISTS (SELECT 1 FROM dlv_deliveries d WHERE d.route_id = NEW.id AND d.status IN ('assigned', 'in_transit')) THEN
                RAISE EXCEPTION 'deliveries: в маршруте % есть незакрытые остановки', NEW.route_no;
            END IF;
            NEW.finished_at := coalesce(NEW.finished_at, now());
        END IF;
        IF NEW.status = 'cancelled' AND EXISTS (SELECT 1 FROM dlv_deliveries d WHERE d.route_id = NEW.id) THEN
            RAISE EXCEPTION 'deliveries: в маршруте % есть доставки — сначала снимите их', NEW.route_no;
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (v_actor, 'deliveries', 'dlv_routes', NEW.id::text, 'status', OLD.status, NEW.status, NEW.cancel_reason);
        RETURN NEW;
    END IF;

    -- Доставки.
    IF NEW.status_at IS NULL OR NEW.status_at IS NOT DISTINCT FROM OLD.status_at THEN NEW.status_at := now(); END IF;
    IF NEW.status_at > now() + interval '5 minutes' THEN
        RAISE EXCEPTION 'deliveries: время события в будущем';
    END IF;
    IF NEW.status = 'assigned' THEN
        SELECT * INTO v_route FROM dlv_routes WHERE id = NEW.route_id;
        IF v_route.status NOT IN ('planned', 'started') THEN
            RAISE EXCEPTION 'deliveries: маршрут % уже %', v_route.route_no, v_route.status;
        END IF;
    ELSIF NEW.status = 'in_transit' THEN
        SELECT * INTO v_route FROM dlv_routes WHERE id = NEW.route_id;
        IF v_route.status <> 'started' THEN RAISE EXCEPTION 'deliveries: маршрут % не начат', v_route.route_no; END IF;
        NEW.departed_at := NEW.status_at;
    ELSIF NEW.status IN ('delivered', 'partially_delivered') THEN
        NEW.delivered_at := NEW.status_at;
        IF NEW.delivered_at < NEW.departed_at THEN RAISE EXCEPTION 'deliveries: доставлено раньше, чем выехали'; END IF;
        v_proof := airl_setting('deliveries', 'proof_required', '["name"]');
        IF v_proof ? 'code' AND NOT NEW.code_confirmed THEN
            RAISE EXCEPTION 'deliveries: нужен код получения от клиента';
        END IF;
        IF v_proof ? 'photo' AND NOT EXISTS (SELECT 1 FROM airl_attachments a WHERE a.module = 'deliveries'
                                                AND a.entity = 'dlv_deliveries' AND a.entity_id = NEW.id::text) THEN
            RAISE EXCEPTION 'deliveries: нужно фото подтверждения';
        END IF;
        IF NEW.delivered_at > NEW.window_to + make_interval(mins => (airl_setting('deliveries', 'late_grace_minutes', '15'))::text::int)
           AND NEW.late_reason IS NULL THEN
            RAISE EXCEPTION 'deliveries: доставка позже окна — укажите причину опоздания';
        END IF;
        IF NEW.amount_to_collect > 0 AND NEW.collected_amount IS NULL THEN
            RAISE EXCEPTION 'deliveries: укажите, сколько получено от клиента (к оплате %)', NEW.amount_to_collect;
        END IF;
    ELSIF NEW.status = 'new' THEN
        NEW.route_id := NULL; NEW.stop_seq := NULL;
    ELSIF NEW.status = 'cancelled' THEN
        NEW.route_id := NULL; NEW.stop_seq := NULL;
        UPDATE airl_notifications SET cancelled_at = now(), error = 'cancelled: delivery cancelled'
        WHERE module = 'deliveries' AND sent_at IS NULL AND cancelled_at IS NULL
          AND split_part(dedup_key, ':', 3) = NEW.id::text;
    END IF;

    -- Уведомления.
    SELECT o.* INTO v_order FROM src_dlv_orders o WHERE o.order_id = NEW.order_id;
    IF NEW.status = 'in_transit' AND v_order.contact_phone IS NOT NULL
       AND (airl_setting('deliveries', 'notify_client', 'true'))::text::boolean THEN
        INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
        VALUES ('deliveries:on_the_way:' || NEW.id || ':' || v_order.client_id, 'deliveries',
                airl_setting('deliveries', 'client_channel', '"sms"') #>> '{}', v_order.contact_phone,
                v_org || ': заказ ' || v_order.order_no || ' в пути, привезём '
                || to_char(NEW.window_from AT TIME ZONE v_tz, 'HH24:MI') || '–' || to_char(NEW.window_to AT TIME ZONE v_tz, 'HH24:MI')
                || '. Код получения для водителя: ' || NEW.confirm_code || '.')
        ON CONFLICT (dedup_key) DO NOTHING;
    ELSIF NEW.status IN ('delivered', 'partially_delivered') AND v_order.contact_phone IS NOT NULL
          AND (airl_setting('deliveries', 'notify_client', 'true'))::text::boolean THEN
        INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text, not_before)
        VALUES ('deliveries:feedback:' || NEW.id || ':' || v_order.client_id, 'deliveries',
                airl_setting('deliveries', 'client_channel', '"sms"') #>> '{}', v_order.contact_phone,
                v_org || ': как прошла доставка заказа ' || v_order.order_no || '? Оцените от 1 до 5 ответом на это сообщение.',
                greatest(now(), NEW.delivered_at + make_interval(hours => (airl_setting('deliveries', 'feedback_delay_hours', '2'))::text::int)))
        ON CONFLICT (dedup_key) DO NOTHING;
    ELSIF NEW.status IN ('failed', 'returned') THEN
        INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
        VALUES ('deliveries:' || NEW.status || ':' || NEW.id || ':' || v_mgr, 'deliveries',
                airl_setting('deliveries', 'channel', '"telegram"') #>> '{}', v_mgr,
                'Доставка ' || NEW.delivery_no || ' (заказ ' || coalesce(v_order.order_no, NEW.order_id) || ', '
                || coalesce(v_order.client_name, '') || '): ' || NEW.status || ', причина ' || NEW.reason_code
                || coalesce(' — ' || NEW.comment, ''))
        ON CONFLICT (dedup_key) DO NOTHING;
    END IF;

    v_details := jsonb_strip_nulls(jsonb_build_object('at', NEW.status_at, 'lat', NEW.event_lat, 'lon', NEW.event_lon,
                                                      'route_id', coalesce(NEW.route_id, OLD.route_id)));
    INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment, details)
    VALUES (v_actor, 'deliveries', 'dlv_deliveries', NEW.id::text, 'status', OLD.status, NEW.status,
            coalesce(NEW.reason_code || coalesce(': ' || NEW.comment, ''), NEW.late_reason, NEW.cancel_reason), v_details);
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS dlv_routes_status ON dlv_routes;
CREATE TRIGGER dlv_routes_status BEFORE INSERT OR UPDATE ON dlv_routes FOR EACH ROW EXECUTE FUNCTION dlv_status_guard();
DROP TRIGGER IF EXISTS dlv_deliveries_status ON dlv_deliveries;
CREATE TRIGGER dlv_deliveries_status BEFORE INSERT OR UPDATE ON dlv_deliveries FOR EACH ROW EXECUTE FUNCTION dlv_status_guard();

-- Низкая оценка — руководителю сервиса (один раз на отзыв).
CREATE OR REPLACE FUNCTION dlv_feedback_notify() RETURNS trigger LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_to text := airl_setting('deliveries', 'service_recipient', '"service_head"') #>> '{}';
    d    record;
BEGIN
    IF NEW.rating <= (airl_setting('deliveries', 'low_rating', '3'))::text::int THEN
        SELECT x.delivery_no, x.order_id, o.order_no, o.client_name INTO d
        FROM dlv_deliveries x LEFT JOIN src_dlv_orders o ON o.order_id = x.order_id WHERE x.id = NEW.delivery_id;
        INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
        VALUES ('deliveries:low_rating:' || NEW.delivery_id || ':' || v_to, 'deliveries',
                airl_setting('deliveries', 'channel', '"telegram"') #>> '{}', v_to,
                'Оценка ' || NEW.rating || ' за доставку заказа ' || coalesce(d.order_no, d.order_id) || ' (' || coalesce(d.client_name, '')
                || ')' || coalesce(': «' || NEW.comment || '»', '') || '. Заведите обращение (объект — заказ).')
        ON CONFLICT (dedup_key) DO NOTHING;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS dlv_feedback_notify ON dlv_feedback;
CREATE TRIGGER dlv_feedback_notify AFTER INSERT ON dlv_feedback FOR EACH ROW EXECUTE FUNCTION dlv_feedback_notify();

-- ───────────── Действия ─────────────

-- Доставки из подтверждённых заказов (запускать каждые 5–15 минут, дублей не будет).
-- Заказ отменён в учёте — не выехавшая доставка отменяется.
CREATE OR REPLACE FUNCTION dlv_generate(p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE n int;
BEGIN
    INSERT INTO dlv_deliveries (order_id, address, lat, lon, window_from, window_to, weight_kg, volume_m3,
                                amount_to_collect, currency, created_by)
    SELECT o.order_id, o.address || coalesce(', ' || o.city, ''), o.lat, o.lon, o.window_from, o.window_to,
           o.weight_kg, o.volume_m3,
           CASE WHEN o.payment_status IN ('cod', 'unpaid') THEN o.amount ELSE 0 END, o.currency, p_actor
    FROM src_dlv_orders o
    WHERE o.status = 'confirmed'
      AND NOT EXISTS (SELECT 1 FROM dlv_deliveries d WHERE d.order_id = o.order_id)
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    UPDATE dlv_deliveries d SET status = 'cancelled', cancel_reason = 'заказ отменён в учёте', updated_by = p_actor
    FROM src_dlv_orders o
    WHERE o.order_id = d.order_id AND o.status = 'cancelled' AND d.status IN ('new', 'assigned');
    RETURN n;
END $$;

-- Создать маршрут водителю на день. Второй маршрут тому же водителю на тот же день база не даст.
CREATE OR REPLACE FUNCTION dlv_create_route(p_date date, p_driver text, p_actor text) RETURNS bigint
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE v_id bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM src_dlv_drivers d WHERE d.driver_id = p_driver AND d.active) THEN
        RAISE EXCEPTION 'deliveries: водитель % не найден или не работает', p_driver;
    END IF;
    INSERT INTO dlv_routes (route_date, driver_id, created_by) VALUES (p_date, p_driver, p_actor) RETURNING id INTO v_id;
    RETURN v_id;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'deliveries: у водителя % уже есть маршрут на %', p_driver, to_char(p_date, 'DD.MM.YYYY')
        USING ERRCODE = 'unique_violation';
END $$;

-- Поставить доставку в маршрут. Блокирует доставку и маршрут: два диспетчера
-- не поставят одну доставку в два маршрута, второй получит ошибку.
CREATE OR REPLACE FUNCTION dlv_assign(p_delivery_id bigint, p_route_id bigint, p_actor text) RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    d dlv_deliveries%ROWTYPE;
    r dlv_routes%ROWTYPE;
    v_seq int;
BEGIN
    SELECT * INTO r FROM dlv_routes WHERE id = p_route_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'deliveries: маршрут % не найден', p_route_id; END IF;
    SELECT * INTO d FROM dlv_deliveries WHERE id = p_delivery_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'deliveries: доставка % не найдена', p_delivery_id; END IF;
    IF d.status <> 'new' THEN
        RAISE EXCEPTION 'deliveries: доставка % уже % (маршрут %)', d.delivery_no, d.status,
            coalesce((SELECT route_no FROM dlv_routes WHERE id = d.route_id), '—') USING ERRCODE = 'unique_violation';
    END IF;
    SELECT coalesce(max(stop_seq), 0) + 1 INTO v_seq FROM dlv_deliveries WHERE route_id = r.id;
    UPDATE dlv_deliveries SET status = 'assigned', route_id = r.id, stop_seq = v_seq, updated_by = p_actor
    WHERE id = d.id;
    RETURN v_seq;
END $$;

CREATE OR REPLACE FUNCTION dlv_unassign(p_delivery_id bigint, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    UPDATE dlv_deliveries SET status = 'new', updated_by = p_actor WHERE id = p_delivery_id AND status = 'assigned';
    IF NOT FOUND THEN RAISE EXCEPTION 'deliveries: снять можно только назначенную, ещё не выехавшую доставку'; END IF;
END $$;

-- Порядок остановок вручную: массив id доставок маршрута в нужном порядке.
CREATE OR REPLACE FUNCTION dlv_reorder(p_route_id bigint, p_ids bigint[], p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE r dlv_routes%ROWTYPE;
BEGIN
    SELECT * INTO r FROM dlv_routes WHERE id = p_route_id FOR UPDATE;
    IF NOT FOUND OR r.status NOT IN ('planned', 'started') THEN
        RAISE EXCEPTION 'deliveries: порядок меняется только у запланированного или начатого маршрута';
    END IF;
    IF (SELECT array_agg(id ORDER BY id) FROM dlv_deliveries WHERE route_id = r.id)
       IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(p_ids) x) THEN
        RAISE EXCEPTION 'deliveries: в списке должны быть ровно все доставки маршрута, без повторов';
    END IF;
    UPDATE dlv_deliveries SET stop_seq = stop_seq + 10000 WHERE route_id = r.id;
    UPDATE dlv_deliveries d SET stop_seq = x.ord, updated_by = p_actor
    FROM unnest(p_ids) WITH ORDINALITY AS x(id, ord)
    WHERE d.id = x.id;
END $$;

-- Подсказка порядка: «ближайший следующий» от склада по прямой. Это эвристика, а не
-- оптимизация: окна, пробки и односторонние улицы не учитываются — диспетчер двигает
-- остановки вручную. Доставки без координат — в конце, по началу окна.
CREATE OR REPLACE FUNCTION dlv_suggest_sequence(p_route_id bigint)
RETURNS TABLE (delivery_id bigint, seq int, leg_km numeric)
LANGUAGE plpgsql STABLE SET search_path FROM CURRENT AS $$
DECLARE
    v_ids  bigint[];
    v_lat  numeric[];
    v_lon  numeric[];
    v_used boolean[];
    c_lat  numeric := (airl_setting('deliveries', 'depot_lat', '43.2567'))::text::numeric;
    c_lon  numeric := (airl_setting('deliveries', 'depot_lon', '76.9286'))::text::numeric;
    best   int;
    best_d numeric;
    dd     numeric;
    n      int;
    s      int := 0;
    rec    record;
BEGIN
    SELECT array_agg(d.id ORDER BY d.id), array_agg(d.lat ORDER BY d.id), array_agg(d.lon ORDER BY d.id)
    INTO v_ids, v_lat, v_lon
    FROM dlv_deliveries d WHERE d.route_id = p_route_id AND d.lat IS NOT NULL;
    n := coalesce(array_length(v_ids, 1), 0);
    v_used := array_fill(false, ARRAY[greatest(n, 1)]);
    FOR k IN 1..n LOOP
        best := NULL; best_d := NULL;
        FOR i IN 1..n LOOP
            CONTINUE WHEN v_used[i];
            dd := dlv_km(c_lat, c_lon, v_lat[i], v_lon[i]);
            IF best_d IS NULL OR dd < best_d THEN best := i; best_d := dd; END IF;
        END LOOP;
        v_used[best] := true; s := s + 1;
        delivery_id := v_ids[best]; seq := s; leg_km := best_d;
        RETURN NEXT;
        c_lat := v_lat[best]; c_lon := v_lon[best];
    END LOOP;
    FOR rec IN SELECT d.id FROM dlv_deliveries d WHERE d.route_id = p_route_id AND d.lat IS NULL ORDER BY d.window_from, d.id LOOP
        s := s + 1; delivery_id := rec.id; seq := s; leg_km := NULL;
        RETURN NEXT;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION dlv_apply_suggestion(p_route_id bigint, p_actor text) RETURNS void
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    PERFORM dlv_reorder(p_route_id, ARRAY(SELECT s.delivery_id FROM dlv_suggest_sequence(p_route_id) s ORDER BY s.seq), p_actor);
END $$;

-- Начать маршрут (пробег на старте) — водитель нажимает «Начать маршрут».
CREATE OR REPLACE FUNCTION dlv_start_route(p_route_id bigint, p_odometer int, p_actor text, p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    UPDATE dlv_routes SET status = 'started', started_at = p_at, odometer_start = coalesce(p_odometer, odometer_start), updated_by = p_actor
    WHERE id = p_route_id AND status = 'planned';
    IF NOT FOUND THEN RAISE EXCEPTION 'deliveries: начать можно только запланированный маршрут'; END IF;
END $$;

CREATE OR REPLACE FUNCTION dlv_finish_route(p_route_id bigint, p_odometer int, p_extra_cost numeric, p_actor text,
                                            p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
BEGIN
    UPDATE dlv_routes SET status = 'finished', finished_at = p_at, odometer_end = p_odometer,
                          extra_cost = coalesce(p_extra_cost, extra_cost), updated_by = p_actor
    WHERE id = p_route_id AND status = 'started';
    IF NOT FOUND THEN RAISE EXCEPTION 'deliveries: закончить можно только начатый маршрут'; END IF;
END $$;

-- Код получения от клиента. После 5 неверных попыток проверка блокируется (подбор).
CREATE OR REPLACE FUNCTION dlv_check_code(p_delivery_id bigint, p_code text, p_actor text) RETURNS boolean
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE d dlv_deliveries%ROWTYPE;
BEGIN
    SELECT * INTO d FROM dlv_deliveries WHERE id = p_delivery_id FOR UPDATE;
    IF NOT FOUND OR d.status <> 'in_transit' THEN RAISE EXCEPTION 'deliveries: код проверяется у доставки в пути'; END IF;
    IF d.code_attempts >= 5 THEN RAISE EXCEPTION 'deliveries: слишком много попыток — позвоните диспетчеру'; END IF;
    IF btrim(p_code) = d.confirm_code THEN
        UPDATE dlv_deliveries SET code_confirmed = true, updated_by = p_actor WHERE id = d.id;
        RETURN true;
    END IF;
    UPDATE dlv_deliveries SET code_attempts = code_attempts + 1, updated_by = p_actor WHERE id = d.id;
    RETURN false;
END $$;

-- Смена статуса с телефона водителя. p_at — время нажатия (офлайн-очередь присылает позже).
-- Геопозиция сохраняется, только если включено geo_on_status; иначе отбрасывается.
-- Начало первой доставки автоматически начинает маршрут.
CREATE OR REPLACE FUNCTION dlv_set_status(p_delivery_id bigint, p_status text, p_actor text,
                                          p_reason text DEFAULT NULL, p_comment text DEFAULT NULL,
                                          p_recipient text DEFAULT NULL, p_late_reason text DEFAULT NULL,
                                          p_collected numeric DEFAULT NULL, p_lat numeric DEFAULT NULL,
                                          p_lon numeric DEFAULT NULL, p_at timestamptz DEFAULT now())
RETURNS void LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    d   dlv_deliveries%ROWTYPE;
    geo boolean := (airl_setting('deliveries', 'geo_on_status', 'false'))::text::boolean;
BEGIN
    SELECT * INTO d FROM dlv_deliveries WHERE id = p_delivery_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'deliveries: доставка % не найдена', p_delivery_id; END IF;
    IF p_status NOT IN ('in_transit', 'delivered', 'partially_delivered', 'failed', 'returned') THEN
        RAISE EXCEPTION 'deliveries: водитель не ставит статус %', p_status;
    END IF;
    IF p_status = 'in_transit' THEN
        UPDATE dlv_routes SET status = 'started', started_at = least(p_at, now()), updated_by = p_actor
        WHERE id = d.route_id AND status = 'planned';
    END IF;
    UPDATE dlv_deliveries
    SET status = p_status, status_at = p_at,
        reason_code = CASE WHEN p_status IN ('in_transit', 'delivered') THEN reason_code ELSE coalesce(p_reason, reason_code) END,
        comment = coalesce(p_comment, comment),
        recipient_name = CASE WHEN p_status IN ('delivered', 'partially_delivered') THEN coalesce(p_recipient, recipient_name) ELSE recipient_name END,
        late_reason = coalesce(p_late_reason, late_reason),
        collected_amount = coalesce(p_collected, collected_amount),
        event_lat = CASE WHEN geo THEN p_lat END,
        event_lon = CASE WHEN geo THEN p_lon END,
        updated_by = p_actor
    WHERE id = d.id;
END $$;

-- Повторная попытка после неудачи или возврата: новая доставка того же заказа.
CREATE OR REPLACE FUNCTION dlv_retry(p_delivery_id bigint, p_actor text) RETURNS bigint
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    d dlv_deliveries%ROWTYPE;
    o record;
    v_id bigint;
BEGIN
    SELECT * INTO d FROM dlv_deliveries WHERE id = p_delivery_id FOR UPDATE;
    IF NOT FOUND OR d.status NOT IN ('failed', 'returned') THEN
        RAISE EXCEPTION 'deliveries: повторить можно неудачную или возвращённую доставку';
    END IF;
    SELECT * INTO o FROM src_dlv_orders WHERE order_id = d.order_id;
    INSERT INTO dlv_deliveries (order_id, attempt, address, lat, lon, window_from, window_to, weight_kg, volume_m3,
                                amount_to_collect, currency, created_by)
    VALUES (d.order_id, (SELECT max(attempt) + 1 FROM dlv_deliveries WHERE order_id = d.order_id),
            coalesce(o.address || coalesce(', ' || o.city, ''), d.address), coalesce(o.lat, d.lat), coalesce(o.lon, d.lon),
            coalesce(o.window_from, d.window_from), coalesce(o.window_to, d.window_to), d.weight_kg, d.volume_m3,
            d.amount_to_collect, d.currency, p_actor)
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

-- ───────────── Экраны ─────────────

-- «Доставки дня» (диспетчер): все доставки с заказом, маршрутом и риском опоздания.
CREATE OR REPLACE VIEW v_dlv_board AS
SELECT d.id, d.delivery_no, d.order_id, o.order_no, o.client_id, o.client_name, d.address, d.lat, d.lon,
       d.window_from, d.window_to,
       (coalesce(r.route_date, (d.window_from AT TIME ZONE (airl_setting('deliveries', 'timezone', '"Asia/Almaty"') #>> '{}'))::date)) AS delivery_date,
       d.weight_kg, d.volume_m3, o.amount, o.payment_status, d.amount_to_collect, d.currency,
       d.status, d.attempt, r.route_no, r.driver_id, dr.driver_name, d.stop_seq,
       d.departed_at, d.delivered_at, d.reason_code, d.late_reason, d.comment,
       (d.status IN ('new', 'assigned', 'in_transit') AND d.window_to < now()) AS overdue,
       (d.delivered_at > d.window_to + make_interval(mins => (airl_setting('deliveries', 'late_grace_minutes', '15'))::text::int)) AS late
FROM dlv_deliveries d
LEFT JOIN src_dlv_orders o ON o.order_id = d.order_id
LEFT JOIN dlv_routes r ON r.id = d.route_id
LEFT JOIN src_dlv_drivers dr ON dr.driver_id = r.driver_id;

-- «Нераспределённые»: ждут маршрута.
CREATE OR REPLACE VIEW v_dlv_unassigned AS
SELECT b.* FROM v_dlv_board b WHERE b.status = 'new';

-- «Маршруты»: загрузка машины, пробег, стоимость, ссылка на весь маршрут в картах.
CREATE OR REPLACE VIEW v_dlv_routes AS
SELECT r.id, r.route_no, r.route_date, r.driver_id, dr.driver_name, dr.vehicle, r.status, r.started_at, r.finished_at,
       count(d.id) AS stops,
       count(d.id) FILTER (WHERE d.status IN ('delivered', 'partially_delivered')) AS delivered,
       count(d.id) FILTER (WHERE d.status IN ('failed', 'returned')) AS failed,
       sum(d.weight_kg) AS weight_kg, dr.capacity_kg,
       (sum(d.weight_kg) > dr.capacity_kg OR sum(d.volume_m3) > dr.capacity_m3) AS overloaded,
       (r.odometer_end - r.odometer_start) AS km,
       CASE WHEN r.status = 'finished' AND (dr.currency IS NULL OR dr.currency = r.currency) THEN
            (coalesce(dr.day_cost, 0) + coalesce((r.odometer_end - r.odometer_start) * dr.cost_per_km, 0) + r.extra_cost)::numeric(18,2)
       END AS route_cost,
       r.currency,
       CASE airl_setting('deliveries', 'map_provider', '"yandex"') #>> '{}'
           WHEN 'google' THEN 'https://www.google.com/maps/dir/?api=1&travelmode=driving&waypoints='
                || string_agg(d.lat || ',' || d.lon, '|' ORDER BY d.stop_seq) FILTER (WHERE d.lat IS NOT NULL)
           WHEN '2gis' THEN 'https://2gis.kz/directions/points/'
                || string_agg(d.lon || ',' || d.lat, '|' ORDER BY d.stop_seq) FILTER (WHERE d.lat IS NOT NULL)
           ELSE 'https://yandex.kz/maps/?rtt=auto&rtext=' || (airl_setting('deliveries', 'depot_lat', '43.2567') #>> '{}') || ','
                || (airl_setting('deliveries', 'depot_lon', '76.9286') #>> '{}') || '~'
                || string_agg(d.lat || ',' || d.lon, '~' ORDER BY d.stop_seq) FILTER (WHERE d.lat IS NOT NULL)
       END AS route_url
FROM dlv_routes r
LEFT JOIN src_dlv_drivers dr ON dr.driver_id = r.driver_id
LEFT JOIN dlv_deliveries d ON d.route_id = r.id
GROUP BY r.id, dr.driver_name, dr.vehicle, dr.capacity_kg, dr.capacity_m3, dr.currency, dr.day_cost, dr.cost_per_km;

-- Экран водителя: остановки по порядку, адрес, окно, кому звонить, сколько получить, ссылка в карты.
CREATE OR REPLACE VIEW v_dlv_driver_stops AS
SELECT d.id, r.id AS route_id, r.route_no, r.route_date, r.driver_id, r.status AS route_status, d.stop_seq,
       d.delivery_no, o.order_no, o.client_name, o.contact_name, o.contact_phone,
       d.address, dlv_map_url(d.lat, d.lon) AS map_url, d.address AS map_query,
       d.window_from, d.window_to, d.weight_kg, o.payment_status, d.amount_to_collect, d.currency,
       d.status, d.status_at, d.recipient_name, d.code_confirmed,
       EXISTS (SELECT 1 FROM airl_attachments a WHERE a.module = 'deliveries' AND a.entity = 'dlv_deliveries'
                 AND a.entity_id = d.id::text) AS has_photo
FROM dlv_deliveries d
JOIN dlv_routes r ON r.id = d.route_id
LEFT JOIN src_dlv_orders o ON o.order_id = d.order_id;

-- «Проблемы»: недоставки, частичные, опоздания — с причинами (DEL-008).
CREATE OR REPLACE VIEW v_dlv_problems AS
SELECT b.id, b.delivery_no, b.order_no, b.client_name, b.delivery_date, b.driver_name, b.status,
       CASE WHEN b.status IN ('failed', 'returned') THEN 'недоставка'
            WHEN b.status = 'partially_delivered' THEN 'частично'
            WHEN b.late THEN 'опоздание'
            ELSE 'просрочено окно' END::text AS problem,
       coalesce(b.reason_code, b.late_reason) AS reason, b.comment, b.window_to, b.delivered_at,
       EXISTS (SELECT 1 FROM dlv_deliveries n WHERE n.order_id = b.order_id AND n.attempt > b.attempt) AS retried
FROM v_dlv_board b
WHERE b.status IN ('failed', 'returned', 'partially_delivered') OR b.late OR b.overdue;

-- Отзывы; низкие без обращения — кандидаты в complaints (object_type = 'order').
CREATE OR REPLACE VIEW v_dlv_feedback AS
SELECT f.id, f.delivery_id, d.delivery_no, d.order_id, o.order_no, o.client_id, o.client_name, f.rating, f.comment,
       f.channel, f.received_at, f.complaint_ref,
       (f.rating <= (airl_setting('deliveries', 'low_rating', '3'))::text::int AND f.complaint_ref IS NULL) AS needs_complaint
FROM dlv_feedback f
JOIN dlv_deliveries d ON d.id = f.delivery_id
LEFT JOIN src_dlv_orders o ON o.order_id = d.order_id;

-- Загрузка и результаты водителей по неделям (DEL-009).
CREATE OR REPLACE VIEW v_dlv_driver_load AS
SELECT r.driver_id, r.driver_name, to_char(r.route_date, 'IYYY-"W"IW') AS week,
       count(*) AS routes, sum(r.stops) AS stops, sum(r.delivered) AS delivered, sum(r.failed) AS failed,
       sum(r.km) AS km, round(avg(100.0 * r.weight_kg / NULLIF(r.capacity_kg, 0)), 1) AS avg_load_pct,
       sum(r.route_cost)::numeric(18,2) AS cost, max(r.currency) AS currency
FROM v_dlv_routes r
WHERE r.status = 'finished'
GROUP BY r.driver_id, r.driver_name, to_char(r.route_date, 'IYYY-"W"IW');

-- Наличные и оплата при получении по маршруту: сколько водитель должен сдать.
CREATE OR REPLACE VIEW v_dlv_cash AS
SELECT r.route_no, r.route_date, r.driver_id, d.currency,
       sum(d.amount_to_collect) FILTER (WHERE d.status IN ('delivered', 'partially_delivered')) AS to_collect,
       sum(d.collected_amount) AS collected,
       sum(d.amount_to_collect) FILTER (WHERE d.status IN ('delivered', 'partially_delivered')) - coalesce(sum(d.collected_amount), 0) AS shortfall
FROM dlv_deliveries d JOIN dlv_routes r ON r.id = d.route_id
WHERE d.amount_to_collect > 0
GROUP BY r.route_no, r.route_date, r.driver_id, d.currency;

-- История статусов доставки с временем нажатия и геопозицией (если включена).
CREATE OR REPLACE VIEW v_dlv_timeline AS
SELECT a.entity_id::bigint AS delivery_id, a.at AS recorded_at, (a.details ->> 'at')::timestamptz AS status_at,
       a.actor, a.from_status, a.to_status, a.comment,
       (a.details ->> 'lat')::numeric AS lat, (a.details ->> 'lon')::numeric AS lon
FROM airl_audit a
WHERE a.module = 'deliveries' AND a.entity = 'dlv_deliveries' AND a.action = 'status';

-- ───────────── Показатели ─────────────
-- Закрытые доставки: доставлено, частично, неудача, возврат. Неделя — по дню маршрута.
CREATE OR REPLACE VIEW v_dlv_closed AS
SELECT b.id, to_char(b.delivery_date, 'IYYY-"W"IW') AS week, b.status,
       (b.status IN ('delivered', 'partially_delivered') AND NOT coalesce(b.late, false)) AS on_time,
       (b.status IN ('failed', 'returned')) AS failed
FROM v_dlv_board b
WHERE b.status IN ('delivered', 'partially_delivered', 'failed', 'returned');

-- Вовремя: доставлено (полностью или частично) не позже конца окна + late_grace_minutes,
-- к всем закрытым доставкам недели (неудача — тоже «не вовремя»).
CREATE OR REPLACE VIEW m_on_time_delivery_rate AS
SELECT 'on_time_delivery_rate'::text AS metric_id, week AS period,
       round(100.0 * count(*) FILTER (WHERE on_time) / NULLIF(count(*), 0), 2) AS value, '%'::text AS unit,
       airl_traffic(round(100.0 * count(*) FILTER (WHERE on_time) / NULLIF(count(*), 0), 2),
                    (airl_setting('deliveries', 'on_time_warn', '90'))::text::numeric,
                    (airl_setting('deliveries', 'on_time_bad', '80'))::text::numeric, true) AS status
FROM v_dlv_closed GROUP BY week;

-- Неудачные: неудача + возврат / все закрытые доставки недели.
CREATE OR REPLACE VIEW m_failed_delivery_rate AS
SELECT 'failed_delivery_rate'::text AS metric_id, week AS period,
       round(100.0 * count(*) FILTER (WHERE failed) / NULLIF(count(*), 0), 2) AS value, '%'::text AS unit,
       airl_traffic(round(100.0 * count(*) FILTER (WHERE failed) / NULLIF(count(*), 0), 2),
                    (airl_setting('deliveries', 'failed_warn', '3'))::text::numeric,
                    (airl_setting('deliveries', 'failed_bad', '6'))::text::numeric, false) AS status
FROM v_dlv_closed GROUP BY week;

-- Стоимость доставки: стоимость законченных маршрутов (день водителя + км × ставка + расходы)
-- / доставленные (полностью и частично); только маршруты в валюте модуля и со ставками.
CREATE OR REPLACE VIEW m_cost_per_delivery AS
SELECT 'cost_per_delivery'::text AS metric_id, to_char(r.route_date, 'IYYY-"W"IW') AS period,
       round(sum(r.route_cost) / NULLIF(sum(r.delivered), 0), 2) AS value,
       (airl_setting('deliveries', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}')::text AS unit,
       airl_traffic(round(sum(r.route_cost) / NULLIF(sum(r.delivered), 0), 2),
                    (airl_setting('deliveries', 'cost_warn', '7000'))::text::numeric,
                    (airl_setting('deliveries', 'cost_bad', '9000'))::text::numeric, false) AS status
FROM v_dlv_routes r
WHERE r.status = 'finished' AND r.route_cost IS NOT NULL
  AND r.currency = (airl_setting('deliveries', 'currency', airl_setting('kit', 'currency', '"KZT"')) #>> '{}')
GROUP BY to_char(r.route_date, 'IYYY-"W"IW');
