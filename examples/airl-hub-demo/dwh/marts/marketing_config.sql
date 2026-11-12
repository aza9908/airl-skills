-- Настройка витрины «Маркетинг». Значения СИНТЕТИЧЕСКИЕ (таблица бюджета генератора). Повторный запуск безопасен.
SET search_path TO mart_marketing;

INSERT INTO airl_settings (module, key, value, updated_by) VALUES
 ('kit',       'currency',        '"KZT"', 'setup'),
 ('marketing', 'budget_warn_pct', '110',   'setup'),
 ('marketing', 'budget_bad_pct',  '125',   'setup')
ON CONFLICT (module, key) DO NOTHING;

-- Бюджет — из таблицы бюджета маркетинга (raw_ads.mkt_budget), один раз при подключении: дальше его
-- меняет руководитель маркетинга в сервисе («Изменить бюджет»), витрина — источник правды по бюджету.
-- Следующий месяц — как текущий (план ещё не утверждён).
INSERT INTO mkt_budgets (month, channel, amount, created_by, updated_by)
SELECT month::date, channel, budget::numeric, 'setup', 'setup' FROM raw_ads.mkt_budget
UNION ALL
SELECT (month::date + interval '1 month')::date, channel, budget::numeric, 'setup', 'setup' FROM raw_ads.mkt_budget
WHERE month::date = date_trunc('month', current_date)::date
ON CONFLICT DO NOTHING;

-- staff_marketing ведёт Instagram и лид-формы Meta (SMM): заметки — только к своим кампаниям.
INSERT INTO mkt_staff_channels (login, channels, created_by)
VALUES ('staff_marketing', ARRAY['instagram', 'meta_form'], 'setup')
ON CONFLICT (login) DO NOTHING;
