-- Сверка «одни цифры»: показатели модулей витрин против единых показателей metrics.
-- Каждая строка — сравнение; расхождение > 0 — находка. Запуск: psql "$ADMIN_DB_URL" -f tests/reconcile.sql
WITH checks AS (
    SELECT 'revenue: модуль ОПиУ (компания) = metrics.m_revenue' AS check_name, r.period,
           r.fact AS module_value, m.value AS metrics_value
    FROM mart_finance.v_pnl_report r JOIN metrics.m_revenue m USING (period)
    WHERE r.branch_id = 'all' AND r.line_code = 'S:revenue'
    UNION ALL
    SELECT 'gross_margin:all: m_pnl_gross_margin = metrics.m_gross_margin', g.period, g.value, m.value
    FROM mart_finance.m_pnl_gross_margin g JOIN metrics.m_gross_margin m USING (metric_id, period)
    WHERE g.metric_id = 'gross_margin:all'
    UNION ALL
    SELECT 'net_profit:all: m_pnl_net_profit = metrics.m_net_profit', n.period, n.value, m.value
    FROM mart_finance.m_pnl_net_profit n JOIN metrics.m_net_profit m USING (metric_id, period)
    UNION ALL
    SELECT 'cash_balance: m_pnl_cash_balance = metrics.m_cash_balance', c.period, c.value, m.value
    FROM mart_finance.m_pnl_cash_balance c JOIN metrics.m_cash_balance m USING (period)
    UNION ALL
    SELECT 'receivables_overdue: модуль = metrics на вчера', 'сегодня', r.value,
           (SELECT value FROM metrics.kpi_period('day') WHERE metric_id = 'receivables_overdue')
    FROM mart_finance.m_receivables_overdue r
    UNION ALL
    SELECT 'plan-fact: факт выручки месяца = metrics.m_revenue', to_char(p.month, 'YYYY-MM'), p.fact_value, m.value
    FROM mart_sales.v_pf_plan_fact p JOIN metrics.m_revenue m ON m.period = to_char(p.month, 'YYYY-MM')
    WHERE p.metric_id = 'revenue' AND p.dimension_type = 'company' AND p.month < date_trunc('month', current_date)
)
SELECT check_name, count(*) AS periods, count(*) FILTER (WHERE module_value IS DISTINCT FROM metrics_value) AS mismatches,
       max(abs(module_value - metrics_value)) AS max_diff
FROM checks GROUP BY check_name ORDER BY check_name;
