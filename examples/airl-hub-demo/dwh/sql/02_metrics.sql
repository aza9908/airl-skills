-- Единые показатели (metrics). Формулы — дословно по разделу 4 COMPANY_MAP.md.
-- Пишет только команда AIRL. Сервисы, хаб и ИИ-слой читают отсюда и не считают сами.
--
-- Устройство:
--   metrics.value(id, с, по [, юрлицо]) — официальная формула показателя за период;
--   metrics.status(id, значение, сравнение) — светофор по порогам metrics.thresholds;
--   metrics.m_<id>          — показатель по месяцам: metric_id, period, value, unit, status
--                             (та же форма, что m_<…> модулей); текущий месяц — «с 1-го по вчера»,
--                             статус сравнивается с теми же днями прошлого месяца;
--   metrics.kpi_period(...) — все показатели за день / неделю / месяц / квартал с прошлым периодом;
--   metrics.series(...)     — ряд для графика; metrics.pnl(...) — управленческий ОПиУ;
--   metrics.receivables_aging(...), metrics.lead_funnel(...) — расшифровки для экрана руководителя.
-- Данные загружаются раз в сутки, поэтому «сегодня» для показателей — вчерашний день.

CREATE TABLE IF NOT EXISTS metrics.definitions (
    metric_id        text PRIMARY KEY,
    title            text NOT NULL,
    unit             text NOT NULL,          -- KZT | % | шт | чел
    kind             text NOT NULL CHECK (kind IN ('flow', 'ratio', 'point')),
    department       text NOT NULL,          -- чей показатель на экране руководителя
    higher_is_better boolean NOT NULL,
    status_mode      text NOT NULL CHECK (status_mode IN ('abs', 'delta_pct')),
    warn             numeric,                -- abs: граница; delta_pct: падение к прошлому периоду, %
    bad              numeric,
    owner            text NOT NULL,
    source           text NOT NULL DEFAULT 'metrics'  -- metrics | mart_<отдел> (показатель модуля или сервиса)
);
ALTER TABLE metrics.definitions ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'metrics';

INSERT INTO metrics.definitions VALUES
 ('revenue',                 'Выручка',                       'KZT', 'flow',  'finance', true,  'delta_pct', -5,  -15, 'Финансовый директор'),
 ('gross_margin',            'Валовая маржа',                 '%',   'ratio', 'finance', true,  'abs',       65,  55,  'Финансовый директор'),
 ('net_profit',              'Чистая прибыль',                'KZT', 'flow',  'finance', true,  'abs',       0,   0,   'Финансовый директор'),
 ('cash_balance',            'Остаток денег',                 'KZT', 'point', 'finance', true,  'abs',       25000000, 12000000, 'Финансовый директор'),
 ('receivables_overdue',     'Просроченная дебиторка',        'KZT', 'point', 'finance', false, 'abs',       8000000,  15000000, 'Финансовый директор'),
 ('lead',                    'Заявки',                        'шт',  'flow',  'sales',   true,  'delta_pct', -10, -25, 'Руководитель продаж'),
 ('conversion_lead_to_deal', 'Конверсия заявки в оплату',     '%',   'ratio', 'sales',   true,  'abs',       8,   5,   'Руководитель продаж'),
 ('avg_check',               'Средний чек',                   'KZT', 'ratio', 'sales',   true,  'delta_pct', -10, -25, 'Руководитель продаж'),
 ('enrollments',             'Записи на курс',                'чел', 'flow',  'edu',     true,  'delta_pct', -10, -25, 'Руководитель обучения'),
 ('cohort_fill_rate',        'Заполненность потоков',         '%',   'point', 'edu',     true,  'abs',       85,  70,  'Руководитель обучения'),
 ('course_completion_rate',  'Доля завершивших курс',         '%',   'point', 'edu',     true,  'abs',       80,  65,  'Руководитель обучения'),
 ('headcount',               'Численность',                   'чел', 'point', 'ceo',     true,  'abs',       NULL, NULL, 'Генеральный директор')
ON CONFLICT (metric_id) DO UPDATE SET title = EXCLUDED.title, unit = EXCLUDED.unit, kind = EXCLUDED.kind,
    department = EXCLUDED.department, higher_is_better = EXCLUDED.higher_is_better,
    status_mode = EXCLUDED.status_mode, warn = EXCLUDED.warn, bad = EXCLUDED.bad, owner = EXCLUDED.owner;

-- Показатели карты, которые считает модуль или сервис в своей витрине (источник правды —
-- сервис, раздел 2 карты). Здесь только название и единица для подписей хаба.
INSERT INTO metrics.definitions (metric_id, title, unit, kind, department, higher_is_better, status_mode, warn, bad, owner, source) VALUES
 ('plan_completion',           'Выполнение плана',               '%',   'ratio', 'sales',   true,  'abs', NULL, NULL, 'Руководитель продаж',   'mart_sales'),
 ('receivables_overdue_share', 'Доля просрочки в дебиторке',     '%',   'point', 'finance', false, 'abs', NULL, NULL, 'Финансовый директор',   'mart_finance'),
 ('bank_unmatched_count',      'Неразнесённые строки выписки',   'шт',  'point', 'finance', false, 'abs', NULL, NULL, 'Главный бухгалтер',     'mart_finance'),
 ('bank_auto_match_rate',      'Доля строк, разнесённых по подсказке', '%', 'ratio', 'finance', true, 'abs', NULL, NULL, 'Главный бухгалтер', 'mart_finance'),
 ('edu_at_risk',               'Слушатели под риском отсева',    'чел', 'point', 'edu',     false, 'abs', NULL, NULL, 'Руководитель обучения', 'mart_edu')
ON CONFLICT (metric_id) DO UPDATE SET title = EXCLUDED.title, unit = EXCLUDED.unit, department = EXCLUDED.department, source = EXCLUDED.source;

-- «Сегодня» показателей: последний загруженный день (данные за вчера).
CREATE OR REPLACE FUNCTION metrics.as_of() RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ SELECT (now() AT TIME ZONE 'Asia/Almaty')::date - 1 $$;

-- Выручка: «Реализация» без НДС по дате документа, без внутригрупповых продаж.
-- Для отчёта юрлица (p_entity) внутригрупповые продажи этого юрлица входят.
CREATE OR REPLACE FUNCTION metrics.revenue(p_from date, p_to date, p_entity text DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT COALESCE(sum(amount_net), 0) FROM core.sales_docs
    WHERE doc_date BETWEEN p_from AND p_to AND currency = 'KZT'
      AND (CASE WHEN p_entity IS NULL THEN NOT is_intragroup ELSE entity_id = p_entity END)
$$;

-- Расходы по статьям (без НДС), без внутригрупповых для компании.
CREATE OR REPLACE FUNCTION metrics.expense(p_from date, p_to date, p_articles text[], p_entity text DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT COALESCE(sum(amount_net), 0) FROM core.expenses
    WHERE doc_date BETWEEN p_from AND p_to
      AND (p_articles IS NULL OR article = ANY (p_articles))
      AND (CASE WHEN p_entity IS NULL THEN NOT is_intragroup ELSE entity_id = p_entity END)
$$;

-- Прямые расходы (себестоимость услуг): статьи «Подрядчики» и «Облако и API ИИ».
CREATE OR REPLACE FUNCTION metrics.direct_articles() RETURNS text[]
LANGUAGE sql IMMUTABLE AS $$ SELECT ARRAY['Подрядчики', 'Облако и API ИИ'] $$;

-- Остаток денег на конец дня p_at: начальные остатки + поступления − списания (по 1С).
CREATE OR REPLACE FUNCTION metrics.cash_at(p_at date, p_entity text DEFAULT NULL)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT COALESCE((SELECT sum(o.amount) FROM core.cash_openings o JOIN core.cash_accounts a USING (account_id)
                     WHERE o.as_of <= p_at AND a.currency = 'KZT' AND (p_entity IS NULL OR a.entity_id = p_entity)), 0)
         + COALESCE((SELECT sum(p.amount) FROM core.payments_in p JOIN core.cash_accounts a USING (account_id)
                     WHERE p.pay_date <= p_at AND a.currency = 'KZT' AND (p_entity IS NULL OR a.entity_id = p_entity)), 0)
         - COALESCE((SELECT sum(p.amount) FROM core.payments_out p JOIN core.cash_accounts a USING (account_id)
                     WHERE p.pay_date <= p_at AND a.currency = 'KZT' AND (p_entity IS NULL OR a.entity_id = p_entity)), 0)
$$;

-- Остаток долга по документу на конец дня p_at.
CREATE OR REPLACE FUNCTION metrics.doc_balance(p_doc text, p_gross numeric, p_at date)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT p_gross - COALESCE((SELECT sum(amount) FROM core.payments_in WHERE doc_id = p_doc AND pay_date <= p_at), 0)
$$;

-- Просроченная дебиторка на конец дня p_at: остатки документов (с НДС), срок оплаты
-- которых прошёл (срок < следующего дня), без внутригрупповых. Переплаты не вычитаются.
CREATE OR REPLACE FUNCTION metrics.receivables_overdue_at(p_at date)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT COALESCE(sum(b), 0) FROM (
        SELECT metrics.doc_balance(d.doc_id, d.amount_gross, p_at) AS b
        FROM core.sales_docs d
        WHERE NOT d.is_intragroup AND d.currency = 'KZT' AND d.doc_date <= p_at
          AND d.due_date IS NOT NULL AND d.due_date <= p_at
    ) x WHERE b > 0
$$;

-- Официальная формула каждого показателя за период [p_from; p_to].
CREATE OR REPLACE FUNCTION metrics.value(p_metric text, p_from date, p_to date, p_entity text DEFAULT NULL)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_rev numeric; v_n numeric; v_d numeric;
BEGIN
    CASE p_metric
    WHEN 'revenue' THEN
        RETURN metrics.revenue(p_from, p_to, p_entity);
    WHEN 'gross_margin' THEN
        v_rev := metrics.revenue(p_from, p_to, p_entity);
        IF v_rev = 0 THEN RETURN NULL; END IF;
        RETURN round(100 * (v_rev - metrics.expense(p_from, p_to, metrics.direct_articles(), p_entity)) / v_rev, 1);
    WHEN 'net_profit' THEN
        RETURN metrics.revenue(p_from, p_to, p_entity) - metrics.expense(p_from, p_to, NULL, p_entity);
    WHEN 'cash_balance' THEN
        RETURN metrics.cash_at(p_to, p_entity);
    WHEN 'receivables_overdue' THEN
        RETURN metrics.receivables_overdue_at(p_to);
    WHEN 'lead' THEN
        RETURN (SELECT count(*) FROM core.leads WHERE created_date BETWEEN p_from AND p_to AND NOT is_duplicate);
    WHEN 'conversion_lead_to_deal' THEN
        -- оплаты периода (заявка «Успешно реализовано», дата закрытия в периоде) / заявки периода
        SELECT count(*) INTO v_n FROM core.leads
        WHERE stage = 'won' AND closed_date BETWEEN p_from AND p_to AND NOT is_duplicate;
        SELECT count(*) INTO v_d FROM core.leads
        WHERE created_date BETWEEN p_from AND p_to AND NOT is_duplicate;
        RETURN CASE WHEN v_d = 0 THEN NULL ELSE round(100 * v_n / v_d, 1) END;
    WHEN 'avg_check' THEN
        SELECT COALESCE(sum(amount_net), 0), count(DISTINCT client_id) INTO v_n, v_d
        FROM core.sales_docs WHERE doc_date BETWEEN p_from AND p_to AND NOT is_intragroup AND currency = 'KZT';
        RETURN CASE WHEN v_d = 0 THEN NULL ELSE round(v_n / v_d, 0) END;
    WHEN 'enrollments' THEN
        RETURN (SELECT COALESCE(sum(qty), 0) FROM core.sales_docs
                WHERE service_line = 'Курс VibeOps' AND doc_date BETWEEN p_from AND p_to AND NOT is_intragroup);
    WHEN 'cohort_fill_rate' THEN
        -- потоки в наборе: старт в ближайшие 45 дней после конца периода; места, проданные к концу периода
        SELECT COALESCE(sum(s.qty), 0) INTO v_n
        FROM core.cohorts c JOIN core.sales_docs s ON s.cohort_code = c.cohort_code
        WHERE c.start_date > p_to AND c.start_date <= p_to + 45 AND NOT s.is_intragroup AND s.doc_date <= p_to;
        SELECT sum(capacity) INTO v_d FROM core.cohorts WHERE start_date > p_to AND start_date <= p_to + 45;
        RETURN CASE WHEN COALESCE(v_d, 0) = 0 THEN NULL ELSE round(100 * v_n / v_d, 1) END;
    WHEN 'course_completion_rate' THEN
        -- потоки, закончившиеся за 90 дней до конца периода: завершили / (завершили + отчислены)
        SELECT count(*) FILTER (WHERE e.status = 'завершил'), count(*) FILTER (WHERE e.status IN ('завершил', 'отчислен'))
          INTO v_n, v_d
        FROM core.enrollments e JOIN core.cohorts c USING (cohort_code)
        WHERE c.end_date > p_to - 90 AND c.end_date <= p_to;
        RETURN CASE WHEN v_d = 0 THEN NULL ELSE round(100 * v_n / v_d, 1) END;
    WHEN 'headcount' THEN
        RETURN (SELECT count(*) FROM core.employees WHERE hire_date <= p_to AND (fire_date IS NULL OR fire_date > p_to));
    ELSE
        RAISE EXCEPTION 'Нет показателя % в карте', p_metric;
    END CASE;
END $$;

-- Светофор: abs — по порогам; delta_pct — по изменению к прошлому периоду.
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

-- Границы периода и сопоставимого прошлого периода. Неполный период сравнивается
-- с тем же числом дней прошлого (1–11 ноября против 1–11 октября).
CREATE OR REPLACE FUNCTION metrics.period_bounds(p_grain text, p_at date,
    OUT cur_from date, OUT cur_to date, OUT prev_from date, OUT prev_to date, OUT label text)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_step interval;
BEGIN
    cur_to := p_at;
    CASE p_grain
    WHEN 'day' THEN
        cur_from := p_at; v_step := interval '1 day';
        label := to_char(p_at, 'DD.MM.YYYY');
    WHEN 'week' THEN
        cur_from := date_trunc('week', p_at)::date; v_step := interval '7 days';
        label := to_char(cur_from, 'DD.MM') || '–' || to_char(p_at, 'DD.MM.YYYY');
    WHEN 'month' THEN
        cur_from := date_trunc('month', p_at)::date; v_step := interval '1 month';
        label := to_char(cur_from, 'DD.MM') || '–' || to_char(p_at, 'DD.MM.YYYY');
    WHEN 'quarter' THEN
        cur_from := date_trunc('quarter', p_at)::date; v_step := interval '3 months';
        label := to_char(cur_from, 'DD.MM') || '–' || to_char(p_at, 'DD.MM.YYYY');
    ELSE
        RAISE EXCEPTION 'Период % не поддерживается', p_grain;
    END CASE;
    prev_from := (cur_from - v_step)::date;
    prev_to := least((p_at - v_step)::date, (cur_from - 1));
END $$;

-- Все показатели карты за период с прошлым периодом и светофором.
CREATE OR REPLACE FUNCTION metrics.kpi_period(p_grain text, p_at date DEFAULT NULL)
RETURNS TABLE (metric_id text, title text, unit text, department text, period text,
               value numeric, prev_value numeric, status text, cur_from date, cur_to date,
               prev_from date, prev_to date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH b AS (SELECT * FROM metrics.period_bounds(p_grain, COALESCE(p_at, metrics.as_of())))
    SELECT d.metric_id, d.title, d.unit, d.department, b.label,
           v.cur, v.prev, metrics.status(d.metric_id, v.cur, v.prev),
           b.cur_from, b.cur_to, b.prev_from, b.prev_to
    FROM (SELECT * FROM metrics.definitions WHERE source = 'metrics') d CROSS JOIN b
    CROSS JOIN LATERAL (SELECT metrics.value(d.metric_id, b.cur_from, b.cur_to)  AS cur,
                               metrics.value(d.metric_id, b.prev_from, b.prev_to) AS prev) v
    ORDER BY d.department, d.metric_id
$$;

-- Ряд для графика: последние p_n периодов зерна p_grain (неполный текущий — «по вчера»).
CREATE OR REPLACE FUNCTION metrics.series(p_metric text, p_grain text, p_n int, p_at date DEFAULT NULL)
RETURNS TABLE (period_start date, period_end date, label text, value numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH a AS (SELECT COALESCE(p_at, metrics.as_of()) AS at),
    s AS (
        SELECT (date_trunc(CASE p_grain WHEN 'day' THEN 'day' ELSE p_grain END, a.at)
                - (k * CASE p_grain WHEN 'day' THEN interval '1 day' WHEN 'week' THEN interval '7 days'
                                    WHEN 'month' THEN interval '1 month' ELSE interval '3 months' END))::date AS ps,
               a.at
        FROM a, generate_series(p_n - 1, 0, -1) k
    ),
    e AS (
        SELECT ps, least(at, (ps + CASE p_grain WHEN 'day' THEN interval '1 day' WHEN 'week' THEN interval '7 days'
                                  WHEN 'month' THEN interval '1 month' ELSE interval '3 months' END)::date - 1) AS pe
        FROM s
    )
    SELECT ps, pe,
           CASE p_grain WHEN 'day' THEN to_char(ps, 'DD.MM') WHEN 'week' THEN to_char(ps, 'DD.MM')
                        WHEN 'month' THEN to_char(ps, 'MM.YY') ELSE to_char(ps, 'YYYY') || '-Q' || to_char(ps, 'Q') END,
           metrics.value(p_metric, ps, pe)
    FROM e ORDER BY ps
$$;

-- Показатели по месяцам в форме модулей (metric_id, period, value, unit, status).
CREATE OR REPLACE FUNCTION metrics.monthly(p_metric text, p_months int DEFAULT 18, p_entity text DEFAULT NULL)
RETURNS TABLE (metric_id text, period text, value numeric, unit text, status text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH m AS (
        SELECT (date_trunc('month', metrics.as_of()) - make_interval(months => k))::date AS ms
        FROM generate_series(0, p_months - 1) k
    ), b AS (
        SELECT ms, least(metrics.as_of(), (ms + interval '1 month')::date - 1) AS me,
               (ms - interval '1 month')::date AS ps,
               least((least(metrics.as_of(), (ms + interval '1 month')::date - 1) - interval '1 month')::date, ms - 1) AS pe
        FROM m
    )
    SELECT CASE WHEN p_entity IS NULL THEN p_metric ELSE p_metric || ':' || p_entity END,
           to_char(ms, 'YYYY-MM'), v.cur, d.unit, metrics.status(p_metric, v.cur, v.prev)
    FROM b
    JOIN metrics.definitions d ON d.metric_id = p_metric
    CROSS JOIN LATERAL (SELECT metrics.value(p_metric, ms, me, p_entity) AS cur,
                               metrics.value(p_metric, ps, pe, p_entity) AS prev) v
    WHERE v.cur IS NOT NULL
$$;

CREATE OR REPLACE VIEW metrics.m_revenue AS SELECT * FROM metrics.monthly('revenue');
-- Семейство gross_margin: компания ('all') и юрлица.
CREATE OR REPLACE VIEW metrics.m_gross_margin AS
    SELECT 'gross_margin:all'::text AS metric_id, period, value, unit, status FROM metrics.monthly('gross_margin')
    UNION ALL SELECT * FROM metrics.monthly('gross_margin', 18, 'airl')
    UNION ALL SELECT * FROM metrics.monthly('gross_margin', 18, 'airl_dev');
CREATE OR REPLACE VIEW metrics.m_net_profit AS
    SELECT 'net_profit:all'::text AS metric_id, period, value, unit, status FROM metrics.monthly('net_profit');
CREATE OR REPLACE VIEW metrics.m_cash_balance AS SELECT * FROM metrics.monthly('cash_balance');
CREATE OR REPLACE VIEW metrics.m_receivables_overdue AS SELECT * FROM metrics.monthly('receivables_overdue');
CREATE OR REPLACE VIEW metrics.m_lead AS SELECT * FROM metrics.monthly('lead');
CREATE OR REPLACE VIEW metrics.m_conversion_lead_to_deal AS SELECT * FROM metrics.monthly('conversion_lead_to_deal');
CREATE OR REPLACE VIEW metrics.m_avg_check AS SELECT * FROM metrics.monthly('avg_check');
CREATE OR REPLACE VIEW metrics.m_enrollments AS SELECT * FROM metrics.monthly('enrollments');
CREATE OR REPLACE VIEW metrics.m_cohort_fill_rate AS SELECT * FROM metrics.monthly('cohort_fill_rate');
CREATE OR REPLACE VIEW metrics.m_course_completion_rate AS SELECT * FROM metrics.monthly('course_completion_rate');
CREATE OR REPLACE VIEW metrics.m_headcount AS SELECT * FROM metrics.monthly('headcount');

-- Дневная выручка по направлениям — вход модуля plan-fact (src_pf_facts) и графиков.
CREATE OR REPLACE VIEW metrics.revenue_daily AS
SELECT doc_date AS day, service_line, sum(amount_net) AS value
FROM core.sales_docs WHERE NOT is_intragroup AND currency = 'KZT'
GROUP BY doc_date, service_line;

CREATE OR REPLACE VIEW metrics.enrollments_daily AS
SELECT doc_date AS day, sum(qty) AS value
FROM core.sales_docs WHERE service_line = 'Курс VibeOps' AND NOT is_intragroup
GROUP BY doc_date;

CREATE OR REPLACE VIEW metrics.lead_daily AS
SELECT created_date AS day, count(*)::numeric AS value
FROM core.leads WHERE NOT is_duplicate GROUP BY created_date;

-- Детализация cohort_fill_rate (карта: «metrics.<id>_detail»): потоки и проданные места.
CREATE OR REPLACE VIEW metrics.cohort_fill_rate_detail AS
SELECT c.cohort_code, c.course, c.format, c.start_date, c.end_date, c.capacity, c.curator,
       COALESCE((SELECT sum(s.qty) FROM core.sales_docs s WHERE s.cohort_code = c.cohort_code AND NOT s.is_intragroup), 0) AS seats_sold,
       round(100 * COALESCE((SELECT sum(s.qty) FROM core.sales_docs s WHERE s.cohort_code = c.cohort_code AND NOT s.is_intragroup), 0) / c.capacity, 1) AS fill_pct
FROM core.cohorts c;

-- Управленческий ОПиУ компании за период: строки по статьям 1С, без внутригрупповых.
CREATE OR REPLACE FUNCTION metrics.pnl(p_from date, p_to date)
RETURNS TABLE (ord int, line_code text, title text, kind text, amount numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH r AS (SELECT metrics.revenue(p_from, p_to) AS rev),
    e AS (
        SELECT article, sum(amount_net) AS amt FROM core.expenses
        WHERE doc_date BETWEEN p_from AND p_to AND NOT is_intragroup GROUP BY article
    ),
    g AS (SELECT COALESCE(sum(amt) FILTER (WHERE article = ANY (metrics.direct_articles())), 0) AS direct,
                 COALESCE(sum(amt) FILTER (WHERE article NOT IN ('Подрядчики', 'Облако и API ИИ', 'Налог на прибыль')), 0) AS opex,
                 COALESCE(sum(amt) FILTER (WHERE article = 'Налог на прибыль'), 0) AS tax
          FROM e)
    SELECT 10, 'revenue', 'Выручка', 'total', r.rev FROM r
    UNION ALL SELECT 20, 'direct:' || article, article, 'expense', -amt FROM e WHERE article = ANY (metrics.direct_articles())
    UNION ALL SELECT 30, 'gross_profit', 'Валовая прибыль', 'margin', r.rev - g.direct FROM r, g
    UNION ALL SELECT 40, 'opex:' || article, article, 'expense', -amt FROM e
              WHERE article NOT IN ('Подрядчики', 'Облако и API ИИ', 'Налог на прибыль')
    UNION ALL SELECT 50, 'ebitda', 'Операционная прибыль', 'margin', r.rev - g.direct - g.opex FROM r, g
    UNION ALL SELECT 60, 'tax', 'Налог на прибыль', 'expense', -g.tax FROM g
    UNION ALL SELECT 70, 'net_profit', 'Чистая прибыль', 'net', r.rev - g.direct - g.opex - g.tax FROM r, g
    ORDER BY 1, 2
$$;

-- Старение дебиторки на конец дня p_at (по дням просрочки), без внутригрупповых.
CREATE OR REPLACE FUNCTION metrics.receivables_aging(p_at date DEFAULT NULL)
RETURNS TABLE (bucket text, ord int, amount numeric, docs bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH a AS (SELECT COALESCE(p_at, metrics.as_of()) AS at),
    d AS (
        SELECT metrics.doc_balance(s.doc_id, s.amount_gross, a.at) AS bal, a.at - s.due_date AS days
        FROM core.sales_docs s, a
        WHERE NOT s.is_intragroup AND s.doc_date <= a.at AND s.due_date IS NOT NULL
    ),
    b AS (
        SELECT CASE WHEN days < 0 THEN 'Срок не наступил' WHEN days <= 30 THEN '1–30 дней'
                    WHEN days <= 60 THEN '31–60 дней' WHEN days <= 90 THEN '61–90 дней' ELSE 'больше 90 дней' END AS bucket,
               CASE WHEN days < 0 THEN 0 WHEN days <= 30 THEN 1 WHEN days <= 60 THEN 2 WHEN days <= 90 THEN 3 ELSE 4 END AS ord,
               bal
        FROM d WHERE bal > 0
    )
    SELECT bucket, ord, sum(bal), count(*) FROM b GROUP BY bucket, ord ORDER BY ord
$$;

-- Воронка заявок за период (без дублей): все → в работе/закрыты → оплата; по каналам.
CREATE OR REPLACE FUNCTION metrics.lead_funnel(p_from date, p_to date)
RETURNS TABLE (channel text, leads bigint, open bigint, lost bigint, won bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT channel, count(*), count(*) FILTER (WHERE stage = 'open'),
           count(*) FILTER (WHERE stage = 'lost'), count(*) FILTER (WHERE stage = 'won')
    FROM core.leads WHERE created_date BETWEEN p_from AND p_to AND NOT is_duplicate
    GROUP BY channel ORDER BY count(*) DESC
$$;

-- Прогноз выручки на конец месяца — ОЦЕНКА по темпу: факт / прошедшие дни × дни месяца.
CREATE OR REPLACE FUNCTION metrics.revenue_forecast(p_at date DEFAULT NULL,
    OUT month text, OUT fact numeric, OUT days_passed int, OUT days_total int, OUT forecast numeric,
    OUT last_year numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    WITH a AS (SELECT COALESCE(p_at, metrics.as_of()) AS at)
    SELECT to_char(a.at, 'YYYY-MM'),
           metrics.revenue(date_trunc('month', a.at)::date, a.at),
           extract(day FROM a.at)::int,
           extract(day FROM (date_trunc('month', a.at) + interval '1 month - 1 day'))::int,
           round(metrics.revenue(date_trunc('month', a.at)::date, a.at) / extract(day FROM a.at)
                 * extract(day FROM (date_trunc('month', a.at) + interval '1 month - 1 day')), -3),
           metrics.revenue((date_trunc('month', a.at) - interval '12 months')::date,
                           (date_trunc('month', a.at) - interval '11 months')::date - 1)
    FROM a
$$;
