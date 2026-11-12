-- Сверка «одни цифры»: показатель модуля против единого показателя metrics с тем же id.
-- Пишет /airl-modules при приёмке модуля в хабе (шаг 7). Главный — metrics: в хаб уходит он,
-- а модуль обязан с ним совпадать. Строка с mismatches > 0 — находка, модуль не принят.
-- Запуск под администратором тестового хранилища:
--   psql "$ADMIN_DB_URL" -v ON_ERROR_STOP=1 -f reconcile.sql
-- Замени [схему], [модульный показатель] и [id]; по блоку UNION ALL на каждый общий показатель.
WITH checks AS (
    SELECT '[id]: mart_[отдел].m_[показатель модуля] = metrics.m_[id]' AS check_name,
           x.period, x.value AS module_value, m.value AS metrics_value
    FROM mart_[отдел].m_[показатель модуля] x
    JOIN metrics.m_[id] m USING (period)
    WHERE x.metric_id = '[id]'                 -- или '[id]:all' для семейства с разрезами
    -- UNION ALL
    -- SELECT '…', …
)
SELECT check_name,
       count(*)                                                        AS periods,
       count(*) FILTER (WHERE module_value IS DISTINCT FROM metrics_value) AS mismatches,
       max(abs(module_value - metrics_value))                          AS max_diff
FROM checks
GROUP BY check_name
ORDER BY check_name;
