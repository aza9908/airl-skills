-- Синтетические настройки, материалы и нормы расхода для разработки и показа.
-- Расчёт запускается, только если сегодня ещё не было успешного — повторный запуск
-- seed.sql не плодит расчёты.

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('demand-forecast', 'horizon_weeks',     '8',                   'demo'),
 ('demand-forecast', 'backtest_weeks',    '8',                   'demo'),
 ('demand-forecast', 'sn_weeks',          '4',                   'demo'),
 ('demand-forecast', 'ma_days',           '56',                  'demo'),
 ('demand-forecast', 'ses_alpha',         '0.3',                 'demo'),
 ('demand-forecast', 'min_history_weeks', '26',                  'demo'),
 ('demand-forecast', 'recent_weeks',      '8',                   'demo'),
 ('demand-forecast', 'roast_loss_pct',    '17',                  'demo'),
 ('demand-forecast', 'wape_warn',         '30',                  'demo'),
 ('demand-forecast', 'wape_bad',          '50',                  'demo'),
 ('demand-forecast', 'coverage_warn',     '90',                  'demo'),
 ('demand-forecast', 'coverage_bad',      '70',                  'demo'),
 ('demand-forecast', 'recipient',         '"role:purchasing"',   'demo'),
 ('demand-forecast', 'tech_recipient',    '"role:analyst"',      'demo'),
 ('demand-forecast', 'channel',           '"telegram"',          'demo')
ON CONFLICT (module, key) DO NOTHING;

INSERT INTO fc_materials (code, title, unit, lead_time_weeks, safety_weeks, pack_size, created_by) VALUES
 ('GREEN-ETH', 'Зелёное зерно Эфиопия Сидамо',  'кг', 10, 3, 60,   'demo'),
 ('GREEN-BRA', 'Зелёное зерно Бразилия Серрадо', 'кг', 8,  3, 60,   'demo'),
 ('GREEN-COL', 'Зелёное зерно Колумбия Уила',    'кг', 10, 3, 70,   'demo'),
 ('GREEN-KEN', 'Зелёное зерно Кения AA',         'кг', 12, 3, 60,   'demo'),
 ('PACK-250',  'Дой-пак 250 г с клапаном',       'шт', 3,  2, 1000, 'demo'),
 ('PACK-1KG',  'Дой-пак 1 кг с клапаном',        'шт', 3,  2, 500,  'demo')
ON CONFLICT (code) DO NOTHING;

-- Нормы: кг обжаренного зерна в единице товара; упаковка — без потерь (loss_pct = 0).
-- Для зерна loss_pct не задан — берётся ужарка из настройки roast_loss_pct (17 %).
INSERT INTO fc_bom (output_sku, material_code, qty_per_unit, loss_pct, created_by) VALUES
 ('ETH-SID-250',   'GREEN-ETH', 0.25, NULL, 'demo'),
 ('ETH-SID-250',   'PACK-250',  1,    0,    'demo'),
 ('BRA-CER-1KG',   'GREEN-BRA', 1.0,  NULL, 'demo'),
 ('BRA-CER-1KG',   'PACK-1KG',  1,    0,    'demo'),
 ('COL-HUI-250',   'GREEN-COL', 0.25, NULL, 'demo'),
 ('COL-HUI-250',   'PACK-250',  1,    0,    'demo'),
 ('ESP-BLEND-1KG', 'GREEN-BRA', 0.6,  NULL, 'demo'),
 ('ESP-BLEND-1KG', 'GREEN-COL', 0.4,  NULL, 'demo'),
 ('ESP-BLEND-1KG', 'PACK-1KG',  1,    0,    'demo'),
 ('DRIP-10',       'GREEN-ETH', 0.1,  NULL, 'demo'),
 ('KEN-AA-250',    'GREEN-KEN', 0.25, NULL, 'demo'),
 ('KEN-AA-250',    'PACK-250',  1,    0,    'demo')
ON CONFLICT (output_sku, material_code) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM fc_runs WHERE status = 'done' AND created_at::date = current_date) THEN
        PERFORM fc_run('demo');
        -- Закупщик принял предложение по бразильскому зерну.
        PERFORM fc_decide(g.id, 'accepted', 'u_purchase', 'Заказ поставщику на следующей неделе')
        FROM fc_suggestions g JOIN fc_runs r ON r.id = g.run_id
        WHERE r.id = (SELECT max(id) FROM fc_runs WHERE status = 'done')
          AND g.material_code = 'GREEN-BRA' AND g.status = 'proposed';
        PERFORM fc_queue_notifications();
    END IF;
END $$;
