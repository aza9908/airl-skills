-- Модуль «План-факт» (plan-fact). Требует kit/kit.sql в той же схеме
-- и представление src_facts (адаптер или demo_src.sql).
-- Планы вводят люди (таблица pf_plans), факты приходят из src_facts.

-- Какие показатели планируем и как их складывать.
CREATE TABLE IF NOT EXISTS pf_metric_defs (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    metric_id        text        NOT NULL UNIQUE,     -- как в разделе 4 карты (revenue, gross_profit…)
    title            text        NOT NULL,
    unit             text        NOT NULL,
    aggregation      text        NOT NULL DEFAULT 'sum' CHECK (aggregation IN ('sum', 'last')),
    higher_is_better boolean     NOT NULL DEFAULT true,
    active           boolean     NOT NULL DEFAULT true,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       text        NOT NULL,
    updated_at       timestamptz,
    updated_by       text
);

-- Планы. Изменить план = старую строку в superseded, новую — active (функция pf_set_plan).
CREATE TABLE IF NOT EXISTS pf_plans (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    metric_id       text          NOT NULL REFERENCES pf_metric_defs (metric_id),
    period          date          NOT NULL CHECK (extract(day FROM period) = 1),
    dimension_type  text          NOT NULL
                    CHECK (dimension_type IN ('company', 'branch', 'manager', 'category', 'channel', 'city')),
    dimension_value text          NOT NULL,
    plan_value      numeric(18,2) NOT NULL CHECK (plan_value >= 0),
    status          text          NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'superseded', 'cancelled')),
    comment         text,
    created_at      timestamptz   NOT NULL DEFAULT now(),
    created_by      text          NOT NULL,
    updated_at      timestamptz,
    updated_by      text,
    CHECK (dimension_type <> 'company' OR dimension_value = 'all')
);
CREATE UNIQUE INDEX IF NOT EXISTS pf_plans_active_uq
    ON pf_plans (metric_id, period, dimension_type, dimension_value) WHERE status = 'active';

DROP TRIGGER IF EXISTS pf_metric_defs_touch ON pf_metric_defs;
CREATE TRIGGER pf_metric_defs_touch BEFORE UPDATE ON pf_metric_defs FOR EACH ROW EXECUTE FUNCTION airl_touch();
DROP TRIGGER IF EXISTS pf_plans_touch ON pf_plans;
CREATE TRIGGER pf_plans_touch BEFORE UPDATE ON pf_plans FOR EACH ROW EXECUTE FUNCTION airl_touch();

-- Цифру плана не правят на месте: только новая версия. Статус — только из active.
CREATE OR REPLACE FUNCTION pf_plans_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.plan_value <> OLD.plan_value OR NEW.metric_id <> OLD.metric_id OR NEW.period <> OLD.period
       OR NEW.dimension_type <> OLD.dimension_type OR NEW.dimension_value <> OLD.dimension_value THEN
        RAISE EXCEPTION 'plan-fact: план % не правится на месте — используйте pf_set_plan', OLD.id;
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        IF OLD.status <> 'active' THEN
            RAISE EXCEPTION 'plan-fact: переход % → % не разрешён (план %)', OLD.status, NEW.status, OLD.id;
        END IF;
        INSERT INTO airl_audit (actor, module, entity, entity_id, action, from_status, to_status, comment, details)
        VALUES (COALESCE(NEW.updated_by, 'system'), 'plan-fact', 'plan', OLD.id::text, 'status',
                OLD.status, NEW.status, NEW.comment, jsonb_build_object('plan_value', OLD.plan_value));
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pf_plans_guard ON pf_plans;
CREATE TRIGGER pf_plans_guard BEFORE UPDATE ON pf_plans FOR EACH ROW EXECUTE FUNCTION pf_plans_guard();

-- Поставить или изменить план: прежний активный уходит в superseded, история остаётся.
CREATE OR REPLACE FUNCTION pf_set_plan(p_metric_id text, p_period date, p_dimension_type text,
                                       p_dimension_value text, p_value numeric, p_actor text, p_comment text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
    UPDATE pf_plans SET status = 'superseded', updated_by = p_actor, comment = COALESCE(p_comment, comment)
     WHERE metric_id = p_metric_id AND period = date_trunc('month', p_period)::date
       AND dimension_type = p_dimension_type AND dimension_value = p_dimension_value AND status = 'active';
    INSERT INTO pf_plans (metric_id, period, dimension_type, dimension_value, plan_value, comment, created_by)
    VALUES (p_metric_id, date_trunc('month', p_period)::date, p_dimension_type, p_dimension_value, p_value, p_comment, p_actor)
    RETURNING id INTO v_id;
    INSERT INTO airl_audit (actor, module, entity, entity_id, action, comment, details)
    VALUES (p_actor, 'plan-fact', 'plan', v_id::text, 'create', p_comment, jsonb_build_object('plan_value', p_value));
    RETURN v_id;
END $$;

-- Факт по месяцам: sum — сумма за месяц, last — последнее значение в месяце.
CREATE OR REPLACE VIEW v_pf_facts_month AS
SELECT f.metric_id,
       date_trunc('month', f.period)::date AS month,
       f.dimension_type, f.dimension_value,
       (CASE WHEN COALESCE(d.aggregation, 'sum') = 'last'
             THEN (array_agg(f.value ORDER BY f.period DESC))[1]
             ELSE sum(f.value) END)::numeric AS fact_value,
       max(f.period) AS last_fact_date
FROM src_facts f
LEFT JOIN pf_metric_defs d ON d.metric_id = f.metric_id
GROUP BY f.metric_id, date_trunc('month', f.period)::date, f.dimension_type, f.dimension_value, d.aggregation;

-- План против факта по каждой активной строке плана.
-- Прогноз на конец месяца (ОЦЕНКА) — линейно по рабочим дням: факт / прошло дней × дней в месяце.
-- Данные считаются полными по (сегодня − facts_lag_days). Для показателей «last» прогноз = факт.
CREATE OR REPLACE VIEW v_pf_plan_fact AS
WITH cfg AS (
    SELECT (airl_setting('plan-fact', 'facts_lag_days', '1'))::text::int AS lag_days,
           ARRAY(SELECT jsonb_array_elements_text(airl_setting('plan-fact', 'work_weekdays', '[1,2,3,4,5,6,7]'))::int) AS weekdays,
           (airl_setting('plan-fact', 'warn_below_pct', '95'))::text::numeric  AS warn_below,
           (airl_setting('plan-fact', 'bad_below_pct', '85'))::text::numeric   AS bad_below,
           (airl_setting('plan-fact', 'warn_above_pct', '105'))::text::numeric AS warn_above,
           (airl_setting('plan-fact', 'bad_above_pct', '115'))::text::numeric  AS bad_above
),
base AS (
    SELECT p.id AS plan_id, p.metric_id, d.title, d.unit, d.aggregation, d.higher_is_better,
           p.period AS month, p.dimension_type, p.dimension_value, p.plan_value, p.comment, p.created_at, p.created_by,
           f.fact_value, f.last_fact_date, ly.fact_value AS ly_fact_value,
           (CASE WHEN p.period = date_trunc('month', current_date)::date THEN 'current'
                 WHEN p.period < date_trunc('month', current_date)::date THEN 'past'
                 ELSE 'future' END)::text AS month_state,
           (SELECT count(*) FROM generate_series(p.period, (p.period + interval '1 month' - interval '1 day')::date, interval '1 day') g(dd)
             WHERE extract(isodow FROM g.dd)::int = ANY (cfg.weekdays))::int AS work_days_total,
           (SELECT count(*) FROM generate_series(p.period, least(current_date - cfg.lag_days,
                                                   (p.period + interval '1 month' - interval '1 day')::date), interval '1 day') g(dd)
             WHERE extract(isodow FROM g.dd)::int = ANY (cfg.weekdays))::int AS work_days_passed,
           cfg.warn_below, cfg.bad_below, cfg.warn_above, cfg.bad_above
    FROM pf_plans p
    CROSS JOIN cfg
    JOIN pf_metric_defs d ON d.metric_id = p.metric_id
    LEFT JOIN v_pf_facts_month f
           ON f.metric_id = p.metric_id AND f.month = p.period
          AND f.dimension_type = p.dimension_type AND f.dimension_value = p.dimension_value
    LEFT JOIN v_pf_facts_month ly
           ON ly.metric_id = p.metric_id AND ly.month = (p.period - interval '1 year')::date
          AND ly.dimension_type = p.dimension_type AND ly.dimension_value = p.dimension_value
    WHERE p.status = 'active'
),
fc AS (
    SELECT b.*,
           (CASE WHEN b.month_state = 'past' THEN b.fact_value
                 WHEN b.month_state = 'current' AND b.aggregation = 'last' THEN b.fact_value
                 WHEN b.month_state = 'current' AND b.work_days_passed > 0
                      THEN round(COALESCE(b.fact_value, 0) * b.work_days_total / b.work_days_passed, 2)
            END)::numeric AS forecast_value
    FROM base b
),
pct AS (
    SELECT fc.*,
           round(100.0 * fc.fact_value / NULLIF(fc.plan_value, 0), 1) AS completion_pct,
           round(100.0 * fc.forecast_value / NULLIF(fc.plan_value, 0), 1) AS forecast_pct
    FROM fc
)
SELECT plan_id, metric_id, title, unit, higher_is_better,
       month, to_char(month, 'YYYY-MM') AS period, month_state,
       dimension_type, dimension_value,
       plan_value, fact_value, last_fact_date,
       completion_pct,
       (fact_value - plan_value)::numeric(18,2) AS deviation,
       forecast_value, forecast_pct,
       (forecast_value - plan_value)::numeric(18,2) AS forecast_deviation,
       work_days_total, work_days_passed,
       ly_fact_value,
       round(100.0 * (fact_value - ly_fact_value) / NULLIF(ly_fact_value, 0), 1) AS yoy_pct,
       (CASE WHEN month_state = 'future' THEN NULL
             ELSE airl_traffic(CASE WHEN month_state = 'current' THEN forecast_pct ELSE completion_pct END,
                               CASE WHEN higher_is_better THEN warn_below ELSE warn_above END,
                               CASE WHEN higher_is_better THEN bad_below ELSE bad_above END,
                               higher_is_better) END)::text AS status,
       comment, created_at, created_by
FROM pct;

-- Экран «Текущий месяц»: все разрезы, сначала красные.
CREATE OR REPLACE VIEW v_pf_current AS
SELECT *
FROM v_pf_plan_fact
WHERE month_state = 'current'
ORDER BY CASE status WHEN 'danger' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END,
         metric_id, dimension_type, dimension_value;

-- Экран «История»: уровень компании по месяцам, факт, прошлый год и план (если был).
CREATE OR REPLACE VIEW v_pf_history AS
SELECT f.metric_id, d.title, d.unit, f.month, to_char(f.month, 'YYYY-MM') AS period,
       f.fact_value, ly.fact_value AS ly_fact_value,
       round(100.0 * (f.fact_value - ly.fact_value) / NULLIF(ly.fact_value, 0), 1) AS yoy_pct,
       p.plan_value,
       round(100.0 * f.fact_value / NULLIF(p.plan_value, 0), 1) AS completion_pct
FROM v_pf_facts_month f
LEFT JOIN pf_metric_defs d ON d.metric_id = f.metric_id
LEFT JOIN v_pf_facts_month ly
       ON ly.metric_id = f.metric_id AND ly.month = (f.month - interval '1 year')::date
      AND ly.dimension_type = f.dimension_type AND ly.dimension_value = f.dimension_value
LEFT JOIN pf_plans p
       ON p.metric_id = f.metric_id AND p.period = f.month AND p.status = 'active'
      AND p.dimension_type = f.dimension_type AND p.dimension_value = f.dimension_value
WHERE f.dimension_type = 'company';

-- Реестр планов с историей изменений (superseded — прежние версии).
CREATE OR REPLACE VIEW v_pf_plans AS
SELECT p.id AS plan_id, p.metric_id, d.title, d.unit, p.period AS month, to_char(p.period, 'YYYY-MM') AS period,
       p.dimension_type, p.dimension_value, p.plan_value, p.status, p.comment,
       p.created_at, p.created_by, p.updated_at, p.updated_by
FROM pf_plans p
JOIN pf_metric_defs d ON d.metric_id = p.metric_id;

-- Сигналы о критических отклонениях: красные строки текущего месяца после signal_from_day.
-- Получатель: для разреза «менеджер» — сам менеджер, иначе — signal_recipient.
CREATE OR REPLACE VIEW v_pf_signals AS
SELECT pf.plan_id, pf.metric_id, pf.title, pf.unit, pf.period, pf.dimension_type, pf.dimension_value,
       pf.plan_value, pf.fact_value, pf.forecast_value, pf.forecast_pct,
       CASE WHEN pf.dimension_type = 'manager' THEN pf.dimension_value
            ELSE airl_setting('plan-fact', 'signal_recipient', '"role:director"') #>> '{}' END AS recipient
FROM v_pf_plan_fact pf
WHERE pf.month_state = 'current'
  AND pf.status = 'danger'
  AND extract(day FROM current_date) >= (airl_setting('plan-fact', 'signal_from_day', '7'))::text::int;

-- Показатель: выполнение плана по каждому показателю, уровень компании, по месяцам.
-- metric_id = 'plan_completion:<показатель>'. Значение — факт / план, %;
-- цвет текущего месяца — по прогнозу на конец месяца, прошлых — по факту.
CREATE OR REPLACE VIEW m_plan_completion AS
SELECT ('plan_completion:' || metric_id)::text AS metric_id,
       period,
       COALESCE(completion_pct, 0)::numeric AS value,
       '%'::text AS unit,
       status
FROM v_pf_plan_fact
WHERE dimension_type = 'company' AND month_state IN ('past', 'current');

-- Очередь уведомлений по v_pf_signals: одно на строку плана, месяц и получателя.
CREATE OR REPLACE FUNCTION pf_queue_signals() RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_channel text := airl_setting('plan-fact', 'channel', '"telegram"') #>> '{}';
    v_n int;
BEGIN
    INSERT INTO airl_notifications (dedup_key, module, channel, recipient, text)
    SELECT 'plan-fact:danger:' || s.metric_id || '.' || s.period || '.' || s.dimension_type || '.' || s.dimension_value
           || ':' || s.recipient,
           'plan-fact', v_channel, s.recipient,
           s.title || ' (' || s.dimension_type || ' ' || s.dimension_value || '): прогноз на конец месяца '
           || COALESCE(s.forecast_pct::text, '—') || '% плана (оценка)'
    FROM v_pf_signals s
    WHERE s.recipient IS NOT NULL
    ON CONFLICT (dedup_key) DO NOTHING;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;
