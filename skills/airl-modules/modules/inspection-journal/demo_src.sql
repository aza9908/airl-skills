-- Демо-источник: синтетические партии обжарки. Только для разработки и показа.
-- В работе src_inspection_objects заменяет адаптер /airl-dwh или /airl-connect.

CREATE TABLE IF NOT EXISTS demo_insp_objects (
    object_id   text PRIMARY KEY,
    object_type text NOT NULL,
    title       text NOT NULL,
    sku         text,
    lot         text,
    produced_at timestamptz NOT NULL,
    produced_by text,
    branch_id   text
);

INSERT INTO demo_insp_objects VALUES
 ('PR-1001', 'batch', 'Эфиопия Сидамо · 12 кг',  'ETH-SID-250', 'GL-24-017', now() - interval '3 days',  'roaster_1', 'roast'),
 ('PR-1002', 'batch', 'Бразилия Серрадо · 15 кг', 'BRA-CER-1KG', 'GL-24-021', now() - interval '2 days',  'roaster_2', 'roast'),
 ('PR-1003', 'batch', 'Колумбия Уила · 10 кг',   'COL-HUI-250', 'GL-24-019', now() - interval '40 hours', 'roaster_1', 'roast'),
 ('PR-1004', 'batch', 'Эфиопия Сидамо · 12 кг',  'ETH-SID-250', 'GL-24-017', now() - interval '30 hours', 'roaster_2', 'roast'),
 ('PR-1005', 'batch', 'Бразилия Серрадо · 15 кг', 'BRA-CER-1KG', 'GL-24-022', now() - interval '5 hours',  'roaster_1', 'roast'),
 ('PR-1006', 'batch', 'Кения AA · 8 кг',         'KEN-AA-250',  'GL-24-025', now() - interval '2 hours',  'roaster_2', 'roast')
ON CONFLICT (object_id) DO NOTHING;

CREATE OR REPLACE VIEW src_inspection_objects AS
SELECT object_id, object_type, title, sku, lot, produced_at, produced_by, branch_id
FROM demo_insp_objects;
