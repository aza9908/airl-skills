-- Демо-источник для модуля «План-факт»: факты по месяцам за ~16 месяцев.
-- Синтетика, только для разработки и показа. В работе src_pf_facts пишет адаптер
-- /airl-dwh поверх представлений показателей хаба (metrics.m_revenue и т. п.) или 1С.

CREATE TABLE IF NOT EXISTS demo_pf_facts (
    metric_id       text    NOT NULL,
    period          date    NOT NULL,
    dimension_type  text    NOT NULL,
    dimension_value text    NOT NULL,
    value           numeric NOT NULL,
    PRIMARY KEY (metric_id, period, dimension_type, dimension_value)
);

-- base — обычная выручка в месяц, тг. Текущий месяц — только прошедшие дни (факт на сегодня).
-- Сезонность: зимой кофе берут больше. Рост — 15% в год. Тимур и категория «оборудование»
-- в текущем месяце отстают, чтобы были жёлтые и красные строки.
INSERT INTO demo_pf_facts (metric_id, period, dimension_type, dimension_value, value)
SELECT m.metric_id, x.month, d.dim_type, d.dim_value,
       round((d.base * m.k * x.season::numeric * x.growth * x.part
             * CASE WHEN x.k <= 1 THEN d.lag_factor ELSE 1 END
             * (0.95 + ((x.k * 7 + length(d.dim_value) * 3 + length(m.metric_id)) % 11) / 100.0))::numeric, m.digits)
FROM (VALUES
    ('branch',   'ala',          42000000, 1.00),
    ('branch',   'ast',          28000000, 0.97),
    ('manager',  'm_aidana',     23000000, 1.03),
    ('manager',  'm_ruslan',     19000000, 0.98),
    ('manager',  'm_dana',       16800000, 1.02),
    ('manager',  'm_timur',      11200000, 0.72),
    ('category', 'beans',        49000000, 1.02),
    ('category', 'drip',          8400000, 1.05),
    ('category', 'tea',           5600000, 0.96),
    ('category', 'equipment',     7000000, 0.55)
) AS d(dim_type, dim_value, base, lag_factor)
CROSS JOIN (VALUES
    ('revenue',      1.0,        0),
    ('gross_profit', 0.34,       0),
    ('volume_kg',    1 / 9500.0, 0)
) AS m(metric_id, k, digits)
CROSS JOIN LATERAL (
    SELECT g.k,
           (date_trunc('month', current_date) - make_interval(months => g.k))::date AS month,
           1 + 0.10 * cos(2 * pi() * (extract(month FROM date_trunc('month', current_date) - make_interval(months => g.k)) - 1) / 12) AS season,
           power(1.15, -g.k / 12.0) AS growth,
           CASE WHEN g.k = 0
                THEN greatest(current_date - date_trunc('month', current_date)::date, 0)::numeric
                     / extract(day FROM date_trunc('month', current_date) + interval '1 month' - interval '1 day')
                ELSE 1 END AS part
    FROM generate_series(0, 15) AS g(k)
) x
WHERE NOT (m.metric_id <> 'revenue' AND d.dim_type = 'category')
ON CONFLICT DO NOTHING;

-- Активные клиенты: показатель «на дату», не складывается по дням (aggregation = last).
INSERT INTO demo_pf_facts (metric_id, period, dimension_type, dimension_value, value)
SELECT 'active_clients', (date_trunc('month', current_date) - make_interval(months => g.k))::date,
       'branch', b.branch, b.n - g.k + (g.k % 3)
FROM (VALUES ('ala', 86), ('ast', 61)) AS b(branch, n)
CROSS JOIN generate_series(0, 15) AS g(k)
ON CONFLICT DO NOTHING;

-- Вход модуля. Уровень «компания» = сумма филиалов (так обычно делает и адаптер).
CREATE OR REPLACE VIEW src_pf_facts AS
SELECT metric_id, period, dimension_type, dimension_value, value
FROM demo_pf_facts
UNION ALL
SELECT metric_id, period, 'company'::text, 'all'::text, sum(value)
FROM demo_pf_facts
WHERE dimension_type = 'branch'
GROUP BY metric_id, period;
