-- Демо-источник для модуля «Клиенты под риском»: продажи B2B-клиентам за ~8 месяцев.
-- Синтетика, только для разработки и показа. В работе src_churn_sales заменяет адаптер
-- /airl-dwh (1С: реализации, core.sales) или /airl-connect (CRM).

CREATE TABLE IF NOT EXISTS demo_churn_sales (
    sale_id       text PRIMARY KEY,
    client_id     text NOT NULL,
    client_name   text NOT NULL,
    point_id      text,
    sale_date     date NOT NULL,
    amount        numeric(18,2) NOT NULL,
    gross_profit  numeric(18,2),
    manager_id    text,
    branch_id     text,
    is_aggregator boolean NOT NULL DEFAULT false
);

-- Профиль клиента: base — обычная закупка за раз; every — раз в сколько недель покупает;
-- first_w / last_w — первая и последняя покупка (недель назад); recent — множитель
-- последних 4 недель (0.4 — закупки упали). Даты считаются от дня первой загрузки.
INSERT INTO demo_churn_sales
SELECT p.client_id || '-' || w, p.client_id, p.client_name,
       CASE WHEN p.points > 1 THEN p.client_id || '-P' || (w % p.points + 1) END,
       current_date - (w * 7 + 2),
       round(p.base * CASE WHEN w < 4 THEN p.recent ELSE 1 END * (0.9 + ((w * 7 + length(p.client_name)) % 10) / 50.0), -2),
       CASE WHEN p.aggr THEN NULL
            ELSE round(0.32 * p.base * CASE WHEN w < 4 THEN p.recent ELSE 1 END * (0.9 + ((w * 7 + length(p.client_name)) % 10) / 50.0), -2) END,
       p.manager_id, p.branch_id, p.aggr
FROM (VALUES
 ('CH-001', 'Кофейня «Зерно», Алматы',            'm_aidana', 'ala', 1, 180000, 1, 34, 0,  1.00, false),
 ('CH-002', 'Сеть кофеен «Daily Cup»',            'm_aidana', 'ala', 3, 650000, 1, 34, 0,  1.05, false),
 ('CH-003', 'Ресторан «Тюбетей», Алматы',         'm_ruslan', 'ala', 1, 120000, 1, 34, 0,  0.45, false),
 ('CH-004', 'Отель «Достар», Астана',             'm_dana',   'ast', 1, 300000, 2, 34, 0,  1.00, false),
 ('CH-005', 'Кофейня «Бариста-бар», Астана',      'm_dana',   'ast', 1, 90000,  1, 34, 0,  0.50, false),
 ('CH-006', 'ТОО «Офис-Сервис» (кофе в офисы)',   'm_timur',  'ala', 1, 150000, 2, 34, 0,  1.10, false),
 ('CH-007', 'Пекарня «Бауырсак»',                 'm_ruslan', 'ala', 1, 60000,  1, 34, 7,  1.00, false),
 ('CH-008', 'Кофейня «Утро», Астана',             'm_timur',  'ast', 1, 70000,  1, 30, 6,  1.00, false),
 ('CH-009', 'Кейтеринг «Той-Той»',                'm_ruslan', 'ala', 1, 200000, 2, 34, 0,  0.30, false),
 ('CH-010', 'Кофейня «Lounge 24», Астана',        'm_dana',   'ast', 1, 80000,  1, 34, 18, 1.00, false),
 ('CH-011', 'Кофейня «Арома», Алматы',            'm_aidana', 'ala', 1, 110000, 1, 34, 15, 1.00, false),
 ('CH-012', 'Кофейня «Новая волна», Алматы',      'm_aidana', 'ala', 1, 95000,  1, 3,  0,  1.00, false),
 ('CH-013', 'Коворкинг «Hub», Астана',            'm_timur',  'ast', 1, 50000,  1, 6,  0,  1.00, false),
 ('CH-014', 'Kaspi Магазин',                      'm_aidana', 'ala', 1, 900000, 1, 34, 0,  0.40, true),
 ('CH-015', 'Летняя веранда «Кок-Тобе»',          'm_ruslan', 'ala', 1, 130000, 1, 26, 10, 1.00, false),
 ('CH-016', 'Кофейня «Бар 7», Алматы',            'm_ruslan', 'ala', 1, 75000,  1, 34, 0,  0.90, false),
 ('CH-017', 'Ресторан «Сарай», Астана',           'm_dana',   'ast', 1, 140000, 1, 34, 0,  1.00, false),
 ('CH-018', 'ТОО «Казтех» (офис)',                'm_timur',  'ast', 1, 40000,  4, 32, 0,  1.00, false)
) AS p(client_id, client_name, manager_id, branch_id, points, base, every, first_w, last_w, recent, aggr)
CROSS JOIN generate_series(0, 34) AS w
WHERE w BETWEEN p.last_w AND p.first_w
  AND (w - p.last_w) % p.every = 0
ON CONFLICT (sale_id) DO NOTHING;

CREATE OR REPLACE VIEW src_churn_sales AS
SELECT client_id, client_name, point_id, sale_date, amount, gross_profit, manager_id, branch_id, is_aggregator
FROM demo_churn_sales;
