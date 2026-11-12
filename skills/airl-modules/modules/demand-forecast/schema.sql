-- Модуль «Прогноз спроса» (demand-forecast). Требует kit/kit.sql в той же схеме и
-- представления src_fc_sales_daily, src_fc_events, src_fc_material_stock (адаптер или demo_src.sql).
-- Честный базовый прогноз без ИИ: три простых метода, проверка каждого на последних
-- неделях истории (backtest), выбор лучшего для каждого товара × точки, прогноз на N недель
-- и потребность в сырье (зелёное зерно, упаковка) через нормы расхода с учётом срока поставки.
-- Расчёт — функция fc_run(); экраны читают таблицы последнего успешного расчёта.

CREATE SEQUENCE IF NOT EXISTS fc_run_seq;

CREATE TABLE IF NOT EXISTS fc_runs (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_no         text        NOT NULL UNIQUE DEFAULT 'FC-' || lpad(nextval('fc_run_seq')::text, 5, '0'),
    status         text        NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'done', 'failed')),
    as_of          date        NOT NULL,           -- последний полный день продаж
    horizon_weeks  int         NOT NULL,
    backtest_weeks int         NOT NULL,
    params         jsonb       NOT NULL,
    series         int,
    error          text,
    finished_at    timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     text        NOT NULL,
    updated_at     timestamptz,
    updated_by     text,
    CHECK (status <> 'failed' OR error IS NOT NULL)
);

-- Результат проверки каждого метода по товару × точке.
CREATE TABLE IF NOT EXISTS fc_backtest (
    run_id       bigint        NOT NULL REFERENCES fc_runs (id),
    sku          text          NOT NULL,
    location_id  text          NOT NULL,
    method       text          NOT NULL CHECK (method IN ('seasonal_naive', 'moving_average', 'ses')),
    weeks_tested int           NOT NULL,
    actual       numeric(18,3) NOT NULL,
    abs_error    numeric(18,3) NOT NULL,       -- сумма |прогноз − факт| по неделям
    wape         numeric(9,1),                 -- abs_error / actual × 100
    mape         numeric(9,1),                 -- среднее |ошибка| / факт по неделям с продажами
    wape_daily   numeric(9,1),                 -- то же по дням (насколько угадан ритм недели)
    PRIMARY KEY (run_id, sku, location_id, method)
);

-- Ряд товар × точка: какой метод выбран, точность, хватает ли истории.
CREATE TABLE IF NOT EXISTS fc_series (
    run_id         bigint        NOT NULL REFERENCES fc_runs (id),
    sku            text          NOT NULL,
    location_id    text          NOT NULL,
    first_day      date          NOT NULL,
    history_weeks  int           NOT NULL,
    recent_volume  numeric(18,3) NOT NULL,     -- продажи за последние recent_weeks недель
    chosen_method  text          NOT NULL,
    wape           numeric(9,1),
    mape           numeric(9,1),
    wape_daily     numeric(9,1),
    low_history    boolean       NOT NULL,
    note           text,
    PRIMARY KEY (run_id, sku, location_id)
);

-- Прогноз по неделям: неделя 1 — 7 дней после as_of. qty — с поправкой на будущие акции.
CREATE TABLE IF NOT EXISTS fc_forecasts (
    run_id       bigint        NOT NULL REFERENCES fc_runs (id),
    sku          text          NOT NULL,
    location_id  text          NOT NULL,
    week_no      int           NOT NULL,
    week_start   date          NOT NULL,
    week_end     date          NOT NULL,
    qty_base     numeric(18,3) NOT NULL,
    qty          numeric(18,3) NOT NULL,
    method       text          NOT NULL,
    promo_days   int           NOT NULL DEFAULT 0,
    PRIMARY KEY (run_id, sku, location_id, week_no)
);

-- Сырьё и материалы: срок поставки и страховой запас — в неделях.
CREATE TABLE IF NOT EXISTS fc_materials (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            text          NOT NULL UNIQUE,
    title           text          NOT NULL,
    unit            text          NOT NULL,
    lead_time_weeks numeric(6,2)  NOT NULL CHECK (lead_time_weeks >= 0),
    safety_weeks    numeric(6,2)  NOT NULL DEFAULT 2 CHECK (safety_weeks >= 0),
    pack_size       numeric(18,3) CHECK (pack_size IS NULL OR pack_size > 0),   -- кратность заказа (мешок 60 кг)
    active          boolean       NOT NULL DEFAULT true,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    created_by      text          NOT NULL,
    updated_at      timestamptz,
    updated_by      text
);

-- Норма расхода: на единицу готового товара — сколько материала в готовом виде.
-- loss_pct — потери при производстве (ужарка зерна 15–20 %); NULL — настройка roast_loss_pct.
-- Потребность материала = qty × qty_per_unit / (1 − loss_pct / 100).
CREATE TABLE IF NOT EXISTS fc_bom (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    output_sku    text          NOT NULL,
    material_code text          NOT NULL REFERENCES fc_materials (code),
    qty_per_unit  numeric(18,6) NOT NULL CHECK (qty_per_unit > 0),
    loss_pct      numeric(5,2)  CHECK (loss_pct IS NULL OR (loss_pct >= 0 AND loss_pct < 100)),
    active        boolean       NOT NULL DEFAULT true,
    created_at    timestamptz   NOT NULL DEFAULT now(),
    created_by    text          NOT NULL,
    updated_at    timestamptz,
    updated_by    text,
    UNIQUE (output_sku, material_code)
);

-- Предложение закупки по материалу на расчёт. Решает закупщик.
CREATE TABLE IF NOT EXISTS fc_suggestions (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id           bigint        NOT NULL REFERENCES fc_runs (id),
    material_code    text          NOT NULL,
    unit             text          NOT NULL,
    cover_weeks      numeric(6,2)  NOT NULL,   -- срок поставки + страховой запас
    need_qty         numeric(18,3) NOT NULL,   -- потребность на cover_weeks
    on_hand          numeric(18,3) NOT NULL,
    on_order         numeric(18,3) NOT NULL,
    suggest_qty      numeric(18,3) NOT NULL,
    uses_low_history boolean       NOT NULL,   -- в расчёте есть товары с малой историей
    status           text          NOT NULL DEFAULT 'proposed'
                     CHECK (status IN ('proposed', 'accepted', 'rejected', 'superseded')),
    decided_at       timestamptz,
    decided_by       text,
    decision_comment text,
    created_at       timestamptz   NOT NULL DEFAULT now(),
    created_by       text          NOT NULL,
    updated_at       timestamptz,
    updated_by       text,
    UNIQUE (run_id, material_code),
    CHECK (status <> 'rejected' OR decision_comment IS NOT NULL)
);

DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['fc_runs', 'fc_materials', 'fc_bom', 'fc_suggestions'] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', t || '_touch', t);
        EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION airl_touch()', t || '_touch', t);
    END LOOP;
END $$;

-- Переходы: расчёт running → done | failed; предложение proposed → accepted | rejected | superseded.
CREATE OR REPLACE FUNCTION fc_status_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_entity text;
    v_key    text;
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF TG_TABLE_NAME = 'fc_runs' THEN
            v_entity := 'run'; v_key := NEW.run_no;
            IF (OLD.status, NEW.status) NOT IN (('running', 'done'), ('running', 'failed')) THEN
                RAISE EXCEPTION 'demand-forecast: переход расчёта % → % не разрешён (%)', OLD.status, NEW.status, v_key;
            END IF;
        ELSE
            v_entity := 'suggestion'; v_key := NEW.id::text;
            IF (OLD.status, NEW.status) NOT IN (('proposed', 'accepted'), ('proposed', 'rejected'), ('proposed', 'superseded')) THEN
                RAISE EXCEPTION 'demand-forecast: переход предложения % → % не разрешён (%)', OLD.status, NEW.status, v_key;
            END IF;
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment)
        VALUES (COALESCE(NEW.updated_by, 'system'), 'demand-forecast', v_entity, v_key, 'status', OLD.status, NEW.status,
                CASE WHEN TG_TABLE_NAME = 'fc_runs' THEN to_jsonb(NEW)->>'error' ELSE to_jsonb(NEW)->>'decision_comment' END);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS fc_runs_status ON fc_runs;
CREATE TRIGGER fc_runs_status BEFORE UPDATE ON fc_runs FOR EACH ROW EXECUTE FUNCTION fc_status_guard();
DROP TRIGGER IF EXISTS fc_suggestions_status ON fc_suggestions;
CREATE TRIGGER fc_suggestions_status BEFORE UPDATE ON fc_suggestions FOR EACH ROW EXECUTE FUNCTION fc_status_guard();

-- Расчёт прогноза. Запускать раз в неделю (или после загрузки продаж); повторный запуск
-- создаёт новый расчёт, старые остаются для сравнения «прогноз против факта».
--
-- Ряд — товар × точка, от первого дня с продажей до as_of (пропуски = 0).
-- Методы (дневной прогноз, неделя = сумма 7 дней):
--   seasonal_naive  среднее того же дня недели за последние sn_weeks недель;
--   moving_average  среднее за последние ma_days дней;
--   ses             простое экспоненциальное сглаживание, коэффициент ses_alpha.
-- Дни акций (src_fc_events) не участвуют ни в обучении, ни в проверке; будущие акции
-- увеличивают прогноз на uplift_pct.
-- Проверка: для каждой из последних backtest_weeks недель прогноз строится по данным
-- до её начала и сравнивается с фактом. Выбирается метод с меньшим WAPE по неделям.
-- Ряду не хватает истории на проверку — moving_average по всем дням, отметка low_history.
CREATE OR REPLACE FUNCTION fc_run(p_actor text) RETURNS text
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_h        int     := (airl_setting('demand-forecast', 'horizon_weeks', '8'))::text::int;
    v_k        int     := (airl_setting('demand-forecast', 'backtest_weeks', '8'))::text::int;
    v_sn       int     := (airl_setting('demand-forecast', 'sn_weeks', '4'))::text::int;
    v_ma       int     := (airl_setting('demand-forecast', 'ma_days', '56'))::text::int;
    v_alpha    numeric := (airl_setting('demand-forecast', 'ses_alpha', '0.3'))::text::numeric;
    v_min_w    int     := (airl_setting('demand-forecast', 'min_history_weeks', '26'))::text::int;
    v_recent   int     := (airl_setting('demand-forecast', 'recent_weeks', '8'))::text::int;
    v_loss     numeric := (airl_setting('demand-forecast', 'roast_loss_pct', '17'))::text::numeric;
    v_as_of    date;
    v_run      bigint;
    v_no       text;
    v_origins  date[];
    v_key      text;
    v_level    numeric;
    v_n        int;
    r          record;
BEGIN
    SELECT max(day) INTO v_as_of FROM src_fc_sales_daily WHERE day < current_date;
    IF v_as_of IS NULL THEN RAISE EXCEPTION 'demand-forecast: нет продаж во входе src_fc_sales_daily'; END IF;
    PERFORM pg_advisory_xact_lock(hashtext('demand-forecast:run'));

    INSERT INTO fc_runs (as_of, horizon_weeks, backtest_weeks, params, created_by, updated_by)
    VALUES (v_as_of, v_h, v_k,
            jsonb_build_object('sn_weeks', v_sn, 'ma_days', v_ma, 'ses_alpha', v_alpha,
                               'min_history_weeks', v_min_w, 'roast_loss_pct', v_loss),
            p_actor, p_actor)
    RETURNING id, run_no INTO v_run, v_no;

    BEGIN
        DROP TABLE IF EXISTS fc_tmp_daily;
        CREATE TEMP TABLE fc_tmp_daily ON COMMIT DROP AS
        WITH s AS (
            SELECT sku, location_id, day, sum(qty) AS qty
            FROM src_fc_sales_daily WHERE day <= v_as_of GROUP BY 1, 2, 3
        ),
        b AS (
            SELECT sku, location_id, min(day) FILTER (WHERE qty > 0) AS d0 FROM s GROUP BY 1, 2
        )
        SELECT b.sku, b.location_id, g::date AS day, COALESCE(s.qty, 0)::numeric AS qty,
               EXISTS (SELECT 1 FROM src_fc_events e
                       WHERE (e.sku IS NULL OR e.sku = b.sku) AND (e.location_id IS NULL OR e.location_id = b.location_id)
                         AND g::date BETWEEN e.date_from AND e.date_to) AS promo,
               (g::date > v_as_of) AS future
        FROM b
        CROSS JOIN generate_series(b.d0, v_as_of + 1, interval '1 day') g
        LEFT JOIN s ON s.sku = b.sku AND s.location_id = b.location_id AND s.day = g::date
        WHERE b.d0 IS NOT NULL;
        CREATE INDEX ON fc_tmp_daily (sku, location_id, day);
        ANALYZE fc_tmp_daily;

        -- Экспоненциальное сглаживание: уровень перед каждой точкой отсчёта (начала проверочных
        -- недель и день после as_of). Один проход по ряду.
        v_origins := ARRAY(SELECT v_as_of - 7 * k + 1 FROM generate_series(1, v_k) k) || (v_as_of + 1);
        DROP TABLE IF EXISTS fc_tmp_ses;
        CREATE TEMP TABLE fc_tmp_ses (sku text, location_id text, day date, level numeric) ON COMMIT DROP;
        v_key := NULL;
        FOR r IN SELECT sku, location_id, day, qty, promo, future FROM fc_tmp_daily ORDER BY sku, location_id, day LOOP
            IF v_key IS DISTINCT FROM r.sku || '|' || r.location_id THEN
                v_key := r.sku || '|' || r.location_id; v_level := NULL;
            END IF;
            IF r.day = ANY (v_origins) THEN
                INSERT INTO fc_tmp_ses VALUES (r.sku, r.location_id, r.day, v_level);
            END IF;
            IF NOT r.promo AND NOT r.future THEN
                v_level := CASE WHEN v_level IS NULL THEN r.qty ELSE v_alpha * r.qty + (1 - v_alpha) * v_level END;
            END IF;
        END LOOP;

        -- Проверка на последних v_k неделях.
        INSERT INTO fc_backtest (run_id, sku, location_id, method, weeks_tested, actual, abs_error, wape, mape, wape_daily)
        WITH ser AS (
            SELECT sku, location_id, min(day) AS d0 FROM fc_tmp_daily GROUP BY 1, 2
        ),
        tests AS (
            SELECT s.sku, s.location_id, k, v_as_of - 7 * k + 1 AS origin
            FROM ser s CROSS JOIN generate_series(1, v_k) k
            WHERE s.d0 <= v_as_of - 7 * v_k + 1 - greatest(7 * v_sn, v_ma)
        ),
        days AS (
            SELECT t.sku, t.location_id, t.k, t.origin, d.day, d.qty AS actual,
                   (SELECT avg(h.qty) FROM fc_tmp_daily h
                    WHERE h.sku = t.sku AND h.location_id = t.location_id AND NOT h.promo
                      AND h.day < t.origin AND h.day >= d.day - 7 * v_sn AND (d.day - h.day) % 7 = 0) AS f_sn,
                   ma.v AS f_ma, ses.level AS f_ses
            FROM tests t
            JOIN fc_tmp_daily d ON d.sku = t.sku AND d.location_id = t.location_id
                               AND d.day BETWEEN t.origin AND t.origin + 6 AND NOT d.promo
            LEFT JOIN LATERAL (SELECT avg(h.qty) AS v FROM fc_tmp_daily h
                               WHERE h.sku = t.sku AND h.location_id = t.location_id AND NOT h.promo
                                 AND h.day >= t.origin - v_ma AND h.day < t.origin) ma ON true
            LEFT JOIN fc_tmp_ses ses ON ses.sku = t.sku AND ses.location_id = t.location_id AND ses.day = t.origin
        ),
        long AS (
            SELECT d.sku, d.location_id, d.k, d.actual, m.method, COALESCE(m.f, 0) AS f
            FROM days d
            CROSS JOIN LATERAL (VALUES ('seasonal_naive', d.f_sn), ('moving_average', d.f_ma), ('ses', d.f_ses)) AS m(method, f)
        ),
        wk AS (
            SELECT sku, location_id, method, k, sum(actual) AS a, sum(f) AS f, sum(abs(f - actual)) AS abs_daily
            FROM long GROUP BY 1, 2, 3, 4
        )
        SELECT v_run, sku, location_id, method, count(*), sum(a), sum(abs(f - a)),
               round(100 * sum(abs(f - a)) / NULLIF(sum(a), 0), 1),
               round(100 * avg(abs(f - a) / a) FILTER (WHERE a > 0), 1),
               round(100 * sum(abs_daily) / NULLIF(sum(a), 0), 1)
        FROM wk GROUP BY sku, location_id, method;

        -- Выбор метода и признак «мало истории».
        INSERT INTO fc_series (run_id, sku, location_id, first_day, history_weeks, recent_volume, chosen_method,
                               wape, mape, wape_daily, low_history, note)
        SELECT v_run, s.sku, s.location_id, s.d0, (v_as_of - s.d0 + 1) / 7,
               (SELECT COALESCE(sum(qty), 0) FROM fc_tmp_daily x
                WHERE x.sku = s.sku AND x.location_id = s.location_id AND NOT x.future AND x.day > v_as_of - 7 * v_recent),
               COALESCE(best.method, 'moving_average'), best.wape, best.mape, best.wape_daily,
               (best.method IS NULL OR (v_as_of - s.d0 + 1) < 7 * v_min_w),
               CASE WHEN best.method IS NULL
                    THEN 'Мало истории для проверки — прогноз по среднему, не показывать как точный'
                    WHEN (v_as_of - s.d0 + 1) < 7 * v_min_w
                    THEN 'Мало истории (меньше ' || v_min_w || ' недель) — прогноз не показывать как точный'
                    WHEN best.wape IS NULL THEN 'Не было продаж на проверочных неделях — точность неизвестна'
               END
        FROM (SELECT sku, location_id, min(day) AS d0 FROM fc_tmp_daily GROUP BY 1, 2) s
        LEFT JOIN LATERAL (
            SELECT b.method, b.wape, b.mape, b.wape_daily FROM fc_backtest b
            WHERE b.run_id = v_run AND b.sku = s.sku AND b.location_id = s.location_id
            ORDER BY b.wape NULLS LAST, b.wape_daily NULLS LAST, b.method
            LIMIT 1
        ) best ON true;
        GET DIAGNOSTICS v_n = ROW_COUNT;

        -- Прогноз на v_h недель выбранным методом по всей истории до as_of.
        INSERT INTO fc_forecasts (run_id, sku, location_id, week_no, week_start, week_end, qty_base, qty, method, promo_days)
        WITH fd AS (
            SELECT s.sku, s.location_id, s.chosen_method, g::date AS day
            FROM fc_series s
            CROSS JOIN generate_series(v_as_of + 1, v_as_of + 7 * v_h, interval '1 day') g
            WHERE s.run_id = v_run
        ),
        base AS (
            SELECT fd.*,
                   CASE fd.chosen_method
                       WHEN 'seasonal_naive' THEN
                           (SELECT avg(h.qty) FROM fc_tmp_daily h
                            WHERE h.sku = fd.sku AND h.location_id = fd.location_id AND NOT h.promo AND NOT h.future
                              AND h.day > v_as_of - 7 * v_sn AND (fd.day - h.day) % 7 = 0)
                       WHEN 'ses' THEN
                           (SELECT x.level FROM fc_tmp_ses x
                            WHERE x.sku = fd.sku AND x.location_id = fd.location_id AND x.day = v_as_of + 1)
                       ELSE
                           (SELECT avg(h.qty) FROM fc_tmp_daily h
                            WHERE h.sku = fd.sku AND h.location_id = fd.location_id AND NOT h.promo AND NOT h.future
                              AND h.day > v_as_of - v_ma)
                   END AS f,
                   (SELECT max(e.uplift_pct) FROM src_fc_events e
                    WHERE (e.sku IS NULL OR e.sku = fd.sku) AND (e.location_id IS NULL OR e.location_id = fd.location_id)
                      AND fd.day BETWEEN e.date_from AND e.date_to) AS uplift
            FROM fd
        )
        SELECT v_run, sku, location_id, (day - v_as_of - 1) / 7 + 1, min(day), max(day),
               round(sum(COALESCE(f, 0)), 3),
               round(sum(COALESCE(f, 0) * (1 + COALESCE(uplift, 0) / 100)), 3),
               max(chosen_method), count(*) FILTER (WHERE uplift IS NOT NULL)
        FROM base
        GROUP BY sku, location_id, (day - v_as_of - 1) / 7 + 1;

        -- Предложения закупки: потребность на срок поставки + страховой запас минус остаток и заказы.
        -- Если срок длиннее горизонта, недостающие недели — по среднему последних 4 недель прогноза.
        UPDATE fc_suggestions SET status = 'superseded', updated_by = p_actor WHERE status = 'proposed';
        INSERT INTO fc_suggestions (run_id, material_code, unit, cover_weeks, need_qty, on_hand, on_order,
                                    suggest_qty, uses_low_history, created_by, updated_by)
        WITH dem AS (
            SELECT b.material_code, f.week_no,
                   sum(f.qty * b.qty_per_unit / (1 - COALESCE(b.loss_pct, v_loss) / 100)) AS need,
                   bool_or(s.low_history) AS low
            FROM fc_forecasts f
            JOIN fc_bom b    ON b.output_sku = f.sku AND b.active
            JOIN fc_series s ON s.run_id = f.run_id AND s.sku = f.sku AND s.location_id = f.location_id
            WHERE f.run_id = v_run
            GROUP BY b.material_code, f.week_no
        ),
        cover AS (
            SELECT m.code, m.unit, m.pack_size, m.lead_time_weeks + m.safety_weeks AS cw,
                   COALESCE((SELECT sum(d.need * least(1, greatest(0, m.lead_time_weeks + m.safety_weeks - (d.week_no - 1))))
                             FROM dem d WHERE d.material_code = m.code), 0)
                   + greatest(0, m.lead_time_weeks + m.safety_weeks - v_h)
                     * COALESCE((SELECT avg(d.need) FROM dem d WHERE d.material_code = m.code AND d.week_no > v_h - 4), 0) AS need,
                   COALESCE((SELECT bool_or(d.low) FROM dem d WHERE d.material_code = m.code), false) AS low
            FROM fc_materials m
            WHERE m.active AND EXISTS (SELECT 1 FROM dem d WHERE d.material_code = m.code)
        ),
        st AS (
            SELECT material_code, sum(qty_on_hand) AS on_hand, sum(qty_on_order) AS on_order
            FROM src_fc_material_stock GROUP BY material_code
        )
        SELECT v_run, c.code, c.unit, c.cw, round(c.need, 3),
               COALESCE(st.on_hand, 0), COALESCE(st.on_order, 0),
               CASE WHEN c.need - COALESCE(st.on_hand, 0) - COALESCE(st.on_order, 0) <= 0 THEN 0
                    ELSE ceil((c.need - COALESCE(st.on_hand, 0) - COALESCE(st.on_order, 0)) / COALESCE(c.pack_size, 1))
                         * COALESCE(c.pack_size, 1) END,
               c.low, p_actor, p_actor
        FROM cover c LEFT JOIN st ON st.material_code = c.code;

        UPDATE fc_runs SET status = 'done', series = v_n, finished_at = now(), updated_by = p_actor WHERE id = v_run;
    EXCEPTION WHEN OTHERS THEN
        UPDATE fc_runs SET status = 'failed', error = SQLERRM, finished_at = now(), updated_by = p_actor WHERE id = v_run;
    END;
    RETURN v_no;
END $$;

-- Решение закупщика по предложению: accepted | rejected (с комментарием).
CREATE OR REPLACE FUNCTION fc_decide(p_suggestion_id bigint, p_decision text, p_actor text, p_comment text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_n int;
BEGIN
    IF p_decision NOT IN ('accepted', 'rejected') THEN
        RAISE EXCEPTION 'demand-forecast: решение должно быть accepted или rejected';
    END IF;
    UPDATE fc_suggestions SET status = p_decision, decided_at = now(), decided_by = p_actor,
                              decision_comment = p_comment, updated_by = p_actor
     WHERE id = p_suggestion_id AND status = 'proposed';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN RAISE EXCEPTION 'demand-forecast: предложение % не ждёт решения', p_suggestion_id; END IF;
    RETURN p_decision;
END $$;

-- Последний успешный расчёт.
CREATE OR REPLACE VIEW v_fc_runs AS
SELECT r.id AS run_id, r.run_no, r.status, r.as_of, r.horizon_weeks, r.backtest_weeks, r.params, r.series,
       r.error, r.created_at, r.finished_at, r.created_by,
       r.id = (SELECT max(id) FROM fc_runs WHERE status = 'done') AS is_latest
FROM fc_runs r;

-- Экран «Прогноз»: последний расчёт, по неделям, с точностью метода и предупреждением.
CREATE OR REPLACE VIEW v_fc_forecast AS
SELECT f.sku, f.location_id, f.week_no, f.week_start, f.week_end, f.qty, f.qty_base, f.promo_days,
       s.chosen_method AS method, s.wape, s.history_weeks, s.low_history, s.note,
       CASE WHEN s.low_history THEN 'ориентир'
            WHEN s.wape IS NULL THEN 'точность неизвестна'
            WHEN s.wape <= (airl_setting('demand-forecast', 'wape_warn', '30'))::text::numeric THEN 'надёжный'
            WHEN s.wape <= (airl_setting('demand-forecast', 'wape_bad', '50'))::text::numeric THEN 'с запасом'
            ELSE 'грубый' END AS reliability,
       r.run_no, r.as_of
FROM fc_forecasts f
JOIN fc_series s ON s.run_id = f.run_id AND s.sku = f.sku AND s.location_id = f.location_id
JOIN v_fc_runs r ON r.run_id = f.run_id AND r.is_latest;

-- Экран «Методы»: как каждый метод справился на проверке, какой выбран.
CREATE OR REPLACE VIEW v_fc_methods AS
SELECT b.sku, b.location_id, b.method, b.weeks_tested, b.actual, b.abs_error, b.wape, b.mape, b.wape_daily,
       (b.method = s.chosen_method) AS chosen, s.history_weeks, s.low_history, r.run_no, r.as_of
FROM fc_backtest b
JOIN fc_series s ON s.run_id = b.run_id AND s.sku = b.sku AND s.location_id = b.location_id
JOIN v_fc_runs r ON r.run_id = b.run_id AND r.is_latest;

-- График: факт по 7-дневным неделям (последние 26) и прогноз последнего расчёта.
CREATE OR REPLACE VIEW v_fc_chart AS
WITH r AS (SELECT run_id, as_of, run_no FROM v_fc_runs WHERE is_latest)
SELECT s.sku, s.location_id, 'actual'::text AS kind, -((r.as_of - s.day) / 7) AS week_no,
       r.as_of - 7 * ((r.as_of - s.day) / 7) - 6 AS week_start, sum(s.qty) AS qty
FROM src_fc_sales_daily s, r
WHERE s.day <= r.as_of AND s.day > r.as_of - 7 * 26
GROUP BY s.sku, s.location_id, (r.as_of - s.day) / 7, r.as_of
UNION ALL
SELECT f.sku, f.location_id, 'forecast', f.week_no, f.week_start, f.qty
FROM fc_forecasts f JOIN r ON r.run_id = f.run_id;

-- Экран «Закупка»: предложения последнего расчёта по материалам.
CREATE OR REPLACE VIEW v_fc_purchase AS
SELECT g.id AS suggestion_id, g.material_code, m.title, g.unit, m.lead_time_weeks, m.safety_weeks, g.cover_weeks,
       g.need_qty, g.on_hand, g.on_order, g.suggest_qty, m.pack_size, g.uses_low_history,
       g.status, g.decided_at, g.decided_by, g.decision_comment, r.run_no, r.as_of
FROM fc_suggestions g
JOIN fc_materials m ON m.code = g.material_code
JOIN v_fc_runs r ON r.run_id = g.run_id AND r.is_latest;

-- Точность на деле: прогнозы прошлых расчётов против продаж, которые уже случились.
CREATE OR REPLACE VIEW v_fc_accuracy AS
WITH last_day AS (SELECT max(day) AS d FROM src_fc_sales_daily)
SELECT r.run_no, r.as_of, f.sku, f.location_id, f.week_no, f.week_start, f.qty AS forecast,
       COALESCE(a.qty, 0) AS actual, abs(f.qty - COALESCE(a.qty, 0)) AS abs_error
FROM fc_forecasts f
JOIN fc_runs r ON r.id = f.run_id AND r.status = 'done'
CROSS JOIN last_day
LEFT JOIN LATERAL (SELECT sum(s.qty) AS qty FROM src_fc_sales_daily s
                   WHERE s.sku = f.sku AND s.location_id = f.location_id
                     AND s.day BETWEEN f.week_start AND f.week_end) a ON true
WHERE f.week_end <= last_day.d;

-- Показатель: WAPE выбранных методов на проверке (взвешенно по объёму), последний расчёт месяца.
CREATE OR REPLACE VIEW m_forecast_wape AS
WITH last_run AS (
    SELECT DISTINCT ON (date_trunc('month', as_of)) id, as_of
    FROM fc_runs WHERE status = 'done'
    ORDER BY date_trunc('month', as_of), id DESC
),
x AS (
    SELECT lr.as_of, round(100 * sum(b.abs_error) / NULLIF(sum(b.actual), 0), 1) AS v
    FROM last_run lr
    JOIN fc_series s   ON s.run_id = lr.id
    JOIN fc_backtest b ON b.run_id = s.run_id AND b.sku = s.sku AND b.location_id = s.location_id AND b.method = s.chosen_method
    GROUP BY lr.as_of
)
SELECT 'forecast_wape'::text AS metric_id, to_char(as_of, 'YYYY-MM') AS period, v AS value, '%'::text AS unit,
       airl_traffic(v, (airl_setting('demand-forecast', 'wape_warn', '30'))::text::numeric,
                       (airl_setting('demand-forecast', 'wape_bad', '50'))::text::numeric, false) AS status
FROM x;

-- Показатель: доля продаж последних recent_weeks недель, на которую есть прогноз
-- не «по малой истории», последний расчёт месяца.
CREATE OR REPLACE VIEW m_forecast_coverage AS
WITH last_run AS (
    SELECT DISTINCT ON (date_trunc('month', as_of)) id, as_of
    FROM fc_runs WHERE status = 'done'
    ORDER BY date_trunc('month', as_of), id DESC
),
x AS (
    SELECT lr.as_of,
           round(100 * sum(s.recent_volume) FILTER (WHERE NOT s.low_history) / NULLIF(sum(s.recent_volume), 0), 1) AS v
    FROM last_run lr JOIN fc_series s ON s.run_id = lr.id
    GROUP BY lr.as_of
)
SELECT 'forecast_coverage'::text AS metric_id, to_char(as_of, 'YYYY-MM') AS period, v AS value, '%'::text AS unit,
       airl_traffic(v, (airl_setting('demand-forecast', 'coverage_warn', '90'))::text::numeric,
                       (airl_setting('demand-forecast', 'coverage_bad', '70'))::text::numeric, true) AS status
FROM x;

-- Уведомления (после fc_run): предложение закупки больше нуля — закупщику, один раз на
-- расчёт и материал; расчёт упал — аналитику.
CREATE OR REPLACE FUNCTION fc_queue_notifications() RETURNS int
LANGUAGE plpgsql SET search_path FROM CURRENT AS $$
DECLARE
    v_channel text := airl_setting('demand-forecast', 'channel', '"telegram"') #>> '{}';
    v_buyer   text := airl_setting('demand-forecast', 'recipient', '"role:purchasing"') #>> '{}';
    v_tech    text := airl_setting('demand-forecast', 'tech_recipient', '"role:analyst"') #>> '{}';
    v_n int; v_total int := 0;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'demand-forecast:suggestion:' || p.run_no || ':' || p.material_code || ':' || v_buyer, 'demand-forecast',
           v_channel, v_buyer,
           'Прогноз ' || p.run_no || ': заказать ' || p.title || ' ' || replace(to_char(p.suggest_qty, 'FM999,999,990'), ',', ' ') || ' ' || p.unit
           || ' (срок поставки ' || p.lead_time_weeks || ' нед.)'
           || CASE WHEN p.uses_low_history THEN '. Есть товары с малой историей — проверьте вручную' ELSE '' END
    FROM v_fc_purchase p
    WHERE p.status = 'proposed' AND p.suggest_qty > 0
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;

    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'demand-forecast:failed:' || run_no || ':' || v_tech, 'demand-forecast', v_channel, v_tech,
           'Расчёт прогноза ' || run_no || ' не выполнен: ' || error
    FROM fc_runs WHERE status = 'failed'
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT; v_total := v_total + v_n;
    RETURN v_total;
END $$;
