-- Синтетические данные модуля для разработки и показа: доставка по Алматы за три недели.
-- Сценарий идёт через функции модуля, поэтому seed заодно проверяет правила.
-- Повторный запуск ничего не дублирует.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('deliveries', 'timezone',             '"Asia/Almaty"',     'demo'),
 ('deliveries', 'org_name',             '"Demo Coffee"',     'demo'),
 ('deliveries', 'depot_lat',            '43.2567',           'demo'),
 ('deliveries', 'depot_lon',            '76.9286',           'demo'),
 ('deliveries', 'map_provider',         '"yandex"',          'demo'),
 ('deliveries', 'proof_required',       '["name"]',          'demo'),
 ('deliveries', 'late_grace_minutes',   '15',                'demo'),
 ('deliveries', 'geo_on_status',        'true',              'demo'),
 ('deliveries', 'notify_client',        'true',              'demo'),
 ('deliveries', 'client_channel',       '"sms"',             'demo'),
 ('deliveries', 'channel',              '"telegram"',        'demo'),
 ('deliveries', 'manager_recipient',    '"logistics_head"',  'demo'),
 ('deliveries', 'service_recipient',    '"service_head"',    'demo'),
 ('deliveries', 'feedback_delay_hours', '2',                 'demo'),
 ('deliveries', 'low_rating',           '3',                 'demo'),
 ('deliveries', 'on_time_warn',         '90',                'demo'),
 ('deliveries', 'on_time_bad',          '80',                'demo'),
 ('deliveries', 'failed_warn',          '3',                 'demo'),
 ('deliveries', 'failed_bad',           '6',                 'demo'),
 ('deliveries', 'cost_warn',            '7000',              'demo'),
 ('deliveries', 'cost_bad',             '9000',              'demo')
ON CONFLICT (module, key) DO NOTHING;

DO $$
DECLARE
    tz     text := 'Asia/Almaty';
    d      date;
    r1     bigint;
    r2     bigint;
    rid    bigint;
    x      record;
    i      int;
    h      int;
    v_dep  timestamptz;
    v_at   timestamptz;
    v_odo  int;
    v_fail bigint;
BEGIN
    IF EXISTS (SELECT 1 FROM dlv_routes) THEN RETURN; END IF;
    PERFORM dlv_generate('demo');

    FOR d IN SELECT DISTINCT (dd.window_from AT TIME ZONE tz)::date FROM dlv_deliveries dd
             WHERE dd.status = 'new' AND (dd.window_from AT TIME ZONE tz)::date <= current_date ORDER BY 1 LOOP
        r1 := dlv_create_route(d, 'DRV-01', 'dispatcher_zhanna');
        r2 := dlv_create_route(d, 'DRV-02', 'dispatcher_zhanna');
        i := 0;
        FOR x IN SELECT dd.id FROM dlv_deliveries dd
                 WHERE dd.status = 'new' AND (dd.window_from AT TIME ZONE tz)::date = d ORDER BY dd.window_from, dd.id LOOP
            PERFORM dlv_assign(x.id, CASE WHEN i % 2 = 0 THEN r1 ELSE r2 END, 'dispatcher_zhanna');
            i := i + 1;
        END LOOP;
        PERFORM dlv_apply_suggestion(r1, 'dispatcher_zhanna');
        PERFORM dlv_apply_suggestion(r2, 'dispatcher_zhanna');

        IF d = current_date THEN
            -- Сегодня: первый водитель выехал к первой точке, остальное ждёт.
            SELECT dd.id INTO rid FROM dlv_deliveries dd WHERE dd.route_id = r1 ORDER BY dd.stop_seq LIMIT 1;
            IF rid IS NOT NULL THEN
                PERFORM dlv_start_route(r1, 48210, 'DRV-01', now() - interval '40 minutes');
                PERFORM dlv_set_status(rid, 'in_transit', 'DRV-01', p_lat => 43.2567, p_lon => 76.9286, p_at => now() - interval '30 minutes');
            END IF;
            CONTINUE;
        END IF;

        FOREACH rid IN ARRAY ARRAY[r1, r2] LOOP
            v_odo := 40000 + (d - date '2026-01-01') * 85 + (rid % 7) * 1000;
            PERFORM dlv_start_route(rid, v_odo, 'driver', (d + time '08:30') AT TIME ZONE tz);
            FOR x IN SELECT dd.*, o.contact_name FROM dlv_deliveries dd LEFT JOIN src_dlv_orders o ON o.order_id = dd.order_id
                     WHERE dd.route_id = rid ORDER BY dd.stop_seq LOOP
                h := abs(hashtext(x.delivery_no)) % 100;
                v_dep := x.window_from - interval '40 minutes';
                PERFORM dlv_set_status(x.id, 'in_transit', 'driver', p_at => v_dep);
                IF h < 4 THEN
                    PERFORM dlv_set_status(x.id, 'failed', 'driver', p_reason => 'client_absent',
                                           p_comment => 'Закрыто, телефон не отвечает', p_lat => x.lat, p_lon => x.lon,
                                           p_at => x.window_from + interval '30 minutes');
                ELSIF h < 6 THEN
                    PERFORM dlv_set_status(x.id, 'returned', 'driver', p_reason => 'client_refused',
                                           p_comment => 'Клиент отказался: заказывал другой помол', p_at => x.window_from + interval '50 minutes');
                ELSIF h < 10 THEN
                    PERFORM dlv_set_status(x.id, 'partially_delivered', 'driver', p_reason => 'damaged',
                                           p_comment => 'Одна коробка помята — клиент её не принял', p_recipient => x.contact_name,
                                           p_collected => CASE WHEN x.amount_to_collect > 0 THEN x.amount_to_collect - 5000 END,
                                           p_lat => x.lat, p_lon => x.lon, p_at => x.window_from + interval '45 minutes');
                ELSIF h < 18 THEN
                    PERFORM dlv_set_status(x.id, 'delivered', 'driver', p_recipient => x.contact_name, p_late_reason => 'traffic',
                                           p_collected => CASE WHEN x.amount_to_collect > 0 THEN x.amount_to_collect END,
                                           p_lat => x.lat, p_lon => x.lon, p_at => x.window_to + interval '35 minutes');
                ELSE
                    PERFORM dlv_set_status(x.id, 'delivered', 'driver', p_recipient => x.contact_name,
                                           p_collected => CASE WHEN x.amount_to_collect > 0 THEN x.amount_to_collect END,
                                           p_lat => x.lat, p_lon => x.lon,
                                           p_at => x.window_from + make_interval(mins => 10 + h % 150));
                END IF;
            END LOOP;
            PERFORM dlv_finish_route(rid, v_odo + 35 + (abs(hashtext(rid::text)) % 45), CASE WHEN rid % 3 = 0 THEN 1500 ELSE 0 END,
                                     'driver', (d + time '18:30') AT TIME ZONE tz);
        END LOOP;
    END LOOP;

    -- Отзывы клиентов: примерно на половину доставленного.
    INSERT INTO dlv_feedback (delivery_id, rating, comment, channel, received_at, created_by)
    SELECT dd.id,
           CASE abs(hashtext('f' || dd.delivery_no)) % 10 WHEN 0 THEN 2 WHEN 1 THEN 3 WHEN 2 THEN 4 ELSE 5 END,
           CASE abs(hashtext('f' || dd.delivery_no)) % 10 WHEN 0 THEN 'Опоздали, водитель не позвонил заранее'
                                                         WHEN 1 THEN 'Пакеты были в пыли' END,
           'sms', dd.delivered_at + interval '3 hours', 'bot'
    FROM dlv_deliveries dd
    WHERE dd.status IN ('delivered', 'partially_delivered') AND abs(hashtext('g' || dd.delivery_no)) % 2 = 0
    ON CONFLICT (delivery_id) DO NOTHING;

    -- Одну неудачную доставку повторяем завтра.
    SELECT dd.id INTO v_fail FROM dlv_deliveries dd WHERE dd.status = 'failed' ORDER BY dd.id DESC LIMIT 1;
    IF v_fail IS NOT NULL THEN PERFORM dlv_retry(v_fail, 'dispatcher_zhanna'); END IF;
END $$;
