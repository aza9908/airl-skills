-- Демо-источники: подтверждённые заказы на доставку и водители синтетической кофейной
-- компании в Алматы. Только для разработки и показа. В работе src_dlv_* заменяет адаптер
-- /airl-dwh или /airl-connect (заказы и оплаты из 1С, водители — из кадров или справочника).

CREATE TABLE IF NOT EXISTS demo_dlv_drivers (
    driver_id   text PRIMARY KEY,
    driver_name text          NOT NULL,
    phone       text,
    vehicle     text,
    capacity_kg numeric(10,1),
    capacity_m3 numeric(10,2),
    day_cost    numeric(18,2),
    cost_per_km numeric(18,2),
    currency    char(3),
    active      boolean       NOT NULL
);

INSERT INTO demo_dlv_drivers VALUES
 ('DRV-01', 'Ерлан С.',  '+77011230001', 'Hyundai Porter · 512 ABK 02', 1000, 6.0, 18000, 110, 'KZT', true),
 ('DRV-02', 'Арман К.',  '+77011230002', 'Lada Largus · 274 AXM 02',     600, 2.5, 15000,  85, 'KZT', true),
 ('DRV-03', 'Азамат Т.', '+77011230003', 'Isuzu NPR · 903 BCE 02',      3000, 16.0, 26000, 160, 'KZT', false)
ON CONFLICT (driver_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_dlv_orders (
    order_id       text PRIMARY KEY,
    order_no       text          NOT NULL,
    client_id      text          NOT NULL,
    client_name    text          NOT NULL,
    contact_name   text,
    contact_phone  text,
    address        text          NOT NULL,
    city           text          NOT NULL,
    lat            numeric(9,6),
    lon            numeric(9,6),
    window_from    timestamptz   NOT NULL,
    window_to      timestamptz   NOT NULL,
    weight_kg      numeric(10,1),
    volume_m3      numeric(10,2),
    amount         numeric(18,2) NOT NULL,
    currency       char(3)       NOT NULL,
    payment_status text          NOT NULL,
    confirmed_at   timestamptz   NOT NULL,
    status         text          NOT NULL
);

-- 7 заказов в день (кроме воскресенья) за 3 недели назад и на завтра.
INSERT INTO demo_dlv_orders
SELECT 'SO-' || to_char(d, 'YYMMDD') || '-' || k,
       'ЗК-' || to_char(d, 'MMDD') || k,
       c.client_id, c.client_name, c.contact_name,
       '+7701555' || lpad((c.n * 37 % 10000)::text, 4, '0'),
       c.address, 'Алматы', c.lat, c.lon,
       (d::date + time '09:00' + make_interval(hours => (k % 4) * 2)) AT TIME ZONE 'Asia/Almaty',
       (d::date + time '12:00' + make_interval(hours => (k % 4) * 2)) AT TIME ZONE 'Asia/Almaty',
       5 + (abs(hashtext(d::text || k)) % 36),
       round((0.05 + (abs(hashtext(d::text || k)) % 30) / 100.0)::numeric, 2),
       25000 + (abs(hashtext('a' || d::text || k)) % 30) * 5000,
       'KZT',
       (ARRAY['paid', 'paid', 'unpaid', 'cod', 'paid', 'partial', 'paid'])[1 + k],
       (d::date - 1 + time '16:00') AT TIME ZONE 'Asia/Almaty',
       CASE WHEN abs(hashtext('x' || d::text || k)) % 25 = 0 THEN 'cancelled' ELSE 'confirmed' END
FROM generate_series(current_date - 21, current_date + 1, interval '1 day') AS d
CROSS JOIN generate_series(0, 6) AS k
JOIN (VALUES
  (1,  'CL-001', 'Кофейня «Достык»',          'Айгуль',  'пр. Достык, 97',            43.233500, 76.956800),
  (2,  'CL-002', 'Ресторан «Самал»',          'Бекзат',  'мкр. Самал-2, 58',          43.232400, 76.949000),
  (3,  'CL-003', 'Кофейня «Абай 44»',         'Динара',  'ул. Абая, 44',              43.240500, 76.928300),
  (4,  'CL-004', 'Офис «Нурлы Тау»',          'Руслан',  'пр. Аль-Фараби, 17',        43.218100, 76.927800),
  (5,  'CL-005', 'Отель «Медеу»',             'Салтанат','ул. Толе би, 155',          43.252100, 76.886200),
  (6,  'CL-006', 'Кофейня «Жибек Жолы»',      'Тимур',   'ул. Жибек Жолы, 115',       43.261400, 76.945600),
  (7,  'CL-007', 'Пекарня «Райымбек»',        'Мадина',  'пр. Райымбека, 212',        43.270900, 76.881000),
  (8,  'CL-008', 'Кофейня «Сатпаева»',        'Ержан',   'ул. Сатпаева, 30А',         43.235800, 76.915600),
  (9,  'CL-009', 'Бизнес-центр «Розыбакиева»','Асель',   'ул. Розыбакиева, 247',      43.209300, 76.892500),
  (10, 'CL-010', 'Кофейня «Орбита»',          'Нурлан',  'мкр. Орбита-1, 15',         43.192600, 76.866500),
  (11, 'CL-011', 'Ресторан «Кабанбай»',       'Жанна',   'ул. Кабанбай батыра, 83',   43.246800, 76.945400),
  (12, 'CL-012', 'Кофейня «Тузусай»',         'Олжас',   'пос. Тузусай, ул. Новая, 5', NULL,     NULL)
) AS c(n, client_id, client_name, contact_name, address, lat, lon)
  ON c.n = 1 + ((d::date - current_date + 30) * 3 + k) % 12
WHERE extract(isodow FROM d) <> 7
ON CONFLICT (order_id) DO NOTHING;

CREATE OR REPLACE VIEW src_dlv_drivers AS
SELECT driver_id, driver_name, phone, vehicle, capacity_kg, capacity_m3, day_cost, cost_per_km, currency, active
FROM demo_dlv_drivers;

CREATE OR REPLACE VIEW src_dlv_orders AS
SELECT order_id, order_no, client_id, client_name, contact_name, contact_phone, address, city, lat, lon,
       window_from, window_to, weight_kg, volume_m3, amount, currency, payment_status, confirmed_at, status
FROM demo_dlv_orders;
