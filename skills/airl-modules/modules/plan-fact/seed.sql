-- Синтетические показатели и планы для разработки и показа.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('plan-fact', 'facts_lag_days',   '1',                 'demo'),
 ('plan-fact', 'work_weekdays',    '[1,2,3,4,5,6,7]',   'demo'),
 ('plan-fact', 'warn_below_pct',   '95',                'demo'),
 ('plan-fact', 'bad_below_pct',    '85',                'demo'),
 ('plan-fact', 'warn_above_pct',   '105',               'demo'),
 ('plan-fact', 'bad_above_pct',    '115',               'demo'),
 ('plan-fact', 'signal_from_day',  '7',                 'demo'),
 ('plan-fact', 'signal_recipient', '"role:director"',   'demo'),
 ('plan-fact', 'channel',          '"telegram"',        'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO pf_metric_defs (metric_id, title, unit, aggregation, higher_is_better, created_by) VALUES
 ('revenue',        'Выручка',           'KZT',      'sum',  true, 'demo'),
 ('gross_profit',   'Валовая прибыль',   'KZT',      'sum',  true, 'demo'),
 ('volume_kg',      'Отгрузка кофе',     'кг',       'sum',  true, 'demo'),
 ('active_clients', 'Активные клиенты',  'клиентов', 'last', true, 'demo')
ON CONFLICT (metric_id) DO NOTHING;

-- Планы на 3 прошлых месяца, текущий и следующий. Плановая выручка = обычная выручка
-- с учётом сезона и роста, округлённая до 100 000 тг.
WITH months AS (
    SELECT g.k,
           (date_trunc('month', current_date) - make_interval(months => g.k))::date AS month,
           (1 + 0.10 * cos(2 * pi() * (extract(month FROM date_trunc('month', current_date) - make_interval(months => g.k)) - 1) / 12))::numeric
             * power(1.15, -g.k / 12.0) AS factor
    FROM generate_series(-1, 3) AS g(k)
),
rev AS (
    SELECT m.month, d.dim_type, d.dim_value, round(d.base * m.factor, -5) AS plan_rev
    FROM months m
    CROSS JOIN (VALUES ('branch', 'ala', 42000000), ('branch', 'ast', 28000000),
                       ('manager', 'm_aidana', 23000000), ('manager', 'm_ruslan', 19000000),
                       ('manager', 'm_dana', 16800000), ('manager', 'm_timur', 11200000),
                       ('category', 'beans', 49000000), ('category', 'drip', 8400000),
                       ('category', 'tea', 5600000), ('category', 'equipment', 7000000))
               AS d(dim_type, dim_value, base)
),
plans AS (
    SELECT 'revenue' AS metric_id, month, dim_type, dim_value, plan_rev AS plan_value FROM rev
    UNION ALL
    SELECT 'revenue', month, 'company', 'all', sum(plan_rev) FROM rev WHERE dim_type = 'branch' GROUP BY month
    UNION ALL
    SELECT 'gross_profit', month, dim_type, dim_value, round(plan_rev * 0.34, -4) FROM rev WHERE dim_type = 'branch'
    UNION ALL
    SELECT 'gross_profit', month, 'company', 'all', sum(round(plan_rev * 0.34, -4)) FROM rev WHERE dim_type = 'branch' GROUP BY month
    UNION ALL
    SELECT 'volume_kg', month, 'company', 'all', round(sum(plan_rev) / 9500, -2) FROM rev WHERE dim_type = 'branch' GROUP BY month
    UNION ALL
    SELECT 'active_clients', m.month, 'branch', b.branch, b.n FROM months m, (VALUES ('ala', 88), ('ast', 64)) AS b(branch, n)
    UNION ALL
    SELECT 'active_clients', m.month, 'company', 'all', 152 FROM months m
)
INSERT INTO pf_plans (metric_id, period, dimension_type, dimension_value, plan_value, comment, created_at, created_by)
SELECT p.metric_id, p.month, p.dim_type, p.dim_value, p.plan_value, 'План утверждён на планёрке',
       (p.month - interval '5 days')::timestamptz, 'u_director'
FROM plans p
WHERE NOT EXISTS (SELECT 1 FROM pf_plans x
                  WHERE x.metric_id = p.metric_id AND x.period = p.month
                    AND x.dimension_type = p.dim_type AND x.dimension_value = p.dim_value);

-- Прежняя версия плана выручки текущего месяца (план снизили в середине месяца).
INSERT INTO pf_plans (metric_id, period, dimension_type, dimension_value, plan_value, status, comment, created_at, created_by)
SELECT 'revenue', date_trunc('month', current_date)::date, 'company', 'all',
       a.plan_value + 5000000, 'superseded', 'Первоначальный план, до закрытия точки клиента', a.created_at - interval '1 day', 'u_director'
FROM pf_plans a
WHERE a.metric_id = 'revenue' AND a.period = date_trunc('month', current_date)::date
  AND a.dimension_type = 'company' AND a.status = 'active'
  AND NOT EXISTS (SELECT 1 FROM pf_plans x
                  WHERE x.metric_id = 'revenue' AND x.period = date_trunc('month', current_date)::date
                    AND x.dimension_type = 'company' AND x.status = 'superseded');
