-- Демо-источники для модуля «Прогноз спроса»: продажи по дням за ~14 месяцев, акции и
-- остатки сырья. Синтетика, только для разработки и показа. В работе src_fc_sales_daily
-- пишет адаптер /airl-dwh поверх реализации 1С (или чеков касс), src_fc_events — маркетинг
-- (календарь акций), src_fc_material_stock — остатки и заказы сырья из 1С.
--
-- Ряды разные нарочно: розница с недельным ритмом, B2B с редкими крупными заказами,
-- сезонный сорт, растущий продукт с прошедшей акцией и новинка с 6 неделями истории.

CREATE TABLE IF NOT EXISTS demo_fc_sales (
    sku         text          NOT NULL,
    location_id text          NOT NULL,
    day         date          NOT NULL,
    qty         numeric(18,3) NOT NULL,
    PRIMARY KEY (sku, location_id, day)
);

INSERT INTO demo_fc_sales
SELECT s.sku, s.location_id, d::date,
       CASE WHEN s.kind = 'b2b' THEN
                CASE WHEN abs(hashtext(s.sku || s.location_id || d::date)) % 7 IN (0, 3)
                     THEN round(s.base * (1 + s.trend * (d::date - (current_date - 420)) / 365.0)
                                * (1 + 0.4 * ((abs(hashtext(d::date || s.sku)) % 200) - 100) / 100.0))
                     ELSE 0 END
            ELSE greatest(0, round(
                 s.base
                 * (ARRAY[0.80, 0.85, 0.90, 1.00, 1.25, 1.45, 0.75])[extract(isodow FROM d)::int]
                 * (1 + s.trend * (d::date - (current_date - 420)) / 365.0)
                 * (1 + s.seas * cos(2 * pi() * (extract(doy FROM d) - 15) / 365.0))::numeric
                 * (1 + s.noise * ((abs(hashtext(s.sku || s.location_id || d::date)) % 200) - 100) / 100.0)
                 * CASE WHEN s.sku = 'DRIP-10' AND d::date BETWEEN current_date - 60 AND current_date - 47 THEN 1.5 ELSE 1 END))
       END
FROM (VALUES
 ('ETH-SID-250',   'ala', 14, 'retail', 0.10, 0.10, 0.30, 420),
 ('ETH-SID-250',   'ast',  8, 'retail', 0.15, 0.10, 0.35, 420),
 ('BRA-CER-1KG',   'ala', 30, 'b2b',    0.30, 0.00, 0.00, 420),
 ('COL-HUI-250',   'ala',  6, 'retail', 0.00, 0.35, 0.30, 420),
 ('ESP-BLEND-1KG', 'ala', 12, 'retail', 0.20, 0.05, 0.25, 420),
 ('ESP-BLEND-1KG', 'ast',  6, 'retail', 0.20, 0.05, 0.40, 420),
 ('DRIP-10',       'ala', 10, 'retail', 0.50, 0.00, 0.30, 300),
 ('KEN-AA-250',    'ala',  5, 'retail', 0.00, 0.00, 0.30, 42)
) AS s(sku, location_id, base, kind, trend, seas, noise, days)
CROSS JOIN generate_series(current_date - s.days, current_date - 1, interval '1 day') d
ON CONFLICT (sku, location_id, day) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_fc_events (
    event_id    text PRIMARY KEY,
    sku         text,
    location_id text,
    date_from   date    NOT NULL,
    date_to     date    NOT NULL,
    kind        text    NOT NULL,
    uplift_pct  numeric
);

INSERT INTO demo_fc_events VALUES
 ('PROMO-DRIP-1', 'DRIP-10',     NULL,  current_date - 60, current_date - 47, 'promo', 50),
 ('PROMO-ETH-2',  'ETH-SID-250', 'ala', current_date + 10, current_date + 16, 'promo', 30)
ON CONFLICT (event_id) DO NOTHING;

CREATE TABLE IF NOT EXISTS demo_fc_material_stock (
    material_code text PRIMARY KEY,
    qty_on_hand   numeric(18,3) NOT NULL,
    qty_on_order  numeric(18,3) NOT NULL
);

INSERT INTO demo_fc_material_stock VALUES
 ('GREEN-ETH',  300, 0),
 ('GREEN-BRA',  900, 500),
 ('GREEN-COL',  150, 0),
 ('GREEN-KEN',   40, 0),
 ('PACK-250',  3000, 0),
 ('PACK-1KG',   800, 0)
ON CONFLICT (material_code) DO NOTHING;

CREATE OR REPLACE VIEW src_fc_sales_daily AS
SELECT sku, location_id, day, qty FROM demo_fc_sales;

CREATE OR REPLACE VIEW src_fc_events AS
SELECT event_id, sku, location_id, date_from, date_to, kind, uplift_pct FROM demo_fc_events;

CREATE OR REPLACE VIEW src_fc_material_stock AS
SELECT material_code, qty_on_hand, qty_on_order FROM demo_fc_material_stock;
