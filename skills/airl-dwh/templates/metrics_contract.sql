-- Контракт единых показателей хаба (схема metrics). Пишет /airl-dwh, команда AIRL.
-- Формулы — дословно из раздела 4 карты компании. Сервисы, хаб и ИИ-слой только читают.
--
-- Что даёт контракт (одинаково для всех потребителей):
--   metrics.definitions            — id, подпись, единица, тип (flow | ratio | point), пороги светофора;
--   metrics.value(id, с, по)       — официальная формула показателя за любой период;
--   metrics.period_bounds(...)     — границы периода и СОПОСТАВИМОГО прошлого: неполный период
--                                    сравнивается с теми же днями прошлого (1–11 ноября ↔ 1–11 октября);
--   metrics.kpi_period(зерно, дата) — все показатели за день / неделю / месяц / квартал:
--                                    значение, прошлое значение, светофор;
--   metrics.m_<id>                 — показатель по месяцам в форме модулей:
--                                    metric_id, period (ГГГГ-ММ), value, unit, status.
--
-- Права: функции принадлежат роли metrics_owner (NOLOGIN, SELECT на нужные таблицы core)
-- и работают как SECURITY DEFINER с фиксированным search_path. Иначе вызывающий
-- (svc_hub, ai_reader) получит «нет прав на core», хотя право на metrics у него есть.
-- Запуск под администратором базы: psql "$ADMIN_DB_URL" -v ON_ERROR_STOP=1 -f metrics_contract.sql
-- Замени всё в [квадратных скобках]; часовой пояс — компании.

CREATE SCHEMA IF NOT EXISTS metrics;
SELECT 'CREATE ROLE metrics_owner NOLOGIN'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metrics_owner') \gexec
GRANT USAGE, CREATE ON SCHEMA metrics TO metrics_owner;
-- [GRANT USAGE ON SCHEMA core TO metrics_owner;]
-- [GRANT SELECT ON core.<таблица>, core.<таблица> TO metrics_owner;]

CREATE TABLE IF NOT EXISTS metrics.definitions (
    metric_id        text PRIMARY KEY,                 -- id из раздела 4 карты
    title            text NOT NULL,                    -- подпись на плитке хаба
    unit             text NOT NULL,                    -- KZT | UZS | % | шт | чел
    kind             text NOT NULL CHECK (kind IN ('flow', 'ratio', 'point')),
                                                       -- flow: сумма за период; ratio: доля; point: на дату
    department       text NOT NULL,
    higher_is_better boolean NOT NULL,
    status_mode      text NOT NULL CHECK (status_mode IN ('abs', 'delta_pct')),
    warn             numeric,                          -- abs: граница; delta_pct: изменение к прошлому, %
    bad              numeric,
    owner            text NOT NULL,
    source           text NOT NULL DEFAULT 'metrics'   -- metrics | mart_<отдел> (считает модуль)
);

-- «Сегодня» показателей: последний загруженный день. Загрузка раз в сутки → вчера.
CREATE OR REPLACE FUNCTION metrics.as_of() RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT (now() AT TIME ZONE '[Asia/Almaty]')::date - 1
$$;

-- Официальные формулы. По ветке WHEN на каждый показатель карты.
CREATE OR REPLACE FUNCTION metrics.value(p_metric text, p_from date, p_to date)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    CASE p_metric
    WHEN '__пример__' THEN RETURN NULL;   -- убери, когда появится первая настоящая ветка
    -- WHEN '[revenue]' THEN
    --     RETURN (SELECT COALESCE(sum(amount_net), 0) FROM core.[sales]
    --             WHERE doc_date BETWEEN p_from AND p_to AND NOT is_deleted AND NOT is_intragroup);
    ELSE
        RAISE EXCEPTION 'Нет показателя % в карте', p_metric;
    END CASE;
END $$;

-- Светофор: abs — по порогам; delta_pct — по изменению к сопоставимому прошлому периоду.
CREATE OR REPLACE FUNCTION metrics.status(p_metric text, p_value numeric, p_prev numeric)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT CASE
        WHEN p_value IS NULL THEN 'warning'
        WHEN d.warn IS NULL THEN 'ok'
        WHEN d.status_mode = 'abs' AND d.higher_is_better THEN
             CASE WHEN p_value <= d.bad THEN 'danger' WHEN p_value <= d.warn THEN 'warning' ELSE 'ok' END
        WHEN d.status_mode = 'abs' THEN
             CASE WHEN p_value >= d.bad THEN 'danger' WHEN p_value >= d.warn THEN 'warning' ELSE 'ok' END
        WHEN p_prev IS NULL OR p_prev = 0 THEN 'ok'
        ELSE CASE WHEN 100 * (p_value - p_prev) / abs(p_prev) < d.bad THEN 'danger'
                  WHEN 100 * (p_value - p_prev) / abs(p_prev) < d.warn THEN 'warning' ELSE 'ok' END
    END
    FROM metrics.definitions d WHERE d.metric_id = p_metric
$$;

-- Границы периода и сопоставимого прошлого периода (те же дни).
CREATE OR REPLACE FUNCTION metrics.period_bounds(p_grain text, p_at date,
    OUT cur_from date, OUT cur_to date, OUT prev_from date, OUT prev_to date, OUT label text)
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_step interval;
BEGIN
    cur_to := p_at;
    CASE p_grain
    WHEN 'day'     THEN cur_from := p_at;                                 v_step := interval '1 day';
    WHEN 'week'    THEN cur_from := date_trunc('week', p_at)::date;       v_step := interval '7 days';
    WHEN 'month'   THEN cur_from := date_trunc('month', p_at)::date;      v_step := interval '1 month';
    WHEN 'quarter' THEN cur_from := date_trunc('quarter', p_at)::date;    v_step := interval '3 months';
    ELSE RAISE EXCEPTION 'Период % не поддерживается', p_grain;
    END CASE;
    label := CASE WHEN p_grain = 'day' THEN to_char(p_at, 'DD.MM.YYYY')
                  ELSE to_char(cur_from, 'DD.MM') || '–' || to_char(p_at, 'DD.MM.YYYY') END;
    prev_from := (cur_from - v_step)::date;
    prev_to := least((p_at - v_step)::date, cur_from - 1);
END $$;

-- Все показатели карты за период с прошлым периодом и светофором.
CREATE OR REPLACE FUNCTION metrics.kpi_period(p_grain text, p_at date DEFAULT NULL)
RETURNS TABLE (metric_id text, title text, unit text, department text, period text,
               value numeric, prev_value numeric, status text,
               cur_from date, cur_to date, prev_from date, prev_to date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH b AS (SELECT * FROM metrics.period_bounds(p_grain, COALESCE(p_at, metrics.as_of())))
    SELECT d.metric_id, d.title, d.unit, d.department, b.label,
           v.cur, v.prev, metrics.status(d.metric_id, v.cur, v.prev),
           b.cur_from, b.cur_to, b.prev_from, b.prev_to
    FROM (SELECT * FROM metrics.definitions WHERE source = 'metrics') d CROSS JOIN b
    CROSS JOIN LATERAL (SELECT metrics.value(d.metric_id, b.cur_from, b.cur_to)   AS cur,
                               metrics.value(d.metric_id, b.prev_from, b.prev_to) AS prev) v
    ORDER BY d.department, d.metric_id
$$;

-- Показатель по месяцам в форме модулей. Текущий месяц — «с 1-го по вчера»,
-- его светофор сравнивается с теми же днями прошлого месяца.
CREATE OR REPLACE FUNCTION metrics.monthly(p_metric text, p_months int DEFAULT 18)
RETURNS TABLE (metric_id text, period text, value numeric, unit text, status text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH m AS (
        SELECT (date_trunc('month', metrics.as_of()) - make_interval(months => k))::date AS ms
        FROM generate_series(0, p_months - 1) k
    ), b AS (
        SELECT ms, (metrics.period_bounds('month', least(metrics.as_of(), (ms + interval '1 month')::date - 1))).*
        FROM m
    )
    SELECT p_metric, to_char(b.ms, 'YYYY-MM'), v.cur, d.unit, metrics.status(p_metric, v.cur, v.prev)
    FROM b
    JOIN metrics.definitions d ON d.metric_id = p_metric
    CROSS JOIN LATERAL (SELECT metrics.value(p_metric, b.cur_from, b.cur_to)   AS cur,
                               metrics.value(p_metric, b.prev_from, b.prev_to) AS prev) v
    WHERE v.cur IS NOT NULL
$$;

-- Представление на каждый показатель: metrics.m_<id>.
-- CREATE OR REPLACE VIEW metrics.m_[revenue] AS SELECT * FROM metrics.monthly('[revenue]');

ALTER FUNCTION metrics.as_of() OWNER TO metrics_owner;
ALTER FUNCTION metrics.value(text, date, date) OWNER TO metrics_owner;
ALTER FUNCTION metrics.status(text, numeric, numeric) OWNER TO metrics_owner;
ALTER FUNCTION metrics.kpi_period(text, date) OWNER TO metrics_owner;
ALTER FUNCTION metrics.monthly(text, int) OWNER TO metrics_owner;
ALTER TABLE metrics.definitions OWNER TO metrics_owner;

-- Чтение: сервисы, хаб и ИИ-слой (имена — из карты, раздел 7, и /airl-ai).
-- [GRANT USAGE ON SCHEMA metrics TO svc_<отдел>, svc_hub, ai_reader;]
-- [GRANT SELECT ON ALL TABLES IN SCHEMA metrics TO svc_<отдел>, svc_hub, ai_reader;]
-- [ALTER DEFAULT PRIVILEGES FOR ROLE metrics_owner IN SCHEMA metrics GRANT SELECT ON TABLES TO svc_<отдел>, svc_hub, ai_reader;]
