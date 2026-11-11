-- Демо-источники для модуля «Лиды»: сделки из CRM/1С и расходы на рекламу. Синтетика,
-- только для разработки и показа. В работе src_lead_deals пишет адаптер /airl-dwh или
-- /airl-connect поверх CRM или 1С, src_lead_ad_costs — коннектор рекламных кабинетов
-- (Meta, Google, Яндекс) или выгрузка CSV. Сами лиды модуль принимает сам (lead_capture).
--
-- Телефоны синтетические и совпадают с формулой в seed.sql: лид i — +7 70 и 8 цифр.

CREATE TABLE IF NOT EXISTS demo_lead_deals (
    deal_id       text PRIMARY KEY,
    lead_ref      text,
    phone         text,
    amount        numeric(18,2) NOT NULL,
    currency      char(3)       NOT NULL,
    won_at        timestamptz   NOT NULL,
    source_system text          NOT NULL
);

-- Каждый 6-й лид купил: B2B (кампании для HoReCa) — крупный заказ, розница — небольшой.
INSERT INTO demo_lead_deals
SELECT 'D-' || lpad(i::text, 5, '0'), NULL,
       '8 (70' || substr(lpad((10000000 + (i * 7919) % 89999999)::text, 8, '0'), 1, 1) || ') '
              || substr(lpad((10000000 + (i * 7919) % 89999999)::text, 8, '0'), 2),
       CASE WHEN i % 10 IN (2, 3) THEN 450000 + (i * 37 % 8) * 95000 ELSE 15000 + (i * 53 % 6) * 6500 END,
       'KZT',
       date_trunc('hour', now()) - make_interval(days => 120 - i / 3) + interval '4 days',
       CASE WHEN i % 10 IN (2, 3) THEN 'crm' ELSE '1c' END
FROM generate_series(1, 360) i
WHERE i % 6 = 0 AND 120 - i / 3 >= 5
ON CONFLICT (deal_id) DO NOTHING;

-- Покупка без лида (пришёл в кофейню сам) — не должна приписаться никакой кампании.
INSERT INTO demo_lead_deals VALUES
 ('D-90001', NULL, '+7 777 000 00 01', 85000.00, 'KZT', now() - interval '10 days', '1c'),
 ('D-90002', NULL, '+7 777 000 00 02', 32000.00, 'KZT', now() - interval '3 days',  '1c')
ON CONFLICT (deal_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_lead_ad_costs (
    day      date          NOT NULL,
    channel  text          NOT NULL,
    campaign text          NOT NULL,
    cost     numeric(18,2) NOT NULL,
    currency char(3)       NOT NULL,
    PRIMARY KEY (day, channel, campaign)
);

INSERT INTO demo_lead_ad_costs
SELECT d::date, c.channel, c.campaign,
       round(c.daily * (1 + 0.2 * ((abs(hashtext(c.campaign || d::date)) % 100) - 50) / 50.0), 2), 'KZT'
FROM generate_series(current_date - 120, current_date - 1, interval '1 day') d
CROSS JOIN (VALUES ('meta',   'ig_autumn_blend',      25000),
                   ('meta',   'ig_horeca_b2b',        15000),
                   ('google', 'google_search_coffee', 20000),
                   ('meta',   'fb_office_coffee',     10000),
                   ('yandex', 'ya_test_campaign',      5000)) AS c(channel, campaign, daily)
ON CONFLICT (day, channel, campaign) DO NOTHING;

CREATE OR REPLACE VIEW src_lead_deals AS
SELECT deal_id, lead_ref, phone, amount, currency, won_at, source_system
FROM demo_lead_deals;

CREATE OR REPLACE VIEW src_lead_ad_costs AS
SELECT day, channel, campaign, cost, currency
FROM demo_lead_ad_costs;
