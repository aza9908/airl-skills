-- Настройка модуля plan-fact отдела «Продажи» (mart_sales). Значения СИНТЕТИЧЕСКИЕ:
-- «руководитель продаж» утвердил план = тот же месяц прошлого года × 1,3 (заявки × 1,25).
-- Повторный запуск безопасен.
SET search_path TO mart_sales;

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('kit',       'currency',         '"KZT"',              'setup'),
 ('plan-fact', 'facts_lag_days',   '1',                  'setup'),
 ('plan-fact', 'work_weekdays',    '[1,2,3,4,5,6,7]',    'setup'),
 ('plan-fact', 'warn_below_pct',   '95',                 'setup'),
 ('plan-fact', 'bad_below_pct',    '85',                 'setup'),
 ('plan-fact', 'warn_above_pct',   '105',                'setup'),
 ('plan-fact', 'bad_above_pct',    '115',                'setup'),
 ('plan-fact', 'signal_from_day',  '7',                  'setup'),
 ('plan-fact', 'signal_recipient', '"role:head_sales"',  'setup'),
 ('plan-fact', 'channel',          '"in_app"',           'setup')
ON CONFLICT (module, key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by;

INSERT INTO pf_metric_defs (metric_id, title, unit, aggregation, higher_is_better, created_by) VALUES
 ('revenue',     'Выручка',        'KZT', 'sum', true, 'setup'),
 ('enrollments', 'Записи на курс', 'чел', 'sum', true, 'setup'),
 ('lead',        'Заявки',         'шт',  'sum', true, 'setup')
ON CONFLICT (metric_id) DO NOTHING;

WITH months AS (
    SELECT (date_trunc('month', current_date) - make_interval(months => k))::date AS month
    FROM generate_series(-1, 5) k
),
ly AS (
    SELECT m.month, f.metric_id, f.dimension_type, f.dimension_value, sum(f.value) AS v
    FROM months m
    JOIN src_pf_facts f ON f.period >= (m.month - interval '12 months')::date
                       AND f.period <  (m.month - interval '11 months')::date
    GROUP BY 1, 2, 3, 4
)
INSERT INTO pf_plans (metric_id, period, dimension_type, dimension_value, plan_value, comment, created_at, created_by)
SELECT metric_id, month, dimension_type, dimension_value,
       CASE metric_id WHEN 'revenue' THEN round(v * 1.30, -5)
                      WHEN 'lead' THEN round(v * 1.25, 0)
                      ELSE round(v * 1.20, 0) END,
       'План утверждён руководителем продаж (демо)', (month - interval '5 days')::timestamptz, 'setup'
FROM ly
WHERE NOT EXISTS (SELECT 1 FROM pf_plans x
                  WHERE x.metric_id = ly.metric_id AND x.period = ly.month
                    AND x.dimension_type = ly.dimension_type AND x.dimension_value = ly.dimension_value);
